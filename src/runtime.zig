const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const discovery = @import("discovery/discover.zig");
const session_mod = @import("core/session.zig");
const common = @import("protocol/common.zig");
const cdp = @import("protocol/cdp/adapter.zig");
const webdriver = @import("protocol/webdriver/adapter.zig");
const bidi = @import("protocol/bidi/adapter.zig");
const http = @import("transport/http_client.zig");
const extensions = @import("extensions/api.zig");
const webview_discovery = @import("discovery/webview/discover.zig");
const string_util = @import("util/strings.zig");

pub const Session = session_mod.Session;
const webdriver_startup_timeout_ms: i64 = 8_000;
const webdriver_startup_sleep_ms: u64 = 100;
const default_webdriver_session_body = "{\"capabilities\":{\"alwaysMatch\":{},\"firstMatch\":[{}]}}";
const default_webdriver_session_body_accept_insecure = "{\"capabilities\":{\"alwaysMatch\":{\"acceptInsecureCerts\":true},\"firstMatch\":[{}]}}";

const WebKitGtkResolvedBrowserBinarySource = enum {
    none,
    auto,
    explicit,
};

const WebKitGtkResolvedBrowserBinary = struct {
    path: ?[]u8 = null,
    source: WebKitGtkResolvedBrowserBinarySource = .none,
};

const WebKitGtkSessionCreatePlan = struct {
    primary_body: []u8,
    fallback_body: ?[]u8 = null,
};

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
    const effective_profile_dir = try resolveEffectiveProfileDir(allocator, opts.profile_mode, opts.profile_dir);
    var effective_profile_dir_owned = true;
    defer if (effective_profile_dir_owned) allocator.free(effective_profile_dir);
    errdefer if (opts.profile_mode == .ephemeral) {
        std.fs.cwd().deleteTree(effective_profile_dir) catch {};
    };
    if (opts.ignore_tls_errors and opts.install.engine == .gecko) {
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

    const debug_port = if (adapter_kind == .cdp and opts.install.engine == .chromium)
        try reserveLocalPort(allocator)
    else
        null;

    try appendDefaultArgs(allocator, &raw_args, &temp_owned_strings, opts, adapter_kind, debug_port);
    try appendProfileArgs(allocator, &raw_args, &temp_owned_strings, opts.install.engine, effective_profile_dir);

    for (opts.args) |arg| try raw_args.append(allocator, arg);

    const final_args = try extensions.applyLaunchArgs(allocator, opts, raw_args.items);
    errdefer {
        for (final_args) |arg| allocator.free(arg);
        allocator.free(final_args);
    }

    var launch_env: ?std.process.EnvMap = null;
    defer if (launch_env) |*env_map| env_map.deinit();

    if (needsProfileEnvSandbox(opts.install.engine)) {
        var env_map = try std.process.getEnvMap(allocator);
        errdefer env_map.deinit();
        try applyProfileSandboxEnv(allocator, &env_map, builtin.os.tag, effective_profile_dir);
        launch_env = env_map;
    }

    var child = std.process.Child.init(final_args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    if (launch_env) |*env_map| child.env_map = env_map;

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
    const ephemeral_profile_dir = if (opts.profile_mode == .ephemeral) blk: {
        effective_profile_dir_owned = false;
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
        .child = child,
        .owned_argv = final_args,
        .ephemeral_profile_dir = ephemeral_profile_dir,
    };

    extensions.notifySessionInit(session.id);
    return session;
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !Session {
    var adapter_kind: common.AdapterKind = .webdriver;
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
    } else if (std.mem.startsWith(u8, endpoint, "webdriver://") or
        std.mem.startsWith(u8, endpoint, "http://") or
        std.mem.startsWith(u8, endpoint, "https://"))
    {
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
    if (engine == .chromium and opts.legacy_automation_markers) {
        try argv_list.append(allocator, try allocator.dupe(u8, "--disable-blink-features=AutomationControlled"));
        try argv_list.append(allocator, try allocator.dupe(u8, "--disable-infobars"));
    }
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
    else
        try buildAndroidWebViewEndpoint(allocator, opts);
    defer if (opts.endpoint == null) allocator.free(endpoint);

    switch (opts.bridge_kind) {
        .adb, .shizuku, .direct => {},
    }
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

pub fn attachWebKitGtkWebView(allocator: std.mem.Allocator, opts: types.WebKitGtkWebViewAttachOptions) !Session {
    const endpoint = if (opts.endpoint) |ep|
        ep
    else blk: {
        const session_id = opts.session_id orelse return error.InvalidEndpoint;
        break :blk try std.fmt.allocPrint(
            allocator,
            "webdriver://{s}:{d}/session/{s}",
            .{ opts.host, opts.port, session_id },
        );
    };
    defer if (opts.endpoint == null) allocator.free(endpoint);

    return attachWebView(allocator, .{ .kind = .webkitgtk, .endpoint = endpoint });
}

pub fn launchWebKitGtkWebView(allocator: std.mem.Allocator, opts: types.WebKitGtkWebViewLaunchOptions) !Session {
    if (opts.host.len == 0) return error.InvalidEndpoint;

    const driver_path = if (opts.driver_executable_path) |path|
        try allocator.dupe(u8, path)
    else
        try discoverWebKitGtkDriverPath(allocator);
    defer allocator.free(driver_path);

    const resolved_port = opts.port orelse try reserveLocalPort(allocator);
    const effective_profile_dir = try resolveEffectiveProfileDir(allocator, opts.profile_mode, opts.profile_dir);
    var effective_profile_dir_owned = true;
    defer if (effective_profile_dir_owned) allocator.free(effective_profile_dir);
    errdefer if (opts.profile_mode == .ephemeral) {
        std.fs.cwd().deleteTree(effective_profile_dir) catch {};
    };

    const resolved_browser = try resolveWebKitGtkBrowserBinary(allocator, opts.browser_target, opts.browser_binary_path);
    defer if (resolved_browser.path) |path| allocator.free(path);

    const session_plan = try buildWebKitGtkSessionCreatePlan(allocator, opts, resolved_browser);
    defer {
        allocator.free(session_plan.primary_body);
        if (session_plan.fallback_body) |body| allocator.free(body);
    }

    const argv = try buildWebKitGtkDriverArgv(allocator, opts, driver_path, resolved_port);
    errdefer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    var launch_env = try std.process.getEnvMap(allocator);
    defer launch_env.deinit();
    try applyProfileSandboxEnv(allocator, &launch_env, builtin.os.tag, effective_profile_dir);
    if (opts.ignore_tls_errors) {
        try launch_env.put("WEBKIT_IGNORE_TLS_ERRORS", "1");
    }
    if (builtin.os.tag == .linux) {
        try launch_env.put("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1");
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.env_map = &launch_env;

    child.spawn() catch return error.SpawnFailed;
    errdefer {
        _ = child.kill() catch {};
    }

    try waitForWebDriverReady(allocator, opts.host, resolved_port);
    const session_id = createWebDriverSessionIdWithTimeout(
        allocator,
        opts.host,
        resolved_port,
        session_plan.primary_body,
        opts.session_create_timeout_ms,
    ) catch |err| blk: {
        if (session_plan.fallback_body) |fallback_body| {
            break :blk try createWebDriverSessionIdWithTimeout(
                allocator,
                opts.host,
                resolved_port,
                fallback_body,
                opts.session_create_timeout_ms,
            );
        }
        return err;
    };
    defer allocator.free(session_id);

    const endpoint = try std.fmt.allocPrint(allocator, "webdriver://127.0.0.1:{d}/session/{s}", .{ resolved_port, session_id });
    const ephemeral_profile_dir = if (opts.profile_mode == .ephemeral) blk: {
        effective_profile_dir_owned = false;
        break :blk effective_profile_dir;
    } else null;

    return Session{
        .allocator = allocator,
        .id = session_mod.nextSessionId(),
        .mode = .webview,
        .transport = .webdriver_http,
        .install = .{
            .kind = .safari,
            .engine = .webkit,
            .path = try allocator.dupe(u8, driver_path),
            .version = null,
            .source = .explicit,
        },
        .capability_set = capabilitiesFor(.webkit, .webdriver),
        .adapter_kind = .webdriver,
        .endpoint = endpoint,
        .current_url = null,
        .browsing_context_id = null,
        .request_id = 0,
        .child = child,
        .owned_argv = argv,
        .ephemeral_profile_dir = ephemeral_profile_dir,
    };
}

pub fn attachElectronWebView(allocator: std.mem.Allocator, opts: types.ElectronWebViewAttachOptions) !Session {
    const endpoint = if (opts.endpoint) |ep|
        ep
    else
        try std.fmt.allocPrint(allocator, "cdp://{s}:{d}/", .{ opts.host, opts.port });
    defer if (opts.endpoint == null) allocator.free(endpoint);

    return attachWebView(allocator, .{ .kind = .electron, .endpoint = endpoint });
}

pub fn launchElectronWebView(allocator: std.mem.Allocator, opts: types.ElectronWebViewLaunchOptions) !Session {
    const debug_port = opts.debug_port orelse try reserveLocalPort(allocator);
    const effective_profile_dir = try resolveEffectiveProfileDir(allocator, opts.profile_mode, opts.profile_dir);
    var effective_profile_dir_owned = true;
    defer if (effective_profile_dir_owned) allocator.free(effective_profile_dir);
    errdefer if (opts.profile_mode == .ephemeral) {
        std.fs.cwd().deleteTree(effective_profile_dir) catch {};
    };

    var argv_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv_list.items) |arg| allocator.free(arg);
        argv_list.deinit(allocator);
    }

    try argv_list.append(allocator, try allocator.dupe(u8, opts.executable_path));
    if (opts.app_path) |app_path| {
        try argv_list.append(allocator, try allocator.dupe(u8, app_path));
    }
    if (opts.headless) {
        try argv_list.append(allocator, try allocator.dupe(u8, "--headless=new"));
    }
    if (opts.legacy_automation_markers) {
        try argv_list.append(allocator, try allocator.dupe(u8, "--disable-blink-features=AutomationControlled"));
        try argv_list.append(allocator, try allocator.dupe(u8, "--disable-infobars"));
    }
    if (opts.ignore_tls_errors) {
        try argv_list.append(allocator, try allocator.dupe(u8, "--ignore-certificate-errors"));
        try argv_list.append(allocator, try allocator.dupe(u8, "--allow-insecure-localhost"));
    }

    const debug_flag = try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{debug_port});
    try argv_list.append(allocator, debug_flag);

    const profile_flag = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{effective_profile_dir});
    try argv_list.append(allocator, profile_flag);

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

    const endpoint = try std.fmt.allocPrint(allocator, "cdp://127.0.0.1:{d}/", .{debug_port});
    const ephemeral_profile_dir = if (opts.profile_mode == .ephemeral) blk: {
        effective_profile_dir_owned = false;
        break :blk effective_profile_dir;
    } else null;

    return Session{
        .allocator = allocator,
        .id = session_mod.nextSessionId(),
        .mode = .webview,
        .transport = .cdp_ws,
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, opts.executable_path),
            .version = null,
            .source = .explicit,
        },
        .capability_set = capabilitiesFor(.chromium, .cdp),
        .adapter_kind = .cdp,
        .endpoint = endpoint,
        .current_url = null,
        .browsing_context_id = null,
        .request_id = 0,
        .child = child,
        .owned_argv = argv,
        .ephemeral_profile_dir = ephemeral_profile_dir,
    };
}

