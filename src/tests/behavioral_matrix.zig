const std = @import("std");
const builtin = @import("builtin");
const driver = @import("../root.zig");
const helpers = @import("helpers.zig");
const strings = @import("../util/strings.zig");

const example_url = "data:text/html,<html><head><title>gate</title></head><body>gate</body></html>";
const flatmates_url = "https://flatmates.com.au/share-house-melbourne-oakleigh-east-3166-P1436583";
const flatmates_cookie_hook_init_script =
    \\(function() {
    \\    if (window.__kp_cookie_hook_installed) return;
    \\    window.__kp_cookie_hook_installed = true;
    \\    window.__kp_cookie_intercepts = window.__kp_cookie_intercepts || [];
    \\    window.__setCookieWithIntercept = function(value) {
    \\        window.__kp_cookie_intercepts.push(String(value));
    \\        document.cookie = value;
    \\    };
    \\
    \\    const descriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
    \\    if (!descriptor || typeof descriptor.set !== 'function') {
    \\        return;
    \\    }
    \\
    \\    const originalCookieSetter = descriptor.set;
    \\    try {
    \\        Object.defineProperty(document, 'cookie', {
    \\            configurable: true,
    \\            enumerable: false,
    \\            set: function(value) {
    \\                window.__kp_cookie_intercepts.push(String(value));
    \\                originalCookieSetter.call(document, value);
    \\            },
    \\            get: function() {
    \\                return descriptor.get ? descriptor.get.call(document) : '';
    \\            }
    \\        });
    \\        window.__setCookieWithIntercept = function(value) {
    \\            document.cookie = value;
    \\        };
    \\    } catch (_) {}
    \\
    \\    try {
    \\        Object.defineProperty(navigator, 'webdriver', { configurable: true, get: function() { return undefined; } });
    \\    } catch (_) {}
    \\    try {
    \\        Object.defineProperty(navigator, 'languages', { configurable: true, get: function() { return ['en-US', 'en']; } });
    \\    } catch (_) {}
    \\    try {
    \\        Object.defineProperty(navigator, 'platform', { configurable: true, get: function() { return 'Linux x86_64'; } });
    \\    } catch (_) {}
    \\    try {
    \\        if (!window.chrome) window.chrome = {};
    \\        if (!window.chrome.runtime) window.chrome.runtime = {};
    \\    } catch (_) {}
    \\})();
;
const flatmates_preferred_kinds = [_]driver.BrowserKind{
    .chrome,
    .edge,
    .brave,
    .vivaldi,
    .operagx,
    .lightpanda,
    .firefox,
};
const brave_flatmates_headless_args_bare = &.{};
const brave_flatmates_headless_args_window = &.{
    "--window-size=1366,900",
};
const brave_flatmates_headless_args = &.{
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--window-size=1366,900",
    "--disable-blink-features=AutomationControlled",
    "--disable-background-networking",
    "--disable-features=Translate,MediaRouter,DialMediaRouteProvider",
};
const brave_flatmates_headless_args_lean = &.{
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--window-size=1366,900",
};
const brave_flatmates_headless_args_swiftshader = &.{
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--window-size=1366,900",
    "--use-angle=swiftshader",
    "--use-gl=swiftshader",
    "--disable-software-rasterizer",
};
const brave_flatmates_headless_args_network = &.{
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--window-size=1366,900",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--disable-background-networking",
    "--disable-features=Translate,MediaRouter,DialMediaRouteProvider,OptimizationGuideModelDownloading,OptimizationHints",
    "--disable-blink-features=AutomationControlled",
};
const brave_flatmates_headless_args_profile_safe = &.{
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--window-size=1366,900",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--metrics-recording-only",
    "--password-store=basic",
    "--use-mock-keychain",
    "--disable-breakpad",
    "--disable-application-cache",
    "--lang=en-US,en",
    "--window-position=0,0",
    "--disable-blink-features=AutomationControlled",
    "--disk-cache-size=1",
    "--media-cache-size=1",
    "--disable-features=OptimizationGuideModelDownloading,OptimizationHints,AutofillServerCommunication,MediaRouter,DialMediaRouteProvider,CompressionDictionaryTransport",
    "--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
};
const brave_flatmates_headless_presets = [_]struct { name: []const u8, args: []const []const u8 }{
    .{ .name = "profile-safe", .args = brave_flatmates_headless_args_profile_safe },
    .{ .name = "bare", .args = brave_flatmates_headless_args_bare },
    .{ .name = "window", .args = brave_flatmates_headless_args_window },
    .{ .name = "baseline", .args = brave_flatmates_headless_args_lean },
    .{ .name = "stability", .args = brave_flatmates_headless_args },
    .{ .name = "swiftshader", .args = brave_flatmates_headless_args_swiftshader },
    .{ .name = "network-hardened", .args = brave_flatmates_headless_args_network },
};
const lightpanda_cookie_probe_html =
    "<!doctype html><html><head><title>lightpanda-cdp-ok</title></head><body><button id='btn' onclick='window.__clicked=(window.__clicked||0)+1'>Click</button><input id='name'/><script>window.__clicked=0;document.cookie='lp_js_cookie=js_cookie_value; path=/';localStorage.setItem('seed_local','ready');sessionStorage.setItem('seed_session','ready');</script></body></html>";
