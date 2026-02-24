const std = @import("std");
const session_mod = @import("session.zig");

pub const BrowsingContext = struct {
    id: []const u8,
};

pub const ContextsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *ContextsClient, allocator: std.mem.Allocator) ![]BrowsingContext {
        const id = self.session.base.browsing_context_id orelse "default";
        const contexts = try allocator.alloc(BrowsingContext, 1);
        contexts[0] = .{ .id = try allocator.dupe(u8, id) };
        return contexts;
    }

    pub fn freeList(self: *ContextsClient, allocator: std.mem.Allocator, list_items: []BrowsingContext) void {
        _ = self;
        for (list_items) |item| allocator.free(item.id);
        allocator.free(list_items);
    }

    pub fn create(self: *ContextsClient, allocator: std.mem.Allocator) !BrowsingContext {
        const id = try std.fmt.allocPrint(allocator, "ctx-{d}", .{self.session.base.id});
        if (self.session.base.browsing_context_id) |old| self.session.base.allocator.free(old);
        self.session.base.browsing_context_id = try self.session.base.allocator.dupe(u8, id);
        return .{ .id = id };
    }

    pub fn close(self: *ContextsClient, context_id: []const u8) !void {
        if (self.session.base.browsing_context_id) |current| {
            if (std.mem.eql(u8, current, context_id)) {
                self.session.base.allocator.free(current);
                self.session.base.browsing_context_id = null;
            }
        }
    }
};
