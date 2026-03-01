const std = @import("std");
const session_mod = @import("session.zig");
const common = @import("../protocol/common.zig");
const http_client = @import("../transport/http_client.zig");

pub const BrowsingContext = struct {
    id: []const u8,
};

pub const ContextsClient = struct {
    session: *session_mod.ModernSession,

    pub fn list(self: *ContextsClient, allocator: std.mem.Allocator) ![]BrowsingContext {
        const parsed = try parseCdpEndpoint(self.session);
        const response = try http_client.getJson(allocator, parsed.host, parsed.port, "/json/list");
        defer allocator.free(response.body);
        if (response.status_code < 200 or response.status_code >= 300) return error.InvalidResponse;
        return parseContextList(allocator, response.body);
    }

    pub fn freeList(self: *ContextsClient, allocator: std.mem.Allocator, list_items: []BrowsingContext) void {
        _ = self;
        for (list_items) |item| allocator.free(item.id);
        allocator.free(list_items);
    }

    pub fn create(self: *ContextsClient, allocator: std.mem.Allocator) !BrowsingContext {
        const parsed = try parseCdpEndpoint(self.session);
        const create_paths = [_][]const u8{ "/json/new?about:blank", "/json/new" };
        for (create_paths) |path| {
            const response = http_client.getJson(self.session.base.allocator, parsed.host, parsed.port, path) catch continue;
            defer self.session.base.allocator.free(response.body);
            if (response.status_code < 200 or response.status_code >= 300) continue;
            const created = try parseCreatedContext(self.session.base.allocator, response.body);
            errdefer self.session.base.allocator.free(created.id);
            errdefer if (created.endpoint) |ep| self.session.base.allocator.free(ep);

            if (self.session.base.browsing_context_id) |old| self.session.base.allocator.free(old);
            self.session.base.browsing_context_id = try self.session.base.allocator.dupe(u8, created.id);

            if (created.endpoint) |endpoint| {
                replaceEndpoint(self.session, endpoint);
            }

            return .{ .id = try allocator.dupe(u8, created.id) };
        }
        return error.ProtocolCommandFailed;
    }

    pub fn close(self: *ContextsClient, context_id: []const u8) !void {
        const parsed = try parseCdpEndpoint(self.session);
        const escaped = try std.fmt.allocPrint(self.session.base.allocator, "/json/close/{s}", .{context_id});
        defer self.session.base.allocator.free(escaped);
        const response = try http_client.getJson(self.session.base.allocator, parsed.host, parsed.port, escaped);
        defer self.session.base.allocator.free(response.body);
        if (response.status_code < 200 or response.status_code >= 300) return error.ProtocolCommandFailed;

        if (self.session.base.browsing_context_id) |current| {
            if (std.mem.eql(u8, current, context_id)) {
                self.session.base.allocator.free(current);
                self.session.base.browsing_context_id = null;
            }
        }

        if (self.session.base.endpoint) |endpoint| {
            if (std.mem.indexOf(u8, endpoint, context_id) != null) {
                const root = try std.fmt.allocPrint(self.session.base.allocator, "cdp://{s}:{d}/", .{ parsed.host, parsed.port });
                replaceEndpoint(self.session, root);
            }
        }
    }
};

const CreatedContext = struct {
    id: []u8,
    endpoint: ?[]u8,
};

fn parseCdpEndpoint(session: *session_mod.ModernSession) !common.EndpointParts {
    if (session.base.transport != .cdp_ws) return error.UnsupportedProtocol;
    const endpoint = session.base.endpoint orelse return error.MissingEndpoint;
    const parsed = try common.parseEndpoint(endpoint, .cdp);
    if (parsed.adapter != .cdp) return error.UnsupportedProtocol;
    return parsed;
}

fn parseContextList(allocator: std.mem.Allocator, payload: []const u8) ![]BrowsingContext {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponse;

    var out: std.ArrayList(BrowsingContext) = .empty;
    errdefer {
        for (out.items) |ctx| allocator.free(ctx.id);
        out.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        const type_value = item.object.get("type") orelse continue;
        if (id_value != .string or type_value != .string) continue;
        if (!std.ascii.eqlIgnoreCase(type_value.string, "page") and !std.ascii.eqlIgnoreCase(type_value.string, "tab")) continue;
        try out.append(allocator, .{ .id = try allocator.dupe(u8, id_value.string) });
    }
    return out.toOwnedSlice(allocator);
}

fn parseCreatedContext(allocator: std.mem.Allocator, payload: []const u8) !CreatedContext {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const id_value = parsed.value.object.get("id") orelse return error.MissingEndpoint;
    if (id_value != .string) return error.InvalidResponse;
    const ws_url = if (parsed.value.object.get("webSocketDebuggerUrl")) |value|
        if (value == .string) value.string else null
    else
        null;

    return .{
        .id = try allocator.dupe(u8, id_value.string),
        .endpoint = if (ws_url) |url| try endpointFromWsUrl(allocator, url) else null,
    };
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

test "parse context list filters to page-like targets" {
    const allocator = std.testing.allocator;
    const contexts = try parseContextList(allocator,
        \\[
        \\  {"id":"page-1","type":"page"},
        \\  {"id":"worker-1","type":"service_worker"},
        \\  {"id":"tab-1","type":"tab"}
        \\]
    );
    defer {
        for (contexts) |ctx| allocator.free(ctx.id);
        allocator.free(contexts);
    }
    try std.testing.expectEqual(@as(usize, 2), contexts.len);
    try std.testing.expectEqualStrings("page-1", contexts[0].id);
    try std.testing.expectEqualStrings("tab-1", contexts[1].id);
}

test "parse created context extracts id and endpoint" {
    const allocator = std.testing.allocator;
    const created = try parseCreatedContext(allocator,
        \\{"id":"page-abc","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/page-abc"}
    );
    defer allocator.free(created.id);
    defer if (created.endpoint) |ep| allocator.free(ep);
    try std.testing.expectEqualStrings("page-abc", created.id);
    try std.testing.expectEqualStrings("cdp://127.0.0.1:9222/devtools/page/page-abc", created.endpoint.?);
}
