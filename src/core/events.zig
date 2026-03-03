const std = @import("std");
const string_util = @import("../util/strings.zig");
const types = @import("../types.zig");
const Session = @import("session.zig").Session;

pub const EventSubscription = struct {
    id: u64,
    domain: ?[]u8 = null,
    kinds: []types.LifecycleEventKind = &.{},
    callback: *const fn (types.LifecycleEvent) void,
};

pub fn register(
    session: *Session,
    filter: types.EventFilter,
    callback: *const fn (types.LifecycleEvent) void,
) !u64 {
    session.event_lock.lock();
    defer session.event_lock.unlock();

    const id = session.next_event_subscription_id;
    session.next_event_subscription_id += 1;

    var owned_kinds: []types.LifecycleEventKind = &.{};
    errdefer if (owned_kinds.len > 0) session.allocator.free(owned_kinds);
    if (filter.kinds.len > 0) {
        owned_kinds = try session.allocator.alloc(types.LifecycleEventKind, filter.kinds.len);
        @memcpy(owned_kinds, filter.kinds);
    }

    const owned_domain = if (filter.domain) |d| try session.allocator.dupe(u8, d) else null;
    errdefer if (owned_domain) |d| session.allocator.free(d);

    const sub: EventSubscription = .{
        .id = id,
        .domain = owned_domain,
        .kinds = owned_kinds,
        .callback = callback,
    };

    try session.event_subscriptions.append(session.allocator, sub);
    return id;
}

pub fn unregister(session: *Session, id: u64) bool {
    session.event_lock.lock();
    defer session.event_lock.unlock();

    var idx: usize = 0;
    while (idx < session.event_subscriptions.items.len) : (idx += 1) {
        if (session.event_subscriptions.items[idx].id != id) continue;
        const sub = session.event_subscriptions.swapRemove(idx);
        freeSubscription(session.allocator, sub);
        return true;
    }
    return false;
}

pub fn clear(session: *Session) void {
    session.event_lock.lock();
    defer session.event_lock.unlock();

    while (session.event_subscriptions.items.len > 0) {
        const sub = session.event_subscriptions.pop().?;
        freeSubscription(session.allocator, sub);
    }
}

pub fn emit(session: *Session, event: types.LifecycleEvent) void {
    var callbacks: std.ArrayList(*const fn (types.LifecycleEvent) void) = .empty;
    defer callbacks.deinit(session.allocator);

    session.event_lock.lock();
    for (session.event_subscriptions.items) |sub| {
        if (!matchesKind(sub.kinds, event)) continue;
        if (sub.domain) |domain| {
            const event_domain = domainForEvent(event) orelse continue;
            if (!domainMatches(event_domain, domain)) continue;
        }
        callbacks.append(session.allocator, sub.callback) catch continue;
    }
    session.event_lock.unlock();

    for (callbacks.items) |callback| {
        callback(event);
    }
}

fn matchesKind(allowed: []const types.LifecycleEventKind, event: types.LifecycleEvent) bool {
    if (allowed.len == 0) return true;
    const kind = std.meta.activeTag(event);
    for (allowed) |candidate| {
        if (candidate == kind) return true;
    }
    return false;
}

fn domainForEvent(event: types.LifecycleEvent) ?[]const u8 {
    return switch (event) {
        .navigation_started => |e| hostFromUrl(e.url),
        .navigation_completed => |e| hostFromUrl(e.url),
        .navigation_failed => |e| hostFromUrl(e.url),
        .reload_started => |e| hostFromUrl(e.url),
        .reload_completed => |e| hostFromUrl(e.url),
        .reload_failed => |e| hostFromUrl(e.url),
        .network_request_observed => |e| hostFromUrl(e.url),
        .network_response_observed => |e| hostFromUrl(e.url),
        .response_received => |e| hostFromUrl(e.url),
        .dom_ready => |e| hostFromUrl(e.url),
        .scripts_settled => |e| hostFromUrl(e.url),
        .challenge_detected => |e| hostFromUrl(e.url),
        .challenge_solved => |e| hostFromUrl(e.url),
        .cookie_updated => |e| e.domain,
        .wait_started,
        .wait_satisfied,
        .wait_timeout,
        .wait_canceled,
        .wait_failed,
        .action_started,
        .action_completed,
        .action_failed,
        => null,
    };
}

fn hostFromUrl(url: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    const colon = std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len;
    const host = host_port[0..colon];
    if (host.len == 0) return null;
    return host;
}

fn domainMatches(value: []const u8, filter: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(value, filter)) return true;
    if (value.len <= filter.len) return false;
    if (!std.ascii.eqlIgnoreCase(value[value.len - filter.len ..], filter)) return false;
    return value[value.len - filter.len - 1] == '.';
}

fn freeSubscription(allocator: std.mem.Allocator, sub: EventSubscription) void {
    if (sub.domain) |domain| allocator.free(domain);
    if (sub.kinds.len > 0) allocator.free(sub.kinds);
}

