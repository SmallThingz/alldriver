const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .safari, .firefox, .chrome },
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

    if (session.supports(.network_intercept)) {
        try session.enableNetworkInterception();
        std.debug.print("network interception enabled\n", .{});
    } else {
        std.debug.print("network interception not supported; continuing without it\n", .{});
    }

    if (session.supports(.tracing)) {
        try session.startTracing();
        const trace = try session.stopTracing(allocator);
        defer allocator.free(trace);
        std.debug.print("trace payload size={d}\n", .{trace.len});
    } else {
        std.debug.print("tracing not supported on selected adapter\n", .{});
    }
}
