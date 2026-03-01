const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const discovery = @import("discovery/discover.zig");
const webview_discovery = @import("discovery/webview/discover.zig");
const session_mod = @import("core/session.zig");
const common = @import("protocol/common.zig");
const cdp = @import("protocol/cdp/adapter.zig");
const bidi = @import("protocol/bidi/adapter.zig");
const extensions = @import("extensions/api.zig");

pub const Session = session_mod.Session;

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) ![]types.BrowserInstall {
    return discovery.discover(allocator, prefs, opts);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) ![]types.WebViewRuntime {
    return webview_discovery.discover(allocator, prefs);
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !Session {
    const adapter_kind = switch (opts.install.engine) {
        .chromium => common.AdapterKind.cdp,
        .gecko => common.AdapterKind.bidi,
        else => return error.UnsupportedEngine,
    };
    const transport = common.transportForAdapter(adapter_kind);
    const capability_set = capabilitiesFor(opts.install.engine, adapter_kind);
    const effective_profile_dir = try resolveEffectiveProfileDir(allocator, opts.profile_mode, opts.profile_dir);
    var profile_dir_owned = true;
    defer if (profile_dir_owned) allocator.free(effective_profile_dir);
    errdefer if (opts.profile_mode == .ephemeral) {
        std.fs.cwd().deleteTree(effective_profile_dir) catch {};
    };

    const effective_ignore_tls_errors = opts.ignore_tls_errors or hasTlsAliasArg(opts.args);

    if (effective_ignore_tls_errors and opts.install.engine == .gecko) {
        try writeGeckoInsecureTlsPrefs(allocator, effective_profile_dir);
    }
    if (opts.install.engine == .gecko and opts.gecko_stealth_prefs) {
        try writeGeckoStealthPrefs(allocator, effective_profile_dir);
    }

    var raw_args: std.ArrayList([]const u8) = .empty;
    defer raw_args.deinit(allocator);

    var temp_owned_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_owned_strings.items) |buf| allocator.free(buf);
        temp_owned_strings.deinit(allocator);
    }

    try raw_args.append(allocator, opts.install.path);

    const debug_port = try reserveLocalPort();
    try appendDefaultArgs(
        allocator,
        &raw_args,
        &temp_owned_strings,
        opts,
        effective_ignore_tls_errors,
        adapter_kind,
        debug_port,
    );
    try appendProfileArgs(allocator, &raw_args, &temp_owned_strings, opts.install.engine, effective_profile_dir);
    try appendUserArgs(allocator, &raw_args, opts.args);

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

    const launch_timeout_ms = (opts.timeout_policy orelse types.TimeoutPolicy{}).launch_ms;
    waitForLocalDebugEndpoint(debug_port, launch_timeout_ms) catch return error.Timeout;

    const install_copy: types.BrowserInstall = .{
        .kind = opts.install.kind,
        .engine = opts.install.engine,
        .path = try allocator.dupe(u8, opts.install.path),
        .version = if (opts.install.version) |v| try allocator.dupe(u8, v) else null,
        .source = opts.install.source,
    };

    const id = session_mod.nextSessionId();
    const endpoint = try buildEndpoint(allocator, adapter_kind, id, debug_port);
    const ephemeral_profile_dir = if (opts.profile_mode == .ephemeral) blk: {
        profile_dir_owned = false;
        break :blk effective_profile_dir;
    } else null;

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
        .timeout_policy = opts.timeout_policy orelse .{},
        .child = child,
        .owned_argv = final_args,
        .ephemeral_profile_dir = ephemeral_profile_dir,
    };

    extensions.notifySessionInit(session.id);
    return session;
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !Session {
    var adapter_kind: common.AdapterKind = undefined;
    var engine: types.EngineKind = .unknown;
    var kind: types.BrowserKind = .chrome;

    if (std.mem.startsWith(u8, endpoint, "cdp://") or
        std.mem.startsWith(u8, endpoint, "ws://") or
        std.mem.startsWith(u8, endpoint, "wss://"))
    {
        adapter_kind = .cdp;
        engine = .chromium;
        kind = .chrome;
    } else if (std.mem.startsWith(u8, endpoint, "bidi://")) {
        adapter_kind = .bidi;
        engine = .gecko;
        kind = .firefox;
    } else {
        return error.UnsupportedProtocol;
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
    const adapter_kind = adapterForWebViewKind(opts.kind);
    const engine = webview_discovery.engineForWebView(opts.kind);
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
    if (opts.kind == .android_webview) return error.UnsupportedWebViewKind;

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

    const endpoint = if (opts.endpoint) |ep|
        try allocator.dupe(u8, ep)
    else
        try allocator.dupe(u8, "cdp://127.0.0.1:9222/");

    return Session{
        .allocator = allocator,
        .id = session_mod.nextSessionId(),
        .mode = .webview,
        .transport = .cdp_ws,
        .install = .{
            .kind = browserKindForWebView(opts.kind),
            .engine = .chromium,
            .path = try allocator.dupe(u8, opts.host_executable),
            .version = null,
            .source = .explicit,
        },
        .capability_set = cdp.capabilities(),
        .adapter_kind = .cdp,
        .endpoint = endpoint,
        .current_url = null,
        .browsing_context_id = null,
        .request_id = 0,
        .child = child,
        .owned_argv = argv,
    };
}

pub fn attachAndroidWebView(allocator: std.mem.Allocator, opts: types.AndroidWebViewAttachOptions) !Session {
    _ = opts.device_id;
    _ = opts.bridge_kind;
    _ = opts.socket_name;
    _ = opts.pid;
    const endpoint = if (opts.endpoint) |explicit|
        try allocator.dupe(u8, explicit)
    else
        try cdpEndpointForHostPort(allocator, opts.host, opts.port);
    defer allocator.free(endpoint);
    return attachWebView(allocator, .{ .kind = .android_webview, .endpoint = endpoint });
}

pub fn attachElectronWebView(allocator: std.mem.Allocator, opts: types.ElectronWebViewAttachOptions) !Session {
    const endpoint = if (opts.endpoint) |explicit|
        try allocator.dupe(u8, explicit)
    else
        try cdpEndpointForHostPort(allocator, opts.host, opts.port);
    defer allocator.free(endpoint);
    return attachWebView(allocator, .{ .kind = .electron, .endpoint = endpoint });
}

pub fn launchElectronWebView(allocator: std.mem.Allocator, opts: types.ElectronWebViewLaunchOptions) !Session {
    var args = std.ArrayList([]const u8).initCapacity(allocator, 2 + opts.args.len) catch return error.OutOfMemory;
    defer args.deinit(allocator);

    if (opts.app_path) |app_path| {
        args.appendAssumeCapacity(app_path);
    }
    for (opts.args) |arg| args.appendAssumeCapacity(arg);

    if (opts.headless) _ = opts.headless;
    if (opts.ignore_tls_errors) _ = opts.ignore_tls_errors;
    if (opts.profile_mode == .persistent and opts.profile_dir == null) return error.PersistentProfileDirRequired;

    return launchWebViewHost(allocator, .{
        .kind = .electron,
        .host_executable = opts.executable_path,
        .args = args.items,
        .endpoint = if (opts.debug_port) |port|
            try std.fmt.allocPrint(allocator, "cdp://127.0.0.1:{d}/", .{port})
        else
            "cdp://127.0.0.1:9222/",
    });
}

fn appendDefaultArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    temp_owned_strings: *std.ArrayList([]u8),
    opts: types.LaunchOptions,
    effective_ignore_tls_errors: bool,
    adapter: common.AdapterKind,
    debug_port: u16,
) !void {
    if (effective_ignore_tls_errors and opts.install.engine == .chromium) {
        try args.append(allocator, "--ignore-certificate-errors");
    }

    if (opts.headless) {
        switch (opts.install.engine) {
            .chromium => try args.append(allocator, "--headless=new"),
            .gecko => try args.append(allocator, "-headless"),
            else => {},
        }
    }

    // Keep headful launches clean by suppressing first-run/default-browser notices.
    if (!opts.headless) {
        switch (opts.install.engine) {
            .chromium => {
                try args.append(allocator, "--no-first-run");
                try args.append(allocator, "--no-default-browser-check");
                try args.append(allocator, "--disable-default-apps");
            },
            .gecko => {
                try args.append(allocator, "--no-default-browser-check");
            },
            else => {},
        }
    }

    switch (adapter) {
        .cdp, .bidi => {
            const flag = try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{debug_port});
            try temp_owned_strings.append(allocator, flag);
            try args.append(allocator, flag);
        },
    }
}

