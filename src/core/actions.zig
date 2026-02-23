const std = @import("std");
const Session = @import("session.zig").Session;

pub const WaitCondition = enum {
    dom_ready,
    network_idle,
    selector_visible,
};

pub fn navigate(session: *Session, url: []const u8) !void {
    if (!session.capabilities.dom) return error.UnsupportedCapability;

    if (session.current_url) |old| {
        session.allocator.free(old);
    }
    session.current_url = try session.allocator.dupe(u8, url);
}

pub fn reload(session: *Session) !void {
    if (!session.capabilities.dom) return error.UnsupportedCapability;
    if (session.current_url == null) return error.NoActivePage;
}

pub fn click(session: *Session, selector: []const u8) !void {
    _ = selector;
    if (!session.capabilities.dom) return error.UnsupportedCapability;
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    _ = selector;
    _ = text;
    if (!session.capabilities.dom) return error.UnsupportedCapability;
}

pub fn evaluate(session: *Session, script: []const u8) ![]u8 {
    if (!session.capabilities.js_eval) return error.UnsupportedCapability;
    return std.fmt.allocPrint(session.allocator, "{\"script\":\"{s}\",\"status\":\"queued\"}", .{script});
}

pub fn waitFor(session: *Session, condition: WaitCondition, timeout_ms: u32) !void {
    _ = condition;
    _ = timeout_ms;
    if (!session.capabilities.dom) return error.UnsupportedCapability;
}
