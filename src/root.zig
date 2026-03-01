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

pub const BrowserKind = types.BrowserKind;
pub const EngineKind = types.EngineKind;
pub const Platform = types.Platform;
pub const ApiTier = types.ApiTier;
pub const WebViewPlatform = types.WebViewPlatform;
pub const ProfileMode = types.ProfileMode;
pub const CancelToken = types.CancelToken;
pub const BrowserPreference = types.BrowserPreference;
pub const DiscoveryOptions = types.DiscoveryOptions;
pub const BrowserInstall = types.BrowserInstall;
pub const BrowserInstallList = types.BrowserInstallList;
pub const LaunchOptions = types.LaunchOptions;
pub const CapabilitySet = types.CapabilitySet;
pub const CapabilityFeature = types.CapabilityFeature;
pub const BrowserInstallSource = types.BrowserInstallSource;
pub const InterceptAction = types.InterceptAction;
pub const NetworkRule = types.NetworkRule;
pub const RequestEvent = types.RequestEvent;
pub const ResponseEvent = types.ResponseEvent;
pub const Cookie = types.Cookie;
pub const CookieQuery = types.CookieQuery;
pub const CookieHeaderOptions = types.CookieHeaderOptions;
pub const Header = types.Header;
pub const StorageValue = types.StorageValue;
pub const StorageArea = types.StorageArea;
pub const StorageKeyQuery = types.StorageKeyQuery;
pub const WaitTarget = types.WaitTarget;
pub const WaitTargetTag = types.WaitTargetTag;
pub const WaitOptions = types.WaitOptions;
pub const WaitResult = types.WaitResult;
pub const TimeoutPhase = types.TimeoutPhase;
pub const TimeoutPolicy = types.TimeoutPolicy;
pub const Diagnostic = types.Diagnostic;
pub const LifecycleEventKind = types.LifecycleEventKind;
pub const LifecycleEvent = types.LifecycleEvent;
pub const EventFilter = types.EventFilter;
pub const SessionCachePayloadMask = types.SessionCachePayloadMask;
pub const SessionCachePreset = types.SessionCachePreset;
pub const SessionCacheOptions = types.SessionCacheOptions;
pub const SessionCacheEntry = types.SessionCacheEntry;
pub const WebViewKind = types.WebViewKind;
pub const WebViewRuntimeSource = types.WebViewRuntimeSource;
pub const WebViewPreference = types.WebViewPreference;
pub const WebViewRuntime = types.WebViewRuntime;
pub const WebViewRuntimeList = types.WebViewRuntimeList;
pub const WebViewAttachOptions = types.WebViewAttachOptions;
pub const WebViewLaunchOptions = types.WebViewLaunchOptions;
pub const AndroidBridgeKind = types.AndroidBridgeKind;
pub const AndroidWebViewAttachOptions = types.AndroidWebViewAttachOptions;
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
pub const SessionCacheStore = @import("session_cache/store.zig").SessionCacheStore;
pub const session_cache = @import("session_cache/store.zig");

pub const modern = modern_api;
pub const support_tier = support_tier_catalog;
pub const strings = @import("util/strings.zig");
pub const path = @import("util/path.zig");

pub const extension_hooks = extensions;
pub const async_api = @import("core/async.zig");

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: BrowserPreference,
    opts: DiscoveryOptions,
) !BrowserInstallList {
    return .{
        .allocator = allocator,
        .items = try runtime.discover(allocator, prefs, opts),
    };
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: WebViewPreference,
) !WebViewRuntimeList {
    return .{
        .allocator = allocator,
        .items = try runtime.discoverWebViews(allocator, prefs),
    };
}

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("alldriver ready. Use modern CDP/BiDi APIs.\n", .{});
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

test "discoverWebViews root API" {
    const allocator = std.testing.allocator;
    var runtimes = try discoverWebViews(allocator, .{
        .kinds = &.{.android_webview},
        .include_path_env = false,
        .include_known_paths = false,
        .include_mobile_bridges = false,
    });
    defer runtimes.deinit();

    try std.testing.expectEqual(@as(usize, 0), runtimes.items.len);
}

test "platform matrix contracts" {
    _ = @import("tests/platform_matrix.zig");
}

test "behavioral matrix contracts" {
    _ = @import("tests/behavioral_matrix.zig");
}
