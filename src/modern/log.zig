const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");
const core_log = @import("../core/log.zig");

pub const LogEntry = core_log.LogEntry;

pub const LogClient = struct {
    session: *session_mod.ModernSession,

    pub fn onConsole(self: *LogClient, callback: *const fn (LogEntry) void) !void {
        try self.enableRuntime();
        self.session.base.state_lock.lock();
        defer self.session.base.state_lock.unlock();
        self.session.base.console_callback = callback;
    }

    pub fn onException(self: *LogClient, callback: *const fn (LogEntry) void) !void {
        try self.enableRuntime();
        self.session.base.state_lock.lock();
        defer self.session.base.state_lock.unlock();
        self.session.base.exception_callback = callback;
    }

    pub fn clearConsole(self: *LogClient) void {
        self.session.base.state_lock.lock();
        defer self.session.base.state_lock.unlock();
        self.session.base.console_callback = null;
    }

    pub fn clearException(self: *LogClient) void {
        self.session.base.state_lock.lock();
        defer self.session.base.state_lock.unlock();
        self.session.base.exception_callback = null;
    }

    fn enableRuntime(self: *LogClient) !void {
        if (self.session.base.transport != .cdp_ws) return error.UnsupportedProtocol;
        const payload = try executor.callCdp(&self.session.base, "Runtime.enable", "{}");
        self.session.base.allocator.free(payload);
    }
};
