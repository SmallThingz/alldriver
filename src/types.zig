const std = @import("std");
const catalog = @import("catalog/browser_kind.zig");
const cancel_mod = @import("core/cancel.zig");

pub const BrowserKind = catalog.BrowserKind;
pub const EngineKind = catalog.EngineKind;
pub const Platform = catalog.Platform;
pub const CancelToken = cancel_mod.CancelToken;
pub const ApiTier = enum {
    modern,
    legacy,
};
pub const WebViewPlatform = enum {
    windows,
    macos,
    linux,
    android,
    ios,
};

pub const WebViewKind = enum {
    webview2,
    wkwebview,
    webkitgtk,
    electron,
    android_webview,
    ios_wkwebview,
};

pub const ProfileMode = enum {
    persistent,
    ephemeral,
};

pub const BrowserPreference = struct {
    kinds: []const BrowserKind,
    channel: ?[]const u8 = null,
    explicit_path: ?[]const u8 = null,
    allow_managed_download: bool = false,
    managed_cache_dir: ?[]const u8 = null,
};

pub const DiscoveryOptions = struct {
    include_path_env: bool = true,
    include_os_probes: bool = true,
    include_known_paths: bool = true,
};

pub const BrowserInstallSource = enum {
    explicit,
    path_env,
    known_path,
    registry,
    app_bundle,
    package_db,
    managed_cache,
};

pub const BrowserInstall = struct {
    kind: BrowserKind,
    engine: EngineKind,
    path: []const u8,
    version: ?[]const u8 = null,
    source: BrowserInstallSource,
};

pub const BrowserInstallList = struct {
    allocator: std.mem.Allocator,
    items: []BrowserInstall,
    owned_len: usize = 0,

    pub fn deinit(self: *BrowserInstallList) void {
        for (self.items) |install| {
            self.allocator.free(install.path);
            if (install.version) |version| self.allocator.free(version);
        }
        const owned_len = if (self.owned_len == 0) self.items.len else self.owned_len;
        self.allocator.free(self.items.ptr[0..owned_len]);
        self.* = undefined;
    }

    pub fn retainByTier(self: *BrowserInstallList, tier: ApiTier) void {
        if (self.owned_len == 0) self.owned_len = self.items.len;
        var write_index: usize = 0;
        var read_index: usize = 0;
        while (read_index < self.items.len) : (read_index += 1) {
            const install = self.items[read_index];
            if (browserTierForKind(install.kind) != tier) {
                self.allocator.free(install.path);
                if (install.version) |version| self.allocator.free(version);
                continue;
            }
            if (write_index != read_index) self.items[write_index] = install;
            write_index += 1;
        }
        self.items = self.items[0..write_index];
    }
};

pub const LaunchOptions = struct {
    install: BrowserInstall,
    profile_mode: ProfileMode,
    profile_dir: ?[]const u8 = null,
    headless: bool = false,
    ignore_tls_errors: bool = false,
    legacy_automation_markers: bool = false,
    gecko_stealth_prefs: bool = false,
    timeout_policy: ?TimeoutPolicy = null,
    args: []const []const u8 = &.{},
};

pub const TimeoutPhase = enum {
    launch,
    attach,
    navigate,
    wait,
    storage,
    network,
    overall,
};

pub const TimeoutPolicy = struct {
    launch_ms: u32 = 15_000,
    attach_ms: u32 = 10_000,
    navigate_ms: u32 = 30_000,
    wait_ms: u32 = 30_000,
    network_ms: u32 = 15_000,
    overall_ms: ?u32 = null,
};

pub const Diagnostic = struct {
    phase: TimeoutPhase,
    code: []const u8,
    message: []const u8,
    transport: ?[]const u8 = null,
    elapsed_ms: ?u32 = null,
};

pub const CapabilitySet = struct {
    dom: bool,
    js_eval: bool,
    network_intercept: bool,
    tracing: bool,
    downloads: bool,
    bidi_events: bool,
};

pub const CapabilityFeature = enum {
    dom,
    js_eval,
    network_intercept,
    tracing,
    downloads,
    bidi_events,
};

