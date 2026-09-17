const std = @import("std");
const driver = @import("../root.zig");
const compat = @import("../util/compat.zig");
const Browser = @import("chromium_behavior.zig").Browser;
const LocalServer = @import("chromium_network.zig").LocalServer;
const allocator = std.testing.allocator;

comptime {
    _ = @import("../core/storage.zig");
}

test "Chromium cookies preserve options scope expiry and rejection and storage preserves exact values" {
    const server = try LocalServer.start();
    defer server.deinit();
    var browser = try Browser.launch();
    defer browser.deinit();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server.listener.socket.address.getPort()});
    defer allocator.free(url);
    var page = browser.session.page();
    try page.navigate(url);
    var storage = browser.session.storage();
    const expires = compat.timestamp() + 3600;
    const cookies = [_]driver.Cookie{
        .{ .name = "private_sid", .value = "secret", .domain = "127.0.0.1", .path = "/", .secure = false, .http_only = true, .same_site = .lax, .expires_unix_seconds = expires },
        .{ .name = "path_sid", .value = "scoped", .domain = "127.0.0.1", .path = "/private", .secure = false, .http_only = false, .same_site = .strict, .expires_unix_seconds = expires },
        .{ .name = "remote_sid", .value = "remote", .domain = ".example.test", .path = "/", .secure = true, .http_only = true, .same_site = .none, .expires_unix_seconds = expires },
    };
    for (cookies) |cookie| try storage.setCookie(cookie);
    const actual = try storage.getCookies(allocator);
    defer storage.freeCookies(allocator, actual);
    for (cookies) |expected| {
        var found = false;
        for (actual) |cookie| {
            if (!std.mem.eql(u8, cookie.name, expected.name)) continue;
            try std.testing.expectEqualDeep(expected, cookie);
            found = true;
        }
        try std.testing.expect(found);
    }
    try browser.evaluateTrue("!document.cookie.includes('private_sid') && !document.cookie.includes('path_sid')");
    const private_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/private?query=1", .{server.listener.socket.address.getPort()});
    defer allocator.free(private_url);
    const header = try storage.buildCookieHeaderForUrl(allocator, private_url, .{});
    defer allocator.free(header);
    try std.testing.expectEqualStrings("path_sid=scoped; private_sid=secret", header);
    const script_header = try storage.buildCookieHeaderForUrl(allocator, private_url, .{ .include_http_only = false });
    defer allocator.free(script_header);
    try std.testing.expectEqualStrings("path_sid=scoped", script_header);
    const root_header = try storage.buildCookieHeaderForUrl(allocator, url, .{});
    defer allocator.free(root_header);
    try std.testing.expectEqualStrings("private_sid=secret", root_header);
    const remote_header = try storage.buildCookieHeaderForUrl(allocator, "https://sub.example.test/", .{});
    defer allocator.free(remote_header);
    try std.testing.expectEqualStrings("remote_sid=remote", remote_header);
    const insecure_remote = try storage.buildCookieHeaderForUrl(allocator, "http://sub.example.test/", .{});
    defer allocator.free(insecure_remote);
    try std.testing.expectEqualStrings("", insecure_remote);
    const remote_query = try storage.queryCookies(allocator, .{ .domain = "sub.example.test", .secure_only = true });
    defer storage.freeCookies(allocator, remote_query);
    try std.testing.expectEqual(@as(usize, 1), remote_query.len);
    try std.testing.expectEqualStrings("remote_sid", remote_query[0].name);

    try page.navigate(private_url);
    try browser.evaluateTrue("document.cookie==='path_sid=scoped'");
    var expired = cookies[0];
    expired.expires_unix_seconds = 1;
    try storage.setCookie(expired);
    const deleted = try storage.queryCookies(allocator, .{ .name = "private_sid" });
    defer storage.freeCookies(allocator, deleted);
    try std.testing.expectEqual(@as(usize, 0), deleted.len);
    try std.testing.expectError(error.ProtocolCommandFailed, storage.setCookie(.{
        .name = "bad;name",
        .value = "must-not-exist",
        .domain = "127.0.0.1",
        .secure = false,
        .http_only = false,
    }));
    try browser.evaluateTrue("!document.cookie.includes('must-not-exist')");

    try storage.setLocalStorage("quoted'key", "λ\n\"value\"");
    try storage.setSessionStorage("tab", "🙂\nvalue");
    try browser.evaluateTrue("localStorage.getItem(\"quoted'key\")==='λ\\n\"value\"' && sessionStorage.getItem('tab')==='🙂\\nvalue'");
    const local = try storage.getLocalStorage("quoted'key");
    defer allocator.free(local);
    try expectRemoteString(local, "λ\n\"value\"");
    const tab = try storage.getSessionStorage("tab");
    defer allocator.free(tab);
    try expectRemoteString(tab, "🙂\nvalue");
    try page.reload();
    try browser.evaluateTrue("localStorage.getItem(\"quoted'key\")==='λ\\n\"value\"' && sessionStorage.getItem('tab')==='🙂\\nvalue'");
    try storage.clear();
    try browser.evaluateTrue("localStorage.length===0 && sessionStorage.length===0");
}

fn expectRemoteString(payload: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("result").?.object.get("result").?.object.get("value").?;
    try std.testing.expectEqualStrings(expected, value.string);
}
