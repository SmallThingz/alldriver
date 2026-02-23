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
    const capabilities = capabilitiesFor(opts.install.engine, adapter_kind);

    var raw_args: std.ArrayList([]const u8) = .empty;
    defer raw_args.deinit(allocator);

    var temp_owned_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_owned_strings.items) |buf| allocator.free(buf);
        temp_owned_strings.deinit(allocator);
    }

    try raw_args.append(allocator, opts.install.path);

    try appendDefaultArgs(allocator, &raw_args, &temp_owned_strings, opts, adapter_kind);

    for (opts.args) |arg| {
        try raw_args.append(allocator, arg);
    }

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
    const endpoint = try buildEndpoint(allocator, adapter_kind, id);

    const session = Session{
        .allocator = allocator,
        .id = id,
        .install = install_copy,
        .capabilities = capabilities,
        .adapter_kind = adapter_kind,
        .endpoint = endpoint,
        .current_url = null,
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

    if (std.mem.startsWith(u8, endpoint, "cdp://")) {
        adapter_kind = .cdp;
        engine = .chromium;
        kind = .chrome;
    } else if (std.mem.startsWith(u8, endpoint, "bidi://")) {
        adapter_kind = .bidi;
        engine = .gecko;
        kind = .firefox;
    } else if (std.mem.startsWith(u8, endpoint, "webdriver://")) {
        adapter_kind = .webdriver;
        engine = .webkit;
        kind = .safari;
    }

    const capabilities = capabilitiesFor(engine, adapter_kind);

    return Session{
        .allocator = allocator,
        .id = session_mod.nextSessionId(),
        .install = .{
            .kind = kind,
            .engine = engine,
            .path = try allocator.dupe(u8, "attached"),
            .version = null,
            .source = .explicit,
        },
        .capabilities = capabilities,
        .adapter_kind = adapter_kind,
        .endpoint = try allocator.dupe(u8, endpoint),
        .current_url = null,
        .child = null,
        .owned_argv = null,
    };
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !Session {
    const engine = webview_discovery.engineForWebView(opts.kind);
    const adapter_kind = adapterForWebViewKind(opts.kind);
    const capabilities = capabilitiesFor(engine, adapter_kind);

    return Session{
        .allocator = allocator,
        .id = session_mod.nextSessionId(),
        .install = .{
            .kind = browserKindForWebView(opts.kind),
            .engine = engine,
            .path = try allocator.dupe(u8, "webview-attached"),
            .version = null,
            .source = .explicit,
        },
        .capabilities = capabilities,
        .adapter_kind = adapter_kind,
        .endpoint = try allocator.dupe(u8, opts.endpoint),
        .current_url = null,
        .child = null,
        .owned_argv = null,
    };
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !Session {
    const engine = webview_discovery.engineForWebView(opts.kind);
    const adapter_kind = adapterForWebViewKind(opts.kind);
    const capabilities = capabilitiesFor(engine, adapter_kind);

    var argv_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv_list.items) |arg| allocator.free(arg);
        argv_list.deinit(allocator);
    }
    try argv_list.append(allocator, try allocator.dupe(u8, opts.host_executable));
    for (opts.args) |arg| {
        try argv_list.append(allocator, try allocator.dupe(u8, arg));
    }
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
        .install = .{
            .kind = browserKindForWebView(opts.kind),
            .engine = engine,
            .path = try allocator.dupe(u8, opts.host_executable),
            .version = null,
            .source = .explicit,
        },
        .capabilities = capabilities,
        .adapter_kind = adapter_kind,
        .endpoint = endpoint,
        .current_url = null,
        .child = child,
        .owned_argv = argv,
    };
}

fn appendDefaultArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    temp_owned_strings: *std.ArrayList([]u8),
    opts: types.LaunchOptions,
    adapter: common.AdapterKind,
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
        try args.append(allocator, "--remote-debugging-port=0");
    }
}

fn capabilitiesFor(engine: types.EngineKind, adapter: common.AdapterKind) types.CapabilitySet {
    return switch (adapter) {
        .cdp => cdp.capabilities(),
        .webdriver => webdriver.capabilitiesFor(engine),
        .bidi => bidi.capabilitiesFor(engine),
    };
}

fn buildEndpoint(allocator: std.mem.Allocator, adapter: common.AdapterKind, session_id: u64) ![]u8 {
    return switch (adapter) {
        .cdp => std.fmt.allocPrint(allocator, "cdp://session/{d}", .{session_id}),
        .webdriver => std.fmt.allocPrint(allocator, "webdriver://session/{d}", .{session_id}),
        .bidi => std.fmt.allocPrint(allocator, "bidi://session/{d}", .{session_id}),
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

test "attach infers adapter" {
    const allocator = std.testing.allocator;
    var s = try attach(allocator, "cdp://localhost:9222");
    defer s.deinit();
    try std.testing.expect(s.adapter_kind == .cdp);
    try std.testing.expect(s.capabilities.dom);
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
    }, .cdp);

    try std.testing.expect(hasArg(args.items, "--headless=new"));
    try std.testing.expect(hasArg(args.items, "--remote-debugging-port=0"));
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

    try std.testing.expect(std.mem.startsWith(u8, session.endpoint.?, "webdriver://session/"));
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
