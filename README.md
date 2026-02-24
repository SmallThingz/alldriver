# browser_driver (Zig)

`browser_driver` is a desktop-focused browser and webview automation framework in Zig.

## What It Provides
- Cross-browser desktop discovery for Windows/macOS/Linux.
- Cross-platform webview runtime discovery (WebView2, WKWebView, WebKitGTK, Android/iOS bridge tooling).
- Dedicated Electron webview driver support (CDP attach + managed launch).
- Dedicated WebKitGTK webview driver support (WebKitWebDriver attach + managed launch).
- Engine-tier automation architecture (Chromium, Gecko, WebKit).
- Hybrid protocol surface (CDP, WebDriver, BiDi) with capability negotiation.
- Real transport modules for HTTP/WebSocket protocol execution.
- Optional managed browser cache discovery (`allow_managed_download` + configurable cache dir).
- Idiomatic Zig API plus a nodriver-style compatibility facade.
- nodriver facade contract: Chromium-only driverless launch (CDP), no WebDriver fallback.
- Dual API model: synchronous core + thread-backed awaitable `AsyncResult(T)` operations.
- Compile-time extension hooks (no runtime plugin loader).

## WebView Support
- Discover runtimes and bridge tools with `discoverWebViews(...)`.
- Attach to an existing webview debug endpoint with `attachWebView(...)`.
- Launch a host app and manage it as a session with `launchWebViewHost(...)`.
- Electron-specific APIs:
  - `attachElectronWebView(...)`
  - `launchElectronWebView(...)`
- WebKitGTK-specific APIs:
  - `attachWebKitGtkWebView(...)`
  - `launchWebKitGtkWebView(...)`
- Mobile helper attach APIs:
  - `attachAndroidWebView(...)`
  - `attachIosWebView(...)`
- Android bridge modes:
  - `AndroidWebViewAttachOptions.bridge_kind = .adb` (default)
  - `AndroidWebViewAttachOptions.bridge_kind = .shizuku`
  - `AndroidWebViewAttachOptions.bridge_kind = .direct` (existing forwarded endpoint)
  - `attachAndroidWebView(...)` can synthesize a root CDP endpoint (`cdp://host:port/`) when `pid`/`socket_name` are omitted.

### Android Shizuku Example
```zig
var session = try driver.attachAndroidWebView(allocator, .{
    .device_id = "emulator-5554",
    .bridge_kind = .shizuku,
    .host = "127.0.0.1",
    .port = 9322,
    .socket_name = "chrome_devtools_remote",
});
defer session.deinit();
```
Default Android WebView driving remains unchanged via `.bridge_kind = .adb`.

## Safety Boundary
This project targets legitimate automation workflows (testing, QA, scripted browser operations).
It does not guarantee bypass of bot-detection systems and does not ship explicit evasion primitives.

## API Namespaces (`modern` + `legacy`)
- `modern` is CDP/BiDi-first and only allows `.cdp_ws` / `.bidi_ws` session transports.
- `legacy` contains WebDriver-only browser/webview paths.
- Root-level entrypoints (`discover`, `launch`, `attach`, webview helpers) remain as compatibility shims for one migration cycle and route to `modern` or `legacy` based on discovered support.

Modern targets:
- Browser engines: Chromium and Gecko.
- Webviews: `webview2`, `electron`, `android_webview`.

Legacy targets:
- WebDriver browser/webview paths including Safari/WebKit and WebDriver-only webviews (`wkwebview`, `webkitgtk`, `ios_wkwebview`).

Example split usage:
```zig
const driver = @import("browser_driver");

// Modern CDP/BiDi flow.
var modern = try driver.modern.attach(allocator, "cdp://127.0.0.1:9222");
defer modern.deinit();
try modern.page().navigate("https://example.com");

// Legacy WebDriver flow.
var legacy = try driver.legacy.attachWebDriver(allocator, "webdriver://127.0.0.1:4444/session/1");
defer legacy.deinit();
try legacy.navigate("https://example.com");
```

## External Binary Dependencies
### Core Runtime (Library Usage)
- Browser binaries (at least one installed target): Chrome/Chromium, Edge, Safari, Firefox, Brave, Tor Browser, DuckDuckGo Browser, Mullvad Browser, LibreWolf, Epic, Arc, Vivaldi, SigmaOS, Sidekick, Shift, Opera GX, Pale Moon.
- Lightpanda is optional and build-gated via `-Dinclude_lightpanda_browser=true`; when enabled, discovery uses bundled runtime payload from the lazy `lightpanda_browser` dependency.
- Webview runtime/driver binaries (as applicable): `msedgewebview2`, `safaridriver`, `WebKitWebDriver`, `MiniBrowser`, `electron`.
- Mobile bridge binaries: `adb`, `shizuku` (or `rish`), `ios_webkit_debug_proxy`, `tidevice`.

