const std = @import("std");
const compat = @import("../util/compat.zig");

pub fn AsyncResult(comptime T: type) type {
    return struct {
        const Self = @This();
        const Runner = *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) anyerror!T;
        const Destroyer = *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void;
        const Canceler = *const fn (allocator: std.mem.Allocator, ctx: *anyopaque) void;

        allocator: std.mem.Allocator,
        mutex: compat.Mutex = .{},
        cond: compat.Condition = .{},
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
            // Ownership of ctx transfers on entry, including every failure.
            errdefer destroyer(allocator, ctx);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
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
                const deadline_ns = compat.nanoTimestamp() + @as(i128, @intCast(ms)) * std.time.ns_per_ms;
                while (self.state == .pending) {
                    const now = compat.nanoTimestamp();
                    if (now >= deadline_ns) return error.Timeout;
                    self.mutex.unlock();
                    compat.sleepMs(1);
                    self.mutex.lock();
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

        /// Request cooperative cancellation. Returns false when the operation
        /// cannot stop safely, or has already completed. A true result means
        /// the cancellation callback ran; deinit still joins the worker.
        pub fn requestCancel(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .pending) return false;
            const canceler = self.canceler orelse return false;
            canceler(self.allocator, self.ctx);
            self.state = .canceled;
            self.cond.broadcast();
            return true;
        }

        /// Non-cooperative operations continue and retain their actual result.
        /// Use requestCancel when the caller needs to know whether cancellation
        /// was accepted. Cancellation never implies that the worker has exited.
        pub fn cancel(self: *Self) void {
            _ = self.requestCancel();
        }

        pub fn isCancelable(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.state == .pending and self.canceler != null;
        }

        /// Joins the worker and releases an unconsumed owned result. Buffers
        /// use the operation allocator; managed structs invoke their deinit.
        /// Successful await transfers ownership to the caller exactly once.
        pub fn deinit(self: *Self) void {
            if (self.thread) |t| t.join();
            switch (self.state) {
                .completed => |value| self.discardResult(value),
                else => {},
            }
            self.allocator.destroy(self);
        }

        fn discardResult(self: *Self, value: T) void {
            if (T == []u8) {
                self.allocator.free(value);
            } else switch (@typeInfo(T)) {
                .@"struct" => {
                    // Launch futures own Sessions, which include browser
                    // processes, subscriptions and profile directories.
                    if (@hasDecl(T, "deinit")) {
                        var owned = value;
                        owned.deinit();
                    }
                },
                else => {},
            }
        }

        fn worker(self: *Self) void {
            const result = self.runner(self.allocator, self.ctx);
            self.mutex.lock();
            defer self.mutex.unlock();

            // canceler and destroyer share this lock: cancellation must never
            // inspect a context after its destroyer has reclaimed it.
            if (self.state == .canceled) {
                if (result) |value| self.discardResult(value) else |_| {}
            } else if (result) |value| {
                self.state = .{ .completed = value };
            } else |err| {
                self.state = .{ .failed = err };
            }
            self.destroyer(self.allocator, self.ctx);
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
            compat.sleepMs(100);
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

test "async operation without cooperative cancellation retains its outcome" {
    const allocator = std.testing.allocator;

    const Ctx = struct {};
    const ctx = try allocator.create(Ctx);
    ctx.* = .{};

    const Runner = struct {
        fn run(_: std.mem.Allocator, _: *anyopaque) anyerror!u32 {
            compat.sleepMs(80);
            return 2;
        }

        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(p));
            a.destroy(c);
        }
    };

    var op = try AsyncResult(u32).spawn(allocator, ctx, Runner.run, Runner.destroy);
    defer op.deinit();

    try std.testing.expect(!op.isCancelable());
    try std.testing.expect(!op.requestCancel());
    op.cancel();
    try std.testing.expectEqual(@as(u32, 2), try op.await(1000));
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

test "cooperative cancellation disposes a late owned result and destroys context once" {
    const allocator = std.testing.allocator;
    const State = struct {
        release: std.atomic.Value(bool) = .init(false),
        canceled: std.atomic.Value(u32) = .init(0),
        destroyed: std.atomic.Value(u32) = .init(0),
    };
    const Ctx = struct { state: *State };
    const Runner = struct {
        fn run(a: std.mem.Allocator, p: *anyopaque) anyerror![]u8 {
            const ctx: *Ctx = @ptrCast(@alignCast(p));
            while (!ctx.state.release.load(.acquire)) compat.sleepMs(1);
            // A cooperative operation can finish successfully concurrently with
            // cancellation; the unpublished result must still be reclaimed.
            return a.dupe(u8, "late result");
        }
        fn cancel(_: std.mem.Allocator, p: *anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(p));
            _ = ctx.state.canceled.fetchAdd(1, .monotonic);
            ctx.state.release.store(true, .release);
        }
        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(p));
            _ = ctx.state.destroyed.fetchAdd(1, .monotonic);
            a.destroy(ctx);
        }
    };
    var state: State = .{};
    const ctx = try allocator.create(Ctx);
    ctx.* = .{ .state = &state };
    const op = try AsyncResult([]u8).spawnWithCancel(allocator, ctx, Runner.run, Runner.destroy, Runner.cancel);
    try std.testing.expect(op.isCancelable());
    try std.testing.expect(op.requestCancel());
    try std.testing.expect(!op.requestCancel());
    try std.testing.expectError(error.Canceled, op.await(1000));
    op.deinit();
    try std.testing.expectEqual(@as(u32, 1), state.canceled.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), state.destroyed.load(.acquire));
}

