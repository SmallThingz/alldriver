const std = @import("std");

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "containsIgnoreCase matches case-insensitively" {
    try std.testing.expect(containsIgnoreCase("HelloWorld", "world"));
    try std.testing.expect(containsIgnoreCase("ABC", "abc"));
    try std.testing.expect(!containsIgnoreCase("ABC", "abd"));
}
