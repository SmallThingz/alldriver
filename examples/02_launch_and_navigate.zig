const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var launch_op = try driver.modern.launchAutoAsync(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox, .lightpanda },
        .allow_managed_download = false,
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer launch_op.deinit();
    var session = try launch_op.await(30_000);
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
