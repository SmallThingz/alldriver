const core_session = @import("../core/session.zig");
const core_storage = @import("../core/storage.zig");
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

    pub fn waitFor(self: *LegacySession, target: types.WaitTarget, opts: types.WaitOptions) !types.WaitResult {
        return self.base.waitFor(target, opts);
    }

    pub fn onEvent(
        self: *LegacySession,
        filter: types.EventFilter,
        callback: *const fn (types.LifecycleEvent) void,
    ) !u64 {
        return self.base.onEvent(filter, callback);
    }

    pub fn offEvent(self: *LegacySession, id: u64) bool {
        return self.base.offEvent(id);
    }

    pub fn setTimeoutPolicy(self: *LegacySession, policy: types.TimeoutPolicy) void {
        self.base.setTimeoutPolicy(policy);
    }

    pub fn timeoutPolicy(self: *const LegacySession) types.TimeoutPolicy {
        return self.base.timeoutPolicy();
    }

    pub fn lastDiagnostic(self: *const LegacySession) ?types.Diagnostic {
        return self.base.lastDiagnostic();
    }

    pub fn queryCookies(
        self: *LegacySession,
        allocator: @import("std").mem.Allocator,
        query: types.CookieQuery,
    ) ![]types.Cookie {
        return core_storage.queryCookies(&self.base, allocator, query);
    }

    pub fn buildCookieHeaderForUrl(
        self: *LegacySession,
        allocator: @import("std").mem.Allocator,
        url: []const u8,
        opts: types.CookieHeaderOptions,
    ) ![]u8 {
        return core_storage.buildCookieHeaderForUrl(&self.base, allocator, url, opts);
    }
};
