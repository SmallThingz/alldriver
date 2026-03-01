const Session = @import("session.zig").Session;
const executor = @import("../protocol/executor.zig");

pub fn navigate(session: *Session, url: []const u8) !void {
    if (!session.supports(.dom)) return error.UnsupportedCapability;
    try executor.navigate(session, url);

    session.state_lock.lock();
    defer session.state_lock.unlock();
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
