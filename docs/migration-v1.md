# Migration to V1 Contract

## Breaking Changes
- `Session` now has explicit `mode` and `transport` fields.
- `Session.capabilities` field moved to `Session.capabilities()` method.
- Capability checks should use `Session.supports(feature)`.
- Async operations are exposed via `AsyncResult(T)` handles and `*Async` methods.

## New APIs
- Webview helper attach APIs:
  - `attachAndroidWebView(...)`
  - `attachIosWebView(...)`
- Network interception APIs on `Session`:
  - `addInterceptRule`, `removeInterceptRule`, `clearInterceptRules`
  - `onRequest`, `onResponse`

## Upgrade Pattern
1. Replace direct field access (`session.capabilities.*`) with method calls.
2. Migrate webview attach code to dedicated helper APIs where possible.
3. Move any ad-hoc interception logic to `NetworkRule` + `InterceptAction`.
4. For non-blocking workflows, switch from custom threads to `*Async` session methods and `.await()`.
