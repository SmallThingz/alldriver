const std = @import("std");
const driver = @import("alldriver");

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

    if (!session.supports(.network_intercept)) {
        std.debug.print("network interception not supported by selected adapter\n", .{});
        return;
    }

    var network = session.network();
    network.onRequest(onRequest);
    network.onResponse(onResponse);

    try network.enable();
    try network.addRule(.{
        .id = "block-trackers",
        .url_pattern = "*://*/tracker/*",
        .action = .{ .block = {} },
    });

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });

    _ = try network.removeRule("block-trackers");
}
