# Known Limitations (V1)

## Protocol Surface Variance
- Protocol features still depend on externally exposed browser endpoints and installed driver/runtime versions.
- Unsupported protocol operations return typed capability/protocol errors instead of silent no-op behavior.
- `modern` exposes CDP/BiDi-first domain APIs, but some operations remain adapter-specific (for example, handle lifecycle operations can return typed unsupported errors).

## Namespace Migration Window
- Root compatibility shims (`launch`, `attach`, and root webview helpers) are maintained for one migration cycle.
- New integrations should use `modern.*` or `legacy.*` explicitly; shim removal can happen in the next major cycle.

## Mobile Bridge Scope
- Android/iOS support is bridge-smoke scoped for v1 release gates.
- Full mobile app lifecycle orchestration is outside current GA scope.
- Adversarial gate coverage for mobile webviews depends on bridge tooling/runtime presence on the host and reports missing targets as explicit skips.

## Strict TLS Default
- TLS validation is strict by default across launch paths.
- On constrained environments, some WebDriver HTTPS navigations can remain on `about:blank`; this now fails deterministically with `NavigationNotCommitted`.
- Opt in to insecure cert handling with `ignore_tls_errors = true` when this behavior is expected for test infrastructure.

## Managed Cache Packaging
- Managed cache install supports direct binary payloads (`file://` and `http://`).
- Archive extraction/packaging normalization is expected to be handled upstream by distribution tooling.

## Strict GA Policy
- Tier-1 and Tier-2 failures are both release-blocking in strict GA mode.
- Manual matrix evidence and signed reports are mandatory release artifacts.
- Strict matrix summaries require both `behavioral_matrix` and `adversarial_detection_gate` to pass in signed reports.
