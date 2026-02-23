const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");
const cdp = @import("cdp/adapter.zig");
const ws = @import("../transport/ws_client.zig");
const http = @import("../transport/http_client.zig");
const json_rpc = @import("../transport/json_rpc.zig");

const Session = @import("../core/session.zig").Session;
const cdp_target_poll_timeout_ms: i64 = 8_000;
const cdp_target_poll_sleep_ms: u64 = 100;
const startup_connect_retry_timeout_ms: i64 = 8_000;
const startup_connect_retry_sleep_ms: u64 = 100;

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
        .webdriver_http => {
            const escaped = try escapeJsonString(session.allocator, url);
            defer session.allocator.free(escaped);
            const body = try std.fmt.allocPrint(session.allocator, "{{\"url\":\"{s}\"}}", .{escaped});
            defer session.allocator.free(body);
            const raw = try callWebDriver(session, .POST, "/url", body);
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
        .webdriver_http => {
            const raw = try callWebDriver(session, .POST, "/refresh", "{}");
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
    switch (session.transport) {
        .cdp_ws => {
            const sel = try escapeJsonString(session.allocator, selector);
            defer session.allocator.free(sel);
            const expr = try std.fmt.allocPrint(
                session.allocator,
                "(function(){{const el=document.querySelector(\"{s}\"); if(!el) throw new Error('selector not found'); el.click(); return true;}})();",
                .{sel},
            );
            defer session.allocator.free(expr);
            _ = try evalViaCdp(session, expr);
        },
        .webdriver_http => {
            const element_id = try findWebDriverElement(session, selector);
            defer session.allocator.free(element_id);
            const suffix = try std.fmt.allocPrint(session.allocator, "/element/{s}/click", .{element_id});
            defer session.allocator.free(suffix);
            const raw = try callWebDriver(session, .POST, suffix, "{}");
            defer session.allocator.free(raw);
        },
        .bidi_ws => {
            const sel = try escapeJsonString(session.allocator, selector);
            defer session.allocator.free(sel);
            const expr = try std.fmt.allocPrint(
                session.allocator,
                "(function(){{const el=document.querySelector(\"{s}\"); if(!el) return false; el.click(); return true;}})();",
                .{sel},
            );
            defer session.allocator.free(expr);
            _ = try evalViaBidi(session, expr);
        },
    }
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    switch (session.transport) {
        .cdp_ws => {
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
            _ = try evalViaCdp(session, expr);
        },
        .webdriver_http => {
            const element_id = try findWebDriverElement(session, selector);
            defer session.allocator.free(element_id);
            const txt = try escapeJsonString(session.allocator, text);
            defer session.allocator.free(txt);
            const suffix = try std.fmt.allocPrint(session.allocator, "/element/{s}/value", .{element_id});
            defer session.allocator.free(suffix);
            const body = try std.fmt.allocPrint(session.allocator, "{{\"text\":\"{s}\"}}", .{txt});
            defer session.allocator.free(body);
            const raw = try callWebDriver(session, .POST, suffix, body);
            defer session.allocator.free(raw);
        },
        .bidi_ws => {
            const sel = try escapeJsonString(session.allocator, selector);
            defer session.allocator.free(sel);
            const txt = try escapeJsonString(session.allocator, text);
            defer session.allocator.free(txt);
            const expr = try std.fmt.allocPrint(
                session.allocator,
                "(function(){{const el=document.querySelector(\"{s}\"); if(!el) return false; el.focus(); el.value=\"{s}\"; el.dispatchEvent(new Event('input',{{bubbles:true}})); return true;}})();",
                .{ sel, txt },
            );
            defer session.allocator.free(expr);
            _ = try evalViaBidi(session, expr);
        },
    }
}

pub fn evaluate(session: *Session, script: []const u8) ![]u8 {
    return switch (session.transport) {
        .cdp_ws => evalViaCdp(session, script),
        .webdriver_http => evalViaWebDriver(session, script),
        .bidi_ws => evalViaBidi(session, script),
    };
}

pub fn waitForDomReady(session: *Session, timeout_ms: u32) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (true) {
        const res = evaluate(session, "document.readyState") catch {
            if (std.time.milliTimestamp() >= deadline) return error.Timeout;
            std.Thread.sleep(25 * std.time.ns_per_ms);
            continue;
        };
        defer session.allocator.free(res);

        if (std.mem.indexOf(u8, res, "complete") != null or std.mem.indexOf(u8, res, "interactive") != null) {
            return;
        }

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
    switch (session.transport) {
        .cdp_ws => {
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
        },
        .webdriver_http => {
            const n = try escapeJsonString(session.allocator, cookie.name);
            defer session.allocator.free(n);
            const v = try escapeJsonString(session.allocator, cookie.value);
            defer session.allocator.free(v);
            const d = try escapeJsonString(session.allocator, domain);
            defer session.allocator.free(d);
            const p = try escapeJsonString(session.allocator, path);
            defer session.allocator.free(p);
            const body = try std.fmt.allocPrint(
                session.allocator,
                "{{\"cookie\":{{\"name\":\"{s}\",\"value\":\"{s}\",\"domain\":\"{s}\",\"path\":\"{s}\"}}}}",
                .{ n, v, d, p },
            );
            defer session.allocator.free(body);
            const raw = try callWebDriver(session, .POST, "/cookie", body);
            defer session.allocator.free(raw);
        },
        .bidi_ws => return error.UnsupportedProtocol,
    }
}

pub fn getCookies(session: *Session) ![]u8 {
    return switch (session.transport) {
        .cdp_ws => callCdp(session, "Network.getCookies", "{}"),
        .webdriver_http => callWebDriver(session, .GET, "/cookie", null),
        .bidi_ws => error.UnsupportedProtocol,
    };
}

pub fn screenshot(session: *Session) ![]u8 {
    return switch (session.transport) {
        .cdp_ws => callCdp(session, "Page.captureScreenshot", "{}"),
        .webdriver_http => callWebDriver(session, .GET, "/screenshot", null),
        .bidi_ws => error.UnsupportedProtocol,
    };
}

pub fn startTracing(session: *Session) !void {
    switch (session.transport) {
        .cdp_ws => {
            const raw = try callCdp(session, "Tracing.start", "{}");
            defer session.allocator.free(raw);
        },
        else => return error.UnsupportedProtocol,
    }
}

pub fn stopTracing(session: *Session) ![]u8 {
    return switch (session.transport) {
        .cdp_ws => callCdp(session, "Tracing.end", "{}"),
        else => error.UnsupportedProtocol,
    };
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
        .webdriver_http => return error.UnsupportedProtocol,
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
        .webdriver_http => return error.UnsupportedProtocol,
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
        .webdriver_http => return error.UnsupportedProtocol,
    }
}

