const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");
const cdp = @import("cdp/adapter.zig");
const bidi = @import("bidi/adapter.zig");
const ws = @import("../transport/ws_client.zig");
const http = @import("../transport/http_client.zig");
const json_rpc = @import("../transport/json_rpc.zig");
const json_util = @import("../util/json.zig");
const compat = @import("../util/compat.zig");

const Session = @import("../core/session.zig").Session;

pub fn waitUntilReady(session: *Session, timeout_ms: u32) !void {
    if (timeout_ms == 0) return error.Timeout;
    const Result = union(enum) { ready: anyerror!void, timeout: anyerror!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(compat.io(), &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.ready, waitUntilReadyLoop, .{ session, timeout_ms });
    try select.concurrent(.timeout, protocolTimeout, .{timeout_ms});
    switch (try select.await()) {
        .ready => |ready| try ready,
        .timeout => |done| {
            try done;
            return error.Timeout;
        },
    }
}

fn protocolTimeout(timeout_ms: u32) anyerror!void {
    try std.Io.sleep(compat.io(), .fromMilliseconds(timeout_ms), .awake);
}

fn waitUntilReadyLoop(session: *Session, timeout_ms: u32) anyerror!void {
    const started = compat.milliTimestamp();
    const deadline = started + @as(i64, @intCast(timeout_ms));
    var last_error: ?anyerror = null;

    while (compat.milliTimestamp() < deadline) {
        initializeSession(session) catch |err| {
            if (err == error.Canceled) return err;
            last_error = err;
            try std.Io.sleep(compat.io(), .fromMilliseconds(50), .awake);
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
            const raw = try callCdp(session, "Page.navigate", params);
            defer session.allocator.free(raw);
            var parsed = try std.json.parseFromSlice(std.json.Value, session.allocator, raw, .{});
            defer parsed.deinit();
            const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
            if (result != .object) return error.InvalidResponse;
            if (result.object.get("errorText")) |failure| {
                if (failure == .string and failure.string.len > 0) return error.NavigationFailed;
            }
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
    if (session.transport != .cdp_ws) return error.UnsupportedCapability;
    session.input_lock.lock();
    defer session.input_lock.unlock();
    const point = try prepareInputTarget(session, selector, false);
    try dispatchPointer(session, "mouseMoved", point, false);
    session.input_mouse_x = @intFromFloat(point.x);
    session.input_mouse_y = @intFromFloat(point.y);
    try dispatchPointer(session, "mousePressed", point, true);
    // Always attempt release, including a failed first release, to avoid leaving
    // the browser's pointer pressed when transport/protocol errors occur.
    dispatchPointer(session, "mouseReleased", point, false) catch |err| {
        dispatchPointer(session, "mouseReleased", point, false) catch {};
        return err;
    };
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedCapability;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    session.input_lock.lock();
    defer session.input_lock.unlock();
    _ = try prepareInputTarget(session, selector, true);
    // Preserve typeText's replacement contract using the native editing command.
    // Unlike setting .value, this also edits contenteditable and preserves undo.
    try inputCommand(session, "Input.dispatchKeyEvent", "{\"type\":\"rawKeyDown\",\"key\":\"a\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65,\"modifiers\":2,\"commands\":[\"selectAll\"]}");
    try inputCommand(session, "Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"a\",\"code\":\"KeyA\",\"windowsVirtualKeyCode\":65}");
    if (text.len == 0) {
        try inputCommand(session, "Input.dispatchKeyEvent", "{\"type\":\"rawKeyDown\",\"key\":\"Backspace\",\"code\":\"Backspace\",\"windowsVirtualKeyCode\":8}");
        try inputCommand(session, "Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"Backspace\",\"code\":\"Backspace\",\"windowsVirtualKeyCode\":8}");
    } else {
        const escaped = try json_util.escapeJsonString(session.allocator, text);
        defer session.allocator.free(escaped);
        const params = try std.fmt.allocPrint(session.allocator, "{{\"text\":\"{s}\"}}", .{escaped});
        defer session.allocator.free(params);
        try inputCommand(session, "Input.insertText", params);
    }
}

const InputPoint = struct { x: f64, y: f64 };

fn inputCommand(session: *Session, method: []const u8, params: []const u8) !void {
    const response = try callCdp(session, method, params);
    session.allocator.free(response);
}

fn dispatchPointer(session: *Session, kind: []const u8, point: InputPoint, pressed: bool) !void {
    const moving = std.mem.eql(u8, kind, "mouseMoved");
    const params = try std.fmt.allocPrint(session.allocator, "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"buttons\":{d},\"clickCount\":{d},\"modifiers\":{d}}}", .{ kind, point.x, point.y, if (moving) "none" else "left", @as(u8, if (pressed) 1 else 0), @as(u8, if (moving) 0 else 1), session.input_modifiers });
    defer session.allocator.free(params);
    try inputCommand(session, "Input.dispatchMouseEvent", params);
}

fn prepareInputTarget(session: *Session, selector: []const u8, editable: bool) !InputPoint {
    const escaped = try json_util.escapeJsonString(session.allocator, selector);
    defer session.allocator.free(escaped);
    // Return explicit failures instead of hiding browser-side exceptions. Test
    // several points in every visible fragment so inline and partly covered
    // controls remain actionable when their rectangle centre is obstructed.
    const script = try std.fmt.allocPrint(session.allocator,
        \\(function() {{
        \\  let el;
        \\  try {{ el = document.querySelector("{s}"); }} catch (_) {{ return {{error:'selector'}}; }}
        \\  if (!el) return {{error:'missing'}};
        \\  if (el.matches(':disabled') || el.closest('[inert]')) return {{error:'disabled'}};
        \\  if ({s} && (el.readOnly || !(el.isContentEditable || el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && ['text','search','email','url','tel','password','number'].includes(el.type))))) return {{error:'editable'}};
        \\  el.scrollIntoView({{block:'center',inline:'center',behavior:'instant'}});
        \\  const style = getComputedStyle(el);
        \\  if (style.visibility !== 'visible' || style.display === 'none') return {{error:'hidden'}};
        \\  let point = null, visible = false;
        \\  for (const rect of el.getClientRects()) {{
        \\    const left = Math.max(0,rect.left), right = Math.min(innerWidth,rect.right);
        \\    const top = Math.max(0,rect.top), bottom = Math.min(innerHeight,rect.bottom);
        \\    if (right <= left || bottom <= top) continue;
        \\    visible = true;
        \\    for (const [fx,fy] of [[.5,.5],[.25,.25],[.75,.25],[.25,.75],[.75,.75]]) {{
        \\      const x = left+(right-left)*fx, y = top+(bottom-top)*fy;
        \\      const hit = document.elementFromPoint(x,y);
        \\      if (hit && (hit === el || el.contains(hit))) {{ point = {{x,y}}; break; }}
        \\    }}
        \\    if (point) break;
        \\  }}
        \\  if (!point) return {{error:visible?'occluded':'hidden'}};
        \\  if ({s}) {{ el.focus({{preventScroll:true}}); if (document.activeElement !== el) return {{error:'focus'}}; }}
        \\  return point;
        \\}})()
    , .{ escaped, if (editable) "true" else "false", if (editable) "true" else "false" });
    defer session.allocator.free(script);
    const raw = try evaluate(session, script);
    defer session.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, session.allocator, raw, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const remote = result.object.get("result") orelse return error.InvalidResponse;
    if (remote != .object) return error.InvalidResponse;
    const value = remote.object.get("value") orelse return error.InvalidResponse;
    if (value != .object) return error.InvalidResponse;
    if (value.object.get("error")) |failure| {
        if (failure != .string) return error.InvalidResponse;
        const reason = failure.string;
        if (std.mem.eql(u8, reason, "selector")) return error.InvalidSelector;
        if (std.mem.eql(u8, reason, "missing")) return error.ElementNotFound;
        if (std.mem.eql(u8, reason, "disabled")) return error.ElementDisabled;
        if (std.mem.eql(u8, reason, "editable")) return error.ElementNotEditable;
        if (std.mem.eql(u8, reason, "hidden")) return error.ElementNotVisible;
        if (std.mem.eql(u8, reason, "occluded")) return error.ElementOccluded;
        if (std.mem.eql(u8, reason, "focus")) return error.ElementNotFocusable;
        return error.InvalidResponse;
    }
    return .{
        .x = try inputCoordinate(value.object.get("x") orelse return error.InvalidResponse),
        .y = try inputCoordinate(value.object.get("y") orelse return error.InvalidResponse),
    };
}

fn inputCoordinate(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => error.InvalidResponse,
    };
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
    const deadline = compat.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const res = try evaluate(session, "document.readyState");
        defer session.allocator.free(res);
        if (std.mem.indexOf(u8, res, "complete") != null) return;
        if (compat.milliTimestamp() >= deadline) return error.Timeout;
        compat.sleepMs(50);
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

    const deadline = compat.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const res = try evaluate(session, expr);
        defer session.allocator.free(res);
        if (std.mem.indexOf(u8, res, "true") != null) return;
        if (compat.milliTimestamp() >= deadline) return error.Timeout;
        compat.sleepMs(50);
    }
}

