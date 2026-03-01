const std = @import("std");
const session_mod = @import("session.zig");
const core_storage = @import("../core/storage.zig");
const json_util = @import("../util/json.zig");

pub const Cookie = core_storage.Cookie;
pub const CookieQuery = core_storage.CookieQuery;
pub const CookieHeaderOptions = core_storage.CookieHeaderOptions;

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

    pub fn queryCookies(self: *StorageClient, allocator: std.mem.Allocator, query: CookieQuery) ![]Cookie {
        return core_storage.queryCookies(&self.session.base, allocator, query);
    }

    pub fn buildCookieHeaderForUrl(
        self: *StorageClient,
        allocator: std.mem.Allocator,
        url: []const u8,
        opts: CookieHeaderOptions,
    ) ![]u8 {
        return core_storage.buildCookieHeaderForUrl(&self.session.base, allocator, url, opts);
    }

    pub fn setLocalStorage(self: *StorageClient, key: []const u8, value: []const u8) !void {
        try core_storage.setLocalStorage(&self.session.base, key, value);
    }

    pub fn getLocalStorage(self: *StorageClient, key: []const u8) ![]u8 {
        return evalStorageLookup(self.session, "localStorage", key);
    }

    pub fn setSessionStorage(self: *StorageClient, key: []const u8, value: []const u8) !void {
        const k = try json_util.escapeJsonString(self.session.base.allocator, key);
        defer self.session.base.allocator.free(k);
        const v = try json_util.escapeJsonString(self.session.base.allocator, value);
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
    const escaped = try json_util.escapeJsonString(session.base.allocator, key);
    defer session.base.allocator.free(escaped);
    const script = try std.fmt.allocPrint(
        session.base.allocator,
        "(function(){{const v={s}.getItem(\"{s}\");return v===null?\"\":v;}})();",
        .{ storage_name, escaped },
    );
    defer session.base.allocator.free(script);
    return session.base.evaluate(script);
}
