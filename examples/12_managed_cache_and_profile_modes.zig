const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const explicit = std.posix.getenv("BROWSER_DRIVER_EXPLICIT_PATH");

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox },
        .explicit_path = explicit,
        .allow_managed_download = true,
        .managed_cache_dir = "/home/a/.cache/browser_driver",
    }, .{});
    defer driver.freeInstalls(allocator, installs);

    if (installs.len == 0) {
        std.debug.print("no install candidates\n", .{});
        return;
    }

    // Persistent profile launch.
    var persistent = try driver.launch(allocator, .{
        .install = installs[0],
        .profile_mode = .persistent,
        .profile_dir = "/tmp/browser-driver-profile",
        .headless = true,
        .args = &.{},
    });
    defer persistent.deinit();

    try persistent.navigate("https://example.com");
    try persistent.waitFor(.dom_ready, 10_000);

    // Ephemeral launch.
    var ephemeral = try driver.launch(allocator, .{
        .install = installs[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer ephemeral.deinit();

    try ephemeral.navigate("https://example.com?mode=ephemeral");
    try ephemeral.waitFor(.dom_ready, 10_000);
}
