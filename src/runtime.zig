const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const discovery = @import("discovery/discover.zig");
const session_mod = @import("core/session.zig");
const common = @import("protocol/common.zig");
const cdp = @import("protocol/cdp/adapter.zig");
const webdriver = @import("protocol/webdriver/adapter.zig");
const bidi = @import("protocol/bidi/adapter.zig");
const extensions = @import("extensions/api.zig");
const webview_discovery = @import("discovery/webview/discover.zig");

pub const Session = session_mod.Session;

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) ![]types.BrowserInstall {
    return discovery.discover(allocator, prefs, opts);
}

pub fn freeInstalls(allocator: std.mem.Allocator, installs: []types.BrowserInstall) void {
    for (installs) |install| {
        allocator.free(install.path);
        if (install.version) |version| allocator.free(version);
    }
    allocator.free(installs);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) ![]types.WebViewRuntime {
    return webview_discovery.discover(allocator, prefs);
}

pub fn freeWebViewRuntimes(allocator: std.mem.Allocator, runtimes: []types.WebViewRuntime) void {
    webview_discovery.freeRuntimes(allocator, runtimes);
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !Session {
    const adapter_kind = common.preferredAdapterForEngine(opts.install.engine);
    const transport = common.transportForAdapter(adapter_kind);
    const capability_set = capabilitiesFor(opts.install.engine, adapter_kind);

    var raw_args: std.ArrayList([]const u8) = .empty;
    defer raw_args.deinit(allocator);

    var temp_owned_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_owned_strings.items) |buf| allocator.free(buf);
        temp_owned_strings.deinit(allocator);
    }

    try raw_args.append(allocator, opts.install.path);

    const debug_port = if (adapter_kind == .cdp and opts.install.engine == .chromium)
        try reserveLocalPort(allocator)
    else
        null;

    try appendDefaultArgs(allocator, &raw_args, &temp_owned_strings, opts, adapter_kind, debug_port);

    for (opts.args) |arg| try raw_args.append(allocator, arg);

    const final_args = try extensions.applyLaunchArgs(allocator, opts, raw_args.items);
    errdefer {
        for (final_args) |arg| allocator.free(arg);
        allocator.free(final_args);
    }

    var child = std.process.Child.init(final_args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return error.SpawnFailed;
    errdefer {
        _ = child.kill() catch {};
    }

    const install_copy: types.BrowserInstall = .{
        .kind = opts.install.kind,
        .engine = opts.install.engine,
        .path = try allocator.dupe(u8, opts.install.path),
        .version = if (opts.install.version) |v| try allocator.dupe(u8, v) else null,
        .source = opts.install.source,
    };

    const id = session_mod.nextSessionId();
    const endpoint = try buildEndpoint(allocator, adapter_kind, id, debug_port);

    const session = Session{
        .allocator = allocator,
        .id = id,
        .mode = .browser,
        .transport = transport,
        .install = install_copy,
        .capability_set = capability_set,
        .adapter_kind = adapter_kind,
        .endpoint = endpoint,
        .current_url = null,
        .browsing_context_id = null,
        .request_id = 0,
        .child = child,
        .owned_argv = final_args,
    };

    extensions.notifySessionInit(session.id);
    return session;
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !Session {
    var adapter_kind: common.AdapterKind = .webdriver;
    var engine: types.EngineKind = .unknown;
    var kind: types.BrowserKind = .chrome;

    if (std.mem.startsWith(u8, endpoint, "cdp://") or std.mem.startsWith(u8, endpoint, "ws://")) {
        adapter_kind = .cdp;
        engine = .chromium;
        kind = .chrome;
    } else if (std.mem.startsWith(u8, endpoint, "bidi://")) {
        adapter_kind = .bidi;
        engine = .gecko;
        kind = .firefox;
    } else if (std.mem.startsWith(u8, endpoint, "webdriver://") or std.mem.startsWith(u8, endpoint, "http://")) {
        adapter_kind = .webdriver;
        engine = .webkit;
        kind = .safari;
    }

    const capability_set = capabilitiesFor(engine, adapter_kind);

    return Session{
        .allocator = allocator,
        .id = session_mod.nextSessionId(),
        .mode = .browser,
        .transport = common.transportForAdapter(adapter_kind),
        .install = .{
            .kind = kind,
            .engine = engine,
            .path = try allocator.dupe(u8, "attached"),
            .version = null,
            .source = .explicit,
        },
        .capability_set = capability_set,
        .adapter_kind = adapter_kind,
        .endpoint = try allocator.dupe(u8, endpoint),
        .current_url = null,
        .browsing_context_id = null,
        .request_id = 0,
        .child = null,
        .owned_argv = null,
    };
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !Session {
    const engine = webview_discovery.engineForWebView(opts.kind);
    const adapter_kind = adapterForWebViewKind(opts.kind);
    const capability_set = capabilitiesFor(engine, adapter_kind);

    return Session{
        .allocator = allocator,
        .id = session_mod.nextSessionId(),
        .mode = .webview,
        .transport = common.transportForAdapter(adapter_kind),
        .install = .{
            .kind = browserKindForWebView(opts.kind),
            .engine = engine,
            .path = try allocator.dupe(u8, "webview-attached"),
            .version = null,
            .source = .explicit,
        },
        .capability_set = capability_set,
        .adapter_kind = adapter_kind,
        .endpoint = try allocator.dupe(u8, opts.endpoint),
        .current_url = null,
        .browsing_context_id = null,
        .request_id = 0,
        .child = null,
        .owned_argv = null,
    };
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !Session {
    const engine = webview_discovery.engineForWebView(opts.kind);
    const adapter_kind = adapterForWebViewKind(opts.kind);
    const capability_set = capabilitiesFor(engine, adapter_kind);

    var argv_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv_list.items) |arg| allocator.free(arg);
        argv_list.deinit(allocator);
    }
    try argv_list.append(allocator, try allocator.dupe(u8, opts.host_executable));
    for (opts.args) |arg| try argv_list.append(allocator, try allocator.dupe(u8, arg));
    const argv = try argv_list.toOwnedSlice(allocator);
    errdefer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return error.SpawnFailed;
    errdefer {
        _ = child.kill() catch {};
    }

    const id = session_mod.nextSessionId();
    const endpoint = if (opts.endpoint) |ep|
        try allocator.dupe(u8, ep)
    else
        try std.fmt.allocPrint(allocator, "webview://session/{d}", .{id});

    return Session{
        .allocator = allocator,
        .id = id,
        .mode = .webview,
        .transport = common.transportForAdapter(adapter_kind),
        .install = .{
            .kind = browserKindForWebView(opts.kind),
            .engine = engine,
            .path = try allocator.dupe(u8, opts.host_executable),
            .version = null,
            .source = .explicit,
        },
        .capability_set = capability_set,
        .adapter_kind = adapter_kind,
        .endpoint = endpoint,
        .current_url = null,
        .browsing_context_id = null,
        .request_id = 0,
        .child = child,
        .owned_argv = argv,
    };
}

pub fn attachAndroidWebView(allocator: std.mem.Allocator, opts: types.AndroidWebViewAttachOptions) !Session {
    const endpoint = if (opts.endpoint) |ep|
        ep
    else if (opts.socket_name) |socket|
        try std.fmt.allocPrint(allocator, "cdp://127.0.0.1:9222/devtools/page/{s}", .{socket})
    else if (opts.pid) |pid|
        try std.fmt.allocPrint(allocator, "cdp://127.0.0.1:9222/devtools/page/{d}", .{pid})
    else
        return error.InvalidEndpoint;
    defer if (opts.endpoint == null) allocator.free(endpoint);
    _ = opts.device_id;

    return attachWebView(allocator, .{ .kind = .android_webview, .endpoint = endpoint });
}

pub fn attachIosWebView(allocator: std.mem.Allocator, opts: types.IosWebViewAttachOptions) !Session {
    const endpoint = if (opts.endpoint) |ep|
        ep
    else if (opts.page_id) |page_id|
        try std.fmt.allocPrint(allocator, "webdriver://127.0.0.1:9221/session/{s}", .{page_id})
    else if (opts.app_bundle_id) |bundle|
        try std.fmt.allocPrint(allocator, "webdriver://127.0.0.1:9221/session/{s}", .{bundle})
    else
        return error.InvalidEndpoint;
    defer if (opts.endpoint == null) allocator.free(endpoint);
    _ = opts.udid;

    return attachWebView(allocator, .{ .kind = .ios_wkwebview, .endpoint = endpoint });
}

fn appendDefaultArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    temp_owned_strings: *std.ArrayList([]u8),
    opts: types.LaunchOptions,
    adapter: common.AdapterKind,
    debug_port: ?u16,
) !void {
    if (opts.headless) {
        switch (opts.install.engine) {
            .chromium => try args.append(allocator, "--headless=new"),
            .gecko => try args.append(allocator, "-headless"),
            .webkit, .unknown => {},
        }
    }

    switch (opts.profile_mode) {
        .persistent => {
            if (opts.profile_dir) |profile_dir| {
                switch (opts.install.engine) {
                    .chromium => {
                        const flag = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{profile_dir});
                        try temp_owned_strings.append(allocator, flag);
                        try args.append(allocator, flag);
                    },
                    .gecko => {
                        try args.append(allocator, "-profile");
                        try args.append(allocator, profile_dir);
                    },
                    .webkit, .unknown => {},
                }
            }
        },
        .ephemeral => switch (opts.install.engine) {
            .chromium => try args.append(allocator, "--incognito"),
            .gecko => try args.append(allocator, "-private"),
            .webkit, .unknown => {},
        },
    }

    if (adapter == .cdp and opts.install.engine == .chromium) {
        const port = debug_port orelse 9222;
        const flag = try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{port});
        try temp_owned_strings.append(allocator, flag);
        try args.append(allocator, flag);
    }
}

