const std = @import("std");
const driver = @import("../root.zig");
const helpers = @import("helpers.zig");
const common = @import("../protocol/common.zig");
const http = @import("../transport/http_client.zig");

const brave_cookie_probe_html =
    "<!doctype html><html><head><title>brave-transport-ok</title></head><body><button id='btn' onclick='window.__clicked=(window.__clicked||0)+1'>Click</button><input id='name'/><script>window.__clicked=0;document.cookie='brave_js_cookie=js_cookie_value; path=/';localStorage.setItem('seed_local','ready');sessionStorage.setItem('seed_session','ready');</script></body></html>";
const data_page_one = "data:text/html,<html><head><title>brave-page-one</title></head><body><button id='btn'>one</button><input id='name' value=''/></body></html>";
const data_page_two = "data:text/html,<html><head><title>brave-page-two</title></head><body><button id='btn'>two</button><input id='name' value=''/></body></html>";
const brave_headless_args = &.{
    "--no-sandbox",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--disable-dev-shm-usage",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--metrics-recording-only",
    "--password-store=basic",
    "--use-mock-keychain",
    "--disable-breakpad",
    "--disable-features=OptimizationGuideModelDownloading,OptimizationHints,AutofillServerCommunication,MediaRouter,DialMediaRouteProvider",
    "--disk-cache-size=1",
    "--media-cache-size=1",
};
const brave_headless_bidi_args = &.{
    "--no-sandbox",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--disable-dev-shm-usage",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--metrics-recording-only",
    "--password-store=basic",
    "--use-mock-keychain",
    "--disable-breakpad",
    "--disable-features=OptimizationGuideModelDownloading,OptimizationHints,AutofillServerCommunication,MediaRouter,DialMediaRouteProvider",
    "--disk-cache-size=1",
    "--media-cache-size=1",
    "--enable-bidi-server",
};

var event_lock: std.Thread.Mutex = .{};
var nav_started_count: usize = 0;
var nav_completed_count: usize = 0;
var cookie_updated_count: usize = 0;

fn resetEventCounters() void {
    event_lock.lock();
    defer event_lock.unlock();
    nav_started_count = 0;
    nav_completed_count = 0;
    cookie_updated_count = 0;
}

fn snapshotEventCounters() struct { nav_started: usize, nav_completed: usize, cookie_updated: usize } {
    event_lock.lock();
    defer event_lock.unlock();
    return .{
        .nav_started = nav_started_count,
        .nav_completed = nav_completed_count,
        .cookie_updated = cookie_updated_count,
    };
}

fn lifecycleCallback(event: driver.LifecycleEvent) void {
    event_lock.lock();
    defer event_lock.unlock();
    switch (event) {
        .navigation_started => nav_started_count += 1,
        .navigation_completed => nav_completed_count += 1,
        .cookie_updated => cookie_updated_count += 1,
        else => {},
    }
}

fn requestCallback(_: driver.RequestEvent) void {}
fn responseCallback(_: driver.ResponseEvent) void {}
fn logCallback(_: @import("../modern/log.zig").LogEntry) void {}

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
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nSet-Cookie: brave_server_cookie=server_cookie_value; Path=/\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
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

fn launchBraveHeadless(allocator: std.mem.Allocator, enable_bidi: bool) !driver.modern.ModernSession {
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

    return driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .ignore_tls_errors = true,
        .args = if (enable_bidi) brave_headless_bidi_args else brave_headless_args,
    });
}

fn attachBraveBidiFromCdpEndpoint(allocator: std.mem.Allocator, cdp_endpoint: []const u8) !driver.modern.ModernSession {
    const parsed = try common.parseEndpoint(cdp_endpoint, .cdp);
    var candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (candidates.items) |endpoint| allocator.free(endpoint);
        candidates.deinit(allocator);
    }

    try appendUniqueBidiEndpoint(&candidates, allocator, parsed.host, parsed.port, "/session");
    try appendUniqueBidiEndpoint(&candidates, allocator, parsed.host, parsed.port, "/session/");
    try appendUniqueBidiEndpoint(&candidates, allocator, parsed.host, parsed.port, "/");
    try appendBidiCandidatesFromVersion(&candidates, allocator, parsed.host, parsed.port);

    var first_error: ?anyerror = null;

    for (candidates.items) |endpoint| {
        const session = driver.modern.attach(allocator, endpoint) catch |err| {
            if (first_error == null) first_error = err;
            continue;
        };
        return session;
    }

    return first_error orelse error.MissingEndpoint;
}

fn appendUniqueBidiEndpoint(
    candidates: *std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
) !void {
    const endpoint = try std.fmt.allocPrint(allocator, "bidi://{s}:{d}{s}", .{ host, port, path });
    defer allocator.free(endpoint);
    for (candidates.items) |existing| {
        if (std.mem.eql(u8, existing, endpoint)) return;
    }
    try candidates.append(allocator, try allocator.dupe(u8, endpoint));
}

