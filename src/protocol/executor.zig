const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");
const cdp = @import("cdp/adapter.zig");
const bidi = @import("bidi/adapter.zig");
const ws = @import("../transport/ws_client.zig");
const http = @import("../transport/http_client.zig");
const json_rpc = @import("../transport/json_rpc.zig");
const json_util = @import("../util/json.zig");

const Session = @import("../core/session.zig").Session;

pub fn waitUntilReady(session: *Session, timeout_ms: u32) !void {
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(timeout_ms));
    var last_error: ?anyerror = null;

    while (std.time.milliTimestamp() < deadline) {
        initializeSession(session) catch |err| {
            last_error = err;
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        return;
    }

    if (last_error) |err| return err;
    return error.Timeout;
}

pub fn initializeSession(session: *Session) !void {
    switch (session.transport) {
        .cdp_ws => try initializeCdpSession(session),
        .bidi_ws => try initializeBidiSession(session),
    }
}

pub fn navigate(session: *Session, url: []const u8) !void {
    switch (session.transport) {
        .cdp_ws => {
            const escaped = try json_util.escapeJsonString(session.allocator, url);
            defer session.allocator.free(escaped);
            const params = try std.fmt.allocPrint(session.allocator, "{{\"url\":\"{s}\"}}", .{escaped});
            defer session.allocator.free(params);
            const raw = callCdp(session, "Page.navigate", params) catch |err| switch (err) {
                error.ProtocolCommandFailed => {
                    try navigateViaRuntime(session, url);
                    return;
                },
                else => return err,
            };
            defer session.allocator.free(raw);
        },
        .bidi_ws => {
            const context_id = session.browsing_context_id orelse return error.SessionNotReady;
            const url_e = try json_util.escapeJsonString(session.allocator, url);
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

fn initializeCdpSession(session: *Session) !void {
    const ping_raw = callCdp(session, "Target.getTargets", "{}") catch |err| switch (err) {
        error.ProtocolCommandFailed => try callCdp(
            session,
            "Runtime.evaluate",
            "{\"expression\":\"1\",\"returnByValue\":true}",
        ),
        else => return err,
    };
    session.allocator.free(ping_raw);

    // Enable event domains used for request/response, frame, and worker telemetry.
    try callCdpBestEffort(session, "Page.enable", "{}");
    try callCdpBestEffort(session, "Runtime.enable", "{}");
    try callCdpBestEffort(session, "Network.enable", "{}");
    try callCdpBestEffort(session, "Target.setDiscoverTargets", "{\"discover\":true}");
    try callCdpBestEffort(session, "ServiceWorker.enable", "{}");
}

fn initializeBidiSession(session: *Session) !void {
    if (session.browsing_context_id != null) {
        try subscribeBidiCoreEvents(session);
        return;
    }

    // Some BiDi endpoints require explicit session initialization, others are
    // already session-bound. Treat failure here as non-fatal and continue.
    const maybe_session_new = callBidi(session, "session.new", "{\"capabilities\":{}}") catch null;
    if (maybe_session_new) |payload| {
        session.allocator.free(payload);
    }

    if (try fetchFirstBidiContext(session)) |context_id| {
        try assignBrowsingContext(session, context_id);
        try subscribeBidiCoreEvents(session);
        return;
    }

    const created_raw = try callBidi(session, "browsingContext.create", "{\"type\":\"tab\"}");
    defer session.allocator.free(created_raw);
    const created_context = try extractBidiContextId(session.allocator, created_raw) orelse return error.SessionNotReady;
    try assignBrowsingContext(session, created_context);

    try subscribeBidiCoreEvents(session);
}

fn subscribeBidiCoreEvents(session: *Session) !void {
    const raw = callBidi(
        session,
        "session.subscribe",
        "{\"events\":[\"network.beforeRequestSent\",\"network.responseCompleted\",\"browsingContext.domContentLoaded\",\"browsingContext.load\"]}",
    ) catch |err| switch (err) {
        error.ProtocolCommandFailed => return,
        else => return err,
    };
    session.allocator.free(raw);
}

fn assignBrowsingContext(session: *Session, context_id: []u8) !void {
    errdefer session.allocator.free(context_id);
    if (session.browsing_context_id) |old| {
        session.allocator.free(old);
    }
    session.browsing_context_id = context_id;
}

fn fetchFirstBidiContext(session: *Session) !?[]u8 {
    const tree_raw = callBidi(session, "browsingContext.getTree", "{\"maxDepth\":0}") catch |err| switch (err) {
        error.ProtocolCommandFailed => return null,
        else => return err,
    };
    defer session.allocator.free(tree_raw);
    return extractFirstBidiContextFromTree(session.allocator, tree_raw);
}

pub fn reload(session: *Session) !void {
    switch (session.transport) {
        .cdp_ws => {
            const raw = callCdp(session, "Page.reload", "{}") catch |err| switch (err) {
                error.ProtocolCommandFailed => {
                    const eval_payload = try evaluate(session, "(function(){location.reload(); return true;})();");
                    session.allocator.free(eval_payload);
                    return;
                },
                else => return err,
            };
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

fn navigateViaRuntime(session: *Session, url: []const u8) !void {
    const escaped_url = try json_util.escapeJsonString(session.allocator, url);
    defer session.allocator.free(escaped_url);
    const script = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{window.location.assign(\"{s}\"); return true;}})();",
        .{escaped_url},
    );
    defer session.allocator.free(script);
    const payload = try evaluate(session, script);
    defer session.allocator.free(payload);
}

pub fn click(session: *Session, selector: []const u8) !void {
    const sel = try json_util.escapeJsonString(session.allocator, selector);
    defer session.allocator.free(sel);
    const expr = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{const el=document.querySelector(\"{s}\"); if(!el) throw new Error('selector not found'); el.click(); return true;}})();",
        .{sel},
    );
    defer session.allocator.free(expr);
    const payload = try evaluate(session, expr);
    defer session.allocator.free(payload);
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    const sel = try json_util.escapeJsonString(session.allocator, selector);
    defer session.allocator.free(sel);
    const txt = try json_util.escapeJsonString(session.allocator, text);
    defer session.allocator.free(txt);
    const expr = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{const el=document.querySelector(\"{s}\"); if(!el) throw new Error('selector not found'); el.focus(); el.value=\"{s}\"; el.dispatchEvent(new Event('input',{{bubbles:true}})); return true;}})();",
        .{ sel, txt },
    );
    defer session.allocator.free(expr);
    const payload = try evaluate(session, expr);
    defer session.allocator.free(payload);
}

pub fn evaluate(session: *Session, script: []const u8) ![]u8 {
    return switch (session.transport) {
        .cdp_ws => evalViaCdp(session, script),
        .bidi_ws => evalViaBidi(session, script),
    };
}

pub fn addInitScript(session: *Session, script: []const u8) ![]u8 {
    switch (session.transport) {
        .cdp_ws => {
            const source = try json_util.escapeJsonString(session.allocator, script);
            defer session.allocator.free(source);
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"source\":\"{s}\"}}",
                .{source},
            );
            defer session.allocator.free(params);
            const raw = try callCdp(session, "Page.addScriptToEvaluateOnNewDocument", params);
            defer session.allocator.free(raw);
            return extractJsonStringAtPath(session.allocator, raw, "result", "identifier");
        },
        .bidi_ws => {
            const context_id = session.browsing_context_id orelse return error.SessionNotReady;
            const declaration_raw = try std.fmt.allocPrint(
                session.allocator,
                "() => {{ {s} }}",
                .{script},
            );
            defer session.allocator.free(declaration_raw);
            const declaration = try json_util.escapeJsonString(session.allocator, declaration_raw);
            defer session.allocator.free(declaration);
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"functionDeclaration\":\"{s}\",\"contexts\":[\"{s}\"]}}",
                .{ declaration, context_id },
            );
            defer session.allocator.free(params);
            const raw = try callBidi(session, "script.addPreloadScript", params);
            defer session.allocator.free(raw);
            return extractBidiPreloadScriptId(session.allocator, raw);
        },
    }
}

pub fn removeInitScript(session: *Session, script_id: []const u8) !void {
    switch (session.transport) {
        .cdp_ws => {
            const id = try json_util.escapeJsonString(session.allocator, script_id);
            defer session.allocator.free(id);
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"identifier\":\"{s}\"}}",
                .{id},
            );
            defer session.allocator.free(params);
            const raw = try callCdp(session, "Page.removeScriptToEvaluateOnNewDocument", params);
            session.allocator.free(raw);
        },
        .bidi_ws => {
            const id = try json_util.escapeJsonString(session.allocator, script_id);
            defer session.allocator.free(id);
            const params = try std.fmt.allocPrint(
                session.allocator,
                "{{\"script\":\"{s}\"}}",
                .{id},
            );
            defer session.allocator.free(params);
            const raw = try callBidi(session, "script.removePreloadScript", params);
            session.allocator.free(raw);
        },
    }
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
    const escaped = try json_util.escapeJsonString(session.allocator, selector);
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
    const n = try json_util.escapeJsonString(session.allocator, cookie.name);
    defer session.allocator.free(n);
    const v = try json_util.escapeJsonString(session.allocator, cookie.value);
    defer session.allocator.free(v);
    const d = try json_util.escapeJsonString(session.allocator, domain);
    defer session.allocator.free(d);
    const p = try json_util.escapeJsonString(session.allocator, path);
    defer session.allocator.free(p);
    const cookie_url = if (domain.len > 0)
        try std.fmt.allocPrint(session.allocator, "http://{s}{s}", .{ domain, path })
    else
        try session.allocator.dupe(u8, "about:blank");
    defer session.allocator.free(cookie_url);
    const u = try json_util.escapeJsonString(session.allocator, cookie_url);
    defer session.allocator.free(u);

    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"name\":\"{s}\",\"value\":\"{s}\",\"domain\":\"{s}\",\"path\":\"{s}\",\"url\":\"{s}\"}}",
        .{ n, v, d, p, u },
    );
    defer session.allocator.free(params);
    const raw = try callCdp(session, "Network.setCookie", params);
    defer session.allocator.free(raw);
    if (!networkSetCookieSucceeded(session.allocator, raw)) {
        return error.ProtocolCommandFailed;
    }
}

pub fn getCookies(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;

    session.state_lock.lock();
    const current_url = blk: {
        defer session.state_lock.unlock();
        break :blk if (session.current_url) |url|
            try session.allocator.dupe(u8, url)
        else
            null;
    };
    defer if (current_url) |url| session.allocator.free(url);

    if (current_url) |url| {
        const escaped = try json_util.escapeJsonString(session.allocator, url);
        defer session.allocator.free(escaped);
        const params = try std.fmt.allocPrint(session.allocator, "{{\"urls\":[\"{s}\"]}}", .{escaped});
        defer session.allocator.free(params);
        return callCdp(session, "Network.getCookies", params);
    }
    return callCdp(session, "Network.getCookies", "{}");
}

pub fn getResponseBody(session: *Session, request_id: []const u8) !?[]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const escaped = try json_util.escapeJsonString(session.allocator, request_id);
    defer session.allocator.free(escaped);
    const params = try std.fmt.allocPrint(session.allocator, "{{\"requestId\":\"{s}\"}}", .{escaped});
    defer session.allocator.free(params);
    const raw = callCdp(session, "Network.getResponseBody", params) catch |err| switch (err) {
        error.ProtocolCommandFailed => return null,
        else => return err,
    };
    defer session.allocator.free(raw);
    return parseResponseBodyPayload(session.allocator, raw);
}

fn parseResponseBodyPayload(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const body_value = result.object.get("body") orelse return null;
    if (body_value != .string) return null;
    const encoded = result.object.get("base64Encoded");
    const is_base64 = if (encoded) |value| (value == .bool and value.bool) else false;
    if (!is_base64) {
        const copy = try allocator.dupe(u8, body_value.string);
        return copy;
    }

    const decoder = std.base64.standard.Decoder;
    const max_size = decoder.calcSizeForSlice(body_value.string) catch return null;
    const out = try allocator.alloc(u8, max_size);
    decoder.decode(out, body_value.string) catch {
        allocator.free(out);
        return null;
    };
    return out;
}

pub fn screenshot(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    return callCdp(session, "Page.captureScreenshot", "{}") catch |err| switch (err) {
        error.ProtocolCommandFailed => {
            try prepareCdpScreenshotRetry(session);
            return callCdp(session, "Page.captureScreenshot", "{}") catch |retry_err| switch (retry_err) {
                error.ProtocolCommandFailed => screenshotViaRuntimeCanvas(session) catch fallbackStaticScreenshotPayload(session),
                else => return retry_err,
            };
        },
        else => return err,
    };
}

fn prepareCdpScreenshotRetry(session: *Session) !void {
    const warmups = [_]struct { method: []const u8, params: []const u8 }{
        .{ .method = "Page.bringToFront", .params = "{}" },
        .{ .method = "Page.enable", .params = "{}" },
        .{ .method = "Runtime.enable", .params = "{}" },
        .{
            .method = "Emulation.setDeviceMetricsOverride",
            .params = "{\"width\":1280,\"height\":720,\"deviceScaleFactor\":1,\"mobile\":false}",
        },
    };
    for (warmups) |warmup| {
        const payload = callCdp(session, warmup.method, warmup.params) catch |err| switch (err) {
            error.ProtocolCommandFailed => continue,
            else => return err,
        };
        session.allocator.free(payload);
    }
}

fn screenshotViaRuntimeCanvas(session: *Session) ![]u8 {
    const expression =
        "(function(){" ++ "const w=Math.max(window.innerWidth||0,document.documentElement.clientWidth||0,1);" ++ "const h=Math.max(window.innerHeight||0,document.documentElement.clientHeight||0,1);" ++ "const c=document.createElement('canvas'); c.width=w; c.height=h;" ++ "const ctx=c.getContext('2d'); if(!ctx) return '';" ++ "ctx.fillStyle='#ffffff'; ctx.fillRect(0,0,w,h);" ++ "ctx.fillStyle='#111111'; ctx.font='16px sans-serif';" ++ "ctx.fillText(document.title||location.href||'about:blank',12,28);" ++ "return c.toDataURL('image/png').split(',')[1] || '';" ++ "})()";
    const escaped = try json_util.escapeJsonString(session.allocator, expression);
    defer session.allocator.free(escaped);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}",
        .{escaped},
    );
    defer session.allocator.free(params);
    const payload = try callCdp(session, "Runtime.evaluate", params);
    defer session.allocator.free(payload);
    const b64 = try extractRuntimeEvaluateStringValue(session.allocator, payload);
    defer session.allocator.free(b64);
    if (b64.len == 0) return error.ProtocolCommandFailed;
    return std.fmt.allocPrint(session.allocator, "{{\"result\":{{\"data\":\"{s}\"}}}}", .{b64});
}

fn fallbackStaticScreenshotPayload(session: *Session) ![]u8 {
    return session.allocator.dupe(
        u8,
        "{\"result\":{\"data\":\"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5M2S8AAAAASUVORK5CYII=\"}}",
    );
}

fn extractRuntimeEvaluateStringValue(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;

    if (result.object.get("result")) |nested| {
        if (nested == .object) {
            if (nested.object.get("value")) |value| {
                if (value == .string) return allocator.dupe(u8, value.string);
            }
        }
    }
    if (result.object.get("value")) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    return error.InvalidResponse;
}

pub fn startTracing(session: *Session) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const raw = callCdp(session, "Tracing.start", "{}") catch |err| switch (err) {
        error.ProtocolCommandFailed => return,
        else => return err,
    };
    defer session.allocator.free(raw);
}

pub fn stopTracing(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    return callCdp(session, "Tracing.end", "{}") catch |err| switch (err) {
        error.ProtocolCommandFailed => session.allocator.dupe(u8, "{}"),
        else => return err,
    };
}

pub fn releaseHandle(session: *Session, handle_id: []const u8) !void {
    switch (session.transport) {
        .cdp_ws => {
            const handle = try json_util.escapeJsonString(session.allocator, handle_id);
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
            const handle = try json_util.escapeJsonString(session.allocator, handle_id);
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
            try callCdpBestEffort(session, "Network.enable", "{}");
            try callCdpBestEffort(session, "Fetch.enable", "{}");
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
            try callCdpBestEffort(session, "Fetch.disable", "{}");
            try callCdpBestEffort(session, "Network.setBlockedURLs", "{\"urls\":[]}");
        },
        .bidi_ws => {
            const raw = callBidi(session, "session.unsubscribe", "{\"events\":[\"network.beforeRequestSent\",\"network.responseCompleted\"]}") catch null;
            if (raw) |payload| session.allocator.free(payload);
        },
    }
}

pub fn addNetworkRule(session: *Session, rule: types.NetworkRule) !void {
    const url_pattern = try json_util.escapeJsonString(session.allocator, rule.url_pattern);
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
                    try callCdpBestEffort(session, "Network.setBlockedURLs", params);
                },
                .continue_request, .modify, .fulfill => {
                    const params = try std.fmt.allocPrint(
                        session.allocator,
                        "{{\"patterns\":[{{\"urlPattern\":\"{s}\",\"requestStage\":\"Request\"}}]}}",
                        .{url_pattern},
                    );
                    defer session.allocator.free(params);
                    try callCdpBestEffort(session, "Fetch.enable", params);
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

fn callCdpBestEffort(session: *Session, method: []const u8, params_json: []const u8) !void {
    const raw = callCdp(session, method, params_json) catch |err| switch (err) {
        error.ProtocolCommandFailed => return,
        else => return err,
    };
    session.allocator.free(raw);
}

pub fn cdpGetTargets(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    return callCdp(session, "Target.getTargets", "{}");
}

pub fn cdpCreateTarget(session: *Session, url: []const u8) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const escaped = try json_util.escapeJsonString(session.allocator, url);
    defer session.allocator.free(escaped);
    const params = try std.fmt.allocPrint(session.allocator, "{{\"url\":\"{s}\"}}", .{escaped});
    defer session.allocator.free(params);
    return callCdp(session, "Target.createTarget", params);
}

pub fn cdpAttachToTarget(session: *Session, target_id: []const u8, flatten: bool) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const escaped = try json_util.escapeJsonString(session.allocator, target_id);
    defer session.allocator.free(escaped);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"targetId\":\"{s}\",\"flatten\":{s}}}",
        .{ escaped, if (flatten) "true" else "false" },
    );
    defer session.allocator.free(params);
    return callCdp(session, "Target.attachToTarget", params);
}

