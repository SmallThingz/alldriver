const catalog = @import("catalog/browser_kind.zig");

pub const BrowserKind = catalog.BrowserKind;
pub const EngineKind = catalog.EngineKind;
pub const Platform = catalog.Platform;
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

pub const LaunchOptions = struct {
    install: BrowserInstall,
    profile_mode: ProfileMode,
    profile_dir: ?[]const u8 = null,
    headless: bool = false,
    ignore_tls_errors: bool = false,
    legacy_automation_markers: bool = false,
    gecko_stealth_prefs: bool = false,
    args: []const []const u8 = &.{},
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