const RetryClock = struct {
    ctx: *anyopaque,
    now_ms_fn: *const fn (ctx: *anyopaque) i64,
    sleep_ms_fn: *const fn (ctx: *anyopaque, interval_ms: u64) void,

    fn nowMs(self: RetryClock) i64 {
        return self.now_ms_fn(self.ctx);
    }

    fn sleepMs(self: RetryClock, interval_ms: u64) void {
        self.sleep_ms_fn(self.ctx, interval_ms);
    }
};

const WsConnectCtx = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
};

const WebDriverRequestCtx = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: http.HttpMethod,
    path: []const u8,
    body_json: ?[]const u8,
};

var system_retry_clock_dummy: u8 = 0;

fn systemRetryClock() RetryClock {
    return .{
        .ctx = &system_retry_clock_dummy,
        .now_ms_fn = systemNowMs,
        .sleep_ms_fn = systemSleepMs,
    };
}

fn systemNowMs(_: *anyopaque) i64 {
    return std.time.milliTimestamp();
}

fn systemSleepMs(_: *anyopaque, interval_ms: u64) void {
    std.Thread.sleep(interval_ms * std.time.ns_per_ms);
}

fn connectWsAttempt(ctx: *const anyopaque) anyerror!ws.Client {
    const connect_ctx: *const WsConnectCtx = @ptrCast(@alignCast(ctx));
    return ws.Client.connect(connect_ctx.allocator, connect_ctx.host, connect_ctx.port, connect_ctx.path);
}

