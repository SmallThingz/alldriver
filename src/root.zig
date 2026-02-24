//! Browser driver library root API.
const std = @import("std");

const catalog = @import("catalog/browser_kind.zig");
const types = @import("types.zig");
const runtime = @import("runtime.zig");
const session_mod = @import("core/session.zig");
const extensions = @import("extensions/api.zig");
const errors = @import("errors.zig");
const support_tier_catalog = @import("catalog/support_tier.zig");
const modern_api = @import("modern/api.zig");
const legacy_api = @import("legacy/api.zig");

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
pub const CapabilityFeature = types.CapabilityFeature;
pub const BrowserInstallSource = types.BrowserInstallSource;
pub const InterceptAction = types.InterceptAction;
pub const NetworkRule = types.NetworkRule;
pub const RequestEvent = types.RequestEvent;
pub const ResponseEvent = types.ResponseEvent;
pub const WebViewKind = types.WebViewKind;
pub const WebViewRuntimeSource = types.WebViewRuntimeSource;
pub const WebViewPreference = types.WebViewPreference;
pub const WebViewRuntime = types.WebViewRuntime;
pub const WebViewAttachOptions = types.WebViewAttachOptions;
pub const WebViewLaunchOptions = types.WebViewLaunchOptions;
pub const AndroidBridgeKind = types.AndroidBridgeKind;
pub const AndroidWebViewAttachOptions = types.AndroidWebViewAttachOptions;
pub const IosWebViewAttachOptions = types.IosWebViewAttachOptions;
pub const WebKitGtkWebViewAttachOptions = types.WebKitGtkWebViewAttachOptions;
pub const WebKitGtkBrowserTarget = types.WebKitGtkBrowserTarget;
pub const WebKitGtkWebViewLaunchOptions = types.WebKitGtkWebViewLaunchOptions;
pub const ElectronWebViewAttachOptions = types.ElectronWebViewAttachOptions;
pub const ElectronWebViewLaunchOptions = types.ElectronWebViewLaunchOptions;

pub const ProtocolError = errors.ProtocolError;
pub const TransportError = errors.TransportError;
pub const CapabilityError = errors.CapabilityError;
pub const TimeoutError = errors.TimeoutError;
pub const DiscoveryError = errors.DiscoveryError;
pub const LaunchError = errors.LaunchError;
pub const WebViewError = errors.WebViewError;
pub const UnsupportedCapabilityInfo = errors.UnsupportedCapabilityInfo;

pub const Session = session_mod.Session;
pub const modern = modern_api;
pub const legacy = legacy_api;
pub const support_tier = support_tier_catalog;

pub const extension_hooks = extensions;
pub const nodriver = @import("compat/nodriver_facade.zig");
pub const async_api = @import("core/async.zig");

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: BrowserPreference,
    opts: DiscoveryOptions,
) ![]BrowserInstall {
    return runtime.discover(allocator, prefs, opts);
}

/// Deprecated shim: prefer `modern.launch` or `legacy.launch`.
pub fn launch(allocator: std.mem.Allocator, opts: LaunchOptions) !Session {
    if (support_tier_catalog.browserTier(opts.install.kind) == .modern) {
        var session = try modern_api.launch(allocator, opts);
        return session.intoBase();
    }

    var session = try legacy_api.launch(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `modern.attach` or `legacy.attachWebDriver`.
pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !Session {
    if (support_tier_catalog.endpointTier(endpoint) == .modern) {
        var session = try modern_api.attach(allocator, endpoint);
        return session.intoBase();
    }

    var session = try legacy_api.attachWebDriver(allocator, endpoint);
    return session.intoBase();
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

/// Deprecated shim: prefer `modern.attachWebView` or `legacy.attachWebView`.
pub fn attachWebView(allocator: std.mem.Allocator, opts: WebViewAttachOptions) !Session {
    if (support_tier_catalog.webViewTier(opts.kind) == .modern) {
        var session = try modern_api.attachWebView(allocator, opts);
        return session.intoBase();
    }

    var session = try legacy_api.attachWebView(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `modern.launchWebViewHost` or `legacy.launchWebViewHost`.
pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: WebViewLaunchOptions) !Session {
    if (support_tier_catalog.webViewTier(opts.kind) == .modern) {
        var session = try modern_api.launchWebViewHost(allocator, opts);
        return session.intoBase();
    }

    var session = try legacy_api.launchWebViewHost(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `modern.attachAndroidWebView`.
pub fn attachAndroidWebView(
    allocator: std.mem.Allocator,
    opts: AndroidWebViewAttachOptions,
) !Session {
    var session = try modern_api.attachAndroidWebView(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `legacy.attachIosWebView`.
pub fn attachIosWebView(
    allocator: std.mem.Allocator,
    opts: IosWebViewAttachOptions,
) !Session {
    var session = try legacy_api.attachIosWebView(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `legacy.attachWebKitGtkWebView`.
pub fn attachWebKitGtkWebView(
    allocator: std.mem.Allocator,
    opts: WebKitGtkWebViewAttachOptions,
) !Session {
    var session = try legacy_api.attachWebKitGtkWebView(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `legacy.launchWebKitGtkWebView`.
pub fn launchWebKitGtkWebView(
    allocator: std.mem.Allocator,
    opts: WebKitGtkWebViewLaunchOptions,
) !Session {
    var session = try legacy_api.launchWebKitGtkWebView(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `modern.attachElectronWebView`.
pub fn attachElectronWebView(
    allocator: std.mem.Allocator,
    opts: ElectronWebViewAttachOptions,
) !Session {
    var session = try modern_api.attachElectronWebView(allocator, opts);
    return session.intoBase();
}

/// Deprecated shim: prefer `modern.launchElectronWebView`.
pub fn launchElectronWebView(
    allocator: std.mem.Allocator,
    opts: ElectronWebViewLaunchOptions,
) !Session {
    var session = try modern_api.launchElectronWebView(allocator, opts);
    return session.intoBase();
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
    try std.testing.expect(s.capabilities().dom);
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

test "platform matrix contracts" {
    _ = @import("tests/platform_matrix.zig");
}

test "behavioral matrix contracts" {
    _ = @import("tests/behavioral_matrix.zig");
}

test "api split contracts" {
    _ = @import("tests/api_split.zig");
}
