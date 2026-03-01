const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Downloads and installs the latest Lightpanda release asset for the
    // current OS/arch into managed cache.
    const installed_path = try driver.lightpanda.downloadLatest(allocator, .{});
    defer allocator.free(installed_path);

    std.debug.print("lightpanda installed at: {s}\n", .{installed_path});

    var installs = try driver.modern.discover(allocator, .{
        .kinds = &.{.lightpanda},
        .allow_managed_download = true,
    }, .{});
    defer installs.deinit();

    std.debug.print("lightpanda candidates discovered: {d}\n", .{installs.items.len});
}