const data_page_one = "data:text/html,<html><head><title>lp-page-one</title></head><body><button id='btn'>one</button><input id='name' value=''/></body></html>";
const data_page_two = "data:text/html,<html><head><title>lp-page-two</title></head><body><button id='btn'>two</button><input id='name' value=''/></body></html>";

var endpoint_event_lock: std.Thread.Mutex = .{};
var endpoint_nav_started_count: usize = 0;
var endpoint_nav_completed_count: usize = 0;
var endpoint_nav_failed_count: usize = 0;
var endpoint_wait_satisfied_count: usize = 0;
var endpoint_wait_failed_count: usize = 0;
var endpoint_action_started_count: usize = 0;
var endpoint_action_completed_count: usize = 0;
var endpoint_action_failed_count: usize = 0;
var endpoint_reload_failed_count: usize = 0;
var endpoint_cookie_updated_count: usize = 0;

fn resetEndpointEventCounters() void {
    endpoint_event_lock.lock();
    defer endpoint_event_lock.unlock();
    endpoint_nav_started_count = 0;
    endpoint_nav_completed_count = 0;
    endpoint_nav_failed_count = 0;
    endpoint_wait_satisfied_count = 0;
    endpoint_wait_failed_count = 0;
    endpoint_action_started_count = 0;
    endpoint_action_completed_count = 0;
    endpoint_action_failed_count = 0;
    endpoint_reload_failed_count = 0;
    endpoint_cookie_updated_count = 0;
}

fn snapshotEndpointEventCounters() struct {
    nav_started: usize,
    nav_completed: usize,
    nav_failed: usize,
    wait_satisfied: usize,
    wait_failed: usize,
    action_started: usize,
    action_completed: usize,
    action_failed: usize,
    reload_failed: usize,
    cookie_updated: usize,
} {
    endpoint_event_lock.lock();
    defer endpoint_event_lock.unlock();
    return .{
        .nav_started = endpoint_nav_started_count,
        .nav_completed = endpoint_nav_completed_count,
        .nav_failed = endpoint_nav_failed_count,
        .wait_satisfied = endpoint_wait_satisfied_count,
        .wait_failed = endpoint_wait_failed_count,
        .action_started = endpoint_action_started_count,
        .action_completed = endpoint_action_completed_count,
        .action_failed = endpoint_action_failed_count,
        .reload_failed = endpoint_reload_failed_count,
        .cookie_updated = endpoint_cookie_updated_count,
    };
}

fn endpointLifecycleCallback(event: driver.LifecycleEvent) void {
    endpoint_event_lock.lock();
    defer endpoint_event_lock.unlock();
    switch (event) {
        .navigation_started => endpoint_nav_started_count += 1,
        .navigation_completed => endpoint_nav_completed_count += 1,
        .navigation_failed => endpoint_nav_failed_count += 1,
        .wait_satisfied => endpoint_wait_satisfied_count += 1,
        .wait_failed => endpoint_wait_failed_count += 1,
        .action_started => endpoint_action_started_count += 1,
        .action_completed => endpoint_action_completed_count += 1,
        .action_failed => endpoint_action_failed_count += 1,
        .reload_failed => endpoint_reload_failed_count += 1,
        .cookie_updated => endpoint_cookie_updated_count += 1,
        else => {},
    }
}

fn endpointRequestCallback(_: driver.RequestEvent) void {}
fn endpointResponseCallback(_: driver.ResponseEvent) void {}
fn endpointLogCallback(_: @import("../modern/log.zig").LogEntry) void {}

fn pickPageLikeTargetId(targets: anytype) ?[]const u8 {
    for (targets) |target| {
        if (std.ascii.eqlIgnoreCase(target.kind, "page") or std.ascii.eqlIgnoreCase(target.kind, "tab")) {
            return target.id;
        }
    }
    if (targets.len == 0) return null;
    return targets[0].id;
}

fn fetchAndAssert(session: anytype, allocator: std.mem.Allocator) !void {
    const base = &session.base;
    try base.navigate(example_url);
    _ = try base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });
    const payload = try base.evaluate("document.title + '|' + location.href");
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "gate") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "data:text/html") != null);
}

fn behavioralKinds() []const driver.BrowserKind {
    return &[_]driver.BrowserKind{
        .chrome, .edge, .firefox, .brave,    .tor,   .duckduckgo, .mullvad,    .librewolf,
        .epic,   .arc,  .vivaldi, .sidekick, .shift, .operagx,    .lightpanda, .palemoon,
    };
}

const OneShotCookieServer = struct {
    server: std.net.Server,
    body: []const u8,
    failed: bool = false,
    handled: bool = false,

    fn port(self: *const OneShotCookieServer) u16 {
        const real = self.server.listen_address.in.sa;
        return std.mem.bigToNative(u16, real.port);
    }
};