fn requestWebDriverAttempt(ctx: *const anyopaque) anyerror!http.Response {
    const request_ctx: *const WebDriverRequestCtx = @ptrCast(@alignCast(ctx));
    return http.requestJson(
        request_ctx.allocator,
        request_ctx.host,
        request_ctx.port,
        request_ctx.method,
        request_ctx.path,
        request_ctx.body_json,
    );
}

fn retryTransientConnect(
    comptime T: type,
    attempt_ctx: *const anyopaque,
    attempt_fn: *const fn (ctx: *const anyopaque) anyerror!T,
    timeout_ms: i64,
    interval_ms: u64,
    clock: RetryClock,
) !T {
    const deadline_ms = clock.nowMs() + timeout_ms;

    while (true) {
        return attempt_fn(attempt_ctx) catch |err| {
            if (!shouldRetryTransientConnect(err, clock.nowMs(), deadline_ms)) return err;
            clock.sleepMs(interval_ms);
            continue;
        };
    }
}

fn shouldRetryTransientConnect(err: anyerror, now_ms: i64, deadline_ms: i64) bool {
    return isTransientStartupConnectError(err) and now_ms < deadline_ms;
}

fn isTransientStartupConnectError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        => true,
        else => false,
    };
}

fn callCdp(session: *Session, method: []const u8, params_json: []const u8) ![]u8 {
    const endpoint = session.endpoint orelse return error.SessionNotReady;
    const parsed = try common.parseEndpoint(endpoint, .cdp);

    var actual_path = parsed.path;
    var maybe_owned_path: ?[]u8 = null;
    defer if (maybe_owned_path) |p| session.allocator.free(p);

    if (std.mem.eql(u8, actual_path, "/")) {
        maybe_owned_path = try resolveCdpPagePath(session.allocator, parsed.host, parsed.port);
        actual_path = maybe_owned_path.?;
    }

    const connect_ctx = WsConnectCtx{
        .allocator = session.allocator,
        .host = parsed.host,
        .port = parsed.port,
        .path = actual_path,
    };
    var client = try retryTransientConnect(
        ws.Client,
        &connect_ctx,
        connectWsAttempt,
        startup_connect_retry_timeout_ms,
        startup_connect_retry_sleep_ms,
        systemRetryClock(),
    );
    defer client.deinit();

    const request_id = session.nextRequestId();
    const req = try cdp.serializeCommand(session.allocator, request_id, method, params_json);
    defer session.allocator.free(req);

    try client.sendText(req);
    return recvRpcResponse(session, &client, request_id);
}

fn callBidi(session: *Session, method: []const u8, params_json: []const u8) ![]u8 {
    const endpoint = session.endpoint orelse return error.SessionNotReady;
    const parsed = try common.parseEndpoint(endpoint, .bidi);

    const connect_ctx = WsConnectCtx{
        .allocator = session.allocator,
        .host = parsed.host,
        .port = parsed.port,
        .path = parsed.path,
    };
    var client = try retryTransientConnect(
        ws.Client,
        &connect_ctx,
        connectWsAttempt,
        startup_connect_retry_timeout_ms,
        startup_connect_retry_sleep_ms,
        systemRetryClock(),
    );
    defer client.deinit();

    const request_id = session.nextRequestId();
    const req = try json_rpc.encodeRequest(session.allocator, request_id, method, params_json);
    defer session.allocator.free(req);

    try client.sendText(req);
    return recvRpcResponse(session, &client, request_id);
}

