const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Replace with your existing endpoint.
    var session = try driver.modern.attach(allocator, "cdp://127.0.0.1:9222/devtools/browser/abc");
    defer session.deinit();

    std.debug.print("attached: transport={s} dom={any}\n", .{
        @tagName(session.base.transport),
        session.supports(.dom),
    });

    if (session.supports(.js_eval)) {
        var runtime = session.runtime();
        const value = try runtime.evaluate("1 + 1");
        defer allocator.free(value);
        std.debug.print("eval payload: {s}\n", .{value});
    }
}
