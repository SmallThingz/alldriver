# alldriver

> Cross-browser and cross-webview automation for Zig.

[![zig](https://img.shields.io/badge/Zig-0.15.x-orange)](#)
[![platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Linux-blue)](#)
[![protocols](https://img.shields.io/badge/Protocols-CDP%20%7C%20BiDi%20%7C%20WebDriver-green)](#)

`alldriver` is a desktop-first automation framework with explicit modern/legacy API tiers:
- `modern`: CDP + BiDi (`cdp_ws`, `bidi_ws`)
- `legacy`: WebDriver-only (`webdriver_http`)

## Why alldriver
- One library for major desktop browsers + webviews.
- Deterministic discovery with platform probes and known-path catalogs.
- Strong capability/error contracts (typed unsupported behavior, no silent no-ops).
- Built-in matrix/release tooling and adversarial detection gates.

## Safety Boundary
`alldriver` targets standards-compliant automation (testing, QA, scripting).
It does **not** provide bot-detection bypass/evasion primitives.

## Quick Start

```zig
const std = @import("std");
const driver = @import("alldriver");

pub fn run(allocator: std.mem.Allocator) !void {
    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox, .safari },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    const install = installs.items[0];
    if (driver.support_tier.browserTier(install.kind) == .modern) {
        var s = try driver.modern.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
        });
        defer s.deinit();

        var page = s.page();
        try page.navigate("https://example.com");
        try s.base.waitFor(.dom_ready, 30_000);
    } else {
        var s = try driver.legacy.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
        });
        defer s.deinit();

        try s.navigate("https://example.com");
        try s.base.waitFor(.dom_ready, 30_000);
    }
}
```

## API Model

### Discovery ownership
- `discover(...) -> BrowserInstallList`
- `discoverWebViews(...) -> WebViewRuntimeList`
- Caller releases with `.deinit()`.

### Namespace split
- `driver.modern.*` for Chromium/Gecko + CDP-capable webviews.
- `driver.legacy.*` for WebDriver-only browser/webview paths.
- Compatibility facades and root launch/attach shims are removed.

### Modern domains
- `page()`, `runtime()`, `network()`, `input()`, `log()`, `storage()`, `contexts()`, `targets()`

## Browser / WebView Coverage

### Browser tiers
- Tier 1: Chromium family + Firefox + Safari (platform dependent).
- Tier 2: Tor, Mullvad, LibreWolf, Pale Moon, SigmaOS (strict scope depends on runtime exposure).

### Webviews
- `webview2`, `electron`, `android_webview` (modern)
- `wkwebview`, `webkitgtk`, `ios_wkwebview` (legacy)

## External Binary Dependencies

### Core runtime
- Browser binaries (at least one target installed): Chrome/Chromium, Edge, Safari, Firefox, Brave, Tor Browser, DuckDuckGo Browser, Mullvad Browser, LibreWolf, Epic, Arc, Vivaldi, SigmaOS, Sidekick, Shift, Opera GX, Pale Moon.
- Optional Lightpanda support via `-Dinclude_lightpanda_browser=true`.
- Webview/runtime binaries as applicable: `msedgewebview2`, `safaridriver`, `WebKitWebDriver`, `MiniBrowser`, `electron`.
- Mobile bridges: `adb`, `shizuku` (or `rish`), `ios_webkit_debug_proxy`, `tidevice`.

### Tooling / matrix / release (`zig build tools -- ...`)
- Base tooling: `zig`, `git`, `bash`, `tar`, `date`, `which` (or `where` on Windows), `chmod`.
- Signing: `gpg`.
- Remote orchestration: `ssh`, `scp`, `rsync`.
- VM/QEMU workflows: `qemu-system-x86_64`, `qemu-img`, `curl`, `ssh-keygen`.
- Optional checksum verification: `sha256sum`.

## Commands

### Build and test
- `zig build test`
- `zig build examples`

### Gates
- `zig build tools -- adversarial-detection-gate --allow-missing-browser=1`
- `zig build production-gate`
- `zig build tools -- production-gate --strict-ga`

### Matrix / release
- `zig build tools -- matrix-run --platform linux`
- `zig build tools -- matrix-collect`
- `zig build tools -- release-bundle --release-id v1.0.0`

### VM / QEMU helpers
- `zig build tools -- vm-check-prereqs`
- `zig build tools -- vm-image-sources --check`
- `zig build tools -- vm-init-lab --project alldriver`
- `zig build tools -- vm-create-linux --project alldriver --name linux-matrix`
- `zig build tools -- vm-start-linux --project alldriver --name linux-matrix`
- `zig build tools -- vm-run-linux-matrix --project alldriver --name linux-matrix`

## Docs
- `docs/support-matrix.md`
- `docs/path-discovery.md`
- `docs/extensions.md`
- `docs/migration-v1.md`
- `docs/known-limitations.md`
- `docs/vm-matrix.md`
- `docs/vm-image-sources.md`
