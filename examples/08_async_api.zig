const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    var session = try driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    var nav_op = try session.navigateAsync("https://example.com");
    defer nav_op.deinit();
    try nav_op.await(15_000);

    var wait_op = try session.waitForAsync(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });
    defer wait_op.deinit();
    _ = try wait_op.await(15_000);

    var eval_op = try session.evaluateAsync("document.title");
    defer eval_op.deinit();
    const title = try eval_op.await(15_000);
    defer allocator.free(title);

    std.debug.print("async title payload: {s}\n", .{title});
}
