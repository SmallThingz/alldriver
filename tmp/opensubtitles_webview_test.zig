const std = @import("std");
const builtin = @import("builtin");
const driver = @import("alldriver");

const target_url = "https://www.opensubtitles.com/";

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const driver_path = std.posix.getenv("WEBKITGTK_DRIVER");
    var session = driver.launchWebKitGtkWebView(allocator, .{
        .driver_executable_path = driver_path,
        .host = "127.0.0.1",
        .profile_mode = .ephemeral,
        .ignore_tls_errors = true,
    }) catch |err| {
        if (err == error.WebKitGtkWebDriverNotFound) {
            std.debug.print("WebKitGTK driver not found. Install/provide WebKitWebDriver.\n", .{});
        } else {
            std.debug.print("WebKitGTK driver/session startup failed: {s}\n", .{@errorName(err)});
        }
        return err;
    };
    defer session.deinit();

    std.debug.print("WebKitGTK session endpoint: {s}\n", .{session.endpoint.?});

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

    std.debug.print("WebKitGTK session is live. Press Enter to close...\n", .{});
    var one: [1]u8 = undefined;
    while (true) {
        const n = try std.fs.File.stdin().read(&one);
        if (n == 0 or one[0] == '\n') break;
    }
}