test "owned results are freed when abandoned and transferred only once when awaited" {
    const allocator = std.testing.allocator;
    const Runner = struct {
        fn run(a: std.mem.Allocator, _: *anyopaque) anyerror![]u8 {
            return a.dupe(u8, "owned");
        }
        fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
    };
    var context: u8 = 0;
    const abandoned = try AsyncResult([]u8).spawn(allocator, &context, Runner.run, Runner.destroy);
    abandoned.deinit();
    const consumed = try AsyncResult([]u8).spawn(allocator, &context, Runner.run, Runner.destroy);
    const result = try consumed.await(1000);
    try std.testing.expectError(error.AlreadyConsumed, consumed.await(1000));
    consumed.deinit();
    try std.testing.expectEqualStrings("owned", result);
    allocator.free(result);
}

test "cancel cannot access context while completion destroys it" {
    const allocator = std.testing.allocator;
    const State = struct {
        destroying: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        cancel_called: std.atomic.Value(bool) = .init(false),
    };
    const Ctx = struct { state: *State };
    const Runner = struct {
        fn run(_: std.mem.Allocator, _: *anyopaque) anyerror!u32 {
            return 19;
        }
        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(p));
            ctx.state.destroying.store(true, .release);
            while (!ctx.state.release.load(.acquire)) compat.sleepMs(1);
            a.destroy(ctx);
        }
        fn cancel(_: std.mem.Allocator, p: *anyopaque) void {
            const ctx: *Ctx = @ptrCast(@alignCast(p));
            ctx.state.cancel_called.store(true, .release);
        }
        fn release(state: *State) void {
            compat.sleepMs(20);
            state.release.store(true, .release);
        }
    };
    var state: State = .{};
    const ctx = try allocator.create(Ctx);
    ctx.* = .{ .state = &state };
    const op = try AsyncResult(u32).spawnWithCancel(allocator, ctx, Runner.run, Runner.destroy, Runner.cancel);
    defer op.deinit();
    while (!state.destroying.load(.acquire)) compat.sleepMs(1);
    const releaser = try std.Thread.spawn(.{}, Runner.release, .{&state});
    defer releaser.join();
    try std.testing.expect(!op.requestCancel());
    try std.testing.expect(!state.cancel_called.load(.acquire));
    try std.testing.expectEqual(@as(u32, 19), try op.await(1000));
}

test "unawaited managed results deinitialize and awaited results transfer ownership" {
    const Managed = struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        destroyed: *usize,
        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.bytes);
            self.destroyed.* += 1;
        }
    };
    const Runner = struct {
        fn run(a: std.mem.Allocator, context: *anyopaque) anyerror!Managed {
            const destroyed: *usize = @ptrCast(@alignCast(context));
            return .{ .allocator = a, .bytes = try a.dupe(u8, "owned session resource"), .destroyed = destroyed };
        }
        fn destroy(_: std.mem.Allocator, _: *anyopaque) void {}
    };
    const allocator = std.testing.allocator;
    var destroyed: usize = 0;
    const abandoned = try AsyncResult(Managed).spawn(allocator, &destroyed, Runner.run, Runner.destroy);
    abandoned.deinit();
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    const consumed = try AsyncResult(Managed).spawn(allocator, &destroyed, Runner.run, Runner.destroy);
    var result = try consumed.await(1000);
    consumed.deinit();
    try std.testing.expectEqual(@as(usize, 1), destroyed);
    try std.testing.expectEqualStrings("owned session resource", result.bytes);
    result.deinit();
    try std.testing.expectEqual(@as(usize, 2), destroyed);
}
