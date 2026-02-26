const std = @import("std");
const types = @import("../types.zig");
const core_runtime = @import("../runtime.zig");
const tier_runtime = @import("../tier/runtime_common.zig");
const session_mod = @import("session.zig");

pub const ModernSession = session_mod.ModernSession;

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) !types.BrowserInstallList {
    return tier_runtime.discoverBrowsersByTier(allocator, prefs, opts, .modern);
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !ModernSession {
    const base = try tier_runtime.launchByTier(allocator, opts, .modern);
    return ModernSession.fromBase(base);
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !ModernSession {
    const base = try tier_runtime.attachByTier(allocator, endpoint, .modern);
    return ModernSession.fromBase(base);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) !types.WebViewRuntimeList {
    return tier_runtime.discoverWebViewsByTier(allocator, prefs, .modern);
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !ModernSession {
    const base = try tier_runtime.attachWebViewByTier(allocator, opts, .modern);
    return ModernSession.fromBase(base);
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !ModernSession {
    const base = try tier_runtime.launchWebViewHostByTier(allocator, opts, .modern);
    return ModernSession.fromBase(base);
}

pub fn attachAndroidWebView(
    allocator: std.mem.Allocator,
    opts: types.AndroidWebViewAttachOptions,
) !ModernSession {
    const base = try core_runtime.attachAndroidWebView(allocator, opts);
    return ModernSession.fromBase(base);
}

pub fn attachElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewAttachOptions,
) !ModernSession {
    const base = try core_runtime.attachElectronWebView(allocator, opts);
    return ModernSession.fromBase(base);
}

pub fn launchElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewLaunchOptions,
) !ModernSession {
    const base = try core_runtime.launchElectronWebView(allocator, opts);
    return ModernSession.fromBase(base);
}
