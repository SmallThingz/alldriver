const std = @import("std");
const compat = @import("../util/compat.zig");
const ws = @import("../transport/ws_client.zig");
const rpc = @import("../transport/json_rpc.zig");
const common = @import("../protocol/common.zig");

/// Strings are borrowed and remain valid only for the duration of the callback.
pub const LogEntry = struct {
    level: []const u8,
    text: []const u8,
    /// Script URL when reported by Chromium, otherwise the event source name.
    source: []const u8,
};

pub const Callback = *const fn (LogEntry) void;

/// A stable, heap-owned push subscription independent of command traffic.
/// Callbacks run on the observer task and may unregister themselves. The owner
/// must not destroy the session from inside one of its own callbacks.
pub const Observer = struct {
    allocator: std.mem.Allocator,
    client: ws.Client,
    mutex: compat.Mutex = .{},
    console_callback: ?Callback = null,
    exception_callback: ?Callback = null,
    failure: ?anyerror = null,
    worker: ?std.Io.Future(anyerror!void) = null,

    pub fn create(allocator: std.mem.Allocator, endpoint: []const u8) !*Observer {
        const parsed = try common.parseEndpoint(endpoint, .cdp);
        if (!std.mem.startsWith(u8, parsed.path, "/devtools/page/")) return error.InvalidEndpoint;
        const self = try allocator.create(Observer);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .client = try ws.Client.connect(allocator, parsed.host, parsed.port, parsed.path) };
        errdefer self.client.deinit();
        try self.client.sendText("{\"id\":1,\"method\":\"Runtime.enable\",\"params\":{}}");
        while (true) {
            const message = try self.client.recvText(allocator);
            defer allocator.free(message);
            var envelope = try rpc.decodeEnvelope(allocator, message);
            defer envelope.deinit(allocator);
            if (envelope.id == 1) {
                if (envelope.has_error) return error.ProtocolCommandFailed;
                break;
            }
        }
        self.client.receive_timeout_ms = std.math.maxInt(u32);
        self.worker = try std.Io.concurrent(compat.io(), run, .{self});
        return self;
    }

    pub fn destroy(self: *Observer) void {
        if (self.worker) |*worker| _ = worker.cancel(compat.io()) catch {};
        self.client.deinit();
        self.allocator.destroy(self);
    }

    pub fn setConsole(self: *Observer, callback: ?Callback) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |failure| return failure;
        self.console_callback = callback;
    }

    pub fn setException(self: *Observer, callback: ?Callback) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |failure| return failure;
        self.exception_callback = callback;
    }

    pub fn clearConsole(self: *Observer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.console_callback = null;
    }

    pub fn clearException(self: *Observer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.exception_callback = null;
    }

    pub fn lastError(self: *Observer) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure;
    }

    fn run(self: *Observer) anyerror!void {
        self.receiveLoop() catch |err| {
            self.mutex.lock();
            self.failure = err;
            self.mutex.unlock();
            return err;
        };
    }

    fn receiveLoop(self: *Observer) !void {
        while (true) {
            const message = try self.client.recvText(self.allocator);
            defer self.allocator.free(message);
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidResponse;
            const method = parsed.value.object.get("method") orelse continue;
            const params = parsed.value.object.get("params") orelse continue;
            if (method != .string or params != .object) continue;
            self.mutex.lock();
            const console = self.console_callback;
            const exception = self.exception_callback;
            self.mutex.unlock();
            try handleNotification(self.allocator, method.string, params.object, console, exception);
        }
    }
};

pub fn handleNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: std.json.ObjectMap,
    console_callback: ?Callback,
    exception_callback: ?Callback,
) !void {
    if (std.mem.eql(u8, method, "Runtime.consoleAPICalled")) {
        const callback = console_callback orelse return;
        const kind = stringField(params, "type") orelse return;
        const args = params.get("args") orelse return;
        if (args != .array) return;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (args.array.items, 0..) |arg, index| {
            if (arg != .object) return;
            if (index > 0) try text.append(allocator, ' ');
            try appendRemoteObject(allocator, &text, arg.object);
        }
        callback(.{
            .level = if (std.mem.eql(u8, kind, "assert")) "error" else kind,
            .text = text.items,
            .source = stackSource(params) orelse "console-api",
        });
    } else if (std.mem.eql(u8, method, "Runtime.exceptionThrown")) {
        const callback = exception_callback orelse return;
        const details = params.get("exceptionDetails") orelse return;
        if (details != .object) return;
        const fallback = stringField(details.object, "text") orelse return;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        if (details.object.get("exception")) |exception| {
            if (exception == .object) try appendRemoteObject(allocator, &text, exception.object);
        }
        callback(.{
            .level = "error",
            .text = if (text.items.len != 0) text.items else fallback,
            .source = stringField(details.object, "url") orelse stackSource(details.object) orelse "javascript",
        });
    }
}

