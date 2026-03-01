# alldriver

> Modern browser automation for Zig using CDP and BiDi.

[![zig](https://img.shields.io/badge/Zig-0.15.x-orange)](#)
[![platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Linux-blue)](#)
[![protocols](https://img.shields.io/badge/Protocols-CDP%20%7C%20BiDi-green)](#)

`alldriver` is a library-first automation framework focused on real browser binaries, deterministic discovery, and typed behavior.

## Why

- CDP/BiDi-first API with typed domain clients.
- Deterministic browser/webview discovery across desktop platforms.
- Strong capability and error contracts (explicit unsupported behavior).
- Built-in adversarial, matrix, and GA tooling.

## Safety Boundary

`alldriver` is for standards-compliant automation (testing, QA, scripting).
It does **not** include detection-bypass/evasion primitives.

## Install

```bash
zig fetch --save git+https://github.com/SmallThingz/alldriver
```

Then import in `build.zig.zon` and `build.zig` as usual for Zig dependencies.

## Quick Start

```zig
const std = @import("std");
const driver = @import("alldriver");

pub fn run(allocator: std.mem.Allocator) !void {
    var installs = try driver.modern.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox, .lightpanda },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    var session = try driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 30_000 });
}
```

## API At A Glance

### Discovery ownership

- `discover(...) -> BrowserInstallList`
- `discoverWebViews(...) -> WebViewRuntimeList`
- Caller owns memory and must call `.deinit()`.

### Modern session domains

- `page()`, `runtime()`, `network()`, `input()`, `log()`, `storage()`, `contexts()`, `targets()`

### Waits and cancellation

- `waitFor(target, opts)` + `waitForAsync(target, opts)`
- Targets: `dom_ready`, `network_idle`, `selector_visible`, `url_contains`, `cookie_present`, `storage_key_present`, `js_truthy`
- `CancelToken` for cooperative cancel.

### Events

- `onEvent(filter, callback)` / `offEvent(id)`
- Event kinds: `navigation_started`, `navigation_completed`, `challenge_detected`, `challenge_solved`, `cookie_updated`

### Timeouts and diagnostics

- `setTimeoutPolicy`, `timeoutPolicy`, `lastDiagnostic`

### Cookie helpers

- `queryCookies`
- `buildCookieHeaderForUrl`

### Session cache

- `SessionCacheStore.open/load/save/saveWithOptions/invalidate/cleanupExpired`
- Payload presets:
  - `.minimal` (cookies)
  - `.http_session` (cookies + user agent)
  - `.rich_state` (cookies + user agent + storage + url + extra headers)
- Custom combinations via `SessionCachePayloadMask`.

## Coverage

### Modern (supported)

- Chromium-family browsers via CDP
- Firefox/Gecko via BiDi
- CDP-capable webviews: `webview2`, `electron`, `android_webview`

### Unsupported tier (discovered/classified, not driven)

- Targets without usable CDP/BiDi surfaces on the host.

## External Binary Dependencies

### Core runtime

- Browser binaries (at least one target installed): Chrome/Chromium, Edge, Firefox, Brave, Tor Browser, DuckDuckGo Browser, Mullvad Browser, LibreWolf, Epic, Arc, Vivaldi, SigmaOS, Sidekick, Shift, Opera GX, Pale Moon.
- Optional Lightpanda support via `-Dinclude_lightpanda_browser=true`.
- Webview/runtime binaries as applicable: `msedgewebview2`, `electron`.
- Mobile bridge tooling: `adb`, `shizuku` (or `rish`) for Android WebView.
- Managed cache tooling (only when using managed downloads): `curl` for `https://` payloads, `tar`/`unzip` for archive payload extraction.

### Tooling / matrix / release (`zig build tools -- ...`)

- Base tooling: `zig`, `git`, `bash`, `tar`, `date`, `which` (or `where` on Windows), `chmod`.
- Signing: `gpg`.
- Remote orchestration: `ssh`, `scp`, `rsync`.
- VM/QEMU workflows: `qemu-system-x86_64`, `qemu-img`, `curl`, `ssh-keygen`.
- Optional checksum verification: `sha256sum`.

## Common Commands

```bash
# Build + tests
zig build test
zig build examples

# Tool self-check
zig build tools -- self-test

# Gates
zig build tools -- adversarial-detection-gate --allow-missing-browser=1
zig build production-gate
zig build tools -- production-gate --strict-ga

# Matrix + release
zig build tools -- matrix-run --platform linux
zig build tools -- matrix-collect
zig build tools -- release-bundle --release-id v1.0.0

# VM / QEMU helpers
zig build tools -- vm-check-prereqs
zig build tools -- vm-image-sources --check
zig build tools -- vm-init-lab --project alldriver
zig build tools -- vm-create-linux --project alldriver --name linux-matrix
zig build tools -- vm-start-linux --project alldriver --name linux-matrix
zig build tools -- vm-run-linux-matrix --project alldriver --name linux-matrix
```

## Examples

See `/home/a/projects/zig/browser_driver/examples/README.md` for runnable examples.

## Docs

- `/home/a/projects/zig/browser_driver/DOCUMENTATION.md`
- `/home/a/projects/zig/browser_driver/CONTRIBUTING.md`
- `/home/a/projects/zig/browser_driver/SECURITY.md`
