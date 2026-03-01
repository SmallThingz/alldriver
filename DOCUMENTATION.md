# DOCUMENTATION

This file is the canonical project documentation for `alldriver`.

## Overview

`alldriver` is a Zig browser automation library with a modern protocol contract:

- Browser protocols: CDP and BiDi only
- Public session namespace: `driver.modern.*`
- Supported webview targets: `webview2`, `electron`, `android_webview`

The project is standards-compliant automation only and does not implement detection-evasion primitives.

## Quick Start

```zig
const std = @import("std");
const driver = @import("alldriver");

pub fn run(allocator: std.mem.Allocator) !void {
    var session = try driver.modern.launchAuto(allocator, .{
        .kinds = &.{ .chrome, .firefox, .lightpanda },
        .allow_managed_download = false,
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 30_000 });
}
```

## API Model

### Ownership

- `discover(...) -> BrowserInstallList`
- `discoverWebViews(...) -> WebViewRuntimeList`
- Caller owns the returned lists and must call `.deinit()`.
- `launchAuto(...)` / `launchAutoAsync(...)` run discovery with sane defaults and return a fully ready session.

### Modern session domains

- `page()`, `runtime()`, `network()`, `input()`, `log()`, `storage()`, `contexts()`, `targets()`
- `launch`, `launchAuto`, `attach`, and webview attach/launch all wait for protocol readiness; no manual CDP/BiDi session bootstrap is required.

### Waits and cancellation

- `waitFor(target, opts)` and `waitForAsync(target, opts)`
- Targets:
  - `dom_ready`
  - `network_idle`
  - `selector_visible`
  - `url_contains`
  - `cookie_present`
  - `storage_key_present`
  - `js_truthy`
- Use `CancelToken` for cooperative cancellation.

### Events

- `onEvent(filter, callback)` / `offEvent(id)`
- Event kinds:
  - `navigation_started`
  - `navigation_completed`
  - `challenge_detected`
  - `challenge_solved`
  - `cookie_updated`

### Timeouts and diagnostics

- `setTimeoutPolicy`, `timeoutPolicy`, `lastDiagnostic`
- `setHardErrorLogger` (register custom hard-error sink; default sink writes to stderr)

### Cookie helpers

- `queryCookies`
- `buildCookieHeaderForUrl`

### Session cache

- `SessionCacheStore.open/load/save/saveWithOptions/invalidate/cleanupExpired`
- Payload presets:
  - `.minimal` (cookies)
  - `.http_session` (cookies + user agent)
  - `.rich_state` (cookies + user agent + storage + URL + extra headers)
- Use `SessionCachePayloadMask` for explicit include combinations.

## Support Matrix

### Protocol contract

- `modern` is the only public session namespace.
- Supported transports: `cdp_ws`, `bidi_ws`.
- WebDriver transport is not part of the supported contract.

### Browser coverage

- Chromium family (CDP): Chrome, Edge, Brave, Vivaldi, Opera GX, Arc, Sidekick, Shift, Epic, DuckDuckGo desktop variants, Lightpanda.
- Gecko family (BiDi): Firefox, Tor, Mullvad, LibreWolf, Pale Moon.

### Not in the modern contract

- Safari/WebKit (requires WebDriver path, out of scope).
- SigmaOS/unknown shells without guaranteed CDP/BiDi surfaces.

### Webview coverage

- WebView2 on Windows (CDP)
- Electron on Windows/macOS/Linux (CDP)
- Android WebView bridge from host tooling (CDP)

## Path Discovery

`discover()` uses deterministic precedence:

1. Explicit path (`BrowserPreference.explicit_path`)
2. Managed cache (always scanned; default fixed cache root per OS)
3. `PATH` executable scan
4. Known path catalog (`src/catalog/path_table.zig`)
5. OS probes (Windows/macOS/Linux providers)

Sorting:

1. Descending score
2. Descending version (if present)
3. Ascending lexicographic path

Deduplication uses normalized path keys (case-insensitive on Windows).

## Managed Browser Cache

Managed install supports:

- Direct payloads: `file://`, `http://`, `https://`
- Archive payloads: `.zip`, `.tar`, `.tar.gz`, `.tgz`, `.tar.xz`, `.txz`
- SHA-256 verification with `expected_sha256_hex`
- Optional `archive_executable_name` for non-canonical archive layouts

Notes:

- Managed downloads and extraction are implemented with Zig stdlib (`std.http`, `std.zip`, `std.tar`, `std.compress`).
- Default managed cache root (when `BrowserPreference.managed_cache_dir` is not set):
  - Linux: `$XDG_CACHE_HOME/alldriver/browsers` (fallback: `$HOME/.cache/alldriver/browsers`)
  - macOS: `$HOME/Library/Caches/alldriver/browsers`
  - Windows: `%LOCALAPPDATA%\\alldriver\\browsers`
