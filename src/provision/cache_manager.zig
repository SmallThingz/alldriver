const std = @import("std");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("../discovery/util.zig");

pub const ManagedHit = struct {
    kind: types.BrowserKind,
    engine: types.EngineKind,
    path: []u8,
    source: types.BrowserInstallSource,
    score: i32,
};

pub fn defaultCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".cache", "browser_driver", "browsers" });
}

pub fn discoverManaged(
    allocator: std.mem.Allocator,
    kinds: []const types.BrowserKind,
    maybe_cache_dir: ?[]const u8,
) ![]ManagedHit {
    const cache_dir = if (maybe_cache_dir) |dir|
        try allocator.dupe(u8, dir)
    else
        try defaultCacheDir(allocator);
    defer allocator.free(cache_dir);

    var hits: std.ArrayList(ManagedHit) = .empty;
    errdefer {
        for (hits.items) |hit| allocator.free(hit.path);
        hits.deinit(allocator);
    }

    for (kinds) |kind| {
        const hints = path_table.hintsFor(kind, catalog.nativePlatform());

        // root/<browser-kind>/<exec>
        for (hints.executable_names) |exec_name| {
            const kind_name = @tagName(kind);
            const direct = std.fs.path.join(allocator, &.{ cache_dir, kind_name, exec_name }) catch continue;
            if (util.exists(direct)) {
                try hits.append(allocator, .{
                    .kind = kind,
                    .engine = hints.engine,
                    .path = direct,
                    .source = .managed_cache,
                    .score = hints.confidence_weight + 20,
                });
            } else {
                allocator.free(direct);
            }

            const current = std.fs.path.join(allocator, &.{ cache_dir, kind_name, "current", exec_name }) catch continue;
            if (util.exists(current)) {
                try hits.append(allocator, .{
                    .kind = kind,
                    .engine = hints.engine,
                    .path = current,
                    .source = .managed_cache,
                    .score = hints.confidence_weight + 22,
                });
            } else {
                allocator.free(current);
            }
        }
    }

    return hits.toOwnedSlice(allocator);
}

pub fn installManagedBrowser(
    allocator: std.mem.Allocator,
    kind: types.BrowserKind,
    cache_dir: []const u8,
    download_url: []const u8,
) !void {
    _ = allocator;
    _ = kind;
    _ = cache_dir;
    _ = download_url;
    return error.NotImplemented;
}