fn appendUniqueBidiFromWs(
    candidates: *std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    ws_url: []const u8,
) !void {
    const parsed = common.parseEndpoint(ws_url, .bidi) catch return;
    if (parsed.adapter != .bidi) return;
    try appendUniqueBidiEndpoint(candidates, allocator, parsed.host, parsed.port, parsed.path);
    if (std.mem.startsWith(u8, parsed.path, "/devtools/browser/")) {
        try appendUniqueBidiEndpoint(candidates, allocator, parsed.host, parsed.port, "/session");
        try appendUniqueBidiEndpoint(candidates, allocator, parsed.host, parsed.port, "/session/");
    }
}

fn appendBidiCandidatesFromVersion(
    candidates: *std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
) !void {
    const version = http.getJson(allocator, host, port, "/json/version") catch return;
    defer allocator.free(version.body);
    if (version.status_code < 200 or version.status_code >= 300) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, version.body, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const keys = [_][]const u8{
        "webSocketUrl",
        "webSocketBiDiUrl",
        "webSocketBidiUrl",
        "bidiWebSocketUrl",
        "webSocketDebuggerUrl",
    };
    inline for (keys) |key| {
        if (parsed.value.object.get(key)) |value| {
            if (value == .string) {
                try appendUniqueBidiFromWs(candidates, allocator, value.string);
            }
        }
    }
}

fn runCdpFullConformance(
    session: *driver.modern.ModernSession,
    allocator: std.mem.Allocator,
    server_url: []const u8,
) !void {
    resetEventCounters();
    const subscription_id = try session.onEvent(.{
        .kinds = &.{ .navigation_started, .navigation_completed, .cookie_updated },
    }, lifecycleCallback);
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
        .name = "brave_api_cookie",
        .value = "api_cookie_value",
        .domain = "127.0.0.1",
        .path = "/",
    });
    _ = try session.waitFor(.{ .cookie_present = .{
        .name = "brave_api_cookie",
        .domain = "127.0.0.1",
        .include_http_only = true,
    } }, .{ .timeout_ms = 10_000 });

    const cookies = try storage.getCookies(allocator);
    defer storage.freeCookies(allocator, cookies);
    try std.testing.expect(findCookieValue(cookies, "brave_server_cookie") != null);
    try std.testing.expect(findCookieValue(cookies, "brave_js_cookie") != null);
    try std.testing.expect(findCookieValue(cookies, "brave_api_cookie") != null);

    const filtered = try storage.queryCookies(allocator, .{
        .name = "brave_api_cookie",
        .domain = "127.0.0.1",
    });
    defer storage.freeCookies(allocator, filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);

    const cookie_header = try storage.buildCookieHeaderForUrl(allocator, server_url, .{});
    defer allocator.free(cookie_header);
    try std.testing.expect(std.mem.indexOf(u8, cookie_header, "brave_api_cookie") != null);

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
    network_client.onRequest(requestCallback);
    network_client.onResponse(responseCallback);
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
    defer {
        contexts.close(created_context.id) catch {};
        allocator.free(created_context.id);
    }
    try std.testing.expect(created_context.id.len > 0);

    var targets = session.targets();
    const target_list = try targets.list(allocator);
    defer targets.freeList(allocator, target_list);
    try std.testing.expect(target_list.len > 0);
    try targets.attach(created_context.id);
    try targets.detach(created_context.id);

    var log_client = session.log();
    try std.testing.expectError(error.UnsupportedProtocol, log_client.onConsole(logCallback));
    try std.testing.expectError(error.UnsupportedProtocol, log_client.onException(logCallback));

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

    const counters = snapshotEventCounters();
    try std.testing.expect(counters.nav_started > 0);
    try std.testing.expect(counters.nav_completed > 0);
    try std.testing.expect(counters.cookie_updated > 0);

    try std.testing.expect(session.offEvent(subscription_id));
}

