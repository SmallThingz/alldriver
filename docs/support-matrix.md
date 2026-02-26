# Support Matrix (Desktop/WebView v1)

## Guarantee Model
- Guarantees are validated per browser and per platform in the manual GA matrix.
- Tier 1 and Tier 2 are both release-gating for GA.
- If any in-scope Tier 2 browser fails functional validation, GA is blocked.
- API guarantees are split by namespace:
  - `modern`: CDP/BiDi (`cdp_ws`, `bidi_ws`).
  - `legacy`: WebDriver-only flows (`webdriver_http`).
- Launch/attach contracts are namespace-only; root compatibility shims are removed.

## Tier 1
| API Class | Engine | Browsers | Platforms | Adversarial Gate Coverage |
|---|---|---|---|---|
| modern | Chromium | Chrome, Edge, Brave, Vivaldi, Opera GX, Arc, Sidekick, Shift, Epic, DuckDuckGo (desktop availability varies) | Windows, macOS, Linux | Included on host where supported by platform path hints |
| modern | Gecko | Firefox | Windows, macOS, Linux | Included on host where supported by platform path hints |
| legacy | WebKit | Safari (via `safaridriver` + WebDriver) | macOS | Included on macOS hosts |

## Tier 2 (GA-Blocking in Strict Mode)
| API Class | Browser | Engine Family | Expected Contract | Adversarial Gate Coverage |
|---|---|---|---|---|
| modern | Tor Browser | Gecko-derived | Full functional suite pass required for GA | Included on host where supported by platform path hints |
| modern | Mullvad Browser | Gecko-derived | Full functional suite pass required for GA | Included on host where supported by platform path hints |
| modern | LibreWolf | Gecko-derived | Full functional suite pass required for GA | Included on host where supported by platform path hints |
| modern | Pale Moon | Gecko-derived fork | Full functional suite pass required for GA | Included on host where supported by platform path hints |
| legacy | SigmaOS | Closed-shell / unknown | Full functional suite pass required for GA | Included on macOS hosts |

## WebView Coverage
| API Class | Runtime | Platform | GA Requirement | Adversarial Gate Coverage |
|---|---|---|---|---|
| modern | WebView2 | Windows | Attach/launch smoke + basic interaction | Included on Windows hosts |
| legacy | WKWebView | macOS | Attach/launch smoke + basic interaction | Included on macOS hosts |
| legacy | WebKitGTK | Linux | Driver-first (`WebKitWebDriver`) attach/launch + `example.com` fetch; includes MiniBrowser-targeted WebDriver capabilities (`webkitgtk:browserOptions`) validation | Included on Linux hosts |
| modern | Electron | Windows/macOS/Linux | Attach/launch smoke + basic interaction (strict GA blocking when enabled) | Included on all desktop hosts |
| modern | Android WebView bridge | Linux/macOS host with Android tooling (`adb` or `shizuku`) | Discovery + attach/evaluate smoke | Included on Linux/macOS hosts; missing bridge tooling is reported as skip |
| legacy | iOS WKWebView bridge | macOS host with iOS bridge tooling | Discovery + attach/evaluate smoke | Included on macOS hosts; missing bridge tooling is reported as skip |

## Adversarial Gate Semantics
- Gate objective is undetected by default (`OVERALL: PASS` means no detection).
- Any detected automation signals fail the gate.
- Any discovered target that cannot be launched or probed fails the gate.
- Targets not supported on the host platform or not installed are reported as explicit skips.
- Reports include per-target `api=modern|legacy` classification.
- Endpoint scheme, transport, and profile-isolation metadata are diagnostic-only and do not fail detection by themselves.
- Detection classification prioritizes web-observable runtime signals (for example `navigator.webdriver === true`, automation globals, and DOM automation markers).

## TLS/Insecure Cert Contract
- Launch paths default to strict TLS validation and expose `ignore_tls_errors` for opt-in insecure/self-signed certificate handling.
- WebKitGTK maps this to WebDriver `acceptInsecureCerts`; MiniBrowser `--ignore-tls-errors` is added only when MiniBrowser args are explicitly targeted.

## Desktop Target Matrix
| OS | Architectures |
|---|---|
| Windows | x64, arm64 |
| macOS | x64, arm64 |
| Linux | x64, arm64 |
