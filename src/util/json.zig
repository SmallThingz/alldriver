const std = @import("std");

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

test "escapeJsonString escapes control chars and quotes" {
    const allocator = std.testing.allocator;
    const escaped = try escapeJsonString(allocator, "a\"b\\c\n\t");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\n\\t", escaped);
}
