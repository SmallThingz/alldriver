const std = @import("std");
const types = @import("../../types.zig");

pub fn capabilitiesFor(engine: types.EngineKind) types.CapabilitySet {
    return switch (engine) {
        .webkit => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = false,
            .tracing = false,
            .downloads = true,
            .bidi_events = false,
        },
        .gecko => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = false,
            .downloads = true,
            .bidi_events = true,
        },
        else => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = false,
            .tracing = false,
            .downloads = true,
            .bidi_events = false,
        },
    };
}

pub fn serializeNewSession(
    allocator: std.mem.Allocator,
    browser_name: []const u8,
    headless: bool,
) ![]u8 {
    const headless_raw = if (headless) "true" else "false";
    return std.mem.concat(allocator, u8, &.{
        "{\"capabilities\":{\"alwaysMatch\":{\"browserName\":\"",
        browser_name,
        "\",\"browserOptions\":{\"headless\":",
        headless_raw,
        "}}}}",
    });
}

test "webdriver serialize new session" {
    const allocator = std.testing.allocator;
    const json = try serializeNewSession(allocator, "firefox", true);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "headless") != null);
}
