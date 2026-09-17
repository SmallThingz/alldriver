const std = @import("std");
const artifacts = @import("../core/artifacts.zig");
const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");
const compat = @import("../util/compat.zig");

pub const PageClient = struct {
    session: *session_mod.ModernSession,

    pub fn navigate(self: *PageClient, url: []const u8) !void {
        try self.session.base.navigate(url);
    }

    pub fn reload(self: *PageClient) !void {
        try self.session.base.reload();
    }

    pub fn goBack(self: *PageClient) !void {
        try self.navigateHistory(-1);
    }

    pub fn goForward(self: *PageClient) !void {
        try self.navigateHistory(1);
    }

    pub fn setViewport(self: *PageClient, width: u32, height: u32) !void {
        if (width == 0 or height == 0 or width > 10_000_000 or height > 10_000_000)
            return error.InvalidViewport;
        const params = try std.fmt.allocPrint(
            self.session.base.allocator,
            "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":1,\"mobile\":false}}",
            .{ width, height },
        );
        defer self.session.base.allocator.free(params);
        const payload = try executor.callCdp(&self.session.base, "Emulation.setDeviceMetricsOverride", params);
        self.session.base.allocator.free(payload);
    }

    fn navigateHistory(self: *PageClient, offset: i64) !void {
        const allocator = self.session.base.allocator;
        const history = try executor.callCdp(&self.session.base, "Page.getNavigationHistory", "{}");
        defer allocator.free(history);
        const target = try historyTarget(allocator, history, offset) orelse return;
        const params = try std.fmt.allocPrint(allocator, "{{\"entryId\":{d}}}", .{target});
        defer allocator.free(params);
        const payload = try executor.callCdp(&self.session.base, "Page.navigateToHistoryEntry", params);
        allocator.free(payload);

        const timeout = self.session.base.timeoutPolicy().navigate_ms;
        const deadline = compat.milliTimestamp() + @as(i64, timeout);
        while (true) {
            const current = executor.callCdp(&self.session.base, "Page.getNavigationHistory", "{}") catch |err| {
                // Cross-document history traversal can temporarily detach the
                // renderer. Only retry this read, never the navigation itself.
                if (err != error.PageNotActive) return err;
                if (compat.milliTimestamp() >= deadline) return error.Timeout;
                compat.sleepMs(10);
                continue;
            };
            defer allocator.free(current);
            if (try historyTarget(allocator, current, 0) == target) break;
            if (compat.milliTimestamp() >= deadline) return error.Timeout;
            compat.sleepMs(10);
        }
        const remaining: u32 = @intCast(@max(0, deadline - compat.milliTimestamp()));
        try executor.waitForDomReady(&self.session.base, remaining);
    }

    pub fn screenshot(
        self: *PageClient,
        allocator: std.mem.Allocator,
        format: artifacts.ScreenshotFormat,
    ) ![]u8 {
        return self.session.base.screenshot(allocator, format);
    }
};

fn historyTarget(allocator: std.mem.Allocator, payload: []const u8, offset: i64) !?i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const index = result.object.get("currentIndex") orelse return error.InvalidResponse;
    const entries = result.object.get("entries") orelse return error.InvalidResponse;
    if (index != .integer or entries != .array) return error.InvalidResponse;
    if (index.integer < 0 or index.integer >= entries.array.items.len) return error.InvalidResponse;
    const next = index.integer + offset;
    if (next < 0 or next >= entries.array.items.len) return null;
    const entry = entries.array.items[@intCast(next)];
    if (entry != .object) return error.InvalidResponse;
    const id = entry.object.get("id") orelse return error.InvalidResponse;
    if (id != .integer) return error.InvalidResponse;
    return id.integer;
}
