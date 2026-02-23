const std = @import("std");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("util.zig");

pub const PathHit = struct {
    kind: types.BrowserKind,
    engine: types.EngineKind,
    path: []u8,
    source: types.BrowserInstallSource,
    score: i32,
};

pub fn collect(allocator: std.mem.Allocator, kinds: []const types.BrowserKind) ![]PathHit {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return allocator.alloc(PathHit, 0);
    defer allocator.free(path_env);
    return collectFromPathValue(allocator, kinds, path_env);
}

fn collectFromPathValue(
    allocator: std.mem.Allocator,
    kinds: []const types.BrowserKind,
    path_env: []const u8,
) ![]PathHit {
    var hits: std.ArrayList(PathHit) = .empty;
    errdefer {
        for (hits.items) |hit| allocator.free(hit.path);
        hits.deinit(allocator);
    }

    var dir_it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dir_it.next()) |dir_raw| {
        const dir = std.mem.trim(u8, dir_raw, " \t\r\n\"");
        if (dir.len == 0) continue;

        for (kinds) |kind| {
            const hints = path_table.hintsFor(kind, catalog.nativePlatform());
            for (hints.executable_names) |exec_name| {
                if (exec_name.len == 0) continue;

                const candidate = std.fs.path.join(allocator, &.{ dir, exec_name }) catch continue;
                if (!util.exists(candidate)) {
                    allocator.free(candidate);
                    continue;
                }

                try hits.append(allocator, .{
                    .kind = kind,
                    .engine = hints.engine,
                    .path = candidate,
                    .source = .path_env,
                    .score = hints.confidence_weight + 15,
                });
            }
        }
    }

    return hits.toOwnedSlice(allocator);
}

test "collect from explicit PATH value finds executable alias" {
    const allocator = std.testing.allocator;
    const platform = catalog.nativePlatform();
    const hints = path_table.hintsFor(.chrome, platform);
    if (hints.executable_names.len == 0) return error.SkipZigTest;

    const exec_name = hints.executable_names[0];
    if (exec_name.len == 0) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = exec_name,
        .data = "stub\n",
    });

    const path_value = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(path_value);

    const hits = try collectFromPathValue(allocator, &.{.chrome}, path_value);
    defer {
        for (hits) |hit| allocator.free(hit.path);
        allocator.free(hits);
    }

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(types.BrowserKind.chrome, hits[0].kind);
    try std.testing.expectEqual(types.BrowserInstallSource.path_env, hits[0].source);
}
