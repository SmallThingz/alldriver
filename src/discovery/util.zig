const std = @import("std");
const builtin = @import("builtin");

pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn normalizePathForKey(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        return std.ascii.allocLowerString(allocator, path);
    }
    return allocator.dupe(u8, path);
}

pub fn expandEnvTemplates(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) {
        return allocator.dupe(u8, raw);
    }

    var replaced = std.ArrayList(u8).empty;
    defer replaced.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%') {
            const close = std.mem.indexOfPos(u8, raw, i + 1, "%");
            if (close) |j| {
                const var_name = raw[i + 1 .. j];
                const value = std.process.getEnvVarOwned(allocator, var_name) catch {
                    try replaced.appendSlice(allocator, raw[i .. j + 1]);
                    i = j + 1;
                    continue;
                };
                defer allocator.free(value);
                try replaced.appendSlice(allocator, value);
                i = j + 1;
                continue;
            }
        }

        try replaced.append(allocator, raw[i]);
        i += 1;
    }

    return replaced.toOwnedSlice(allocator);
}
