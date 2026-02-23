const std = @import("std");
const Session = @import("session.zig").Session;

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    secure: bool = true,
    http_only: bool = true,
};

pub fn setCookie(session: *Session, cookie: Cookie) !void {
    _ = cookie;
    if (!session.capabilities.dom) return error.UnsupportedCapability;
}

pub fn getCookies(session: *Session, allocator: std.mem.Allocator) ![]Cookie {
    _ = session;
    return allocator.alloc(Cookie, 0);
}

pub fn setLocalStorage(session: *Session, key: []const u8, value: []const u8) !void {
    _ = key;
    _ = value;
    if (!session.capabilities.dom) return error.UnsupportedCapability;
}

pub fn clearStorage(session: *Session) !void {
    if (!session.capabilities.dom) return error.UnsupportedCapability;
}
