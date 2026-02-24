const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = &.{.electron},
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = false,
    });
    defer driver.freeWebViewRuntimes(allocator, runtimes);

    if (runtimes.len == 0) {
        std.debug.print("no electron runtime discovered\n", .{});
        return;
    }

    const executable_path = runtimes[0].runtime_path orelse {
        std.debug.print("discovered electron runtime does not expose a runtime_path\n", .{});
        return;
    };

    var session = try driver.launchElectronWebView(allocator, .{
        .executable_path = executable_path,
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    try session.navigate("https://example.com");
    try session.waitFor(.dom_ready, 30_000);

    const title_payload = try session.evaluate("document.title");
    defer allocator.free(title_payload);

    std.debug.print("electron title payload: {s}\n", .{title_payload});
}
