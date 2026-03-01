const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");
const cdp = @import("cdp/adapter.zig");
const ws = @import("../transport/ws_client.zig");
const http = @import("../transport/http_client.zig");
const json_rpc = @import("../transport/json_rpc.zig");

const Session = @import("../core/session.zig").Session;

pub fn navigate(session: *Session, url: []const u8) !void {
    switch (session.transport) {
        .cdp_ws => {
            const escaped = try escapeJsonString(session.allocator, url);
            defer session.allocator.free(escaped);
            const params = try std.fmt.allocPrint(session.allocator, "{{\"url\":\"{s}\"}}", .{escaped});
            defer session.allocator.free(params);
            const raw = try callCdp(session, "Page.navigate", params);
            defer session.allocator.free(raw);
        },
        .bidi_ws => {
            const context_id = session.browsing_context_id orelse return error.SessionNotReady;
            const url_e = try escapeJsonString(session.allocator, url);
            defer session.allocator.free(url_e);
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"context\":\"{s}\",\"url\":\"{s}\",\"wait\":\"complete\"}}",
                .{ context_id, url_e },
            );
            defer session.allocator.free(params);
            const raw = try callBidi(session, "browsingContext.navigate", params);
            defer session.allocator.free(raw);
        },
    }
}

pub fn reload(session: *Session) !void {
    switch (session.transport) {
        .cdp_ws => {
            const raw = try callCdp(session, "Page.reload", "{}");
            defer session.allocator.free(raw);
        },
        .bidi_ws => {
            const context_id = session.browsing_context_id orelse return error.SessionNotReady;
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"context\":\"{s}\",\"ignoreCache\":false}}",
                .{context_id},
            );
            defer session.allocator.free(params);
            const raw = try callBidi(session, "browsingContext.reload", params);
            defer session.allocator.free(raw);
        },
    }
}

pub fn click(session: *Session, selector: []const u8) !void {
    const sel = try escapeJsonString(session.allocator, selector);
    defer session.allocator.free(sel);
    const expr = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{const el=document.querySelector(\"{s}\"); if(!el) throw new Error('selector not found'); el.click(); return true;}})();",
        .{sel},
    );
    defer session.allocator.free(expr);
    _ = try evaluate(session, expr);
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    const sel = try escapeJsonString(session.allocator, selector);
    defer session.allocator.free(sel);
    const txt = try escapeJsonString(session.allocator, text);
    defer session.allocator.free(txt);
    const expr = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{const el=document.querySelector(\"{s}\"); if(!el) throw new Error('selector not found'); el.focus(); el.value=\"{s}\"; el.dispatchEvent(new Event('input',{{bubbles:true}})); return true;}})();",
        .{ sel, txt },
    );
    defer session.allocator.free(expr);
    _ = try evaluate(session, expr);
}

pub fn evaluate(session: *Session, script: []const u8) ![]u8 {
    return switch (session.transport) {
        .cdp_ws => evalViaCdp(session, script),
        .bidi_ws => evalViaBidi(session, script),
    };
}

pub fn waitForDomReady(session: *Session, timeout_ms: u32) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const res = try evaluate(session, "document.readyState");
        defer session.allocator.free(res);
        if (std.mem.indexOf(u8, res, "complete") != null) return;
        if (std.time.milliTimestamp() >= deadline) return error.Timeout;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

pub fn waitForSelector(session: *Session, selector: []const u8, timeout_ms: u32) !void {
    const escaped = try escapeJsonString(session.allocator, selector);
    defer session.allocator.free(escaped);
    const expr = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{return !!document.querySelector(\"{s}\");}})();",
        .{escaped},
    );
    defer session.allocator.free(expr);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const res = try evaluate(session, expr);
        defer session.allocator.free(res);
        if (std.mem.indexOf(u8, res, "true") != null) return;
        if (std.time.milliTimestamp() >= deadline) return error.Timeout;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

pub fn setCookie(session: *Session, cookie: types.Header, domain: []const u8, path: []const u8) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const n = try escapeJsonString(session.allocator, cookie.name);
    defer session.allocator.free(n);
    const v = try escapeJsonString(session.allocator, cookie.value);
    defer session.allocator.free(v);
    const d = try escapeJsonString(session.allocator, domain);
    defer session.allocator.free(d);
    const p = try escapeJsonString(session.allocator, path);
    defer session.allocator.free(p);

    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"name\":\"{s}\",\"value\":\"{s}\",\"domain\":\"{s}\",\"path\":\"{s}\"}}",
        .{ n, v, d, p },
    );
    defer session.allocator.free(params);
    const raw = try callCdp(session, "Network.setCookie", params);
    defer session.allocator.free(raw);
}

pub fn getCookies(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    return callCdp(session, "Network.getCookies", "{}");
}

pub fn screenshot(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    return callCdp(session, "Page.captureScreenshot", "{}");
}

pub fn startTracing(session: *Session) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const raw = try callCdp(session, "Tracing.start", "{}");
    defer session.allocator.free(raw);
}

pub fn stopTracing(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    return callCdp(session, "Tracing.end", "{}");
}

pub fn releaseHandle(session: *Session, handle_id: []const u8) !void {
    switch (session.transport) {
        .cdp_ws => {
            const handle = try escapeJsonString(session.allocator, handle_id);
            defer session.allocator.free(handle);
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"objectId\":\"{s}\"}}",
                .{handle},
            );
            defer session.allocator.free(params);
            const raw = try callCdp(session, "Runtime.releaseObject", params);
            defer session.allocator.free(raw);
        },
        .bidi_ws => {
            const context_id = session.browsing_context_id orelse return error.SessionNotReady;
            const handle = try escapeJsonString(session.allocator, handle_id);
            defer session.allocator.free(handle);
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"target\":{{\"context\":\"{s}\"}},\"handles\":[\"{s}\"]}}",
                .{ context_id, handle },
            );
            defer session.allocator.free(params);
            const raw = try callBidi(session, "script.disown", params);
            defer session.allocator.free(raw);
        },
    }
}

