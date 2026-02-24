const executor = @import("executor.zig");
const support_tier = @import("../catalog/support_tier.zig");
const Session = @import("../core/session.zig").Session;
const types = @import("../types.zig");

fn assertLegacy(session: *Session) !void {
    if (support_tier.transportTier(session.transport) != .legacy) return error.UnsupportedProtocol;
}

pub fn navigate(session: *Session, url: []const u8) !void {
    try assertLegacy(session);
    try executor.navigate(session, url);
}

pub fn reload(session: *Session) !void {
    try assertLegacy(session);
    try executor.reload(session);
}

pub fn click(session: *Session, selector: []const u8) !void {
    try assertLegacy(session);
    try executor.click(session, selector);
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    try assertLegacy(session);
    try executor.typeText(session, selector, text);
}

pub fn evaluate(session: *Session, script: []const u8) ![]u8 {
    try assertLegacy(session);
    return executor.evaluate(session, script);
}

pub fn setCookie(session: *Session, cookie: types.Header, domain: []const u8, path: []const u8) !void {
    try assertLegacy(session);
    try executor.setCookie(session, cookie, domain, path);
}

pub fn getCookies(session: *Session) ![]u8 {
    try assertLegacy(session);
    return executor.getCookies(session);
}
