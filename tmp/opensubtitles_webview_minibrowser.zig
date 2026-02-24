const std = @import("std");
const builtin = @import("builtin");
const driver = @import("browser_driver");

const target_url = "https://www.opensubtitles.com/";

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const driver_path = std.posix.getenv("WEBKITGTK_DRIVER");
    const mini_override = std.posix.getenv("WEBKITGTK_MINIBROWSER");
    const browser_target: driver.WebKitGtkBrowserTarget = if (mini_override != null) .custom_binary else .minibrowser;

    var session = driver.launchWebKitGtkWebView(allocator, .{
        .driver_executable_path = driver_path,
        .host = "127.0.0.1",
        .profile_mode = .ephemeral,
        .ignore_tls_errors = true,
        .browser_target = browser_target,
        .browser_binary_path = mini_override,
    }) catch |err| {
        std.debug.print("MiniBrowser-targeted WebKitGTK launch failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer session.deinit();

    std.debug.print("WebKitGTK MiniBrowser-targeted endpoint: {s}\n", .{session.endpoint.?});

    session.navigate(target_url) catch |err| {
        std.debug.print("Navigation failed: {s}\n", .{@errorName(err)});
        return err;
    };
    session.waitFor(.dom_ready, 60_000) catch |err| {
        std.debug.print("DOM ready wait failed ({s}); continuing with probe.\n", .{@errorName(err)});
    };
    session.waitFor(.network_idle, 10_000) catch {};

    const probe = session.evaluate(
        "(function(){return [location.href, location.hostname, document.title, document.readyState].join('\\n');})();",
    ) catch |err| blk: {
        std.debug.print("Page probe failed: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (probe) |payload| {
        defer allocator.free(payload);
        std.debug.print("Page probe:\n{s}\n", .{payload});
    }

    std.debug.print("MiniBrowser-targeted WebKitGTK session is live. Press Enter to close...\n", .{});
    var one: [1]u8 = undefined;
    while (true) {
        const n = try std.fs.File.stdin().read(&one);
        if (n == 0 or one[0] == '\n') break;
    }
}
