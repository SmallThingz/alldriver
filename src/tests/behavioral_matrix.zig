const std = @import("std");
const builtin = @import("builtin");
const driver = @import("../root.zig");
const helpers = @import("helpers.zig");

const example_url = "data:text/html,<html><head><title>gate</title></head><body>gate</body></html>";
const flatmates_url = "https://flatmates.com.au/";
const lightpanda_cookie_probe_html =
    "<!doctype html><html><head><title>lightpanda-cdp-ok</title></head><body>ok<script>document.cookie='lp_js_cookie=js_cookie_value; path=/';</script></body></html>";

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
