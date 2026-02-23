const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox, .edge },
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

    const page = "data:text/html,<html><body><input id='name'/><button id='go' onclick=\"document.title=document.getElementById('name').value\">Go</button></body></html>";

    try session.navigate(page);
    try session.waitFor(.dom_ready, 10_000);
    try session.waitForSelector("#name", 10_000);

    try session.typeText("#name", "zig-driver");
    try session.click("#go");

    const title = try session.evaluate("document.title");
    defer allocator.free(title);
    std.debug.print("document.title payload: {s}\n", .{title});
}