### Tooling / Matrix / Release (When using `zig build tools -- ...`)
- Base tooling: `zig`, `git`, `bash`, `tar`, `date`, `which` (or `where` on Windows), `chmod`.
- Strict signing: `gpg`.
- Remote matrix orchestration: `ssh`, `scp`, `rsync`.
- VM/QEMU workflows: `qemu-system-x86_64`, `qemu-img`, `curl`, `python3`, `ssh-keygen`.
- Optional VM image checksum verification: `sha256sum`.

If you only call core APIs (`discover`, `launch`, `attach`), you typically only need runtime binaries for your target browser/driver. Tooling binaries are only required for matrix/release/VM commands.

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
- WebKitGTK automation is driver-first via `WebKitWebDriver` session bootstrap.
- `launchWebKitGtkWebView(...)` supports MiniBrowser targeting via `webkitgtk:browserOptions`:
  - `browser_target = .auto` (default): use default WebDriver capabilities without forcing a browser binary path.
  - `browser_target = .minibrowser`: require MiniBrowser targeting.
  - `browser_target = .custom_binary` + `browser_binary_path`: target an explicit browser binary path.
  - Explicit MiniBrowser/custom targeting uses `webkitgtk:browserOptions` with supplied `browser_args`.

## Privacy Defaults
- Runtime launch defaults are privacy-first and avoid emitting legacy Chromium automation marker flags.
- Legacy marker behavior is opt-in via:
  - `LaunchOptions.legacy_automation_markers`
  - `WebViewLaunchOptions.legacy_automation_markers`
  - `ElectronWebViewLaunchOptions.legacy_automation_markers`
- Gecko stealth prefs are opt-in via `LaunchOptions.gecko_stealth_prefs`.

## TLS Handling
- Strict TLS is the default (`ignore_tls_errors = false`).
- Use `ignore_tls_errors = true` in launch options to allow insecure/invalid certs.
- `LaunchOptions.ignore_tls_errors` applies across desktop browser launches.
- `WebKitGtkWebViewLaunchOptions.ignore_tls_errors` sets WebDriver `acceptInsecureCerts`, and adds MiniBrowser `--ignore-tls-errors` when MiniBrowser args are explicitly used.
- `ElectronWebViewLaunchOptions.ignore_tls_errors` adds Chromium insecure-cert launch flags.
- In strict mode, WebDriver navigation that does not commit (for example, blocked TLS leading to `about:blank`) returns `NavigationNotCommitted`.

## Examples
- Many end-to-end usage examples live in `/home/a/projects/zig/browser_driver/examples/README.md`.
- Build all examples with: `zig build examples`
- Examples include discover/launch/attach, DOM actions, waits, async API, network interception, cookies/storage, screenshots/tracing, nodriver facade, and webview/mobile bridge attach flows.

## Build Option
Use `-Denable_builtin_extension=true` to enable the built-in compile-time extension adapter.
Use `-Dinclude_lightpanda_browser=true` to enable bundled Lightpanda support from the lazy dependency.

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
  - `BROWSER_DRIVER_BEHAVIORAL=1 WEBVIEW_BRIDGE_BEHAVIORAL=1 WEBKITGTK_BEHAVIORAL=1 zig build tools -- test-behavioral-matrix`
  - Strict mode (fails when expected installs/bridges are missing): set `BROWSER_DRIVER_BEHAVIORAL_STRICT=1` and/or `WEBVIEW_BRIDGE_BEHAVIORAL_STRICT=1`
- Adversarial automation-detection gate:
  - `zig build tools -- adversarial-detection-gate --out artifacts/reports/adversarial-detection.txt`
  - Default objective is adversarial: `OVERALL: PASS` means no detection signals were found across discovered browser + webview targets.
  - Detected automation signals or discovered target launch/probe failures cause gate failure.
  - Endpoint/transport/profile-isolation markers are reported for diagnostics but are not treated as standalone detection.
  - Optional mode for internal validation: add `--expect-detected 1`.
  - Optional zero-discovery skip behavior: add `--allow-missing-browser 1`.

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
