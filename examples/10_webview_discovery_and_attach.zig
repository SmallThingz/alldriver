const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{ .webview2, .wkwebview, .webkitgtk },
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer runtimes.deinit();

    std.debug.print("discovered {d} desktop webview runtime(s)\n", .{runtimes.items.len});
    if (runtimes.items.len == 0) return;

    const first = runtimes.items[0];
    const endpoint = switch (first.kind) {
        .webview2 => "cdp://127.0.0.1:9222/devtools/page/1",
        .wkwebview, .webkitgtk => "webdriver://127.0.0.1:4444/session/1",
        else => return,
    };

    if (driver.support_tier.webViewTier(first.kind) == .modern) {
        var session = try driver.modern.attachWebView(allocator, .{ .kind = first.kind, .endpoint = endpoint });
        defer session.deinit();
        std.debug.print("attached webview mode={s} transport={s}\n", .{ @tagName(session.base.mode), @tagName(session.base.transport) });
    } else {
        var session = try driver.legacy.attachWebView(allocator, .{ .kind = first.kind, .endpoint = endpoint });
        defer session.deinit();
        std.debug.print("attached webview mode={s} transport={s}\n", .{ @tagName(session.base.mode), @tagName(session.base.transport) });
    }
}
