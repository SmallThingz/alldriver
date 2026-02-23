const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox },
        .allow_managed_download = false,
    }, .{});
    defer driver.freeInstalls(allocator, installs);

    if (installs.len == 0) return error.NoBrowserFound;

    var session = try driver.launch(allocator, .{
        .install = installs[0],
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    var nav_op = try session.navigateAsync("https://example.com");
    defer nav_op.deinit();
    try nav_op.await(15_000);

    var wait_op = try session.waitForAsync(.dom_ready, 15_000);
    defer wait_op.deinit();
    try wait_op.await(15_000);

    var eval_op = try session.evaluateAsync("document.title");
    defer eval_op.deinit();
    const title = try eval_op.await(15_000);
    defer allocator.free(title);

    std.debug.print("async title payload: {s}\n", .{title});
}
