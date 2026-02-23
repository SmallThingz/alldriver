const std = @import("std");
const driver = @import("../root.zig");

const example_url = "https://example.com/";

fn envEnabled(name: []const u8) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
    defer std.heap.page_allocator.free(value);

    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    return false;
}

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

fn fetchExampleAndAssert(session: *driver.Session, allocator: std.mem.Allocator) !void {
    try session.navigate(example_url);
    try session.waitFor(.dom_ready, 15_000);
    session.waitFor(.network_idle, 10_000) catch {};

    const probe = try session.evaluate(
        "(function(){return [location.hostname, document.title, document.body ? document.body.innerText : ''].join('\\n');})();",
    );
    defer allocator.free(probe);

    const has_domain = std.mem.indexOf(u8, probe, "example.com") != null or
        std.mem.indexOf(u8, probe, "www.example.com") != null;
    const has_title = std.mem.indexOf(u8, probe, "Example Domain") != null or
        std.mem.indexOf(u8, probe, "example domain") != null or
        std.mem.indexOf(u8, probe, "EXAMPLE DOMAIN") != null;

    if (!has_domain or !has_title) {
        return error.ExampleFetchAssertionFailed;
    }
}

test "behavioral browser smoke matrix (opt-in)" {
    if (!envEnabled("BROWSER_DRIVER_BEHAVIORAL")) return error.SkipZigTest;

    const strict = envEnabled("BROWSER_DRIVER_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;

    const all_kinds = [_]driver.BrowserKind{
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

    var discovered_any: bool = false;
    var fetched_any: bool = false;
    var cdp_candidate_any: bool = false;
    var webview_fetched_any: bool = false;

    for (all_kinds) |kind| {
        const installs = try driver.discover(allocator, .{
            .kinds = &.{kind},
            .allow_managed_download = false,
        }, .{
            .include_path_env = true,
            .include_os_probes = true,
            .include_known_paths = true,
        });
        defer driver.freeInstalls(allocator, installs);

        if (installs.len == 0) {
            if (strict) return error.MissingBrowserInstall;
            continue;
        }
        discovered_any = true;

        var session = driver.launch(allocator, .{
            .install = installs[0],
            .profile_mode = .ephemeral,
            .headless = true,
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

        if (session.transport == .cdp_ws and session.endpoint != null) {
            cdp_candidate_any = true;
            var webview_session = driver.attachWebView(allocator, .{
                .kind = .android_webview,
                .endpoint = session.endpoint.?,
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
    }

    if (!discovered_any) return error.NoBehavioralRuns;
    if (!fetched_any) return error.NoSuccessfulExampleFetch;
    if (cdp_candidate_any and !webview_fetched_any) return error.NoSuccessfulWebViewExampleFetch;
}

test "behavioral webview bridge discovery smoke (opt-in)" {
    if (!envEnabled("WEBVIEW_BRIDGE_BEHAVIORAL")) return error.SkipZigTest;

    const strict = envEnabled("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT");
    const allocator = std.testing.allocator;

    const runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{ .android_webview, .ios_wkwebview },
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = true,
    });
    defer driver.freeWebViewRuntimes(allocator, runtimes);

    if (!strict) return;

    var has_android = false;
    var has_ios = false;
    for (runtimes) |runtime| {
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
