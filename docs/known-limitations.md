# Known Limitations (V1)

## Protocol Surface Variance
- Protocol features still depend on externally exposed browser endpoints and installed driver/runtime versions.
- Unsupported protocol operations return typed capability/protocol errors instead of silent no-op behavior.

## Mobile Bridge Scope
- Android/iOS support is bridge-smoke scoped for v1 release gates.
- Full mobile app lifecycle orchestration is outside current GA scope.

## Managed Cache Packaging
- Managed cache install supports direct binary payloads (`file://` and `http://`).
- Archive extraction/packaging normalization is expected to be handled upstream by distribution tooling.

## Strict GA Policy
- Tier-1 and Tier-2 failures are both release-blocking in strict GA mode.
- Manual matrix evidence and signed reports are mandatory release artifacts.