fn appendUserArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    user_args: []const []const u8,
) !void {
    for (user_args) |arg| {
        if (isTlsAliasArg(arg)) continue;
        try args.append(allocator, arg);
    }
}

fn hasTlsAliasArg(user_args: []const []const u8) bool {
    for (user_args) |arg| {
        if (isTlsAliasArg(arg)) return true;
    }
    return false;
}

fn isTlsAliasArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--no-tls") or
        std.mem.eql(u8, arg, "--ignore-tls-errors") or
        std.mem.eql(u8, arg, "--ignore-tls-error") or
        std.mem.eql(u8, arg, "--insecure-tls");
}

fn appendProfileArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    temp_owned_strings: *std.ArrayList([]u8),
    engine: types.EngineKind,
    effective_profile_dir: []const u8,
) !void {
    switch (engine) {
        .chromium => {
            const flag = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{effective_profile_dir});
            try temp_owned_strings.append(allocator, flag);
            try args.append(allocator, flag);
        },
        .gecko => {
            try args.append(allocator, "-profile");
            try args.append(allocator, effective_profile_dir);
        },
        else => {},
    }
}

fn resolveEffectiveProfileDir(
    allocator: std.mem.Allocator,
    profile_mode: types.ProfileMode,
    profile_dir: ?[]const u8,
) ![]u8 {
    const effective = switch (profile_mode) {
        .persistent => blk: {
            const configured = profile_dir orelse return error.PersistentProfileDirRequired;
            break :blk try allocator.dupe(u8, configured);
        },
        .ephemeral => if (profile_dir) |configured|
            try allocator.dupe(u8, configured)
        else
            try createEphemeralProfileDir(allocator),
    };
    errdefer allocator.free(effective);
    try ensureDirPathExists(effective);
    return effective;
}