pub fn setCookie(session: *Session, cookie: types.Header, domain: []const u8, path: []const u8) !void {
    return setCookieFull(session, .{ .name = cookie.name, .value = cookie.value, .domain = domain, .path = path });
}

pub fn setCookieFull(session: *Session, cookie: types.Cookie) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const same_site: ?[]const u8 = switch (cookie.same_site) {
        .strict => "Strict",
        .lax => "Lax",
        .none => "None",
        .unspecified => null,
    };
    const params = try std.json.Stringify.valueAlloc(session.allocator, .{
        .name = cookie.name,
        .value = cookie.value,
        .domain = cookie.domain,
        .path = cookie.path,
        .secure = cookie.secure,
        .httpOnly = cookie.http_only,
        .sameSite = same_site,
        .expires = cookie.expires_unix_seconds,
    }, .{ .emit_null_optional_fields = false });
    defer session.allocator.free(params);
    const raw = try callCdp(session, "Network.setCookie", params);
    defer session.allocator.free(raw);
    if (!networkSetCookieSucceeded(session.allocator, raw)) return error.ProtocolCommandFailed;
}

pub fn getCookies(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    // Queries and cookie-header exports can target another origin or path.
    // Network.getCookies without explicit URLs only sees the current page.
    return callCdp(session, "Storage.getCookies", "{}");
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
    return screenshotWithFormat(session, "png");
}

pub fn screenshotWithFormat(session: *Session, format: []const u8) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    if (!std.mem.eql(u8, format, "png") and !std.mem.eql(u8, format, "jpeg")) return error.InvalidScreenshotFormat;
    const params = try std.fmt.allocPrint(session.allocator, "{{\"format\":\"{s}\"}}", .{format});
    defer session.allocator.free(params);
    return callCdp(session, "Page.captureScreenshot", params);
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
    return @import("tracing.zig").start(session);
}

pub fn stopTracing(session: *Session) ![]u8 {
    return @import("tracing.zig").stop(session);
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
    try syncNetworkRules(session);
}

pub fn disableNetworkInterception(session: *Session) !void {
    if (session.interceptor) |worker| {
        worker.destroy();
        session.interceptor = null;
    }
}

pub fn addNetworkRule(session: *Session, rule: types.NetworkRule) !void {
    const combined = try session.allocator.alloc(types.NetworkRule, session.rules.items.len + 1);
    defer session.allocator.free(combined);
    @memcpy(combined[0..session.rules.items.len], session.rules.items);
    combined[combined.len - 1] = rule;
    try installNetworkRules(session, combined);
}

pub fn syncNetworkRules(session: *Session) !void {
    try installNetworkRules(session, session.rules.items);
}

fn installNetworkRules(session: *Session, rules: []const types.NetworkRule) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    if (session.interceptor) |worker| return worker.syncRules(rules);
    const page_endpoint = try pageWebSocketEndpoint(session);
    defer session.allocator.free(page_endpoint);
    session.interceptor = try @import("interceptor.zig").Interceptor.create(session.allocator, page_endpoint, rules);
}

/// Returns an owned endpoint for a dedicated observer of this session's page.
pub fn pageWebSocketEndpoint(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const ping = try callCdp(session, "Page.getFrameTree", "{}");
    session.allocator.free(ping);
    const endpoint = session.cdp_ws_endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    if (!cdpPathNeedsTargetSession(parsed.path)) return session.allocator.dupe(u8, endpoint);
    const target = session.cdp_target_id orelse return error.MissingTarget;
    const authority = try common.formatHostPortAuthority(session.allocator, parsed.host, parsed.port);
    defer session.allocator.free(authority);
    return std.fmt.allocPrint(session.allocator, "ws://{s}/devtools/page/{s}", .{ authority, target });
}

/// Returns an owned browser endpoint for browser-wide CDP events.
pub fn browserWebSocketEndpoint(session: *Session) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const endpoint = session.endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    if (std.mem.startsWith(u8, parsed.path, "/devtools/browser/")) {
        const authority = try common.formatHostPortAuthority(session.allocator, parsed.host, parsed.port);
        defer session.allocator.free(authority);
        return std.fmt.allocPrint(session.allocator, "ws://{s}{s}", .{ authority, parsed.path });
    }
    const response = try http.requestJsonWithOptions(session.allocator, parsed.host, parsed.port, .GET, "/json/version", null, .{ .timeout_ms = session.timeout_policy.network_ms });
    defer session.allocator.free(response.body);
    if (!httpStatusIsSuccess(response.status_code)) return error.MissingEndpoint;
    return extractJsonStringValue(session.allocator, response.body, "webSocketDebuggerUrl");
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

