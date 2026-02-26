const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var installs = try driver.discover(allocator, .{
        .kinds = &.{ .safari, .firefox, .chrome },
        .allow_managed_download = false,
    }, .{});
    defer installs.deinit();

    if (installs.items.len == 0) return error.NoBrowserFound;

    const install = installs.items[0];
    if (driver.support_tier.browserTier(install.kind) == .modern) {
        var session = try driver.modern.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
        });
        defer session.deinit();

        var page = session.page();
        try page.navigate("https://example.com");
        _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });

        if (session.supports(.network_intercept)) {
            var network = session.network();
            try network.enable();
            std.debug.print("network interception enabled\n", .{});
        } else {
            std.debug.print("network interception not supported; continuing without it\n", .{});
        }

        if (session.supports(.tracing)) {
            try session.base.startTracing();
            const trace = try session.base.stopTracing(allocator);
            defer allocator.free(trace);
            std.debug.print("trace payload size={d}\n", .{trace.len});
        } else {
            std.debug.print("tracing not supported on selected adapter\n", .{});
        }
    } else {
        var session = try driver.legacy.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
        });
        defer session.deinit();

        try session.navigate("https://example.com");
        _ = try session.base.waitFor(.{ .dom_ready = {} }, .{ .timeout_ms = 10_000 });

        if (session.supports(.network_intercept)) {
            try session.base.enableNetworkInterception();
            std.debug.print("network interception enabled\n", .{});
        } else {
            std.debug.print("network interception not supported; continuing without it\n", .{});
        }
    }
}
