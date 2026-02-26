const std = @import("std");
const string_util = @import("../util/strings.zig");

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return string_util.containsIgnoreCase(haystack, needle);
}

pub fn envEnabled(name: []const u8) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    return false;
}