pub fn enableNetworkInterception(session: *Session) !void {
    switch (session.transport) {
        .cdp_ws => {
            const enable_raw = try callCdp(session, "Network.enable", "{}");
            defer session.allocator.free(enable_raw);
            const fetch_raw = try callCdp(session, "Fetch.enable", "{}");
            defer session.allocator.free(fetch_raw);
        },
        .bidi_ws => {
            const raw = try callBidi(session, "session.subscribe", "{\"events\":[\"network.beforeRequestSent\",\"network.responseCompleted\"]}");
            defer session.allocator.free(raw);
        },
    }
}

pub fn disableNetworkInterception(session: *Session) !void {
    switch (session.transport) {
        .cdp_ws => {
            const fetch_raw = try callCdp(session, "Fetch.disable", "{}");
            defer session.allocator.free(fetch_raw);
            const blocked_raw = try callCdp(session, "Network.setBlockedURLs", "{\"urls\":[]}");
            defer session.allocator.free(blocked_raw);
        },
        .bidi_ws => {
            const raw = callBidi(session, "session.unsubscribe", "{\"events\":[\"network.beforeRequestSent\",\"network.responseCompleted\"]}") catch null;
            if (raw) |payload| session.allocator.free(payload);
        },
    }
}

pub fn addNetworkRule(session: *Session, rule: types.NetworkRule) !void {
    const url_pattern = try escapeJsonString(session.allocator, rule.url_pattern);
    defer session.allocator.free(url_pattern);

    switch (session.transport) {
        .cdp_ws => {
            switch (rule.action) {
                .block => {
                    const params = try std.fmt.allocPrint(
                        session.allocator,
                        "{{\"urls\":[\"{s}\"]}}",
                        .{url_pattern},
                    );
                    defer session.allocator.free(params);
                    const raw = try callCdp(session, "Network.setBlockedURLs", params);
                    defer session.allocator.free(raw);
                },
                .continue_request, .modify, .fulfill => {
                    const params = try std.fmt.allocPrint(
                        session.allocator,
                        "{{\"patterns\":[{{\"urlPattern\":\"{s}\",\"requestStage\":\"Request\"}}]}}",
                        .{url_pattern},
                    );
                    defer session.allocator.free(params);
                    const raw = try callCdp(session, "Fetch.enable", params);
                    defer session.allocator.free(raw);
                },
            }
        },
        .bidi_ws => {
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"phases\":[\"beforeRequestSent\"],\"urlPatterns\":[{{\"type\":\"string\",\"pattern\":\"{s}\"}}]}}",
                .{url_pattern},
            );
            defer session.allocator.free(params);
            const raw = try callBidi(session, "network.addIntercept", params);
            defer session.allocator.free(raw);
        },
    }
}

fn callCdp(session: *Session, method: []const u8, params_json: ?[]const u8) ![]u8 {
    const endpoint = session.endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    if (parsed.adapter != .cdp) return error.UnsupportedProtocol;

    const ws_endpoint = try resolveCdpWebSocketEndpoint(session.allocator, parsed.host, parsed.port);
    defer session.allocator.free(ws_endpoint);
    const ws_parts = try parseWsUrl(session.allocator, ws_endpoint);
    defer session.allocator.free(ws_parts.path);

    var client = try ws.Client.connect(session.allocator, ws_parts.host, ws_parts.port, ws_parts.path);
    defer client.deinit();

    const id = session.nextRequestId();
    const request = try json_rpc.encodeRequest(session.allocator, id, method, params_json);
    defer session.allocator.free(request);
    try client.sendText(request);

    while (true) {
        const payload = try client.recvText(session.allocator);
        errdefer session.allocator.free(payload);
        const env = json_rpc.decodeEnvelope(session.allocator, payload) catch {
            session.allocator.free(payload);
            continue;
        };
        if (env.id == null or env.id.? != id) {
            session.allocator.free(payload);
            continue;
        }
        if (env.has_error) return error.ProtocolCommandFailed;
        return payload;
    }
}

