const std = @import("std");
const Session = @import("session.zig").Session;
const types = @import("../types.zig");
const events = @import("events.zig");
const executor = @import("../protocol/executor.zig");

pub const Cookie = types.Cookie;
pub const CookieQuery = types.CookieQuery;
pub const CookieHeaderOptions = types.CookieHeaderOptions;

pub fn setCookie(session: *Session, cookie: Cookie) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    executor.setCookie(session, .{ .name = cookie.name, .value = cookie.value }, cookie.domain, cookie.path) catch |err| switch (err) {
        error.ProtocolCommandFailed => try setCookieViaDocument(session, cookie),
        else => return err,
    };
    events.emit(session, .{
        .cookie_updated = .{
            .domain = cookie.domain,
            .name = cookie.name,
        },
    });
}

fn setCookieViaDocument(session: *Session, cookie: Cookie) !void {
    const name = try escapeJsonString(session.allocator, cookie.name);
    defer session.allocator.free(name);
    const value = try escapeJsonString(session.allocator, cookie.value);
    defer session.allocator.free(value);
    const path = try escapeJsonString(session.allocator, cookie.path);
    defer session.allocator.free(path);

    const script = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{document.cookie=\"{s}={s}; path={s}\"; return true;}})();",
        .{ name, value, path },
    );
    defer session.allocator.free(script);
    const result = try executor.evaluate(session, script);
    defer session.allocator.free(result);
}

pub fn getCookies(session: *Session, allocator: std.mem.Allocator) ![]Cookie {
    if (!session.supports(.dom)) return error.UnsupportedCapability;

    const raw = try executor.getCookies(session);
    defer session.allocator.free(raw);

    return parseCookiesFromPayload(allocator, raw);
}

pub fn freeCookies(allocator: std.mem.Allocator, cookies: []Cookie) void {
    for (cookies) |cookie| {
        freeCookieFields(allocator, cookie);
    }
    allocator.free(cookies);
}

pub fn queryCookies(session: *Session, allocator: std.mem.Allocator, q: CookieQuery) ![]Cookie {
    const all = try getCookies(session, allocator);
    errdefer freeCookies(allocator, all);
    session.state_lock.lock();
    const current_url = if (session.current_url) |url|
        allocator.dupe(u8, url) catch null
    else
        null;
    session.state_lock.unlock();
    defer if (current_url) |url| allocator.free(url);

    const current_host = if (current_url) |url|
        (parseUrl(url) orelse ParsedUrl{ .secure = false, .host = "", .path = "/" }).host
    else
        "";

    var matched_count: usize = 0;
    for (all) |cookie| {
        if (matchesQueryForSession(cookie, q, current_host)) matched_count += 1;
    }

    if (matched_count == all.len) return all;

    const out = try allocator.alloc(Cookie, matched_count);
    var out_index: usize = 0;
    for (all) |cookie| {
        if (matchesQueryForSession(cookie, q, current_host)) {
            out[out_index] = cookie;
            out_index += 1;
        } else {
            freeCookieFields(allocator, cookie);
        }
    }
    allocator.free(all);
    return out;
}

