const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox, .safari, .brave },
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer installs.deinit();

    std.debug.print("found {d} install(s)\n", .{installs.items.len});
    for (installs.items, 0..) |install, i| {
        std.debug.print(
            "#{d} kind={s} engine={s} source={s} path={s}\n",
            .{ i, @tagName(install.kind), @tagName(install.engine), @tagName(install.source), install.path },
        );
    }
}
