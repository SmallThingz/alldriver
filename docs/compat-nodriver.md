# nodriver Compatibility Facade

The compatibility facade is available at:
- `src/compat/nodriver_facade.zig`

## Purpose
Provide a migration-friendly API shape over the idiomatic Zig core runtime.

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
const nodriver = @import("browser_driver").nodriver;

var client = try nodriver.start(allocator, .{
    .preference = .{ .kinds = &.{.chrome} },
    .profile_mode = .ephemeral,
});
defer client.deinit();

try client.get("https://example.com");
try client.click("button#submit");
try client.typeText("input[name=q]", "zig automation");
```
