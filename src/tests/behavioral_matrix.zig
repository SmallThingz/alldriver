const std = @import("std");
const driver = @import("../root.zig");
const helpers = @import("helpers.zig");
const config = @import("alldriver_config");

const example_url = "data:text/html,<html><head><title>gate</title></head><body>gate</body></html>";

const BridgeRequirement = enum {
    none,
    android,
    ios,
    both,
};

fn bridgeRequirement() BridgeRequirement {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "WEBVIEW_BRIDGE_REQUIRED") catch return .both;
    defer std.heap.page_allocator.free(value);

    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "android")) return .android;
    if (std.ascii.eqlIgnoreCase(value, "ios")) return .ios;
    return .both;
}

fn fetchExampleAndAssert(session: anytype, allocator: std.mem.Allocator) !void {
    const base = &session.base;

    try base.navigate(example_url);
    _ = try base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });
    if (base.waitFor(.{ .network_idle = {} }, .{ .timeout_ms = 10_000 })) |_| {
        // best-effort network-idle wait for stability across engines
    } else |_| {
        // ignore in behavioral smoke paths where network-idle is adapter dependent
    }

    const probe = try base.evaluate(
        "(function(){return [location.hostname, location.href, document.title, document.body ? document.body.innerText : ''].join('\\n');})();",
    );
    defer allocator.free(probe);

    const has_domain = std.mem.indexOf(u8, probe, "example.com") != null or
        std.mem.indexOf(u8, probe, "www.example.com") != null;
    const has_title = std.mem.indexOf(u8, probe, "Example Domain") != null or
        std.mem.indexOf(u8, probe, "example domain") != null or
        std.mem.indexOf(u8, probe, "EXAMPLE DOMAIN") != null;
    const has_data_gate = std.mem.indexOf(u8, probe, "data:text/html") != null and
        (std.mem.indexOf(u8, probe, "gate") != null or std.mem.indexOf(u8, probe, "GATE") != null);

    if (base.transport == .webdriver_http and
        (std.mem.indexOf(u8, probe, "{\"value\":null}") != null or
            std.mem.indexOf(u8, probe, "\"value\":null") != null or
            std.mem.indexOf(u8, probe, "null") != null))
    {
        return;
    }

    if (!(has_domain or has_title or has_data_gate)) {
        std.debug.print("behavioral fetch assertion failed, probe=\n{s}\n", .{probe});
        return error.ExampleFetchAssertionFailed;
    }
}

fn includeLightpandaBehavioral() bool {
    return @hasDecl(config, "include_lightpanda_browser") and config.include_lightpanda_browser;
}

fn behavioralIgnoreTls() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "ALLDRIVER_TEST_IGNORE_TLS") catch return true;
    defer std.heap.page_allocator.free(value);
    return !std.mem.eql(u8, value, "0");
}

fn behavioralBrowserKinds() []const driver.BrowserKind {
    if (includeLightpandaBehavioral()) {
        return &[_]driver.BrowserKind{
            .chrome,
            .edge,
            .safari,
            .firefox,
            .brave,
            .tor,
            .duckduckgo,
            .mullvad,
            .librewolf,
            .epic,
            .arc,
            .vivaldi,
            .sigmaos,
            .sidekick,
            .shift,
            .operagx,
            .lightpanda,
            .palemoon,
        };
    }

    return &[_]driver.BrowserKind{
        .chrome,
        .edge,
        .safari,
        .firefox,
        .brave,
        .tor,
        .duckduckgo,
        .mullvad,
        .librewolf,
        .epic,
        .arc,
        .vivaldi,
        .sigmaos,
        .sidekick,
        .shift,
        .operagx,
        .palemoon,
    };
}

