const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("util.zig");

pub const MacHit = struct {
    kind: types.BrowserKind,
    engine: types.EngineKind,
    path: []u8,
    source: types.BrowserInstallSource,
    score: i32,
};

pub fn collect(allocator: std.mem.Allocator, kinds: []const types.BrowserKind) ![]MacHit {
    if (builtin.os.tag != .macos) return allocator.alloc(MacHit, 0);

    var hits: std.ArrayList(MacHit) = .empty;
    errdefer {
        for (hits.items) |hit| allocator.free(hit.path);
        hits.deinit(allocator);
    }

    for (kinds) |kind| {
        const hints = path_table.hintsFor(kind, catalog.nativePlatform());

        for (hints.known_paths) |candidate| {
            if (!util.exists(candidate)) continue;
            const source: types.BrowserInstallSource = if (std.mem.endsWith(u8, candidate, "safaridriver")) .known_path else .app_bundle;
            try hits.append(allocator, .{
                .kind = kind,
                .engine = hints.engine,
                .path = try allocator.dupe(u8, candidate),
                .source = source,
                .score = hints.confidence_weight + 12,
            });
        }

        const found_in_dirs = try scanApplicationDirs(allocator, kind, hints);
        defer {
            for (found_in_dirs) |hit| allocator.free(hit.path);
            allocator.free(found_in_dirs);
        }
        for (found_in_dirs) |hit| {
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

fn scanApplicationDirs(allocator: std.mem.Allocator, kind: types.BrowserKind, hints: path_table.BrowserPathHints) ![]MacHit {
    var out: std.ArrayList(MacHit) = .empty;
    errdefer {
        for (out.items) |hit| allocator.free(hit.path);
        out.deinit(allocator);
    }

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |h| allocator.free(h);

    var roots: std.ArrayList([]const u8) = .empty;
    var owned_roots: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_roots.items) |path| allocator.free(path);
        owned_roots.deinit(allocator);
    }
    defer roots.deinit(allocator);
    try roots.append(allocator, "/Applications");
    if (home) |h| {
        const user_apps = try std.fs.path.join(allocator, &.{ h, "Applications" });
        defer allocator.free(user_apps);
        const owned = try allocator.dupe(u8, user_apps);
        try owned_roots.append(allocator, owned);
        try roots.append(allocator, owned);
    }

    for (roots.items) |root| {
        var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch continue;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".app")) continue;

            for (hints.executable_names) |exec_name| {
                const executable = try std.fs.path.join(allocator, &.{ root, entry.name, "Contents", "MacOS", exec_name });
                defer allocator.free(executable);
                if (!util.exists(executable)) continue;

                try out.append(allocator, .{
                    .kind = kind,
                    .engine = hints.engine,
                    .path = try allocator.dupe(u8, executable),
                    .source = .app_bundle,
                    .score = hints.confidence_weight + 4,
                });
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

test "collect returns empty on non-macos hosts" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const hits = try collect(allocator, &.{ .safari, .chrome, .firefox });
    defer allocator.free(hits);

    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
