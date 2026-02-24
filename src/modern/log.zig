const session_mod = @import("session.zig");

pub const LogEntry = struct {
    level: []const u8,
    text: []const u8,
    source: []const u8,
};

pub const LogClient = struct {
    session: *session_mod.ModernSession,

    pub fn onConsole(self: *LogClient, callback: *const fn (LogEntry) void) !void {
        _ = self;
        _ = callback;
        return error.UnsupportedProtocol;
    }

    pub fn onException(self: *LogClient, callback: *const fn (LogEntry) void) !void {
        _ = self;
        _ = callback;
        return error.UnsupportedProtocol;
    }
};
