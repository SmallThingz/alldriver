const std = @import("std");
const browser_driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var installs = try browser_driver.discover(gpa, .{
        .kinds = &.{ .chrome, .edge, .safari, .firefox, .brave, .tor, .duckduckgo, .mullvad, .librewolf, .epic, .arc, .vivaldi, .sigmaos, .sidekick, .shift, .operagx, .lightpanda, .palemoon },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    try browser_driver.bufferedPrint();

    std.debug.print("Discovered {d} browser installs\n", .{installs.items.len});
    for (installs.items) |install| {
        std.debug.print("- {s} [{s}] at {s} ({s})\n", .{ @tagName(install.kind), @tagName(install.engine), install.path, @tagName(install.source) });
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