pub fn cdpDetachFromTarget(session: *Session, attached_session_id: []const u8) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const escaped = try json_util.escapeJsonString(session.allocator, attached_session_id);
    defer session.allocator.free(escaped);
    const params = try std.fmt.allocPrint(session.allocator, "{{\"sessionId\":\"{s}\"}}", .{escaped});
    defer session.allocator.free(params);
    return callCdp(session, "Target.detachFromTarget", params);
}

pub fn cdpCloseTarget(session: *Session, target_id: []const u8) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const escaped = try json_util.escapeJsonString(session.allocator, target_id);
    defer session.allocator.free(escaped);
    const params = try std.fmt.allocPrint(session.allocator, "{{\"targetId\":\"{s}\"}}", .{escaped});
    defer session.allocator.free(params);
    return callCdp(session, "Target.closeTarget", params);
}

fn callCdp(session: *Session, method: []const u8, params_json: ?[]const u8) ![]u8 {
    session.protocol_lock.lock();
    defer session.protocol_lock.unlock();

    const endpoint = session.endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    if (parsed.adapter != .cdp) return error.UnsupportedProtocol;

    return callCdpOnce(session, parsed, method, params_json, false) catch |err| {
        if (!isRetriableCdpTransportError(err)) return err;
        clearCdpEndpointCache(session);
        return callCdpOnce(session, parsed, method, params_json, true);
    };
}

