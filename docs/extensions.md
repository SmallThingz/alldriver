# Compile-Time Extensions

Extension hooks are defined in:
- `src/extensions/api.zig`

## Constraints
- Extensions are statically linked at compile time.
- Runtime dynamic loading is intentionally out of scope.

## Hook Points
- Install scoring override/addition: `score_install`
- Launch argument policy: `launch_args`
- Session init notification: `session_init`
- Event observer: `event_observer`

## Registering Hooks
```zig
const ext = @import("browser_driver").extension_hooks;

fn score(install: @import("browser_driver").BrowserInstall) i32 {
    return if (install.kind == .firefox) 20 else 0;
}

pub fn configure() void {
    ext.registerHooks(.{
        .score_install = score,
        .launch_args = null,
        .session_init = null,
        .event_observer = null,
    });
}
```

## Build Integration
`build.zig` exposes:
- `-Denable_builtin_extension=true`

This enables the built-in static adapter (defined in `src/extensions/api.zig`) that adjusts install scoring and launch args.