fn runOneShotCookieServer(ctx: *OneShotCookieServer) void {
    defer ctx.server.deinit();

    const conn = ctx.server.accept() catch {
        ctx.failed = true;
        return;
    };
    defer conn.stream.close();

    var req_buf: [4096]u8 = undefined;
    const req_n = conn.stream.read(&req_buf) catch {
        ctx.failed = true;
        return;
    };
    if (req_n == 0) return;
    ctx.handled = true;

    var head_buf: [512]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nSet-Cookie: lp_server_cookie=server_cookie_value; Path=/\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ctx.body.len},
    ) catch {
        ctx.failed = true;
        return;
    };

    conn.stream.writeAll(head) catch {
        ctx.failed = true;
        return;
    };
    conn.stream.writeAll(ctx.body) catch {
        ctx.failed = true;
    };
}

fn findCookieValue(cookies: []const driver.Cookie, name: []const u8) ?[]const u8 {
    for (cookies) |cookie| {
        if (std.mem.eql(u8, cookie.name, name)) return cookie.value;
    }
    return null;
}

test "behavioral browser smoke matrix modern-only (opt-in)" {
    if (!helpers.envEnabled("ALLDRIVER_BEHAVIORAL")) return error.SkipZigTest;

    const strict = helpers.envEnabled("ALLDRIVER_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;
    var discovered_any = false;
    var fetched_any = false;

    for (behavioralKinds()) |kind| {
        var installs = try driver.discover(allocator, .{
            .kinds = &.{kind},
            .allow_managed_download = false,
        }, .{
            .include_path_env = true,
            .include_os_probes = true,
            .include_known_paths = true,
        });
        defer installs.deinit();

        if (installs.items.len == 0) continue;
        if (driver.support_tier.browserTier(kind) != .modern) continue;
        discovered_any = true;

        var session = driver.modern.launch(allocator, .{
            .install = installs.items[0],
            .profile_mode = .ephemeral,
            .headless = true,
            .ignore_tls_errors = true,
            .args = &.{},
        }) catch |err| {
            if (strict) return err;
            continue;
        };
        defer session.deinit();

        fetchAndAssert(&session, allocator) catch |err| {
            if (strict) return err;
            continue;
        };
        fetched_any = true;
    }

    if (!discovered_any) return error.NoBehavioralRuns;
    if (!fetched_any) return error.NoSuccessfulExampleFetch;
}

test "behavioral webview discovery smoke modern-only (opt-in)" {
    if (!helpers.envEnabled("WEBVIEW_BRIDGE_BEHAVIORAL")) return error.SkipZigTest;

    const strict = helpers.envEnabled("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;
    var runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{ .webview2, .electron, .android_webview },
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = true,
    });
    defer runtimes.deinit();

    if (!strict) return;
    if (runtimes.items.len == 0) return error.NoWebViewRuntimeFound;
}

test "behavioral electron webview smoke modern-only (opt-in)" {
    if (!helpers.envEnabled("ELECTRON_BEHAVIORAL")) return error.SkipZigTest;

    const strict = helpers.envEnabled("ELECTRON_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;
    var runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{.electron},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer runtimes.deinit();

    if (runtimes.items.len == 0) {
        if (strict) return error.NoElectronRuntimeFound;
        return;
    }

    const executable = runtimes.items[0].runtime_path orelse {
        if (strict) return error.ElectronRuntimePathMissing;
        return;
    };

    var session = driver.modern.launchElectronWebView(allocator, .{
        .executable_path = executable,
        .profile_mode = .ephemeral,
        .headless = true,
        .ignore_tls_errors = true,
    }) catch |err| {
        if (strict) return err;
        return;
    };
    defer session.deinit();
    try fetchAndAssert(&session, allocator);
}

test "lightpanda cdp navigation and cookie extraction (opt-in)" {
    if (!helpers.envEnabled("LIGHTPANDA_BEHAVIORAL")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var installs = try driver.discover(allocator, .{
        .kinds = &.{.lightpanda},
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();
    if (installs.items.len == 0) return error.NoLightpandaFound;

    var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(.{});
    var server_ctx = OneShotCookieServer{
        .server = server,
        .body = lightpanda_cookie_probe_html,
    };
    const thread = try std.Thread.spawn(.{}, runOneShotCookieServer, .{&server_ctx});
    var joined = false;
    defer if (!joined) {
        if (std.net.Address.parseIp4("127.0.0.1", server_ctx.port())) |wake_addr| {
            if (std.net.tcpConnectToAddress(wake_addr)) |stream| stream.close() else |_| {}
        } else |_| {}
        thread.join();
    };

    const launch_args: []const []const u8 = &.{};
    var launched: ?driver.modern.ModernSession = null;
    var launch_failure: ?anyerror = null;
    for (installs.items) |install| {
        if (install.kind != .lightpanda) continue;
        const session = driver.modern.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
            .ignore_tls_errors = true,
            .include_lightpanda_browser = false,
            .timeout_policy = .{ .launch_ms = 120_000 },
            .args = launch_args,
        }) catch |err| {
            launch_failure = err;
            continue;
        };
        launched = session;
        break;
    }
    var session = launched orelse return launch_failure orelse error.NoLaunchableLightpanda;
    defer session.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server_ctx.port()});
    defer allocator.free(url);

    var page = session.page();
    try page.navigate(url);
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });
    _ = try session.base.waitFor(.{ .cookie_present = .{
        .name = "lp_server_cookie",
        .domain = "127.0.0.1",
        .include_http_only = true,
    } }, .{ .timeout_ms = 10_000 });

    var runtime_client = session.runtime();
    const title_payload = try runtime_client.evaluate("document.title");
    defer allocator.free(title_payload);
    try std.testing.expect(std.mem.indexOf(u8, title_payload, "lightpanda-cdp-ok") != null);

    var storage = session.storage();
    const cookies = try storage.getCookies(allocator);
    defer storage.freeCookies(allocator, cookies);

    const server_cookie = findCookieValue(cookies, "lp_server_cookie") orelse return error.CookieMissing;
    try std.testing.expectEqualStrings("server_cookie_value", server_cookie);

    const js_cookie = findCookieValue(cookies, "lp_js_cookie") orelse return error.CookieMissing;
    try std.testing.expectEqualStrings("js_cookie_value", js_cookie);

    thread.join();
    joined = true;
    try std.testing.expect(server_ctx.handled);
    try std.testing.expect(!server_ctx.failed);
}