/// Select exactly the requested target, staging a complete replacement before
/// releasing the old connection. Explicit page connections are promoted to the
/// browser endpoint so future target-scoped commands follow this selection.
pub fn selectTarget(session: *Session, target_id: []const u8) !void {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    if (session.cdp_target_id) |current| {
        if (std.mem.eql(u8, current, target_id) and session.cdp_attached_session_id != null and session.network_tracking_valid) return;
    }
    const allocator = session.allocator;
    const endpoint = try browserWebSocketEndpoint(session);
    errdefer allocator.free(endpoint);
    const cached_endpoint = try allocator.dupe(u8, endpoint);
    errdefer allocator.free(cached_endpoint);
    const owned_target = try allocator.dupe(u8, target_id);
    errdefer allocator.free(owned_target);
    const parts = try common.parseEndpoint(endpoint, .cdp);
    var client = try ws.Client.connectWithTimeout(allocator, parts.host, parts.port, parts.path, session.timeout_policy.network_ms);
    errdefer client.deinit();
    var queued: std.ArrayList([]u8) = .empty;
    defer freeQueuedNotifications(allocator, &queued);

    session.network_observer_lock.lock();
    var network_locked = true;
    defer if (network_locked) session.network_observer_lock.unlock();
    session.protocol_lock.lock();
    var locked = true;
    defer if (locked) session.protocol_lock.unlock();
    const attached = try attachToTargetAndGetSessionId(session, &client, target_id, &queued);
    errdefer allocator.free(attached);
    for ([_][]const u8{ "Page.enable", "Runtime.enable", "Network.enable" }) |method| {
        const response = try sendCdpRpcTracking(session, &client, method, "{}", attached, true, &queued, false);
        allocator.free(response);
    }
    const authority = try common.formatHostPortAuthority(allocator, parts.host, parts.port);
    defer allocator.free(authority);
    const page_endpoint = try std.fmt.allocPrint(allocator, "ws://{s}/devtools/page/{s}", .{ authority, target_id });
    defer allocator.free(page_endpoint);
    var observer: ?*@import("../core/log.zig").Observer = null;
    var console_callback: ?@import("../core/log.zig").Callback = null;
    var exception_callback: ?@import("../core/log.zig").Callback = null;
    errdefer if (observer) |value| value.destroy();
    if (session.log_observer) |old| {
        observer = try @import("../core/log.zig").Observer.create(allocator, page_endpoint);
        old.mutex.lock();
        console_callback = old.console_callback;
        exception_callback = old.exception_callback;
        old.mutex.unlock();
        if (observer.?.lastError()) |failure| return failure;
    }
    var interceptor: ?*@import("interceptor.zig").Interceptor = null;
    errdefer if (interceptor) |value| value.destroy();
    if (session.interceptor != null or session.rules.items.len > 0) {
        interceptor = try @import("interceptor.zig").Interceptor.create(allocator, page_endpoint, session.rules.items);
    }
    const network_log = @import("../core/network_observer.zig");
    var network_observer: ?*network_log.Observer = null;
    errdefer if (network_observer) |value| value.destroy();
    var network_callbacks: network_log.Callbacks = .{ .request = session.on_request, .response = session.on_response, .raw = session.on_network_raw };
    if (session.network_observer) |old| {
        old.mutex.lock();
        network_callbacks = old.callbacks;
        old.mutex.unlock();
    }
    if (session.network_observer != null or network_callbacks.request != null or network_callbacks.response != null or network_callbacks.raw != null) {
        network_observer = try network_log.Observer.create(allocator, page_endpoint, .{});
        try network_observer.?.check();
    }

    const old_observer = session.log_observer;
    const old_interceptor = session.interceptor;
    const old_network_observer = session.network_observer;
    // Closing a browser connection detaches all its target sessions.
    clearCdpEndpointCache(session);
    if (session.endpoint) |old| allocator.free(old);
    session.endpoint = endpoint;
    session.cdp_ws_endpoint = cached_endpoint;
    session.cdp_target_id = owned_target;
    session.cdp_attached_session_id = attached;
    session.cdp_client = client;
    session.log_observer = observer;
    session.interceptor = interceptor;
    session.network_observer = network_observer;
    if (network_observer) |value| {
        value.mutex.lock();
        value.callbacks = network_callbacks;
        value.mutex.unlock();
    }
    if (observer) |value| {
        value.mutex.lock();
        value.console_callback = console_callback;
        value.exception_callback = exception_callback;
        value.mutex.unlock();
    }
    session.state_lock.lock();
    if (session.current_url) |old| allocator.free(old);
    session.current_url = null;
    session.state_lock.unlock();
    clearNetworkActivity(session);
    for (queued.items) |notification| trackCdpNetworkNotification(session, notification);
    session.protocol_lock.unlock();
    locked = false;
    session.network_observer_lock.unlock();
    network_locked = false;
    if (old_observer) |old| old.destroy();
    if (old_interceptor) |old| old.destroy();
    if (old_network_observer) |old| old.destroy();
    processQueuedCdpNotifications(session, queued.items);
}

/// Forget only the active target after a successful detach or close. Retain log
/// callbacks in their stopped observer so the next explicit selection rebinds them.
pub fn clearSelectedTarget(session: *Session) void {
    session.network_observer_lock.lock();
    const old_network_observer = session.network_observer;
    session.network_observer = null;
    session.network_observer_lock.unlock();
    if (old_network_observer) |observer| observer.destroy();
    if (session.log_observer) |observer| {
        if (observer.worker) |*worker| _ = worker.cancel(compat.io()) catch {};
        observer.worker = null;
        observer.client.stream.shutdown(compat.io(), .both) catch {};
    }
    if (session.interceptor) |worker| worker.destroy();
    session.interceptor = null;
    session.protocol_lock.lock();
    defer session.protocol_lock.unlock();
    clearCdpEndpointCache(session);
    session.state_lock.lock();
    defer session.state_lock.unlock();
    if (session.current_url) |url| session.allocator.free(url);
    session.current_url = null;
    clearNetworkActivity(session);
}

pub fn callCdp(session: *Session, method: []const u8, params_json: ?[]const u8) ![]u8 {
    const budget = if (std.mem.eql(u8, method, "Page.navigate") or std.mem.eql(u8, method, "Page.reload")) session.timeout_policy.navigate_ms else session.timeout_policy.network_ms;
    return callCdpWithTimeout(session, method, params_json, budget);
}

