const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const installs = try driver.discover(allocator, .{
        .kinds = &.{.webkitgtk},
        .allow_managed_download = false,
    }, .{});
    defer driver.freeInstalls(allocator, installs);

    if (installs.len == 0) {
        std.debug.print("no webkitgtk install found\n", .{});
        return;
    }

    var session = try driver.launchWebKitGtkWebView(allocator, .{
        .driver_executable_path = installs[0].runtime_path orelse return error.NoPath,
        .profile_mode = .ephemeral,
    });
    defer session.deinit();

    std.debug.print("navigating...\n", .{});
    try session.navigate("https://example.com");
    std.debug.print("waiting for dom_ready...\n", .{});
    try session.waitFor(.dom_ready, 15_000);

    const title_json = try session.evaluate("document.title");
    defer allocator.free(title_json);

    std.debug.print("title payload: {s}\n", .{title_json});
}
