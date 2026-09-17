const std = @import("std");
const types = @import("../types.zig");
const compat = @import("../util/compat.zig");
const ws = @import("../transport/ws_client.zig");
const rpc = @import("../transport/json_rpc.zig");
const common = @import("common.zig");

/// Owns a dedicated target connection so interception progresses while callers
/// are idle. No pointer into the movable public Session is retained.
pub const Interceptor = struct {
    allocator: std.mem.Allocator,
    client: ws.Client,
    mutex: compat.Mutex = .{},
    arena: std.heap.ArenaAllocator,
    rules: []const types.NetworkRule = &.{},
    failure: ?anyerror = null,
    worker: ?std.Io.Future(anyerror!void) = null,
    next_id: u64 = 2,

    pub fn create(allocator: std.mem.Allocator, endpoint: []const u8, rules: []const types.NetworkRule) !*Interceptor {
        const parsed = try common.parseEndpoint(endpoint, .cdp);
        if (!std.mem.startsWith(u8, parsed.path, "/devtools/page/")) return error.InvalidEndpoint;
        const self = try allocator.create(Interceptor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .client = try ws.Client.connect(allocator, parsed.host, parsed.port, parsed.path),
            .arena = .init(allocator),
        };
        errdefer self.client.deinit();
        errdefer self.arena.deinit();
        try self.syncRules(rules);
        const enable = try rpc.encodeRequest(allocator, 1, "Fetch.enable", "{\"patterns\":[{\"urlPattern\":\"*\",\"requestStage\":\"Request\"}]}");
        defer allocator.free(enable);
        try self.client.sendText(enable);
        while (true) {
            const message = try self.client.recvText(allocator);
            defer allocator.free(message);
            var envelope = try rpc.decodeEnvelope(allocator, message);
            defer envelope.deinit(allocator);
            if (envelope.id == 1) {
                if (envelope.has_error) return error.ProtocolCommandFailed;
                break;
            }
            try self.processMessage(message);
        }
        // A quiet browser is normal. Cancellation, not idle timeout, ends the worker.
        self.client.receive_timeout_ms = std.math.maxInt(u32);
        self.worker = try std.Io.concurrent(compat.io(), run, .{self});
        return self;
    }

    pub fn destroy(self: *Interceptor) void {
        if (self.worker) |*worker| _ = worker.cancel(compat.io()) catch {};
        self.client.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn lastError(self: *Interceptor) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure;
    }

    pub fn syncRules(self: *Interceptor, rules: []const types.NetworkRule) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const copied = try cloneRules(arena.allocator(), rules);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |failure| return failure;
        self.arena.deinit();
        self.arena = arena;
        self.rules = copied;
    }

    fn run(self: *Interceptor) anyerror!void {
        self.receiveLoop() catch |err| {
            self.mutex.lock();
            self.failure = err;
            self.mutex.unlock();
            // Release paused requests even if the owner does not call us again.
            self.client.stream.shutdown(compat.io(), .both) catch {};
            return err;
        };
    }

    fn receiveLoop(self: *Interceptor) !void {
        while (true) {
            const message = try self.client.recvText(self.allocator);
            defer self.allocator.free(message);
            try self.processMessage(message);
        }
    }

    fn processMessage(self: *Interceptor, message: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("error") != null) return error.ProtocolCommandFailed;
        const method = parsed.value.object.get("method") orelse return;
        if (method != .string or !std.mem.eql(u8, method.string, "Fetch.requestPaused")) return;
        const params = parsed.value.object.get("params") orelse return error.InvalidResponse;
        if (params != .object) return error.InvalidResponse;
        self.mutex.lock();
        const command = buildCommand(self.allocator, self.next_id, params.object, self.rules) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        defer self.allocator.free(command);
        self.next_id += 1;
        try self.client.sendText(command);
    }
};

