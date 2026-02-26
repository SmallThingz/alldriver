//! VM/QEMU command module.
//! Implementation remains in `dispatch.zig` during the refactor migration.
const dispatch = @import("dispatch.zig");

pub fn moduleLoaded() void {
    _ = dispatch;
}