fn buildWebKitGtkDriverArgv(
    allocator: std.mem.Allocator,
    opts: types.WebKitGtkWebViewLaunchOptions,
    driver_path: []const u8,
    resolved_port: u16,
) ![]const []const u8 {
    var argv_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv_list.items) |arg| allocator.free(arg);
        argv_list.deinit(allocator);
    }

    try argv_list.append(allocator, try allocator.dupe(u8, driver_path));
    try argv_list.append(allocator, try std.fmt.allocPrint(allocator, "--port={d}", .{resolved_port}));
    try argv_list.append(allocator, try std.fmt.allocPrint(allocator, "--host={s}", .{opts.host}));
    if (opts.replace_on_new_session) {
        try argv_list.append(allocator, try allocator.dupe(u8, "--replace-on-new-session"));
    }
    for (opts.driver_args) |arg| {
        try argv_list.append(allocator, try allocator.dupe(u8, arg));
    }

    return argv_list.toOwnedSlice(allocator);
}

fn waitForWebDriverReady(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    const deadline = std.time.milliTimestamp() + webdriver_startup_timeout_ms;

    while (true) {
        const response = http.getJson(allocator, host, port, "/status") catch |err| {
            if (std.time.milliTimestamp() >= deadline) return err;
            std.Thread.sleep(webdriver_startup_sleep_ms * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(response.body);

        if (response.status_code >= 200 and response.status_code < 300 and try webDriverStatusReady(allocator, response.body)) {
            return;
        }

        if (std.time.milliTimestamp() >= deadline) return error.Timeout;
        std.Thread.sleep(webdriver_startup_sleep_ms * std.time.ns_per_ms);
    }
}

fn buildWebKitGtkSessionCreatePlan(
    allocator: std.mem.Allocator,
    opts: types.WebKitGtkWebViewLaunchOptions,
    resolved_browser: WebKitGtkResolvedBrowserBinary,
) !WebKitGtkSessionCreatePlan {
    if (opts.session_capabilities_json) |body| {
        return .{
            .primary_body = try allocator.dupe(u8, body),
            .fallback_body = null,
        };
    }

    const auto_detected_minibrowser = blk: {
        if (opts.browser_target != .auto) break :blk false;
        if (resolved_browser.path == null) break :blk false;
        const path = resolved_browser.path orelse break :blk false;
        const base = std.fs.path.basename(path);
        break :blk string_util.containsIgnoreCase(base, "minibrowser");
    };
    const auto_uses_default_capabilities = opts.browser_target == .auto and
        opts.browser_args.len == 0 and
        !auto_detected_minibrowser;
    const browser_binary_for_capabilities: ?[]const u8 = if (opts.browser_target == .auto and !auto_detected_minibrowser)
        null
    else
        resolved_browser.path;

    const needs_minibrowser_automation = blk: {
        if (browser_binary_for_capabilities == null) break :blk false;
        const path = browser_binary_for_capabilities orelse break :blk false;
        const base = std.fs.path.basename(path);
        break :blk string_util.containsIgnoreCase(base, "minibrowser") and !hasArgValue(opts.browser_args, "--automation");
    };

    const needs_minibrowser_ignore_tls = blk: {
        if (browser_binary_for_capabilities == null) break :blk false;
        if (!opts.ignore_tls_errors) break :blk false;
        const path = browser_binary_for_capabilities orelse break :blk false;
        const base = std.fs.path.basename(path);
        break :blk string_util.containsIgnoreCase(base, "minibrowser") and !hasArgValue(opts.browser_args, "--ignore-tls-errors");
    };

    const primary_body = if (auto_uses_default_capabilities)
        try defaultWebDriverSessionBodyAlloc(allocator, opts.ignore_tls_errors)
    else
        try buildWebKitGtkSessionCapabilitiesJson(
            allocator,
            browser_binary_for_capabilities,
            opts.browser_args,
            needs_minibrowser_automation,
            needs_minibrowser_ignore_tls,
            opts.ignore_tls_errors,
        );
    var fallback_body: ?[]u8 = null;
    errdefer if (fallback_body) |body| allocator.free(body);

    if (!auto_uses_default_capabilities and resolved_browser.path != null and resolved_browser.source == .auto and opts.browser_target == .auto) {
        fallback_body = try defaultWebDriverSessionBodyAlloc(allocator, opts.ignore_tls_errors);
    }

    return .{
        .primary_body = primary_body,
        .fallback_body = fallback_body,
    };
}

fn buildWebKitGtkSessionCapabilitiesJson(
    allocator: std.mem.Allocator,
    browser_binary_path: ?[]const u8,
    browser_args: []const []const u8,
    inject_automation_arg: bool,
    inject_ignore_tls_arg: bool,
    accept_insecure_certs: bool,
) ![]u8 {
    if (browser_binary_path == null and browser_args.len == 0 and !inject_automation_arg and !inject_ignore_tls_arg and !accept_insecure_certs) {
        return defaultWebDriverSessionBodyAlloc(allocator, false);
    }

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "{\"capabilities\":{\"alwaysMatch\":{");
    var wrote_always_match_field = false;

    if (accept_insecure_certs) {
        try body.appendSlice(allocator, "\"acceptInsecureCerts\":true");
        wrote_always_match_field = true;
    }

    const has_browser_options = browser_binary_path != null or browser_args.len > 0 or inject_automation_arg or inject_ignore_tls_arg;
    if (has_browser_options) {
        if (wrote_always_match_field) try body.append(allocator, ',');
        try body.appendSlice(allocator, "\"webkitgtk:browserOptions\":{");
        var wrote_browser_options_field = false;

        if (browser_binary_path) |binary| {
            const escaped = try escapeJsonStringAlloc(allocator, binary);
            defer allocator.free(escaped);

            try body.writer(allocator).print("\"binary\":\"{s}\"", .{escaped});
            wrote_browser_options_field = true;
        }

        if (browser_args.len > 0 or inject_automation_arg or inject_ignore_tls_arg) {
            if (wrote_browser_options_field) try body.append(allocator, ',');
            try body.appendSlice(allocator, "\"args\":[");
            var idx: usize = 0;
            if (inject_automation_arg) {
                try body.appendSlice(allocator, "\"--automation\"");
                idx += 1;
            }
            if (inject_ignore_tls_arg) {
                if (idx > 0) try body.append(allocator, ',');
                try body.appendSlice(allocator, "\"--ignore-tls-errors\"");
                idx += 1;
            }
            for (browser_args) |arg| {
                if (idx > 0) try body.append(allocator, ',');
                const escaped = try escapeJsonStringAlloc(allocator, arg);
                defer allocator.free(escaped);
                try body.writer(allocator).print("\"{s}\"", .{escaped});
                idx += 1;
            }
            try body.append(allocator, ']');
        }

        try body.append(allocator, '}');
    }

    try body.appendSlice(allocator, "},\"firstMatch\":[{}]}}");
    return body.toOwnedSlice(allocator);
}

fn defaultWebDriverSessionBodyAlloc(allocator: std.mem.Allocator, accept_insecure_certs: bool) ![]u8 {
    const body = if (accept_insecure_certs)
        default_webdriver_session_body_accept_insecure
    else
        default_webdriver_session_body;
    return allocator.dupe(u8, body);
}

fn resolveWebKitGtkBrowserBinary(
    allocator: std.mem.Allocator,
    target: types.WebKitGtkBrowserTarget,
    browser_binary_path: ?[]const u8,
) !WebKitGtkResolvedBrowserBinary {
    if (browser_binary_path) |path| {
        if (!isExecutablePath(path)) return error.WebKitGtkBrowserBinaryNotFound;
        return .{
            .path = try allocator.dupe(u8, path),
            .source = .explicit,
        };
    }

    return switch (target) {
        .custom_binary => error.WebKitGtkBrowserBinaryNotFound,
        .minibrowser => .{
            .path = try discoverMiniBrowserPath(allocator) orelse return error.WebKitGtkMiniBrowserNotFound,
            .source = .explicit,
        },
        .auto => blk: {
            const path = try discoverMiniBrowserPath(allocator);
            if (path) |resolved| {
                break :blk .{
                    .path = resolved,
                    .source = .auto,
                };
            }
            break :blk .{};
        },
    };
}

fn discoverMiniBrowserPath(allocator: std.mem.Allocator) !?[]u8 {
    const known_paths = [_][]const u8{
        "/usr/lib/webkitgtk-6.0/MiniBrowser",
        "/usr/bin/MiniBrowser",
        "/usr/local/bin/MiniBrowser",
        "/usr/libexec/webkit2gtk-4.1/MiniBrowser",
        "/usr/libexec/webkit2gtk-4.0/MiniBrowser",
    };

    for (known_paths) |path| {
        if (!isExecutablePath(path)) continue;
        return @as(?[]u8, try allocator.dupe(u8, path));
    }

    const runtimes = discoverWebViews(allocator, .{
        .kinds = &.{.webkitgtk},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    }) catch return null;
    defer freeWebViewRuntimes(allocator, runtimes);

    for (runtimes) |runtime| {
        const path = runtime.runtime_path orelse continue;
        const base = std.fs.path.basename(path);
        if (!string_util.containsIgnoreCase(base, "minibrowser")) continue;
        if (!isExecutablePath(path)) continue;
        return @as(?[]u8, try allocator.dupe(u8, path));
    }

    return null;
}

fn createWebDriverSessionIdWithTimeout(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    body_json: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (true) {
        const response = http.postJson(allocator, host, port, "/session", body_json) catch |err| {
            if (isTransientConnectError(err) and std.time.milliTimestamp() < deadline) {
                std.Thread.sleep(webdriver_startup_sleep_ms * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        defer allocator.free(response.body);

        if (response.status_code < 200 or response.status_code >= 300) {
            return error.ProtocolCommandFailed;
        }

        const session_id = try extractWebDriverSessionIdAlloc(allocator, response.body);
        if (session_id) |id| return id;
        return error.InvalidResponse;
    }
}

fn isTransientConnectError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        => true,
        else => false,
    };
}

fn escapeJsonStringAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
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

fn extractWebDriverSessionIdAlloc(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    if (root.object.get("value")) |value| {
        if (value == .object) {
            if (value.object.get("sessionId")) |session_id| {
                if (session_id == .string) return @as(?[]u8, try allocator.dupe(u8, session_id.string));
            }
        }
    }

    if (root.object.get("sessionId")) |session_id| {
        if (session_id == .string) return @as(?[]u8, try allocator.dupe(u8, session_id.string));
    }

    return null;
}

fn webDriverStatusReady(allocator: std.mem.Allocator, payload: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return true;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return true;
    const value = root.object.get("value") orelse return true;
    if (value != .object) return true;
    const ready = value.object.get("ready") orelse return true;
    if (ready == .bool) return ready.bool;
    return true;
}

fn buildAndroidWebViewEndpoint(
    allocator: std.mem.Allocator,
    opts: types.AndroidWebViewAttachOptions,
) ![]u8 {
    if (opts.host.len == 0) return error.InvalidEndpoint;

    const path = if (opts.socket_name) |socket|
        try std.fmt.allocPrint(allocator, "/devtools/page/{s}", .{socket})
    else if (opts.pid) |pid|
        try std.fmt.allocPrint(allocator, "/devtools/page/{d}", .{pid})
    else
        try allocator.dupe(u8, "/");
    defer allocator.free(path);

    return std.fmt.allocPrint(allocator, "cdp://{s}:{d}{s}", .{ opts.host, opts.port, path });
}

fn discoverWebKitGtkDriverPath(allocator: std.mem.Allocator) ![]u8 {
    const runtimes = try discoverWebViews(allocator, .{
        .kinds = &.{.webkitgtk},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer freeWebViewRuntimes(allocator, runtimes);

    for (runtimes) |runtime| {
        const path = runtime.runtime_path orelse continue;
        const base = std.fs.path.basename(path);
        if (!string_util.containsIgnoreCase(base, "webkitwebdriver")) continue;
        if (!isExecutablePath(path)) continue;
        return allocator.dupe(u8, path);
    }

    return error.WebKitGtkWebDriverNotFound;
}

fn isExecutablePath(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

fn hasArgValue(args: []const []const u8, value: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, value)) return true;
    }
    return false;
}

fn appendDefaultArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    temp_owned_strings: *std.ArrayList([]u8),
    opts: types.LaunchOptions,
    adapter: common.AdapterKind,
    debug_port: ?u16,
) !void {
    if (opts.ignore_tls_errors) {
        switch (opts.install.engine) {
            .chromium => {
                try args.append(allocator, "--ignore-certificate-errors");
                try args.append(allocator, "--allow-insecure-localhost");
            },
            .gecko, .webkit, .unknown => {},
        }
    }

    if (opts.headless) {
        switch (opts.install.engine) {
            .chromium => try args.append(allocator, "--headless=new"),
            .gecko => try args.append(allocator, "-headless"),
            .webkit, .unknown => {},
        }
    }

    switch (opts.install.engine) {
        .chromium => if (opts.legacy_automation_markers) {
            try args.append(allocator, "--disable-blink-features=AutomationControlled");
            try args.append(allocator, "--disable-infobars");
        },
        else => {},
    }

    if (adapter == .cdp and opts.install.engine == .chromium) {
        const port = debug_port orelse 9222;
        const flag = try std.fmt.allocPrint(allocator, "--remote-debugging-port={d}", .{port});
        try temp_owned_strings.append(allocator, flag);
        try args.append(allocator, flag);
    }
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
        .webkit, .unknown => {},
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
    const leaf = try std.fmt.allocPrint(allocator, "browser-driver-ephemeral-{x}-{x}", .{ stamp, nonce });
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

    const prefs =
        \\user_pref("webdriver_accept_untrusted_certs", true);
        \\user_pref("webdriver_assume_untrusted_issuer", false);
        \\user_pref("security.cert_pinning.enforcement_level", 0);
        \\user_pref("network.stricttransportsecurity.preloadlist", false);
        \\user_pref("security.enterprise_roots.enabled", true);
        \\
    ;
    try file.writeAll(prefs);
}

fn writeGeckoStealthPrefs(allocator: std.mem.Allocator, profile_dir: []const u8) !void {
    const user_js_path = try std.fs.path.join(allocator, &.{ profile_dir, "user.js" });
    defer allocator.free(user_js_path);

    var file = try std.fs.cwd().createFile(user_js_path, .{ .truncate = false, .read = false });
    defer file.close();
    try file.seekFromEnd(0);

    const prefs =
        \\user_pref("dom.webdriver.enabled", false);
        \\user_pref("privacy.resistFingerprinting", true);
        \\
    ;
    try file.writeAll(prefs);
}

fn needsProfileEnvSandbox(engine: types.EngineKind) bool {
    return switch (engine) {
        .webkit, .unknown => true,
        .chromium, .gecko => false,
    };
}

fn applyProfileSandboxEnv(
    allocator: std.mem.Allocator,
    env_map: *std.process.EnvMap,
    os_tag: std.Target.Os.Tag,
    profile_root: []const u8,
) !void {
    switch (os_tag) {
        .windows => {
            const userprofile = try allocProfileSubdir(allocator, profile_root, "userprofile");
            defer allocator.free(userprofile);
            const appdata = try allocProfileSubdir(allocator, profile_root, "userprofile/AppData/Roaming");
            defer allocator.free(appdata);
            const localappdata = try allocProfileSubdir(allocator, profile_root, "userprofile/AppData/Local");
            defer allocator.free(localappdata);
            const temp = try allocProfileSubdir(allocator, profile_root, "tmp");
            defer allocator.free(temp);

            try env_map.put("USERPROFILE", userprofile);
            try env_map.put("APPDATA", appdata);
            try env_map.put("LOCALAPPDATA", localappdata);
            try env_map.put("TEMP", temp);
            try env_map.put("TMP", temp);
        },
        else => {
            const home = try allocProfileSubdir(allocator, profile_root, "home");
            defer allocator.free(home);
            const xdg_config = try allocProfileSubdir(allocator, profile_root, "xdg/config");
            defer allocator.free(xdg_config);
            const xdg_cache = try allocProfileSubdir(allocator, profile_root, "xdg/cache");
            defer allocator.free(xdg_cache);
            const xdg_data = try allocProfileSubdir(allocator, profile_root, "xdg/data");
            defer allocator.free(xdg_data);

            try env_map.put("HOME", home);
            try env_map.put("XDG_CONFIG_HOME", xdg_config);
            try env_map.put("XDG_CACHE_HOME", xdg_cache);
            try env_map.put("XDG_DATA_HOME", xdg_data);
        },
    }
}

fn allocProfileSubdir(allocator: std.mem.Allocator, profile_root: []const u8, suffix: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ profile_root, suffix });
    errdefer allocator.free(path);
    try ensureDirPathExists(path);
    return path;
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
        .webview2, .electron, .android_webview => .cdp,
        .wkwebview, .webkitgtk, .ios_wkwebview => .webdriver,
    };
}

