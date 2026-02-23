const std = @import("std");
const Session = @import("session.zig").Session;

pub const RequestEvent = struct {
    method: []const u8,
    url: []const u8,
};

pub const ResponseEvent = struct {
    status: u16,
    url: []const u8,
};

pub fn enableInterception(session: *Session) !void {
    if (!session.capabilities.network_intercept) return error.UnsupportedCapability;
}

pub fn disableInterception(session: *Session) !void {
    if (!session.capabilities.network_intercept) return error.UnsupportedCapability;
}

pub fn subscribe(session: *Session, callback: *const fn (event_json: []const u8) void) !void {
    _ = callback;
    if (!session.capabilities.network_intercept) return error.UnsupportedCapability;
}

pub fn emitDebugEvent(session: *Session, event_json: []const u8) void {
    _ = session;
    _ = event_json;
}

pub fn serializeBlockRule(allocator: std.mem.Allocator, glob: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{\"action\":\"block\",\"urlPattern\":\"{s}\"}", .{glob});
}
