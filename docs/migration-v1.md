# Migration Notes (CDP/BiDi-Only)

## Breaking Changes
- `driver.legacy` namespace removed.
- WebDriver transport removed from public/runtime contracts.
- Legacy WebKit webview APIs removed (`attachIosWebView`, `attachWebKitGtkWebView`, `launchWebKitGtkWebView`).
- WebView kinds reduced to:
  - `webview2`
  - `electron`
  - `android_webview`

## Current Launch/Attach Surface
- Browser:
  - `driver.modern.discover(...)`
  - `driver.modern.launch(...)`
  - `driver.modern.attach(...)`
- WebView:
  - `driver.modern.discoverWebViews(...)`
  - `driver.modern.attachWebView(...)`
  - `driver.modern.launchWebViewHost(...)`
  - `driver.modern.attachAndroidWebView(...)`
  - `driver.modern.attachElectronWebView(...)`
  - `driver.modern.launchElectronWebView(...)`

## Tier Semantics
- `support_tier.browserTier(kind)` returns:
  - `.modern` for Chromium/Gecko families
  - `.unsupported` for WebKit/unknown engines in the modern contract
