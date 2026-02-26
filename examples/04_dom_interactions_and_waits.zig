const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox, .edge },
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

    const page_data = "data:text/html,<html><body><input id='name'/><button id='go' onclick=\"document.title=document.getElementById('name').value\">Go</button></body></html>";

    var page = session.page();
    try page.navigate(page_data);
    try session.base.waitFor(.dom_ready, 10_000);
    try session.base.waitForSelector("#name", 10_000);

    var input = session.input();
    try input.typeText("#name", "zig-driver");
    try input.click("#go");

    var runtime = session.runtime();
    const title = try runtime.evaluate("document.title");
    defer allocator.free(title);
    std.debug.print("document.title payload: {s}\n", .{title});
}