fn browserKindForWebView(kind: types.WebViewKind) types.BrowserKind {
    return switch (kind) {
        .webview2 => .edge,
        .electron, .android_webview => .chrome,
        .wkwebview, .ios_wkwebview, .webkitgtk => .safari,
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

test "appendDefaultArgs adds chromium headless and cdp flags" {
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
        .profile_mode = .ephemeral,
        .profile_dir = null,
        .headless = true,
        .args = &.{},
    }, .cdp, 9333);

    try std.testing.expect(hasArg(args.items, "--headless=new"));
    try std.testing.expect(hasArg(args.items, "--remote-debugging-port=9333"));
}

test "appendDefaultArgs does not add chromium automation markers by default" {
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
        .profile_mode = .ephemeral,
        .profile_dir = null,
        .headless = false,
        .args = &.{},
    }, .cdp, 9333);

    try std.testing.expect(!hasArg(args.items, "--disable-blink-features=AutomationControlled"));
    try std.testing.expect(!hasArg(args.items, "--disable-infobars"));
}

test "appendDefaultArgs adds chromium automation markers when legacy mode enabled" {
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
        .profile_mode = .ephemeral,
        .profile_dir = null,
        .headless = false,
        .legacy_automation_markers = true,
        .args = &.{},
    }, .cdp, 9333);

    try std.testing.expect(hasArg(args.items, "--disable-blink-features=AutomationControlled"));
    try std.testing.expect(hasArg(args.items, "--disable-infobars"));
}

