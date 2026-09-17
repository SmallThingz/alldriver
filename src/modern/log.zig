const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");
const core_log = @import("../core/log.zig");

pub const LogEntry = core_log.LogEntry;

pub const LogClient = struct {
    session: *session_mod.ModernSession,

    pub fn onConsole(self: *LogClient, callback: *const fn (LogEntry) void) !void {
        const observer = try self.ensureObserver();
        try observer.setConsole(callback);
    }

    pub fn onException(self: *LogClient, callback: *const fn (LogEntry) void) !void {
        const observer = try self.ensureObserver();
        try observer.setException(callback);
    }

    pub fn clearConsole(self: *LogClient) void {
        if (self.session.base.log_observer) |observer| observer.clearConsole();
    }

    pub fn clearException(self: *LogClient) void {
        if (self.session.base.log_observer) |observer| observer.clearException();
    }

    fn ensureObserver(self: *LogClient) !*core_log.Observer {
        if (self.session.base.transport != .cdp_ws) return error.UnsupportedProtocol;
        if (self.session.base.log_observer) |observer| return observer;
        const endpoint = try executor.pageWebSocketEndpoint(&self.session.base);
        defer self.session.base.allocator.free(endpoint);
        const observer = try core_log.Observer.create(self.session.base.allocator, endpoint);
        self.session.base.log_observer = observer;
        return observer;
    }
};
