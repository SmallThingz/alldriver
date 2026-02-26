const std = @import("std");

pub fn AsyncResult(comptime T: type) type {
    return struct {
        const Self = @This();
        const Runner = *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) anyerror!T;
        const Destroyer = *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void;
        const Canceler = *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void;

        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        thread: ?std.Thread = null,

        runner: Runner,
        destroyer: Destroyer,
        canceler: ?Canceler = null,
        ctx: *anyopaque,

        state: union(enum) {
            pending,
            completed: T,
            failed: anyerror,
            canceled,
            consumed,
        } = .pending,

        pub fn spawn(
            allocator: std.mem.Allocator,
            ctx: *anyopaque,
            runner: Runner,
            destroyer: Destroyer,
        ) !*Self {
            return spawnWithCancel(allocator, ctx, runner, destroyer, null);
        }

        pub fn spawnWithCancel(
            allocator: std.mem.Allocator,
            ctx: *anyopaque,
            runner: Runner,
            destroyer: Destroyer,
            canceler: ?Canceler,
        ) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .runner = runner,
                .destroyer = destroyer,
                .canceler = canceler,
                .ctx = ctx,
            };

            self.thread = try std.Thread.spawn(.{}, worker, .{self});
            return self;
        }

        pub fn await(self: *Self, timeout_ms: ?u32) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (timeout_ms) |ms| {
                const deadline_ns = std.time.nanoTimestamp() + @as(i128, @intCast(ms)) * std.time.ns_per_ms;
                while (self.state == .pending) {
                    const now = std.time.nanoTimestamp();
                    if (now >= deadline_ns) return error.Timeout;

                    const remaining: u64 = @intCast(deadline_ns - now);
                    self.cond.timedWait(&self.mutex, remaining) catch |err| switch (err) {
                        error.Timeout => return error.Timeout,
                    };
                }
            } else {
                while (self.state == .pending) {
                    self.cond.wait(&self.mutex);
                }
            }

            switch (self.state) {
                .completed => |value| {
                    self.state = .consumed;
                    return value;
                },
                .failed => |err| return err,
                .canceled => return error.Canceled,
                .consumed => return error.AlreadyConsumed,
                .pending => unreachable,
            }
        }

        pub fn cancel(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state == .pending) {
                if (self.canceler) |canceler| {
                    canceler(self.allocator, self.ctx);
                }
                self.state = .canceled;
                self.cond.broadcast();
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.thread) |t| t.join();
            self.allocator.destroy(self);
        }

        fn worker(self: *Self) void {
            const result = self.runner(self.allocator, self.ctx);
            self.destroyer(self.allocator, self.ctx);

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state == .canceled) {
                self.cond.broadcast();
                return;
            }

            if (result) |value| {
                self.state = .{ .completed = value };
            } else |err| {
                self.state = .{ .failed = err };
            }
            self.cond.broadcast();
        }
    };
}

test "async result completion" {
    const allocator = std.testing.allocator;

    const Ctx = struct { value: u32 };
    const ctx = try allocator.create(Ctx);
    ctx.* = .{ .value = 7 };

    const Runner = struct {
        fn run(_: std.mem.Allocator, p: *anyopaque) anyerror!u32 {
            const c: *Ctx = @ptrCast(@alignCast(p));
            return c.value;
        }

        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(p));
            a.destroy(c);
        }
    };

    var op = try AsyncResult(u32).spawn(allocator, ctx, Runner.run, Runner.destroy);
    defer op.deinit();

    const result = try op.await(5_000);
    try std.testing.expectEqual(@as(u32, 7), result);
}

test "async await timeout" {
    const allocator = std.testing.allocator;

    const Ctx = struct {};
    const ctx = try allocator.create(Ctx);
    ctx.* = .{};

    const Runner = struct {
        fn run(_: std.mem.Allocator, _: *anyopaque) anyerror!u32 {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            return 1;
        }

        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(p));
            a.destroy(c);
        }
    };

    var op = try AsyncResult(u32).spawn(allocator, ctx, Runner.run, Runner.destroy);
    defer op.deinit();

    try std.testing.expectError(error.Timeout, op.await(1));
}

test "async cancel before completion" {
    const allocator = std.testing.allocator;

    const Ctx = struct {};
    const ctx = try allocator.create(Ctx);
    ctx.* = .{};

    const Runner = struct {
        fn run(_: std.mem.Allocator, _: *anyopaque) anyerror!u32 {
            std.Thread.sleep(80 * std.time.ns_per_ms);
            return 2;
        }

        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(p));
            a.destroy(c);
        }
    };

    var op = try AsyncResult(u32).spawn(allocator, ctx, Runner.run, Runner.destroy);
    defer op.deinit();

    op.cancel();
    try std.testing.expectError(error.Canceled, op.await(1000));
}

test "async double await" {
    const allocator = std.testing.allocator;

    const Ctx = struct {};
    const ctx = try allocator.create(Ctx);
    ctx.* = .{};

    const Runner = struct {
        fn run(_: std.mem.Allocator, _: *anyopaque) anyerror!u32 {
            return 42;
        }

        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(p));
            a.destroy(c);
        }
    };

    var op = try AsyncResult(u32).spawn(allocator, ctx, Runner.run, Runner.destroy);
    defer op.deinit();

    const first = try op.await(1000);
    try std.testing.expectEqual(@as(u32, 42), first);
    try std.testing.expectError(error.AlreadyConsumed, op.await(1000));
}
