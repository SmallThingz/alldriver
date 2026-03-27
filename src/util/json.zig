const std = @import("std");
const types = @import("../types.zig");

pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn getBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub fn getI64Field(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

pub fn parseCookieSameSite(raw: ?[]const u8) types.CookieSameSite {
    const value = raw orelse return .unspecified;
    if (std.ascii.eqlIgnoreCase(value, "strict")) return .strict;
    if (std.ascii.eqlIgnoreCase(value, "lax")) return .lax;
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    return .unspecified;
}

test "escapeJsonString escapes control chars and quotes" {
    const allocator = std.testing.allocator;
    const escaped = try escapeJsonString(allocator, "a\"b\\c\n\t");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\n\\t", escaped);
}

test "json field helpers parse scalar values" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"name":"cookie","enabled":true,"expires":123.9,"sameSite":"Strict"}
    , .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("cookie", getStringField(obj, "name").?);
    try std.testing.expectEqual(true, getBoolField(obj, "enabled").?);
    try std.testing.expectEqual(@as(i64, 123), getI64Field(obj, "expires").?);
    try std.testing.expectEqual(types.CookieSameSite.strict, parseCookieSameSite(getStringField(obj, "sameSite")));
}
