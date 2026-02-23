const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("util.zig");

pub const WindowsHit = struct {
    kind: types.BrowserKind,
    engine: types.EngineKind,
    path: []u8,
    source: types.BrowserInstallSource,
    score: i32,
};

pub fn collect(allocator: std.mem.Allocator, kinds: []const types.BrowserKind) ![]WindowsHit {
    if (builtin.os.tag != .windows) return allocator.alloc(WindowsHit, 0);

    var hits: std.ArrayList(WindowsHit) = .empty;
    errdefer {
        for (hits.items) |hit| allocator.free(hit.path);
        hits.deinit(allocator);
    }

    for (kinds) |kind| {
        const hints = path_table.hintsFor(kind, catalog.nativePlatform());

        for (hints.known_paths) |raw_path| {
            const expanded = try util.expandEnvTemplates(allocator, raw_path);
            defer allocator.free(expanded);
            if (!util.exists(expanded)) continue;

            const src: types.BrowserInstallSource = if (hints.windows_registry_hints.len > 0) .registry else .known_path;
            try hits.append(allocator, .{
                .kind = kind,
                .engine = hints.engine,
                .path = try allocator.dupe(u8, expanded),
                .source = src,
                .score = hints.confidence_weight + 10,
            });
        }

        const program_files_hits = try collectProgramFilesCandidates(allocator, kind, hints);
        defer {
            for (program_files_hits) |hit| allocator.free(hit.path);
            allocator.free(program_files_hits);
        }
        for (program_files_hits) |hit| {
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

fn collectProgramFilesCandidates(allocator: std.mem.Allocator, kind: types.BrowserKind, hints: path_table.BrowserPathHints) ![]WindowsHit {
    var out: std.ArrayList(WindowsHit) = .empty;
    errdefer {
        for (out.items) |hit| allocator.free(hit.path);
        out.deinit(allocator);
    }

    const program_files = std.process.getEnvVarOwned(allocator, "ProgramFiles") catch null;
    defer if (program_files) |v| allocator.free(v);

    const program_files_x86 = std.process.getEnvVarOwned(allocator, "ProgramFiles(x86)") catch null;
    defer if (program_files_x86) |v| allocator.free(v);

    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(allocator);
    if (program_files) |v| try roots.append(allocator, v);
    if (program_files_x86) |v| try roots.append(allocator, v);

    for (roots.items) |root| {
        for (hints.executable_names) |exec_name| {
            const full = try std.fs.path.join(allocator, &.{ root, exec_name });
            defer allocator.free(full);
            if (!util.exists(full)) continue;

            try out.append(allocator, .{
                .kind = kind,
                .engine = hints.engine,
                .path = try allocator.dupe(u8, full),
                .source = .registry,
                .score = hints.confidence_weight + 3,
            });
        }
    }

    return out.toOwnedSlice(allocator);
}

test "collect returns empty on non-windows hosts" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const hits = try collect(allocator, &.{ .chrome, .edge, .firefox });
    defer allocator.free(hits);

    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