pub fn buildCookieHeaderForUrl(
    session: *Session,
    allocator: std.mem.Allocator,
    url: []const u8,
    opts: CookieHeaderOptions,
) ![]u8 {
    const parsed = parseUrl(url) orelse return error.InvalidEndpoint;
    const cookies = try getCookies(session, allocator);
    defer freeCookies(allocator, cookies);

    var matching_indexes: std.ArrayList(usize) = .empty;
    defer matching_indexes.deinit(allocator);

    for (cookies, 0..) |cookie, idx| {
        if (!opts.include_http_only and cookie.http_only) continue;
        if (!domainMatches(cookie.domain, parsed.host)) continue;
        if (!pathMatches(cookie.path, parsed.path)) continue;
        if (cookie.secure and !parsed.secure) continue;
        if (isExpired(cookie)) continue;
        try matching_indexes.append(allocator, idx);
    }

    if (opts.sort_by_path_len_desc) {
        std.mem.sort(usize, matching_indexes.items, cookies, struct {
            fn lessThan(pool: []const Cookie, lhs: usize, rhs: usize) bool {
                const a = pool[lhs];
                const b = pool[rhs];
                if (a.path.len == b.path.len) return std.mem.lessThan(u8, a.name, b.name);
                return a.path.len > b.path.len;
            }
        }.lessThan);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (matching_indexes.items, 0..) |cookie_index, idx| {
        const cookie = cookies[cookie_index];
        if (idx != 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, cookie.name);
        try out.append(allocator, '=');
        try out.appendSlice(allocator, cookie.value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn setLocalStorage(session: *Session, key: []const u8, value: []const u8) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;

    const k = try escapeJsonString(session.allocator, key);
    defer session.allocator.free(k);
    const v = try escapeJsonString(session.allocator, value);
    defer session.allocator.free(v);

    const script = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{localStorage.setItem(\"{s}\",\"{s}\"); return true;}})();",
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
        const expires_unix_seconds = getI64Field(item.object, "expires");
        const same_site = parseSameSite(getStringField(item.object, "sameSite"));

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
            .domain = try allocator.dupe(u8, domain),
            .path = try allocator.dupe(u8, path),
            .secure = secure,
            .http_only = http_only,
            .expires_unix_seconds = expires_unix_seconds,
            .same_site = same_site,
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

fn getI64Field(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

fn parseSameSite(raw: ?[]const u8) types.CookieSameSite {
    const value = raw orelse return .unspecified;
    if (std.ascii.eqlIgnoreCase(value, "strict")) return .strict;
    if (std.ascii.eqlIgnoreCase(value, "lax")) return .lax;
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    return .unspecified;
}

fn freeCookieFields(allocator: std.mem.Allocator, cookie: Cookie) void {
    allocator.free(cookie.name);
    allocator.free(cookie.value);
    allocator.free(cookie.domain);
    allocator.free(cookie.path);
}

fn isExpired(cookie: Cookie) bool {
    const expiry = cookie.expires_unix_seconds orelse return false;
    if (expiry < 0) return false;
    return std.time.timestamp() >= expiry;
}

fn matchesQuery(cookie: Cookie, q: CookieQuery) bool {
    if (q.name) |name| {
        if (!std.mem.eql(u8, cookie.name, name)) return false;
    }
    if (q.domain) |domain| {
        if (!domainMatches(cookie.domain, domain)) return false;
    }
    if (q.path) |path| {
        if (!pathMatches(cookie.path, path)) return false;
    }
    if (q.secure_only and !cookie.secure) return false;
    if (!q.include_http_only and cookie.http_only) return false;
    if (!q.include_expired and isExpired(cookie)) return false;
    return true;
}

fn matchesQueryForSession(cookie: Cookie, q: CookieQuery, current_host: []const u8) bool {
    if (q.domain) |domain| {
        if (cookie.domain.len == 0) {
            if (current_host.len == 0 or !domainMatches(domain, current_host)) return false;
        } else if (!domainMatches(cookie.domain, domain)) {
            return false;
        }
    }
    if (q.path) |path| {
        if (!pathMatches(cookie.path, path)) return false;
    }
    if (q.name) |name| {
        if (!std.mem.eql(u8, cookie.name, name)) return false;
    }
    if (q.secure_only and !cookie.secure) return false;
    if (!q.include_http_only and cookie.http_only) return false;
    if (!q.include_expired and isExpired(cookie)) return false;
    return true;
}

const ParsedUrl = struct {
    secure: bool,
    host: []const u8,
    path: []const u8,
};

fn parseUrl(url: []const u8) ?ParsedUrl {
    const scheme_idx = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_idx];
    const secure = std.ascii.eqlIgnoreCase(scheme, "https");
    const rest = url[scheme_idx + 3 ..];
    if (rest.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    if (host_port.len == 0) return null;
    const host = normalizeDomainToken(host_port);
    if (host.len == 0) return null;
    const path = if (slash < rest.len) rest[slash..] else "/";
    return .{ .secure = secure, .host = host, .path = path };
}

fn domainMatches(cookie_domain_raw: []const u8, host: []const u8) bool {
    if (cookie_domain_raw.len == 0 or host.len == 0) return false;
    const cookie_domain = normalizeDomainToken(cookie_domain_raw);
    const host_domain = normalizeDomainToken(host);
    if (cookie_domain.len == 0 or host_domain.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(cookie_domain, host_domain)) return true;
    if (host_domain.len <= cookie_domain.len) return false;
    if (!std.ascii.eqlIgnoreCase(host_domain[host_domain.len - cookie_domain.len ..], cookie_domain)) return false;
    return host_domain[host_domain.len - cookie_domain.len - 1] == '.';
}

fn normalizeDomainToken(raw: []const u8) []const u8 {
    if (raw.len == 0) return raw;
    var token = raw;
    if (std.mem.indexOf(u8, token, "://")) |scheme_sep| {
        token = token[scheme_sep + 3 ..];
    }
    if (std.mem.indexOfAny(u8, token, "/?#")) |cut| {
        token = token[0..cut];
    }
    if (token.len == 0) return token;

    while (token.len > 0 and token[0] == '.') {
        token = token[1..];
    }
    while (token.len > 0 and token[token.len - 1] == '.') {
        token = token[0 .. token.len - 1];
    }
    if (token.len == 0) return token;

    if (token[0] == '[') {
        if (std.mem.indexOfScalar(u8, token, ']')) |close_idx| {
            if (close_idx <= 1) return "";
            return token[1..close_idx];
        }
    }

    const first_colon = std.mem.indexOfScalar(u8, token, ':');
    const last_colon = std.mem.lastIndexOfScalar(u8, token, ':');
    if (first_colon) |idx| {
        if (last_colon != null and idx == last_colon.?) {
            token = token[0..idx];
        }
    }
    return token;
}

fn pathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (cookie_path.len == 0 or std.mem.eql(u8, cookie_path, "/")) return true;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (request_path.len == cookie_path.len) return true;
    if (cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path[cookie_path.len] == '/';
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

test "cookie domain/path matching helpers" {
    try std.testing.expect(domainMatches("example.com", "example.com"));
    try std.testing.expect(domainMatches(".example.com", "www.example.com"));
    try std.testing.expect(!domainMatches("example.com", "evil-example.com"));
    try std.testing.expect(domainMatches("127.0.0.1", "127.0.0.1:45123"));
    try std.testing.expect(domainMatches("127.0.0.1:45123", "127.0.0.1"));
    try std.testing.expect(domainMatches("http://127.0.0.1:45123/", "127.0.0.1"));

    try std.testing.expect(pathMatches("/", "/app/page"));
    try std.testing.expect(pathMatches("/app", "/app/page"));
    try std.testing.expect(pathMatches("/app/", "/app/page"));
    try std.testing.expect(!pathMatches("/app", "/api/page"));
}

test "cookie query filters secure and expired" {
    const now = std.time.timestamp();
    const active: Cookie = .{
        .name = "sid",
        .value = "ok",
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .expires_unix_seconds = now + 3600,
    };
    const expired: Cookie = .{
        .name = "sid",
        .value = "old",
        .domain = "example.com",
        .path = "/",
        .secure = false,
        .expires_unix_seconds = now - 60,
    };

    try std.testing.expect(matchesQuery(active, .{
        .name = "sid",
        .domain = "example.com",
        .secure_only = true,
    }));
    try std.testing.expect(!matchesQuery(expired, .{
        .name = "sid",
        .domain = "example.com",
        .secure_only = true,
    }));
    try std.testing.expect(!matchesQuery(expired, .{
        .name = "sid",
        .domain = "example.com",
        .include_expired = false,
    }));
    try std.testing.expect(matchesQuery(expired, .{
        .name = "sid",
        .domain = "example.com",
        .include_expired = true,
    }));

    const session_cookie: Cookie = .{
        .name = "sid",
        .value = "session",
        .domain = "example.com",
        .path = "/",
        .secure = false,
        .expires_unix_seconds = -1,
    };
    try std.testing.expect(matchesQuery(session_cookie, .{
        .name = "sid",
        .domain = "example.com",
        .include_expired = false,
    }));
}