fn createEphemeralProfileDir(allocator: std.mem.Allocator) ![]u8 {
    const base_dir = try tempBaseDirAlloc(allocator);
    defer allocator.free(base_dir);

    var nonce_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const stamp = @as(u64, @intCast(std.time.nanoTimestamp()));
    const leaf = try std.fmt.allocPrint(allocator, "alldriver-ephemeral-{x}-{x}", .{ stamp, nonce });
    defer allocator.free(leaf);

    const profile_dir = try std.fs.path.join(allocator, &.{ base_dir, leaf });
    errdefer allocator.free(profile_dir);
    try ensureDirPathExists(profile_dir);
    return profile_dir;
}

fn tempBaseDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            if (std.process.getEnvVarOwned(allocator, "TMP")) |dir| return dir else |_| {}
            if (std.process.getEnvVarOwned(allocator, "TEMP")) |dir| return dir else |_| {}
            if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |dir| return dir else |_| {}
            return allocator.dupe(u8, ".");
        },
        else => {
            if (std.process.getEnvVarOwned(allocator, "TMPDIR")) |dir| return dir else |_| {}
            return allocator.dupe(u8, "/tmp");
        },
    }
}

fn ensureDirPathExists(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn writeGeckoInsecureTlsPrefs(allocator: std.mem.Allocator, profile_dir: []const u8) !void {
    const user_js_path = try std.fs.path.join(allocator, &.{ profile_dir, "user.js" });
    defer allocator.free(user_js_path);

    var file = try std.fs.cwd().createFile(user_js_path, .{ .truncate = false, .read = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(
        \\user_pref("webdriver_accept_untrusted_certs", true);
        \\user_pref("webdriver_assume_untrusted_issuer", false);
        \\user_pref("security.cert_pinning.enforcement_level", 0);
        \\user_pref("network.stricttransportsecurity.preloadlist", false);
        \\user_pref("security.enterprise_roots.enabled", true);
        \\
    );
}

fn writeGeckoStealthPrefs(allocator: std.mem.Allocator, profile_dir: []const u8) !void {
    const user_js_path = try std.fs.path.join(allocator, &.{ profile_dir, "user.js" });
    defer allocator.free(user_js_path);

    var file = try std.fs.cwd().createFile(user_js_path, .{ .truncate = false, .read = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(
        \\user_pref("dom.webdriver.enabled", false);
        \\user_pref("privacy.resistFingerprinting", true);
        \\
    );
}

fn capabilitiesFor(engine: types.EngineKind, adapter: common.AdapterKind) types.CapabilitySet {
    return switch (adapter) {
        .cdp => cdp.capabilities(),
        .bidi => bidi.capabilitiesFor(engine),
    };
}

fn buildEndpoint(allocator: std.mem.Allocator, adapter: common.AdapterKind, session_id: u64, debug_port: u16) ![]u8 {
    return switch (adapter) {
        .cdp => std.fmt.allocPrint(allocator, "cdp://127.0.0.1:{d}/", .{debug_port}),
        .bidi => std.fmt.allocPrint(allocator, "bidi://127.0.0.1:{d}/session/{d}", .{ debug_port, session_id }),
    };
}

fn cdpEndpointForHostPort(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "cdp://{s}:{d}/", .{ host, port });
}

fn adapterForWebViewKind(kind: types.WebViewKind) common.AdapterKind {
    return switch (kind) {
        .webview2, .electron, .android_webview => .cdp,
    };
}

fn browserKindForWebView(kind: types.WebViewKind) types.BrowserKind {
    return switch (kind) {
        .webview2 => .edge,
        .electron, .android_webview => .chrome,
    };
}

fn reserveLocalPort() !u16 {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{});
    defer server.deinit();
    const real = server.listen_address.in.sa;
    return std.mem.bigToNative(u16, real.port);
}

fn waitForLocalDebugEndpoint(port: u16, timeout_ms: u32) !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline_ms) {
        const stream = std.net.tcpConnectToAddress(address) catch {
            std.Thread.sleep(25 * std.time.ns_per_ms);
            continue;
        };
        stream.close();
        return;
    }
    return error.Timeout;
}

test "attach supports cdp and bidi endpoints only" {
    const allocator = std.testing.allocator;
    var cdp_session = try attach(allocator, "cdp://127.0.0.1:9222/");
    defer cdp_session.deinit();
    try std.testing.expectEqual(common.TransportKind.cdp_ws, cdp_session.transport);

    var bidi_session = try attach(allocator, "bidi://127.0.0.1:9223/session/1");
    defer bidi_session.deinit();
    try std.testing.expectEqual(common.TransportKind.bidi_ws, bidi_session.transport);

    try std.testing.expectError(error.UnsupportedProtocol, attach(allocator, "http://127.0.0.1:4444/session/1"));
}

test "attachWebView is cdp-only for modern kinds" {
    const allocator = std.testing.allocator;
    var session = try attachWebView(allocator, .{
        .kind = .electron,
        .endpoint = "cdp://127.0.0.1:9222/",
    });
    defer session.deinit();
    try std.testing.expectEqual(common.AdapterKind.cdp, session.adapter_kind);
    try std.testing.expectEqual(common.TransportKind.cdp_ws, session.transport);
}

test "tls aliases are consumed and not forwarded as raw args" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    try appendUserArgs(allocator, &list, &.{
        "--no-tls",
        "--ignore-tls-errors",
        "--some-real-flag",
    });
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expect(std.mem.eql(u8, list.items[0], "--some-real-flag"));
    try std.testing.expect(hasTlsAliasArg(&.{ "--no-tls", "--abc" }));
    try std.testing.expect(!hasTlsAliasArg(&.{"--abc"}));
}

