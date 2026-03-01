const std = @import("std");
const driver = @import("../root.zig");
const helpers = @import("helpers.zig");

const example_url = "data:text/html,<html><head><title>gate</title></head><body>gate</body></html>";

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
