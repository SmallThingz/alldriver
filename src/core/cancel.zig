const std = @import("std");

pub const CancelToken = struct {
    mutex: std.Thread.Mutex = .{},
    canceled: bool = false,

    pub fn init() CancelToken {
        return .{};
    }

    pub fn cancel(self: *CancelToken) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.canceled = true;
    }

    pub fn isCanceled(self: *const CancelToken) bool {
        const mut_self: *CancelToken = @constCast(self);
        mut_self.mutex.lock();
        defer mut_self.mutex.unlock();
        return mut_self.canceled;
    }
};

test "cancel token toggles to canceled" {
    var token = CancelToken.init();
    try std.testing.expect(!token.isCanceled());
    token.cancel();
    try std.testing.expect(token.isCanceled());
}
