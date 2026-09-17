const std = @import("std");
const compat = @import("../util/compat.zig");
const ws = @import("../transport/ws_client.zig");
const rpc = @import("../transport/json_rpc.zig");
const common = @import("../protocol/common.zig");
const types = @import("../types.zig");

pub const Callbacks = struct {
    request: ?*const fn (types.RequestEvent) void = null,
    response: ?*const fn (types.ResponseEvent) void = null,
    raw: ?*const fn ([]const u8) void = null,
};

/// Callbacks run on a dedicated task with borrowed event strings. Registration
/// can change inside a callback, but destroying the owning session there is not
/// supported: destruction joins this task.
pub const Observer = struct {
    allocator: std.mem.Allocator,
    client: ws.Client,
    mutex: compat.Mutex = .{},
    callbacks: Callbacks,
    failure: ?anyerror = null,
    worker: ?std.Io.Future(anyerror!void) = null,

    pub fn create(allocator: std.mem.Allocator, endpoint: []const u8, callbacks: Callbacks) !*Observer {
        const parsed = try common.parseEndpoint(endpoint, .cdp);
        if (!std.mem.startsWith(u8, parsed.path, "/devtools/page/")) return error.InvalidEndpoint;
        const self = try allocator.create(Observer);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .client = try ws.Client.connect(allocator, parsed.host, parsed.port, parsed.path), .callbacks = callbacks };
        errdefer self.client.deinit();
        try self.client.sendText("{\"id\":1,\"method\":\"Network.enable\",\"params\":{}}");
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

    pub fn setRequest(self: *Observer, callback: ?*const fn (types.RequestEvent) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callbacks.request = callback;
    }

    pub fn setResponse(self: *Observer, callback: ?*const fn (types.ResponseEvent) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callbacks.response = callback;
    }

    pub fn setRaw(self: *Observer, callback: ?*const fn ([]const u8) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callbacks.raw = callback;
    }

    pub fn check(self: *Observer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |failure| return failure;
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
            self.mutex.lock();
            const callbacks = self.callbacks;
            self.mutex.unlock();
            try dispatch(self.allocator, message, callbacks);
        }
    }
};

pub fn dispatch(allocator: std.mem.Allocator, message: []const u8, callbacks: Callbacks) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const method = stringField(parsed.value.object, "method") orelse return;
    if (!std.mem.startsWith(u8, method, "Network.")) return;
    const params = parsed.value.object.get("params") orelse return error.InvalidResponse;
    if (params != .object) return error.InvalidResponse;
    if (callbacks.raw) |callback| callback(message);
    if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
        const request_id = stringField(params.object, "requestId") orelse return error.InvalidResponse;
        if (params.object.get("redirectResponse")) |redirect| {
            try emitResponse(allocator, callbacks.response, request_id, redirect);
        }
        const callback = callbacks.request orelse return;
        const request = params.object.get("request") orelse return error.InvalidResponse;
        if (request != .object) return error.InvalidResponse;
        const headers = try std.json.Stringify.valueAlloc(allocator, request.object.get("headers") orelse return error.InvalidResponse, .{});
        defer allocator.free(headers);
        callback(.{
            .request_id = request_id,
            .method = stringField(request.object, "method") orelse return error.InvalidResponse,
            .url = stringField(request.object, "url") orelse return error.InvalidResponse,
            .headers_json = headers,
            .body = stringField(request.object, "postData"),
        });
    } else if (std.mem.eql(u8, method, "Network.responseReceived")) {
        try emitResponse(allocator, callbacks.response, stringField(params.object, "requestId") orelse return error.InvalidResponse, params.object.get("response") orelse return error.InvalidResponse);
    }
}

fn emitResponse(allocator: std.mem.Allocator, maybe_callback: ?*const fn (types.ResponseEvent) void, id: []const u8, response: std.json.Value) !void {
    const callback = maybe_callback orelse return;
    if (response != .object) return error.InvalidResponse;
    const status_value = response.object.get("status") orelse return error.InvalidResponse;
    const status: u16 = switch (status_value) {
        .integer => |n| std.math.cast(u16, n) orelse return error.InvalidResponse,
        .float => |n| if (std.math.isFinite(n) and n >= 0 and n <= std.math.maxInt(u16) and @trunc(n) == n) @intFromFloat(n) else return error.InvalidResponse,
        else => return error.InvalidResponse,
    };
    const headers = try std.json.Stringify.valueAlloc(allocator, response.object.get("headers") orelse return error.InvalidResponse, .{});
    defer allocator.free(headers);
    callback(.{ .request_id = id, .status = status, .url = stringField(response.object, "url") orelse return error.InvalidResponse, .headers_json = headers });
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

var test_requests: usize = 0;
var test_responses: usize = 0;
var test_raw: usize = 0;

fn testRequest(event: types.RequestEvent) void {
    std.testing.expectEqualStrings("POST", event.method) catch @panic("wrong method");
    std.testing.expectEqualStrings("https://example.test/final", event.url) catch @panic("wrong URL");
    std.testing.expectEqualStrings("body", event.body.?) catch @panic("wrong body");
    std.testing.expectEqualStrings("{\"X-Test\":\"yes\"}", event.headers_json) catch @panic("wrong headers");
    test_requests += 1;
}
fn testResponse(event: types.ResponseEvent) void {
    std.testing.expectEqual(@as(u16, 302), event.status) catch @panic("wrong status");
    std.testing.expectEqualStrings("https://example.test/start", event.url) catch @panic("wrong redirect");
    test_responses += 1;
}
fn testRaw(message: []const u8) void {
    std.testing.expect(std.mem.indexOf(u8, message, "Network.requestWillBeSent") != null) catch @panic("fake event");
    test_raw += 1;
}

test "network observer dispatch preserves real metadata and redirect responses without synthetic events" {
    test_requests = 0;
    test_responses = 0;
    test_raw = 0;
    const callbacks: Callbacks = .{ .request = testRequest, .response = testResponse, .raw = testRaw };
    try dispatch(std.testing.allocator,
        \\{"method":"Network.requestWillBeSent","params":{"requestId":"1","request":{"method":"POST","url":"https://example.test/final","headers":{"X-Test":"yes"},"postData":"body"},"redirectResponse":{"status":302,"url":"https://example.test/start","headers":{"Location":"/final"}}}}
    , callbacks);
    try dispatch(std.testing.allocator, "{\"id\":1,\"result\":{}}", callbacks);
    try dispatch(std.testing.allocator, "{\"method\":\"Page.loadEventFired\",\"params\":{}}", callbacks);
    try std.testing.expectEqual(@as(usize, 1), test_requests);
    try std.testing.expectEqual(@as(usize, 1), test_responses);
    try std.testing.expectEqual(@as(usize, 1), test_raw);
}
