# alldriver

Chromium browser automation for Zig 0.16, using the Chrome DevTools Protocol (CDP).

Launch or attach to a browser, navigate pages, send trusted input, inspect network traffic, and collect screenshots, traces, logs, and downloads. The public API lives under `driver.modern`.

Chromium is the supported scope. The required browser integration suite runs against Brave. Firefox/BiDi, other browser engines, and webview platforms remain deferred or unvalidated; catalog entries and successful cross-compilation do not establish runtime support.

## Quick start

```zig
const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var session = try driver.modern.launchAuto(allocator, .{
        .kinds = &.{ .brave, .chrome, .edge },
        .allow_managed_download = false,
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    const image = try page.screenshot(allocator, .png);
    defer allocator.free(image);
}
```

Install with `zig fetch --save git+https://github.com/SmallThingz/alldriver`, then import the dependency's `alldriver` module in your build.

## Validation

Use Zig **0.16.0** and an installed Brave browser:

```sh
zig build
zig build test
zig build examples
zig build test-chromium
```

`test-chromium` is mandatory for browser changes. It runs real browser assertions and **fails when its browser is missing**. Unit tests and example compilation alone do not prove browser behavior. The integration suite uses local fixtures for input, navigation, storage, artifacts, and downloads.

## API

Session domains: `page()`, `runtime()`, `network()`, `input()`, `log()`, `storage()`, `contexts()`, and `targets()`.

- Native keyboard/pointer input, editable text replacement, and browser hit-testing.
- Typed waits, cooperative cancellation, lifecycle events, and diagnostics.
- PNG/JPEG bytes, complete JSON traces, and background console/exception callbacks.
- Explicit download directories with background progress tracking and owned snapshots.
- Cookies, storage, session caches, and deterministic discovery.

See [API documentation](DOCUMENTATION.md), [examples](examples/README.md), [contributing](CONTRIBUTING.md), and [security](SECURITY.md).