test "headful chromium defaults suppress startup notices" {
    const allocator = std.testing.allocator;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var temps: std.ArrayList([]u8) = .empty;
    defer {
        for (temps.items) |buf| allocator.free(buf);
        temps.deinit(allocator);
    }

    const opts: types.LaunchOptions = .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = "/bin/chrome",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .headless = false,
        .args = &.{},
    };

    try appendDefaultArgs(allocator, &args, &temps, opts, false, .cdp, 9222);
    try std.testing.expect(containsArg(args.items, "--no-first-run"));
    try std.testing.expect(containsArg(args.items, "--no-default-browser-check"));
    try std.testing.expect(containsArg(args.items, "--disable-default-apps"));
}

test "chromium tls ignore uses supported certificate flag" {
    const allocator = std.testing.allocator;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var temps: std.ArrayList([]u8) = .empty;
    defer {
        for (temps.items) |buf| allocator.free(buf);
        temps.deinit(allocator);
    }

    const opts: types.LaunchOptions = .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = "/bin/chrome",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    };

    try appendDefaultArgs(allocator, &args, &temps, opts, true, .cdp, 9222);
    try std.testing.expect(containsArg(args.items, "--ignore-certificate-errors"));
    try std.testing.expect(!containsArg(args.items, "--no-tls"));
}

fn containsArg(args: []const []const u8, want: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, want)) return true;
    }
    return false;
}
