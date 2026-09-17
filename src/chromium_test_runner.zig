comptime {
    _ = @import("tests/brave_transports.zig");
    _ = @import("tests/chromium_behavior.zig");
    _ = @import("tests/chromium_network.zig");
    _ = @import("tests/chromium_lifecycle.zig");
    _ = @import("tests/chromium_downloads.zig");
    _ = @import("tests/chromium_storage.zig");
    _ = @import("tests/chromium_waits.zig");
}
