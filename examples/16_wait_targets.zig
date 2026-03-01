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

    _ = try session.base.waitFor(.{ .url_contains = "example.com" }, .{ .timeout_ms = 15_000 });
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });

    var runtime = session.runtime();
    const bootstrap = try runtime.evaluate(
        "document.body.insertAdjacentHTML('beforeend','<div id=\"ready\">ready</div>');" ++
            "localStorage.setItem('alldriver_wait_key','1');" ++
            "window.__wait_ready__=true; true;",
    );
    defer allocator.free(bootstrap);

    _ = try session.base.waitFor(.{ .selector_visible = "#ready" }, .{ .timeout_ms = 5_000 });
    _ = try session.base.waitFor(.{ .storage_key_present = .{ .key = "alldriver_wait_key", .area = .local } }, .{ .timeout_ms = 5_000 });
    _ = try session.base.waitFor(.{ .js_truthy = "window.__wait_ready__===true" }, .{ .timeout_ms = 5_000 });

    var storage = session.storage();
    try storage.setCookie(.{
        .name = "wait_cookie",
        .value = "ok",
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .http_only = true,
    });

    _ = try session.base.waitFor(.{
        .cookie_present = .{
            .name = "wait_cookie",
            .domain = "example.com",
            .path = "/",
        },
    }, .{ .timeout_ms = 5_000 });

    std.debug.print("wait targets completed\n", .{});
}
