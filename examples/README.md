# Examples

These examples target Zig 0.16.0. Desktop launch examples select Chromium browsers; compilation alone does not validate their runtime behavior.

## Build All Examples

```bash
zig build examples
```

Built executables are written to `zig-out/examples`.

## Example Index

- `01_discover.zig`: discover installed browsers and print scored candidates.
- `02_launch_and_navigate.zig`: auto-discover and launch with sane defaults, then navigate/wait/evaluate.
- `03_attach_existing_endpoint.zig`: attach to an existing CDP endpoint.
- `04_dom_interactions_and_waits.zig`: DOM interaction flow using target-based waits (`dom_ready`, `selector_visible`).
- `05_network_interception.zig`: register request/response observers and interception rules.
- `06_cookies_and_storage.zig`: cookie write plus localStorage read/write via JS.
- `07_screenshots_and_tracing.zig`: capture screenshots and tracing artifacts.
- `08_async_api.zig`: use thread-backed async operations and await results.
- `09_modern_contexts_and_targets.zig`: modern context/target domain clients.
- `10_webview_discovery_and_attach.zig`: discover desktop webview runtimes and attach.
- `11_mobile_webview_attach.zig`: Android webview attach helper usage.
- `12_managed_cache_and_profile_modes.zig`: managed cache preference and profile modes.
- `13_capability_aware_flow.zig`: capability-checked flow with graceful fallbacks.
- `14_electron_webview.zig`: discover and launch Electron as a dedicated webview driver.
- `16_wait_targets.zig`: use `waitFor` targets for URL, selector, cookie, storage key, and JS truthy checks.
- `17_event_hooks.zig`: subscribe to lifecycle/challenge/cookie events and handle callback flow.
- `18_cookie_header_export.zig`: query cookies with typed filters and build canonical `Cookie` headers for URLs.
- `19_session_cache.zig`: persist/load session state with payload presets and custom payload masks.
- `20_timeout_and_cancel.zig`: apply timeout policies and cooperative cancellation for waits.
- `21_lightpanda_runtime_download.zig`: Lightpanda provisioning API example, outside the supported Chromium scope.
- `22_forensic_timeline_snapshot.zig`: forensic debugging flow for request/response timelines, redirect/status chains, frame/service-worker introspection, and phase snapshots.

## Notes

- Launch-based examples use `driver.modern.launchAsync(...).await(...)` so control is returned only after launch/connection completes or times out.
- Run `zig build test-chromium` for the mandatory real-Brave behavior gate; it fails if the required browser is unavailable.
- Examples require installed Chromium browsers or an explicitly configured CDP endpoint.
- Webview/mobile and Lightpanda examples are retained API demonstrations, not validated platform-support claims. Firefox/BiDi is deferred.
- Mobile bridge examples require host tooling (`adb` or `shizuku`/`rish`) and forwarded endpoints.
- Launch APIs support `ignore_tls_errors = true` for environments with self-signed or invalid certificates.
- Examples are designed as minimal building blocks and can be composed into larger automation harnesses.
- Profile mode semantics:
  `.persistent` requires `profile_dir` and keeps data at that path.
  `.ephemeral` creates an isolated disposable profile directory that is deleted on session teardown.

Async handles must be deinitialized. `requestCancel()` returns whether cooperative cancellation was accepted; `isCancelable()` reports availability. An await timeout does not stop an operation. Free returned buffers, and deinitialize sessions whose ownership you obtained through await. See [ownership and artifacts](../DOCUMENTATION.md) for input, trace, log callback, and download contracts.