test "appendDefaultArgs adds chromium tls ignore flags when requested" {
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
        .profile_mode = .ephemeral,
        .profile_dir = null,
        .headless = false,
        .ignore_tls_errors = true,
        .args = &.{},
    }, .cdp, 9222);

    try std.testing.expect(hasArg(args.items, "--ignore-certificate-errors"));
    try std.testing.expect(hasArg(args.items, "--allow-insecure-localhost"));
}

test "writeGeckoInsecureTlsPrefs writes expected prefs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "gecko-insecure-profile" });
    defer allocator.free(profile_dir);
    try ensureDirPathExists(profile_dir);

    try writeGeckoInsecureTlsPrefs(allocator, profile_dir);

    const user_js_path = try std.fs.path.join(allocator, &.{ profile_dir, "user.js" });
    defer allocator.free(user_js_path);
    const data = try std.fs.cwd().readFileAlloc(allocator, user_js_path, 64 * 1024);
    defer allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "webdriver_accept_untrusted_certs") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "security.cert_pinning.enforcement_level") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "security.enterprise_roots.enabled") != null);
}

test "launch gecko does not write stealth prefs by default" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "gecko-stealth-disabled" });
    defer allocator.free(profile_dir);

    var session = try launch(allocator, .{
        .install = .{
            .kind = .firefox,
            .engine = .gecko,
            .path = "/bin/sh",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .profile_dir = profile_dir,
        .headless = false,
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    const user_js_path = try std.fs.path.join(allocator, &.{ profile_dir, "user.js" });
    defer allocator.free(user_js_path);
    try std.testing.expect(!pathExists(user_js_path));
}

test "launch gecko writes stealth prefs when enabled" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "gecko-stealth-enabled" });
    defer allocator.free(profile_dir);

    var session = try launch(allocator, .{
        .install = .{
            .kind = .firefox,
            .engine = .gecko,
            .path = "/bin/sh",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .profile_dir = profile_dir,
        .headless = false,
        .gecko_stealth_prefs = true,
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    const user_js_path = try std.fs.path.join(allocator, &.{ profile_dir, "user.js" });
    defer allocator.free(user_js_path);
    const data = try std.fs.cwd().readFileAlloc(allocator, user_js_path, 64 * 1024);
    defer allocator.free(data);

    try std.testing.expect(std.mem.indexOf(u8, data, "dom.webdriver.enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "privacy.resistFingerprinting") != null);
}

test "persistent chromium includes user data dir argument" {
    const allocator = std.testing.allocator;
    const profile_dir = try resolveEffectiveProfileDir(allocator, .persistent, "/tmp/browser-driver-persistent-chromium");
    defer allocator.free(profile_dir);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var temp_owned: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_owned.items) |item| allocator.free(item);
        temp_owned.deinit(allocator);
    }

    try appendProfileArgs(allocator, &args, &temp_owned, .chromium, profile_dir);

    const expected = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{profile_dir});
    defer allocator.free(expected);
    try std.testing.expect(hasArg(args.items, expected));
}

test "persistent gecko includes profile argument pair" {
    const allocator = std.testing.allocator;
    const profile_dir = try resolveEffectiveProfileDir(allocator, .persistent, "/tmp/browser-driver-persistent-gecko");
    defer allocator.free(profile_dir);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var temp_owned: std.ArrayList([]u8) = .empty;
    defer temp_owned.deinit(allocator);

    try appendProfileArgs(allocator, &args, &temp_owned, .gecko, profile_dir);

    try std.testing.expect(hasArgPair(args.items, "-profile", profile_dir));
}

test "persistent profile mode requires profile_dir" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.PersistentProfileDirRequired, launch(allocator, .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = "/definitely/not/a/browser",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .persistent,
        .profile_dir = null,
        .headless = true,
        .args = &.{},
    }));
}

