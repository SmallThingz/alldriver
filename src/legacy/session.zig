const core_session = @import("../core/session.zig");
const types = @import("../types.zig");
const support_tier = @import("../catalog/support_tier.zig");

pub const LegacySession = struct {
    base: core_session.Session,

    pub fn fromBase(base: core_session.Session) !LegacySession {
        if (support_tier.transportTier(base.transport) != .legacy) {
            var tmp = base;
            tmp.deinit();
            return error.UnsupportedProtocol;
        }
        return .{ .base = base };
    }

    pub fn deinit(self: *LegacySession) void {
        self.base.deinit();
        self.* = undefined;
    }

    pub fn intoBase(self: *LegacySession) core_session.Session {
        const moved = self.base;
        self.* = undefined;
        return moved;
    }

    pub fn capabilities(self: *const LegacySession) types.CapabilitySet {
        return self.base.capabilities();
    }

    pub fn supports(self: *const LegacySession, feature: types.CapabilityFeature) bool {
        return self.base.supports(feature);
    }

    pub fn navigate(self: *LegacySession, url: []const u8) !void {
        try self.base.navigate(url);
    }

    pub fn click(self: *LegacySession, selector: []const u8) !void {
        try self.base.click(selector);
    }

    pub fn typeText(self: *LegacySession, selector: []const u8, text: []const u8) !void {
        try self.base.typeText(selector, text);
    }

    pub fn evaluate(self: *LegacySession, script: []const u8) ![]u8 {
        return self.base.evaluate(script);
    }
};
