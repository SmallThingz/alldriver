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
        // Discovery always checks managed cache. This flag controls whether
        // managed provisioning/download workflows are allowed.
        .allow_managed_download = true,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) {
        std.debug.print("no install candidates\n", .{});
        return;
    }

    // Persistent profile launch. Launch now waits for debug-endpoint readiness
    // before returning, bounded by the launch timeout policy.
    var persistent_launch_op = try driver.modern.launchAsync(allocator, .{
        .install = installs.items[0],
        .profile_mode = .persistent,
        .profile_dir = "/tmp/alldriver-profile",
        .headless = true,
        .args = &.{},
    });
    defer persistent_launch_op.deinit();
    var persistent = try persistent_launch_op.await(30_000);
    defer persistent.deinit();

    var persistent_page = persistent.page();
    try persistent_page.navigate("https://example.com");
    _ = try persistent.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });

    // Ephemeral launch (isolated disposable profile that is deleted on deinit).
    var ephemeral_launch_op = try driver.modern.launchAsync(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer ephemeral_launch_op.deinit();
    var ephemeral = try ephemeral_launch_op.await(30_000);
    defer ephemeral.deinit();

    var ephemeral_page = ephemeral.page();
    try ephemeral_page.navigate("https://example.com?mode=ephemeral");
    _ = try ephemeral.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });
}
