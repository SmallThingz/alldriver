const std = @import("std");
const session_mod = @import("session.zig");
const core_storage = @import("../core/storage.zig");

pub const Cookie = core_storage.Cookie;

pub const StorageClient = struct {
    session: *session_mod.ModernSession,

    pub fn setCookie(self: *StorageClient, cookie: Cookie) !void {
        try core_storage.setCookie(&self.session.base, cookie);
    }

    pub fn getCookies(self: *StorageClient, allocator: std.mem.Allocator) ![]Cookie {
        return core_storage.getCookies(&self.session.base, allocator);
    }

    pub fn freeCookies(self: *StorageClient, allocator: std.mem.Allocator, cookies: []Cookie) void {
        _ = self;
        core_storage.freeCookies(allocator, cookies);
    }

    pub fn setLocalStorage(self: *StorageClient, key: []const u8, value: []const u8) !void {
        try core_storage.setLocalStorage(&self.session.base, key, value);
    }

    pub fn getLocalStorage(self: *StorageClient, key: []const u8) ![]u8 {
        return evalStorageLookup(self.session, "localStorage", key);
    }

    pub fn setSessionStorage(self: *StorageClient, key: []const u8, value: []const u8) !void {
        const k = try escapeJsonString(self.session.base.allocator, key);
        defer self.session.base.allocator.free(k);
        const v = try escapeJsonString(self.session.base.allocator, value);
        defer self.session.base.allocator.free(v);
        const script = try std.fmt.allocPrint(
            self.session.base.allocator,
            "(function(){{sessionStorage.setItem(\"{s}\",\"{s}\"); return true;}})();",
            .{ k, v },
        );
        defer self.session.base.allocator.free(script);
        const payload = try self.session.base.evaluate(script);
        self.session.base.allocator.free(payload);
    }

    pub fn getSessionStorage(self: *StorageClient, key: []const u8) ![]u8 {
        return evalStorageLookup(self.session, "sessionStorage", key);
    }

    pub fn clear(self: *StorageClient) !void {
        try core_storage.clearStorage(&self.session.base);
    }
};

fn evalStorageLookup(session: *session_mod.ModernSession, storage_name: []const u8, key: []const u8) ![]u8 {
    const escaped = try escapeJsonString(session.base.allocator, key);
    defer session.base.allocator.free(escaped);
    const script = try std.fmt.allocPrint(
        session.base.allocator,
        "(function(){{const v={s}.getItem(\"{s}\");return v===null?\"\":v;}})();",
        .{ storage_name, escaped },
    );
    defer session.base.allocator.free(script);
    return session.base.evaluate(script);
}

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
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
