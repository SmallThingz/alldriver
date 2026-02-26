const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var child = std.process.Child.init(&[_][]const u8{ "WebKitWebDriver", "--port=4444" }, allocator);
    try child.spawn();
    defer _ = child.kill() catch {};

    std.time.sleep(1 * std.time.ns_per_s);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const body = "{\"capabilities\":{\"alwaysMatch\":{\"webkitgtk:browserOptions\":{\"binary\":\"/usr/lib/webkitgtk-6.0/MiniBrowser\"}}}}";

    var head_buf: [4096]u8 = undefined;
    var req = try client.open(.POST, try std.Uri.parse("http://127.0.0.1:4444/session"), .{ .server_header_buffer = &head_buf });
    defer req.deinit();

    try req.send();
    try req.writeAll(body);
    try req.finish();

    try req.wait();

    var body_buf: [4096]u8 = undefined;
    const read_len = try req.readAll(&body_buf);
    std.debug.print("Response: {s}\n", .{body_buf[0..read_len]});
}