pub fn callCdpWithTimeout(session: *Session, method: []const u8, params_json: ?[]const u8, budget: u32) ![]u8 {
    if (budget == 0) return error.Timeout;
    const Result = union(enum) { response: anyerror![]u8, timeout: anyerror!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(compat.io(), &buffer);
    defer while (select.cancel()) |result| {
        switch (result) {
            .response => |response| if (response) |payload| {
                session.allocator.free(payload);
            } else |_| {},
            .timeout => {},
        }
    };
    try select.concurrent(.response, callCdpBlocking, .{ session, method, params_json });
    try select.concurrent(.timeout, protocolTimeout, .{budget});
    return switch (try select.await()) {
        .response => |response| response,
        .timeout => |done| {
            try done;
            return error.Timeout;
        },
    };
}

pub fn callCdpCancelable(session: *Session, method: []const u8, params_json: ?[]const u8, timeout_ms: u32, token: ?*const @import("../core/cancel.zig").CancelToken) ![]u8 {
    const cancel_token = token orelse return callCdpWithTimeout(session, method, params_json, timeout_ms);
    if (cancel_token.isCanceled()) return error.Canceled;
    const Result = union(enum) { response: anyerror![]u8, canceled: anyerror!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(compat.io(), &buffer);
    defer while (select.cancel()) |result| {
        switch (result) {
            .response => |response| if (response) |payload| {
                session.allocator.free(payload);
            } else |_| {},
            .canceled => {},
        }
    };
    try select.concurrent(.response, callCdpWithTimeout, .{ session, method, params_json, timeout_ms });
    try select.concurrent(.canceled, watchCancelToken, .{cancel_token});
    return switch (try select.await()) {
        .response => |response| response,
        .canceled => |canceled| {
            try canceled;
            return error.Canceled;
        },
    };
}

fn callCdpBlocking(session: *Session, method: []const u8, params_json: ?[]const u8) anyerror![]u8 {
    var queued_notifications: std.ArrayList([]u8) = .empty;
    defer freeQueuedNotifications(session.allocator, &queued_notifications);

    try session.protocol_lock.inner.lock(compat.io());
    defer {
        session.protocol_lock.unlock();
        processQueuedCdpNotifications(session, queued_notifications.items);
    }
    const endpoint = session.endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    if (parsed.adapter != .cdp) return error.UnsupportedProtocol;

    const payload = callCdpOnce(session, parsed, method, params_json, false, &queued_notifications) catch |err| {
        // A lost response does not prove that the browser did not execute the
        // command. Replaying a click, navigation or script can duplicate effects.
        if (isRetriableCdpTransportError(err) or err == error.Timeout or err == error.Canceled or
            (if (session.cdp_client) |client| client.failed else false)) clearCdpConnection(session);
        return err;
    };
    return payload;
}

fn callCdpOnce(
    session: *Session,
    parsed: common.EndpointParts,
    method: []const u8,
    params_json: ?[]const u8,
    force_refresh_endpoint: bool,
    queued_notifications: *std.ArrayList([]u8),
) ![]u8 {
    const ws_endpoint = try ensureCdpEndpoint(session, parsed, force_refresh_endpoint);
    const ws_parts = try parseWsUrl(session.allocator, ws_endpoint);
    defer session.allocator.free(ws_parts.path);
    const client = try ensurePersistentCdpClient(session, ws_parts.host, ws_parts.port, ws_parts.path);
    const routed_session_id = try prepareCdpRoutingSessionId(session, client, ws_parts.path, method, queued_notifications);
    return sendCdpRpc(session, client, method, params_json, routed_session_id, true, queued_notifications);
}

fn callBidi(session: *Session, method: []const u8, params_json: ?[]const u8) ![]u8 {
    var queued_notifications: std.ArrayList([]u8) = .empty;
    defer freeQueuedNotifications(session.allocator, &queued_notifications);

    session.protocol_lock.lock();
    var lock_held = true;
    defer if (lock_held) session.protocol_lock.unlock();
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
        var env = json_rpc.decodeEnvelope(session.allocator, payload) catch |err| {
            session.allocator.free(payload);
            client.failed = true;
            return err;
        };
        defer env.deinit(session.allocator);
        if (env.id == null or env.id.? != id) {
            if (env.id == null) {
                queueNotificationPayload(session.allocator, &queued_notifications, payload) catch {};
            }
            session.allocator.free(payload);
            continue;
        }
        if (env.has_error) {
            recordProtocolErrorDiagnostic(session, .bidi_ws, method, env, payload);
            session.allocator.free(payload);
            return error.ProtocolCommandFailed;
        }
        session.protocol_lock.unlock();
        lock_held = false;
        processQueuedBidiNotifications(session, queued_notifications.items);
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
        session.cdp_ws_endpoint = try cdpWebSocketEndpointWithTimeout(session.allocator, parsed, session.timeout_policy.network_ms);
    }
    return session.cdp_ws_endpoint.?;
}

fn clearCdpEndpointCache(session: *Session) void {
    clearCdpConnection(session);
    clearPinnedCdpTargetId(session);
}

fn clearCdpConnection(session: *Session) void {
    if (session.cdp_client != null) {
        session.network_lock.lock();
        session.network_tracking_valid = false;
        session.network_lock.unlock();
    }
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
}

fn ensurePersistentCdpClient(
    session: *Session,
    host: []const u8,
    port: u16,
    path: []const u8,
) !*ws.Client {
    if (session.cdp_client) |*client| return client;
    session.cdp_client = try ws.Client.connectWithTimeout(session.allocator, host, port, path, session.timeout_policy.network_ms);
    return &session.cdp_client.?;
}

fn sendCdpRpc(
    session: *Session,
    client: *ws.Client,
    method: []const u8,
    params_json: ?[]const u8,
    routed_session_id: ?[]const u8,
    record_error_diagnostic: bool,
    queued_notifications: *std.ArrayList([]u8),
) ![]u8 {
    return sendCdpRpcTracking(session, client, method, params_json, routed_session_id, record_error_diagnostic, queued_notifications, true);
}

fn sendCdpRpcTracking(
    session: *Session,
    client: *ws.Client,
    method: []const u8,
    params_json: ?[]const u8,
    routed_session_id: ?[]const u8,
    record_error_diagnostic: bool,
    queued_notifications: *std.ArrayList([]u8),
    track_network_activity: bool,
) ![]u8 {
    const budget = if (std.mem.eql(u8, method, "Page.navigate") or std.mem.eql(u8, method, "Page.reload"))
        session.timeout_policy.navigate_ms
    else
        session.timeout_policy.network_ms;
    const deadline = compat.milliTimestamp() + @as(i64, budget);
    const previous_timeout = client.receive_timeout_ms;
    defer client.receive_timeout_ms = previous_timeout;
    const previous_send_timeout = client.send_timeout_ms;
    client.send_timeout_ms = budget;
    defer client.send_timeout_ms = previous_send_timeout;
    const id = session.nextRequestId();
    const request = try encodeCdpRequest(session.allocator, id, method, params_json, routed_session_id);
    defer session.allocator.free(request);
    try client.sendText(request);

    while (true) {
        const remaining = deadline - compat.milliTimestamp();
        if (remaining <= 0) return error.Timeout;
        client.receive_timeout_ms = @intCast(remaining);
        const payload = try client.recvText(session.allocator);
        var env = json_rpc.decodeEnvelope(session.allocator, payload) catch |err| {
            session.allocator.free(payload);
            client.failed = true;
            return err;
        };
        defer env.deinit(session.allocator);
        if (env.id == null or env.id.? != id) {
            if (env.id == null) {
                if (track_network_activity) trackCdpNetworkNotification(session, payload);
                queueNotificationPayload(session.allocator, queued_notifications, payload) catch |err| {
                    session.allocator.free(payload);
                    client.failed = true;
                    return err;
                };
            }
            session.allocator.free(payload);
            continue;
        }
        if (env.has_error) {
            if (record_error_diagnostic) {
                recordProtocolErrorDiagnostic(session, .cdp_ws, method, env, payload);
            }
            session.allocator.free(payload);
            if (env.error_message) |message| {
                if (std.mem.eql(u8, message, "Not attached to an active page")) return error.PageNotActive;
            }
            return error.ProtocolCommandFailed;
        }
        return payload;
    }
}

fn processCdpNotification(session: *Session, payload: []const u8) void {
    processCdpNotificationWithTracking(session, payload, true);
}

fn processCdpNotificationWithTracking(session: *Session, payload: []const u8, track_activity: bool) void {
    if (track_activity) trackCdpNetworkNotification(session, payload);
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method_value = parsed.value.object.get("method") orelse return;
    if (method_value != .string) return;
    const method = method_value.string;
    const params_value = parsed.value.object.get("params") orelse return;
    if (params_value != .object) return;
    const params = params_value.object;

    if (std.mem.eql(u8, method, "Network.loadingFinished") or std.mem.eql(u8, method, "Network.loadingFailed")) {
        return;
    }

    if (std.mem.eql(u8, method, "Tracing.tracingComplete")) {
        session.state_lock.lock();
        defer session.state_lock.unlock();
        if (jsonObjectString(params, "stream")) |handle| {
            if (session.trace_stream) |old| session.allocator.free(old);
            session.trace_stream = session.allocator.dupe(u8, handle) catch null;
        }
        if (params.get("dataLossOccurred")) |loss| {
            session.trace_data_loss = loss == .bool and loss.bool;
        }
        return;
    }

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

// Runs in receipt order under the primary connection lock. Deferred callbacks
// may reenter the driver, so they must not replay this bookkeeping afterward.
fn trackCdpNetworkNotification(session: *Session, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, session.allocator, payload, .{}) catch {
        session.network_lock.lock();
        session.network_tracking_valid = false;
        session.network_lock.unlock();
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method = jsonObjectString(parsed.value.object, "method") orelse return;
    const params = parsed.value.object.get("params") orelse return;
    if (params != .object) return;
    if (std.mem.eql(u8, method, "Network.requestWillBeSent")) beginNetworkRequest(session, params.object) else if (std.mem.eql(u8, method, "Network.loadingFinished") or std.mem.eql(u8, method, "Network.loadingFailed")) finishNetworkRequest(session, params.object);
}

fn beginNetworkRequest(session: *Session, params: std.json.ObjectMap) void {
    const request_id = jsonObjectString(params, "requestId") orelse return;
    session.network_lock.lock();
    defer session.network_lock.unlock();
    session.network_last_activity_ms = compat.milliTimestamp();
    if (session.network_inflight.contains(request_id)) return;
    const key = session.allocator.dupe(u8, request_id) catch {
        session.network_tracking_valid = false;
        return;
    };
    session.network_inflight.put(session.allocator, key, {}) catch {
        session.allocator.free(key);
        session.network_tracking_valid = false;
        return;
    };
}

fn finishNetworkRequest(session: *Session, params: std.json.ObjectMap) void {
    const request_id = jsonObjectString(params, "requestId") orelse return;
    session.network_lock.lock();
    defer session.network_lock.unlock();
    session.network_last_activity_ms = compat.milliTimestamp();
    if (session.network_inflight.fetchRemove(request_id)) |entry| session.allocator.free(entry.key);
}

fn clearNetworkActivity(session: *Session) void {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    var keys = session.network_inflight.keyIterator();
    while (keys.next()) |key| session.allocator.free(key.*);
    session.network_inflight.clearRetainingCapacity();
    session.network_last_activity_ms = compat.milliTimestamp();
    session.network_tracking_valid = true;
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
    if (std.mem.eql(u8, method, "network.responseCompleted")) {
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
    if (jsonObjectString(frame, "parentId") == null) {
        updateCurrentUrl(session, url);
    }
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
    if (session.browsing_context_id == null or std.mem.eql(u8, session.browsing_context_id.?, context)) {
        updateCurrentUrl(session, url);
    }
}

fn updateCurrentUrl(session: *Session, url: []const u8) void {
    session.state_lock.lock();
    defer session.state_lock.unlock();
    if (session.current_url) |old| session.allocator.free(old);
    session.current_url = session.allocator.dupe(u8, url) catch null;
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
    const ts = compat.milliTimestamp();
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
    queued_notifications: *std.ArrayList([]u8),
) !?[]const u8 {
    if (!cdpPathNeedsTargetSession(ws_path)) return null;
    if (!cdpMethodNeedsTargetSession(method)) return null;
    return try createAttachedCdpSession(session, client, queued_notifications);
}

fn cdpPathNeedsTargetSession(path: []const u8) bool {
    return std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/devtools/browser/");
}

fn cdpMethodNeedsTargetSession(method: []const u8) bool {
    if (std.mem.startsWith(u8, method, "Browser.")) return false;
    if (std.mem.startsWith(u8, method, "Target.")) return false;
    return true;
}

fn createAttachedCdpSession(
    session: *Session,
    client: *ws.Client,
    queued_notifications: *std.ArrayList([]u8),
) ![]const u8 {
    if (session.cdp_attached_session_id) |attached| return attached;
    const target_id = try ensurePinnedCdpTargetId(session, client, queued_notifications);
    const attached_session_id = try attachToTargetAndGetSessionId(session, client, target_id, queued_notifications);
    session.cdp_attached_session_id = attached_session_id;
    try primeAttachedCdpSession(session, client, attached_session_id, queued_notifications);
    return attached_session_id;
}

fn ensurePinnedCdpTargetId(
    session: *Session,
    client: *ws.Client,
    queued_notifications: *std.ArrayList([]u8),
) ![]const u8 {
    if (session.cdp_target_id) |target_id| return target_id;
    if (try firstNavigableTargetId(session, client, queued_notifications)) |target_id| {
        errdefer session.allocator.free(target_id);
        session.cdp_target_id = target_id;
        return target_id;
    }
    const target_id = try createBlankTargetId(session, client, queued_notifications);
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

fn firstNavigableTargetId(
    session: *Session,
    client: *ws.Client,
    queued_notifications: *std.ArrayList([]u8),
) !?[]u8 {
    const payload = try sendCdpRpc(session, client, "Target.getTargets", "{}", null, false, queued_notifications);
    defer session.allocator.free(payload);
    return extractNavigableTargetIdFromTargetsPayload(session.allocator, payload);
}

fn createBlankTargetId(
    session: *Session,
    client: *ws.Client,
    queued_notifications: *std.ArrayList([]u8),
) ![]u8 {
    const payload = try sendCdpRpc(session, client, "Target.createTarget", "{\"url\":\"about:blank\"}", null, false, queued_notifications);
    defer session.allocator.free(payload);
    return extractJsonStringAtPath(session.allocator, payload, "result", "targetId");
}

fn attachToTargetAndGetSessionId(
    session: *Session,
    client: *ws.Client,
    target_id: []const u8,
    queued_notifications: *std.ArrayList([]u8),
) ![]u8 {
    const escaped_target = try json_util.escapeJsonString(session.allocator, target_id);
    defer session.allocator.free(escaped_target);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"targetId\":\"{s}\",\"flatten\":true}}",
        .{escaped_target},
    );
    defer session.allocator.free(params);
    const payload = try sendCdpRpc(session, client, "Target.attachToTarget", params, null, false, queued_notifications);
    defer session.allocator.free(payload);
    return extractJsonStringAtPath(session.allocator, payload, "result", "sessionId");
}

fn primeAttachedCdpSession(
    session: *Session,
    client: *ws.Client,
    attached_session_id: []const u8,
    queued_notifications: *std.ArrayList([]u8),
) !void {
    const methods = [_][]const u8{
        "Page.enable",
        "Runtime.enable",
        "Network.enable",
    };
    for (methods) |method| {
        const payload = sendCdpRpc(session, client, method, "{}", attached_session_id, false, queued_notifications) catch |err| {
            if (err == error.ProtocolCommandFailed) continue;
            return err;
        };
        session.allocator.free(payload);
    }
}

fn queueNotificationPayload(
    allocator: std.mem.Allocator,
    queued_notifications: *std.ArrayList([]u8),
    payload: []const u8,
) !void {
    const copy = try allocator.dupe(u8, payload);
    errdefer allocator.free(copy);
    try queued_notifications.append(allocator, copy);
}

fn freeQueuedNotifications(allocator: std.mem.Allocator, queued_notifications: *std.ArrayList([]u8)) void {
    for (queued_notifications.items) |payload| allocator.free(payload);
    queued_notifications.deinit(allocator);
}

fn processQueuedCdpNotifications(session: *Session, queued_notifications: []const []const u8) void {
    for (queued_notifications) |payload| {
        processCdpNotificationWithTracking(session, payload, false);
    }
}

fn processQueuedBidiNotifications(session: *Session, queued_notifications: []const []u8) void {
    for (queued_notifications) |payload| {
        processBidiNotification(session, payload);
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
    return cdpWebSocketEndpointWithTimeout(allocator, parsed, 30_000);
}

fn cdpWebSocketEndpointWithTimeout(allocator: std.mem.Allocator, parsed: common.EndpointParts, timeout_ms: u32) ![]u8 {
    if (!shouldResolveCdpEndpointPath(parsed.path)) {
        const authority = try common.formatHostPortAuthority(allocator, parsed.host, parsed.port);
        defer allocator.free(authority);
        return std.fmt.allocPrint(allocator, "ws://{s}{s}", .{ authority, parsed.path });
    }
    return resolveCdpWebSocketEndpoint(allocator, parsed.host, parsed.port, timeout_ms);
}

fn shouldResolveCdpEndpointPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return true;
    if (std.mem.startsWith(u8, path, "/json")) return true;
    return false;
}

fn resolveCdpWebSocketEndpoint(allocator: std.mem.Allocator, host: []const u8, port: u16, timeout_ms: u32) ![]u8 {
    const deadline = compat.milliTimestamp() + @as(i64, timeout_ms);
    const version = try http.requestJsonWithOptions(allocator, host, port, .GET, "/json/version", null, .{ .timeout_ms = timeout_ms });
    defer allocator.free(version.body);
    if (httpStatusIsSuccess(version.status_code)) {
        if (extractJsonStringValue(allocator, version.body, "webSocketDebuggerUrl")) |endpoint| return endpoint else |_| {}
    }
    const list_paths = [_][]const u8{ "/json/list", "/json" };
    for (list_paths) |path| {
        const remaining = deadline - compat.milliTimestamp();
        if (remaining <= 0) return error.Timeout;
        const list = http.requestJsonWithOptions(allocator, host, port, .GET, path, null, .{ .timeout_ms = @intCast(remaining) }) catch |err| {
            if (err == error.Canceled or err == error.Timeout) return err;
            continue;
        };
        defer allocator.free(list.body);
        if (!httpStatusIsSuccess(list.status_code)) continue;
        if (firstJsonListWsEndpoint(allocator, list.body)) |ws_url| return ws_url else |_| {}
    }

    return error.MissingEndpoint;
}

fn httpStatusIsSuccess(code: u16) bool {
    return code >= 200 and code < 300;
}

fn parseWsUrl(allocator: std.mem.Allocator, endpoint: []const u8) !struct { host: []const u8, port: u16, path: []u8 } {
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    return .{
        .host = parsed.host,
        .port = parsed.port,
        .path = try allocator.dupe(u8, parsed.path),
    };
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
    return evaluateWithTimeout(session, script, session.timeout_policy.network_ms);
}

pub fn evaluateWithTimeout(session: *Session, script: []const u8, timeout_ms: u32) ![]u8 {
    if (session.transport != .cdp_ws) return error.UnsupportedProtocol;
    const expression = try json_util.escapeJsonString(session.allocator, script);
    defer session.allocator.free(expression);
    const params = try std.fmt.allocPrint(
        session.allocator,
        "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}",
        .{expression},
    );
    defer session.allocator.free(params);
    const raw = try callCdpWithTimeout(session, "Runtime.evaluate", params, timeout_ms);
    errdefer session.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, session.allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    if (result.object.contains("exceptionDetails")) return error.JavaScriptException;
    return raw;
}

pub fn evaluateCancelable(session: *Session, script: []const u8, timeout_ms: u32, token: ?*const @import("../core/cancel.zig").CancelToken) ![]u8 {
    const cancel_token = token orelse return evaluateWithTimeout(session, script, timeout_ms);
    if (cancel_token.isCanceled()) return error.Canceled;
    const Result = union(enum) { response: anyerror![]u8, canceled: anyerror!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(compat.io(), &buffer);
    defer while (select.cancel()) |result| {
        switch (result) {
            .response => |response| if (response) |payload| {
                session.allocator.free(payload);
            } else |_| {},
            .canceled => {},
        }
    };
    try select.concurrent(.response, evaluateWithTimeout, .{ session, script, timeout_ms });
    try select.concurrent(.canceled, watchCancelToken, .{cancel_token});
    return switch (try select.await()) {
        .response => |response| response,
        .canceled => |canceled| {
            try canceled;
            return error.Canceled;
        },
    };
}

fn watchCancelToken(token: *const @import("../core/cancel.zig").CancelToken) anyerror!void {
    const mutable = @constCast(token);
    while (true) {
        try mutable.mutex.inner.lock(compat.io());
        const canceled = mutable.canceled;
        mutable.mutex.unlock();
        if (canceled) return error.Canceled;
        try std.Io.sleep(compat.io(), .fromMilliseconds(10), .awake);
    }
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

test "parseWsUrl supports bracketed IPv6 endpoint" {
    const allocator = std.testing.allocator;
    const parsed = try parseWsUrl(allocator, "ws://[::1]:9222/devtools/browser/abc");
    defer allocator.free(parsed.path);
    try std.testing.expectEqualStrings("::1", parsed.host);
    try std.testing.expectEqual(@as(u16, 9222), parsed.port);
}

test "cdp endpoint path resolution rules keep page targets direct" {
    try std.testing.expect(shouldResolveCdpEndpointPath("/"));
    try std.testing.expect(!shouldResolveCdpEndpointPath("/devtools/browser/abc"));
    try std.testing.expect(!shouldResolveCdpEndpointPath("/devtools/page/abc"));
}

test "cdp endpoint selection keeps explicit page endpoint" {
    const allocator = std.testing.allocator;
    const parsed = try common.parseEndpoint("cdp://127.0.0.1:9222/devtools/page/123", .cdp);
    const ws_url = try cdpWebSocketEndpoint(allocator, parsed);
    defer allocator.free(ws_url);
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/123", ws_url);
}

test "cdp endpoint selection brackets ipv6 page endpoint" {
    const allocator = std.testing.allocator;
    const parsed = try common.parseEndpoint("cdp://[::1]:9222/devtools/page/123", .cdp);
    const ws_url = try cdpWebSocketEndpoint(allocator, parsed);
    defer allocator.free(ws_url);
    try std.testing.expectEqualStrings("ws://[::1]:9222/devtools/page/123", ws_url);
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

fn makeProtocolComplianceSession(
    allocator: std.mem.Allocator,
    transport: common.TransportKind,
    engine: types.EngineKind,
) !Session {
    var session = try makeNotificationTestSession(allocator, transport, engine);
    switch (transport) {
        .cdp_ws => {
            session.endpoint = try allocator.dupe(u8, "cdp://127.0.0.1:9222/devtools/page/contract");
        },
        .bidi_ws => {
            session.endpoint = try allocator.dupe(u8, "bidi://127.0.0.1:9222/session/contract");
            session.browsing_context_id = try allocator.dupe(u8, "ctx-contract");
        },
    }
    return session;
}

fn sampleCookieHeader() types.Header {
    return .{ .name = "session", .value = "abc" };
}

fn sampleNetworkRule() types.NetworkRule {
    return .{
        .id = "rule-1",
        .url_pattern = "*://example.test/*",
        .action = .{ .block = {} },
    };
}

var notification_callback_saw_unlocked_protocol: bool = false;
var notification_callback_session: ?*Session = null;

fn resetNotificationCallbackState() void {
    notification_callback_saw_unlocked_protocol = false;
    notification_callback_session = null;
}

fn captureNotificationLifecycleEvent(event: types.LifecycleEvent) void {
    switch (event) {
        .network_request_observed => {
            if (notification_callback_session) |session| {
                if (session.protocol_lock.tryLock()) {
                    session.protocol_lock.unlock();
                    notification_callback_saw_unlocked_protocol = true;
                }
            }
        },
        else => {},
    }
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
    try std.testing.expect(session.current_url != null);
    try std.testing.expectEqualStrings("https://example.com/next", session.current_url.?);

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
    try std.testing.expect(session.current_url != null);
    try std.testing.expectEqualStrings("https://example.org/a", session.current_url.?);
}

test "queued notification processing happens outside protocol lock" {
    const allocator = std.testing.allocator;
    var session = try makeNotificationTestSession(allocator, .cdp_ws, .chromium);
    defer session.deinit();

    const subscription_id = try session.onEvent(
        .{ .kinds = &.{.network_request_observed} },
        captureNotificationLifecycleEvent,
    );
    defer _ = session.offEvent(subscription_id);
    resetNotificationCallbackState();
    notification_callback_session = &session;

    var queued_notifications: std.ArrayList([]u8) = .empty;
    defer freeQueuedNotifications(allocator, &queued_notifications);
    try queueNotificationPayload(allocator, &queued_notifications,
        \\{"method":"Network.requestWillBeSent","params":{"requestId":"r2","request":{"url":"https://example.com/queued","method":"GET","headers":{"accept":"*/*"}}}}
    );

    session.protocol_lock.lock();
    session.protocol_lock.unlock();
    processQueuedCdpNotifications(&session, queued_notifications.items);

    try std.testing.expect(notification_callback_saw_unlocked_protocol);
}

const RecoveryServer = struct {
    server: *std.Io.net.Server,
    requests: usize = 0,
    cancel_after_first: ?*@import("../core/cancel.zig").CancelToken = null,

    fn headers(stream: *std.Io.net.Stream) ![]u8 {
        const io_util = @import("../util/io.zig");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(std.testing.allocator);
        while (!std.mem.endsWith(u8, out.items, "\r\n\r\n")) {
            if (out.items.len > 4096) return error.InvalidRequest;
            try out.append(std.testing.allocator, try io_util.readByte(stream));
        }
        return out.toOwnedSlice(std.testing.allocator);
    }

    fn upgrade(stream: *std.Io.net.Stream) !void {
        const request = try headers(stream);
        defer std.testing.allocator.free(request);
        try std.testing.expect(std.mem.startsWith(u8, request, "GET /devtools/page/pinned "));
        const prefix = "Sec-WebSocket-Key: ";
        const start = (std.mem.indexOf(u8, request, prefix) orelse return error.InvalidRequest) + prefix.len;
        const end = start + (std.mem.indexOf(u8, request[start..], "\r\n") orelse return error.InvalidRequest);
        const input = try std.fmt.allocPrint(std.testing.allocator, "{s}258EAFA5-E914-47DA-95CA-C5AB0DC85B11", .{request[start..end]});
        defer std.testing.allocator.free(input);
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(input, &digest, .{});
        var accept: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept, &digest);
        const response = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
        defer std.testing.allocator.free(response);
        try @import("../util/io.zig").writeAll(stream, response);
    }

    fn readRequest(stream: *std.Io.net.Stream) ![]u8 {
        const io_util = @import("../util/io.zig");
        var header: [2]u8 = undefined;
        try io_util.readExact(stream, &header);
        if (header[0] != 0x81 or header[1] & 0x80 == 0) return error.InvalidRequest;
        var size: usize = header[1] & 0x7f;
        if (size == 126) {
            var ext: [2]u8 = undefined;
            try io_util.readExact(stream, &ext);
            size = std.mem.readInt(u16, &ext, .big);
        }
        if (size > 4096) return error.InvalidRequest;
        var mask: [4]u8 = undefined;
        try io_util.readExact(stream, &mask);
        const out = try std.testing.allocator.alloc(u8, size);
        errdefer std.testing.allocator.free(out);
        try io_util.readExact(stream, out);
        for (out, 0..) |*byte, i| byte.* ^= mask[i % 4];
        return out;
    }

    fn send(stream: *std.Io.net.Stream, payload: []const u8) !void {
        const io_util = @import("../util/io.zig");
        var header: [4]u8 = .{ 0x81, 126, 0, 0 };
        if (payload.len < 126) {
            header[1] = @intCast(payload.len);
            try io_util.writeAll(stream, header[0..2]);
        } else {
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            try io_util.writeAll(stream, &header);
        }
        try io_util.writeAll(stream, payload);
    }

    fn run(self: *RecoveryServer) anyerror!void {
        for (0..2) |iteration| {
            var stream = try self.server.accept(compat.io());
            defer stream.close(compat.io());
            try upgrade(&stream);
            const request = try readRequest(&stream);
            defer std.testing.allocator.free(request);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("Runtime.evaluate", parsed.value.object.get("method").?.string);
            self.requests += 1;
            if (iteration == 0) {
                try send(&stream, "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"before-timeout\",\"request\":{\"url\":\"https://example.test/\",\"method\":\"GET\",\"headers\":{}}}}");
                if (self.cancel_after_first) |token| token.cancel();
                var byte: [1]u8 = undefined;
                _ = try @import("../util/io.zig").read(&stream, &byte);
            } else {
                const response = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":{d},\"result\":{{\"result\":{{\"type\":\"number\",\"value\":7}}}}}}", .{parsed.value.object.get("id").?.integer});
                defer std.testing.allocator.free(response);
                try send(&stream, response);
            }
        }
    }

    fn stall(server: *std.Io.net.Server) anyerror!void {
        var stream = try server.accept(compat.io());
        defer stream.close(compat.io());
        const request = try headers(&stream);
        defer std.testing.allocator.free(request);
        var byte: [1]u8 = undefined;
        _ = try @import("../util/io.zig").read(&stream, &byte);
    }
};

test "CDP timeout preserves queued events and pinned target and next call reconnects without replay" {
    const allocator = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(compat.io(), .{});
    defer server.deinit(compat.io());
    var context = RecoveryServer{ .server = &server };
    var task = try std.Io.concurrent(compat.io(), RecoveryServer.run, .{&context});
    defer _ = task.cancel(compat.io()) catch {};
    var session = try makeProtocolComplianceSession(allocator, .cdp_ws, .chromium);
    defer session.deinit();
    allocator.free(session.endpoint.?);
    session.endpoint = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}/devtools/page/pinned", .{server.socket.address.getPort()});
    session.cdp_target_id = try allocator.dupe(u8, "pinned");
    session.timeout_policy.network_ms = 200;
    try std.testing.expectError(error.Timeout, callCdp(&session, "Runtime.evaluate", "{\"expression\":\"sideEffect()\"}"));
    try std.testing.expect(session.cdp_client == null);
    try std.testing.expect(!session.network_tracking_valid);
    try std.testing.expectEqualStrings("pinned", session.cdp_target_id.?);
    const records = try session.networkRecords(allocator, false);
    defer session.freeNetworkRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("before-timeout", records[0].request_id);
    const response = try callCdp(&session, "Runtime.evaluate", "{\"expression\":\"7\"}");
    defer allocator.free(response);
    try task.await(compat.io());
    try std.testing.expectEqual(@as(usize, 2), context.requests);
    try std.testing.expectEqualStrings("pinned", session.cdp_target_id.?);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"value\":7") != null);
}

test "CDP readiness deadline bounds inner connection setup" {
    const allocator = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(compat.io(), .{});
    defer server.deinit(compat.io());
    var task = try std.Io.concurrent(compat.io(), RecoveryServer.stall, .{&server});
    defer _ = task.cancel(compat.io()) catch {};
    var session = try makeProtocolComplianceSession(allocator, .cdp_ws, .chromium);
    defer session.deinit();
    allocator.free(session.endpoint.?);
    session.endpoint = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}/devtools/page/pinned", .{server.socket.address.getPort()});
    const started = compat.milliTimestamp();
    try std.testing.expectError(error.Timeout, waitUntilReady(&session, 40));
    try std.testing.expect(compat.milliTimestamp() - started < 2000);
}

