const std = @import("std");
const types = @import("../types.zig");
const core_runtime = @import("../runtime.zig");
const tier_runtime = @import("../tier/runtime_common.zig");
const session_mod = @import("session.zig");

pub const LegacySession = session_mod.LegacySession;

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) !types.BrowserInstallList {
    return tier_runtime.discoverBrowsersByTier(allocator, prefs, opts, .legacy);
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !LegacySession {
    const base = try tier_runtime.launchByTier(allocator, opts, .legacy);
    return LegacySession.fromBase(base);
}

pub fn attachWebDriver(allocator: std.mem.Allocator, endpoint: []const u8) !LegacySession {
    const base = try tier_runtime.attachByTier(allocator, endpoint, .legacy);
    return LegacySession.fromBase(base);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) !types.WebViewRuntimeList {
    return tier_runtime.discoverWebViewsByTier(allocator, prefs, .legacy);
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !LegacySession {
    const base = try tier_runtime.attachWebViewByTier(allocator, opts, .legacy);
    return LegacySession.fromBase(base);
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !LegacySession {
    const base = try tier_runtime.launchWebViewHostByTier(allocator, opts, .legacy);
    return LegacySession.fromBase(base);
}

pub fn attachIosWebView(
    allocator: std.mem.Allocator,
    opts: types.IosWebViewAttachOptions,
) !LegacySession {
    const base = try core_runtime.attachIosWebView(allocator, opts);
    return LegacySession.fromBase(base);
}

pub fn attachWebKitGtkWebView(
    allocator: std.mem.Allocator,
    opts: types.WebKitGtkWebViewAttachOptions,
) !LegacySession {
    const base = try core_runtime.attachWebKitGtkWebView(allocator, opts);
    return LegacySession.fromBase(base);
}

pub fn launchWebKitGtkWebView(
    allocator: std.mem.Allocator,
    opts: types.WebKitGtkWebViewLaunchOptions,
) !LegacySession {
    const base = try core_runtime.launchWebKitGtkWebView(allocator, opts);
    return LegacySession.fromBase(base);
}
