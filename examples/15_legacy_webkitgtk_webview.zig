const std = @import("std");
const driver = @import("alldriver");

fn findWebKitGtkDriverPath(runtimes: []const driver.WebViewRuntime) ?[]const u8 {
    for (runtimes) |runtime| {
        const path = runtime.runtime_path orelse continue;
        if (driver.strings.containsIgnoreCase(path, "webkitwebdriver")) return path;
    }
    return null;
}

fn findMiniBrowserPath(runtimes: []const driver.WebViewRuntime) ?[]const u8 {
    for (runtimes) |runtime| {
        const path = runtime.runtime_path orelse continue;
        if (driver.strings.containsIgnoreCase(path, "minibrowser")) return path;
    }
    return null;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var runtimes = try driver.legacy.discoverWebViews(allocator, .{
        .kinds = &.{.webkitgtk},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer runtimes.deinit();

    const webdriver_path = findWebKitGtkDriverPath(runtimes.items) orelse {
        std.debug.print("no WebKitWebDriver runtime discovered\n", .{});
        return;
    };
    const minibrowser_path = findMiniBrowserPath(runtimes.items);

    var session = try driver.legacy.launchWebKitGtkWebView(allocator, .{
        .driver_executable_path = webdriver_path,
        .profile_mode = .ephemeral,
        .ignore_tls_errors = true,
        .browser_target = if (minibrowser_path != null) .minibrowser else .auto,
        .browser_binary_path = minibrowser_path,
    });
    defer session.deinit();

    try session.navigate("data:text/html,<html><body><h1 id='t'>webkitgtk</h1></body></html>");
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 20_000 });

    const title = try session.evaluate("document.getElementById('t').textContent");
    defer allocator.free(title);

    std.debug.print("webkitgtk payload: {s}\n", .{title});
}
