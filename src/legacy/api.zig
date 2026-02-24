const std = @import("std");
const types = @import("../types.zig");
const runtime = @import("runtime.zig");
const session_mod = @import("session.zig");

pub const LegacyInstall = types.BrowserInstall;
pub const LegacySession = session_mod.LegacySession;
pub const LegacyWebViewRuntime = types.WebViewRuntime;

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) ![]LegacyInstall {
    return runtime.discover(allocator, prefs, opts);
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !LegacySession {
    return runtime.launch(allocator, opts);
}

pub fn attachWebDriver(allocator: std.mem.Allocator, endpoint: []const u8) !LegacySession {
    return runtime.attachWebDriver(allocator, endpoint);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) ![]LegacyWebViewRuntime {
    return runtime.discoverWebViews(allocator, prefs);
}

pub fn freeWebViewRuntimes(allocator: std.mem.Allocator, runtimes: []LegacyWebViewRuntime) void {
    runtime.freeWebViewRuntimes(allocator, runtimes);
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !LegacySession {
    return runtime.attachWebView(allocator, opts);
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !LegacySession {
    return runtime.launchWebViewHost(allocator, opts);
}

pub fn attachIosWebView(
    allocator: std.mem.Allocator,
    opts: types.IosWebViewAttachOptions,
) !LegacySession {
    return runtime.attachIosWebView(allocator, opts);
}

pub fn attachWebKitGtkWebView(
    allocator: std.mem.Allocator,
    opts: types.WebKitGtkWebViewAttachOptions,
) !LegacySession {
    return runtime.attachWebKitGtkWebView(allocator, opts);
}

pub fn launchWebKitGtkWebView(
    allocator: std.mem.Allocator,
    opts: types.WebKitGtkWebViewLaunchOptions,
) !LegacySession {
    return runtime.launchWebKitGtkWebView(allocator, opts);
}