fn cloneRules(allocator: std.mem.Allocator, rules: []const types.NetworkRule) ![]types.NetworkRule {
    const out = try allocator.alloc(types.NetworkRule, rules.len);
    for (rules, out) |rule, *copy| {
        copy.* = .{ .id = try allocator.dupe(u8, rule.id), .url_pattern = try allocator.dupe(u8, rule.url_pattern), .action = rule.action };
        switch (copy.action) {
            .fulfill => |*fulfill| {
                fulfill.body = try allocator.dupe(u8, fulfill.body);
                fulfill.headers = try cloneHeaders(allocator, fulfill.headers);
            },
            .modify => |*modify| {
                modify.add_headers = try cloneHeaders(allocator, modify.add_headers);
                const names = try allocator.alloc([]const u8, modify.remove_header_names.len);
                for (modify.remove_header_names, names) |name, *item| item.* = try allocator.dupe(u8, name);
                modify.remove_header_names = names;
            },
            else => {},
        }
    }
    return out;
}

fn cloneHeaders(allocator: std.mem.Allocator, headers: []const types.Header) ![]types.Header {
    const out = try allocator.alloc(types.Header, headers.len);
    for (headers, out) |header, *copy| copy.* = .{ .name = try allocator.dupe(u8, header.name), .value = try allocator.dupe(u8, header.value) };
    return out;
}

