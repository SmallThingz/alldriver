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
- `session.waitForCookie(query, opts)`
- `session.waitForAsync(target, opts)`
- `session.waitForCookieAsync(query, opts)`
- `driver.CancelToken`
- `session.onEvent(filter, callback)` / `session.offEvent(id)`
- `session.addInitScript(script)` / `session.removeInitScript(id)` (pre-document init scripts)
- Lifecycle hook kinds:
  - Navigation/reload: `navigation_started`, `navigation_completed`, `navigation_failed`, `reload_started`, `reload_completed`, `reload_failed`
  - Deterministic milestones: `response_received`, `dom_ready`, `scripts_settled`
  - Wait lifecycle: `wait_started`, `wait_satisfied`, `wait_timeout`, `wait_canceled`, `wait_failed`
  - Action lifecycle: `action_started`, `action_completed`, `action_failed`
  - Network observation: `network_request_observed`, `network_response_observed`
  - Challenge/cookie: `challenge_detected`, `challenge_solved`, `cookie_updated`
- Key semantics:
  - `navigation_started` is emitted before each navigate attempt, including attempts that later fail.
  - `navigation_completed` is emitted only after successful navigate; failures emit `navigation_failed`.
  - Wait APIs emit the `wait_*` lifecycle hooks, including failure/cancel/timeout outcomes.
  - Session actions (`click`, `typeText`, `evaluate`) emit `action_*` hooks around each attempt.
  - Network telemetry keeps request/response metadata, redirect chains, and per-request status timelines.
  - `network.records(allocator, include_bodies=true)` attempts full response-body capture via protocol APIs where available.
  - `network.frames(...)` and `network.serviceWorkers(...)` provide frame/service-worker introspection from protocol notifications.
  - Snapshot bundles are captured per navigation phase and retrievable via `network.navigationSnapshots(...)`.
  - `challenge_detected` (challenge heuristic became active during wait polling)
  - `challenge_solved` (challenge heuristic transitioned back to clear)
  - `cookie_updated` is emitted after successful `setCookie` with `change` and `source` metadata.
  - `reload()` emits both reload hooks and navigation hooks with `cause=.reload` for symmetry.
- Filter semantics:
  - `filter.kinds = &.{}` subscribes to all hook kinds.
  - `filter.domain` is case-insensitive and matches exact host or subdomain suffix.
  - Domain extraction uses URL host for navigation/reload/network/challenge hooks and `cookie.domain` for `cookie_updated`.
  - Domain filtering does not apply to hook kinds without URL/domain payloads (`wait_*`, `action_*`).

### Timeout + diagnostics

- `session.setTimeoutPolicy(...)`
- `session.timeoutPolicy()`
- `session.lastDiagnostic()`
- `driver.modern.setHardErrorLogger(...)`

### Compile-time extension hooks

- `driver.extension_hooks.registerHooks(...)`
- Hook kinds:
  - `score_install` (adjust discovery scoring)
  - `launch_args` (rewrite/append process args before spawn)
  - `session_init` (notified after session protocol readiness)
  - `event_observer` (extension event sink for explicit `notifyEvent` calls)

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
