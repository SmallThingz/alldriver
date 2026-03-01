const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{ .webview2, .electron },
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer runtimes.deinit();

    std.debug.print("discovered {d} desktop webview runtime(s)\n", .{runtimes.items.len});
    if (runtimes.items.len == 0) return;

    const first = runtimes.items[0];
    var session = try driver.modern.attachWebView(allocator, .{
        .kind = first.kind,
        .endpoint = "cdp://127.0.0.1:9222/devtools/page/1",
    });
    defer session.deinit();

    std.debug.print("attached webview mode={s} transport={s}\n", .{
        @tagName(session.base.mode),
        @tagName(session.base.transport),
    });
}
