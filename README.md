# browser_driver (Zig)

`browser_driver` is a desktop-focused browser automation framework in Zig.

## What It Provides
- Cross-browser desktop discovery for Windows/macOS/Linux.
- Cross-platform webview runtime discovery (WebView2, WKWebView, WebKitGTK, Android/iOS bridge tooling).
- Engine-tier automation architecture (Chromium, Gecko, WebKit).
- Hybrid protocol surface (CDP, WebDriver, BiDi) with capability negotiation.
- Optional managed browser cache discovery (`allow_managed_download` + configurable cache dir).
- Idiomatic Zig API plus a nodriver-style compatibility facade.
- Compile-time extension hooks (no runtime plugin loader).

## WebView Support
- Discover runtimes and bridge tools with `discoverWebViews(...)`.
- Attach to an existing webview debug endpoint with `attachWebView(...)`.
- Launch a host app and manage it as a session with `launchWebViewHost(...)`.

## Safety Boundary
This project targets legitimate automation workflows (testing, QA, scripted browser operations).
It does not guarantee bypass of bot-detection systems and does not ship explicit evasion primitives.

## Quick Start
```zig
const std = @import("std");
const driver = @import("browser_driver");

pub fn run(allocator: std.mem.Allocator) !void {
    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox, .safari },
        .allow_managed_download = false,
    }, .{});
    defer driver.freeInstalls(allocator, installs);

    if (installs.len == 0) return error.NoBrowserFound;

    var session = try driver.launch(allocator, .{
        .install = installs[0],
        .profile_mode = .ephemeral,
        .headless = false,
    });
    defer session.deinit();

    try session.navigate("https://example.com");
    try session.waitFor(.dom_ready, 30_000);
}
```

## Build Option
Use `-Denable_builtin_extension=true` to enable the built-in compile-time extension adapter.

## Docs
- `docs/support-matrix.md`
- `docs/path-discovery.md`
- `docs/compat-nodriver.md`
- `docs/extensions.md`
