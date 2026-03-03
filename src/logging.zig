const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

pub const HardErrorLog = struct {
    session_id: ?u64 = null,
    phase: ?types.TimeoutPhase = null,
    code: []const u8,
    message: []const u8,
    transport: ?[]const u8 = null,
};

pub const HardErrorLogger = fn (entry: HardErrorLog) void;

var logger_lock: std.Thread.Mutex = .{};
var logger_callback: ?*const HardErrorLogger = null;

pub fn setHardErrorLogger(callback: ?*const HardErrorLogger) void {
    logger_lock.lock();
    defer logger_lock.unlock();
    logger_callback = callback;
}

pub fn hardErrorLogger() ?*const HardErrorLogger {
    logger_lock.lock();
    defer logger_lock.unlock();
    return logger_callback;
}

pub fn emitHardError(entry: HardErrorLog) void {
    const callback = hardErrorLogger();
    if (callback) |log_fn| {
        log_fn(entry);
        return;
    }

    // Default stderr hard-error logs are useful in runtime diagnostics, but
    // test suites intentionally trigger some failure paths and become noisy.
    if (builtin.is_test) return;

    std.debug.print(
        "[alldriver][hard-error] session={any} phase={s} code={s} transport={s} message={s}\n",
        .{
            entry.session_id,
            if (entry.phase) |phase| @tagName(phase) else "unknown",
            entry.code,
            entry.transport orelse "unknown",
            entry.message,
        },
    );
}

var test_log_count: usize = 0;
var test_saw_custom_code = false;

fn testLogger(entry: HardErrorLog) void {
    test_log_count += 1;
    if (std.mem.eql(u8, entry.code, "test_code")) {
        test_saw_custom_code = true;
    }
}

test "setHardErrorLogger installs callback and receives emissions" {
    test_log_count = 0;
    test_saw_custom_code = false;
    setHardErrorLogger(testLogger);
    defer setHardErrorLogger(null);

    emitHardError(.{
        .session_id = 42,
        .phase = .overall,
        .code = "test_code",
        .message = "test message",
        .transport = "cdp_ws",
    });

    try std.testing.expectEqual(@as(usize, 1), test_log_count);
    try std.testing.expect(test_saw_custom_code);
}
