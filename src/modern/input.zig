const std = @import("std");
const session_mod = @import("session.zig");
const json_util = @import("../util/json.zig");

pub const InputClient = struct {
    session: *session_mod.ModernSession,

    pub fn click(self: *InputClient, selector: []const u8) !void {
        try self.session.base.click(selector);
    }

    pub fn typeText(self: *InputClient, selector: []const u8, text: []const u8) !void {
        try self.session.base.typeText(selector, text);
    }

    pub fn keyDown(self: *InputClient, key: []const u8) !void {
        try dispatchKeyboard(self.session, key, "keydown");
    }

    pub fn keyUp(self: *InputClient, key: []const u8) !void {
        try dispatchKeyboard(self.session, key, "keyup");
    }

    pub fn mouseMove(self: *InputClient, x: i32, y: i32) !void {
        const script = try std.fmt.allocPrint(
            self.session.base.allocator,
            "(function(){{document.dispatchEvent(new MouseEvent('mousemove',{{clientX:{d},clientY:{d},bubbles:true}}));return true;}})();",
            .{ x, y },
        );
        defer self.session.base.allocator.free(script);
        const payload = try self.session.base.evaluate(script);
        self.session.base.allocator.free(payload);
    }

    pub fn wheel(self: *InputClient, delta_x: i32, delta_y: i32) !void {
        const script = try std.fmt.allocPrint(
            self.session.base.allocator,
            "(function(){{document.dispatchEvent(new WheelEvent('wheel',{{deltaX:{d},deltaY:{d},bubbles:true}}));return true;}})();",
            .{ delta_x, delta_y },
        );
        defer self.session.base.allocator.free(script);
        const payload = try self.session.base.evaluate(script);
        self.session.base.allocator.free(payload);
    }
};

fn dispatchKeyboard(session: *session_mod.ModernSession, key: []const u8, event_kind: []const u8) !void {
    const escaped = try json_util.escapeJsonString(session.base.allocator, key);
    defer session.base.allocator.free(escaped);
    const script = try std.fmt.allocPrint(
        session.base.allocator,
        "(function(){{document.dispatchEvent(new KeyboardEvent('{s}',{{key:\"{s}\",bubbles:true}}));return true;}})();",
        .{ event_kind, escaped },
    );
    defer session.base.allocator.free(script);
    const payload = try session.base.evaluate(script);
    session.base.allocator.free(payload);
}
