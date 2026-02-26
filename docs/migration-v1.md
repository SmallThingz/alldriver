# Migration to V1 Contract

## Breaking Changes
- `Session` now has explicit `mode` and `transport` fields.
- `Session.capabilities` field moved to `Session.capabilities()` method.
- Capability checks should use `Session.supports(feature)`.
- Async operations are exposed via `AsyncResult(T)` handles and `*Async` methods.
- Discovery ownership changed:
  - `discover(...) -> BrowserInstallList`
  - `discoverWebViews(...) -> WebViewRuntimeList`
  - Call `.deinit()` on returned lists.
- Root compatibility launch/attach/webview shims were removed.

## Namespace Split
- New public namespaces:
  - `driver.modern` for CDP/BiDi-first workflows.
  - `driver.legacy` for WebDriver-only browser/webview workflows.
- `driver.modern` transport guarantee: only `.cdp_ws` and `.bidi_ws`.
- `driver.legacy` transport scope: `.webdriver_http`.

## New APIs
- Webview helper attach APIs:
  - `attachAndroidWebView(...)`
  - `attachIosWebView(...)`
- Android webview attach now supports explicit bridge selection:
  - `AndroidWebViewAttachOptions.bridge_kind = .adb | .shizuku | .direct`
- Network interception APIs on `Session`:
  - `addInterceptRule`, `removeInterceptRule`, `clearInterceptRules`
  - `onRequest`, `onResponse`

## Removed Root Calls and Replacements
| Removed root call | Replacement |
|---|---|
| `launch(...)` | `modern.launch(...)` for Chromium/Gecko, `legacy.launch(...)` for WebDriver-only targets |
| `attach(endpoint)` | `modern.attach(endpoint)` for CDP/BiDi endpoints, `legacy.attachWebDriver(endpoint)` for WebDriver endpoints |
| `attachWebView(...)` | `modern.attachWebView(...)` for `webview2/electron/android_webview`, `legacy.attachWebView(...)` for `wkwebview/webkitgtk/ios_wkwebview` |
| `launchWebViewHost(...)` | `modern.launchWebViewHost(...)` or `legacy.launchWebViewHost(...)` by webview capability tier |
| `attachAndroidWebView(...)` | `modern.attachAndroidWebView(...)` |
| `attachIosWebView(...)` | `legacy.attachIosWebView(...)` |
| `attachElectronWebView(...)` | `modern.attachElectronWebView(...)` |
| `attachWebKitGtkWebView(...)` | `legacy.attachWebKitGtkWebView(...)` |

## Upgrade Pattern
1. Replace direct field access (`session.capabilities.*`) with method calls.
2. Move all launch/attach code to `modern`/`legacy` namespace calls.
3. Migrate webview attach code to dedicated helper APIs where possible.
4. Move any ad-hoc interception logic to `NetworkRule` + `InterceptAction`.
5. For non-blocking workflows, switch from custom threads to `*Async` session methods and `.await()`.
6. Replace raw discovery slices + `free*` helpers with list `.deinit()` ownership.
