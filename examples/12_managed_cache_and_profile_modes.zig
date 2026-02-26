const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const explicit = std.posix.getenv("ALLDRIVER_EXPLICIT_PATH");

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox },
        .explicit_path = explicit,
        .allow_managed_download = true,
        .managed_cache_dir = "/home/a/.cache/alldriver",
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) {
        std.debug.print("no install candidates\n", .{});
        return;
    }

    // Persistent profile launch.
    var persistent = try driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .persistent,
        .profile_dir = "/tmp/alldriver-profile",
        .headless = true,
        .args = &.{},
    });
    defer persistent.deinit();

    var persistent_page = persistent.page();
    try persistent_page.navigate("https://example.com");
    try persistent.base.waitFor(.dom_ready, 10_000);

    // Ephemeral launch (isolated disposable profile that is deleted on deinit).
    var ephemeral = try driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer ephemeral.deinit();

    var ephemeral_page = ephemeral.page();
    try ephemeral_page.navigate("https://example.com?mode=ephemeral");
    try ephemeral.base.waitFor(.dom_ready, 10_000);
}
