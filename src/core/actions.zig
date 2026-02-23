const std = @import("std");
const Session = @import("session.zig").Session;
const executor = @import("../protocol/executor.zig");

pub const WaitCondition = enum {
    dom_ready,
    network_idle,
    selector_visible,
};

pub fn navigate(session: *Session, url: []const u8) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    try executor.navigate(session, url);

    if (session.current_url) |old| session.allocator.free(old);
    session.current_url = try session.allocator.dupe(u8, url);
}

pub fn reload(session: *Session) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    try executor.reload(session);
}

pub fn click(session: *Session, selector: []const u8) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    try executor.click(session, selector);
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    try executor.typeText(session, selector, text);
}

pub fn evaluate(session: *Session, script: []const u8) ![]u8 {
    if (!session.supports(.js_eval)) return error.UnsupportedCapability;
    return executor.evaluate(session, script);
}

pub fn waitFor(session: *Session, condition: WaitCondition, timeout_ms: u32) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;

    return switch (condition) {
        .dom_ready => executor.waitForDomReady(session, timeout_ms),
        .network_idle => waitForNetworkIdle(session, timeout_ms),
        .selector_visible => executor.waitForSelector(session, "body", timeout_ms),
    };
}

pub fn waitForSelector(session: *Session, selector: []const u8, timeout_ms: u32) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    try executor.waitForSelector(session, selector, timeout_ms);
}

fn waitForNetworkIdle(session: *Session, timeout_ms: u32) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    // Heuristic fallback across protocols: wait until document is complete and no loading overlays are visible.
    const script =
        "(function(){return document.readyState==='complete' && (!window.__webdriver_active_requests || window.__webdriver_active_requests===0);})();";

    while (true) {
        const result = try evaluate(session, script);
        defer session.allocator.free(result);

        if (std.mem.indexOf(u8, result, "true") != null) return;
        if (std.time.milliTimestamp() >= deadline) return error.Timeout;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}
