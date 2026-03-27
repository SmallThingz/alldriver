const std = @import("std");
const alldriver = @import("alldriver");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var installs = try alldriver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .safari, .firefox, .brave, .tor, .duckduckgo, .mullvad, .librewolf, .epic, .arc, .vivaldi, .sigmaos, .sidekick, .shift, .operagx, .lightpanda, .palemoon },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    try alldriver.bufferedPrint();

    std.debug.print("Discovered {d} browser installs\n", .{installs.items.len});
    for (installs.items) |install| {
        std.debug.print("- {s} [{s}] at {s} ({s})\n", .{ @tagName(install.kind), @tagName(install.engine), install.path, @tagName(install.source) });
    }
}

test "simple test" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(allocator);
    try list.append(allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
