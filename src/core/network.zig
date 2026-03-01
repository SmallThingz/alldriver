const std = @import("std");
const Session = @import("session.zig").Session;
const types = @import("../types.zig");
const executor = @import("../protocol/executor.zig");

pub const NetworkRule = types.NetworkRule;
pub const InterceptAction = types.InterceptAction;
pub const RequestEvent = types.RequestEvent;
pub const ResponseEvent = types.ResponseEvent;

pub fn enableInterception(session: *Session) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    try executor.enableNetworkInterception(session);
}

pub fn disableInterception(session: *Session) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    try clearInterceptRules(session);
}

pub fn addInterceptRule(session: *Session, rule: NetworkRule) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;

    const owned = try cloneRule(session.allocator, rule);
    errdefer freeRule(session.allocator, owned);

    try executor.addNetworkRule(session, owned);
    try session.rules.append(session.allocator, owned);
}

pub fn removeInterceptRule(session: *Session, rule_id: []const u8) !bool {
    var i: usize = 0;
    while (i < session.rules.items.len) : (i += 1) {
        if (std.mem.eql(u8, session.rules.items[i].id, rule_id)) {
            const removed = session.rules.swapRemove(i);
            defer freeRule(session.allocator, removed);
            try syncRemoteRules(session);
            return true;
        }
    }
    return false;
}

pub fn clearInterceptRules(session: *Session) !void {
    if (session.supports(.network_intercept)) {
        executor.disableNetworkInterception(session) catch |err| switch (err) {
            error.UnsupportedProtocol => {},
            else => return err,
        };
    }

    while (session.rules.items.len > 0) {
        const rule = session.rules.pop().?;
        freeRule(session.allocator, rule);
    }
}

pub fn onRequest(session: *Session, callback: *const fn (RequestEvent) void) void {
    session.on_request = callback;
}

pub fn onResponse(session: *Session, callback: *const fn (ResponseEvent) void) void {
    session.on_response = callback;
}

pub fn subscribe(session: *Session, callback: *const fn (event_json: []const u8) void) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    try enableInterception(session);
    callback("{\"event\":\"network.subscription.active\"}");
}

pub fn emitDebugEvent(session: *Session, event_json: []const u8) void {
    if (session.on_request) |cb| {
        cb(.{
            .request_id = "debug",
            .method = "DEBUG",
            .url = event_json,
            .headers_json = "{}",
        });
    }
}

pub fn serializeBlockRule(allocator: std.mem.Allocator, glob: []const u8) ![]u8 {
    const escaped = try escapeJsonString(allocator, glob);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "{{\"action\":\"block\",\"urlPattern\":\"{s}\"}}", .{escaped});
}

fn cloneRule(allocator: std.mem.Allocator, rule: NetworkRule) !NetworkRule {
    return .{
        .id = try allocator.dupe(u8, rule.id),
        .url_pattern = try allocator.dupe(u8, rule.url_pattern),
        .action = try cloneAction(allocator, rule.action),
    };
}

fn cloneAction(allocator: std.mem.Allocator, action: InterceptAction) !InterceptAction {
    return switch (action) {
        .block => .{ .block = {} },
        .continue_request => .{ .continue_request = {} },
        .fulfill => |f| blk: {
            const headers = try allocator.alloc(types.Header, f.headers.len);
            errdefer allocator.free(headers);

            var i: usize = 0;
            errdefer {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    allocator.free(headers[j].name);
                    allocator.free(headers[j].value);
                }
            }

            for (f.headers, 0..) |h, idx| {
                headers[idx] = .{
                    .name = try allocator.dupe(u8, h.name),
                    .value = try allocator.dupe(u8, h.value),
                };
                i = idx + 1;
            }

            break :blk .{ .fulfill = .{
                .status = f.status,
                .body = try allocator.dupe(u8, f.body),
                .headers = headers,
            } };
        },
        .modify => |m| blk: {
            const add_headers = try allocator.alloc(types.Header, m.add_headers.len);
            errdefer allocator.free(add_headers);

            var i: usize = 0;
            errdefer {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    allocator.free(add_headers[j].name);
                    allocator.free(add_headers[j].value);
                }
            }

            for (m.add_headers, 0..) |h, idx| {
                add_headers[idx] = .{
                    .name = try allocator.dupe(u8, h.name),
                    .value = try allocator.dupe(u8, h.value),
                };
                i = idx + 1;
            }

            const remove_names = try allocator.alloc([]const u8, m.remove_header_names.len);
            errdefer allocator.free(remove_names);

            var k: usize = 0;
            errdefer {
                var j: usize = 0;
                while (j < k) : (j += 1) allocator.free(remove_names[j]);
            }

            for (m.remove_header_names, 0..) |n, idx| {
                remove_names[idx] = try allocator.dupe(u8, n);
                k = idx + 1;
            }

            break :blk .{ .modify = .{
                .add_headers = add_headers,
                .remove_header_names = remove_names,
            } };
        },
    };
}

fn freeRule(allocator: std.mem.Allocator, rule: NetworkRule) void {
    allocator.free(rule.id);
    allocator.free(rule.url_pattern);

    switch (rule.action) {
        .block, .continue_request => {},
        .fulfill => |f| {
            for (f.headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(f.headers);
            allocator.free(f.body);
        },
        .modify => |m| {
            for (m.add_headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(m.add_headers);
            for (m.remove_header_names) |n| allocator.free(n);
            allocator.free(m.remove_header_names);
        },
    }
}

fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn syncRemoteRules(session: *Session) !void {
    if (!session.supports(.network_intercept)) return;
    executor.disableNetworkInterception(session) catch |err| switch (err) {
        error.UnsupportedProtocol => return,
        else => return err,
    };
    if (session.rules.items.len == 0) return;
    try executor.enableNetworkInterception(session);
    for (session.rules.items) |rule| {
        try executor.addNetworkRule(session, rule);
    }
}
