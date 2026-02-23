const std = @import("std");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const common = @import("../protocol/common.zig");
const types = @import("../types.zig");
const windows_registry = @import("../discovery/windows_registry.zig");
const macos_apps = @import("../discovery/macos_apps.zig");
const linux_sources = @import("../discovery/linux_sources.zig");
const webview_discovery = @import("../discovery/webview/discover.zig");

fn probeCount(hints: path_table.BrowserPathHints) usize {
    return hints.executable_names.len + hints.known_paths.len + hints.mac_bundle_ids.len + hints.windows_registry_hints.len + hints.linux_package_hints.len;
}

test "path table invariants hold across all platforms" {
    const platforms = [_]catalog.Platform{ .windows, .macos, .linux };

    for (path_table.all_browser_kinds) |kind| {
        for (platforms) |platform| {
            const hints = path_table.hintsFor(kind, platform);
            try std.testing.expectEqual(kind, hints.kind);
            try std.testing.expectEqual(platform, hints.platform);
            try std.testing.expectEqual(catalog.engineFor(kind), hints.engine);

            for (hints.executable_names) |entry| try std.testing.expect(entry.len > 0);
            for (hints.known_paths) |entry| try std.testing.expect(entry.len > 0);
            for (hints.mac_bundle_ids) |entry| try std.testing.expect(entry.len > 0);
            for (hints.windows_registry_hints) |entry| try std.testing.expect(entry.len > 0);
            for (hints.linux_package_hints) |entry| try std.testing.expect(entry.len > 0);

            if (hints.confidence_weight > 0) {
                try std.testing.expect(probeCount(hints) > 0);
            }
        }
    }
}

test "every browser kind has at least one supported desktop platform hint" {
    const platforms = [_]catalog.Platform{ .windows, .macos, .linux };

    for (path_table.all_browser_kinds) |kind| {
        var supported: usize = 0;
        for (platforms) |platform| {
            const hints = path_table.hintsFor(kind, platform);
            if (hints.confidence_weight > 0 and probeCount(hints) > 0) {
                supported += 1;
            }
        }

        try std.testing.expect(supported > 0);
    }
}

test "browser support contract matches expected desktop platform matrix" {
    const Case = struct {
        kind: catalog.BrowserKind,
        windows: bool,
        macos: bool,
        linux: bool,
    };

    const cases = [_]Case{
        .{ .kind = .chrome, .windows = true, .macos = true, .linux = true },
        .{ .kind = .edge, .windows = true, .macos = true, .linux = true },
        .{ .kind = .safari, .windows = false, .macos = true, .linux = false },
        .{ .kind = .firefox, .windows = true, .macos = true, .linux = true },
        .{ .kind = .brave, .windows = true, .macos = true, .linux = true },
        .{ .kind = .tor, .windows = true, .macos = true, .linux = true },
        .{ .kind = .duckduckgo, .windows = true, .macos = true, .linux = true },
        .{ .kind = .mullvad, .windows = true, .macos = true, .linux = true },
        .{ .kind = .librewolf, .windows = true, .macos = true, .linux = true },
        .{ .kind = .epic, .windows = true, .macos = true, .linux = true },
        .{ .kind = .arc, .windows = true, .macos = true, .linux = true },
        .{ .kind = .vivaldi, .windows = true, .macos = true, .linux = true },
        .{ .kind = .sigmaos, .windows = false, .macos = true, .linux = false },
        .{ .kind = .sidekick, .windows = true, .macos = true, .linux = true },
        .{ .kind = .shift, .windows = true, .macos = true, .linux = true },
        .{ .kind = .operagx, .windows = true, .macos = true, .linux = true },
        .{ .kind = .palemoon, .windows = true, .macos = true, .linux = true },
    };

    for (cases) |c| {
        const win = path_table.hintsFor(c.kind, .windows);
        const mac = path_table.hintsFor(c.kind, .macos);
        const lin = path_table.hintsFor(c.kind, .linux);

        try std.testing.expectEqual(c.windows, win.confidence_weight > 0);
        try std.testing.expectEqual(c.macos, mac.confidence_weight > 0);
        try std.testing.expectEqual(c.linux, lin.confidence_weight > 0);

        if (c.windows) {
            try std.testing.expect(probeCount(win) > 0);
        }
        if (c.macos) {
            try std.testing.expect(probeCount(mac) > 0);
        }
        if (c.linux) {
            try std.testing.expect(probeCount(lin) > 0);
        }
    }
}