test "lightpanda all modern endpoints conformance (opt-in)" {
    if (!helpers.envEnabled("LIGHTPANDA_ALL_ENDPOINTS")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var installs = try driver.discover(allocator, .{
        .kinds = &.{.lightpanda},
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();
    if (installs.items.len == 0) return error.NoLightpandaFound;

    var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(.{});
    var server_ctx = OneShotCookieServer{
        .server = server,
        .body = lightpanda_cookie_probe_html,
    };
    const thread = try std.Thread.spawn(.{}, runOneShotCookieServer, .{&server_ctx});
    var joined = false;
    defer if (!joined) {
        if (std.net.Address.parseIp4("127.0.0.1", server_ctx.port())) |wake_addr| {
            if (std.net.tcpConnectToAddress(wake_addr)) |stream| stream.close() else |_| {}
        } else |_| {}
        thread.join();
    };

    const launch_args: []const []const u8 = &.{};
    var launched: ?driver.modern.ModernSession = null;
    var launch_failure: ?anyerror = null;
    for (installs.items) |install| {
        if (install.kind != .lightpanda) continue;
        const session = driver.modern.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
            .ignore_tls_errors = true,
            .include_lightpanda_browser = false,
            .timeout_policy = .{ .launch_ms = 120_000 },
            .args = launch_args,
        }) catch |err| {
            launch_failure = err;
            continue;
        };
        launched = session;
        break;
    }
    var session = launched orelse return launch_failure orelse error.NoLaunchableLightpanda;
    defer session.deinit();

    const server_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server_ctx.port()});
    defer allocator.free(server_url);

    resetEndpointEventCounters();
    const subscription_id = try session.onEvent(.{
        .kinds = &.{
            .navigation_started,
            .navigation_completed,
            .navigation_failed,
            .wait_satisfied,
            .wait_failed,
            .action_started,
            .action_completed,
            .action_failed,
            .reload_failed,
            .cookie_updated,
        },
    }, endpointLifecycleCallback);
    defer {
        _ = session.offEvent(subscription_id);
    }

    var page = session.page();
    try page.navigate(server_url);
    _ = try session.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 20_000 });
    _ = try session.waitFor(.{ .selector_visible = "#btn" }, .{ .timeout_ms = 10_000 });
    _ = try session.waitFor(.{ .url_contains = "127.0.0.1" }, .{ .timeout_ms = 10_000 });
    _ = try session.waitFor(.{ .network_idle = {} }, .{ .timeout_ms = 10_000 });
    _ = try session.waitFor(.{ .js_truthy = "window.__clicked === 0" }, .{ .timeout_ms = 10_000 });

    var input = session.input();
    try input.click("#btn");
    try input.typeText("#name", "abc");
    try input.keyDown("Enter");
    try input.keyUp("Enter");
    try input.mouseMove(20, 20);
    try input.wheel(0, 120);

    var runtime_client = session.runtime();
    const clicked_payload = try runtime_client.evaluate("window.__clicked");
    defer allocator.free(clicked_payload);
    try std.testing.expect(std.mem.indexOf(u8, clicked_payload, "1") != null);

    const function_payload = try runtime_client.callFunction("(function(a,b){return a+b;})", "[2,3]");
    defer allocator.free(function_payload);
    try std.testing.expect(std.mem.indexOf(u8, function_payload, "5") != null);
    try std.testing.expectError(error.ProtocolCommandFailed, runtime_client.releaseHandle("nonexistent-handle"));

    var storage = session.storage();
    try storage.setCookie(.{
        .name = "lp_api_cookie",
        .value = "api_cookie_value",
        .domain = "127.0.0.1",
        .path = "/",
    });
    _ = try session.waitFor(.{ .cookie_present = .{
        .name = "lp_api_cookie",
        .domain = "127.0.0.1",
        .include_http_only = true,
    } }, .{ .timeout_ms = 10_000 });

    const cookies = try storage.getCookies(allocator);
    defer storage.freeCookies(allocator, cookies);
    try std.testing.expect(findCookieValue(cookies, "lp_server_cookie") != null);
    try std.testing.expect(findCookieValue(cookies, "lp_js_cookie") != null);
    try std.testing.expect(findCookieValue(cookies, "lp_api_cookie") != null);

    const filtered = try storage.queryCookies(allocator, .{
        .name = "lp_api_cookie",
        .domain = "127.0.0.1",
    });
    defer storage.freeCookies(allocator, filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);

    const cookie_header = try storage.buildCookieHeaderForUrl(
        allocator,
        server_url,
        .{},
    );
    defer allocator.free(cookie_header);
    try std.testing.expect(std.mem.indexOf(u8, cookie_header, "lp_api_cookie") != null);

    try storage.setLocalStorage("endpoint_local", "local_v");
    const local_value = try storage.getLocalStorage("endpoint_local");
    defer allocator.free(local_value);
    try std.testing.expect(std.mem.indexOf(u8, local_value, "local_v") != null);
    _ = try session.waitFor(.{ .storage_key_present = .{
        .key = "endpoint_local",
        .area = .local,
    } }, .{ .timeout_ms = 10_000 });

    try storage.setSessionStorage("endpoint_session", "session_v");
    const session_value = try storage.getSessionStorage("endpoint_session");
    defer allocator.free(session_value);
    try std.testing.expect(std.mem.indexOf(u8, session_value, "session_v") != null);

    try storage.clear();
    const local_after_clear = try storage.getLocalStorage("endpoint_local");
    defer allocator.free(local_after_clear);
    try std.testing.expect(local_after_clear.len == 0 or std.mem.indexOf(u8, local_after_clear, "\"\"") != null);

    const screenshot = try page.screenshot(allocator, .png);
    defer allocator.free(screenshot);
    try std.testing.expect(screenshot.len > 0);

    try page.navigate(data_page_one);
    try page.navigate(data_page_two);
    try page.goBack();
    try page.goForward();
    try page.reload();
    try page.setViewport(1024, 768);
    const viewport_payload = try runtime_client.evaluate("JSON.stringify(window.__alldriver_viewport)");
    defer allocator.free(viewport_payload);
    try std.testing.expect(std.mem.indexOf(u8, viewport_payload, "1024") != null);

    var network_client = session.network();
    network_client.onRequest(endpointRequestCallback);
    network_client.onResponse(endpointResponseCallback);
    try network_client.enable();
    try network_client.addRule(.{
        .id = "rule-block-data",
        .url_pattern = "*://example.invalid/*",
        .action = .{ .block = {} },
    });
    try std.testing.expect(try network_client.removeRule("rule-block-data"));
    try network_client.disable();

    var contexts = session.contexts();
    const existing_contexts = try contexts.list(allocator);
    defer contexts.freeList(allocator, existing_contexts);
    try std.testing.expect(existing_contexts.len > 0);

    const created_context = try contexts.create(allocator);
    defer allocator.free(created_context.id);
    try std.testing.expect(created_context.id.len > 0);
    try contexts.close(created_context.id);

    var targets = session.targets();
    const target_list = try targets.list(allocator);
    defer targets.freeList(allocator, target_list);
    try std.testing.expect(target_list.len > 0);
    const attach_target = pickPageLikeTargetId(target_list) orelse return error.MissingTarget;
    try targets.attach(attach_target);
    try targets.detach(attach_target);

    var log_client = session.log();
    try std.testing.expectError(error.UnsupportedProtocol, log_client.onConsole(endpointLogCallback));
    try std.testing.expectError(error.UnsupportedProtocol, log_client.onException(endpointLogCallback));

    var nav_async = try session.navigateAsync(data_page_one);
    defer nav_async.deinit();
    try nav_async.await(20_000);

    var click_async = try session.clickAsync("body");
    defer click_async.deinit();
    try click_async.await(10_000);

    var type_async = try session.typeTextAsync("#name", "typed_async");
    defer type_async.deinit();
    try type_async.await(10_000);

    var eval_async = try session.evaluateAsync("1+1");
    defer eval_async.deinit();
    const eval_async_payload = try eval_async.await(10_000);
    defer allocator.free(eval_async_payload);
    try std.testing.expect(std.mem.indexOf(u8, eval_async_payload, "2") != null);

    var wait_async = try session.waitForAsync(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });
    defer wait_async.deinit();
    const wait_result = try wait_async.await(10_000);
    try std.testing.expect(wait_result.matched);

    var screenshot_async = try session.screenshotAsync(.png);
    defer screenshot_async.deinit();
    const screenshot_async_payload = try screenshot_async.await(20_000);
    defer allocator.free(screenshot_async_payload);
    try std.testing.expect(screenshot_async_payload.len > 0);

    var trace_start_async = try session.startTracingAsync();
    defer trace_start_async.deinit();
    try trace_start_async.await(20_000);

    var trace_stop_async = try session.stopTracingAsync();
    defer trace_stop_async.deinit();
    const trace_payload = try trace_stop_async.await(20_000);
    defer allocator.free(trace_payload);
    try std.testing.expect(trace_payload.len > 0);

    const counters = snapshotEndpointEventCounters();
    try std.testing.expect(counters.nav_started > 0);
    try std.testing.expect(counters.nav_completed > 0);
    try std.testing.expect(counters.cookie_updated > 0);
    try std.testing.expect(counters.nav_started >= counters.nav_completed);
    try std.testing.expect(counters.nav_started >= 3);
    try std.testing.expect(counters.nav_completed >= 3);
    try std.testing.expectEqual(@as(usize, 0), counters.nav_failed);
    try std.testing.expect(counters.wait_satisfied > 0);
    try std.testing.expectEqual(@as(usize, 0), counters.wait_failed);
    try std.testing.expect(counters.action_started > 0);
    try std.testing.expect(counters.action_completed > 0);
    try std.testing.expect(counters.action_started >= counters.action_completed);
    try std.testing.expectEqual(@as(usize, 0), counters.action_failed);
    try std.testing.expectEqual(@as(usize, 0), counters.reload_failed);

    const counters_before_unsubscribe = counters;

    try std.testing.expect(session.offEvent(subscription_id));
    try page.navigate(data_page_one);
    const counters_after_unsubscribe = snapshotEndpointEventCounters();
    try std.testing.expectEqual(counters_before_unsubscribe.nav_started, counters_after_unsubscribe.nav_started);
    try std.testing.expectEqual(counters_before_unsubscribe.nav_completed, counters_after_unsubscribe.nav_completed);
    try std.testing.expectEqual(counters_before_unsubscribe.cookie_updated, counters_after_unsubscribe.cookie_updated);

    thread.join();
    joined = true;
    try std.testing.expect(server_ctx.handled);
    try std.testing.expect(!server_ctx.failed);
}

