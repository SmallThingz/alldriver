const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox },
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

    var page = session.page();
    try page.navigate("https://example.com");
    try session.base.waitFor(.dom_ready, 10_000);

    const png = try page.screenshot(allocator, .png);
    defer allocator.free(png);
    try std.fs.cwd().writeFile(.{ .sub_path = "example-screenshot.png", .data = png });

    if (session.supports(.tracing)) {
        try session.base.startTracing();
        try page.navigate("https://example.com/?traced=1");
        const trace = try session.base.stopTracing(allocator);
        defer allocator.free(trace);
        try std.fs.cwd().writeFile(.{ .sub_path = "example-trace.json", .data = trace });
    }

    std.debug.print("artifacts written\n", .{});
}
