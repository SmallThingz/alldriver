const session_mod = @import("session.zig");
const std = @import("std");
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

    pub fn records(self: *NetworkClient, allocator: std.mem.Allocator, include_bodies: bool) ![]types.NetworkRecord {
        return self.session.base.networkRecords(allocator, include_bodies);
    }

    pub fn freeRecords(self: *NetworkClient, allocator: std.mem.Allocator, record_list: []types.NetworkRecord) void {
        self.session.base.freeNetworkRecords(allocator, record_list);
    }

    pub fn clearRecords(self: *NetworkClient) void {
        self.session.base.clearNetworkRecords();
    }

    pub fn frames(self: *NetworkClient, allocator: std.mem.Allocator) ![]types.FrameInfo {
        return self.session.base.frameInfos(allocator);
    }

    pub fn freeFrames(self: *NetworkClient, allocator: std.mem.Allocator, frame_list: []types.FrameInfo) void {
        self.session.base.freeFrameInfos(allocator, frame_list);
    }

    pub fn serviceWorkers(self: *NetworkClient, allocator: std.mem.Allocator) ![]types.ServiceWorkerInfo {
        return self.session.base.serviceWorkerInfos(allocator);
    }

    pub fn freeServiceWorkers(
        self: *NetworkClient,
        allocator: std.mem.Allocator,
        workers: []types.ServiceWorkerInfo,
    ) void {
        self.session.base.freeServiceWorkerInfos(allocator, workers);
    }

    pub fn captureSnapshot(
        self: *NetworkClient,
        allocator: std.mem.Allocator,
        phase: types.SnapshotPhase,
        url_override: ?[]const u8,
    ) !types.SnapshotBundle {
        return self.session.base.captureSnapshot(allocator, phase, url_override);
    }

    pub fn freeSnapshot(self: *NetworkClient, allocator: std.mem.Allocator, bundle: *types.SnapshotBundle) void {
        self.session.base.freeSnapshot(allocator, bundle);
    }

    pub fn navigationSnapshots(self: *NetworkClient, allocator: std.mem.Allocator) ![]types.SnapshotBundle {
        return self.session.base.navigationSnapshots(allocator);
    }

    pub fn freeNavigationSnapshots(
        self: *NetworkClient,
        allocator: std.mem.Allocator,
        bundles: []types.SnapshotBundle,
    ) void {
        self.session.base.freeNavigationSnapshots(allocator, bundles);
    }

    pub fn clearNavigationSnapshots(self: *NetworkClient) void {
        self.session.base.clearNavigationSnapshots();
    }
};
