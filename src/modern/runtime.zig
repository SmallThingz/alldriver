const std = @import("std");
const types = @import("../types.zig");
const runtime = @import("../runtime.zig");
const support_tier = @import("../catalog/support_tier.zig");
const session_mod = @import("session.zig");

pub const ModernSession = session_mod.ModernSession;

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) ![]types.BrowserInstall {
    const installs = try runtime.discover(allocator, prefs, opts);
    errdefer runtime.freeInstalls(allocator, installs);

    var count: usize = 0;
    for (installs) |install| {
        if (support_tier.browserTier(install.kind) == .modern) count += 1;
    }

    const filtered = try allocator.alloc(types.BrowserInstall, count);
    var idx: usize = 0;
    for (installs) |install| {
        if (support_tier.browserTier(install.kind) != .modern) continue;
        filtered[idx] = .{
            .kind = install.kind,
            .engine = install.engine,
            .path = try allocator.dupe(u8, install.path),
            .version = if (install.version) |v| try allocator.dupe(u8, v) else null,
            .source = install.source,
        };
        idx += 1;
    }

    runtime.freeInstalls(allocator, installs);
    return filtered;
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !ModernSession {
    if (support_tier.browserTier(opts.install.kind) != .modern) return error.UnsupportedEngine;
    const base = try runtime.launch(allocator, opts);
    return ModernSession.fromBase(base);
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !ModernSession {
    if (support_tier.endpointTier(endpoint) != .modern) return error.UnsupportedProtocol;
    const base = try runtime.attach(allocator, endpoint);
    return ModernSession.fromBase(base);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) ![]types.WebViewRuntime {
    const runtimes = try runtime.discoverWebViews(allocator, prefs);
    errdefer runtime.freeWebViewRuntimes(allocator, runtimes);

    var count: usize = 0;
    for (runtimes) |entry| {
        if (support_tier.webViewTier(entry.kind) == .modern) count += 1;
    }

    const filtered = try allocator.alloc(types.WebViewRuntime, count);
    var idx: usize = 0;
    for (runtimes) |entry| {
        if (support_tier.webViewTier(entry.kind) != .modern) continue;
        filtered[idx] = .{
            .kind = entry.kind,
            .engine = entry.engine,
            .platform = entry.platform,
            .runtime_path = if (entry.runtime_path) |path| try allocator.dupe(u8, path) else null,
            .bridge_tool_path = if (entry.bridge_tool_path) |path| try allocator.dupe(u8, path) else null,
            .source = entry.source,
            .version = if (entry.version) |v| try allocator.dupe(u8, v) else null,
        };
        idx += 1;
    }

    runtime.freeWebViewRuntimes(allocator, runtimes);
    return filtered;
}

pub fn freeWebViewRuntimes(allocator: std.mem.Allocator, runtimes: []types.WebViewRuntime) void {
    runtime.freeWebViewRuntimes(allocator, runtimes);
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !ModernSession {
    if (support_tier.webViewTier(opts.kind) != .modern) return error.UnsupportedWebViewKind;
    const base = try runtime.attachWebView(allocator, opts);
    return ModernSession.fromBase(base);
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !ModernSession {
    if (support_tier.webViewTier(opts.kind) != .modern) return error.UnsupportedWebViewKind;
    const base = try runtime.launchWebViewHost(allocator, opts);
    return ModernSession.fromBase(base);
}

pub fn attachAndroidWebView(
    allocator: std.mem.Allocator,
    opts: types.AndroidWebViewAttachOptions,
) !ModernSession {
    const base = try runtime.attachAndroidWebView(allocator, opts);
    return ModernSession.fromBase(base);
}

pub fn attachElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewAttachOptions,
) !ModernSession {
    const base = try runtime.attachElectronWebView(allocator, opts);
    return ModernSession.fromBase(base);
}

pub fn launchElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewLaunchOptions,
) !ModernSession {
    const base = try runtime.launchElectronWebView(allocator, opts);
    return ModernSession.fromBase(base);
}
