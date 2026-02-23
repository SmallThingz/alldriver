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

    if (installs.len == 0) {
        std.debug.print("no browser install found\n", .{});
        return;
    }

    var session = try driver.launch(allocator, .{
        .install = installs[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer session.deinit();

    try session.navigate("https://example.com");
    try session.waitFor(.dom_ready, 15_000);

    const title_json = try session.evaluate("document.title");
    defer allocator.free(title_json);

    std.debug.print("title payload: {s}\n", .{title_json});
    std.debug.print("capabilities: dom={any} js_eval={any} network_intercept={any}\n", .{
        session.capabilities().dom,
        session.capabilities().js_eval,
        session.capabilities().network_intercept,
    });
}
