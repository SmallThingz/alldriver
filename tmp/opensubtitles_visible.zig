const std = @import("std");
const driver = @import("alldriver");

const target_url = "https://www.opensubtitles.com/";

fn runWithInstall(allocator: std.mem.Allocator, install: driver.BrowserInstall, profile_dir: []const u8) !void {
    std.debug.print("Launching {s} ({s}) at {s}\n", .{
        @tagName(install.kind),
        @tagName(install.engine),
        install.path,
    });
    std.debug.print("Using persistent profile at {s}\n", .{profile_dir});

    var session = try driver.launch(allocator, .{
        .install = install,
        .profile_mode = .persistent,
        .profile_dir = profile_dir,
        .headless = false,
        .args = &.{
            "--no-sandbox",
            "--disable-dev-shm-usage",
        },
    });
    defer session.deinit();

    try session.navigate(target_url);
    try session.waitFor(.dom_ready, 30_000);

    std.debug.print("Opened {s}\nPress Enter to close the browser...\n", .{target_url});

    var one: [1]u8 = undefined;
    while (true) {
        const n = try std.fs.File.stdin().read(&one);
        if (n == 0 or one[0] == '\n') break;
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .brave, .firefox, .vivaldi },
        .allow_managed_download = false,
    }, .{});
    defer driver.freeInstalls(allocator, installs);

    const profile_dir = std.posix.getenv("ALLDRIVER_VISIBLE_PROFILE_DIR") orelse "/tmp/alldriver-visible-profile";

    if (installs.len == 0) {
        std.debug.print("No supported browser install found.\n", .{});
        return;
    }

    var last_error: ?anyerror = null;
    for (installs) |install| {
        runWithInstall(allocator, install, profile_dir) catch |err| {
            last_error = err;
            std.debug.print("Launch attempt failed: {s}\n", .{@errorName(err)});
            continue;
        };
        return;
    }

    if (last_error) |err| return err;
}