test "electron launch with persistent profile mode requires profile_dir" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.PersistentProfileDirRequired, launchElectronWebView(allocator, .{
        .executable_path = "/definitely/not/electron",
        .profile_mode = .persistent,
        .profile_dir = null,
    }));
}

test "webkitgtk launch with persistent profile mode requires profile_dir" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.PersistentProfileDirRequired, launchWebKitGtkWebView(allocator, .{
        .driver_executable_path = "/definitely/not/webkitwebdriver",
        .profile_mode = .persistent,
        .profile_dir = null,
    }));
}

test "ephemeral chromium uses user data dir and not incognito" {
    const allocator = std.testing.allocator;
    const profile_dir = try resolveEffectiveProfileDir(allocator, .ephemeral, null);
    defer {
        std.fs.cwd().deleteTree(profile_dir) catch {};
        allocator.free(profile_dir);
    }

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var temp_owned: std.ArrayList([]u8) = .empty;
    defer {
        for (temp_owned.items) |item| allocator.free(item);
        temp_owned.deinit(allocator);
    }

    try appendProfileArgs(allocator, &args, &temp_owned, .chromium, profile_dir);

    try std.testing.expect(!hasArg(args.items, "--incognito"));
    const expected = try std.fmt.allocPrint(allocator, "--user-data-dir={s}", .{profile_dir});
    defer allocator.free(expected);
    try std.testing.expect(hasArg(args.items, expected));
}

