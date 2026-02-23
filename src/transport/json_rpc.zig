const std = @import("std");

pub const RpcEnvelope = struct {
    id: ?u64,
    has_error: bool,
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

    const has_error = root.object.get("error") != null;

    return .{
        .id = id,
        .has_error = has_error,
    };
}

fn parseIdValue(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |v| if (v >= 0) @as(u64, @intCast(v)) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
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
    const env = try decodeEnvelope(allocator, "{\"id\":11,\"error\":{\"message\":\"boom\"}}");
    try std.testing.expectEqual(@as(?u64, 11), env.id);
    try std.testing.expect(env.has_error);
}

test "decode envelope event message" {
    const allocator = std.testing.allocator;
    const env = try decodeEnvelope(allocator, "{\"method\":\"Network.requestWillBeSent\",\"params\":{}}");
    try std.testing.expectEqual(@as(?u64, null), env.id);
    try std.testing.expect(!env.has_error);
}
