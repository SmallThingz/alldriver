const std = @import("std");
const driver = @import("alldriver");

fn printMilestone(event: driver.LifecycleEvent) void {
    switch (event) {
        .response_received => |e| std.debug.print(
            "milestone=response_received url={s} status={any} observed={}\n",
            .{ e.url, e.status, e.observed },
        ),
        .dom_ready => |e| std.debug.print(
            "milestone=dom_ready url={s} observed={}\n",
            .{ e.url, e.observed },
        ),
        .scripts_settled => |e| std.debug.print(
            "milestone=scripts_settled url={s} observed={}\n",
            .{ e.url, e.observed },
        ),
        else => {},
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .brave, .firefox, .lightpanda },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) {
        std.debug.print("no compatible browser install found\n", .{});
        return;
    }

    var launch_op = try driver.modern.launchAsync(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .ignore_tls_errors = true,
    });
    defer launch_op.deinit();
    var session = try launch_op.await(45_000);
    defer session.deinit();

    const sub_id = try session.onEvent(.{
        .kinds = &.{ .response_received, .dom_ready, .scripts_settled },
    }, printMilestone);
    defer _ = session.offEvent(sub_id);

    var page = session.page();
    try page.navigate("https://example.com");
    _ = try session.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 30_000 });

    var net = session.network();

    const records = try net.records(allocator, true);
    defer net.freeRecords(allocator, records);
    std.debug.print("records={d}\n", .{records.len});
    for (records) |record| {
        std.debug.print(
            "record id={s} method={s} url={s} final_status={any} redirects={d} status_points={d} req_body={d} res_body={d}\n",
            .{
                record.request_id,
                record.method,
                record.url,
                record.final_status,
                record.redirects.len,
                record.status_timeline.len,
                if (record.request_body) |b| b.len else 0,
                if (record.response_body) |b| b.len else 0,
            },
        );
    }

    const frames = try net.frames(allocator);
    defer net.freeFrames(allocator, frames);
    std.debug.print("frames={d}\n", .{frames.len});
    for (frames) |frame| {
        std.debug.print("frame id={s} parent={any} url={s}\n", .{ frame.frame_id, frame.parent_frame_id, frame.url });
    }

    const workers = try net.serviceWorkers(allocator);
    defer net.freeServiceWorkers(allocator, workers);
    std.debug.print("service_workers={d}\n", .{workers.len});
    for (workers) |worker| {
        std.debug.print("worker id={s} scope={any} script={any} state={any}\n", .{
            worker.worker_id,
            worker.scope_url,
            worker.script_url,
            worker.state,
        });
    }

    const phase_snapshots = try net.navigationSnapshots(allocator);
    defer net.freeNavigationSnapshots(allocator, phase_snapshots);
    std.debug.print("navigation_snapshots={d}\n", .{phase_snapshots.len});
    for (phase_snapshots) |snap| {
        std.debug.print(
            "snapshot phase={s} url={s} dom_bytes={d} cookies={d} local={d} session={d}\n",
            .{
                @tagName(snap.phase),
                snap.url,
                snap.dom_html.len,
                snap.cookies.len,
                snap.local_storage.len,
                snap.session_storage.len,
            },
        );
    }

    var manual = try net.captureSnapshot(allocator, .manual, null);
    defer net.freeSnapshot(allocator, &manual);
    std.debug.print(
        "manual_snapshot url={s} dom_bytes={d} headers_bytes={d}\n",
        .{ manual.url, manual.dom_html.len, manual.response_headers_json.len },
    );
}
