const std = @import("std");
const Session = @import("session.zig").Session;
const executor = @import("../protocol/executor.zig");
const storage = @import("storage.zig");
const events = @import("events.zig");
const types = @import("../types.zig");
const strings = @import("../util/strings.zig");
const compat = @import("../util/compat.zig");

const Probe = struct {
    session: *Session,
    started_ms: i64,
    deadline_ms: i64,
    cancel_token: ?*const @import("cancel.zig").CancelToken,
};

pub fn waitFor(session: *Session, target: types.WaitTarget, opts: types.WaitOptions) !types.WaitResult {
    const start_ms = compat.milliTimestamp();
    const timeout_ms = opts.timeout_ms orelse session.timeout_policy.wait_ms;
    const poll_interval_ms = if (opts.poll_interval_ms == 0) @as(u32, 25) else opts.poll_interval_ms;
    const target_tag = std.meta.activeTag(target);
    var next_challenge_probe_ms = start_ms;
    const probe: Probe = .{
        .session = session,
        .started_ms = start_ms,
        .deadline_ms = start_ms + @as(i64, timeout_ms),
        .cancel_token = opts.cancel_token,
    };
    events.emit(session, .{ .wait_started = .{ .target = target_tag, .timeout_ms = timeout_ms, .poll_interval_ms = poll_interval_ms } });
    while (true) {
        if (opts.cancel_token) |token| {
            if (token.isCanceled()) return failWait(session, target_tag, start_ms, timeout_ms, error.Canceled);
        }
        if (compat.milliTimestamp() >= probe.deadline_ms)
            return failWait(session, target_tag, start_ms, timeout_ms, error.Timeout);
        const now_ms = compat.milliTimestamp();
        if (now_ms >= next_challenge_probe_ms) {
            maybeEmitChallengeSignals(&probe) catch |err| return failWait(session, target_tag, start_ms, timeout_ms, err);
            next_challenge_probe_ms = now_ms + 500;
        }
        const matched = isTargetMatched(&probe, target) catch |err| return failWait(session, target_tag, start_ms, timeout_ms, err);
        if (opts.cancel_token) |token| {
            if (token.isCanceled()) return failWait(session, target_tag, start_ms, timeout_ms, error.Canceled);
        }
        if (compat.milliTimestamp() >= probe.deadline_ms)
            return failWait(session, target_tag, start_ms, timeout_ms, error.Timeout);
        if (matched) {
            const elapsed = elapsedSince(start_ms);
            session.clearDiagnostic();
            events.emit(session, .{ .wait_satisfied = .{ .target = target_tag, .elapsed_ms = elapsed } });
            return .{ .matched = true, .elapsed_ms = elapsed, .target = target_tag };
        }
        const wake = @min(probe.deadline_ms, compat.milliTimestamp() + @as(i64, poll_interval_ms));
        while (compat.milliTimestamp() < wake) {
            if (opts.cancel_token) |token| if (token.isCanceled()) break;
            const remaining = wake - compat.milliTimestamp();
            if (remaining <= 0) break;
            compat.sleepMs(@intCast(@min(remaining, 25)));
        }
    }
}

fn failWait(session: *Session, target: types.WaitTargetTag, started: i64, timeout_ms: u32, err: anyerror) anyerror {
    const elapsed = elapsedSince(started);
    session.recordDiagnostic(.{
        .phase = .wait,
        .code = if (err == error.Timeout) "timeout" else if (err == error.Canceled) "canceled" else @errorName(err),
        .message = if (err == error.Timeout) "wait timeout reached" else if (err == error.Canceled) "wait canceled by token" else "wait failed",
        .transport = @tagName(session.transport),
        .elapsed_ms = elapsed,
    });
    if (err == error.Timeout) {
        events.emit(session, .{ .wait_timeout = .{ .target = target, .elapsed_ms = elapsed, .timeout_ms = timeout_ms } });
    } else if (err == error.Canceled) {
        events.emit(session, .{ .wait_canceled = .{ .target = target, .elapsed_ms = elapsed } });
    } else {
        events.emit(session, .{ .wait_failed = .{ .target = target, .elapsed_ms = elapsed, .error_code = @errorName(err) } });
    }
    return err;
}

