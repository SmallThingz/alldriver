# alldriver

> Cross-browser and cross-webview automation for Zig.

[![zig](https://img.shields.io/badge/Zig-0.15.x-orange)](#)
[![platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Linux-blue)](#)
[![protocols](https://img.shields.io/badge/Protocols-CDP%20%7C%20BiDi-green)](#)

`alldriver` is a desktop-first automation framework with a modern protocol surface:
- `modern`: CDP + BiDi (`cdp_ws`, `bidi_ws`)

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
        .kinds = &.{ .chrome, .firefox, .lightpanda },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    const install = installs.items[0];
    if (driver.support_tier.browserTier(install.kind) != .modern) return error.UnsupportedEngine;

    var s = try driver.modern.launch(allocator, .{
        .install = install,
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer s.deinit();

    var page = s.page();
    try page.navigate("https://example.com");
    _ = try s.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 30_000 });
}
```

## API Model

### Discovery ownership
- `discover(...) -> BrowserInstallList`
- `discoverWebViews(...) -> WebViewRuntimeList`
- Caller releases with `.deinit()`.

### Namespace
- `driver.modern.*` for Chromium/Gecko + CDP-capable webviews.
- Legacy WebDriver namespace was removed.

### Modern domains
- `page()`, `runtime()`, `network()`, `input()`, `log()`, `storage()`, `contexts()`, `targets()`

### Wait / events / cache primitives
- `Session.waitFor(target, opts)` and `Session.waitForAsync(target, opts)` support:
  `dom_ready`, `network_idle`, `selector_visible`, `url_contains`, `cookie_present`, `storage_key_present`, `js_truthy`.
- Compatibility wait helpers were removed; use `waitFor(.{ .selector_visible = "..." }, ...)`.
- `CancelToken` enables cooperative cancellation for sync/async waits.
- Lifecycle hooks:
  `onEvent(filter, callback)` / `offEvent(id)` with event kinds:
  `navigation_started`, `navigation_completed`, `challenge_detected`, `challenge_solved`, `cookie_updated`.
- Timeout/diagnostics:
  `setTimeoutPolicy`, `timeoutPolicy`, `lastDiagnostic` with phase-tagged diagnostics.
- Typed cookie helpers:
  `queryCookies` and `buildCookieHeaderForUrl`.
- Built-in session cache:
  `SessionCacheStore.open/load/save/saveWithOptions/invalidate/cleanupExpired`.

### Session cache payload options (v1)
- Default recommended payload: `cookies + user_agent` (`preset = .http_session`).
- Presets:
  - `.minimal`: cookies only
  - `.http_session`: cookies + user agent
  - `.rich_state`: cookies + user agent + storage + URL + extra headers
- Any combination is supported with `SessionCacheOptions.include` (`SessionCachePayloadMask`).
  The `include` mask allows enabling/disabling each payload component explicitly.

## Browser / WebView Coverage

### Browser tiers
- Tier 1: Chromium family + Firefox (platform dependent).
- Tier 2: Tor, Mullvad, LibreWolf, Pale Moon, SigmaOS (runtime exposure dependent).

### Webviews
- `webview2`, `electron`, `android_webview`

## External Binary Dependencies

### Core runtime
- Browser binaries (at least one target installed): Chrome/Chromium, Edge, Safari, Firefox, Brave, Tor Browser, DuckDuckGo Browser, Mullvad Browser, LibreWolf, Epic, Arc, Vivaldi, SigmaOS, Sidekick, Shift, Opera GX, Pale Moon.
- Optional Lightpanda support via `-Dinclude_lightpanda_browser=true`.
- Webview/runtime binaries as applicable: `msedgewebview2`, `electron`.
- Mobile bridges: `adb`, `shizuku` (or `rish`) for Android WebView.

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