fn buildCommand(allocator: std.mem.Allocator, id: u64, params: std.json.ObjectMap, rules: []const types.NetworkRule) ![]u8 {
    const request_id = params.get("requestId") orelse return error.InvalidResponse;
    const request = params.get("request") orelse return error.InvalidResponse;
    if (request_id != .string or request != .object) return error.InvalidResponse;
    const url = request.object.get("url") orelse return error.InvalidResponse;
    if (url != .string) return error.InvalidResponse;
    var action: types.InterceptAction = .{ .continue_request = {} };
    for (rules) |rule| {
        if (globMatches(rule.url_pattern, url.string)) {
            action = rule.action;
            break;
        }
    }
    switch (action) {
        .block => return std.json.Stringify.valueAlloc(allocator, .{ .id = id, .method = "Fetch.failRequest", .params = .{ .requestId = request_id.string, .errorReason = "BlockedByClient" } }, .{}),
        .continue_request => return std.json.Stringify.valueAlloc(allocator, .{ .id = id, .method = "Fetch.continueRequest", .params = .{ .requestId = request_id.string } }, .{}),
        .fulfill => |fulfill| {
            const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(fulfill.body.len));
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, fulfill.body);
            return std.json.Stringify.valueAlloc(allocator, .{ .id = id, .method = "Fetch.fulfillRequest", .params = .{ .requestId = request_id.string, .responseCode = fulfill.status, .responseHeaders = fulfill.headers, .body = encoded } }, .{});
        },
        .modify => |modify| {
            var headers: std.ArrayList(types.Header) = .empty;
            defer headers.deinit(allocator);
            if (request.object.get("headers")) |original| {
                if (original != .object) return error.InvalidResponse;
                var it = original.object.iterator();
                while (it.next()) |header| {
                    if (header.value_ptr.* != .string) return error.InvalidResponse;
                    var skip = false;
                    for (modify.remove_header_names) |name| {
                        if (std.ascii.eqlIgnoreCase(name, header.key_ptr.*)) {
                            skip = true;
                            break;
                        }
                    }
                    for (modify.add_headers) |added| {
                        if (std.ascii.eqlIgnoreCase(added.name, header.key_ptr.*)) {
                            skip = true;
                            break;
                        }
                    }
                    if (!skip) try headers.append(allocator, .{ .name = header.key_ptr.*, .value = header.value_ptr.string });
                }
            }
            try headers.appendSlice(allocator, modify.add_headers);
            return std.json.Stringify.valueAlloc(allocator, .{ .id = id, .method = "Fetch.continueRequest", .params = .{ .requestId = request_id.string, .headers = headers.items } }, .{});
        },
    }
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = t;
        } else if (star) |s| {
            p = s + 1;
            retry += 1;
            t = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const paused_fixture =
    \\{"requestId":"fetch-1","request":{"url":"https://example.test/api/data","headers":{"Accept":"application/json","X-Remove":"old","X-Replace":"old"}}}
;

test "interception preserves first-match ordering and continues unmatched requests" {
    const allocator = std.testing.allocator;
    var event = try std.json.parseFromSlice(std.json.Value, allocator, paused_fixture, .{});
    defer event.deinit();
    const rules = [_]types.NetworkRule{
        .{ .id = "other", .url_pattern = "*other.test*", .action = .{ .block = {} } },
        .{ .id = "allow", .url_pattern = "*/api/*", .action = .{ .continue_request = {} } },
        .{ .id = "deny", .url_pattern = "*", .action = .{ .block = {} } },
    };
    const allowed = try buildCommand(allocator, 5, event.value.object, &rules);
    defer allocator.free(allowed);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, allowed, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Fetch.continueRequest", parsed.value.object.get("method").?.string);
    const blocked = try buildCommand(allocator, 6, event.value.object, rules[2..]);
    defer allocator.free(blocked);
    var denied = try std.json.parseFromSlice(std.json.Value, allocator, blocked, .{});
    defer denied.deinit();
    try std.testing.expectEqualStrings("Fetch.failRequest", denied.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("BlockedByClient", denied.value.object.get("params").?.object.get("errorReason").?.string);
    const unmatched = try buildCommand(allocator, 7, event.value.object, rules[0..1]);
    defer allocator.free(unmatched);
    try std.testing.expect(std.mem.indexOf(u8, unmatched, "Fetch.continueRequest") != null);
}

test "interception fulfills binary bodies with base64 and actual response headers" {
    const allocator = std.testing.allocator;
    var event = try std.json.parseFromSlice(std.json.Value, allocator, paused_fixture, .{});
    defer event.deinit();
    const command = try buildCommand(allocator, 1, event.value.object, &.{.{
        .id = "fixture",
        .url_pattern = "*",
        .action = .{ .fulfill = .{
            .status = 201,
            .body = "\x00\xffhello",
            .headers = &.{.{ .name = "content-type", .value = "application/octet-stream" }},
        } },
    }});
    defer allocator.free(command);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, command, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Fetch.fulfillRequest", parsed.value.object.get("method").?.string);
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqual(@as(i64, 201), params.get("responseCode").?.integer);
    const encoded = params.get("body").?.string;
    var decoded: [7]u8 = undefined;
    try std.base64.standard.Decoder.decode(&decoded, encoded);
    try std.testing.expectEqualStrings("\x00\xffhello", &decoded);
    try std.testing.expectEqualStrings("content-type", params.get("responseHeaders").?.array.items[0].object.get("name").?.string);
}

test "interception modifies headers case-insensitively without discarding unrelated headers" {
    const allocator = std.testing.allocator;
    var event = try std.json.parseFromSlice(std.json.Value, allocator, paused_fixture, .{});
    defer event.deinit();
    const command = try buildCommand(allocator, 1, event.value.object, &.{.{
        .id = "headers",
        .url_pattern = "*",
        .action = .{ .modify = .{
            .remove_header_names = &.{"x-remove"},
            .add_headers = &.{ .{ .name = "x-replace", .value = "new" }, .{ .name = "X-New", .value = "yes" } },
        } },
    }});
    defer allocator.free(command);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, command, .{});
    defer parsed.deinit();
    const headers = parsed.value.object.get("params").?.object.get("headers").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings("Accept", headers[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("application/json", headers[0].object.get("value").?.string);
    try std.testing.expectEqualStrings("new", headers[1].object.get("value").?.string);
    try std.testing.expectEqualStrings("yes", headers[2].object.get("value").?.string);
}

test "interception rules own caller data and URL globs match complete URLs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var body = [_]u8{'x'};
    const copied = try cloneRules(arena.allocator(), &.{.{ .id = "a", .url_pattern = "*", .action = .{ .fulfill = .{ .status = 200, .body = &body } } }});
    body[0] = 'y';
    try std.testing.expectEqualStrings("x", copied[0].action.fulfill.body);
    try std.testing.expect(globMatches("https://*.test/api/?", "https://example.test/api/a"));
    try std.testing.expect(!globMatches("https://*.test/api/?", "https://example.test/api/ab"));
    try std.testing.expect(!globMatches("*.test", "https://example.test/path"));
}
