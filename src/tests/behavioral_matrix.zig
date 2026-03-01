const std = @import("std");
const builtin = @import("builtin");
const driver = @import("../root.zig");
const helpers = @import("helpers.zig");

const example_url = "data:text/html,<html><head><title>gate</title></head><body>gate</body></html>";
const flatmates_url = "https://flatmates.com.au/";
const lightpanda_cookie_probe_html =
    "<!doctype html><html><head><title>lightpanda-cdp-ok</title></head><body><button id='btn' onclick='window.__clicked=(window.__clicked||0)+1'>Click</button><input id='name'/><script>window.__clicked=0;document.cookie='lp_js_cookie=js_cookie_value; path=/';localStorage.setItem('seed_local','ready');sessionStorage.setItem('seed_session','ready');</script></body></html>";
const data_page_one = "data:text/html,<html><head><title>lp-page-one</title></head><body><button id='btn'>one</button><input id='name' value=''/></body></html>";
const data_page_two = "data:text/html,<html><head><title>lp-page-two</title></head><body><button id='btn'>two</button><input id='name' value=''/></body></html>";

var endpoint_event_lock: std.Thread.Mutex = .{};
var endpoint_nav_started_count: usize = 0;
var endpoint_nav_completed_count: usize = 0;
var endpoint_cookie_updated_count: usize = 0;

fn resetEndpointEventCounters() void {
    endpoint_event_lock.lock();
    defer endpoint_event_lock.unlock();
    endpoint_nav_started_count = 0;
    endpoint_nav_completed_count = 0;
    endpoint_cookie_updated_count = 0;
}

fn snapshotEndpointEventCounters() struct { nav_started: usize, nav_completed: usize, cookie_updated: usize } {
    endpoint_event_lock.lock();
    defer endpoint_event_lock.unlock();
    return .{
        .nav_started = endpoint_nav_started_count,
        .nav_completed = endpoint_nav_completed_count,
        .cookie_updated = endpoint_cookie_updated_count,
    };
}

fn endpointLifecycleCallback(event: driver.LifecycleEvent) void {
    endpoint_event_lock.lock();
    defer endpoint_event_lock.unlock();
    switch (event) {
        .navigation_started => endpoint_nav_started_count += 1,
        .navigation_completed => endpoint_nav_completed_count += 1,
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

    const launch_args: []const []const u8 = if (builtin.os.tag == .linux)
        &.{ "--no-sandbox", "--disable-dev-shm-usage" }
    else
        &.{};
    var launched: ?driver.modern.ModernSession = null;
    var launch_failure: ?anyerror = null;
    for (installs.items) |install| {
        if (install.kind != .lightpanda) continue;
        const session = driver.modern.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
            .ignore_tls_errors = true,
            .include_lightpanda_browser = true,
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

    const launch_args: []const []const u8 = if (builtin.os.tag == .linux)
        &.{ "--no-sandbox", "--disable-dev-shm-usage" }
    else
        &.{};
    var launched: ?driver.modern.ModernSession = null;
    var launch_failure: ?anyerror = null;
    for (installs.items) |install| {
        if (install.kind != .lightpanda) continue;
        const session = driver.modern.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
            .ignore_tls_errors = true,
            .include_lightpanda_browser = true,
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
        .kinds = &.{ .navigation_started, .navigation_completed, .cookie_updated },
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

    try std.testing.expect(session.offEvent(subscription_id));

    thread.join();
    joined = true;
    try std.testing.expect(server_ctx.handled);
    try std.testing.expect(!server_ctx.failed);
}

test "adversarial flatmates load beyond 429 facade (opt-in)" {
    if (!helpers.envEnabled("ALLDRIVER_ADVERSARIAL_FLATMATES")) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox, .lightpanda },
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    const install = pickFlatmatesInstall(installs.items) orelse installs.items[0];
    const launch_args: []const []const u8 = if (builtin.os.tag == .linux and install.engine == .chromium)
        &.{ "--no-sandbox", "--disable-dev-shm-usage" }
    else
        &.{};

    const timeout_ms: u32 = 90_000;
    const headless = !helpers.envEnabled("ALLDRIVER_ADVERSARIAL_HEADFUL");
    var session = try driver.modern.launch(allocator, .{
        .install = install,
        .profile_mode = .ephemeral,
        .headless = headless,
        .ignore_tls_errors = true,
        .timeout_policy = .{ .launch_ms = 60_000 },
        .args = launch_args,
    });
    defer session.deinit();

    try session.base.navigate(flatmates_url);
    _ = try session.base.waitFor(.{ .url_contains = "flatmates.com.au" }, .{ .timeout_ms = timeout_ms });
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = timeout_ms });
    _ = try session.base.waitFor(.{ .js_truthy = "document.body && document.body.innerText && document.body.innerText.length > 0" }, .{
        .timeout_ms = timeout_ms,
    });

    const payload = try session.base.evaluate(
        "(function(){return location.href+'|'+document.title+'|'+(document.body?document.body.innerText.slice(0,4096):'');})();",
    );
    defer allocator.free(payload);

    try std.testing.expect(helpers.containsIgnoreCase(payload, "flatmates"));
    try std.testing.expect(!helpers.containsIgnoreCase(payload, "429"));
    try std.testing.expect(!helpers.containsIgnoreCase(payload, "too many requests"));
    try std.testing.expect(!helpers.containsIgnoreCase(payload, "just a moment"));
}

fn pickFlatmatesInstall(installs: []const driver.BrowserInstall) ?driver.BrowserInstall {
    const preferred = [_]driver.BrowserKind{
        .chrome,
        .edge,
        .lightpanda,
        .vivaldi,
        .brave,
        .operagx,
        .firefox,
    };
    for (preferred) |kind| {
        for (installs) |install| {
            if (install.kind == kind and driver.support_tier.browserTier(install.kind) == .modern) {
                return install;
            }
        }
    }
    return null;
}