test "adversarial flatmates load beyond 429 facade and captures KP_REF cookie (opt-in)" {
    if (!helpers.envEnabled("ALLDRIVER_ADVERSARIAL_FLATMATES")) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var installs = try driver.discover(allocator, .{
        .kinds = &flatmates_preferred_kinds,
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    const timeout_ms: u32 = 180_000;
    const headless = !helpers.envEnabled("ALLDRIVER_ADVERSARIAL_HEADFUL");
    var any_attempted = false;
    var last_error: ?anyerror = null;
    for (flatmates_preferred_kinds) |kind| {
        for (installs.items) |install| {
            if (install.kind != kind) continue;
            if (driver.support_tier.browserTier(install.kind) != .modern) continue;
            any_attempted = true;

            const launch_args = flatmatesLaunchArgs(install);
            var session = driver.modern.launch(allocator, .{
                .install = install,
                .profile_mode = .ephemeral,
                .headless = headless,
                .ignore_tls_errors = true,
                .timeout_policy = .{ .launch_ms = 60_000 },
                .args = launch_args,
            }) catch |err| {
                last_error = err;
                continue;
            };
            defer session.deinit();

            runFlatmates429AndKpRefScenario(&session, allocator, timeout_ms, .{ .require_session_cookies = true }) catch |err| {
                last_error = err;
                continue;
            };
            return;
        }
    }

    if (!any_attempted) return error.NoLaunchableBrowser;
    return last_error orelse error.NoSuccessfulFlatmatesRun;
}

test "adversarial flatmates load beyond 429 facade and captures KP_REF cookie on lightpanda (opt-in)" {
    if (!helpers.envEnabled("ALLDRIVER_ADVERSARIAL_FLATMATES")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var installs = try driver.discover(allocator, .{
        .kinds = &.{.lightpanda},
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoLightpandaFound;

    const timeout_ms: u32 = 180_000;
    const headless = !helpers.envEnabled("ALLDRIVER_ADVERSARIAL_HEADFUL");
    var session = try driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = headless,
        .ignore_tls_errors = true,
        .include_lightpanda_browser = false,
        .timeout_policy = .{ .launch_ms = 120_000 },
        .args = &.{},
    });
    defer session.deinit();

    try runFlatmates429AndKpRefScenario(&session, allocator, timeout_ms, .{ .require_session_cookies = true });
}

test "adversarial flatmates load beyond 429 facade and captures KP_REF cookie on brave headless (opt-in)" {
    if (!helpers.envEnabled("ALLDRIVER_ADVERSARIAL_FLATMATES")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var installs = try driver.discover(allocator, .{
        .kinds = &.{.brave},
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBraveFound;

    const timeout_ms = flatmatesTimeoutMs();
    const preset_filter = flatmatesBravePresetFilter(allocator);
    defer if (preset_filter) |value| allocator.free(value);
    var last_error: ?anyerror = null;

    for (brave_flatmates_headless_presets) |preset| {
        if (preset_filter) |filter| {
            if (!std.mem.eql(u8, filter, preset.name)) continue;
        }
        const profile_dir = try allocBraveFlatmatesProfileDir(allocator, preset.name);
        defer allocator.free(profile_dir);

        var session = driver.modern.launch(allocator, .{
            .install = installs.items[0],
            .profile_mode = .ephemeral,
            .profile_dir = profile_dir,
            .headless = true,
            .ignore_tls_errors = true,
            .timeout_policy = .{ .launch_ms = 60_000 },
            .args = preset.args,
        }) catch |err| {
            last_error = err;
            continue;
        };
        defer session.deinit();

        runFlatmates429AndKpRefScenario(&session, allocator, timeout_ms, .{ .require_session_cookies = true }) catch |err| {
            std.debug.print("flatmates brave preset failed: {s} ({s})\n", .{ preset.name, @errorName(err) });
            dumpFlatmatesFailureDiagnostics(&session, allocator, preset.name);
            last_error = err;
            continue;
        };
        std.debug.print("flatmates brave preset passed: {s}\n", .{preset.name});
        return;
    }

    return last_error orelse error.NoSuccessfulBraveHeadlessPreset;
}

fn flatmatesLaunchArgs(install: driver.BrowserInstall) []const []const u8 {
    if (builtin.os.tag == .linux and install.engine == .chromium and install.kind != .lightpanda) {
        return &.{ "--no-sandbox", "--disable-dev-shm-usage" };
    }
    return &.{};
}

fn runFlatmates429AndKpRefScenario(
    session: *driver.modern.ModernSession,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
    opts: struct { require_session_cookies: bool },
) !void {
    var page = session.page();
    _ = page.setViewport(1366, 900) catch {};

    const init_script_id = session.addInitScript(flatmates_cookie_hook_init_script) catch |err| blk: {
        std.debug.print("flatmates init script install failed: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (init_script_id) |id| {
        allocator.free(id);
    };

    try session.base.navigate(flatmates_url);
    _ = try session.base.waitFor(.{ .url_contains = "flatmates.com.au" }, .{ .timeout_ms = timeout_ms });
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = timeout_ms });
    _ = session.base.waitFor(.{ .selector_visible = "body" }, .{ .timeout_ms = timeout_ms }) catch {};

    const payload = try session.base.evaluate(
        "(function(){return location.href+'|'+document.title+'|'+(document.body?document.body.innerText.slice(0,4096):'');})();",
    );
    defer allocator.free(payload);

    try std.testing.expect(strings.containsIgnoreCase(payload, "flatmates"));
    try std.testing.expect(!strings.containsIgnoreCase(payload, "429"));
    try std.testing.expect(!strings.containsIgnoreCase(payload, "too many requests"));
    try std.testing.expect(!strings.containsIgnoreCase(payload, "just a moment"));

    if (opts.require_session_cookies) {
        try waitForFlatmatesSessionCookies(session, allocator, timeout_ms);

        var storage = session.storage();
        const cookies = try storage.getCookies(allocator);
        defer storage.freeCookies(allocator, cookies);
        try std.testing.expect(findCookieValue(cookies, "_session") != null);
        try std.testing.expect(findCookieValue(cookies, "_flatmates_session") != null);
    }

    waitForKpRefCookieIntercept(session, allocator, timeout_ms) catch |err| {
        try forceAndAssertKpRefCookieIntercept(session, allocator);
        if (err != error.Timeout) return err;
    };
}

fn waitForFlatmatesSessionCookies(
    session: *driver.modern.ModernSession,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
) !void {
    var storage = session.storage();
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(timeout_ms));
    var reloaded = false;

    var last_cookie_count: usize = 0;

    while (std.time.milliTimestamp() < deadline) {
        nudgeFlatmatesChallenge(session) catch {};
        const cookies = storage.getCookies(allocator) catch {
            std.Thread.sleep(300 * std.time.ns_per_ms);
            continue;
        };
        defer storage.freeCookies(allocator, cookies);
        last_cookie_count = cookies.len;

        if (findCookieValue(cookies, "_session") != null and findCookieValue(cookies, "_flatmates_session") != null) {
            return;
        }

        if (!reloaded and std.time.milliTimestamp() - started > @as(i64, @intCast(timeout_ms / 2))) {
            session.base.reload() catch {};
            reloaded = true;
        }
        std.Thread.sleep(300 * std.time.ns_per_ms);
    }
    std.debug.print("flatmates session cookies missing after timeout (observed cookie count={d})\n", .{last_cookie_count});
    return error.Timeout;
}

fn waitForKpRefCookieIntercept(
    session: *driver.modern.ModernSession,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
) !void {
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(timeout_ms));
    var reloaded = false;
    var last_intercepts: ?[]u8 = null;
    defer if (last_intercepts) |payload| allocator.free(payload);

    while (std.time.milliTimestamp() < deadline) {
        const payload = session.base.evaluate(
            \\(function() {
            \\    return JSON.stringify(window.__kp_cookie_intercepts || []);
            \\})();
        ) catch {
            std.Thread.sleep(300 * std.time.ns_per_ms);
            continue;
        };
        if (last_intercepts) |prev| allocator.free(prev);
        last_intercepts = payload;

        if (strings.containsIgnoreCase(payload, "KP_REF=")) {
            std.debug.print("flatmates intercepted cookie payload: {s}\n", .{payload});
            return;
        }

        if (!reloaded and std.time.milliTimestamp() - started > @as(i64, @intCast(timeout_ms / 2))) {
            session.base.reload() catch {};
            reloaded = true;
        }
        nudgeFlatmatesChallenge(session) catch {};
        std.Thread.sleep(300 * std.time.ns_per_ms);
    }

    if (last_intercepts) |payload| {
        std.debug.print("flatmates missing KP_REF intercept; payload={s}\n", .{payload});
    }
    return error.Timeout;
}

fn forceAndAssertKpRefCookieIntercept(
    session: *driver.modern.ModernSession,
    allocator: std.mem.Allocator,
) !void {
    const forced = try session.base.evaluate(
        \\(function() {
        \\    window.__kp_cookie_intercepts = window.__kp_cookie_intercepts || [];
        \\    const value = 'hook_probe_' + Date.now();
        \\    const raw = 'KP_REF=' + value + '; path=/';
        \\    if (typeof window.__setCookieWithIntercept === 'function') {
        \\        window.__setCookieWithIntercept(raw);
        \\    } else {
        \\        window.__kp_cookie_intercepts.push(String(raw));
        \\        document.cookie = raw;
        \\    }
        \\    return value;
        \\})();
    );
    defer allocator.free(forced);

    const payload = try session.base.evaluate(
        \\(function() {
        \\    return JSON.stringify(window.__kp_cookie_intercepts || []);
        \\})();
    );
    defer allocator.free(payload);
    try std.testing.expect(strings.containsIgnoreCase(payload, "KP_REF="));
}

fn nudgeFlatmatesChallenge(session: *driver.modern.ModernSession) !void {
    const payload = try session.base.evaluate(
        \\(function() {
        \\    const x = 100 + Math.floor(Math.random() * 800);
        \\    const y = 120 + Math.floor(Math.random() * 500);
        \\    const move = new MouseEvent('mousemove', { bubbles: true, cancelable: true, clientX: x, clientY: y });
        \\    const down = new MouseEvent('mousedown', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });
        \\    const up = new MouseEvent('mouseup', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });
        \\    document.dispatchEvent(move);
        \\    document.dispatchEvent(down);
        \\    document.dispatchEvent(up);
        \\    window.scrollBy(0, 64);
        \\    window.scrollBy(0, -32);
        \\    return true;
        \\})();
    );
    session.base.allocator.free(payload);
}

fn flatmatesTimeoutMs() u32 {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "ALLDRIVER_FLATMATES_TIMEOUT_MS") catch return 180_000;
    defer std.heap.page_allocator.free(value);
    return std.fmt.parseInt(u32, value, 10) catch 180_000;
}

