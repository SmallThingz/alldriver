const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("util.zig");

pub const LinuxHit = struct {
    kind: types.BrowserKind,
    engine: types.EngineKind,
    path: []u8,
    source: types.BrowserInstallSource,
    score: i32,
};

pub fn collect(allocator: std.mem.Allocator, kinds: []const types.BrowserKind) ![]LinuxHit {
    if (builtin.os.tag != .linux) return allocator.alloc(LinuxHit, 0);

    var hits: std.ArrayList(LinuxHit) = .empty;
    errdefer {
        for (hits.items) |hit| allocator.free(hit.path);
        hits.deinit(allocator);
    }

    for (kinds) |kind| {
        const hints = path_table.hintsFor(kind, catalog.nativePlatform());

        for (hints.known_paths) |candidate| {
            if (!util.exists(candidate)) continue;
            try hits.append(allocator, .{
                .kind = kind,
                .engine = hints.engine,
                .path = try allocator.dupe(u8, candidate),
                .source = .package_db,
                .score = hints.confidence_weight + 8,
            });
        }

        const desktop_hits = try parseDesktopEntries(allocator, kind, hints);
        defer {
            for (desktop_hits) |hit| allocator.free(hit.path);
            allocator.free(desktop_hits);
        }
        for (desktop_hits) |hit| {
            try hits.append(allocator, .{
                .kind = hit.kind,
                .engine = hit.engine,
                .path = try allocator.dupe(u8, hit.path),
                .source = hit.source,
                .score = hit.score,
            });
        }
    }

    return hits.toOwnedSlice(allocator);
}

fn parseDesktopEntries(allocator: std.mem.Allocator, kind: types.BrowserKind, hints: path_table.BrowserPathHints) ![]LinuxHit {
    var out: std.ArrayList(LinuxHit) = .empty;
    errdefer {
        for (out.items) |hit| allocator.free(hit.path);
        out.deinit(allocator);
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |h| allocator.free(h);

    var dirs: std.ArrayList([]const u8) = .empty;
    var owned_dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_dirs.items) |d| allocator.free(d);
        owned_dirs.deinit(allocator);
    }
    defer dirs.deinit(allocator);
    try dirs.append(allocator, "/usr/share/applications");
    try dirs.append(allocator, "/usr/local/share/applications");
    if (home) |h| {
        const local_dir = try std.fs.path.join(allocator, &.{ h, ".local/share/applications" });
        defer allocator.free(local_dir);
        const owned = try allocator.dupe(u8, local_dir);
        try owned_dirs.append(allocator, owned);
        try dirs.append(allocator, owned);
    }

    for (dirs.items) |dir_path| {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(full_path);

            const file_data = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch continue;
            defer allocator.free(file_data);

            const exec_line = findExecLine(file_data) orelse continue;
            const executable = parseExecBinary(allocator, exec_line) orelse continue;
            defer allocator.free(executable);

            if (!matchesExecutableName(executable, hints.executable_names)) continue;

            const resolved = resolveExecutablePath(allocator, executable) catch continue;
            defer allocator.free(resolved);
            if (!util.exists(resolved)) continue;

            try out.append(allocator, .{
                .kind = kind,
                .engine = hints.engine,
                .path = try allocator.dupe(u8, resolved),
                .source = .package_db,
                .score = hints.confidence_weight + 5,
            });
        }
    }

    return out.toOwnedSlice(allocator);
}

fn findExecLine(file_data: []const u8) ?[]const u8 {
    var line_it = std.mem.splitScalar(u8, file_data, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Exec=")) {
            return std.mem.trim(u8, line[5..], " \t\r");
        }
    }
    return null;
}

fn parseExecBinary(allocator: std.mem.Allocator, exec_line: []const u8) ?[]u8 {
    const raw = std.mem.trim(u8, exec_line, " \t\r\n");
    if (raw.len == 0) return null;

    if (raw[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, raw, 1, '"') orelse return null;
        return allocator.dupe(u8, raw[1..close]) catch null;
    }

    var split = std.mem.splitScalar(u8, raw, ' ');
    const first = split.next() orelse return null;
    return allocator.dupe(u8, first) catch null;
}

fn matchesExecutableName(candidate: []const u8, names: []const []const u8) bool {
    const base = std.fs.path.basename(candidate);
    for (names) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

fn resolveExecutablePath(allocator: std.mem.Allocator, executable: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(executable)) {
        return allocator.dupe(u8, executable);
    }

    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return allocator.dupe(u8, executable);
    defer allocator.free(path_env);

    var dir_it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dir_it.next()) |dir_raw| {
        const dir = std.mem.trim(u8, dir_raw, " \t\r\n\"");
        if (dir.len == 0) continue;

        const joined = std.fs.path.join(allocator, &.{ dir, executable }) catch continue;
        if (util.exists(joined)) return joined;
        allocator.free(joined);
    }

    return allocator.dupe(u8, executable);
}