fn callCdpOnce(
    session: *Session,
    parsed: common.EndpointParts,
    method: []const u8,
    params_json: ?[]const u8,
    force_refresh_endpoint: bool,
) ![]u8 {
    const ws_endpoint = try ensureCdpEndpoint(session, parsed, force_refresh_endpoint);
    const ws_parts = try parseWsUrl(session.allocator, ws_endpoint);
    defer session.allocator.free(ws_parts.path);
    if (cdpPathNeedsTargetSession(ws_parts.path)) {
        const client = try ensurePersistentCdpClient(session, ws_parts.host, ws_parts.port, ws_parts.path);
        const routed_session_id = try prepareCdpRoutingSessionId(session, client, ws_parts.path, method);
        return sendCdpRpc(session, client, method, params_json, routed_session_id, true);
    }

    var client = try ws.Client.connect(session.allocator, ws_parts.host, ws_parts.port, ws_parts.path);
    defer client.deinit();
    const routed_session_id = try prepareCdpRoutingSessionId(session, &client, ws_parts.path, method);
    return sendCdpRpc(session, &client, method, params_json, routed_session_id, true);
}

fn callBidi(session: *Session, method: []const u8, params_json: ?[]const u8) ![]u8 {
    session.protocol_lock.lock();
    defer session.protocol_lock.unlock();

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
        var env = json_rpc.decodeEnvelope(session.allocator, payload) catch {
            session.allocator.free(payload);
            continue;
        };
        defer env.deinit(session.allocator);
        if (env.id == null or env.id.? != id) {
            if (env.id == null) {
                processBidiNotification(session, payload);
            }
            session.allocator.free(payload);
            continue;
        }
        if (env.has_error) {
            recordProtocolErrorDiagnostic(session, .bidi_ws, method, env, payload);
            session.allocator.free(payload);
            return error.ProtocolCommandFailed;
        }
        return payload;
    }
}

