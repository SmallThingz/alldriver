//! Browser driver library root API.
const std = @import("std");

const catalog = @import("catalog/browser_kind.zig");
const types = @import("types.zig");
const runtime = @import("runtime.zig");
const session_mod = @import("core/session.zig");
const extensions = @import("extensions/api.zig");

pub const BrowserKind = types.BrowserKind;
pub const EngineKind = types.EngineKind;
pub const Platform = types.Platform;
pub const WebViewPlatform = types.WebViewPlatform;
pub const ProfileMode = types.ProfileMode;
pub const BrowserPreference = types.BrowserPreference;
pub const DiscoveryOptions = types.DiscoveryOptions;
pub const BrowserInstall = types.BrowserInstall;
pub const LaunchOptions = types.LaunchOptions;
pub const CapabilitySet = types.CapabilitySet;
pub const BrowserInstallSource = types.BrowserInstallSource;
pub const WebViewKind = types.WebViewKind;
pub const WebViewRuntimeSource = types.WebViewRuntimeSource;
pub const WebViewPreference = types.WebViewPreference;
pub const WebViewRuntime = types.WebViewRuntime;
pub const WebViewAttachOptions = types.WebViewAttachOptions;
pub const WebViewLaunchOptions = types.WebViewLaunchOptions;

pub const Session = session_mod.Session;

pub const extension_hooks = extensions;
pub const nodriver = @import("compat/nodriver_facade.zig");

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: BrowserPreference,
    opts: DiscoveryOptions,
) ![]BrowserInstall {
    return runtime.discover(allocator, prefs, opts);
}

pub fn launch(allocator: std.mem.Allocator, opts: LaunchOptions) !Session {
    return runtime.launch(allocator, opts);
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !Session {
    return runtime.attach(allocator, endpoint);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: WebViewPreference,
) ![]WebViewRuntime {
    return runtime.discoverWebViews(allocator, prefs);
}

pub fn freeWebViewRuntimes(
    allocator: std.mem.Allocator,
    runtimes: []WebViewRuntime,
) void {
    runtime.freeWebViewRuntimes(allocator, runtimes);
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: WebViewAttachOptions) !Session {
    return runtime.attachWebView(allocator, opts);
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: WebViewLaunchOptions) !Session {
    return runtime.launchWebViewHost(allocator, opts);
}

pub fn freeInstalls(allocator: std.mem.Allocator, installs: []BrowserInstall) void {
    runtime.freeInstalls(allocator, installs);
}

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("browser_driver ready. Use discover()/launch() API.\n", .{});
    try stdout.flush();
}

pub fn engineFor(kind: BrowserKind) EngineKind {
    return catalog.engineFor(kind);
}

test "engine mapping" {
    try std.testing.expect(engineFor(.chrome) == .chromium);
    try std.testing.expect(engineFor(.firefox) == .gecko);
    try std.testing.expect(engineFor(.safari) == .webkit);
}

test "attach via root API" {
    const allocator = std.testing.allocator;
    var s = try attach(allocator, "cdp://127.0.0.1:9222");
    defer s.deinit();
    try std.testing.expect(s.capabilities.dom);
}

test "discoverWebViews root API" {
    const allocator = std.testing.allocator;
    const runtimes = try discoverWebViews(allocator, .{
        .kinds = &.{.android_webview},
        .include_path_env = false,
        .include_known_paths = false,
        .include_mobile_bridges = false,
    });
    defer freeWebViewRuntimes(allocator, runtimes);

    try std.testing.expectEqual(@as(usize, 0), runtimes.len);
}