fn recvRpcResponse(session: *Session, client: *ws.Client, expected_id: u64) ![]u8 {
    while (true) {
        const message = try client.recvText(session.allocator);
        errdefer session.allocator.free(message);

        const envelope = json_rpc.decodeEnvelope(session.allocator, message) catch |err| switch (err) {
            error.InvalidResponse => return error.InvalidResponse,
            else => return err,
        };

        if (envelope.id == null) {
            // Event message; keep reading until we receive the request result.
            session.allocator.free(message);
            continue;
        }

        if (envelope.id.? != expected_id) {
            return error.ResponseIdMismatch;
        }

        if (envelope.has_error) {
            return error.ProtocolCommandFailed;
        }

        return message;
    }
}

fn callWebDriver(
    session: *Session,
    method: http.HttpMethod,
    suffix: []const u8,
    body_json: ?[]const u8,
) ![]u8 {
    const endpoint = session.endpoint orelse return error.SessionNotReady;
    const parsed = try common.parseEndpoint(endpoint, .webdriver);

    const full_path = try std.mem.concat(session.allocator, u8, &.{ parsed.path, suffix });
    defer session.allocator.free(full_path);

    const request_ctx = WebDriverRequestCtx{
        .allocator = session.allocator,
        .host = parsed.host,
        .port = parsed.port,
        .method = method,
        .path = full_path,
        .body_json = body_json,
    };
    const res = try retryTransientConnect(
        http.Response,
        &request_ctx,
        requestWebDriverAttempt,
        startup_connect_retry_timeout_ms,
        startup_connect_retry_sleep_ms,
        systemRetryClock(),
    );
    errdefer session.allocator.free(res.body);

    if (res.status_code < 200 or res.status_code >= 300) {
        return error.ProtocolCommandFailed;
    }

    if (try webDriverResponseHasError(session.allocator, res.body)) {
        return error.ProtocolCommandFailed;
    }

    return res.body;
}

fn resolveCdpPagePath(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    const deadline = std.time.milliTimestamp() + cdp_target_poll_timeout_ms;

    while (true) {
        const list_response = http.getJson(allocator, host, port, "/json/list") catch |err| {
            if (std.time.milliTimestamp() >= deadline) return err;
            std.Thread.sleep(cdp_target_poll_sleep_ms * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(list_response.body);

        if (list_response.status_code >= 200 and list_response.status_code < 300) {
            if (try extractPageWebSocketUrlAlloc(allocator, list_response.body)) |ws_url| {
                defer allocator.free(ws_url);
                return extractPathFromWebSocketUrl(allocator, ws_url);
            }
        }

        if (std.time.milliTimestamp() >= deadline) return error.TargetNotFound;
        std.Thread.sleep(cdp_target_poll_sleep_ms * std.time.ns_per_ms);
    }
}

fn extractPageWebSocketUrlAlloc(allocator: std.mem.Allocator, json: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return null;

    var first_ws_url: ?[]const u8 = null;
    for (root.array.items) |entry| {
        if (entry != .object) continue;
        const ws_url_value = entry.object.get("webSocketDebuggerUrl") orelse continue;
        if (ws_url_value != .string) continue;

        if (first_ws_url == null) first_ws_url = ws_url_value.string;

        const target_type_value = entry.object.get("type") orelse continue;
        if (target_type_value == .string and std.mem.eql(u8, target_type_value.string, "page")) {
            return @as(?[]u8, try allocator.dupe(u8, ws_url_value.string));
        }
    }

    if (first_ws_url) |url| return @as(?[]u8, try allocator.dupe(u8, url));
    return null;
}

fn webDriverResponseHasError(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;

    const value_obj = root.object.get("value") orelse return false;
    if (value_obj != .object) return false;

    return value_obj.object.get("error") != null;
}

fn findWebDriverElement(session: *Session, selector: []const u8) ![]u8 {
    const sel = try escapeJsonString(session.allocator, selector);
    defer session.allocator.free(sel);

    const body = try std.fmt.allocPrint(
        session.allocator,
        "{{\"using\":\"css selector\",\"value\":\"{s}\"}}",
        .{sel},
    );
    defer session.allocator.free(body);

    const response = try callWebDriver(session, .POST, "/element", body);
    defer session.allocator.free(response);

    if (try extractJsonStringPathAlloc(session.allocator, response, &.{ "value", "element-6066-11e4-a52e-4f735466cecf" })) |id| return id;
    if (try extractJsonStringPathAlloc(session.allocator, response, &.{ "value", "ELEMENT" })) |id| return id;

    return error.InvalidResponse;
}

fn evalViaCdp(session: *Session, expression: []const u8) ![]u8 {
    const escaped = try escapeJsonString(session.allocator, expression);
    defer session.allocator.free(escaped);

    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}",
        .{escaped},
    );
    defer session.allocator.free(params);

    return callCdp(session, "Runtime.evaluate", params);
}