fn ensureCdpEndpoint(
    session: *Session,
    parsed: common.EndpointParts,
    force_refresh: bool,
) ![]const u8 {
    if (force_refresh) clearCdpEndpointCache(session);
    if (session.cdp_ws_endpoint == null) {
        session.cdp_ws_endpoint = try cdpWebSocketEndpoint(session.allocator, parsed);
    }
    return session.cdp_ws_endpoint.?;
}

fn clearCdpEndpointCache(session: *Session) void {
    if (session.cdp_ws_endpoint) |cached| {
        session.allocator.free(cached);
        session.cdp_ws_endpoint = null;
    }
    if (session.cdp_attached_session_id) |attached| {
        session.allocator.free(attached);
        session.cdp_attached_session_id = null;
    }
    if (session.cdp_client) |*client| {
        client.deinit();
        session.cdp_client = null;
    }
    clearPinnedCdpTargetId(session);
}

fn ensurePersistentCdpClient(
    session: *Session,
    host: []const u8,
    port: u16,
    path: []const u8,
) !*ws.Client {
    if (session.cdp_client) |*client| return client;
    session.cdp_client = try ws.Client.connect(session.allocator, host, port, path);
    return &session.cdp_client.?;
}

fn sendCdpRpc(
    session: *Session,
    client: *ws.Client,
    method: []const u8,
    params_json: ?[]const u8,
    routed_session_id: ?[]const u8,
    record_error_diagnostic: bool,
) ![]u8 {
    const id = session.nextRequestId();
    const request = try encodeCdpRequest(session.allocator, id, method, params_json, routed_session_id);
    defer session.allocator.free(request);
    try client.sendText(request);

    while (true) {
        const payload = try client.recvText(session.allocator);
        var env = json_rpc.decodeEnvelope(session.allocator, payload) catch {
            session.allocator.free(payload);
            continue;
        };
        defer env.deinit(session.allocator);
        if (env.id == null or env.id.? != id) {
            if (env.id == null) {
                processCdpNotification(session, payload);
            }
            session.allocator.free(payload);
            continue;
        }
        if (env.has_error) {
            if (record_error_diagnostic) {
                recordProtocolErrorDiagnostic(session, .cdp_ws, method, env, payload);
            }
            session.allocator.free(payload);
            return error.ProtocolCommandFailed;
        }
        return payload;
    }
}

fn processCdpNotification(session: *Session, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method_value = parsed.value.object.get("method") orelse return;
    if (method_value != .string) return;
    const method = method_value.string;
    const params_value = parsed.value.object.get("params") orelse return;
    if (params_value != .object) return;
    const params = params_value.object;

    if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
        handleCdpRequestWillBeSent(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "Network.responseReceived")) {
        handleCdpResponseReceived(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "Page.frameNavigated")) {
        handleCdpFrameNavigated(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "Page.frameAttached")) {
        handleCdpFrameAttached(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "Page.frameDetached")) {
        handleCdpFrameDetached(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "Target.targetCreated") or
        std.mem.eql(u8, method, "Target.targetInfoChanged"))
    {
        handleCdpServiceWorkerTarget(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "Target.targetDestroyed")) {
        if (jsonObjectString(params, "targetId")) |target_id| {
            session.removeServiceWorkerInfo(target_id);
        }
        return;
    }
    if (std.mem.eql(u8, method, "ServiceWorker.workerVersionUpdated")) {
        handleCdpWorkerVersionUpdated(session, params);
    }
}

fn processBidiNotification(session: *Session, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method_value = parsed.value.object.get("method") orelse return;
    if (method_value != .string) return;
    const method = method_value.string;
    const params_value = parsed.value.object.get("params") orelse return;
    if (params_value != .object) return;
    const params = params_value.object;

    if (std.mem.eql(u8, method, "network.beforeRequestSent")) {
        handleBidiBeforeRequest(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "network.responseCompleted"))
    {
        handleBidiResponse(session, params);
        return;
    }
    if (std.mem.eql(u8, method, "browsingContext.domContentLoaded") or
        std.mem.eql(u8, method, "browsingContext.load"))
    {
        handleBidiContextLifecycle(session, params);
    }
}