fn isTargetMatched(probe: *const Probe, target: types.WaitTarget) !bool {
    return switch (target) {
        .dom_ready => waitDomReadyStep(probe),
        .network_idle => waitNetworkIdleStep(probe),
        .selector_visible => |selector| waitSelectorStep(probe, selector),
        .url_contains => |needle| waitUrlContainsStep(probe, needle),
        .cookie_present => |query| waitCookieStep(probe, query),
        .storage_key_present => |query| waitStorageKeyStep(probe, query),
        .js_truthy => |script| waitJsTruthyStep(probe, script),
    };
}

fn waitDomReadyStep(probe: *const Probe) !bool {
    const payload = try evaluateForWait(probe, "document.readyState==='complete'");
    defer probe.session.allocator.free(payload);
    return payloadContainsTruthy(payload);
}

fn waitSelectorStep(probe: *const Probe, selector: []const u8) !bool {
    const allocator = probe.session.allocator;
    const escaped = try escapeJsString(allocator, selector);
    defer allocator.free(escaped);
    const script = try std.fmt.allocPrint(allocator, "(()=>{{const el=document.querySelector(\"{s}\");if(!el)return false;const style=getComputedStyle(el);return style.visibility!=='hidden'&&style.visibility!=='collapse'&&Array.from(el.getClientRects()).some(r=>r.width>0&&r.height>0);}})()", .{escaped});
    defer allocator.free(script);
    const payload = try evaluateForWait(probe, script);
    defer allocator.free(payload);
    return payloadContainsTruthy(payload);
}

fn waitNetworkIdleStep(probe: *const Probe) !bool {
    const session = probe.session;
    const payload = try evaluateForWait(probe, "document.readyState==='complete'");
    defer session.allocator.free(payload);
    if (!payloadContainsTruthy(payload)) return false;
    session.network_lock.lock();
    defer session.network_lock.unlock();
    if (!session.network_tracking_valid) return error.NetworkObservationLost;
    const quiet_since = @max(probe.started_ms, session.network_last_activity_ms);
    return session.network_inflight.count() == 0 and compat.milliTimestamp() - quiet_since >= 500;
}

fn waitUrlContainsStep(probe: *const Probe, needle: []const u8) !bool {
    const session = probe.session;
    const payload = try evaluateForWait(probe, "location.href");
    defer session.allocator.free(payload);
    const url = try extractEvaluationString(session.allocator, payload);
    defer session.allocator.free(url);
    return strings.containsIgnoreCase(url, needle);
}

fn waitCookieStep(probe: *const Probe, query: types.CookieQuery) !bool {
    const session = probe.session;
    const remaining = probe.deadline_ms - compat.milliTimestamp();
    if (remaining <= 0) return error.Timeout;
    const cookies = try storage.queryCookiesCancelable(session, session.allocator, query, @intCast(remaining), probe.cancel_token);
    defer storage.freeCookies(session.allocator, cookies);
    return cookies.len > 0;
}

fn waitStorageKeyStep(probe: *const Probe, query: types.StorageKeyQuery) !bool {
    const session = probe.session;
    if (!session.supports(.js_eval)) return error.UnsupportedCapability;
    const escaped = try escapeJsString(session.allocator, query.key);
    defer session.allocator.free(escaped);

    const script = switch (query.area) {
        .local => try std.fmt.allocPrint(
            session.allocator,
            "(function(){{return localStorage.getItem(\"{s}\")!==null;}})();",
            .{escaped},
        ),
        .session => try std.fmt.allocPrint(
            session.allocator,
            "(function(){{return sessionStorage.getItem(\"{s}\")!==null;}})();",
            .{escaped},
        ),
        .either => try std.fmt.allocPrint(
            session.allocator,
            "(function(){{return localStorage.getItem(\"{s}\")!==null || sessionStorage.getItem(\"{s}\")!==null;}})();",
            .{ escaped, escaped },
        ),
    };
    defer session.allocator.free(script);

    const payload = try evaluateForWait(probe, script);
    defer session.allocator.free(payload);
    return payloadContainsTruthy(payload);
}

