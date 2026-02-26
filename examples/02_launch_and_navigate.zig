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

    if (installs.items.len == 0) {
        std.debug.print("no browser install found\n", .{});
        return;
    }

    var session = try driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });

    var runtime = session.runtime();
    const title_json = try runtime.evaluate("document.title");
    defer allocator.free(title_json);

    std.debug.print("title payload: {s}\n", .{title_json});
    std.debug.print("capabilities: dom={any} js_eval={any} network_intercept={any}\n", .{
        session.capabilities().dom,
        session.capabilities().js_eval,
        session.capabilities().network_intercept,
    });
}
