const std = @import("std");
const Session = @import("../core/session.zig").Session;
const executor = @import("executor.zig");
const json_util = @import("../util/json.zig");
const compat = @import("../util/compat.zig");

const max_trace_bytes = 256 * 1024 * 1024;
const trace_timeout_ms = 30_000;

pub fn start(session: *Session) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    session.state_lock.lock();
    const pending = session.trace_stream != null;
    if (!pending) session.trace_data_loss = false;
    session.state_lock.unlock();
    if (pending) return error.TracePending;
    const raw = try executor.callCdp(session, "Tracing.start", "{\"transferMode\":\"ReturnAsStream\",\"streamFormat\":\"json\",\"streamCompression\":\"none\"}");
    session.allocator.free(raw);
}

pub fn stop(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    session.state_lock.lock();
    const pending = session.trace_stream != null;
    session.state_lock.unlock();
    if (!pending) {
        const raw = try executor.callCdp(session, "Tracing.end", "{}");
        session.allocator.free(raw);
    }
    const started = compat.milliTimestamp();
    const handle = while (true) {
        session.state_lock.lock();
        const stream = session.trace_stream;
        session.trace_stream = null;
        session.state_lock.unlock();
        if (stream) |value| break value;
        if (compat.milliTimestamp() - started >= trace_timeout_ms) return error.Timeout;
        // Commands drain the persistent socket's notifications, including the
        // asynchronous tracingComplete event. This is read-only browser work.
        const pulse = try executor.callCdp(session, "Browser.getVersion", "{}");
        session.allocator.free(pulse);
        compat.sleepMs(10);
    };
    defer session.allocator.free(handle);
    const escaped = try json_util.escapeJsonString(session.allocator, handle);
    defer session.allocator.free(escaped);
    const close_params = try std.fmt.allocPrint(session.allocator, "{{\"handle\":\"{s}\"}}", .{escaped});
    defer session.allocator.free(close_params);
    var closed = false;
    defer if (!closed) {
        const response = executor.callCdp(session, "IO.close", close_params) catch null;
        if (response) |value| session.allocator.free(value);
    };
    session.state_lock.lock();
    const lost = session.trace_data_loss;
    session.state_lock.unlock();
    if (lost) return error.TraceDataLoss;
    const read_params = try std.fmt.allocPrint(session.allocator, "{{\"handle\":\"{s}\",\"size\":1048576}}", .{escaped});
    defer session.allocator.free(read_params);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(session.allocator);
    while (true) {
        if (compat.milliTimestamp() - started >= trace_timeout_ms) return error.Timeout;
        const response = try executor.callCdp(session, "IO.read", read_params);
        defer session.allocator.free(response);
        if (try appendChunk(session.allocator, &bytes, response, max_trace_bytes)) break;
    }
    try validateTrace(session.allocator, bytes.items);
    const close_response = try executor.callCdp(session, "IO.close", close_params);
    session.allocator.free(close_response);
    closed = true;
    return bytes.toOwnedSlice(session.allocator);
}

fn appendChunk(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), payload: []const u8, limit: usize) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const data = result.object.get("data") orelse return error.InvalidResponse;
    const eof = result.object.get("eof") orelse return error.InvalidResponse;
    if (data != .string or eof != .bool) return error.InvalidResponse;
    const encoded = if (result.object.get("base64Encoded")) |value| blk: {
        if (value != .bool) return error.InvalidResponse;
        break :blk value.bool;
    } else false;
    const size = if (encoded) std.base64.standard.Decoder.calcSizeForSlice(data.string) catch return error.InvalidResponse else data.string.len;
    if (bytes.items.len > limit or size > limit - bytes.items.len) return error.TraceTooLarge;
    if (encoded) {
        // Validate in separate storage before appending, so an invalid chunk
        // does not publish a partially decoded trace or mutate prior bytes.
        const decoded = try allocator.alloc(u8, size);
        defer allocator.free(decoded);
        std.base64.standard.Decoder.decode(decoded, data.string) catch return error.InvalidResponse;
        try bytes.appendSlice(allocator, decoded);
    } else try bytes.appendSlice(allocator, data.string);
    return eof.bool;
}

fn validateTrace(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const events = parsed.value.object.get("traceEvents") orelse return error.InvalidResponse;
    if (events != .array) return error.InvalidResponse;
    for (events.array.items) |event| {
        if (event != .object) return error.InvalidResponse;
    }
}

test "trace chunks assemble text and base64 across arbitrary JSON boundaries" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try std.testing.expect(!try appendChunk(allocator, &bytes, "{\"result\":{\"data\":\"{\\\"traceEvents\\\":[\",\"eof\":false}}", 1024));
    try std.testing.expect(try appendChunk(allocator, &bytes, "{\"result\":{\"data\":\"e31dfQ==\",\"base64Encoded\":true,\"eof\":true}}", 1024));
    try std.testing.expectEqualStrings("{\"traceEvents\":[{}]}", bytes.items);
    try validateTrace(allocator, bytes.items);
}

test "trace chunk validation rejects malformed payloads and enforces exact byte budget" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    const invalid = [_][]const u8{
        "[]",                                                              "{}",                                                                   "{\"result\":[]}",
        "{\"result\":{\"data\":\"x\"}}",                                   "{\"result\":{\"data\":4,\"eof\":false}}",                              "{\"result\":{\"data\":\"x\",\"eof\":\"yes\"}}",
        "{\"result\":{\"data\":\"x\",\"eof\":false,\"base64Encoded\":1}}", "{\"result\":{\"data\":\"@@@@\",\"eof\":true,\"base64Encoded\":true}}",
    };
    for (invalid) |payload| {
        try std.testing.expectError(error.InvalidResponse, appendChunk(allocator, &bytes, payload, 4));
        try std.testing.expectEqual(@as(usize, 0), bytes.items.len);
    }
    _ = try appendChunk(allocator, &bytes, "{\"result\":{\"data\":\"1234\",\"eof\":false}}", 4);
    try std.testing.expectError(error.TraceTooLarge, appendChunk(allocator, &bytes, "{\"result\":{\"data\":\"5\",\"eof\":true}}", 4));
    try std.testing.expectEqualStrings("1234", bytes.items);
}

test "trace result validation refuses acknowledgements and truncated traces" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"result\":{}}", "{\"traceEvents\":{}}", "{\"traceEvents\":[", "{\"traceEvents\":[1]}" }) |payload| {
        try std.testing.expectError(error.InvalidResponse, validateTrace(allocator, payload));
    }
    try validateTrace(allocator, "{\"traceEvents\":[]}");
}
