const std = @import("std");
const session_mod = @import("session.zig");
const common = @import("../protocol/common.zig");
const http_client = @import("../transport/http_client.zig");

pub const TargetInfo = struct {
    id: []const u8,
    kind: []const u8,
};

pub const TargetsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *TargetsClient, allocator: std.mem.Allocator) ![]TargetInfo {
        const parsed = try parseCdpEndpoint(self.session);
        const response = try http_client.getJson(allocator, parsed.host, parsed.port, "/json/list");
        defer allocator.free(response.body);
        if (response.status_code < 200 or response.status_code >= 300) return error.InvalidResponse;
        return parseTargetList(allocator, response.body);
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
        const parsed = try parseCdpEndpoint(self.session);
        const response = try http_client.getJson(self.session.base.allocator, parsed.host, parsed.port, "/json/list");
        defer self.session.base.allocator.free(response.body);
        if (response.status_code < 200 or response.status_code >= 300) return error.InvalidResponse;
        const endpoint = try endpointForTargetId(self.session.base.allocator, response.body, target_id);
        replaceEndpoint(self.session, endpoint);
    }

    pub fn detach(self: *TargetsClient, target_id: []const u8) !void {
        _ = target_id;
        const parsed = try parseCdpEndpoint(self.session);
        const root_endpoint = try std.fmt.allocPrint(
            self.session.base.allocator,
            "cdp://{s}:{d}/",
            .{ parsed.host, parsed.port },
        );
        replaceEndpoint(self.session, root_endpoint);
    }
};

fn parseCdpEndpoint(session: *session_mod.ModernSession) !common.EndpointParts {
    if (session.base.transport != .cdp_ws) return error.UnsupportedProtocol;
    const endpoint = session.base.endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    if (parsed.adapter != .cdp) return error.UnsupportedProtocol;
    return parsed;
}

fn parseTargetList(allocator: std.mem.Allocator, payload: []const u8) ![]TargetInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponse;

    var out: std.ArrayList(TargetInfo) = .empty;
    errdefer {
        for (out.items) |target| {
            allocator.free(target.id);
            allocator.free(target.kind);
        }
        out.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        const type_value = item.object.get("type") orelse continue;
        if (id_value != .string or type_value != .string) continue;
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id_value.string),
            .kind = try allocator.dupe(u8, type_value.string),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn endpointForTargetId(allocator: std.mem.Allocator, payload: []const u8, target_id: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponse;

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value != .string or !std.mem.eql(u8, id_value.string, target_id)) continue;
        const ws_value = item.object.get("webSocketDebuggerUrl") orelse continue;
        if (ws_value != .string) continue;
        return endpointFromWsUrl(allocator, ws_value.string);
    }
    return error.MissingEndpoint;
}

fn endpointFromWsUrl(allocator: std.mem.Allocator, ws_url: []const u8) ![]u8 {
    var input = ws_url;
    if (std.mem.startsWith(u8, input, "ws://")) input = input[5..];
    if (std.mem.startsWith(u8, input, "wss://")) input = input[6..];
    const slash = std.mem.indexOfScalar(u8, input, '/') orelse return error.InvalidEndpoint;
    const host_port = input[0..slash];
    const path = input[slash..];

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidEndpoint;
    const host = host_port[0..colon];
    const port = try std.fmt.parseInt(u16, host_port[colon + 1 ..], 10);
    return std.fmt.allocPrint(allocator, "cdp://{s}:{d}{s}", .{ host, port, path });
}

fn replaceEndpoint(session: *session_mod.ModernSession, endpoint: []u8) void {
    if (session.base.endpoint) |old| session.base.allocator.free(old);
    session.base.endpoint = endpoint;
    if (session.base.cdp_ws_endpoint) |old| {
        session.base.allocator.free(old);
        session.base.cdp_ws_endpoint = null;
    }
}

test "parse target list returns protocol-backed targets" {
    const allocator = std.testing.allocator;
    const targets = try parseTargetList(allocator,
        \\[
        \\  {"id":"target-1","type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/target-1"},
        \\  {"id":"target-2","type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/target-2"}
        \\]
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

test "endpoint for target id maps websocket url to cdp endpoint" {
    const allocator = std.testing.allocator;
    const payload =
        \\[
        \\  {"id":"target-1","type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/target-1"}
        \\]
    ;
    const endpoint = try endpointForTargetId(allocator, payload, "target-1");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("cdp://127.0.0.1:9222/devtools/page/target-1", endpoint);
}