fn waitJsTruthyStep(probe: *const Probe, script: []const u8) !bool {
    const session = probe.session;
    if (!session.supports(.js_eval)) return error.UnsupportedCapability;
    const payload = try evaluateForWait(probe, script);
    defer session.allocator.free(payload);
    return payloadContainsTruthy(payload);
}

fn payloadContainsTruthy(payload: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("result")) |result| {
            if (result == .object) {
                if (result.object.get("result")) |remote| return remoteTruthy(remote);
                return remoteTruthy(result);
            }
        }
        return remoteTruthy(parsed.value);
    }
    return jsonValueTruthy(parsed.value);
}

fn remoteTruthy(remote: std.json.Value) bool {
    if (remote != .object) return false;
    if (remote.object.get("value")) |value| return jsonValueTruthy(value);
    const kind = remote.object.get("type") orelse return false;
    if (kind != .string) return false;
    if (std.mem.eql(u8, kind.string, "undefined")) return false;
    if (std.mem.eql(u8, kind.string, "object")) {
        if (remote.object.get("subtype")) |subtype| {
            if (subtype == .string and std.mem.eql(u8, subtype.string, "null")) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, kind.string, "function") or std.mem.eql(u8, kind.string, "symbol")) return true;
    if (remote.object.get("unserializableValue")) |value| {
        if (value != .string) return false;
        if (std.mem.eql(u8, kind.string, "number")) return std.mem.eql(u8, value.string, "Infinity") or std.mem.eql(u8, value.string, "-Infinity");
        if (std.mem.eql(u8, kind.string, "bigint")) return !std.mem.eql(u8, value.string, "0n") and !std.mem.eql(u8, value.string, "-0n");
    }
    return false;
}

fn extractEvaluationValue(value: std.json.Value) ?std.json.Value {
    if (value != .object) return null;
    const result = value.object.get("result") orelse return null;
    if (result == .object) {
        if (result.object.get("result")) |nested| {
            if (nested == .object) {
                if (nested.object.get("value")) |raw| return raw;
            }
        }
        if (result.object.get("value")) |raw| return raw;
    }
    if (value.object.get("value")) |raw| return raw;
    return null;
}

fn jsonValueTruthy(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => value.bool,
        .integer => value.integer != 0,
        .float => value.float != 0 and !std.math.isNan(value.float),
        .number_string => (std.fmt.parseFloat(f64, value.number_string) catch 0) != 0,
        .string => value.string.len != 0,
        // JS objects/arrays are truthy.
        .object, .array => true,
    };
}

fn maybeEmitChallengeSignals(probe: *const Probe) !void {
    const session = probe.session;
    if (!session.supports(.js_eval)) return;
    const title_payload = try evaluateForWait(probe, "document.title");
    defer session.allocator.free(title_payload);
    const title = try extractEvaluationString(session.allocator, title_payload);
    defer session.allocator.free(title);

    const looks_like_challenge = strings.containsIgnoreCase(title, "challenge") or
        strings.containsIgnoreCase(title, "just a moment") or
        strings.containsIgnoreCase(title, "attention required") or
        strings.containsIgnoreCase(title, "cf-chl") or
        strings.containsIgnoreCase(title, "cloudflare");

    const current_url = try currentUrl(probe);
    defer session.allocator.free(current_url);

    var should_emit_detected = false;
    var should_emit_solved = false;
    session.challenge_lock.lock();
    if (looks_like_challenge and !session.challenge_active) {
        session.challenge_active = true;
        should_emit_detected = true;
    } else if (!looks_like_challenge and session.challenge_active) {
        session.challenge_active = false;
        should_emit_solved = true;
    }
    session.challenge_lock.unlock();

    if (should_emit_detected) {
        events.emit(session, .{
            .challenge_detected = .{
                .url = current_url,
                .signal = "title_challenge_heuristic",
            },
        });
        return;
    }
    if (should_emit_solved) {
        events.emit(session, .{
            .challenge_solved = .{ .url = current_url },
        });
    }
}

