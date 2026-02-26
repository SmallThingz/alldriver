const std = @import("std");
const artifacts = @import("../core/artifacts.zig");
const session_mod = @import("session.zig");

pub const PageClient = struct {
    session: *session_mod.ModernSession,

    pub fn navigate(self: *PageClient, url: []const u8) !void {
        try self.session.base.navigate(url);
    }

    pub fn reload(self: *PageClient) !void {
        try self.session.base.reload();
    }

    pub fn goBack(self: *PageClient) !void {
        const payload = try self.session.base.evaluate("history.back(); true;");
        self.session.base.allocator.free(payload);
    }

    pub fn goForward(self: *PageClient) !void {
        const payload = try self.session.base.evaluate("history.forward(); true;");
        self.session.base.allocator.free(payload);
    }

    pub fn setViewport(self: *PageClient, width: u32, height: u32) !void {
        const script = try std.fmt.allocPrint(
            self.session.base.allocator,
            "(function(){{window.__alldriver_viewport={{width:{d},height:{d}}}; return true;}})();",
            .{ width, height },
        );
        defer self.session.base.allocator.free(script);
        const payload = try self.session.base.evaluate(script);
        self.session.base.allocator.free(payload);
    }

    pub fn screenshot(
        self: *PageClient,
        allocator: std.mem.Allocator,
        format: artifacts.ScreenshotFormat,
    ) ![]u8 {
        return self.session.base.screenshot(allocator, format);
    }
};