test "ephemeral gecko uses profile argument and not private mode flag" {
    const allocator = std.testing.allocator;
    const profile_dir = try resolveEffectiveProfileDir(allocator, .ephemeral, null);
    defer {
        std.fs.cwd().deleteTree(profile_dir) catch {};
        allocator.free(profile_dir);
    }

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var temp_owned: std.ArrayList([]u8) = .empty;
    defer temp_owned.deinit(allocator);

    try appendProfileArgs(allocator, &args, &temp_owned, .gecko, profile_dir);

    try std.testing.expect(!hasArg(args.items, "-private"));
    try std.testing.expect(hasArgPair(args.items, "-profile", profile_dir));
}

test "profile env fallback populates expected keys under profile root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "sandbox-profile-root" });
    defer allocator.free(profile_root);
    try ensureDirPathExists(profile_root);

    var unix_env = std.process.EnvMap.init(allocator);
    defer unix_env.deinit();
    try applyProfileSandboxEnv(allocator, &unix_env, .linux, profile_root);

    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME" }) |key| {
        const value = unix_env.get(key) orelse return error.InvalidResponse;
        try std.testing.expect(std.mem.startsWith(u8, value, profile_root));
    }

    var windows_env = std.process.EnvMap.init(allocator);
    defer windows_env.deinit();
    try applyProfileSandboxEnv(allocator, &windows_env, .windows, profile_root);

    for ([_][]const u8{ "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP" }) |key| {
        const value = windows_env.get(key) orelse return error.InvalidResponse;
        try std.testing.expect(std.mem.startsWith(u8, value, profile_root));
    }
}

test "ephemeral profile directory is cleaned up on session deinit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "ephemeral-cleanup-profile" });
    defer allocator.free(profile_dir);

    var session = try launch(allocator, .{
        .install = .{
            .kind = .sigmaos,
            .engine = .unknown,
            .path = "/bin/sh",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .profile_dir = profile_dir,
        .headless = false,
        .args = &.{ "-c", "sleep 2" },
    });

    try std.testing.expect(pathExists(profile_dir));
    session.deinit();
    try std.testing.expect(!pathExists(profile_dir));
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

test "launch uses CDP transport for chromium engine without standalone webdriver" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try launch(allocator, .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = "/bin/sh",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .profile_dir = null,
        .headless = true,
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    try std.testing.expectEqual(common.TransportKind.cdp_ws, session.transport);
    try std.testing.expectEqual(common.AdapterKind.cdp, session.adapter_kind);
    try std.testing.expect(std.mem.startsWith(u8, session.endpoint.?, "cdp://"));
}

test "launch uses BiDi transport for gecko engine without standalone webdriver" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try launch(allocator, .{
        .install = .{
            .kind = .firefox,
            .engine = .gecko,
            .path = "/bin/sh",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .profile_dir = null,
        .headless = true,
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    try std.testing.expectEqual(common.TransportKind.bidi_ws, session.transport);
    try std.testing.expectEqual(common.AdapterKind.bidi, session.adapter_kind);
    try std.testing.expect(std.mem.startsWith(u8, session.endpoint.?, "bidi://"));
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

test "attachWebView maps Electron to chromium CDP session" {
    const allocator = std.testing.allocator;
    var session = try attachWebView(allocator, .{
        .kind = .electron,
        .endpoint = "cdp://127.0.0.1:9222/",
    });
    defer session.deinit();

    try std.testing.expectEqual(types.BrowserKind.chrome, session.install.kind);
    try std.testing.expectEqual(types.EngineKind.chromium, session.install.engine);
    try std.testing.expect(session.transport == .cdp_ws);
    try std.testing.expect(session.adapter_kind == .cdp);
}

test "attachWebView maps WebKitGTK to webdriver session" {
    const allocator = std.testing.allocator;
    var session = try attachWebView(allocator, .{
        .kind = .webkitgtk,
        .endpoint = "webdriver://127.0.0.1:4444/session/1",
    });
    defer session.deinit();

    try std.testing.expectEqual(types.BrowserKind.safari, session.install.kind);
    try std.testing.expectEqual(types.EngineKind.webkit, session.install.engine);
    try std.testing.expect(session.transport == .webdriver_http);
    try std.testing.expect(session.adapter_kind == .webdriver);
}

test "attachWebKitGtkWebView synthesizes webdriver endpoint from host/port/session" {
    const allocator = std.testing.allocator;
    var session = try attachWebKitGtkWebView(allocator, .{
        .host = "127.0.0.1",
        .port = 5555,
        .session_id = "abc-session",
    });
    defer session.deinit();

    try std.testing.expect(std.mem.eql(u8, session.endpoint.?, "webdriver://127.0.0.1:5555/session/abc-session"));
    try std.testing.expect(session.transport == .webdriver_http);
}

test "extractWebDriverSessionIdAlloc parses both W3C and legacy payloads" {
    const allocator = std.testing.allocator;

    const w3c_payload =
        \\{"value":{"sessionId":"w3c-id","capabilities":{"browserName":"webkitgtk"}}}
    ;
    const legacy_payload =
        \\{"sessionId":"legacy-id","status":0,"value":{}}
    ;

    const w3c = try extractWebDriverSessionIdAlloc(allocator, w3c_payload);
    defer if (w3c) |id| allocator.free(id);
    try std.testing.expect(w3c != null);
    try std.testing.expect(std.mem.eql(u8, w3c.?, "w3c-id"));

    const legacy = try extractWebDriverSessionIdAlloc(allocator, legacy_payload);
    defer if (legacy) |id| allocator.free(id);
    try std.testing.expect(legacy != null);
    try std.testing.expect(std.mem.eql(u8, legacy.?, "legacy-id"));
}

test "buildWebKitGtkSessionCapabilitiesJson includes webkitgtk browser options" {
    const allocator = std.testing.allocator;
    const body = try buildWebKitGtkSessionCapabilitiesJson(allocator, "/usr/lib/webkitgtk-6.0/MiniBrowser", &.{ "--foo", "--bar" }, false, false, false);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"webkitgtk:browserOptions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"binary\":\"/usr/lib/webkitgtk-6.0/MiniBrowser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"args\":[\"--foo\",\"--bar\"]") != null);
}

test "buildWebKitGtkSessionCapabilitiesJson injects automation arg when requested" {
    const allocator = std.testing.allocator;
    const body = try buildWebKitGtkSessionCapabilitiesJson(allocator, "/usr/lib/webkitgtk-6.0/MiniBrowser", &.{"--foo"}, true, false, false);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"args\":[\"--automation\",\"--foo\"]") != null);
}

