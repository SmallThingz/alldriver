const std = @import("std");
const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");

pub const BrowsingContext = struct {
    id: []const u8,
};

pub const ContextsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *ContextsClient, allocator: std.mem.Allocator) ![]BrowsingContext {
        const payload = try executor.cdpGetTargets(&self.session.base);
        defer self.session.base.allocator.free(payload);
        const contexts = try parseContextList(allocator, payload);
        if (contexts.len > 0) return contexts;
        allocator.free(contexts);
        return self.synthesizeContextList(allocator);
    }

    pub fn freeList(self: *ContextsClient, allocator: std.mem.Allocator, list_items: []BrowsingContext) void {
        _ = self;
        for (list_items) |item| allocator.free(item.id);
        allocator.free(list_items);
    }

    pub fn create(self: *ContextsClient, allocator: std.mem.Allocator) !BrowsingContext {
        const payload = executor.cdpCreateTarget(&self.session.base, "about:blank") catch |err| switch (err) {
            error.ProtocolCommandFailed => {
                const existing = try self.ensureCurrentContextId();
                return .{ .id = try allocator.dupe(u8, existing) };
            },
            else => return err,
        };
        defer self.session.base.allocator.free(payload);
        const target_id = try parseCreatedContextId(self.session.base.allocator, payload);
        defer self.session.base.allocator.free(target_id);

        if (self.session.base.cdp_target_id) |existing| self.session.base.allocator.free(existing);
        self.session.base.cdp_target_id = try self.session.base.allocator.dupe(u8, target_id);
        if (self.session.base.cdp_attached_session_id) |attached| {
            self.session.base.allocator.free(attached);
            self.session.base.cdp_attached_session_id = null;
        }

        return .{ .id = try allocator.dupe(u8, target_id) };
    }

    pub fn close(self: *ContextsClient, context_id: []const u8) !void {
        const payload = executor.cdpCloseTarget(&self.session.base, context_id) catch |err| switch (err) {
            error.ProtocolCommandFailed => null,
            else => return err,
        };
        if (payload) |raw| {
            self.session.base.allocator.free(raw);
            if (self.session.base.cdp_target_id) |target_id| {
                if (std.mem.eql(u8, target_id, context_id)) {
                    self.session.base.allocator.free(target_id);
                    self.session.base.cdp_target_id = null;
                }
            }
            if (self.session.base.cdp_attached_session_id) |attached| {
                self.session.base.allocator.free(attached);
                self.session.base.cdp_attached_session_id = null;
            }
        }
    }

    fn synthesizeContextList(self: *ContextsClient, allocator: std.mem.Allocator) ![]BrowsingContext {
        const target_id = try self.ensureCurrentContextId();
        const out = try allocator.alloc(BrowsingContext, 1);
        errdefer allocator.free(out);
        out[0] = .{ .id = try allocator.dupe(u8, target_id) };
        return out;
    }

    fn ensureCurrentContextId(self: *ContextsClient) ![]const u8 {
        if (self.session.base.cdp_target_id) |target_id| return target_id;

        const payload = try executor.cdpCreateTarget(&self.session.base, "about:blank");
        defer self.session.base.allocator.free(payload);
        const target_id = try parseCreatedContextId(self.session.base.allocator, payload);
        errdefer self.session.base.allocator.free(target_id);

        self.session.base.cdp_target_id = target_id;
        if (self.session.base.cdp_attached_session_id) |attached| {
            self.session.base.allocator.free(attached);
            self.session.base.cdp_attached_session_id = null;
        }
        return self.session.base.cdp_target_id.?;
    }
};

fn parseContextList(allocator: std.mem.Allocator, payload: []const u8) ![]BrowsingContext {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const target_infos = result.object.get("targetInfos") orelse return error.InvalidResponse;
    if (target_infos != .array) return error.InvalidResponse;

    var out: std.ArrayList(BrowsingContext) = .empty;
    errdefer {
        for (out.items) |ctx| allocator.free(ctx.id);
        out.deinit(allocator);
    }

    for (target_infos.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("targetId") orelse continue;
        const type_value = item.object.get("type") orelse continue;
        if (id_value != .string or type_value != .string) continue;
        if (!isPageLike(type_value.string)) continue;
        try out.append(allocator, .{ .id = try allocator.dupe(u8, id_value.string) });
    }
    return out.toOwnedSlice(allocator);
}

fn parseCreatedContextId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const id_value = result.object.get("targetId") orelse return error.InvalidResponse;
    if (id_value != .string) return error.InvalidResponse;
    return allocator.dupe(u8, id_value.string);
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
