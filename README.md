# 🚀 alldriver

Modern browser automation for Zig with a CDP/BiDi-first API, deterministic discovery, and production gates.

![Zig](https://img.shields.io/badge/Zig-0.15.x-f7a41d?logo=zig&logoColor=111)
![Platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Linux-2ea44f)
![Protocols](https://img.shields.io/badge/Protocols-CDP%20%7C%20BiDi-0366d6)
![API](https://img.shields.io/badge/API-modern-0f766e)

## ⚡ Features

- CDP/BiDi-first modern API (`driver.modern.*`) with typed domain clients.
- Auto-launch and auto-attach flows that wait for real protocol readiness.
- Common utility paths are centralized (`driver.path`, `driver.strings`, `driver.json`, `driver.io`) to keep behavior consistent across modules.
- Deterministic browser discovery (PATH + known paths + OS probes + managed cache).
- Typed waits, cancellation tokens, lifecycle events, timeout policies, diagnostics.
- Typed cookie query/export helpers and built-in session cache.
- Runtime Lightpanda download/install support (no build-time dependency).
- Production tooling: adversarial detection gate, matrix, release bundle.

## 🚀 Quick Start

```zig
const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

## 📦 Install

```bash
zig fetch --save git+https://github.com/SmallThingz/alldriver
```

Then add the dependency import in your `build.zig` as usual.

## 🧠 API At A Glance

### Modern surface

- `driver.modern.discover(...)`
- `driver.modern.launch(...)`
- `driver.modern.launchAuto(...)`
- `driver.modern.attach(...)`

### Session domains

- `session.page()`
- `session.runtime()`
- `session.network()`
- `session.input()`
- `session.log()`
- `session.storage()`
- `session.contexts()`
- `session.targets()`

### Waits, cancel, events

- `session.waitFor(target, opts)`
- `session.waitForAsync(target, opts)`
- `driver.CancelToken`
- `session.onEvent(filter, callback)` / `session.offEvent(id)`

### Timeout + diagnostics

- `session.setTimeoutPolicy(...)`
- `session.timeoutPolicy()`
- `session.lastDiagnostic()`
- `driver.modern.setHardErrorLogger(...)`

### Cookie/session utilities

- `session.storage().queryCookies(...)`
- `session.storage().buildCookieHeaderForUrl(...)`
- `driver.SessionCacheStore.open/load/save/saveWithOptions/invalidate/cleanupExpired`

## 🌐 Coverage

### Modern supported

- Chromium-family browsers via CDP.
- Firefox/Gecko via BiDi.
- CDP-capable webviews: `webview2`, `electron`, `android_webview`.

### Unsupported tier

- Targets without usable CDP/BiDi surfaces on the host are discovered/classified but not driven.

## 💾 Managed Browser Cache

When `managed_cache_dir` is unset, default paths are:

- Linux: `$XDG_CACHE_HOME/alldriver/browsers` (fallback `$HOME/.cache/alldriver/browsers`)
- macOS: `$HOME/Library/Caches/alldriver/browsers`
- Windows: `%LOCALAPPDATA%\\alldriver\\browsers`

`discover()` always scans managed cache.  
`allow_managed_download` controls whether provisioning/download is allowed.

## 🐼 Lightpanda Runtime Download

Programmatic:

```zig
const installed = try driver.modern.downloadLightpandaLatest(allocator, .{
    .cache_dir = null,
    .tag = null,
    .expected_sha256_hex = null,
});
defer allocator.free(installed);
```

Tooling:

```bash
zig build tools -- download-lightpanda
```

## 🧪 Build / Test / Gates

```bash
# core
zig build test
zig build examples
zig build run

# tool sanity
zig build tools -- self-test

# adversarial gate
zig build tools -- adversarial-detection-gate --allow-missing-browser=1

# production gate
zig build production-gate
zig build tools -- production-gate --strict-ga
```

## 🧰 External Binaries

### Core runtime (library users)

- Browser binaries for your chosen targets (Chrome/Edge/Firefox/Brave/etc.).
- Optional Lightpanda binary (auto-downloaded at runtime if requested).
- Optional webview runtimes/tools when using those flows (`msedgewebview2`, `electron`, Android bridge tools such as `adb` or `shizuku`/`rish`).

If you only use `discover/launch/attach` against installed desktop browsers, no additional tooling binaries are required by the library core.

### Tooling/matrix/release (`zig build tools -- ...`)

- `git`, `bash`, `tar`, `date`, `which`/`where`, `chmod`
- `gpg` (sign/verify)
- `ssh`, `scp`, `rsync` (remote matrix)
- `qemu-system-x86_64`, `qemu-img`, `curl`, `ssh-keygen` (VM workflows)

## 🛡 Safety Boundary

`alldriver` is for standards-compliant automation (QA/testing/scripting).  
It does **not** provide built-in detection-bypass/evasion primitives.

## 📚 Documentation

- `/home/a/projects/zig/browser_driver/DOCUMENTATION.md`
- `/home/a/projects/zig/browser_driver/examples/README.md`
- `/home/a/projects/zig/browser_driver/CONTRIBUTING.md`
- `/home/a/projects/zig/browser_driver/SECURITY.md`
