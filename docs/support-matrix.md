# Support Matrix (Desktop/WebView v1)

## Guarantee Model
- Guarantees are validated per browser and per platform in the manual GA matrix.
- Tier 1 and Tier 2 are both release-gating for GA.
- If any in-scope Tier 2 browser fails functional validation, GA is blocked.

## Tier 1
| Engine | Browsers | Platforms |
|---|---|---|
| Chromium | Chrome, Edge, Brave, Vivaldi, Opera GX, Arc, Sidekick, Shift, Epic, DuckDuckGo (desktop availability varies) | Windows, macOS, Linux |
| Gecko | Firefox | Windows, macOS, Linux |
| WebKit | Safari (via `safaridriver` + WebDriver) | macOS |

## Tier 2 (GA-Blocking in Strict Mode)
| Browser | Engine Family | Expected Contract |
|---|---|---|
| Tor Browser | Gecko-derived | Full functional suite pass required for GA |
| Mullvad Browser | Gecko-derived | Full functional suite pass required for GA |
| LibreWolf | Gecko-derived | Full functional suite pass required for GA |
| Pale Moon | Gecko-derived fork | Full functional suite pass required for GA |
| SigmaOS | Closed-shell / unknown | Full functional suite pass required for GA |

## WebView Coverage
| Runtime | Platform | GA Requirement |
|---|---|---|
| WebView2 | Windows | Attach/launch smoke + basic interaction |
| WKWebView | macOS | Attach/launch smoke + basic interaction |
| WebKitGTK | Linux | Attach/launch smoke + basic interaction |
| Android WebView bridge | Linux/macOS host with Android tooling | Discovery + attach/evaluate smoke |
| iOS WKWebView bridge | macOS host with iOS bridge tooling | Discovery + attach/evaluate smoke |

## Desktop Target Matrix
| OS | Architectures |
|---|---|
| Windows | x64, arm64 |
| macOS | x64, arm64 |
| Linux | x64, arm64 |