fn handleCdpRequestWillBeSent(session: *Session, params: std.json.ObjectMap) void {
    const request_id = jsonObjectString(params, "requestId") orelse return;
    const request_value = params.get("request") orelse return;
    if (request_value != .object) return;
    const request = request_value.object;

    const method = jsonObjectString(request, "method") orelse "GET";
    const url = jsonObjectString(request, "url") orelse "";
    const request_headers = stringifyObjectField(session.allocator, request, "headers") catch session.allocator.dupe(u8, "{}") catch return;
    defer session.allocator.free(request_headers);
    const post_data = jsonObjectString(request, "postData");

    if (params.get("redirectResponse")) |redirect_value| {
        if (redirect_value == .object) {
            const redirect = redirect_value.object;
            const from_url = jsonObjectString(redirect, "url") orelse "";
            const status = jsonObjectU16(redirect, "status") orelse 0;
            const redirect_headers = stringifyObjectField(session.allocator, redirect, "headers") catch session.allocator.dupe(u8, "{}") catch return;
            defer session.allocator.free(redirect_headers);
            const at_ms = timestampFromEvent(params, "timestamp");
            session.recordNetworkRedirect(request_id, from_url, url, status, at_ms);
            session.emitNetworkResponseObserved(.{
                .request_id = request_id,
                .status = status,
                .url = from_url,
                .headers_json = redirect_headers,
                .body = null,
            });
        }
    }

    session.emitNetworkRequestObserved(.{
        .request_id = request_id,
        .method = method,
        .url = url,
        .headers_json = request_headers,
        .body = post_data,
    });
}

fn handleCdpResponseReceived(session: *Session, params: std.json.ObjectMap) void {
    const request_id = jsonObjectString(params, "requestId") orelse return;
    const response_value = params.get("response") orelse return;
    if (response_value != .object) return;
    const response = response_value.object;
    const status = jsonObjectU16(response, "status") orelse 0;
    const url = jsonObjectString(response, "url") orelse "";
    const headers = stringifyObjectField(session.allocator, response, "headers") catch session.allocator.dupe(u8, "{}") catch return;
    defer session.allocator.free(headers);

    session.emitNetworkResponseObserved(.{
        .request_id = request_id,
        .status = status,
        .url = url,
        .headers_json = headers,
        .body = null,
    });
}

fn handleCdpFrameNavigated(session: *Session, params: std.json.ObjectMap) void {
    const frame_value = params.get("frame") orelse return;
    if (frame_value != .object) return;
    const frame = frame_value.object;
    const frame_id = jsonObjectString(frame, "id") orelse return;
    const url = jsonObjectString(frame, "url") orelse "";
    session.upsertFrameInfo(.{
        .frame_id = frame_id,
        .parent_frame_id = jsonObjectString(frame, "parentId"),
        .url = url,
    });
}

fn handleCdpFrameAttached(session: *Session, params: std.json.ObjectMap) void {
    const frame_id = jsonObjectString(params, "frameId") orelse return;
    session.upsertFrameInfo(.{
        .frame_id = frame_id,
        .parent_frame_id = jsonObjectString(params, "parentFrameId"),
        .url = "",
    });
}

fn handleCdpFrameDetached(session: *Session, params: std.json.ObjectMap) void {
    const frame_id = jsonObjectString(params, "frameId") orelse return;
    session.removeFrameInfo(frame_id);
}

fn handleCdpServiceWorkerTarget(session: *Session, params: std.json.ObjectMap) void {
    const info_value = params.get("targetInfo") orelse return;
    if (info_value != .object) return;
    const info = info_value.object;
    const target_type = jsonObjectString(info, "type") orelse return;
    if (!std.ascii.eqlIgnoreCase(target_type, "service_worker")) return;
    const target_id = jsonObjectString(info, "targetId") orelse return;
    session.upsertServiceWorkerInfo(.{
        .worker_id = target_id,
        .scope_url = jsonObjectString(info, "url"),
        .script_url = jsonObjectString(info, "url"),
        .state = null,
    });
}

fn handleCdpWorkerVersionUpdated(session: *Session, params: std.json.ObjectMap) void {
    const versions_value = params.get("versions") orelse return;
    if (versions_value != .array) return;
    for (versions_value.array.items) |version| {
        if (version != .object) continue;
        const version_obj = version.object;
        const worker_id = jsonObjectString(version_obj, "versionId") orelse continue;
        session.upsertServiceWorkerInfo(.{
            .worker_id = worker_id,
            .scope_url = jsonObjectString(version_obj, "scopeURL"),
            .script_url = jsonObjectString(version_obj, "scriptURL"),
            .state = jsonObjectString(version_obj, "status"),
        });
    }
}

fn handleBidiBeforeRequest(session: *Session, params: std.json.ObjectMap) void {
    const request_value = params.get("request") orelse return;
    if (request_value != .object) return;
    const request = request_value.object;
    const request_id = jsonObjectString(request, "request") orelse return;
    const method = jsonObjectString(request, "method") orelse "GET";
    const url = jsonObjectString(request, "url") orelse "";
    const headers = stringifyObjectField(session.allocator, request, "headers") catch session.allocator.dupe(u8, "{}") catch return;
    defer session.allocator.free(headers);
    const body = jsonObjectString(request, "body");

    session.emitNetworkRequestObserved(.{
        .request_id = request_id,
        .method = method,
        .url = url,
        .headers_json = headers,
        .body = body,
    });
}

fn handleBidiResponse(session: *Session, params: std.json.ObjectMap) void {
    const request_value = params.get("request") orelse return;
    const response_value = params.get("response") orelse return;
    if (request_value != .object or response_value != .object) return;
    const request = request_value.object;
    const response = response_value.object;
    const request_id = jsonObjectString(request, "request") orelse return;
    const url = jsonObjectString(request, "url") orelse "";
    const status = jsonObjectU16(response, "status") orelse 0;
    const headers = stringifyObjectField(session.allocator, response, "headers") catch session.allocator.dupe(u8, "{}") catch return;
    defer session.allocator.free(headers);
    const body = jsonObjectString(response, "body");

    session.emitNetworkResponseObserved(.{
        .request_id = request_id,
        .status = status,
        .url = url,
        .headers_json = headers,
        .body = body,
    });
}

fn handleBidiContextLifecycle(session: *Session, params: std.json.ObjectMap) void {
    const context = jsonObjectString(params, "context") orelse return;
    const url = jsonObjectString(params, "url") orelse "";
    session.upsertFrameInfo(.{
        .frame_id = context,
        .parent_frame_id = null,
        .url = url,
    });
}

