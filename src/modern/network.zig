const session_mod = @import("session.zig");
const types = @import("../types.zig");

pub const NetworkClient = struct {
    session: *session_mod.ModernSession,

    pub fn enable(self: *NetworkClient) !void {
        try self.session.base.enableNetworkInterception();
    }

    pub fn disable(self: *NetworkClient) !void {
        try self.session.base.clearInterceptRules();
    }

    pub fn addRule(self: *NetworkClient, rule: types.NetworkRule) !void {
        try self.session.base.addInterceptRule(rule);
    }

    pub fn removeRule(self: *NetworkClient, rule_id: []const u8) !bool {
        return self.session.base.removeInterceptRule(rule_id);
    }

    pub fn onRequest(self: *NetworkClient, callback: *const fn (types.RequestEvent) void) void {
        self.session.base.onRequest(callback);
    }

    pub fn onResponse(self: *NetworkClient, callback: *const fn (types.ResponseEvent) void) void {
        self.session.base.onResponse(callback);
    }
};
