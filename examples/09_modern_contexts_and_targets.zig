const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.modern.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox },
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();

    if (installs.items.len == 0) {
        std.debug.print("no modern browser install found\n", .{});
        return;
    }

    var launch_op = try driver.modern.launchAsync(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer launch_op.deinit();
    var session = try launch_op.await(30_000);
    defer session.deinit();

    var page = session.page();
    try page.navigate("data:text/html,<html><body>contexts-targets</body></html>");
    _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });

    var contexts = session.contexts();
    const existing = try contexts.list(allocator);
    defer contexts.freeList(allocator, existing);

    const created = try contexts.create(allocator);
    defer allocator.free(created.id);

    var targets = session.targets();
    const target_list = try targets.list(allocator);
    defer targets.freeList(allocator, target_list);

    std.debug.print(
        "contexts={d} created={s} targets={d}\n",
        .{ existing.len, created.id, target_list.len },
    );
}
