# Examples

This folder contains many focused usage examples for `alldriver`.

## Build All Examples

```bash
zig build examples
```

Built executables are written to `/home/a/projects/zig/browser_driver/zig-out/examples`.

## Example Index

- `01_discover.zig`: discover installed browsers and print scored candidates.
- `02_launch_and_navigate.zig`: launch a browser and navigate/wait/evaluate.
- `03_attach_existing_endpoint.zig`: attach to an existing CDP/WebDriver/BiDi endpoint.
- `04_dom_interactions_and_waits.zig`: DOM interaction flow with waits.
- `05_network_interception.zig`: register request/response observers and interception rules.
- `06_cookies_and_storage.zig`: cookie write plus localStorage read/write via JS.
- `07_screenshots_and_tracing.zig`: capture screenshots and tracing artifacts.
- `08_async_api.zig`: use thread-backed async operations and await results.
- `09_modern_contexts_and_targets.zig`: modern context/target domain clients.
- `10_webview_discovery_and_attach.zig`: discover desktop webview runtimes and attach.
- `11_mobile_webview_attach.zig`: Android/iOS webview attach helper usage.
- `12_managed_cache_and_profile_modes.zig`: managed cache preference and profile modes.
- `13_capability_aware_flow.zig`: capability-checked flow with graceful fallbacks.
- `14_electron_webview.zig`: discover and launch Electron as a dedicated webview driver.
- `15_legacy_webkitgtk_webview.zig`: launch WebKitGTK through `WebKitWebDriver` and probe MiniBrowser when present.

## Notes

- Some examples require installed browsers and local debug endpoints.
- Mobile bridge examples require host tooling (`adb` or `shizuku`/`rish` for Android, `ios_webkit_debug_proxy` or `tidevice` for iOS) and forwarded endpoints.
- WebKitGTK automation uses `WebKitWebDriver` as the primary runtime entrypoint, and can target MiniBrowser via `webkitgtk:browserOptions` (`browser_target` + `browser_binary_path`).
- Launch APIs support `ignore_tls_errors = true` for environments with self-signed or invalid certificates.
- Examples are designed as minimal building blocks and can be composed into larger automation harnesses.
- Profile mode semantics:
  `.persistent` requires `profile_dir` and keeps data at that path.
  `.ephemeral` creates an isolated disposable profile directory that is deleted on session teardown.
