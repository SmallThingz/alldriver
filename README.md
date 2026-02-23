# browser_driver (Zig)

`browser_driver` is a desktop-focused browser and webview automation framework in Zig.

## What It Provides
- Cross-browser desktop discovery for Windows/macOS/Linux.
- Cross-platform webview runtime discovery (WebView2, WKWebView, WebKitGTK, Android/iOS bridge tooling).
- Engine-tier automation architecture (Chromium, Gecko, WebKit).
- Hybrid protocol surface (CDP, WebDriver, BiDi) with capability negotiation.
- Real transport modules for HTTP/WebSocket protocol execution.
- Optional managed browser cache discovery (`allow_managed_download` + configurable cache dir).
- Idiomatic Zig API plus a nodriver-style compatibility facade.
- Dual API model: synchronous core + thread-backed awaitable `AsyncResult(T)` operations.
- Compile-time extension hooks (no runtime plugin loader).

## WebView Support
- Discover runtimes and bridge tools with `discoverWebViews(...)`.
- Attach to an existing webview debug endpoint with `attachWebView(...)`.
- Launch a host app and manage it as a session with `launchWebViewHost(...)`.
- Mobile helper attach APIs:
  - `attachAndroidWebView(...)`
  - `attachIosWebView(...)`

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

## Profile Modes
- `.persistent` requires `profile_dir` and reuses that exact directory across runs.
- `.ephemeral` uses an isolated profile directory and deletes it on `session.deinit()`.
- `.ephemeral` is not incognito/private mode; it is disposable profile storage.
- For WebKit/unknown targets, profile isolation is applied with sandboxed env directories under the effective profile root.

## Examples
- Many end-to-end usage examples live in `/home/a/projects/zig/browser_driver/examples/README.md`.
- Build all examples with: `zig build examples`
- Examples include discover/launch/attach, DOM actions, waits, async API, network interception, cookies/storage, screenshots/tracing, nodriver facade, and webview/mobile bridge attach flows.

## Build Option
Use `-Denable_builtin_extension=true` to enable the built-in compile-time extension adapter.

## Script Migration
- Legacy Bash automation scripts have been replaced with Zig tooling.
- Primary entrypoint: `zig build tools -- <subcommand> [args...]`
- Compatibility wrappers are available under `/home/a/projects/zig/browser_driver/scripts/*.zig`.

## Release and Matrix Commands
- Local gate: `zig build tools -- release-gate`
- Strict GA gate (requires signed matrix evidence): `STRICT_GA=1 zig build tools -- release-gate`
- Production gate (recommended pre-ship): `zig build production-gate`
- Strict production gate (requires full strict matrix evidence): `zig build tools -- production-gate --strict-ga`
- Run one manual matrix execution: `zig build tools -- matrix-run --platform linux`
- Collect and verify matrix reports: `zig build tools -- matrix-collect`
- Build release bundle from matrix evidence: `zig build tools -- release-bundle --release-id v1.0.0`
- Full GA bundle from shared VM-lab evidence:
  - `zig build tools -- vm-ga-collect-and-bundle --project browser_driver --release-id v1-ga --linux-host linux-matrix --macos-host macos-host --windows-host windows-host`

## Test Layers
- Default unit/contract suite (includes cross-platform catalog/discovery invariants): `zig build test`
- Behavioral browser/webview smoke (opt-in):
  - `BROWSER_DRIVER_BEHAVIORAL=1 WEBVIEW_BRIDGE_BEHAVIORAL=1 zig build tools -- test-behavioral-matrix`
  - Strict mode (fails when expected installs/bridges are missing): set `BROWSER_DRIVER_BEHAVIORAL_STRICT=1` and/or `WEBVIEW_BRIDGE_BEHAVIORAL_STRICT=1`

## QEMU VM Helpers
- Check prerequisites: `zig build tools -- vm-check-prereqs`
- List/check official image sources: `zig build tools -- vm-image-sources --check`
- Initialize shared lab (default: `/home/a/vm_lab`): `zig build tools -- vm-init-lab --project browser_driver`
- Create Linux VM assets: `zig build tools -- vm-create-linux --project browser_driver --name linux-matrix`
- Run Linux VM matrix: `zig build tools -- vm-run-linux-matrix --project browser_driver --name linux-matrix`
- Register remote hosts:
  - `zig build tools -- vm-register-host --name macos-host --os macos --arch arm64 --address user@mac-host`
  - `zig build tools -- vm-register-host --name windows-host --os windows --arch x64 --address user@win-host`
- Run remote matrix:
  - `zig build tools -- vm-run-remote-matrix --project browser_driver --host macos-host`
  - `zig build tools -- vm-run-remote-matrix --project browser_driver --host windows-host`
- `zig build` equivalents:
  - `zig build vm-prereqs`
  - `zig build vm-init -Dvm_lab_dir=/home/a/vm_lab`
  - `zig build vm-linux-create -Dvm_lab_dir=/home/a/vm_lab`
  - `zig build vm-linux-matrix -Dvm_lab_dir=/home/a/vm_lab`
  - `zig build vm-remote-matrix -Dvm_host=macos-host -Dvm_lab_dir=/home/a/vm_lab`
  - `zig build vm-ga-bundle -Dvm_lab_dir=/home/a/vm_lab`
  - `zig build production-gate`
  - `zig build test-qemu-aarch64 -fqemu`
- Full guide: `docs/vm-matrix.md`
- Image sources: `docs/vm-image-sources.md`

## Docs
- `docs/support-matrix.md`
- `docs/path-discovery.md`
- `docs/compat-nodriver.md`
- `docs/extensions.md`
- `docs/migration-v1.md`
- `docs/known-limitations.md`
- `docs/vm-matrix.md`
- `docs/vm-image-sources.md`
