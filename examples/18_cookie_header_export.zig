const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) {
        std.debug.print("no browser install found\n", .{});
        return;
    }

    var launch_op = try driver.modern.launchAsync(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .ignore_tls_errors = true,
    });
    defer launch_op.deinit();
    var session = try launch_op.await(30_000);
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });

    var storage = session.storage();
    try storage.setCookie(.{ .name = "sid", .value = "A1", .domain = "example.com", .path = "/", .secure = true, .http_only = true });
    try storage.setCookie(.{ .name = "pref", .value = "B2", .domain = "example.com", .path = "/app", .secure = true, .http_only = false });
    try storage.setCookie(.{ .name = "sub", .value = "C3", .domain = ".example.com", .path = "/app", .secure = true, .http_only = true });

    const filtered = try storage.queryCookies(allocator, .{
        .domain = "example.com",
        .include_expired = false,
        .include_http_only = true,
    });
    defer storage.freeCookies(allocator, filtered);

    const cookie_header = try storage.buildCookieHeaderForUrl(
        allocator,
        "https://example.com/app/dashboard",
        .{
            .sort_by_path_len_desc = true,
            .include_http_only = true,
        },
    );
    defer allocator.free(cookie_header);

    std.debug.print("filtered cookies: {d}\n", .{filtered.len});
    std.debug.print("cookie header: {s}\n", .{cookie_header});
}
