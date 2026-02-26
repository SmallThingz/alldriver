const std = @import("std");
const core_session = @import("../core/session.zig");
const types = @import("../types.zig");
const artifacts = @import("../core/artifacts.zig");
const async_mod = @import("../core/async.zig");
const session_common = @import("../tier/session_common.zig");

const page_mod = @import("page.zig");
const runtime_client_mod = @import("runtime_client.zig");
const network_mod = @import("network.zig");
const input_mod = @import("input.zig");
const log_mod = @import("log.zig");
const storage_mod = @import("storage.zig");
const contexts_mod = @import("contexts.zig");
const targets_mod = @import("targets.zig");

pub const ModernSession = struct {
    base: core_session.Session,

    pub fn fromBase(base: core_session.Session) !ModernSession {
        return .{ .base = try session_common.fromBase(base, .modern) };
    }

    pub fn deinit(self: *ModernSession) void {
        session_common.deinit(&self.base);
    }

    pub fn intoBase(self: *ModernSession) core_session.Session {
        return session_common.intoBase(&self.base);
    }

    pub fn capabilities(self: *const ModernSession) types.CapabilitySet {
        return session_common.capabilities(&self.base);
    }

    pub fn supports(self: *const ModernSession, feature: types.CapabilityFeature) bool {
        return session_common.supports(&self.base, feature);
    }

    pub fn page(self: *ModernSession) page_mod.PageClient {
        return .{ .session = self };
    }

    pub fn runtime(self: *ModernSession) runtime_client_mod.RuntimeClient {
        return .{ .session = self };
    }

    pub fn network(self: *ModernSession) network_mod.NetworkClient {
        return .{ .session = self };
    }

    pub fn input(self: *ModernSession) input_mod.InputClient {
        return .{ .session = self };
    }

    pub fn log(self: *ModernSession) log_mod.LogClient {
        return .{ .session = self };
    }

    pub fn storage(self: *ModernSession) storage_mod.StorageClient {
        return .{ .session = self };
    }

    pub fn contexts(self: *ModernSession) contexts_mod.ContextsClient {
        return .{ .session = self };
    }

    pub fn targets(self: *ModernSession) targets_mod.TargetsClient {
        return .{ .session = self };
    }

    pub fn screenshot(
        self: *ModernSession,
        allocator: std.mem.Allocator,
        format: artifacts.ScreenshotFormat,
    ) ![]u8 {
        var client = self.page();
        return client.screenshot(allocator, format);
    }

    pub fn navigateAsync(self: *ModernSession, url: []const u8) !*async_mod.AsyncResult(void) {
        return self.base.navigateAsync(url);
    }

    pub fn clickAsync(self: *ModernSession, selector: []const u8) !*async_mod.AsyncResult(void) {
        return self.base.clickAsync(selector);
    }

    pub fn typeTextAsync(
        self: *ModernSession,
        selector: []const u8,
        text: []const u8,
    ) !*async_mod.AsyncResult(void) {
        return self.base.typeTextAsync(selector, text);
    }

    pub fn evaluateAsync(self: *ModernSession, script: []const u8) !*async_mod.AsyncResult([]u8) {
        return self.base.evaluateAsync(script);
    }

    pub fn waitForAsync(
        self: *ModernSession,
        condition: @import("../core/actions.zig").WaitCondition,
        timeout_ms: u32,
    ) !*async_mod.AsyncResult(void) {
        return self.base.waitForAsync(condition, timeout_ms);
    }

    pub fn screenshotAsync(
        self: *ModernSession,
        format: artifacts.ScreenshotFormat,
    ) !*async_mod.AsyncResult([]u8) {
        return self.base.screenshotAsync(format);
    }

    pub fn startTracingAsync(self: *ModernSession) !*async_mod.AsyncResult(void) {
        return self.base.startTracingAsync();
    }

    pub fn stopTracingAsync(self: *ModernSession) !*async_mod.AsyncResult([]u8) {
        return self.base.stopTracingAsync();
    }
};
