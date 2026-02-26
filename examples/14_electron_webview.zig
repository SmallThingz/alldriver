const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{.electron},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer runtimes.deinit();

    if (runtimes.items.len == 0) {
        std.debug.print("no electron runtime discovered\n", .{});
        return;
    }

    const executable_path = runtimes.items[0].runtime_path orelse {
        std.debug.print("discovered electron runtime does not expose a runtime_path\n", .{});
        return;
    };

    var session = try driver.modern.launchElectronWebView(allocator, .{
        .executable_path = executable_path,
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    try session.base.waitFor(.dom_ready, 30_000);

    var runtime = session.runtime();
    const title_payload = try runtime.evaluate("document.title");
    defer allocator.free(title_payload);

    std.debug.print("electron title payload: {s}\n", .{title_payload});
}
