const std = @import("std");
const driver = @import("../root.zig");
const runtime = @import("../runtime.zig");
const modern_session_mod = @import("../modern/session.zig");
const legacy_session_mod = @import("../legacy/session.zig");

test "support tier mapping contract" {
    try std.testing.expectEqual(driver.support_tier.ApiTier.modern, driver.support_tier.browserTier(.chrome));
    try std.testing.expectEqual(driver.support_tier.ApiTier.legacy, driver.support_tier.browserTier(.safari));
    try std.testing.expectEqual(driver.support_tier.ApiTier.modern, driver.support_tier.webViewTier(.electron));
    try std.testing.expectEqual(driver.support_tier.ApiTier.legacy, driver.support_tier.webViewTier(.wkwebview));
}

test "modern session rejects webdriver transport" {
    const allocator = std.testing.allocator;
    const base = try runtime.attach(allocator, "webdriver://127.0.0.1:4444/session/1");

    try std.testing.expectError(error.UnsupportedProtocol, modern_session_mod.ModernSession.fromBase(base));
}

test "legacy session accepts webdriver transport" {
    const allocator = std.testing.allocator;
    const base = try runtime.attach(allocator, "webdriver://127.0.0.1:4444/session/1");
    var legacy = try legacy_session_mod.LegacySession.fromBase(base);
    defer legacy.deinit();
    try std.testing.expect(legacy.base.transport == .webdriver_http);
}

test "root attach shim routes cdp and webdriver" {
    const allocator = std.testing.allocator;

    var modern = try driver.attach(allocator, "cdp://127.0.0.1:9222");
    defer modern.deinit();
    try std.testing.expect(modern.transport == .cdp_ws);

    var legacy = try driver.attach(allocator, "webdriver://127.0.0.1:4444/session/1");
    defer legacy.deinit();
    try std.testing.expect(legacy.transport == .webdriver_http);

    var secure_modern = try driver.attach(allocator, "wss://127.0.0.1/devtools/browser/abc");
    defer secure_modern.deinit();
    try std.testing.expect(secure_modern.transport == .cdp_ws);

    var bidi = try driver.attach(allocator, "bidi://127.0.0.1/session/1");
    defer bidi.deinit();
    try std.testing.expect(bidi.transport == .bidi_ws);
}

test "modern and legacy attach endpoints enforce protocol split" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.UnsupportedProtocol,
        driver.modern.attach(allocator, "webdriver://127.0.0.1:4444/session/1"),
    );

    try std.testing.expectError(
        error.UnsupportedProtocol,
        driver.legacy.attachWebDriver(allocator, "cdp://127.0.0.1:9222"),
    );
}

test "root webview shim routes modern and legacy transports" {
    const allocator = std.testing.allocator;

    var modern_webview = try driver.attachWebView(allocator, .{
        .kind = .electron,
        .endpoint = "cdp://127.0.0.1:9222/devtools/page/1",
    });
    defer modern_webview.deinit();
    try std.testing.expectEqual(driver.support_tier.ApiTier.modern, driver.support_tier.webViewTier(.electron));
    try std.testing.expect(modern_webview.transport == .cdp_ws);
    try std.testing.expect(modern_webview.mode == .webview);

    var legacy_webview = try driver.attachWebView(allocator, .{
        .kind = .wkwebview,
        .endpoint = "webdriver://127.0.0.1:4444/session/1",
    });
    defer legacy_webview.deinit();
    try std.testing.expectEqual(driver.support_tier.ApiTier.legacy, driver.support_tier.webViewTier(.wkwebview));
    try std.testing.expect(legacy_webview.transport == .webdriver_http);
    try std.testing.expect(legacy_webview.mode == .webview);
}

test "modern and legacy webview APIs enforce kind split" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.UnsupportedWebViewKind,
        driver.modern.attachWebView(allocator, .{
            .kind = .wkwebview,
            .endpoint = "webdriver://127.0.0.1:4444/session/1",
        }),
    );

    try std.testing.expectError(
        error.UnsupportedWebViewKind,
        driver.legacy.attachWebView(allocator, .{
            .kind = .electron,
            .endpoint = "cdp://127.0.0.1:9222/devtools/page/1",
        }),
    );
}

test "discover split filters incompatible browser kinds" {
    const allocator = std.testing.allocator;

    const modern_from_legacy = try driver.modern.discover(allocator, .{
        .kinds = &.{.safari},
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer driver.freeInstalls(allocator, modern_from_legacy);
    try std.testing.expectEqual(@as(usize, 0), modern_from_legacy.len);

    const legacy_from_modern = try driver.legacy.discover(allocator, .{
        .kinds = &.{.chrome},
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer driver.freeInstalls(allocator, legacy_from_modern);
    try std.testing.expectEqual(@as(usize, 0), legacy_from_modern.len);
}

test "discover split filters incompatible webview kinds" {
    const allocator = std.testing.allocator;

    const modern_from_legacy = try driver.modern.discoverWebViews(allocator, .{
        .kinds = &.{.wkwebview},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = true,
    });
    defer driver.modern.freeWebViewRuntimes(allocator, modern_from_legacy);
    try std.testing.expectEqual(@as(usize, 0), modern_from_legacy.len);

    const legacy_from_modern = try driver.legacy.discoverWebViews(allocator, .{
        .kinds = &.{.electron},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = true,
    });
    defer driver.legacy.freeWebViewRuntimes(allocator, legacy_from_modern);
    try std.testing.expectEqual(@as(usize, 0), legacy_from_modern.len);
}

test "modern executor source does not reference webdriver transport branch" {
    const source = @embedFile("../protocol/modern_executor.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "webdriver_http") == null);
}
