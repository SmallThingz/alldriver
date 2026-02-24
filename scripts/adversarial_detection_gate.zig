const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var default_out: ?[]u8 = null;
    defer if (default_out) |path| allocator.free(path);

    try argv.appendSlice(allocator, &.{ "zig", "build", "tools", "--", "adversarial-detection-gate" });
    var has_out = false;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                const key = arg[0..eq];
                const value = arg[eq + 1 ..];
                if (std.mem.eql(u8, key, "--out")) has_out = true;
                try argv.append(allocator, key);
                try argv.append(allocator, value);
                continue;
            }
        }
        if (std.mem.eql(u8, arg, "--out")) has_out = true;
        try argv.append(allocator, arg);
    }
    if (!has_out) {
        try std.fs.cwd().makePath("artifacts/reports");
        const ts = std.time.timestamp();
        const out = try std.fmt.allocPrint(allocator, "artifacts/reports/adversarial-detection-{d}.txt", .{ts});
        default_out = out;
        try argv.appendSlice(allocator, &.{ "--out", out });
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code == 0) return else return error.CommandFailed,
        else => return error.CommandFailed,
    }
}