fn currentUrl(probe: *const Probe) ![]u8 {
    const session = probe.session;
    if (session.supports(.js_eval)) {
        const payload = try evaluateForWait(probe, "location.href");
        defer session.allocator.free(payload);
        return extractEvaluationString(session.allocator, payload);
    }
    session.state_lock.lock();
    defer session.state_lock.unlock();
    if (session.current_url) |url| return session.allocator.dupe(u8, url);
    return session.allocator.dupe(u8, "");
}

fn extractEvaluationString(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        return allocator.dupe(u8, payload);
    };
    defer parsed.deinit();
    const value = extractEvaluationValue(parsed.value) orelse return allocator.dupe(u8, payload);
    return switch (value) {
        .string => allocator.dupe(u8, value.string),
        else => std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

fn evaluateForWait(probe: *const Probe, script: []const u8) ![]u8 {
    if (!probe.session.supports(.js_eval)) return error.UnsupportedCapability;
    const remaining = probe.deadline_ms - compat.milliTimestamp();
    if (remaining <= 0) return error.Timeout;
    return executor.evaluateCancelable(probe.session, script, @intCast(remaining), probe.cancel_token);
}

fn elapsedSince(start_ms: i64) u32 {
    return compat.elapsedSinceMs(start_ms);
}

fn escapeJsString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (value) |c| {
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

test "payloadContainsTruthy recognizes common encodings" {
    try std.testing.expect(payloadContainsTruthy("{\"result\":{\"result\":{\"value\":true}}}"));
    try std.testing.expect(payloadContainsTruthy("{\"result\":{\"result\":{\"value\":1}}}"));
    try std.testing.expect(payloadContainsTruthy("{\"result\":{\"value\":\"true\"}}"));
    try std.testing.expect(payloadContainsTruthy("{\"result\":{\"result\":{\"value\":{}}}}"));
    try std.testing.expect(!payloadContainsTruthy("false"));
    try std.testing.expect(!payloadContainsTruthy("{\"id\":1,\"result\":{\"result\":{\"value\":false}}}"));
    try std.testing.expect(!payloadContainsTruthy("{\"id\":1,\"result\":{\"result\":{\"value\":0}}}"));
}

test "escapeJsString escapes control characters" {
    const allocator = std.testing.allocator;
    const escaped = try escapeJsString(allocator, "a\\\"b\nc\t");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\\\\\"b\\nc\\t", escaped);
}

test "wait truthiness follows JavaScript values and refuses empty protocol acknowledgements" {
    const truthy = [_][]const u8{
        "{\"result\":{\"result\":{\"type\":\"string\",\"value\":\"hello\"}}}",
        "{\"result\":{\"result\":{\"type\":\"string\",\"value\":\"false\"}}}",
        "{\"result\":{\"result\":{\"type\":\"number\",\"unserializableValue\":\"Infinity\"}}}",
        "{\"result\":{\"result\":{\"type\":\"bigint\",\"unserializableValue\":\"2n\"}}}",
        "{\"result\":{\"result\":{\"type\":\"function\",\"objectId\":\"x\"}}}",
        "{\"result\":{\"result\":{\"type\":\"object\",\"value\":[]}}}",
    };
    const falsy = [_][]const u8{
        "{}",                                                                             "{\"result\":{}}",
        "{\"result\":{\"result\":{\"type\":\"undefined\"}}}",                             "{\"result\":{\"result\":{\"type\":\"number\",\"unserializableValue\":\"NaN\"}}}",
        "{\"result\":{\"result\":{\"type\":\"number\",\"unserializableValue\":\"-0\"}}}", "{\"result\":{\"result\":{\"type\":\"bigint\",\"unserializableValue\":\"0n\"}}}",
        "{\"result\":{\"result\":{\"type\":\"string\",\"value\":\"\"}}}",                 "{\"result\":{\"result\":{\"type\":\"object\",\"subtype\":\"null\"}}}",
    };
    for (truthy) |value| try std.testing.expect(payloadContainsTruthy(value));
    for (falsy) |value| try std.testing.expect(!payloadContainsTruthy(value));
}