pub const InterceptActionKind = enum {
    block,
    continue_request,
    fulfill,
    modify,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const StorageValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const CookieSameSite = enum {
    unspecified,
    lax,
    strict,
    none,
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    secure: bool = true,
    http_only: bool = true,
    expires_unix_seconds: ?i64 = null,
    same_site: CookieSameSite = .unspecified,
};

pub const CookieQuery = struct {
    name: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure_only: bool = false,
    include_expired: bool = false,
    include_http_only: bool = true,
};

pub const CookieHeaderOptions = struct {
    sort_by_path_len_desc: bool = true,
    include_http_only: bool = true,
};

pub const StorageArea = enum {
    local,
    session,
    either,
};

pub const StorageKeyQuery = struct {
    key: []const u8,
    area: StorageArea = .either,
};

pub const WaitTarget = union(enum) {
    dom_ready: void,
    network_idle: void,
    selector_visible: []const u8,
    url_contains: []const u8,
    cookie_present: CookieQuery,
    storage_key_present: StorageKeyQuery,
    js_truthy: []const u8,
};

pub const WaitTargetTag = std.meta.Tag(WaitTarget);

pub const WaitOptions = struct {
    timeout_ms: ?u32 = null,
    poll_interval_ms: u32 = 100,
    cancel_token: ?*CancelToken = null,
};

pub const WaitResult = struct {
    matched: bool,
    elapsed_ms: u32,
    target: WaitTargetTag,
};

pub const LifecycleEventKind = enum {
    navigation_started,
    navigation_completed,
    challenge_detected,
    challenge_solved,
    cookie_updated,
};

pub const LifecycleEvent = union(LifecycleEventKind) {
    navigation_started: struct { url: []const u8 },
    navigation_completed: struct { url: []const u8 },
    challenge_detected: struct { url: []const u8, signal: []const u8 },
    challenge_solved: struct { url: []const u8 },
    cookie_updated: struct { domain: []const u8, name: []const u8 },
};

pub const EventFilter = struct {
    domain: ?[]const u8 = null,
    kinds: []const LifecycleEventKind = &.{},
};

pub const SessionCachePayloadMask = struct {
    cookies: bool = true,
    user_agent: bool = true,
    local_storage: bool = false,
    session_storage: bool = false,
    current_url: bool = false,
    extra_headers: bool = false,
};

pub const SessionCachePreset = enum {
    minimal,
    http_session,
    rich_state,
};

pub const SessionCacheOptions = struct {
    preset: ?SessionCachePreset = null,
    include: ?SessionCachePayloadMask = null,
};

pub const SessionCacheEntry = struct {
    domain: []const u8,
    profile_key: []const u8,
    user_agent: []const u8,
    cookies: []Cookie = &.{},
    local_storage: []StorageValue = &.{},
    session_storage: []StorageValue = &.{},
    current_url: ?[]const u8 = null,
    extra_headers: []Header = &.{},
    captured_at_ms: u64,
    expires_at_ms: ?u64,
    schema_version: u32,
};

pub const InterceptAction = union(InterceptActionKind) {
    block: void,
    continue_request: void,
    fulfill: struct {
        status: u16,
        body: []const u8 = "",
        headers: []const Header = &.{},
    },
    modify: struct {
        add_headers: []const Header = &.{},
        remove_header_names: []const []const u8 = &.{},
    },
};

pub const NetworkRule = struct {
    id: []const u8,
    url_pattern: []const u8,
    action: InterceptAction,
};

pub const RequestEvent = struct {
    request_id: []const u8,
    method: []const u8,
    url: []const u8,
    headers_json: []const u8,
};

pub const ResponseEvent = struct {
    request_id: []const u8,
    status: u16,
    url: []const u8,
    headers_json: []const u8,
};

pub const WebViewRuntimeSource = enum {
    explicit,
    path_env,
    known_path,
    system_framework,
    package_db,
    bridge_tool,
};

pub const WebViewPreference = struct {
    kinds: []const WebViewKind = &.{},
    explicit_runtime_path: ?[]const u8 = null,
    include_path_env: bool = true,
    include_known_paths: bool = true,
    include_mobile_bridges: bool = true,
};

pub const WebViewRuntime = struct {
    kind: WebViewKind,
    engine: EngineKind,
    platform: WebViewPlatform,
    runtime_path: ?[]const u8 = null,
    bridge_tool_path: ?[]const u8 = null,
    source: WebViewRuntimeSource,
    version: ?[]const u8 = null,
};

pub const WebViewRuntimeList = struct {
    allocator: std.mem.Allocator,
    items: []WebViewRuntime,
    owned_len: usize = 0,

    pub fn deinit(self: *WebViewRuntimeList) void {
        for (self.items) |runtime| {
            if (runtime.runtime_path) |path| self.allocator.free(path);
            if (runtime.bridge_tool_path) |path| self.allocator.free(path);
            if (runtime.version) |version| self.allocator.free(version);
        }
        const owned_len = if (self.owned_len == 0) self.items.len else self.owned_len;
        self.allocator.free(self.items.ptr[0..owned_len]);
        self.* = undefined;
    }

    pub fn retainByTier(self: *WebViewRuntimeList, tier: ApiTier) void {
        if (self.owned_len == 0) self.owned_len = self.items.len;
        var write_index: usize = 0;
        var read_index: usize = 0;
        while (read_index < self.items.len) : (read_index += 1) {
            const runtime = self.items[read_index];
            if (webViewTierForKind(runtime.kind) != tier) {
                if (runtime.runtime_path) |path| self.allocator.free(path);
                if (runtime.bridge_tool_path) |path| self.allocator.free(path);
                if (runtime.version) |version| self.allocator.free(version);
                continue;
            }
            if (write_index != read_index) self.items[write_index] = runtime;
            write_index += 1;
        }
        self.items = self.items[0..write_index];
    }
};

pub const WebViewAttachOptions = struct {
    kind: WebViewKind,
    endpoint: []const u8,
};

pub const WebViewLaunchOptions = struct {
    kind: WebViewKind,
    host_executable: []const u8,
    legacy_automation_markers: bool = false,
    args: []const []const u8 = &.{},
    endpoint: ?[]const u8 = null,
};

pub const AndroidBridgeKind = enum {
    adb,
    shizuku,
    direct,
};

pub const AndroidWebViewAttachOptions = struct {
    device_id: []const u8,
    bridge_kind: AndroidBridgeKind = .adb,
    host: []const u8 = "127.0.0.1",
    port: u16 = 9222,
    socket_name: ?[]const u8 = null,
    pid: ?u32 = null,
    endpoint: ?[]const u8 = null,
};

pub const IosWebViewAttachOptions = struct {
    udid: []const u8,
    app_bundle_id: ?[]const u8 = null,
    page_id: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
};

pub const WebKitGtkWebViewAttachOptions = struct {
    endpoint: ?[]const u8 = null,
    host: []const u8 = "127.0.0.1",
    port: u16 = 4444,
    session_id: ?[]const u8 = null,
};

pub const WebKitGtkBrowserTarget = enum {
    auto,
    minibrowser,
    custom_binary,
};

pub const WebKitGtkWebViewLaunchOptions = struct {
    driver_executable_path: ?[]const u8 = null,
    host: []const u8 = "127.0.0.1",
    port: ?u16 = null,
    replace_on_new_session: bool = true,
    profile_mode: ProfileMode = .ephemeral,
    profile_dir: ?[]const u8 = null,
    ignore_tls_errors: bool = false,
    driver_args: []const []const u8 = &.{},
    browser_target: WebKitGtkBrowserTarget = .auto,
    browser_binary_path: ?[]const u8 = null,
    browser_args: []const []const u8 = &.{},
    session_create_timeout_ms: u32 = 30_000,
    session_capabilities_json: ?[]const u8 = null,
};

pub const ElectronWebViewAttachOptions = struct {
    endpoint: ?[]const u8 = null,
    host: []const u8 = "127.0.0.1",
    port: u16 = 9222,
};

pub const ElectronWebViewLaunchOptions = struct {
    executable_path: []const u8,
    app_path: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    debug_port: ?u16 = null,
    profile_mode: ProfileMode = .ephemeral,
    profile_dir: ?[]const u8 = null,
    headless: bool = false,
    ignore_tls_errors: bool = false,
    legacy_automation_markers: bool = false,
};

pub const DiscoveryError = error{
    OutOfMemory,
    InvalidExplicitPath,
};

pub const LaunchError = error{
    OutOfMemory,
    UnsupportedEngine,
    SpawnFailed,
    PersistentProfileDirRequired,
};

fn browserTierForKind(kind: BrowserKind) ApiTier {
    return switch (catalog.engineFor(kind)) {
        .chromium, .gecko => .modern,
        .webkit, .unknown => .legacy,
    };
}

fn webViewTierForKind(kind: WebViewKind) ApiTier {
    return switch (kind) {
        .webview2, .electron, .android_webview => .modern,
        .wkwebview, .webkitgtk, .ios_wkwebview => .legacy,
    };
}
