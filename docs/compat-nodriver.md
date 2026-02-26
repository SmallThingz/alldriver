# nodriver Compatibility Facade

The compatibility facade is available at:
- `src/compat/nodriver_facade.zig`

Note:
- Root launch/attach shims were removed; this facade remains available as a dedicated compatibility layer.

## Purpose
Provide a migration-friendly API shape over the idiomatic Zig core runtime.

## Behavior Contract
- Facade launch is Chromium-only (`chrome`, `edge`, `brave`, plus `lightpanda` only when built with `-Dinclude_lightpanda_browser=true`).
- Chromium sessions are driverless (CDP transport), matching nodriver-style operation.
- Facade does not fall back to WebDriver engines.

## Mapping
| nodriver-style concept | Zig facade |
|---|---|
| Start browser | `nodriver.start(...)` |
| Navigate | `facade.get(url)` |
| Click | `facade.click(selector)` |
| Type text | `facade.typeText(selector, text)` |
| Evaluate JS | `facade.eval(script)` |
| Shutdown | `facade.deinit()` |

## Example
```zig
const nodriver = @import("alldriver").nodriver;

var client = try nodriver.start(allocator, .{
    .preference = .{ .kinds = &.{.chrome} },
    .profile_mode = .ephemeral,
});
defer client.deinit();

try client.get("https://example.com");
try client.click("button#submit");
try client.typeText("input[name=q]", "zig automation");
```
