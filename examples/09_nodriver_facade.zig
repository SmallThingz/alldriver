const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var nd = try driver.nodriver.start(allocator, .{
        .preference = .{
            .kinds = &.{ .chrome, .firefox, .edge },
            .allow_managed_download = false,
        },
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer nd.deinit();

    try nd.get("https://example.com");
    const title = try nd.eval("document.title");
    defer allocator.free(title);

    std.debug.print("nodriver facade payload: {s}\n", .{title});
}
