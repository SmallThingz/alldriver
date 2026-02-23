const std = @import("std");
const types = @import("../../types.zig");
const common = @import("../common.zig");

pub fn capabilities() types.CapabilitySet {
    return common.defaultCapabilityForEngine(.chromium);
}

pub fn serializeCommand(
    allocator: std.mem.Allocator,
    id: u64,
    method: []const u8,
    params_json: ?[]const u8,
) ![]u8 {
    if (params_json) |params| {
        return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
    }

    return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
}

test "cdp serialize command" {
    const allocator = std.testing.allocator;
    const json = try serializeCommand(allocator, 7, "Page.navigate", "{\"url\":\"https://example.com\"}");
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "Page.navigate") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":7") != null);
}
