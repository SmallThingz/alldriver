const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{ .webview2, .wkwebview, .webkitgtk },
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer driver.freeWebViewRuntimes(allocator, runtimes);

    std.debug.print("discovered {d} desktop webview runtime(s)\n", .{runtimes.len});
    if (runtimes.len == 0) return;

    const first = runtimes[0];
    const endpoint = switch (first.kind) {
        .webview2 => "cdp://127.0.0.1:9222/devtools/page/1",
        .wkwebview, .webkitgtk => "webdriver://127.0.0.1:4444/session/1",
        else => return,
    };

    var session = try driver.attachWebView(allocator, .{
        .kind = first.kind,
        .endpoint = endpoint,
    });
    defer session.deinit();

    std.debug.print("attached webview mode={s} transport={s}\n", .{ @tagName(session.mode), @tagName(session.transport) });
}