test "buildWebKitGtkSessionCapabilitiesJson injects ignore tls and acceptInsecureCerts when requested" {
    const allocator = std.testing.allocator;
    const body = try buildWebKitGtkSessionCapabilitiesJson(allocator, "/usr/lib/webkitgtk-6.0/MiniBrowser", &.{"--foo"}, false, true, true);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"acceptInsecureCerts\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"args\":[\"--ignore-tls-errors\",\"--foo\"]") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "buildWebKitGtkSessionCreatePlan does not duplicate automation arg when already provided" {
    const allocator = std.testing.allocator;
    const resolved_path = try allocator.dupe(u8, "/usr/lib/webkitgtk-6.0/MiniBrowser");
    defer allocator.free(resolved_path);
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .browser_target = .minibrowser,
        .browser_args = &.{ "--automation", "--foo" },
    }, .{
        .path = resolved_path,
        .source = .explicit,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"args\":[\"--automation\",\"--foo\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"args\":[\"--automation\",\"--automation\"") == null);
}

test "buildWebKitGtkSessionCreatePlan injects automation arg for minibrowser target by default" {
    const allocator = std.testing.allocator;
    const resolved_path = try allocator.dupe(u8, "/usr/lib/webkitgtk-6.0/MiniBrowser");
    defer allocator.free(resolved_path);
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .browser_target = .minibrowser,
        .browser_args = &.{},
    }, .{
        .path = resolved_path,
        .source = .explicit,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"args\":[\"--automation\"]") != null);
}

test "buildWebKitGtkSessionCreatePlan bypasses typed capabilities when explicit json provided" {
    const allocator = std.testing.allocator;
    const custom_json = "{\"capabilities\":{\"alwaysMatch\":{\"acceptInsecureCerts\":true},\"firstMatch\":[{}]}}";
    const resolved_path = try allocator.dupe(u8, "/usr/lib/webkitgtk-6.0/MiniBrowser");
    defer allocator.free(resolved_path);
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .session_capabilities_json = custom_json,
        .browser_target = .auto,
        .browser_args = &.{"--ignored"},
    }, .{
        .path = resolved_path,
        .source = .auto,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.eql(u8, plan.primary_body, custom_json));
    try std.testing.expect(plan.fallback_body == null);
}

test "buildWebKitGtkSessionCreatePlan in auto mode prefers minibrowser automation body when detected" {
    const allocator = std.testing.allocator;
    const resolved_path = try allocator.dupe(u8, "/usr/lib/webkitgtk-6.0/MiniBrowser");
    defer allocator.free(resolved_path);
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .browser_target = .auto,
        .browser_args = &.{},
    }, .{
        .path = resolved_path,
        .source = .auto,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"webkitgtk:browserOptions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"binary\":\"/usr/lib/webkitgtk-6.0/MiniBrowser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"args\":[\"--automation\"]") != null);
    try std.testing.expect(plan.fallback_body != null);
    try std.testing.expect(std.mem.eql(u8, plan.fallback_body.?, default_webdriver_session_body));
}

test "buildWebKitGtkSessionCreatePlan in auto mode injects automation and ignore tls for minibrowser" {
    const allocator = std.testing.allocator;
    const resolved_path = try allocator.dupe(u8, "/usr/lib/webkitgtk-6.0/MiniBrowser");
    defer allocator.free(resolved_path);
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .browser_target = .auto,
        .ignore_tls_errors = true,
    }, .{
        .path = resolved_path,
        .source = .auto,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"acceptInsecureCerts\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"webkitgtk:browserOptions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"args\":[\"--automation\",\"--ignore-tls-errors\"]") != null);
    try std.testing.expect(plan.fallback_body != null);
    try std.testing.expect(std.mem.eql(u8, plan.fallback_body.?, default_webdriver_session_body_accept_insecure));
}

test "buildWebKitGtkSessionCreatePlan keeps default auto body when minibrowser is not detected" {
    const allocator = std.testing.allocator;
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .browser_target = .auto,
        .browser_args = &.{},
    }, .{
        .path = null,
        .source = .none,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.eql(u8, plan.primary_body, default_webdriver_session_body));
    try std.testing.expect(plan.fallback_body == null);
}

test "buildWebKitGtkSessionCreatePlan in auto mode preserves args and enables minibrowser automation" {
    const allocator = std.testing.allocator;
    const resolved_path = try allocator.dupe(u8, "/usr/lib/webkitgtk-6.0/MiniBrowser");
    defer allocator.free(resolved_path);
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .browser_target = .auto,
        .browser_args = &.{"--foo"},
    }, .{
        .path = resolved_path,
        .source = .auto,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"webkitgtk:browserOptions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"args\":[\"--automation\",\"--foo\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"binary\":\"/usr/lib/webkitgtk-6.0/MiniBrowser\"") != null);
    try std.testing.expect(plan.fallback_body != null);
    try std.testing.expect(std.mem.eql(u8, plan.fallback_body.?, default_webdriver_session_body));
}

