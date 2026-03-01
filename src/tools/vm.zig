//! VM/QEMU command module.
//! Implementation is currently consolidated in `dispatch.zig`.
const dispatch = @import("dispatch.zig");

pub fn moduleLoaded() void {
    _ = dispatch;
}
