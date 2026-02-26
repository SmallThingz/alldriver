const core_session = @import("../core/session.zig");
const types = @import("../types.zig");
const session_common = @import("../tier/session_common.zig");

pub const LegacySession = struct {
    base: core_session.Session,

    pub fn fromBase(base: core_session.Session) !LegacySession {
        return .{ .base = try session_common.fromBase(base, .legacy) };
    }

    pub fn deinit(self: *LegacySession) void {
        session_common.deinit(&self.base);
    }

    pub fn intoBase(self: *LegacySession) core_session.Session {
        return session_common.intoBase(&self.base);
    }

    pub fn capabilities(self: *const LegacySession) types.CapabilitySet {
        return session_common.capabilities(&self.base);
    }

    pub fn supports(self: *const LegacySession, feature: types.CapabilityFeature) bool {
        return session_common.supports(&self.base, feature);
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
