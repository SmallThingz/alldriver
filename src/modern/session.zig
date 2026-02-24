const std = @import("std");
const core_session = @import("../core/session.zig");
const types = @import("../types.zig");
const artifacts = @import("../core/artifacts.zig");
const async_mod = @import("../core/async.zig");
const support_tier = @import("../catalog/support_tier.zig");

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
        if (support_tier.transportTier(base.transport) != .modern) {
            var tmp = base;
            tmp.deinit();
            return error.UnsupportedProtocol;
        }
        return .{ .base = base };
    }

    pub fn deinit(self: *ModernSession) void {
        self.base.deinit();
        self.* = undefined;
    }

    pub fn intoBase(self: *ModernSession) core_session.Session {
        const moved = self.base;
        self.* = undefined;
        return moved;
    }

    pub fn capabilities(self: *const ModernSession) types.CapabilitySet {
        return self.base.capabilities();
    }

    pub fn supports(self: *const ModernSession, feature: types.CapabilityFeature) bool {
        return self.base.supports(feature);
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

    pub fn navigate(self: *ModernSession, url: []const u8) !void {
        var client = self.page();
        try client.navigate(url);
    }

    pub fn click(self: *ModernSession, selector: []const u8) !void {
        var client = self.input();
        try client.click(selector);
    }

    pub fn typeText(self: *ModernSession, selector: []const u8, text: []const u8) !void {
        var client = self.input();
        try client.typeText(selector, text);
    }

    pub fn evaluate(self: *ModernSession, script: []const u8) ![]u8 {
        var client = self.runtime();
        return client.evaluate(script);
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
