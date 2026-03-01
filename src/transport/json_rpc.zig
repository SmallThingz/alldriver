const std = @import("std");

pub const RpcEnvelope = struct {
    id: ?u64,
    has_error: bool,
    error_code: ?i64 = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *RpcEnvelope, allocator: std.mem.Allocator) void {
        if (self.error_message) |message| allocator.free(message);
        self.* = undefined;
    }
};

pub fn encodeRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: ?[]const u8,
) ![]u8 {
    if (params_json) |params| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":{d},\"method\":\"{s}\"}}",
        .{ id, method },
    );
}

pub fn extractId(response_json: []const u8) ?u64 {
    const key_idx = std.mem.indexOf(u8, response_json, "\"id\":") orelse return null;
    var i = key_idx + 5;

    while (i < response_json.len and (response_json[i] == ' ' or response_json[i] == '\t')) : (i += 1) {}

    if (i < response_json.len and response_json[i] == '"') {
        i += 1;
        var j = i;
        while (j < response_json.len and std.ascii.isDigit(response_json[j])) : (j += 1) {}
        if (j == i or j >= response_json.len or response_json[j] != '"') return null;
        return std.fmt.parseInt(u64, response_json[i..j], 10) catch null;
    }

    var j = i;
    while (j < response_json.len and std.ascii.isDigit(response_json[j])) : (j += 1) {}
    if (j == i) return null;

    return std.fmt.parseInt(u64, response_json[i..j], 10) catch null;
}

pub fn decodeEnvelope(allocator: std.mem.Allocator, response_json: []const u8) !RpcEnvelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    var id: ?u64 = null;
    if (root.object.get("id")) |id_value| {
        id = parseIdValue(id_value);
    }

    var has_error = false;
    var error_code: ?i64 = null;
    var error_message: ?[]u8 = null;
    if (root.object.get("error")) |error_value| {
        has_error = true;
        if (error_value == .object) {
            error_code = getErrorCode(error_value.object);
            if (error_value.object.get("message")) |message_value| {
                if (message_value == .string) {
                    error_message = try allocator.dupe(u8, message_value.string);
                }
            }
        }
    }

    return .{
        .id = id,
        .has_error = has_error,
        .error_code = error_code,
        .error_message = error_message,
    };
}

fn parseIdValue(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |v| if (v >= 0) @as(u64, @intCast(v)) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn getErrorCode(obj: std.json.ObjectMap) ?i64 {
    const value = obj.get("code") orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

test "encode request" {
    const allocator = std.testing.allocator;
    const req = try encodeRequest(allocator, 3, "Runtime.evaluate", "{\"expression\":\"2+2\"}");
    defer allocator.free(req);

    try std.testing.expect(std.mem.indexOf(u8, req, "Runtime.evaluate") != null);
    try std.testing.expectEqual(@as(?u64, 3), extractId(req));
}

test "decode envelope with error" {
    const allocator = std.testing.allocator;
    var env = try decodeEnvelope(allocator, "{\"id\":11,\"error\":{\"code\":-32000,\"message\":\"boom\"}}");
    defer env.deinit(allocator);
    try std.testing.expectEqual(@as(?u64, 11), env.id);
    try std.testing.expect(env.has_error);
    try std.testing.expectEqual(@as(?i64, -32000), env.error_code);
    try std.testing.expectEqualStrings("boom", env.error_message.?);
}

test "decode envelope event message" {
    const allocator = std.testing.allocator;
    var env = try decodeEnvelope(allocator, "{\"method\":\"Network.requestWillBeSent\",\"params\":{}}");
    defer env.deinit(allocator);
    try std.testing.expectEqual(@as(?u64, null), env.id);
    try std.testing.expect(!env.has_error);
    try std.testing.expectEqual(@as(?i64, null), env.error_code);
    try std.testing.expectEqual(@as(?[]u8, null), env.error_message);
}
