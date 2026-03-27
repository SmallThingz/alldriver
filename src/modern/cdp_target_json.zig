const std = @import("std");

pub const ParsedTargetInfo = struct {
    id: []u8,
    kind: []u8,
};

pub fn parseTargetInfos(allocator: std.mem.Allocator, payload: []const u8) ![]ParsedTargetInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const target_infos = result.object.get("targetInfos") orelse return error.InvalidResponse;
    if (target_infos != .array) return error.InvalidResponse;

    var out: std.ArrayList(ParsedTargetInfo) = .empty;
    errdefer freeTargetInfos(allocator, out.items);
    errdefer out.deinit(allocator);

    for (target_infos.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("targetId") orelse continue;
        const type_value = item.object.get("type") orelse continue;
        if (id_value != .string or type_value != .string) continue;
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id_value.string),
            .kind = try allocator.dupe(u8, type_value.string),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeTargetInfos(allocator: std.mem.Allocator, target_infos: []ParsedTargetInfo) void {
    for (target_infos) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.kind);
    }
    allocator.free(target_infos);
}

pub fn extractResultStringField(allocator: std.mem.Allocator, payload: []const u8, field_name: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const value = result.object.get(field_name) orelse return error.InvalidResponse;
    if (value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, value.string);
}

test "parseTargetInfos parses id and kind pairs" {
    const allocator = std.testing.allocator;
    const target_infos = try parseTargetInfos(allocator,
        \\{"id":1,"result":{"targetInfos":[
        \\  {"targetId":"target-1","type":"page"},
        \\  {"targetId":"target-2","type":"service_worker"}
        \\]}}
    );
    defer freeTargetInfos(allocator, target_infos);

    try std.testing.expectEqual(@as(usize, 2), target_infos.len);
    try std.testing.expectEqualStrings("target-1", target_infos[0].id);
    try std.testing.expectEqualStrings("page", target_infos[0].kind);
}

test "extractResultStringField reads target and session ids" {
    const allocator = std.testing.allocator;

    const target_id = try extractResultStringField(allocator, "{\"id\":9,\"result\":{\"targetId\":\"target-9\"}}", "targetId");
    defer allocator.free(target_id);
    try std.testing.expectEqualStrings("target-9", target_id);

    const session_id = try extractResultStringField(allocator, "{\"id\":4,\"result\":{\"sessionId\":\"sid-123\"}}", "sessionId");
    defer allocator.free(session_id);
    try std.testing.expectEqualStrings("sid-123", session_id);
}
