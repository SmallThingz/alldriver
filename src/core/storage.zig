const std = @import("std");
const Session = @import("session.zig").Session;
const executor = @import("../protocol/executor.zig");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    secure: bool = true,
    http_only: bool = true,
};

pub fn setCookie(session: *Session, cookie: Cookie) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    try executor.setCookie(session, .{ .name = cookie.name, .value = cookie.value }, cookie.domain, cookie.path);
}

pub fn getCookies(session: *Session, allocator: std.mem.Allocator) ![]Cookie {
    if (!session.supports(.dom)) return error.UnsupportedCapability;

    const raw = try executor.getCookies(session);
    defer session.allocator.free(raw);

    return parseCookiesFromPayload(allocator, raw);
}

pub fn freeCookies(allocator: std.mem.Allocator, cookies: []Cookie) void {
    for (cookies) |cookie| {
        allocator.free(cookie.name);
        allocator.free(cookie.value);
        allocator.free(cookie.domain);
        allocator.free(cookie.path);
    }
    allocator.free(cookies);
}

pub fn setLocalStorage(session: *Session, key: []const u8, value: []const u8) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;

    const k = try escapeJsonString(session.allocator, key);
    defer session.allocator.free(k);
    const v = try escapeJsonString(session.allocator, value);
    defer session.allocator.free(v);

    const script = try std.fmt.allocPrint(
        session.allocator,
        "(function(){localStorage.setItem(\"{s}\",\"{s}\"); return true;})();",
        .{ k, v },
    );
    defer session.allocator.free(script);

    const result = try executor.evaluate(session, script);
    defer session.allocator.free(result);
}

pub fn clearStorage(session: *Session) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;

    const result = try executor.evaluate(
        session,
        "(function(){localStorage.clear(); sessionStorage.clear(); return true;})();",
    );
    defer session.allocator.free(result);
}

fn parseCookiesFromPayload(allocator: std.mem.Allocator, payload: []const u8) ![]Cookie {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return allocator.alloc(Cookie, 0);

    var cookies_value: ?std.json.Value = null;

    if (root.object.get("result")) |result| {
        if (result == .object) {
            cookies_value = result.object.get("cookies");
        }
    }

    if (cookies_value == null) {
        cookies_value = root.object.get("value");
    }

    if (cookies_value == null or cookies_value.? != .array) {
        return allocator.alloc(Cookie, 0);
    }

    var out: std.ArrayList(Cookie) = .empty;
    errdefer {
        for (out.items) |cookie| {
            allocator.free(cookie.name);
            allocator.free(cookie.value);
            allocator.free(cookie.domain);
            allocator.free(cookie.path);
        }
        out.deinit(allocator);
    }

    for (cookies_value.?.array.items) |item| {
        if (item != .object) continue;

        const name = getStringField(item.object, "name") orelse continue;
        const value = getStringField(item.object, "value") orelse "";
        const domain = getStringField(item.object, "domain") orelse "";
        const path = getStringField(item.object, "path") orelse "/";
        const secure = getBoolField(item.object, "secure") orelse true;
        const http_only = getBoolField(item.object, "httpOnly") orelse true;

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
            .domain = try allocator.dupe(u8, domain),
            .path = try allocator.dupe(u8, path),
            .secure = secure,
            .http_only = http_only,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
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

test "parse cookies from cdp payload" {
    const allocator = std.testing.allocator;
    const cookies = try parseCookiesFromPayload(
        allocator,
        "{\"result\":{\"cookies\":[{\"name\":\"sid\",\"value\":\"abc\",\"domain\":\"example.com\",\"path\":\"/\",\"secure\":true,\"httpOnly\":false}]}}",
    );
    defer freeCookies(allocator, cookies);

    try std.testing.expectEqual(@as(usize, 1), cookies.len);
    try std.testing.expect(std.mem.eql(u8, cookies[0].name, "sid"));
    try std.testing.expect(std.mem.eql(u8, cookies[0].value, "abc"));
    try std.testing.expect(std.mem.eql(u8, cookies[0].domain, "example.com"));
    try std.testing.expect(cookies[0].secure);
    try std.testing.expect(!cookies[0].http_only);
}
