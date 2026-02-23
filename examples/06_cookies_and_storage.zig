const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox },
        .allow_managed_download = false,
    }, .{});
    defer driver.freeInstalls(allocator, installs);

    if (installs.len == 0) return error.NoBrowserFound;

    var session = try driver.launch(allocator, .{
        .install = installs[0],
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    try session.navigate("https://example.com");
    try session.waitFor(.dom_ready, 10_000);

    try session.setCookie(.{
        .name = "session_id",
        .value = "abc123",
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .http_only = true,
    });

    const local_storage_script =
        "localStorage.setItem('token','hello'); " ++
        "JSON.stringify({cookie: document.cookie, token: localStorage.getItem('token')});";

    const payload = try session.evaluate(local_storage_script);
    defer allocator.free(payload);
    std.debug.print("storage payload: {s}\n", .{payload});
}