fn callBidi(session: *Session, method: []const u8, params_json: ?[]const u8) ![]u8 {
    const endpoint = session.endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .bidi);
    if (parsed.adapter != .bidi) return error.UnsupportedProtocol;

    var client = try ws.Client.connect(session.allocator, parsed.host, parsed.port, parsed.path);
    defer client.deinit();

    const id = session.nextRequestId();
    const request = try json_rpc.encodeRequest(session.allocator, id, method, params_json);
    defer session.allocator.free(request);
    try client.sendText(request);

    while (true) {
        const payload = try client.recvText(session.allocator);
        errdefer session.allocator.free(payload);
        const env = json_rpc.decodeEnvelope(session.allocator, payload) catch {
            session.allocator.free(payload);
            continue;
        };
        if (env.id == null or env.id.? != id) {
            session.allocator.free(payload);
            continue;
        }
        if (env.has_error) return error.ProtocolCommandFailed;
        return payload;
    }
}

fn resolveCdpWebSocketEndpoint(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    const version = try http.getJson(allocator, host, port, "/json/version");
    defer allocator.free(version.body);
    if (extractJsonStringValue(allocator, version.body, "webSocketDebuggerUrl")) |url| return url else |_| {}

    const list = try http.getJson(allocator, host, port, "/json/list");
    defer allocator.free(list.body);
    return firstJsonListWsEndpoint(allocator, list.body);
}

fn parseWsUrl(allocator: std.mem.Allocator, endpoint: []const u8) !struct { host: []const u8, port: u16, path: []u8 } {
    var input = endpoint;
    if (std.mem.startsWith(u8, input, "ws://")) input = input[5..];
    if (std.mem.startsWith(u8, input, "wss://")) input = input[6..];
    const slash = std.mem.indexOfScalar(u8, input, '/') orelse return error.InvalidEndpoint;
    const host_port = input[0..slash];
    const path = try allocator.dupe(u8, input[slash..]);

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidEndpoint;
    const host = host_port[0..colon];
    const port = try std.fmt.parseInt(u16, host_port[colon + 1 ..], 10);
    return .{ .host = host, .port = port, .path = path };
}

fn firstJsonListWsEndpoint(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponse;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("webSocketDebuggerUrl")) |ws_url| {
            if (ws_url == .string) return allocator.dupe(u8, ws_url.string);
        }
    }
    return error.MissingEndpoint;
}

fn evalViaCdp(session: *Session, script: []const u8) ![]u8 {
    const expression = try escapeJsonString(session.allocator, script);
    defer session.allocator.free(expression);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}",
        .{expression},
    );
    defer session.allocator.free(params);
    return callCdp(session, "Runtime.evaluate", params);
}

fn evalViaBidi(session: *Session, script: []const u8) ![]u8 {
    const context_id = session.browsing_context_id orelse return error.SessionNotReady;
    const expression = try escapeJsonString(session.allocator, script);
    defer session.allocator.free(expression);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"target\":{{\"context\":\"{s}\"}},\"expression\":\"{s}\",\"awaitPromise\":true}}",
        .{ context_id, expression },
    );
    defer session.allocator.free(params);
    return callBidi(session, "script.evaluate", params);
}

fn extractJsonStringValue(allocator: std.mem.Allocator, payload: []const u8, field_name: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const value = parsed.value.object.get(field_name) orelse return error.MissingEndpoint;
    if (value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, value.string);
}

fn escapeJsonString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (raw) |c| {
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

test "escape json string" {
    const allocator = std.testing.allocator;
    const escaped = try escapeJsonString(allocator, "a\"b\\c\n");
    defer allocator.free(escaped);
    try std.testing.expect(std.mem.eql(u8, escaped, "a\\\"b\\\\c\\n"));
}

test "parseWsUrl supports ws endpoint" {
    const allocator = std.testing.allocator;
    const parsed = try parseWsUrl(allocator, "ws://127.0.0.1:9222/devtools/browser/abc");
    defer allocator.free(parsed.path);
    try std.testing.expectEqual(@as(u16, 9222), parsed.port);
    try std.testing.expect(std.mem.eql(u8, parsed.host, "127.0.0.1"));
}
