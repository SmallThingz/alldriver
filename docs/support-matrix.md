# Support Matrix (CDP/BiDi-Only)

## Protocol Contract
- `modern` is the only public namespace.
- Supported transports: `cdp_ws`, `bidi_ws`.
- WebDriver transport and legacy namespace are removed.

## Browser Coverage
| API Class | Engine | Browsers | Platforms |
|---|---|---|---|
| modern | Chromium | Chrome, Edge, Brave, Vivaldi, Opera GX, Arc, Sidekick, Shift, Epic, DuckDuckGo (desktop availability varies), Lightpanda | Windows, macOS, Linux |
| modern | Gecko | Firefox, Tor, Mullvad, LibreWolf, Pale Moon | Windows, macOS, Linux |

## Not in modern protocol contract
| Browser | Engine | Status |
|---|---|---|
| Safari | WebKit | Unsupported (requires WebDriver) |
| SigmaOS | Unknown | Unsupported (no guaranteed CDP/BiDi surface) |

## WebView Coverage
| Runtime | Platform | Transport |
|---|---|---|
| WebView2 | Windows | CDP |
| Electron | Windows/macOS/Linux | CDP |
| Android WebView bridge | Linux/macOS/Windows host with Android tooling | CDP |

## Adversarial Gate Semantics
- Gate objective is undetected by default.
- Any detected automation signals fail the gate.
- Any discovered target that cannot be launched/probed fails the gate.
- Unsupported or not-installed targets are explicit `SKIP`.
