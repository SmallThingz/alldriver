const std = @import("std");
const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");
const types = @import("../types.zig");

pub const TargetInfo = struct {
    id: []const u8,
    kind: []const u8,
};

pub const TargetsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *TargetsClient, allocator: std.mem.Allocator) ![]TargetInfo {
        const payload = try executor.cdpGetTargets(&self.session.base);
        defer self.session.base.allocator.free(payload);
        const targets = try parseTargetList(allocator, payload);
        if (targets.len > 0) return targets;
        allocator.free(targets);
        return self.synthesizeTargetList(allocator);
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
        const payload = try executor.cdpAttachToTarget(&self.session.base, target_id, true);
        defer self.session.base.allocator.free(payload);
        const attached_session_id = try extractAttachedSessionId(self.session.base.allocator, payload);
        if (self.session.base.cdp_target_id) |current| self.session.base.allocator.free(current);
        self.session.base.cdp_target_id = try self.session.base.allocator.dupe(u8, target_id);
        if (self.session.base.cdp_attached_session_id) |attached| {
            self.session.base.allocator.free(attached);
        }
        self.session.base.cdp_attached_session_id = attached_session_id;
    }

    pub fn detach(self: *TargetsClient, target_id: []const u8) !void {
        const attached_session_id = blk: {
            if (self.session.base.cdp_attached_session_id) |existing| {
                if (self.session.base.cdp_target_id) |current| {
                    if (std.mem.eql(u8, current, target_id)) break :blk try self.session.base.allocator.dupe(u8, existing);
                }
            }
            const attach_payload = try executor.cdpAttachToTarget(&self.session.base, target_id, true);
            defer self.session.base.allocator.free(attach_payload);
            break :blk try extractAttachedSessionId(self.session.base.allocator, attach_payload);
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
                clearDetachedState(self, target_id, attached_session_id, detached_current_target);
                return;
            },
            else => return err,
        };
        defer self.session.base.allocator.free(detach_payload);
        clearDetachedState(self, target_id, attached_session_id, detached_current_target);
    }

    fn synthesizeTargetList(self: *TargetsClient, allocator: std.mem.Allocator) ![]TargetInfo {
        const target_id = try self.ensureCurrentTargetId();
        const out = try allocator.alloc(TargetInfo, 1);
        errdefer allocator.free(out);
        out[0] = .{
            .id = try allocator.dupe(u8, target_id),
            .kind = try allocator.dupe(u8, "page"),
        };
        return out;
    }

    fn ensureCurrentTargetId(self: *TargetsClient) ![]const u8 {
        if (self.session.base.cdp_target_id) |target_id| return target_id;

        const payload = try executor.cdpCreateTarget(&self.session.base, "about:blank");
        defer self.session.base.allocator.free(payload);
        const target_id = try parseCreatedTargetId(self.session.base.allocator, payload);
        errdefer self.session.base.allocator.free(target_id);
        self.session.base.cdp_target_id = target_id;
        if (self.session.base.cdp_attached_session_id) |attached| {
            self.session.base.allocator.free(attached);
            self.session.base.cdp_attached_session_id = null;
        }
        return self.session.base.cdp_target_id.?;
    }
};

fn clearDetachedState(
    self: *TargetsClient,
    target_id: []const u8,
    attached_session_id: []const u8,
    detached_current_target: bool,
) void {
    if (self.session.base.cdp_target_id) |current| {
        if (std.mem.eql(u8, current, target_id)) {
            self.session.base.allocator.free(current);
            self.session.base.cdp_target_id = null;
        }
    }
    if (self.session.base.cdp_attached_session_id) |attached| {
        if (detached_current_target or std.mem.eql(u8, attached, attached_session_id)) {
            self.session.base.allocator.free(attached);
            self.session.base.cdp_attached_session_id = null;
        }
    }
}

fn isStaleDetachSessionDiagnostic(diag: ?types.Diagnostic) bool {
    const value = diag orelse return false;
    if (!std.mem.eql(u8, value.code, "rpc_-32602")) return false;
    if (std.mem.indexOf(u8, value.message, "Target.detachFromTarget failed") == null) return false;
    return std.mem.indexOf(u8, value.message, "No session with given id") != null;
}

fn parseTargetList(allocator: std.mem.Allocator, payload: []const u8) ![]TargetInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const target_infos = result.object.get("targetInfos") orelse return error.InvalidResponse;
    if (target_infos != .array) return error.InvalidResponse;

    var out: std.ArrayList(TargetInfo) = .empty;
    errdefer {
        for (out.items) |target| {
            allocator.free(target.id);
            allocator.free(target.kind);
        }
        out.deinit(allocator);
    }

    for (target_infos.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("targetId") orelse continue;
        const type_value = item.object.get("type") orelse continue;
        if (id_value != .string or type_value != .string) continue;
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id_value.string),
            .kind = try allocator.dupe(u8, type_value.string),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn extractAttachedSessionId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const session_id = result.object.get("sessionId") orelse return error.InvalidResponse;
    if (session_id != .string) return error.InvalidResponse;
    return allocator.dupe(u8, session_id.string);
}

fn parseCreatedTargetId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const id_value = result.object.get("targetId") orelse return error.InvalidResponse;
    if (id_value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, id_value.string);
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
