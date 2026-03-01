const std = @import("std");
const core_runtime = @import("../runtime.zig");
const core_session = @import("../core/session.zig");
const support_tier = @import("../catalog/support_tier.zig");
const types = @import("../types.zig");

pub fn discoverBrowsersByTier(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
    tier: types.ApiTier,
) !types.BrowserInstallList {
    var list = types.BrowserInstallList{
        .allocator = allocator,
        .items = try core_runtime.discover(allocator, prefs, opts),
    };
    errdefer list.deinit();
    list.retainByTier(tier);
    return list;
}

pub fn discoverWebViewsByTier(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
    tier: types.ApiTier,
) !types.WebViewRuntimeList {
    var list = types.WebViewRuntimeList{
        .allocator = allocator,
        .items = try core_runtime.discoverWebViews(allocator, prefs),
    };
    errdefer list.deinit();
    list.retainByTier(tier);
    return list;
}

pub fn launchByTier(
    allocator: std.mem.Allocator,
    opts: types.LaunchOptions,
    tier: types.ApiTier,
) !core_session.Session {
    if (support_tier.browserTier(opts.install.kind) != tier) return error.UnsupportedEngine;
    return core_runtime.launch(allocator, opts);
}

pub fn attachByTier(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    tier: types.ApiTier,
) !core_session.Session {
    if (support_tier.endpointTier(endpoint) != tier) return error.UnsupportedProtocol;
    return core_runtime.attach(allocator, endpoint);
}

pub fn attachWebViewByTier(
    allocator: std.mem.Allocator,
    opts: types.WebViewAttachOptions,
    tier: types.ApiTier,
) !core_session.Session {
    if (support_tier.webViewTier(opts.kind) != tier) return error.UnsupportedWebViewKind;
    return core_runtime.attachWebView(allocator, opts);
}

pub fn launchWebViewHostByTier(
    allocator: std.mem.Allocator,
    opts: types.WebViewLaunchOptions,
    tier: types.ApiTier,
) !core_session.Session {
    if (support_tier.webViewTier(opts.kind) != tier) return error.UnsupportedWebViewKind;
    return core_runtime.launchWebViewHost(allocator, opts);
}

test "retain-by-tier browser list deinitializes dropped entries" {
    const allocator = std.testing.allocator;
    var list = types.BrowserInstallList{
        .allocator = allocator,
        .items = try allocator.alloc(types.BrowserInstall, 2),
    };
    list.items[0] = .{
        .kind = .chrome,
        .engine = .chromium,
        .path = try allocator.dupe(u8, "chrome-path"),
        .version = try allocator.dupe(u8, "1"),
        .source = .known_path,
    };
    list.items[1] = .{
        .kind = .safari,
        .engine = .webkit,
        .path = try allocator.dupe(u8, "safari-path"),
        .version = try allocator.dupe(u8, "2"),
        .source = .known_path,
    };
    defer list.deinit();

    list.retainByTier(.modern);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(types.BrowserKind.chrome, list.items[0].kind);
}

test "retain-by-tier webview list deinitializes dropped entries" {
    const allocator = std.testing.allocator;
    var list = types.WebViewRuntimeList{
        .allocator = allocator,
        .items = try allocator.alloc(types.WebViewRuntime, 2),
    };
    list.items[0] = .{
        .kind = .electron,
        .engine = .chromium,
        .platform = .linux,
        .runtime_path = try allocator.dupe(u8, "/usr/bin/electron"),
        .bridge_tool_path = null,
        .source = .path_env,
        .version = try allocator.dupe(u8, "1"),
    };
    list.items[1] = .{
        .kind = .webview2,
        .engine = .chromium,
        .platform = .windows,
        .runtime_path = try allocator.dupe(u8, "msedgewebview2"),
        .bridge_tool_path = null,
        .source = .system_framework,
        .version = try allocator.dupe(u8, "2"),
    };
    defer list.deinit();

    list.retainByTier(.modern);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}
