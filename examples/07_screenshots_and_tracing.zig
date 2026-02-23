const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox },
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

    try session.navigate("https://example.com");
    try session.waitFor(.dom_ready, 10_000);

    const png = try session.screenshot(allocator, .png);
    defer allocator.free(png);
    try std.fs.cwd().writeFile(.{ .sub_path = "example-screenshot.png", .data = png });

    if (session.supports(.tracing)) {
        try session.startTracing();
        try session.navigate("https://example.com/?traced=1");
        const trace = try session.stopTracing(allocator);
        defer allocator.free(trace);
        try std.fs.cwd().writeFile(.{ .sub_path = "example-trace.json", .data = trace });
    }

    std.debug.print("artifacts written\n", .{});
}
