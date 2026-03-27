const std = @import("std");
const compat = @import("../util/compat.zig");
const driver = @import("../root.zig");

pub fn envEnabled(name: []const u8) bool {
    const value = compat.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    return false;
}

pub fn findCookieValue(cookies: []const driver.Cookie, name: []const u8) ?[]const u8 {
    for (cookies) |cookie| {
        if (std.mem.eql(u8, cookie.name, name)) return cookie.value;
    }
    return null;
}