test "buildWebKitGtkSessionCreatePlan for explicit custom binary does not include fallback" {
    const allocator = std.testing.allocator;
    const resolved_path = try allocator.dupe(u8, "/usr/lib/webkitgtk-6.0/MiniBrowser");
    defer allocator.free(resolved_path);
    const plan = try buildWebKitGtkSessionCreatePlan(allocator, .{
        .browser_target = .custom_binary,
        .browser_binary_path = "/usr/lib/webkitgtk-6.0/MiniBrowser",
        .browser_args = &.{},
    }, .{
        .path = resolved_path,
        .source = .explicit,
    });
    defer {
        allocator.free(plan.primary_body);
        if (plan.fallback_body) |body| allocator.free(body);
    }

    try std.testing.expect(std.mem.indexOf(u8, plan.primary_body, "\"webkitgtk:browserOptions\"") != null);
    try std.testing.expect(plan.fallback_body == null);
}

test "buildWebKitGtkDriverArgv includes port host and replace-on-new-session flag" {
    const allocator = std.testing.allocator;
    const argv = try buildWebKitGtkDriverArgv(allocator, .{
        .driver_executable_path = "/usr/bin/WebKitWebDriver",
        .host = "127.0.0.1",
        .port = 46741,
        .replace_on_new_session = true,
        .driver_args = &.{ "--foo", "--bar=baz" },
    }, "/usr/bin/WebKitWebDriver", 46741);
    defer {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    try std.testing.expect(std.mem.eql(u8, argv[0], "/usr/bin/WebKitWebDriver"));
    try std.testing.expect(hasArg(argv, "--port=46741"));
    try std.testing.expect(hasArg(argv, "--host=127.0.0.1"));
    try std.testing.expect(hasArg(argv, "--replace-on-new-session"));
    try std.testing.expect(hasArg(argv, "--foo"));
    try std.testing.expect(hasArg(argv, "--bar=baz"));
}

test "attachElectronWebView synthesizes cdp endpoint from host and port" {
    const allocator = std.testing.allocator;
    var session = try attachElectronWebView(allocator, .{
        .host = "127.0.0.1",
        .port = 9333,
    });
    defer session.deinit();

    try std.testing.expect(std.mem.eql(u8, session.endpoint.?, "cdp://127.0.0.1:9333/"));
    try std.testing.expect(session.transport == .cdp_ws);
}

test "launchElectronWebView includes debugging and profile args in owned argv" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "electron-profile" });
    defer allocator.free(profile_dir);

    var session = try launchElectronWebView(allocator, .{
        .executable_path = "/bin/sh",
        .app_path = "-c",
        .args = &.{"exit 0"},
        .debug_port = 9444,
        .profile_mode = .ephemeral,
        .profile_dir = profile_dir,
        .ignore_tls_errors = true,
    });
    defer session.deinit();

    const argv = session.owned_argv.?;
    try std.testing.expect(hasArg(argv, "--remote-debugging-port=9444"));
    try std.testing.expect(hasPrefixArg(argv, "--user-data-dir="));
    try std.testing.expect(hasArg(argv, "--ignore-certificate-errors"));
    try std.testing.expect(hasArg(argv, "--allow-insecure-localhost"));
    try std.testing.expect(!hasArg(argv, "--disable-blink-features=AutomationControlled"));
    try std.testing.expect(!hasArg(argv, "--disable-infobars"));
    try std.testing.expect(std.mem.eql(u8, session.endpoint.?, "cdp://127.0.0.1:9444/"));
    try std.testing.expect(session.transport == .cdp_ws);
}

test "launchElectronWebView includes automation markers when legacy mode enabled" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile_dir = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "electron-profile-legacy" });
    defer allocator.free(profile_dir);

    var session = try launchElectronWebView(allocator, .{
        .executable_path = "/bin/sh",
        .app_path = "-c",
        .args = &.{"exit 0"},
        .debug_port = 9444,
        .profile_mode = .ephemeral,
        .profile_dir = profile_dir,
        .legacy_automation_markers = true,
    });
    defer session.deinit();

    const argv = session.owned_argv.?;
    try std.testing.expect(hasArg(argv, "--disable-blink-features=AutomationControlled"));
    try std.testing.expect(hasArg(argv, "--disable-infobars"));
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

test "launchWebViewHost omits chromium automation markers by default" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try launchWebViewHost(allocator, .{
        .kind = .webview2,
        .host_executable = "/bin/sh",
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    const argv = session.owned_argv.?;
    try std.testing.expect(!hasArg(argv, "--disable-blink-features=AutomationControlled"));
    try std.testing.expect(!hasArg(argv, "--disable-infobars"));
}

test "launchWebViewHost includes chromium automation markers when legacy mode enabled" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try launchWebViewHost(allocator, .{
        .kind = .webview2,
        .host_executable = "/bin/sh",
        .legacy_automation_markers = true,
        .args = &.{ "-c", "exit 0" },
    });
    defer session.deinit();

    const argv = session.owned_argv.?;
    try std.testing.expect(hasArg(argv, "--disable-blink-features=AutomationControlled"));
    try std.testing.expect(hasArg(argv, "--disable-infobars"));
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

test "attachAndroidWebView supports shizuku bridge endpoint synthesis" {
    const allocator = std.testing.allocator;
    var session = try attachAndroidWebView(allocator, .{
        .device_id = "emulator-5554",
        .bridge_kind = .shizuku,
        .host = "127.0.0.1",
        .port = 9322,
        .socket_name = "chrome_devtools_remote",
    });
    defer session.deinit();

    try std.testing.expect(std.mem.eql(u8, session.endpoint.?, "cdp://127.0.0.1:9322/devtools/page/chrome_devtools_remote"));
    try std.testing.expect(session.transport == .cdp_ws);
}

test "attachAndroidWebView allows root CDP endpoint without pid or socket" {
    const allocator = std.testing.allocator;
    var session = try attachAndroidWebView(allocator, .{
        .device_id = "emulator-5554",
        .bridge_kind = .direct,
        .host = "127.0.0.1",
        .port = 9222,
    });
    defer session.deinit();

    try std.testing.expect(std.mem.eql(u8, session.endpoint.?, "cdp://127.0.0.1:9222/"));
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

fn hasArgPair(args: []const []const u8, key: []const u8, value: []const u8) bool {
    if (args.len < 2) return false;
    for (args[0 .. args.len - 1], 0..) |arg, i| {
        if (std.mem.eql(u8, arg, key) and std.mem.eql(u8, args[i + 1], value)) return true;
    }
    return false;
}

fn hasPrefixArg(args: []const []const u8, expected_prefix: []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, expected_prefix)) return true;
    }
    return false;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