fn capabilitiesFor(engine: types.EngineKind, adapter: common.AdapterKind) types.CapabilitySet {
    return switch (adapter) {
        .cdp => cdp.capabilities(),
        .webdriver => webdriver.capabilitiesFor(engine),
        .bidi => bidi.capabilitiesFor(engine),
    };
}

fn buildEndpoint(allocator: std.mem.Allocator, adapter: common.AdapterKind, session_id: u64, debug_port: ?u16) ![]u8 {
    return switch (adapter) {
        .cdp => std.fmt.allocPrint(allocator, "cdp://127.0.0.1:{d}/", .{debug_port orelse 9222}),
        .webdriver => std.fmt.allocPrint(allocator, "webdriver://127.0.0.1:4444/session/{d}", .{session_id}),
        .bidi => std.fmt.allocPrint(allocator, "bidi://127.0.0.1:9223/session/{d}", .{session_id}),
    };
}

fn adapterForWebViewKind(kind: types.WebViewKind) common.AdapterKind {
    return switch (kind) {
        .webview2, .android_webview => .cdp,
        .wkwebview, .webkitgtk, .ios_wkwebview => .webdriver,
    };
}

fn browserKindForWebView(kind: types.WebViewKind) types.BrowserKind {
    return switch (kind) {
        .webview2 => .edge,
        .wkwebview, .ios_wkwebview, .webkitgtk => .safari,
        .android_webview => .chrome,
    };
}

