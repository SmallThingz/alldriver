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
        .challenge_detected => |e| hostFromUrl(e.url),
        .challenge_solved => |e| hostFromUrl(e.url),
        .cookie_updated => |e| e.domain,
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
    try std.testing.expect(matchesKind(&.{}, nav_event));
    try std.testing.expect(matchesKind(&.{.navigation_started}, nav_event));
    try std.testing.expect(!matchesKind(&.{.cookie_updated}, nav_event));
}