fn evalViaWebDriver(session: *Session, script: []const u8) ![]u8 {
    const escaped = try escapeJsonString(session.allocator, script);
    defer session.allocator.free(escaped);

    const body = try std.fmt.allocPrint(session.allocator, "{{\"script\":\"{s}\",\"args\":[]}}", .{escaped});
    defer session.allocator.free(body);

    return callWebDriver(session, .POST, "/execute/sync", body);
}

fn evalViaBidi(session: *Session, expression: []const u8) ![]u8 {
    const context_id = session.browsing_context_id orelse return error.SessionNotReady;
    const escaped = try escapeJsonString(session.allocator, expression);
    defer session.allocator.free(escaped);

    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"target\":{{\"context\":\"{s}\"}},\"expression\":\"{s}\",\"awaitPromise\":true,\"resultOwnership\":\"none\"}}",
        .{ context_id, escaped },
    );
    defer session.allocator.free(params);

    return callBidi(session, "script.evaluate", params);
}

fn extractJsonStringAlloc(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;
    const value = root.object.get(key) orelse return null;
    if (value != .string) return null;

    return try allocator.dupe(u8, value.string);
}

fn extractJsonStringPathAlloc(allocator: std.mem.Allocator, json: []const u8, path: []const []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    var current = parsed.value;
    for (path) |part| {
        if (current != .object) return null;
        current = current.object.get(part) orelse return null;
    }

    if (current != .string) return null;
    return try allocator.dupe(u8, current.string);
}