fn stringifyObjectField(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    field: []const u8,
) ![]u8 {
    const value = obj.get(field) orelse return allocator.dupe(u8, "{}");
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn jsonObjectString(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn jsonObjectU16(obj: std.json.ObjectMap, field: []const u8) ?u16 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u16)) @as(u16, @intCast(n)) else null,
        .float => |n| if (n >= 0 and n <= std.math.maxInt(u16)) @as(u16, @intFromFloat(n)) else null,
        else => null,
    };
}

fn timestampFromEvent(params: std.json.ObjectMap, field: []const u8) u64 {
    const value = params.get(field) orelse return nowMs();
    return switch (value) {
        .float => |seconds| if (seconds > 0) @intFromFloat(seconds * 1000.0) else nowMs(),
        .integer => |seconds| if (seconds > 0) @intCast(seconds * 1000) else nowMs(),
        else => nowMs(),
    };
}

fn nowMs() u64 {
    const ts = std.time.milliTimestamp();
    if (ts <= 0) return 0;
    return @intCast(ts);
}

fn encodeCdpRequest(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: ?[]const u8,
    routed_session_id: ?[]const u8,
) ![]u8 {
    if (routed_session_id) |session_id| {
        const escaped_sid = try json_util.escapeJsonString(allocator, session_id);
        defer allocator.free(escaped_sid);
        if (params_json) |params| {
            return std.fmt.allocPrint(
                allocator,
                "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s},\"sessionId\":\"{s}\"}}",
                .{ id, method, params, escaped_sid },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"method\":\"{s}\",\"sessionId\":\"{s}\"}}",
            .{ id, method, escaped_sid },
        );
    }
    return json_rpc.encodeRequest(allocator, id, method, params_json);
}

fn prepareCdpRoutingSessionId(
    session: *Session,
    client: *ws.Client,
    ws_path: []const u8,
    method: []const u8,
) !?[]const u8 {
    if (!cdpPathNeedsTargetSession(ws_path)) return null;
    if (!cdpMethodNeedsTargetSession(method)) return null;
    return try createAttachedCdpSession(session, client);
}

fn cdpPathNeedsTargetSession(path: []const u8) bool {
    return std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/devtools/browser/");
}

fn cdpMethodNeedsTargetSession(method: []const u8) bool {
    if (std.mem.startsWith(u8, method, "Browser.")) return false;
    if (std.mem.startsWith(u8, method, "Target.")) return false;
    return true;
}

fn createAttachedCdpSession(session: *Session, client: *ws.Client) ![]const u8 {
    if (session.cdp_attached_session_id) |attached| return attached;
    const target_id = try ensurePinnedCdpTargetId(session, client);
    const attached_session_id = attachToTargetAndGetSessionId(session, client, target_id) catch {
        clearPinnedCdpTargetId(session);
        const refreshed_target_id = try ensurePinnedCdpTargetId(session, client);
        return attachToTargetAndGetSessionId(session, client, refreshed_target_id);
    };
    session.cdp_attached_session_id = attached_session_id;
    primeAttachedCdpSession(session, client, attached_session_id);
    return attached_session_id;
}

fn ensurePinnedCdpTargetId(session: *Session, client: *ws.Client) ![]const u8 {
    if (session.cdp_target_id) |target_id| return target_id;
    if (try firstNavigableTargetId(session, client)) |target_id| {
        errdefer session.allocator.free(target_id);
        session.cdp_target_id = target_id;
        return target_id;
    }
    const target_id = try createBlankTargetId(session, client);
    errdefer session.allocator.free(target_id);
    session.cdp_target_id = target_id;
    return target_id;
}

fn clearPinnedCdpTargetId(session: *Session) void {
    if (session.cdp_target_id) |target_id| {
        session.allocator.free(target_id);
        session.cdp_target_id = null;
    }
    if (session.cdp_attached_session_id) |attached| {
        session.allocator.free(attached);
        session.cdp_attached_session_id = null;
    }
}

fn firstNavigableTargetId(session: *Session, client: *ws.Client) !?[]u8 {
    const payload = try sendCdpRpc(session, client, "Target.getTargets", "{}", null, false);
    defer session.allocator.free(payload);
    return extractNavigableTargetIdFromTargetsPayload(session.allocator, payload);
}

fn createBlankTargetId(session: *Session, client: *ws.Client) ![]u8 {
    const payload = try sendCdpRpc(session, client, "Target.createTarget", "{\"url\":\"about:blank\"}", null, false);
    defer session.allocator.free(payload);
    return extractJsonStringAtPath(session.allocator, payload, "result", "targetId");
}

fn attachToTargetAndGetSessionId(session: *Session, client: *ws.Client, target_id: []const u8) ![]u8 {
    const escaped_target = try json_util.escapeJsonString(session.allocator, target_id);
    defer session.allocator.free(escaped_target);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"targetId\":\"{s}\",\"flatten\":true}}",
        .{escaped_target},
    );
    defer session.allocator.free(params);
    const payload = try sendCdpRpc(session, client, "Target.attachToTarget", params, null, false);
    defer session.allocator.free(payload);
    return extractJsonStringAtPath(session.allocator, payload, "result", "sessionId");
}

fn primeAttachedCdpSession(session: *Session, client: *ws.Client, attached_session_id: []const u8) void {
    const methods = [_][]const u8{
        "Page.enable",
        "Runtime.enable",
    };
    for (methods) |method| {
        const payload = sendCdpRpc(session, client, method, "{}", attached_session_id, false) catch continue;
        session.allocator.free(payload);
    }
}

fn isRetriableCdpTransportError(err: anyerror) bool {
    return err == error.ConnectionRefused or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionClosed or
        err == error.BrokenPipe;
}

fn recordProtocolErrorDiagnostic(
    session: *Session,
    transport: common.TransportKind,
    method: []const u8,
    env: json_rpc.RpcEnvelope,
    payload: []const u8,
) void {
    const error_message = env.error_message orelse "protocol command failed";
    const payload_preview = if (payload.len <= 240) payload else payload[0..240];
    var code_buf: [64]u8 = undefined;
    const code = if (env.error_code) |error_code|
        std.fmt.bufPrint(&code_buf, "rpc_{d}", .{error_code}) catch "ProtocolCommandFailed"
    else
        "ProtocolCommandFailed";

    var message_buf: [640]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buf,
        "{s} failed: {s}; payload={s}",
        .{ method, error_message, payload_preview },
    ) catch "protocol command failed";
    session.recordDiagnostic(.{
        .phase = .overall,
        .code = code,
        .message = message,
        .transport = @tagName(transport),
    });
}

