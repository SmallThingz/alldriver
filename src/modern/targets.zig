const std = @import("std");
const session_mod = @import("session.zig");

pub const TargetInfo = struct {
    id: []const u8,
    kind: []const u8,
};

pub const TargetsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *TargetsClient, allocator: std.mem.Allocator) ![]TargetInfo {
        const endpoint = self.session.base.endpoint orelse "unknown";
        const out = try allocator.alloc(TargetInfo, 1);
        out[0] = .{
            .id = try allocator.dupe(u8, endpoint),
            .kind = try allocator.dupe(u8, if (self.session.base.transport == .bidi_ws) "bidi-context" else "cdp-target"),
        };
        return out;
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
        _ = self;
        _ = target_id;
    }

    pub fn detach(self: *TargetsClient, target_id: []const u8) !void {
        _ = self;
        _ = target_id;
    }
};
