const std = @import("std");
const types = @import("../types.zig");
const runtime = @import("runtime.zig");
const session_mod = @import("session.zig");

pub const ModernInstall = types.BrowserInstall;
pub const ModernSession = session_mod.ModernSession;
pub const ModernWebViewRuntime = types.WebViewRuntime;

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) ![]ModernInstall {
    return runtime.discover(allocator, prefs, opts);
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !ModernSession {
    return runtime.launch(allocator, opts);
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !ModernSession {
    return runtime.attach(allocator, endpoint);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) ![]ModernWebViewRuntime {
    return runtime.discoverWebViews(allocator, prefs);
}

pub fn freeWebViewRuntimes(allocator: std.mem.Allocator, runtimes: []ModernWebViewRuntime) void {
    runtime.freeWebViewRuntimes(allocator, runtimes);
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !ModernSession {
    return runtime.attachWebView(allocator, opts);
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !ModernSession {
    return runtime.launchWebViewHost(allocator, opts);
}

pub fn attachAndroidWebView(
    allocator: std.mem.Allocator,
    opts: types.AndroidWebViewAttachOptions,
) !ModernSession {
    return runtime.attachAndroidWebView(allocator, opts);
}

pub fn attachElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewAttachOptions,
) !ModernSession {
    return runtime.attachElectronWebView(allocator, opts);
}

pub fn launchElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewLaunchOptions,
) !ModernSession {
    return runtime.launchElectronWebView(allocator, opts);
}