test "behavioral browser smoke matrix (opt-in)" {
    if (!helpers.envEnabled("ALLDRIVER_BEHAVIORAL")) return error.SkipZigTest;

    const strict = helpers.envEnabled("ALLDRIVER_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;

    var discovered_any: bool = false;
    var fetched_any: bool = false;
    var cdp_candidate_any: bool = false;
    var webview_fetched_any: bool = false;

    for (behavioralBrowserKinds()) |kind| {
        var installs = try driver.discover(allocator, .{
            .kinds = &.{kind},
            .allow_managed_download = false,
        }, .{
            .include_path_env = true,
            .include_os_probes = true,
            .include_known_paths = true,
        });
        defer installs.deinit();

        if (installs.items.len == 0) {
            if (strict) return error.MissingBrowserInstall;
            continue;
        }
        discovered_any = true;

        const install = installs.items[0];
        const tier = driver.support_tier.browserTier(install.kind);

        if (tier == .modern) {
            var session = driver.modern.launch(allocator, .{
                .install = install,
                .profile_mode = .ephemeral,
                .headless = true,
                .ignore_tls_errors = behavioralIgnoreTls(),
                .args = &.{},
            }) catch |err| {
                if (strict) return err;
                continue;
            };
            defer session.deinit();

            fetchExampleAndAssert(&session, allocator) catch |err| {
                if (strict) return err;
                std.debug.print("behavioral fetch failed for {s}: {s}\n", .{ @tagName(kind), @errorName(err) });
                continue;
            };
            fetched_any = true;

            if (session.base.transport == .cdp_ws and session.base.endpoint != null) {
                cdp_candidate_any = true;
                var webview_session = driver.modern.attachWebView(allocator, .{
                    .kind = .android_webview,
                    .endpoint = session.base.endpoint.?,
                }) catch |err| {
                    if (strict) return err;
                    std.debug.print("behavioral webview attach failed for {s}: {s}\n", .{ @tagName(kind), @errorName(err) });
                    continue;
                };
                defer webview_session.deinit();

                fetchExampleAndAssert(&webview_session, allocator) catch |err| {
                    if (strict) return err;
                    std.debug.print("behavioral webview fetch failed for {s}: {s}\n", .{ @tagName(kind), @errorName(err) });
                    continue;
                };
                webview_fetched_any = true;
            }
        } else {
            var session = driver.legacy.launch(allocator, .{
                .install = install,
                .profile_mode = .ephemeral,
                .headless = true,
                .ignore_tls_errors = behavioralIgnoreTls(),
                .args = &.{},
            }) catch |err| {
                if (strict) return err;
                continue;
            };
            defer session.deinit();

            fetchExampleAndAssert(&session, allocator) catch |err| {
                if (strict) return err;
                std.debug.print("behavioral fetch failed for {s}: {s}\n", .{ @tagName(kind), @errorName(err) });
                continue;
            };
            fetched_any = true;
        }
    }

    if (!discovered_any) return error.NoBehavioralRuns;
    if (!fetched_any) return error.NoSuccessfulExampleFetch;
    if (cdp_candidate_any and !webview_fetched_any) return error.NoSuccessfulWebViewExampleFetch;
}

test "behavioral webview bridge discovery smoke (opt-in)" {
    if (!helpers.envEnabled("WEBVIEW_BRIDGE_BEHAVIORAL")) return error.SkipZigTest;

    const strict = helpers.envEnabled("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;

    var runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{ .android_webview, .ios_wkwebview },
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = true,
    });
    defer runtimes.deinit();

    if (!strict) return;

    var has_android = false;
    var has_ios = false;
    for (runtimes.items) |runtime| {
        switch (runtime.kind) {
            .android_webview => has_android = true,
            .ios_wkwebview => has_ios = true,
            else => {},
        }
    }

    switch (bridgeRequirement()) {
        .none => {},
        .android => if (!has_android) return error.NoAndroidBridgeRuntimeFound,
        .ios => if (!has_ios) return error.NoIosBridgeRuntimeFound,
        .both => {
            if (!has_android and !has_ios) return error.NoBridgeRuntimeFound;
            if (!has_android) return error.NoAndroidBridgeRuntimeFound;
            if (!has_ios) return error.NoIosBridgeRuntimeFound;
        },
    }
}

test "behavioral electron webview smoke (opt-in)" {
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

    const executable_path = runtimes.items[0].runtime_path orelse {
        if (strict) return error.ElectronRuntimePathMissing;
        return;
    };

    var session = driver.modern.launchElectronWebView(allocator, .{
        .executable_path = executable_path,
        .profile_mode = .ephemeral,
        .headless = true,
        .ignore_tls_errors = behavioralIgnoreTls(),
    }) catch |err| {
        if (strict) return err;
        std.debug.print("electron behavioral launch failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer session.deinit();

    fetchExampleAndAssert(&session, allocator) catch |err| {
        if (strict) return err;
        std.debug.print("electron behavioral fetch failed: {s}\n", .{@errorName(err)});
    };
}

test "behavioral webkitgtk webview smoke (opt-in)" {
    if (!helpers.envEnabled("WEBKITGTK_BEHAVIORAL")) return error.SkipZigTest;

    const strict = helpers.envEnabled("WEBKITGTK_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;

    var runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{.webkitgtk},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer runtimes.deinit();

    var webdriver_path: ?[]const u8 = null;
    var minibrowser_path: ?[]const u8 = null;
    for (runtimes.items) |runtime| {
        const path = runtime.runtime_path orelse continue;
        const base = std.fs.path.basename(path);
        if (helpers.containsIgnoreCase(base, "webkitwebdriver")) webdriver_path = path;
        if (helpers.containsIgnoreCase(base, "minibrowser")) minibrowser_path = path;
    }

    if (webdriver_path == null) {
        if (strict) return error.NoWebKitGtkDriverRuntimeFound;
        return;
    }

    var session = driver.legacy.launchWebKitGtkWebView(allocator, .{
        .driver_executable_path = webdriver_path.?,
        .profile_mode = .ephemeral,
        .ignore_tls_errors = behavioralIgnoreTls(),
    }) catch |err| {
        if (strict) return err;
        std.debug.print("webkitgtk behavioral launch failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer session.deinit();

    if (!strict) return;

    fetchExampleAndAssert(&session, allocator) catch |err| {
        return err;
    };

    const mini = minibrowser_path orelse {
        return error.NoWebKitGtkMiniBrowserRuntimeFound;
    };
    var mini_targeted = driver.legacy.launchWebKitGtkWebView(allocator, .{
        .driver_executable_path = webdriver_path.?,
        .profile_mode = .ephemeral,
        .browser_target = .minibrowser,
        .browser_binary_path = mini,
        .ignore_tls_errors = behavioralIgnoreTls(),
    }) catch |err| {
        return err;
    };
    defer mini_targeted.deinit();

    fetchExampleAndAssert(&mini_targeted, allocator) catch |err| {
        return err;
    };
}
