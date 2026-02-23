const std = @import("std");
const driver = @import("../root.zig");

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

    var ran_any: bool = false;

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

        session.navigate("data:text/html,<html><body>driver-smoke</body></html>") catch |err| {
            if (strict) return err;
            continue;
        };
        session.waitFor(.dom_ready, 10_000) catch |err| {
            if (strict) return err;
            continue;
        };

        const res = session.evaluate("document.body && document.body.textContent ? document.body.textContent : ''") catch |err| {
            if (strict) return err;
            continue;
        };
        defer allocator.free(res);

        if (strict and std.mem.indexOf(u8, res, "driver-smoke") == null) {
            return error.SmokeAssertionFailed;
        }

        ran_any = true;
    }

    if (strict and !ran_any) return error.NoBehavioralRuns;
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