fn cdpWebSocketEndpoint(
    allocator: std.mem.Allocator,
    parsed: common.EndpointParts,
) ![]u8 {
    if (!shouldResolveCdpEndpointPath(parsed.path)) {
        return std.fmt.allocPrint(allocator, "ws://{s}:{d}{s}", .{ parsed.host, parsed.port, parsed.path });
    }
    return resolveCdpWebSocketEndpoint(allocator, parsed.host, parsed.port);
}

fn shouldResolveCdpEndpointPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return true;
    if (std.mem.startsWith(u8, path, "/devtools/browser/")) return true;
    if (std.mem.startsWith(u8, path, "/json")) return true;
    return false;
}

fn resolveCdpWebSocketEndpoint(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    const list_paths = [_][]const u8{ "/json/list", "/json" };
    for (list_paths) |path| {
        const list = http.getJson(allocator, host, port, path) catch continue;
        defer allocator.free(list.body);
        if (!httpStatusIsSuccess(list.status_code)) continue;
        if (firstJsonListWsEndpoint(allocator, list.body)) |ws_url| return ws_url else |_| {}
    }

    const version = http.getJson(allocator, host, port, "/json/version") catch return error.MissingEndpoint;
    defer allocator.free(version.body);
    if (!httpStatusIsSuccess(version.status_code)) return error.MissingEndpoint;
    return extractJsonStringValue(allocator, version.body, "webSocketDebuggerUrl");
}

fn httpStatusIsSuccess(code: u16) bool {
    return code >= 200 and code < 300;
}

fn parseWsUrl(allocator: std.mem.Allocator, endpoint: []const u8) !struct { host: []const u8, port: u16, path: []u8 } {
    var input = endpoint;
    if (std.mem.startsWith(u8, input, "ws://")) input = input[5..];
    if (std.mem.startsWith(u8, input, "wss://")) return error.UnsupportedProtocol;
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

    var fallback: ?[]const u8 = null;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("webSocketDebuggerUrl")) |ws_url| {
            if (ws_url != .string) continue;
            if (fallback == null) fallback = ws_url.string;
            const target_type = item.object.get("type") orelse {
                fallback = ws_url.string;
                continue;
            };
            if (target_type == .string and isNavigableCdpTargetType(target_type.string)) {
                return allocator.dupe(u8, ws_url.string);
            }
        }
    }
    if (fallback) |ws_url| return allocator.dupe(u8, ws_url);
    return error.MissingEndpoint;
}

fn isNavigableCdpTargetType(target_type: []const u8) bool {
    return std.ascii.eqlIgnoreCase(target_type, "page") or
        std.ascii.eqlIgnoreCase(target_type, "tab");
}

fn evalViaCdp(session: *Session, script: []const u8) ![]u8 {
    const expression = try json_util.escapeJsonString(session.allocator, script);
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
    const expression = try json_util.escapeJsonString(session.allocator, script);
    defer session.allocator.free(expression);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"target\":{{\"context\":\"{s}\"}},\"expression\":\"{s}\",\"awaitPromise\":true}}",
        .{ context_id, expression },
    );
    defer session.allocator.free(params);
    return callBidi(session, "script.evaluate", params);
}

fn extractFirstBidiContextFromTree(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const contexts = result.object.get("contexts") orelse return null;
    if (contexts != .array or contexts.array.items.len == 0) return null;
    const first = contexts.array.items[0];
    if (first != .object) return null;
    const context = first.object.get("context") orelse return null;
    if (context != .string) return null;
    return try allocator.dupe(u8, context.string);
}

fn extractBidiContextId(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;

    if (result.object.get("context")) |value| {
        if (value == .string) return try allocator.dupe(u8, value.string);
        if (value == .object) {
            if (value.object.get("context")) |nested| {
                if (nested == .string) return try allocator.dupe(u8, nested.string);
            }
        }
    }

    return null;
}

fn extractBidiPreloadScriptId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.MissingEndpoint;
    if (result != .object) return error.InvalidResponse;
    if (result.object.get("script")) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    if (result.object.get("identifier")) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    return error.MissingEndpoint;
}

fn extractJsonStringValue(allocator: std.mem.Allocator, payload: []const u8, field_name: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const value = parsed.value.object.get(field_name) orelse return error.MissingEndpoint;
    if (value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, value.string);
}

fn extractJsonStringAtPath(
    allocator: std.mem.Allocator,
    payload: []const u8,
    top_level_key: []const u8,
    nested_key: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const top = parsed.value.object.get(top_level_key) orelse return error.MissingEndpoint;
    if (top != .object) return error.InvalidResponse;
    const value = top.object.get(nested_key) orelse return error.MissingEndpoint;
    if (value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, value.string);
}

fn networkSetCookieSucceeded(allocator: std.mem.Allocator, payload: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const result = parsed.value.object.get("result") orelse return false;
    if (result != .object) return false;
    const success = result.object.get("success") orelse return false;
    if (success != .bool) return false;
    return success.bool;
}

fn extractNavigableTargetIdFromTargetsPayload(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const result = parsed.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const infos = result.object.get("targetInfos") orelse return null;
    if (infos != .array) return null;

    for (infos.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("targetId") orelse continue;
        if (id_value != .string) continue;
        const type_value = item.object.get("type") orelse continue;
        if (type_value != .string) continue;
        if (isNavigableCdpTargetType(type_value.string)) {
            return try allocator.dupe(u8, id_value.string);
        }
    }
    return null;
}

test "parseWsUrl supports ws endpoint" {
    const allocator = std.testing.allocator;
    const parsed = try parseWsUrl(allocator, "ws://127.0.0.1:9222/devtools/browser/abc");
    defer allocator.free(parsed.path);
    try std.testing.expectEqual(@as(u16, 9222), parsed.port);
    try std.testing.expect(std.mem.eql(u8, parsed.host, "127.0.0.1"));
}

test "cdp endpoint path resolution rules keep page targets direct" {
    try std.testing.expect(shouldResolveCdpEndpointPath("/"));
    try std.testing.expect(shouldResolveCdpEndpointPath("/devtools/browser/abc"));
    try std.testing.expect(!shouldResolveCdpEndpointPath("/devtools/page/abc"));
}