test "cancelable evaluation interrupts one pending RPC and permits the next request" {
    const allocator = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(compat.io(), .{});
    defer server.deinit(compat.io());
    var token = @import("../core/cancel.zig").CancelToken.init();
    var context = RecoveryServer{ .server = &server, .cancel_after_first = &token };
    var task = try std.Io.concurrent(compat.io(), RecoveryServer.run, .{&context});
    defer _ = task.cancel(compat.io()) catch {};
    var session = try makeProtocolComplianceSession(allocator, .cdp_ws, .chromium);
    defer session.deinit();
    allocator.free(session.endpoint.?);
    session.endpoint = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{d}/devtools/page/pinned", .{server.socket.address.getPort()});
    session.cdp_target_id = try allocator.dupe(u8, "pinned");
    try std.testing.expectError(error.Canceled, evaluateCancelable(&session, "new Promise(()=>{})", 5000, &token));
    try std.testing.expect(session.cdp_client == null);
    const payload = try evaluateWithTimeout(&session, "7", 1000);
    defer allocator.free(payload);
    try task.await(compat.io());
    try std.testing.expectEqual(@as(usize, 2), context.requests);
    try std.testing.expectEqualStrings("pinned", session.cdp_target_id.?);
}

test "network idle bookkeeping tracks requests through complete bodies and failures" {
    const allocator = std.testing.allocator;
    var session = try makeNotificationTestSession(allocator, .cdp_ws, .chromium);
    defer session.deinit();
    const request = "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"image\",\"request\":{\"url\":\"https://example.test/a.png\",\"method\":\"GET\",\"headers\":{}}}}";
    processCdpNotification(&session, request);
    processCdpNotification(&session, request);
    try std.testing.expectEqual(@as(u32, 1), session.network_inflight.count());
    processCdpNotification(&session, "{\"method\":\"Network.responseReceived\",\"params\":{\"requestId\":\"image\",\"response\":{\"url\":\"https://example.test/a.png\",\"status\":200,\"headers\":{}}}}");
    try std.testing.expectEqual(@as(u32, 1), session.network_inflight.count());
    processCdpNotification(&session, "{\"method\":\"Network.loadingFinished\",\"params\":{\"requestId\":\"image\"}}");
    try std.testing.expectEqual(@as(u32, 0), session.network_inflight.count());
    try std.testing.expect(session.network_last_activity_ms > 0);
    processCdpNotification(&session, request);
    processCdpNotification(&session, "{\"method\":\"Network.loadingFailed\",\"params\":{\"requestId\":\"image\"}}");
    try std.testing.expectEqual(@as(u32, 0), session.network_inflight.count());
}

