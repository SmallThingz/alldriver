const std = @import("std");
const driver = @import("browser_driver");

fn onRequest(evt: driver.RequestEvent) void {
    std.debug.print("request: {s} {s}\n", .{ evt.method, evt.url });
}

fn onResponse(evt: driver.ResponseEvent) void {
    std.debug.print("response: {d} {s}\n", .{ evt.status, evt.url });
}

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

    if (!session.supports(.network_intercept)) {
        std.debug.print("network interception not supported by selected adapter\n", .{});
        return;
    }

    session.onRequest(onRequest);
    session.onResponse(onResponse);

    try session.enableNetworkInterception();
    try session.addInterceptRule(.{
        .id = "block-trackers",
        .url_pattern = "*://*/tracker/*",
        .action = .{ .block = {} },
    });

    try session.navigate("https://example.com");
    try session.waitFor(.dom_ready, 10_000);

    _ = try session.removeInterceptRule("block-trackers");
}