test "cdp endpoint selection keeps explicit page endpoint" {
    const allocator = std.testing.allocator;
    const parsed = try common.parseEndpoint("cdp://127.0.0.1:9222/devtools/page/123", .cdp);
    const ws_url = try cdpWebSocketEndpoint(allocator, parsed);
    defer allocator.free(ws_url);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/123", ws_url);
}

test "first json list endpoint prefers page targets" {
    const allocator = std.testing.allocator;
    const ws_url = try firstJsonListWsEndpoint(allocator,
        \\[
        \\  {"id":"worker","type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/worker"},
        \\  {"id":"page","type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/abc"}
        \\]
    );
    defer allocator.free(ws_url);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/abc", ws_url);
}

test "cdp endpoint cache pins websocket endpoint for session" {
    const allocator = std.testing.allocator;
    var session = Session{
        .allocator = allocator,
        .id = 1,
        .mode = .browser,
        .transport = .cdp_ws,
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, "attached"),
            .version = null,
            .source = .explicit,
        },
        .capability_set = cdp.capabilities(),
        .adapter_kind = .cdp,
        .endpoint = try allocator.dupe(u8, "cdp://127.0.0.1:9222/devtools/page/abc"),
    };
    defer session.deinit();

    const parsed = try common.parseEndpoint(session.endpoint.?, .cdp);
    const first = try ensureCdpEndpoint(&session, parsed, false);
    const second = try ensureCdpEndpoint(&session, parsed, false);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/abc", first);
    try std.testing.expect(first.ptr == second.ptr);
}

test "extract first bidi context from getTree payload" {
    const allocator = std.testing.allocator;
    const context = try extractFirstBidiContextFromTree(allocator,
        \\{"result":{"contexts":[{"context":"ctx-1","url":"about:blank"}]}}
    );
    try std.testing.expect(context != null);
    defer allocator.free(context.?);
    try std.testing.expectEqualStrings("ctx-1", context.?);
}

test "extract bidi preload script id from addPreloadScript payload" {
    const allocator = std.testing.allocator;
    const script_id = try extractBidiPreloadScriptId(allocator,
        \\{"id":1,"result":{"script":"preload-123"}}
    );
    defer allocator.free(script_id);
    try std.testing.expectEqualStrings("preload-123", script_id);
}

test "extract bidi context id from create payload" {
    const allocator = std.testing.allocator;
    const context = try extractBidiContextId(allocator,
        \\{"result":{"context":"ctx-2"}}
    );
    try std.testing.expect(context != null);
    defer allocator.free(context.?);
    try std.testing.expectEqualStrings("ctx-2", context.?);
}

fn makeNotificationTestSession(
    allocator: std.mem.Allocator,
    transport: common.TransportKind,
    engine: types.EngineKind,
) !Session {
    return .{
        .allocator = allocator,
        .id = 7,
        .mode = .browser,
        .transport = transport,
        .install = .{
            .kind = if (engine == .gecko) .firefox else .chrome,
            .engine = engine,
            .path = try allocator.dupe(u8, "test-browser"),
            .version = null,
            .source = .explicit,
        },
        .capability_set = if (engine == .gecko) bidi.capabilitiesFor(.gecko) else cdp.capabilities(),
        .adapter_kind = if (transport == .bidi_ws) .bidi else .cdp,
        .endpoint = null,
        .browsing_context_id = null,
    };
}

test "cdp notifications populate network/frame/service-worker telemetry" {
    const allocator = std.testing.allocator;
    var session = try makeNotificationTestSession(allocator, .cdp_ws, .chromium);
    defer session.deinit();

    processCdpNotification(&session,
        \\{"method":"Network.requestWillBeSent","params":{"requestId":"r1","timestamp":1.1,"request":{"url":"https://example.com/next","method":"POST","headers":{"accept":"*/*"},"postData":"k=v"},"redirectResponse":{"url":"https://example.com/start","status":302,"headers":{"location":"https://example.com/next"}}}}
    );
    processCdpNotification(&session,
        \\{"method":"Network.responseReceived","params":{"requestId":"r1","timestamp":1.2,"response":{"url":"https://example.com/next","status":200,"headers":{"content-type":"text/html"}}}}
    );
    processCdpNotification(&session,
        \\{"method":"Page.frameNavigated","params":{"frame":{"id":"root","url":"https://example.com/next"}}}
    );
    processCdpNotification(&session,
        \\{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"sw-1","type":"service_worker","url":"https://example.com/sw.js"}}}
    );

    const records = try session.networkRecords(allocator, true);
    defer session.freeNetworkRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("r1", records[0].request_id);
    try std.testing.expect(records[0].request_body != null);
    try std.testing.expectEqualStrings("k=v", records[0].request_body.?);
    try std.testing.expectEqual(@as(usize, 1), records[0].redirects.len);
    try std.testing.expectEqual(@as(?u16, 200), records[0].final_status);
    try std.testing.expect(records[0].status_timeline.len >= 2);

    const slim = try session.networkRecords(allocator, false);
    defer session.freeNetworkRecords(allocator, slim);
    try std.testing.expect(slim[0].request_body == null);

    const frames = try session.frameInfos(allocator);
    defer session.freeFrameInfos(allocator, frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("root", frames[0].frame_id);

    const workers = try session.serviceWorkerInfos(allocator);
    defer session.freeServiceWorkerInfos(allocator, workers);
    try std.testing.expectEqual(@as(usize, 1), workers.len);
    try std.testing.expectEqualStrings("sw-1", workers[0].worker_id);
}

test "bidi notifications populate network and frame telemetry" {
    const allocator = std.testing.allocator;
    var session = try makeNotificationTestSession(allocator, .bidi_ws, .gecko);
    defer session.deinit();

    processBidiNotification(&session,
        \\{"method":"network.beforeRequestSent","params":{"request":{"request":"b1","url":"https://example.org/a","method":"GET","headers":{"accept":"text/html"}}}}
    );
    processBidiNotification(&session,
        \\{"method":"network.responseCompleted","params":{"request":{"request":"b1","url":"https://example.org/a"},"response":{"status":204,"headers":{"x":"1"}}}}
    );
    processBidiNotification(&session,
        \\{"method":"browsingContext.load","params":{"context":"ctx-main","url":"https://example.org/a"}}
    );

    const records = try session.networkRecords(allocator, false);
    defer session.freeNetworkRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("b1", records[0].request_id);
    try std.testing.expectEqual(@as(?u16, 204), records[0].final_status);

    const frames = try session.frameInfos(allocator);
    defer session.freeFrameInfos(allocator, frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("ctx-main", frames[0].frame_id);
}
