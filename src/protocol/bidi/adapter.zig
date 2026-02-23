const std = @import("std");
const types = @import("../../types.zig");

pub fn capabilitiesFor(engine: types.EngineKind) types.CapabilitySet {
    return switch (engine) {
        .gecko => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = false,
            .downloads = true,
            .bidi_events = true,
        },
        .chromium => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = true,
            .downloads = true,
            .bidi_events = true,
        },
        else => .{
            .dom = false,
            .js_eval = false,
            .network_intercept = false,
            .tracing = false,
            .downloads = false,
            .bidi_events = false,
        },
    };
}

pub fn serializeSubscribe(allocator: std.mem.Allocator, id: u64, event_names: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "[");
    for (event_names, 0..) |name, i| {
        if (i != 0) try list.appendSlice(allocator, ",");
        try list.writer(allocator).print("\"{s}\"", .{name});
    }
    try list.appendSlice(allocator, "]");

    const names_json = try list.toOwnedSlice(allocator);
    defer allocator.free(names_json);

    const id_raw = try std.fmt.allocPrint(allocator, "{d}", .{id});
    defer allocator.free(id_raw);

    return std.mem.concat(allocator, u8, &.{
        "{\"id\":",
        id_raw,
        ",\"method\":\"session.subscribe\",\"params\":{\"events\":",
        names_json,
        "}}",
    });
}

test "bidi subscribe serialize" {
    const allocator = std.testing.allocator;
    const json = try serializeSubscribe(allocator, 11, &.{ "log.entryAdded", "network.beforeRequestSent" });
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "session.subscribe") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "network.beforeRequestSent") != null);
}