test "host parser extracts host" {
    try std.testing.expectEqualStrings("example.com", hostFromUrl("https://example.com/path").?);
    try std.testing.expectEqualStrings("example.com", hostFromUrl("https://example.com:443/path").?);
    try std.testing.expect(hostFromUrl("data:text/html,hello") == null);
}

test "domain matcher handles subdomains" {
    try std.testing.expect(domainMatches("api.example.com", "example.com"));
    try std.testing.expect(domainMatches("example.com", "example.com"));
    try std.testing.expect(!domainMatches("evil-example.com", "example.com"));
    try std.testing.expect(!domainMatches("example.org", "example.com"));
    try std.testing.expect(string_util.containsIgnoreCase("Example.Com", "example"));
}

test "matchesKind accepts empty filter and exact kind" {
    const nav_event: types.LifecycleEvent = .{ .navigation_started = .{ .url = "https://example.com" } };
    const challenge_event: types.LifecycleEvent = .{
        .challenge_detected = .{ .url = "https://example.com/challenge", .signal = "title_challenge_heuristic" },
    };
    try std.testing.expect(matchesKind(&.{}, nav_event));
    try std.testing.expect(matchesKind(&.{.navigation_started}, nav_event));
    try std.testing.expect(!matchesKind(&.{.cookie_updated}, nav_event));
    try std.testing.expect(matchesKind(&.{.challenge_detected}, challenge_event));
    try std.testing.expect(!matchesKind(&.{.challenge_solved}, challenge_event));
}

fn makeTestSession(allocator: std.mem.Allocator) !Session {
    return .{
        .allocator = allocator,
        .id = 1,
        .mode = .browser,
        .transport = .cdp_ws,
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, "test-browser"),
            .version = null,
            .source = .explicit,
        },
        .capability_set = .{
            .dom = true,
            .js_eval = true,
            .network_intercept = false,
            .tracing = false,
            .downloads = false,
            .bidi_events = false,
        },
        .adapter_kind = .cdp,
        .endpoint = null,
        .browsing_context_id = null,
    };
}

const EventCapture = struct {
    navigation_started: usize = 0,
    network_request_observed: usize = 0,
    wait_failed: usize = 0,
    action_failed: usize = 0,
    challenge_detected: usize = 0,
    cookie_updated: usize = 0,
};

var event_capture: EventCapture = .{};

fn resetEventCapture() void {
    event_capture = .{};
}

fn captureEvent(event: types.LifecycleEvent) void {
    switch (event) {
        .navigation_started => event_capture.navigation_started += 1,
        .network_request_observed => event_capture.network_request_observed += 1,
        .wait_failed => event_capture.wait_failed += 1,
        .action_failed => event_capture.action_failed += 1,
        .challenge_detected => event_capture.challenge_detected += 1,
        .cookie_updated => event_capture.cookie_updated += 1,
        else => {},
    }
}

