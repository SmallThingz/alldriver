const std = @import("std");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const common = @import("../protocol/common.zig");
const types = @import("../types.zig");
const support_tier = @import("../catalog/support_tier.zig");
const windows_registry = @import("../discovery/windows_registry.zig");
const macos_apps = @import("../discovery/macos_apps.zig");
const linux_sources = @import("../discovery/linux_sources.zig");
const webview_discovery = @import("../discovery/webview/discover.zig");
const strings = @import("../util/strings.zig");

fn probeCount(hints: path_table.BrowserPathHints) usize {
    return hints.executable_names.len + hints.known_paths.len + hints.mac_bundle_ids.len + hints.windows_registry_hints.len + hints.linux_package_hints.len;
}

test "path table invariants hold across platforms" {
    const platforms = [_]catalog.Platform{ .windows, .macos, .linux };
    for (path_table.all_browser_kinds) |kind| {
        for (platforms) |platform| {
            const hints = path_table.hintsFor(kind, platform);
            try std.testing.expectEqual(kind, hints.kind);
            try std.testing.expectEqual(platform, hints.platform);
            try std.testing.expectEqual(catalog.engineFor(kind), hints.engine);
        }
    }
}

test "lightpanda has cross-platform path hints" {
    try std.testing.expect(path_table.hintsFor(.lightpanda, .windows).confidence_weight > 0);
    try std.testing.expect(path_table.hintsFor(.lightpanda, .macos).confidence_weight > 0);
    try std.testing.expect(path_table.hintsFor(.lightpanda, .linux).confidence_weight > 0);
}

test "protocol endpoint parsing supports cdp and bidi only" {
    const cdp_endpoint = try common.parseEndpoint("cdp://127.0.0.1:9222/devtools/browser/abc", .cdp);
    try std.testing.expectEqual(common.AdapterKind.cdp, cdp_endpoint.adapter);
    try std.testing.expectEqual(@as(u16, 9222), cdp_endpoint.port);

    const bidi_endpoint = try common.parseEndpoint("bidi://localhost:9223/session/1", .cdp);
    try std.testing.expectEqual(common.AdapterKind.bidi, bidi_endpoint.adapter);
    try std.testing.expectEqual(@as(u16, 9223), bidi_endpoint.port);

    try std.testing.expectError(error.UnsupportedProtocol, common.parseEndpoint("http://127.0.0.1:4444/session/1", .cdp));
    try std.testing.expectError(error.InvalidEndpoint, common.parseEndpoint("not-an-endpoint", .cdp));
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

test "modern webview mapping is stable" {
    const cases = [_]struct {
        kind: types.WebViewKind,
        platform: types.WebViewPlatform,
    }{
        .{ .kind = .webview2, .platform = .windows },
        .{ .kind = .electron, .platform = webview_discovery.platformForWebView(.electron) },
        .{ .kind = .android_webview, .platform = .android },
    };
    for (cases) |c| {
        try std.testing.expectEqual(types.EngineKind.chromium, webview_discovery.engineForWebView(c.kind));
        try std.testing.expectEqual(c.platform, webview_discovery.platformForWebView(c.kind));
        try std.testing.expectEqual(types.ApiTier.modern, support_tier.webViewTier(c.kind));
    }
}

test "browser tier is modern for chromium/gecko and unsupported for webkit/unknown" {
    for (path_table.all_browser_kinds) |kind| {
        const tier = support_tier.browserTier(kind);
        const engine = catalog.engineFor(kind);
        switch (engine) {
            .chromium, .gecko => try std.testing.expectEqual(types.ApiTier.modern, tier),
            .webkit, .unknown => try std.testing.expectEqual(types.ApiTier.unsupported, tier),
        }
    }
}

test "browser hints do not include standalone driver binaries" {
    const forbidden = [_][]const u8{ "chromedriver", "geckodriver", "msedgedriver" };
    const platforms = [_]catalog.Platform{ .windows, .macos, .linux };
    for (path_table.all_browser_kinds) |kind| {
        for (platforms) |platform| {
            const hints = path_table.hintsFor(kind, platform);
            if (hints.confidence_weight == 0 and probeCount(hints) == 0) continue;
            for (hints.executable_names) |entry| {
                for (forbidden) |name| {
                    try std.testing.expect(!strings.containsIgnoreCase(entry, name));
                }
            }
        }
    }
}