test "protocol endpoint parsing covers major schemes" {
    const cdp = try common.parseEndpoint("cdp://127.0.0.1:9222/devtools/browser/abc", .webdriver);
    try std.testing.expectEqual(common.AdapterKind.cdp, cdp.adapter);
    try std.testing.expectEqual(@as(u16, 9222), cdp.port);
    try std.testing.expect(std.mem.eql(u8, cdp.path, "/devtools/browser/abc"));

    const bidi = try common.parseEndpoint("bidi://localhost/session/1", .webdriver);
    try std.testing.expectEqual(common.AdapterKind.bidi, bidi.adapter);
    try std.testing.expectEqual(@as(u16, 9222), bidi.port);

    const webdriver = try common.parseEndpoint("webdriver://localhost:4444/session/42", .cdp);
    try std.testing.expectEqual(common.AdapterKind.webdriver, webdriver.adapter);
    try std.testing.expectEqual(@as(u16, 4444), webdriver.port);

    try std.testing.expectError(error.InvalidEndpoint, common.parseEndpoint("not-an-endpoint", .webdriver));
}

test "os specific collectors are host-gated" {
    const allocator = std.testing.allocator;

    const win = try windows_registry.collect(allocator, &.{ .chrome, .edge });
    defer {
        for (win) |hit| allocator.free(hit.path);
        allocator.free(win);
    }

    const mac = try macos_apps.collect(allocator, &.{ .safari, .firefox });
    defer {
        for (mac) |hit| allocator.free(hit.path);
        allocator.free(mac);
    }

    const lin = try linux_sources.collect(allocator, &.{ .chrome, .firefox });
    defer {
        for (lin) |hit| allocator.free(hit.path);
        allocator.free(lin);
    }

    const os_tag = @import("builtin").os.tag;
    if (os_tag != .windows) try std.testing.expectEqual(@as(usize, 0), win.len);
    if (os_tag != .macos) try std.testing.expectEqual(@as(usize, 0), mac.len);
    if (os_tag != .linux) try std.testing.expectEqual(@as(usize, 0), lin.len);
}

test "webview kind mappings stay stable" {
    const cases = [_]struct {
        kind: types.WebViewKind,
        expected_engine: types.EngineKind,
        expected_platform: types.WebViewPlatform,
    }{
        .{ .kind = .webview2, .expected_engine = .chromium, .expected_platform = .windows },
        .{ .kind = .wkwebview, .expected_engine = .webkit, .expected_platform = .macos },
        .{ .kind = .webkitgtk, .expected_engine = .webkit, .expected_platform = .linux },
        .{ .kind = .android_webview, .expected_engine = .chromium, .expected_platform = .android },
        .{ .kind = .ios_wkwebview, .expected_engine = .webkit, .expected_platform = .ios },
    };

    for (cases) |c| {
        try std.testing.expectEqual(c.expected_engine, webview_discovery.engineForWebView(c.kind));
        try std.testing.expectEqual(c.expected_platform, webview_discovery.platformForWebView(c.kind));
    }
}

test "desktop webview mappings stay on desktop platforms only" {
    const desktop_kinds = [_]types.WebViewKind{ .webview2, .wkwebview, .webkitgtk };
    for (desktop_kinds) |kind| {
        const platform = webview_discovery.platformForWebView(kind);
        try std.testing.expect(platform == .windows or platform == .macos or platform == .linux);
    }

    try std.testing.expectEqual(types.WebViewPlatform.android, webview_discovery.platformForWebView(.android_webview));
    try std.testing.expectEqual(types.WebViewPlatform.ios, webview_discovery.platformForWebView(.ios_wkwebview));
}