test "domainForEvent extracts lifecycle domains" {
    try std.testing.expectEqualStrings(
        "api.example.com",
        domainForEvent(.{
            .navigation_started = .{ .url = "https://api.example.com/path" },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "www.example.com",
        domainForEvent(.{
            .navigation_completed = .{ .url = "https://www.example.com:443/" },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "api.example.com",
        domainForEvent(.{
            .navigation_failed = .{
                .url = "https://api.example.com/path",
                .error_code = "Timeout",
            },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "example.com",
        domainForEvent(.{
            .reload_started = .{ .url = "https://example.com" },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "example.com",
        domainForEvent(.{
            .reload_completed = .{ .url = "https://example.com" },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "example.com",
        domainForEvent(.{
            .reload_failed = .{
                .url = "https://example.com",
                .error_code = "UnsupportedCapability",
            },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "api.example.com",
        domainForEvent(.{
            .network_request_observed = .{
                .request_id = "1",
                .method = "GET",
                .url = "https://api.example.com/v1",
            },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "api.example.com",
        domainForEvent(.{
            .network_response_observed = .{
                .request_id = "1",
                .status = 200,
                .url = "https://api.example.com/v1",
            },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "challenge.example.com",
        domainForEvent(.{
            .challenge_detected = .{
                .url = "https://challenge.example.com/interstitial",
                .signal = "title_challenge_heuristic",
            },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "challenge.example.com",
        domainForEvent(.{
            .challenge_solved = .{ .url = "https://challenge.example.com/home" },
        }).?,
    );
    try std.testing.expectEqualStrings(
        "Sub.Example.Com",
        domainForEvent(.{
            .cookie_updated = .{ .domain = "Sub.Example.Com", .name = "sid" },
        }).?,
    );
    try std.testing.expect(
        domainForEvent(.{
            .challenge_detected = .{ .url = "data:text/html,hello", .signal = "x" },
        }) == null,
    );
    try std.testing.expect(
        domainForEvent(.{
            .wait_failed = .{
                .target = .dom_ready,
                .elapsed_ms = 10,
                .error_code = "Timeout",
            },
        }) == null,
    );
    try std.testing.expect(
        domainForEvent(.{
            .action_failed = .{
                .kind = .evaluate,
                .error_code = "UnsupportedCapability",
            },
        }) == null,
    );
}

test "emit applies domain and kind filters across expanded lifecycle kinds" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator);
    defer session.deinit();

    resetEventCapture();

    const sub_id = try register(&session, .{
        .domain = "example.com",
        .kinds = &.{ .challenge_detected, .cookie_updated },
    }, captureEvent);
    defer _ = unregister(&session, sub_id);

    emit(&session, .{ .challenge_detected = .{
        .url = "https://api.example.com/challenge",
        .signal = "title_challenge_heuristic",
    } });
    emit(&session, .{ .challenge_solved = .{ .url = "https://api.example.com/ok" } });
    emit(&session, .{ .cookie_updated = .{ .domain = "Sub.Example.Com", .name = "sid" } });
    emit(&session, .{ .cookie_updated = .{ .domain = "example.org", .name = "sid" } });
    emit(&session, .{ .navigation_started = .{ .url = "https://example.com" } });

    try std.testing.expectEqual(@as(usize, 0), event_capture.navigation_started);
    try std.testing.expectEqual(@as(usize, 0), event_capture.network_request_observed);
    try std.testing.expectEqual(@as(usize, 0), event_capture.wait_failed);
    try std.testing.expectEqual(@as(usize, 0), event_capture.action_failed);
    try std.testing.expectEqual(@as(usize, 1), event_capture.challenge_detected);
    try std.testing.expectEqual(@as(usize, 1), event_capture.cookie_updated);
}

test "domain filter applies to network urls and excludes domainless hook kinds" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator);
    defer session.deinit();

    resetEventCapture();

    const sub_id = try register(&session, .{
        .domain = "example.com",
        .kinds = &.{ .network_request_observed, .wait_failed, .action_failed },
    }, captureEvent);
    defer _ = unregister(&session, sub_id);

    emit(&session, .{ .network_request_observed = .{
        .request_id = "1",
        .method = "GET",
        .url = "https://api.example.com/resource",
    } });
    emit(&session, .{ .network_request_observed = .{
        .request_id = "2",
        .method = "GET",
        .url = "https://outside.test/resource",
    } });
    emit(&session, .{ .wait_failed = .{
        .target = .dom_ready,
        .elapsed_ms = 10,
        .error_code = "Timeout",
    } });
    emit(&session, .{ .action_failed = .{
        .kind = .evaluate,
        .error_code = "UnsupportedCapability",
    } });

    try std.testing.expectEqual(@as(usize, 1), event_capture.network_request_observed);
    try std.testing.expectEqual(@as(usize, 0), event_capture.wait_failed);
    try std.testing.expectEqual(@as(usize, 0), event_capture.action_failed);
}

test "register copies filter buffers and unregister removes callback" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator);
    defer session.deinit();

    resetEventCapture();

    var mutable_kinds = [_]types.LifecycleEventKind{.challenge_detected};
    var mutable_domain = try allocator.dupe(u8, "example.com");
    defer allocator.free(mutable_domain);

    const sub_id = try register(&session, .{
        .domain = mutable_domain,
        .kinds = &mutable_kinds,
    }, captureEvent);

    mutable_kinds[0] = .navigation_started;
    mutable_domain[0] = 'x';

    emit(&session, .{
        .challenge_detected = .{
            .url = "https://api.example.com/challenge",
            .signal = "title_challenge_heuristic",
        },
    });
    try std.testing.expectEqual(@as(usize, 1), event_capture.challenge_detected);
    try std.testing.expectEqual(@as(usize, 0), event_capture.navigation_started);

    try std.testing.expect(unregister(&session, sub_id));
    try std.testing.expect(!unregister(&session, sub_id));

    emit(&session, .{
        .challenge_detected = .{
            .url = "https://api.example.com/challenge",
            .signal = "title_challenge_heuristic",
        },
    });
    try std.testing.expectEqual(@as(usize, 1), event_capture.challenge_detected);
}

test "domain filtered navigation skips events without host extraction" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator);
    defer session.deinit();

    resetEventCapture();

    const sub_id = try register(&session, .{
        .domain = "example.com",
        .kinds = &.{.navigation_started},
    }, captureEvent);
    defer _ = unregister(&session, sub_id);

    emit(&session, .{ .navigation_started = .{ .url = "data:text/html,hello" } });
    emit(&session, .{ .navigation_started = .{ .url = "https://api.example.com/path" } });

    try std.testing.expectEqual(@as(usize, 1), event_capture.navigation_started);
}