test "deferred callbacks cannot rewind network activity and allocation loss invalidates observation" {
    const allocator = std.testing.allocator;
    var session = try makeNotificationTestSession(allocator, .cdp_ws, .chromium);
    defer session.deinit();
    const request = "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"ordered\",\"request\":{\"url\":\"https://example.test/\",\"method\":\"GET\",\"headers\":{}}}}";
    trackCdpNetworkNotification(&session, request);
    trackCdpNetworkNotification(&session, "{\"method\":\"Network.loadingFinished\",\"params\":{\"requestId\":\"ordered\"}}");
    processQueuedCdpNotifications(&session, &.{request});
    try std.testing.expectEqual(@as(u32, 0), session.network_inflight.count());

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"requestId\":\"oom\"}", .{});
    defer parsed.deinit();
    for (0..2) |fail_index| {
        var fresh = try makeNotificationTestSession(allocator, .cdp_ws, .chromium);
        defer fresh.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        fresh.allocator = failing.allocator();
        beginNetworkRequest(&fresh, parsed.value.object);
        fresh.allocator = allocator;
        try std.testing.expect(!fresh.network_tracking_valid);
        try std.testing.expectEqual(@as(u32, 0), fresh.network_inflight.count());
    }
}

test "cdp-only executor commands reject bidi and stay wired on cdp" {
    const allocator = std.testing.allocator;
    var bidi_session = try makeProtocolComplianceSession(allocator, .bidi_ws, .gecko);
    defer bidi_session.deinit();

    const cookie = sampleCookieHeader();
    try std.testing.expectError(error.UnsupportedProtocol, setCookie(&bidi_session, cookie, "example.test", "/"));
    try std.testing.expectError(error.UnsupportedProtocol, getCookies(&bidi_session));
    try std.testing.expectError(error.UnsupportedProtocol, getResponseBody(&bidi_session, "req-1"));
    try std.testing.expectError(error.UnsupportedProtocol, screenshot(&bidi_session));
    try std.testing.expectError(error.UnsupportedProtocol, startTracing(&bidi_session));
    try std.testing.expectError(error.UnsupportedProtocol, stopTracing(&bidi_session));
    try std.testing.expectError(error.UnsupportedProtocol, cdpGetTargets(&bidi_session));
    try std.testing.expectError(error.UnsupportedProtocol, cdpCreateTarget(&bidi_session, "about:blank"));
    try std.testing.expectError(error.UnsupportedProtocol, cdpAttachToTarget(&bidi_session, "target-1", true));
    try std.testing.expectError(error.UnsupportedProtocol, cdpDetachFromTarget(&bidi_session, "session-1"));
    try std.testing.expectError(error.UnsupportedProtocol, cdpCloseTarget(&bidi_session, "target-1"));

    var cdp_session = try makeProtocolComplianceSession(allocator, .cdp_ws, .chromium);
    defer cdp_session.deinit();
    cdp_session.allocator.free(cdp_session.endpoint.?);
    cdp_session.endpoint = null;

    try std.testing.expectError(error.MissingEndpoint, setCookie(&cdp_session, cookie, "example.test", "/"));
    try std.testing.expectError(error.MissingEndpoint, getCookies(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, getResponseBody(&cdp_session, "req-1"));
    try std.testing.expectError(error.MissingEndpoint, screenshot(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, startTracing(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, stopTracing(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, cdpGetTargets(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, cdpCreateTarget(&cdp_session, "about:blank"));
    try std.testing.expectError(error.MissingEndpoint, cdpAttachToTarget(&cdp_session, "target-1", true));
    try std.testing.expectError(error.MissingEndpoint, cdpDetachFromTarget(&cdp_session, "session-1"));
    try std.testing.expectError(error.MissingEndpoint, cdpCloseTarget(&cdp_session, "target-1"));
}

test "shared executor commands keep setup failures distinct from teardown on both transports" {
    const allocator = std.testing.allocator;
    const rule = sampleNetworkRule();

    var cdp_session = try makeProtocolComplianceSession(allocator, .cdp_ws, .chromium);
    defer cdp_session.deinit();
    cdp_session.allocator.free(cdp_session.endpoint.?);
    cdp_session.endpoint = null;

    try std.testing.expectError(error.MissingEndpoint, evaluate(&cdp_session, "1 + 1"));
    try std.testing.expectError(error.MissingEndpoint, addInitScript(&cdp_session, "window.__driver = true;"));
    try std.testing.expectError(error.MissingEndpoint, removeInitScript(&cdp_session, "script-1"));
    try std.testing.expectError(error.MissingEndpoint, releaseHandle(&cdp_session, "handle-1"));
    try std.testing.expectError(error.MissingEndpoint, enableNetworkInterception(&cdp_session));
    try disableNetworkInterception(&cdp_session);
    try std.testing.expectError(error.MissingEndpoint, addNetworkRule(&cdp_session, rule));

    var bidi_session = try makeProtocolComplianceSession(allocator, .bidi_ws, .gecko);
    defer bidi_session.deinit();
    bidi_session.allocator.free(bidi_session.endpoint.?);
    bidi_session.endpoint = null;

    try std.testing.expectError(error.MissingEndpoint, evaluate(&bidi_session, "1 + 1"));
    try std.testing.expectError(error.MissingEndpoint, addInitScript(&bidi_session, "window.__driver = true;"));
    try std.testing.expectError(error.MissingEndpoint, removeInitScript(&bidi_session, "script-1"));
    try std.testing.expectError(error.MissingEndpoint, releaseHandle(&bidi_session, "handle-1"));
    try std.testing.expectError(error.UnsupportedProtocol, enableNetworkInterception(&bidi_session));
    try disableNetworkInterception(&bidi_session);
    try std.testing.expectError(error.UnsupportedProtocol, addNetworkRule(&bidi_session, rule));
}
