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
        .timeout_policy = .{
            .navigate_ms = 20_000,
            .wait_ms = 8_000,
        },
    });
    defer launch_op.deinit();
    var session = try launch_op.await(30_000);
    defer session.deinit();

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });

    var cancel_token = driver.CancelToken.init();
    var async_wait = try session.waitForAsync(
        .{ .js_truthy = "window.__never_true__===true" },
        .{ .timeout_ms = 10_000, .cancel_token = &cancel_token },
    );
    defer async_wait.deinit();

    cancel_token.cancel();
    if (async_wait.await(2_000)) |_| {
        std.debug.print("async wait unexpectedly completed\n", .{});
    } else |err| {
        std.debug.print("async wait canceled: {s}\n", .{@errorName(err)});
    }

    session.base.setTimeoutPolicy(.{
        .launch_ms = 15_000,
        .attach_ms = 10_000,
        .navigate_ms = 20_000,
        .wait_ms = 250,
        .network_ms = 10_000,
        .overall_ms = null,
    });

    _ = session.base.waitFor(
        .{ .js_truthy = "window.__never_true__===true" },
        .{ .timeout_ms = null, .poll_interval_ms = 50 },
    ) catch |err| {
        std.debug.print("wait result: {s}\n", .{@errorName(err)});
        if (session.base.lastDiagnostic()) |diag| {
            std.debug.print("diagnostic phase={s} code={s} message={s} elapsed_ms={?d}\n", .{
                @tagName(diag.phase),
                diag.code,
                diag.message,
                diag.elapsed_ms,
            });
        }
        return;
    };

    std.debug.print("timeout/cancel demo completed\n", .{});
}
