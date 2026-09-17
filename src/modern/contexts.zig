const std = @import("std");
const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");
const cdp_target_json = @import("cdp_target_json.zig");

pub const BrowsingContext = struct {
    id: []const u8,
};

pub const ContextsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *ContextsClient, allocator: std.mem.Allocator) ![]BrowsingContext {
        const payload = try executor.cdpGetTargets(&self.session.base);
        defer self.session.base.allocator.free(payload);
        return parseContextList(allocator, payload);
    }

    pub fn freeList(self: *ContextsClient, allocator: std.mem.Allocator, list_items: []BrowsingContext) void {
        _ = self;
        for (list_items) |item| allocator.free(item.id);
        allocator.free(list_items);
    }

    pub fn create(self: *ContextsClient, allocator: std.mem.Allocator) !BrowsingContext {
        const payload = try executor.cdpCreateTarget(&self.session.base, "about:blank");
        defer self.session.base.allocator.free(payload);
        const target_id = try parseCreatedContextId(self.session.base.allocator, payload);
        defer self.session.base.allocator.free(target_id);
        errdefer {
            const closed = executor.cdpCloseTarget(&self.session.base, target_id) catch null;
            if (closed) |result| self.session.base.allocator.free(result);
        }
        const result_id = try allocator.dupe(u8, target_id);
        errdefer allocator.free(result_id);
        try executor.selectTarget(&self.session.base, target_id);
        return .{ .id = result_id };
    }

    pub fn close(self: *ContextsClient, context_id: []const u8) !void {
        const payload = try executor.cdpCloseTarget(&self.session.base, context_id);
        defer self.session.base.allocator.free(payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.session.base.allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result != .object) return error.InvalidResponse;
        const success = result.object.get("success") orelse return error.InvalidResponse;
        if (success != .bool or !success.bool) return error.ProtocolCommandFailed;
        if (self.session.base.cdp_target_id) |target_id| {
            if (std.mem.eql(u8, target_id, context_id)) executor.clearSelectedTarget(&self.session.base);
        }
    }
};

fn parseContextList(allocator: std.mem.Allocator, payload: []const u8) ![]BrowsingContext {
    const target_infos = try cdp_target_json.parseTargetInfos(allocator, payload);
    defer cdp_target_json.freeTargetInfos(allocator, target_infos);

    var out: std.ArrayList(BrowsingContext) = .empty;
    errdefer {
        for (out.items) |ctx| allocator.free(ctx.id);
        out.deinit(allocator);
    }

    for (target_infos) |item| {
        if (!isPageLike(item.kind)) continue;
        const id = try allocator.dupe(u8, item.id);
        errdefer allocator.free(id);
        try out.append(allocator, .{ .id = id });
    }
    return out.toOwnedSlice(allocator);
}

fn parseCreatedContextId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return cdp_target_json.extractResultStringField(allocator, payload, "targetId");
}

fn isPageLike(kind: []const u8) bool {
    return std.ascii.eqlIgnoreCase(kind, "page") or std.ascii.eqlIgnoreCase(kind, "tab");
}

test "parse context list filters page-like target infos" {
    const allocator = std.testing.allocator;
    const contexts = try parseContextList(allocator,
        \\{"id":1,"result":{"targetInfos":[
        \\  {"targetId":"page-1","type":"page"},
        \\  {"targetId":"worker-1","type":"service_worker"},
        \\  {"targetId":"tab-1","type":"tab"}
        \\]}}
    );
    defer {
        for (contexts) |ctx| allocator.free(ctx.id);
        allocator.free(contexts);
    }
    try std.testing.expectEqual(@as(usize, 2), contexts.len);
    try std.testing.expectEqualStrings("page-1", contexts[0].id);
    try std.testing.expectEqualStrings("tab-1", contexts[1].id);
}

test "parse created context id from Target.createTarget payload" {
    const allocator = std.testing.allocator;
    const id = try parseCreatedContextId(allocator, "{\"id\":7,\"result\":{\"targetId\":\"ctx-abc\"}}");
    defer allocator.free(id);
    try std.testing.expectEqualStrings("ctx-abc", id);
}

fn allocationContextList(allocator: std.mem.Allocator) !void {
    const contexts = try parseContextList(allocator, "{\"result\":{\"targetInfos\":[{\"targetId\":\"a\",\"type\":\"page\"},{\"targetId\":\"b\",\"type\":\"worker\"},{\"targetId\":\"c\",\"type\":\"page\"}]}}");
    defer {
        for (contexts) |context| allocator.free(context.id);
        allocator.free(contexts);
    }
    try std.testing.expectEqual(@as(usize, 2), contexts.len);
}

test "context list remains empty and handles every allocation failure" {
    const contexts = try parseContextList(std.testing.allocator, "{\"result\":{\"targetInfos\":[]}}");
    defer std.testing.allocator.free(contexts);
    try std.testing.expectEqual(@as(usize, 0), contexts.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationContextList, .{});
}
