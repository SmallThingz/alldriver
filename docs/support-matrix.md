# Support Matrix (Desktop v1)

## Guarantee Model
- Guarantees are by engine adapter, not by browser brand.
- Tier 1 targets full core-capability coverage.
- Tier 2 is best-effort with typed unsupported-capability errors where needed.

## Tier 1
| Engine | Browsers | Platforms |
|---|---|---|
| Chromium | Chrome, Edge, Brave, Vivaldi, Opera GX, Arc, Sidekick, Shift, Epic, DuckDuckGo (desktop availability varies) | Windows, macOS, Linux |
| Gecko | Firefox | Windows, macOS, Linux |
| WebKit | Safari (via `safaridriver` + WebDriver) | macOS |

## Tier 2
| Browser | Engine Family | Expected Contract |
|---|---|---|
| Tor Browser | Gecko-derived | Launch/discovery + best-effort automation surfaces |
| Mullvad Browser | Gecko-derived | Launch/discovery + best-effort automation surfaces |
| LibreWolf | Gecko-derived | Launch/discovery + best-effort automation surfaces |
| Pale Moon | Gecko-derived fork | Limited support; subset depends on exposed protocol surface |
| SigmaOS | Closed-shell / unknown | Discovery/launch coverage; automation depends on exposed interfaces |

## Desktop Target Matrix
| OS | Architectures |
|---|---|
| Windows | x64, arm64 |
| macOS | x64, arm64 |
| Linux | x64, arm64 |
