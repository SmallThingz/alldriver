const std = @import("std");

pub fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

pub fn toAbsolutePath(allocator: std.mem.Allocator, root: []const u8, maybe_rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(maybe_rel)) return allocator.dupe(u8, maybe_rel);
    return try pathJoin(allocator, &.{ root, maybe_rel });
}

test "toAbsolutePath preserves absolute input" {
    const allocator = std.testing.allocator;
    const abs = if (@import("builtin").os.tag == .windows) "C:\\tmp\\x" else "/tmp/x";
    const out = try toAbsolutePath(allocator, "/ignored", abs);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(abs, out);
}

test "toAbsolutePath joins relative input" {
    const allocator = std.testing.allocator;
    const out = try toAbsolutePath(allocator, "/root", "a/b");
    defer allocator.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "root/a/b") or std.mem.endsWith(u8, out, "root\\a\\b"));
}