- Discovery always checks managed cache. `allow_managed_download` only controls whether provisioning/download workflows are permitted.

### Runtime Lightpanda Provisioning

- API: `driver.lightpanda.downloadLatest(allocator, opts)`
  - `opts.cache_dir`: optional managed cache root override
  - `opts.tag`: optional GitHub release tag; `null` means latest release
  - `opts.expected_sha256_hex`: optional payload checksum verification
- Tools: `zig build tools -- download-lightpanda [--cache-dir=...] [--tag=...] [--sha256=...]`
- The downloader resolves release assets for the current runtime OS/arch and installs into managed cache so normal `discover()` picks it up.

## Runtime Notes

- Browser launch waits for local debug endpoint readiness before returning a session, bounded by `TimeoutPolicy.launch_ms`.
- `driver.modern.launch*` and `driver.modern.attach*` return only after protocol readiness checks complete.

## Compile-Time Extensions

Hooks are defined in `src/extensions/api.zig` and are statically linked:

- `score_install`
- `launch_args`
- `session_init`
- `event_observer`

Dynamic runtime plugin loading is intentionally out of scope.

## Adversarial Gate Semantics

- Default objective: undetected.
- Any detected automation signal => FAIL.
- Any discovered target that cannot launch/probe => FAIL.
- Unsupported/not-installed targets => explicit SKIP.

## VM Matrix Workflow

Shared VM lab default root: `/home/a/vm_lab` (`VM_LAB_DIR` override).

Prerequisites:

- `qemu-system-x86_64`
- `qemu-img`
- `ssh`
- `rsync`
- `curl`
- `ssh-keygen`

Core commands:

```bash
zig build tools -- vm-check-prereqs
zig build tools -- vm-image-sources --check
zig build tools -- vm-init-lab --project alldriver
zig build tools -- vm-create-linux --project alldriver --name linux-matrix
zig build tools -- vm-start-linux --project alldriver --name linux-matrix
zig build tools -- vm-run-linux-matrix --project alldriver --name linux-matrix
zig build tools -- vm-register-host --name macos-host --os macos --arch arm64 --address user@mac.example
zig build tools -- vm-register-host --name windows-host --os windows --arch x64 --address user@win.example
zig build tools -- vm-run-remote-matrix --project alldriver --host macos-host
zig build tools -- vm-run-remote-matrix --project alldriver --host windows-host
zig build tools -- vm-ga-collect-and-bundle --project alldriver --release-id v1-ga --linux-host linux-matrix --macos-host macos-host --windows-host windows-host

# Runtime Lightpanda provisioning
zig build tools -- download-lightpanda
```

## VM Image Sources

Official upstream pages:

- Ubuntu cloud images:
  - <https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img>
  - <https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img>
  - <https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img>
  - <https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img>
- Windows:
  - <https://www.microsoft.com/software-download/windows11>
  - <https://www.microsoft.com/software-download/windows11arm64>
  - <https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise>
- macOS:
  - <https://support.apple.com/en-us/102662>
  - <https://developer.apple.com/documentation/virtualization>
  - <https://support.apple.com/guide/deployment/dep5980c3e3d/web>

## External Binary Dependencies

### Core runtime

- Browser binaries for targets you automate
- Optional Lightpanda runtime provisioning via `driver.lightpanda.downloadLatest(...)`
- Webview runtimes as needed: `msedgewebview2`, `electron`
- Android bridge tools: `adb`, `shizuku` (or `rish`)

### Tooling / matrix / release

- `zig`, `git`, `bash`, `tar`, `date`, `which`/`where`, `chmod`
- `gpg` (signing)
- `ssh`, `scp`, `rsync` (remote matrix orchestration)
- `qemu-system-x86_64`, `qemu-img`, `curl`, `ssh-keygen` (VM flows)
- `sha256sum` (optional verification tooling)

## Known Limitations

- Feature behavior still depends on browser/runtime endpoint availability and versions.
- No Cloudflare-specific solver API is provided in core.
- Browser/session pooling is not part of the current architecture.
- HAR-like full network export is deferred until persistent event-stream storage is first-class.
- Domain profile templates are application policy and intentionally out of core.
- Android bridge coverage is bridge-smoke scoped in release gates.
- Session cache is optimized for HTTP session reuse; full profile filesystem snapshots are out of scope.
- Strict GA requires signed manual matrix evidence and passing behavioral + adversarial checks.
