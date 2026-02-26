const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .firefox },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    var session = try driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
    });
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    try session.base.waitFor(.dom_ready, 10_000);

    try session.base.setCookie(.{
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

    var runtime = session.runtime();
    const payload = try runtime.evaluate(local_storage_script);
    defer allocator.free(payload);
    std.debug.print("storage payload: {s}\n", .{payload});
}