fn runBidiConformance(
    session: *driver.modern.ModernSession,
    allocator: std.mem.Allocator,
    server_url: []const u8,
) !void {
    resetEventCounters();
    const subscription_id = try session.onEvent(.{
        .kinds = &.{ .navigation_started, .navigation_completed },
    }, lifecycleCallback);
    defer {
        _ = session.offEvent(subscription_id);
    }

    var page = session.page();
    try page.navigate(server_url);
    _ = try session.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 20_000 });
    _ = try session.waitFor(.{ .selector_visible = "#btn" }, .{ .timeout_ms = 10_000 });
    _ = try session.waitFor(.{ .url_contains = "127.0.0.1" }, .{ .timeout_ms = 10_000 });
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
    try std.testing.expectError(error.UnsupportedProtocol, storage.setCookie(.{
        .name = "bidi_cookie",
        .value = "x",
        .domain = "127.0.0.1",
        .path = "/",
    }));
    try std.testing.expectError(error.UnsupportedProtocol, storage.getCookies(allocator));
    try std.testing.expectError(error.UnsupportedProtocol, storage.queryCookies(allocator, .{ .name = "bidi_cookie" }));
    try std.testing.expectError(error.UnsupportedProtocol, storage.buildCookieHeaderForUrl(allocator, server_url, .{}));

    try storage.setLocalStorage("bidi_local", "local_v");
    const local_value = try storage.getLocalStorage("bidi_local");
    defer allocator.free(local_value);
    try std.testing.expect(std.mem.indexOf(u8, local_value, "local_v") != null);
    _ = try session.waitFor(.{ .storage_key_present = .{
        .key = "bidi_local",
        .area = .local,
    } }, .{ .timeout_ms = 10_000 });

    try storage.setSessionStorage("bidi_session", "session_v");
    const session_value = try storage.getSessionStorage("bidi_session");
    defer allocator.free(session_value);
    try std.testing.expect(std.mem.indexOf(u8, session_value, "session_v") != null);
    try storage.clear();

    try std.testing.expectError(error.UnsupportedProtocol, page.screenshot(allocator, .png));

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
    network_client.onRequest(requestCallback);
    network_client.onResponse(responseCallback);
    try network_client.enable();
    try network_client.addRule(.{
        .id = "rule-block-data-bidi",
        .url_pattern = "*://example.invalid/*",
        .action = .{ .block = {} },
    });
    try std.testing.expect(try network_client.removeRule("rule-block-data-bidi"));
    try network_client.disable();

    var contexts = session.contexts();
    try std.testing.expectError(error.UnsupportedProtocol, contexts.list(allocator));
    try std.testing.expectError(error.UnsupportedProtocol, contexts.create(allocator));
    try std.testing.expectError(error.UnsupportedProtocol, contexts.close("ctx-missing"));

    var targets = session.targets();
    try std.testing.expectError(error.UnsupportedProtocol, targets.list(allocator));
    try std.testing.expectError(error.UnsupportedProtocol, targets.attach("target-missing"));
    try std.testing.expectError(error.UnsupportedProtocol, targets.detach("target-missing"));

    var log_client = session.log();
    try std.testing.expectError(error.UnsupportedProtocol, log_client.onConsole(logCallback));
    try std.testing.expectError(error.UnsupportedProtocol, log_client.onException(logCallback));

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
    try std.testing.expectError(error.UnsupportedProtocol, screenshot_async.await(20_000));

    var trace_start_async = try session.startTracingAsync();
    defer trace_start_async.deinit();
    try std.testing.expectError(error.UnsupportedCapability, trace_start_async.await(20_000));

    var trace_stop_async = try session.stopTracingAsync();
    defer trace_stop_async.deinit();
    try std.testing.expectError(error.UnsupportedCapability, trace_stop_async.await(20_000));

    const counters = snapshotEventCounters();
    try std.testing.expect(counters.nav_started > 0);
    try std.testing.expect(counters.nav_completed > 0);
    try std.testing.expect(session.offEvent(subscription_id));
}

test "brave cdp full endpoints conformance (opt-in)" {
    if (!helpers.envEnabled("BRAVE_ALL_ENDPOINTS")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var session = try launchBraveHeadless(allocator, false);
    defer session.deinit();

    var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(.{});
    var server_ctx = OneShotCookieServer{
        .server = server,
        .body = brave_cookie_probe_html,
    };
    const thread = try std.Thread.spawn(.{}, runOneShotCookieServer, .{&server_ctx});
    var joined = false;
    defer if (!joined) {
        if (std.net.Address.parseIp4("127.0.0.1", server_ctx.port())) |wake_addr| {
            if (std.net.tcpConnectToAddress(wake_addr)) |stream| stream.close() else |_| {}
        } else |_| {}
        thread.join();
    };

    const server_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server_ctx.port()});
    defer allocator.free(server_url);

    try runCdpFullConformance(&session, allocator, server_url);

    thread.join();
    joined = true;
    try std.testing.expect(server_ctx.handled);
    try std.testing.expect(!server_ctx.failed);
}

test "brave bidi endpoints conformance (opt-in)" {
    if (!helpers.envEnabled("BRAVE_ALL_ENDPOINTS")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const strict_bidi = helpers.envEnabled("BRAVE_BIDI_STRICT");
    var launch_session = try launchBraveHeadless(allocator, true);
    defer launch_session.deinit();
    const cdp_endpoint = launch_session.base.endpoint orelse return error.MissingEndpoint;

    var bidi_session = attachBraveBidiFromCdpEndpoint(allocator, cdp_endpoint) catch |err| {
        if (strict_bidi) return err;
        std.debug.print("brave bidi unavailable: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer bidi_session.deinit();

    var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(.{});
    var server_ctx = OneShotCookieServer{
        .server = server,
        .body = brave_cookie_probe_html,
    };
    const thread = try std.Thread.spawn(.{}, runOneShotCookieServer, .{&server_ctx});
    var joined = false;
    defer if (!joined) {
        if (std.net.Address.parseIp4("127.0.0.1", server_ctx.port())) |wake_addr| {
            if (std.net.tcpConnectToAddress(wake_addr)) |stream| stream.close() else |_| {}
        } else |_| {}
        thread.join();
    };

    const server_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server_ctx.port()});
    defer allocator.free(server_url);

    try runBidiConformance(&bidi_session, allocator, server_url);

    thread.join();
    joined = true;
    try std.testing.expect(server_ctx.handled);
    try std.testing.expect(!server_ctx.failed);
}
