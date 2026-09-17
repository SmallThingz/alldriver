const std = @import("std");

/// Strings are borrowed and remain valid only for the duration of the callback.
pub const LogEntry = struct {
    level: []const u8,
    text: []const u8,
    /// Script URL when reported by Chromium, otherwise the event source name.
    source: []const u8,
};

pub const Callback = *const fn (LogEntry) void;

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