fn reserveLocalPort(allocator: std.mem.Allocator) !u16 {
    _ = allocator;
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{});
    defer server.deinit();

    const real = server.listen_address.in.sa;
    return std.mem.bigToNative(u16, real.port);
}

test "attach infers adapter" {
    const allocator = std.testing.allocator;
    var s = try attach(allocator, "cdp://localhost:9222");
    defer s.deinit();
    try std.testing.expect(s.adapter_kind == .cdp);
    try std.testing.expect(s.capabilities().dom);
}

test "appendDefaultArgs adds chromium flags for persistent profile and cdp" {
    const allocator = std.testing.allocator;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var temp_owned: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_owned.items) |item| allocator.free(item);
        temp_owned.deinit(allocator);
    }

    try appendDefaultArgs(allocator, &args, &temp_owned, .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = "/bin/true",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .persistent,
        .profile_dir = "/tmp/driver-profile",
        .headless = true,
        .args = &.{},
    }, .cdp, 9333);

    try std.testing.expect(hasArg(args.items, "--headless=new"));
    try std.testing.expect(hasArg(args.items, "--remote-debugging-port=9333"));
    try std.testing.expect(hasPrefixArg(args.items, "--user-data-dir=/tmp/driver-profile"));
}

test "launch spawns process and returns webdriver endpoint for unknown engine" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try launch(allocator, .{
        .install = .{
            .kind = .sigmaos,
            .engine = .unknown,
            .path = "/bin/sh",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .profile_dir = null,
        .headless = false,
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    try std.testing.expect(std.mem.startsWith(u8, session.endpoint.?, "webdriver://session/") or std.mem.startsWith(u8, session.endpoint.?, "webdriver://127.0.0.1"));
    try std.testing.expect(session.child != null);
}

test "attachWebView maps WebView2 to chromium CDP session" {
    const allocator = std.testing.allocator;
    var session = try attachWebView(allocator, .{
        .kind = .webview2,
        .endpoint = "cdp://127.0.0.1:9222/devtools/page/1",
    });
    defer session.deinit();

    try std.testing.expectEqual(types.BrowserKind.edge, session.install.kind);
    try std.testing.expectEqual(types.EngineKind.chromium, session.install.engine);
    try std.testing.expect(session.adapter_kind == .cdp);
}

test "launchWebViewHost spawns host process" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try launchWebViewHost(allocator, .{
        .kind = .webkitgtk,
        .host_executable = "/bin/sh",
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    try std.testing.expectEqual(types.EngineKind.webkit, session.install.engine);
    try std.testing.expect(std.mem.startsWith(u8, session.endpoint.?, "webview://session/"));
    try std.testing.expect(session.child != null);
}

test "attachAndroidWebView builds CDP webview session" {
    const allocator = std.testing.allocator;
    var session = try attachAndroidWebView(allocator, .{
        .device_id = "emulator-5554",
        .pid = 123,
    });
    defer session.deinit();

    try std.testing.expect(session.mode == .webview);
    try std.testing.expect(session.transport == .cdp_ws);
    try std.testing.expect(std.mem.startsWith(u8, session.endpoint.?, "cdp://"));
}

test "attachIosWebView builds webdriver webview session" {
    const allocator = std.testing.allocator;
    var session = try attachIosWebView(allocator, .{
        .udid = "sim-udid",
        .page_id = "42",
    });
    defer session.deinit();

    try std.testing.expect(session.mode == .webview);
    try std.testing.expect(session.transport == .webdriver_http);
    try std.testing.expect(std.mem.startsWith(u8, session.endpoint.?, "webdriver://"));
}

fn hasArg(args: []const []const u8, expected: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, expected)) return true;
    }
    return false;
}

fn hasPrefixArg(args: []const []const u8, expected_prefix: []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, expected_prefix)) return true;
    }
    return false;
}
