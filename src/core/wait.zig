const std = @import("std");
const Session = @import("session.zig").Session;
const executor = @import("../protocol/executor.zig");
const storage = @import("storage.zig");
const events = @import("events.zig");
const types = @import("../types.zig");
const strings = @import("../util/strings.zig");

pub fn waitFor(session: *Session, target: types.WaitTarget, opts: types.WaitOptions) !types.WaitResult {
    const start_ms = std.time.milliTimestamp();
    const timeout_ms = opts.timeout_ms orelse session.timeout_policy.wait_ms;
    const poll_interval_ms = if (opts.poll_interval_ms == 0) @as(u32, 25) else opts.poll_interval_ms;
    var next_challenge_probe_ms = start_ms;

    while (true) {
        if (opts.cancel_token) |token| {
            if (token.isCanceled()) {
                session.recordDiagnostic(.{
                    .phase = .wait,
                    .code = "canceled",
                    .message = "wait canceled by token",
                    .transport = @tagName(session.transport),
                    .elapsed_ms = elapsedSince(start_ms),
                });
                return error.Canceled;
            }
        }

        const now_ms = std.time.milliTimestamp();
        if (now_ms >= next_challenge_probe_ms) {
            try maybeEmitChallengeSignals(session);
            next_challenge_probe_ms = now_ms + 500;
        }
        const matched = try isTargetMatched(session, target, poll_interval_ms);
        if (matched) {
            session.clearDiagnostic();
            return .{
                .matched = true,
                .elapsed_ms = elapsedSince(start_ms),
                .target = std.meta.activeTag(target),
            };
        }

        if (elapsedSince(start_ms) >= timeout_ms) {
            session.recordDiagnostic(.{
                .phase = .wait,
                .code = "timeout",
                .message = "wait timeout reached",
                .transport = @tagName(session.transport),
                .elapsed_ms = elapsedSince(start_ms),
            });
            return error.Timeout;
        }

        std.Thread.sleep(@as(u64, poll_interval_ms) * std.time.ns_per_ms);
    }
}

fn isTargetMatched(
    session: *Session,
    target: types.WaitTarget,
    poll_interval_ms: u32,
) !bool {
    return switch (target) {
        .dom_ready => waitDomReadyStep(session, poll_interval_ms),
        .network_idle => waitNetworkIdleStep(session),
        .selector_visible => |selector| waitSelectorStep(session, selector, poll_interval_ms),
        .url_contains => |needle| waitUrlContainsStep(session, needle),
        .cookie_present => |query| waitCookieStep(session, query),
        .storage_key_present => |query| waitStorageKeyStep(session, query),
        .js_truthy => |script| waitJsTruthyStep(session, script),
    };
}

fn waitDomReadyStep(session: *Session, poll_interval_ms: u32) !bool {
    const slice = clampTimeout(poll_interval_ms);
    executor.waitForDomReady(session, slice) catch |err| switch (err) {
        error.Timeout => return false,
        else => return err,
    };
    return true;
}

fn waitSelectorStep(session: *Session, selector: []const u8, poll_interval_ms: u32) !bool {
    const slice = clampTimeout(poll_interval_ms);
    executor.waitForSelector(session, selector, slice) catch |err| switch (err) {
        error.Timeout => return false,
        else => return err,
    };
    return true;
}

fn waitNetworkIdleStep(session: *Session) !bool {
    if (!session.supports(.js_eval)) return error.UnsupportedCapability;
    const payload = try session.evaluate(
        "(function(){return document.readyState==='complete' && (!window.__webdriver_active_requests || window.__webdriver_active_requests===0);})();",
    );
    defer session.allocator.free(payload);
    return payloadContainsTruthy(payload);
}

fn waitUrlContainsStep(session: *Session, needle: []const u8) !bool {
    const payload = try session.evaluate("location.href");
    defer session.allocator.free(payload);
    return strings.containsIgnoreCase(payload, needle);
}

fn waitCookieStep(session: *Session, query: types.CookieQuery) !bool {
    const cookies = try storage.queryCookies(session, session.allocator, query);
    defer storage.freeCookies(session.allocator, cookies);
    if (cookies.len > 0) return true;

    if (query.name) |cookie_name| {
        if (!session.supports(.js_eval)) return false;
        const escaped = try escapeJsString(session.allocator, cookie_name);
        defer session.allocator.free(escaped);
        const script = try std.fmt.allocPrint(
            session.allocator,
            "(function(){{return document.cookie.indexOf(\"{s}=\") !== -1;}})();",
            .{escaped},
        );
        defer session.allocator.free(script);
        const payload = try session.evaluate(script);
        defer session.allocator.free(payload);
        return payloadContainsTruthy(payload);
    }

    return false;
}

fn waitStorageKeyStep(session: *Session, query: types.StorageKeyQuery) !bool {
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

    const payload = try session.evaluate(script);
    defer session.allocator.free(payload);
    return payloadContainsTruthy(payload);
}

fn waitJsTruthyStep(session: *Session, script: []const u8) !bool {
    if (!session.supports(.js_eval)) return error.UnsupportedCapability;
    const payload = try session.evaluate(script);
    defer session.allocator.free(payload);
    return payloadContainsTruthy(payload);
}

fn payloadContainsTruthy(payload: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return false;
    defer parsed.deinit();

    const value = extractEvaluationValue(parsed.value) orelse parsed.value;
    return jsonValueTruthy(value);
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
        .float => value.float != 0 and std.math.isFinite(value.float),
        .number_string => std.mem.eql(u8, value.number_string, "1"),
        .string => std.mem.eql(u8, value.string, "true") or std.mem.eql(u8, value.string, "1"),
        // JS objects/arrays are truthy.
        .object, .array => true,
    };
}

fn maybeEmitChallengeSignals(session: *Session) !void {
    if (!session.supports(.js_eval)) return;
    const title_payload = try session.evaluate("document.title");
    defer session.allocator.free(title_payload);

    const looks_like_challenge = strings.containsIgnoreCase(title_payload, "challenge") or
        strings.containsIgnoreCase(title_payload, "just a moment") or
        strings.containsIgnoreCase(title_payload, "attention required") or
        strings.containsIgnoreCase(title_payload, "cf-chl") or
        strings.containsIgnoreCase(title_payload, "cloudflare");

    const current_url = try currentUrl(session);
    defer session.allocator.free(current_url);

    if (looks_like_challenge and !session.challenge_active) {
        session.challenge_active = true;
        events.emit(session, .{
            .challenge_detected = .{
                .url = current_url,
                .signal = "title_challenge_heuristic",
            },
        });
        return;
    }

    if (!looks_like_challenge and session.challenge_active) {
        session.challenge_active = false;
        events.emit(session, .{
            .challenge_solved = .{ .url = current_url },
        });
    }
}

fn currentUrl(session: *Session) ![]u8 {
    if (session.supports(.js_eval)) {
        const payload = try session.evaluate("location.href");
        return payload;
    }
    session.state_lock.lock();
    defer session.state_lock.unlock();
    if (session.current_url) |url| return session.allocator.dupe(u8, url);
    return session.allocator.dupe(u8, "");
}

fn clampTimeout(poll_interval_ms: u32) u32 {
    if (poll_interval_ms < 25) return 25;
    if (poll_interval_ms > 500) return 500;
    return poll_interval_ms;
}

fn elapsedSince(start_ms: i64) u32 {
    const delta = std.time.milliTimestamp() - start_ms;
    if (delta <= 0) return 0;
    return @intCast(delta);
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