fn appendRemoteObject(allocator: std.mem.Allocator, out: *std.ArrayList(u8), object: std.json.ObjectMap) !void {
    if (object.get("value")) |value| {
        if (value == .string) return out.appendSlice(allocator, value.string);
        const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(encoded);
        return out.appendSlice(allocator, encoded);
    }
    if (stringField(object, "unserializableValue")) |value| return out.appendSlice(allocator, value);
    if (stringField(object, "description")) |description| return out.appendSlice(allocator, description);
    if (stringField(object, "type")) |kind| return out.appendSlice(allocator, kind);
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

fn stackSource(object: std.json.ObjectMap) ?[]const u8 {
    const stack = object.get("stackTrace") orelse return null;
    if (stack != .object) return null;
    const frames = stack.object.get("callFrames") orelse return null;
    if (frames != .array) return null;
    for (frames.array.items) |frame| {
        if (frame != .object) continue;
        const url = stringField(frame.object, "url") orelse continue;
        if (url.len > 0) return url;
    }
    return null;
}

var captured_calls: usize = 0;
var capture_matches: bool = false;
fn captureConsole(entry: LogEntry) void {
    captured_calls += 1;
    capture_matches = std.mem.eql(u8, entry.level, "warning") and
        std.mem.eql(u8, entry.text, "hello 42 true null undefined NaN Object") and
        std.mem.eql(u8, entry.source, "https://example.test/app.js");
}
fn captureException(entry: LogEntry) void {
    captured_calls += 1;
    capture_matches = std.mem.eql(u8, entry.level, "error") and
        std.mem.eql(u8, entry.text, "TypeError: broken\n    at app.js:1") and
        std.mem.eql(u8, entry.source, "https://example.test/app.js");
}

test "console notification preserves remote argument values and source URL" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"type":"warning","args":[{"type":"string","value":"hello"},{"type":"number","value":42},{"type":"boolean","value":true},{"type":"object","value":null},{"type":"undefined"},{"type":"number","unserializableValue":"NaN"},{"type":"object","description":"Object"}],"stackTrace":{"callFrames":[{"url":"https://example.test/app.js"}]}}
    , .{});
    defer parsed.deinit();
    captured_calls = 0;
    capture_matches = false;
    try handleNotification(allocator, "Runtime.consoleAPICalled", parsed.value.object, captureConsole, null);
    try std.testing.expectEqual(@as(usize, 1), captured_calls);
    try std.testing.expect(capture_matches);
    try handleNotification(allocator, "Runtime.consoleAPICalled", parsed.value.object, null, captureException);
    try std.testing.expectEqual(@as(usize, 1), captured_calls);
}

test "exception notification preserves actual error description and stack source" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"exceptionDetails":{"text":"Uncaught","exception":{"type":"object","description":"TypeError: broken\n    at app.js:1"},"stackTrace":{"callFrames":[{"url":"https://example.test/app.js"}]}}}
    , .{});
    defer parsed.deinit();
    captured_calls = 0;
    capture_matches = false;
    try handleNotification(allocator, "Runtime.exceptionThrown", parsed.value.object, null, captureException);
    try std.testing.expectEqual(@as(usize, 1), captured_calls);
    try std.testing.expect(capture_matches);
    try handleNotification(allocator, "Runtime.exceptionThrown", parsed.value.object, captureConsole, null);
    try std.testing.expectEqual(@as(usize, 1), captured_calls);
}

test "malformed log notifications do not invent callback entries" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer parsed.deinit();
    captured_calls = 0;
    try handleNotification(allocator, "Runtime.consoleAPICalled", parsed.value.object, captureConsole, captureException);
    try handleNotification(allocator, "Runtime.exceptionThrown", parsed.value.object, captureConsole, captureException);
    try std.testing.expectEqual(@as(usize, 0), captured_calls);
}