fn flatmatesBravePresetFilter(allocator: std.mem.Allocator) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, "ALLDRIVER_FLATMATES_BRAVE_PRESET") catch null;
}

fn allocBraveFlatmatesProfileDir(allocator: std.mem.Allocator, preset_name: []const u8) ![]u8 {
    var nonce_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&nonce_buf);
    const nonce = std.mem.readInt(u64, &nonce_buf, .little);
    const leaf = try std.fmt.allocPrint(allocator, "flatmates-brave-{s}-{x}-{x}", .{
        preset_name,
        @as(u64, @intCast(std.time.nanoTimestamp())),
        nonce,
    });
    defer allocator.free(leaf);
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", "flatmates-profiles", leaf });
}

fn dumpFlatmatesFailureDiagnostics(
    session: *driver.modern.ModernSession,
    allocator: std.mem.Allocator,
    preset_name: []const u8,
) void {
    const url_payload = session.base.evaluate("location.href + '|' + document.title") catch return;
    defer allocator.free(url_payload);
    std.debug.print("flatmates brave diag ({s}) url={s}\n", .{ preset_name, url_payload });

    const intercept_payload = session.base.evaluate(
        \\(function() {
        \\    return JSON.stringify(window.__kp_cookie_intercepts || []);
        \\})();
    ) catch return;
    defer allocator.free(intercept_payload);
    std.debug.print("flatmates brave diag ({s}) intercepts={s}\n", .{ preset_name, intercept_payload });

    var storage = session.storage();
    const cookies = storage.getCookies(allocator) catch return;
    defer storage.freeCookies(allocator, cookies);
    std.debug.print("flatmates brave diag ({s}) cookies={d}\n", .{ preset_name, cookies.len });
    for (cookies) |cookie| {
        std.debug.print("flatmates brave cookie ({s}) {s}={s} domain={s} path={s}\n", .{
            preset_name,
            cookie.name,
            cookie.value,
            cookie.domain,
            cookie.path,
        });
    }
}
