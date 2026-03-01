const std = @import("std");
const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");

pub const RuntimeClient = struct {
    session: *session_mod.ModernSession,

    pub fn evaluate(self: *RuntimeClient, script: []const u8) ![]u8 {
        return self.session.base.evaluate(script);
    }

    pub fn callFunction(
        self: *RuntimeClient,
        function_source: []const u8,
        args_json: []const u8,
    ) ![]u8 {
        const script = try std.fmt.allocPrint(
            self.session.base.allocator,
            "(function(){{const fn=({s});return fn.apply(null,{s});}})();",
            .{ function_source, args_json },
        );
        defer self.session.base.allocator.free(script);
        return self.session.base.evaluate(script);
    }

    pub fn releaseHandle(self: *RuntimeClient, handle_id: []const u8) !void {
        try executor.releaseHandle(&self.session.base, handle_id);
    }
};
