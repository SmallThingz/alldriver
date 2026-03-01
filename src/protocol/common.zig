const std = @import("std");
const types = @import("../types.zig");

pub const AdapterKind = enum {
    cdp,
    bidi,
};

pub const SessionMode = enum {
    browser,
    webview,
};

pub const TransportKind = enum {
    cdp_ws,
    bidi_ws,
};

pub const EndpointParts = struct {
    adapter: AdapterKind,
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub fn defaultCapabilityForEngine(engine: types.EngineKind) types.CapabilitySet {
    return switch (engine) {
        .chromium => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = true,
            .downloads = true,
            .bidi_events = true,
        },
        .gecko => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = false,
            .downloads = true,
            .bidi_events = true,
        },
        .webkit => .{
            .dom = false,
            .js_eval = false,
            .network_intercept = false,
            .tracing = false,
            .downloads = false,
            .bidi_events = false,
        },
        .unknown => .{
            .dom = false,
            .js_eval = false,
            .network_intercept = false,
            .tracing = false,
            .downloads = false,
            .bidi_events = false,
        },
    };
}

pub fn preferredAdapterForEngine(engine: types.EngineKind) AdapterKind {
    return switch (engine) {
        .chromium => .cdp,
        .gecko => .bidi,
        .webkit => .cdp,
        .unknown => .cdp,
    };
}

pub fn transportForAdapter(adapter: AdapterKind) TransportKind {
    return switch (adapter) {
        .cdp => .cdp_ws,
        .bidi => .bidi_ws,
    };
}

pub fn parseEndpoint(endpoint: []const u8, default_adapter: AdapterKind) !EndpointParts {
    const scheme_end = std.mem.indexOf(u8, endpoint, "://") orelse return error.InvalidEndpoint;
    const scheme = endpoint[0..scheme_end];
    const rest = endpoint[scheme_end + 3 ..];

    if (std.mem.startsWith(u8, rest, "session/")) {
        return error.InvalidEndpoint;
    }

    var adapter = default_adapter;
    if (std.mem.eql(u8, scheme, "cdp") or
        std.mem.eql(u8, scheme, "ws") or
        std.mem.eql(u8, scheme, "wss"))
    {
        adapter = .cdp;
    } else if (std.mem.eql(u8, scheme, "bidi")) {
        adapter = .bidi;
    } else if (std.mem.eql(u8, scheme, "http") or
        std.mem.eql(u8, scheme, "https") or
        std.mem.eql(u8, scheme, "webdriver"))
    {
        return error.UnsupportedProtocol;
    }

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |idx| host_port[0..idx] else host_port;
    if (host.len == 0) return error.InvalidEndpoint;

    const port: u16 = if (colon) |idx|
        try std.fmt.parseInt(u16, host_port[idx + 1 ..], 10)
    else switch (adapter) {
        .cdp, .bidi => 9222,
    };

    return .{ .adapter = adapter, .host = host, .port = port, .path = path };
}

test "parse endpoint defaults" {
    const parsed = try parseEndpoint("cdp://127.0.0.1:9222/devtools/page/1", .cdp);
    try std.testing.expect(parsed.adapter == .cdp);
    try std.testing.expectEqual(@as(u16, 9222), parsed.port);
    try std.testing.expect(std.mem.eql(u8, parsed.host, "127.0.0.1"));
    try std.testing.expect(std.mem.eql(u8, parsed.path, "/devtools/page/1"));
}

test "preferred adapter contract stays driverless for chromium and gecko" {
    try std.testing.expectEqual(AdapterKind.cdp, preferredAdapterForEngine(.chromium));
    try std.testing.expectEqual(AdapterKind.bidi, preferredAdapterForEngine(.gecko));
    try std.testing.expectEqual(TransportKind.cdp_ws, transportForAdapter(.cdp));
    try std.testing.expectEqual(TransportKind.bidi_ws, transportForAdapter(.bidi));
}
