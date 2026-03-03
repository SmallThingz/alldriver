const std = @import("std");
const driver = @import("alldriver");

fn printEvent(event: driver.LifecycleEvent) void {
    switch (event) {
        .navigation_started => |e| std.debug.print("event navigation_started url={s} cause={s}\n", .{ e.url, @tagName(e.cause) }),
        .navigation_completed => |e| std.debug.print("event navigation_completed url={s} cause={s}\n", .{ e.url, @tagName(e.cause) }),
        .response_received => |e| std.debug.print("event response_received url={s} status={any} observed={}\n", .{ e.url, e.status, e.observed }),
        .dom_ready => |e| std.debug.print("event dom_ready url={s} observed={}\n", .{ e.url, e.observed }),
        .scripts_settled => |e| std.debug.print("event scripts_settled url={s} observed={}\n", .{ e.url, e.observed }),
        .challenge_detected => |e| std.debug.print("event challenge_detected url={s} signal={s}\n", .{ e.url, e.signal }),
        .challenge_solved => |e| std.debug.print("event challenge_solved url={s}\n", .{e.url}),
        .cookie_updated => |e| std.debug.print("event cookie_updated domain={s} name={s} change={s} source={s}\n", .{
            e.domain,
            e.name,
            @tagName(e.change),
            @tagName(e.source),
        }),
        else => {},
    }
}

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

    const sub_id = try session.base.onEvent(.{
        .kinds = &.{
            .navigation_started,
            .navigation_completed,
            .response_received,
            .dom_ready,
            .scripts_settled,
            .challenge_detected,
            .challenge_solved,
            .cookie_updated,
        },
    }, printEvent);
    defer _ = session.base.offEvent(sub_id);

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 15_000 });

    var storage = session.storage();
    try storage.setCookie(.{
        .name = "event_cookie",
        .value = "ok",
        .domain = "example.com",
        .path = "/",
        .secure = true,
    });

    var runtime = session.runtime();
    const set_challenge = try runtime.evaluate("document.title='Just a moment...'; window.__event_ready__=true; true;");
    defer allocator.free(set_challenge);

    _ = session.base.waitFor(.{ .js_truthy = "window.__never_true__===true" }, .{ .timeout_ms = 300 }) catch .{
        .matched = false,
        .elapsed_ms = 0,
        .target = .js_truthy,
    };

    const clear_challenge = try runtime.evaluate("document.title='events complete'; true;");
    defer allocator.free(clear_challenge);
    _ = try session.base.waitFor(.{ .js_truthy = "window.__event_ready__===true" }, .{ .timeout_ms = 2_000 });

    var net = session.network();
    const records = try net.records(allocator, false);
    defer net.freeRecords(allocator, records);
    std.debug.print("network records captured: {d}\n", .{records.len});

    const frames = try net.frames(allocator);
    defer net.freeFrames(allocator, frames);
    std.debug.print("frames observed: {d}\n", .{frames.len});

    const workers = try net.serviceWorkers(allocator);
    defer net.freeServiceWorkers(allocator, workers);
    std.debug.print("service workers observed: {d}\n", .{workers.len});

    const snapshots = try net.navigationSnapshots(allocator);
    defer net.freeNavigationSnapshots(allocator, snapshots);
    std.debug.print("navigation snapshots: {d}\n", .{snapshots.len});

    std.debug.print("event hook demo completed\n", .{});
}
