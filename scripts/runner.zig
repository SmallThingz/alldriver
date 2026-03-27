const std = @import("std");

pub fn runTool(tool_name: []const u8) !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "zig", "build", "tools", "--", tool_name });
    for (args[1..]) |arg| {
        try argv.append(allocator, arg);
    }

    try spawnAndWait(argv.items, allocator);
}

pub fn spawnAndWait(argv: []const []const u8, allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code == 0) return else return error.CommandFailed,
        else => return error.CommandFailed,
    }
}
