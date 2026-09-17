const std = @import("std");
const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");
const types = @import("../types.zig");
const cdp_target_json = @import("cdp_target_json.zig");

pub const TargetInfo = struct {
    id: []const u8,
    kind: []const u8,
};

pub const TargetsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *TargetsClient, allocator: std.mem.Allocator) ![]TargetInfo {
        const payload = try executor.cdpGetTargets(&self.session.base);
        defer self.session.base.allocator.free(payload);
        return parseTargetList(allocator, payload);
    }

    pub fn freeList(self: *TargetsClient, allocator: std.mem.Allocator, targets: []TargetInfo) void {
        _ = self;
        for (targets) |target| {
            allocator.free(target.id);
            allocator.free(target.kind);
        }
        allocator.free(targets);
    }

    pub fn attach(self: *TargetsClient, target_id: []const u8) !void {
        try executor.selectTarget(&self.session.base, target_id);
    }

    pub fn detach(self: *TargetsClient, target_id: []const u8) !void {
        if (self.session.base.transport != .cdp_ws) return error.UnsupportedProtocol;
        if (self.session.base.endpoint == null) return error.MissingEndpoint;
        const attached_session_id = blk: {
            if (self.session.base.cdp_attached_session_id) |existing| {
                if (self.session.base.cdp_target_id) |current| {
                    if (std.mem.eql(u8, current, target_id)) break :blk try self.session.base.allocator.dupe(u8, existing);
                }
            }
            return error.TargetNotAttached;
        };
        defer self.session.base.allocator.free(attached_session_id);

        const detached_current_target = blk: {
            if (self.session.base.cdp_target_id) |current| {
                break :blk std.mem.eql(u8, current, target_id);
            }
            break :blk false;
        };

        const detach_payload = executor.cdpDetachFromTarget(&self.session.base, attached_session_id) catch |err| switch (err) {
            error.ProtocolCommandFailed => {
                const diag = self.session.base.lastDiagnostic();
                if (!isStaleDetachSessionDiagnostic(diag)) return err;
                if (detached_current_target) executor.clearSelectedTarget(&self.session.base);
                return;
            },
            else => return err,
        };
        defer self.session.base.allocator.free(detach_payload);
        if (detached_current_target) executor.clearSelectedTarget(&self.session.base);
    }
};

fn isStaleDetachSessionDiagnostic(diag: ?types.Diagnostic) bool {
    const value = diag orelse return false;
    if (!std.mem.eql(u8, value.code, "rpc_-32602")) return false;
    if (std.mem.indexOf(u8, value.message, "Target.detachFromTarget failed") == null) return false;
    return std.mem.indexOf(u8, value.message, "No session with given id") != null;
}

fn parseTargetList(allocator: std.mem.Allocator, payload: []const u8) ![]TargetInfo {
    const parsed_targets = try cdp_target_json.parseTargetInfos(allocator, payload);
    errdefer cdp_target_json.freeTargetInfos(allocator, parsed_targets);

    const out = try allocator.alloc(TargetInfo, parsed_targets.len);
    for (parsed_targets, 0..) |item, idx| {
        out[idx] = .{
            .id = item.id,
            .kind = item.kind,
        };
    }
    allocator.free(parsed_targets);
    return out;
}

fn extractAttachedSessionId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return cdp_target_json.extractResultStringField(allocator, payload, "sessionId");
}

fn parseCreatedTargetId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return cdp_target_json.extractResultStringField(allocator, payload, "targetId");
}

test "parse target list handles Target.getTargets payload" {
    const allocator = std.testing.allocator;
    const targets = try parseTargetList(allocator,
        \\{"id":1,"result":{"targetInfos":[
        \\  {"targetId":"target-1","type":"page"},
        \\  {"targetId":"target-2","type":"service_worker"}
        \\]}}
    );
    defer {
        for (targets) |target| {
            allocator.free(target.id);
            allocator.free(target.kind);
        }
        allocator.free(targets);
    }
    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("target-1", targets[0].id);
    try std.testing.expectEqualStrings("page", targets[0].kind);
}

fn allocationTargetList(allocator: std.mem.Allocator) !void {
    const targets = try parseTargetList(allocator, "{\"result\":{\"targetInfos\":[{\"targetId\":\"a\",\"type\":\"page\"},{\"targetId\":\"b\",\"type\":\"worker\"}]}}");
    defer {
        for (targets) |target| {
            allocator.free(target.id);
            allocator.free(target.kind);
        }
        allocator.free(targets);
    }
    try std.testing.expectEqual(@as(usize, 2), targets.len);
}

test "target list remains empty and handles every allocation failure" {
    const targets = try parseTargetList(std.testing.allocator, "{\"result\":{\"targetInfos\":[]}}");
    defer std.testing.allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 0), targets.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTargetList, .{});
}

test "extract attached session id from Target.attachToTarget payload" {
    const allocator = std.testing.allocator;
    const session_id = try extractAttachedSessionId(allocator, "{\"id\":4,\"result\":{\"sessionId\":\"sid-123\"}}");
    defer allocator.free(session_id);
    try std.testing.expectEqualStrings("sid-123", session_id);
}

test "parse created target id from Target.createTarget payload" {
    const allocator = std.testing.allocator;
    const target_id = try parseCreatedTargetId(allocator, "{\"id\":9,\"result\":{\"targetId\":\"target-9\"}}");
    defer allocator.free(target_id);
    try std.testing.expectEqualStrings("target-9", target_id);
}

test "stale detach diagnostic matcher only accepts stale session errors" {
    try std.testing.expect(isStaleDetachSessionDiagnostic(.{
        .phase = .overall,
        .code = "rpc_-32602",
        .message = "Target.detachFromTarget failed: No session with given id; payload={}",
        .transport = "cdp_ws",
        .elapsed_ms = null,
    }));
    try std.testing.expect(!isStaleDetachSessionDiagnostic(.{
        .phase = .overall,
        .code = "rpc_-32000",
        .message = "Target.detachFromTarget failed: target closed",
        .transport = "cdp_ws",
        .elapsed_ms = null,
    }));
}
