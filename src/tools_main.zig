const dispatch = @import("tools/dispatch.zig");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |arg| init.gpa.free(arg);
        args.deinit(init.gpa);
    }

    while (args_iter.next()) |arg| {
        try args.append(init.gpa, try init.gpa.dupe(u8, arg));
    }

    try dispatch.mainWithArgs(args.items);
}

test "tools dispatch self-test" {
    _ = dispatch;
}