fn extractPathFromWebSocketUrl(allocator: std.mem.Allocator, ws_url: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, ws_url, "://") orelse return error.InvalidEndpoint;
    const rest = ws_url[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return allocator.dupe(u8, "/");
    return allocator.dupe(u8, rest[slash..]);
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

const RetryTestClockState = struct {
    now_ms: i64 = 0,
    sleep_calls: usize = 0,
};

fn retryTestNowMs(ctx: *anyopaque) i64 {
    const state: *RetryTestClockState = @ptrCast(@alignCast(ctx));
    return state.now_ms;
}

fn retryTestSleepMs(ctx: *anyopaque, interval_ms: u64) void {
    const state: *RetryTestClockState = @ptrCast(@alignCast(ctx));
    state.sleep_calls += 1;
    state.now_ms += @as(i64, @intCast(interval_ms));
}

test "startup retry retries transient connect failures" {
    const AttemptState = struct {
        attempts: usize = 0,
        fail_count: usize,
    };

    const Runner = struct {
        fn run(ctx: *const anyopaque) anyerror!u8 {
            const state: *AttemptState = @ptrCast(@alignCast(@constCast(ctx)));
            state.attempts += 1;
            if (state.attempts <= state.fail_count) return error.ConnectionRefused;
            return 1;
        }
    };

    var clock_state: RetryTestClockState = .{};
    var attempt_state: AttemptState = .{ .fail_count = 2 };
    const value = try retryTransientConnect(
        u8,
        &attempt_state,
        Runner.run,
        8_000,
        100,
        .{
            .ctx = &clock_state,
            .now_ms_fn = retryTestNowMs,
            .sleep_ms_fn = retryTestSleepMs,
        },
    );

    try std.testing.expectEqual(@as(u8, 1), value);
    try std.testing.expectEqual(@as(usize, 3), attempt_state.attempts);
    try std.testing.expectEqual(@as(usize, 2), clock_state.sleep_calls);
}

test "startup retry fails fast for non transient connect failures" {
    const AttemptState = struct {
        attempts: usize = 0,
    };

    const Runner = struct {
        fn run(ctx: *const anyopaque) anyerror!u8 {
            const state: *AttemptState = @ptrCast(@alignCast(@constCast(ctx)));
            state.attempts += 1;
            return error.HandshakeFailed;
        }
    };

    var clock_state: RetryTestClockState = .{};
    var attempt_state: AttemptState = .{};
    try std.testing.expectError(
        error.HandshakeFailed,
        retryTransientConnect(
            u8,
            &attempt_state,
            Runner.run,
            8_000,
            100,
            .{
                .ctx = &clock_state,
                .now_ms_fn = retryTestNowMs,
                .sleep_ms_fn = retryTestSleepMs,
            },
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), attempt_state.attempts);
    try std.testing.expectEqual(@as(usize, 0), clock_state.sleep_calls);
}

test "startup retry deadline expiry returns transient connect error" {
    const AttemptState = struct {
        attempts: usize = 0,
    };

    const Runner = struct {
        fn run(ctx: *const anyopaque) anyerror!u8 {
            const state: *AttemptState = @ptrCast(@alignCast(@constCast(ctx)));
            state.attempts += 1;
            return error.ConnectionRefused;
        }
    };

    var clock_state: RetryTestClockState = .{};
    var attempt_state: AttemptState = .{};
    try std.testing.expectError(
        error.ConnectionRefused,
        retryTransientConnect(
            u8,
            &attempt_state,
            Runner.run,
            250,
            100,
            .{
                .ctx = &clock_state,
                .now_ms_fn = retryTestNowMs,
                .sleep_ms_fn = retryTestSleepMs,
            },
        ),
    );

    try std.testing.expectEqual(@as(usize, 4), attempt_state.attempts);
    try std.testing.expectEqual(@as(usize, 3), clock_state.sleep_calls);
}

test "escape json string" {
    const allocator = std.testing.allocator;
    const out = try escapeJsonString(allocator, "a\"b\\c\n");
    defer allocator.free(out);

    try std.testing.expect(std.mem.eql(u8, out, "a\\\"b\\\\c\\n"));
}

test "extract json string path alloc" {
    const allocator = std.testing.allocator;
    const value = try extractJsonStringPathAlloc(
        allocator,
        "{\"value\":{\"element-6066-11e4-a52e-4f735466cecf\":\"abc\"}}",
        &.{ "value", "element-6066-11e4-a52e-4f735466cecf" },
    );
    defer if (value) |v| allocator.free(v);

    try std.testing.expect(value != null);
    try std.testing.expect(std.mem.eql(u8, value.?, "abc"));
}

test "extract page web socket url prefers page target" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"id":"browser","type":"browser","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/abc"},
        \\  {"id":"page-1","type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/1"}
        \\]
    ;

    const value = try extractPageWebSocketUrlAlloc(allocator, json);
    defer if (value) |v| allocator.free(v);

    try std.testing.expect(value != null);
    try std.testing.expect(std.mem.eql(u8, value.?, "ws://127.0.0.1:9222/devtools/page/1"));
}

test "extract page web socket url falls back to first target" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"id":"browser","type":"browser","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/browser/abc"},
        \\  {"id":"worker-1","type":"worker","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/worker/1"}
        \\]
    ;

    const value = try extractPageWebSocketUrlAlloc(allocator, json);
    defer if (value) |v| allocator.free(v);

    try std.testing.expect(value != null);
    try std.testing.expect(std.mem.eql(u8, value.?, "ws://127.0.0.1:9222/devtools/browser/abc"));
}
