const std = @import("std");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const path_scan = @import("path_scan.zig");
const windows_registry = @import("windows_registry.zig");
const macos_apps = @import("macos_apps.zig");
const linux_sources = @import("linux_sources.zig");
const cache_manager = @import("../provision/cache_manager.zig");
const extensions = @import("../extensions/api.zig");
const util = @import("util.zig");
const string_util = @import("../util/strings.zig");
const config = @import("alldriver_config");

const Candidate = struct {
    install: types.BrowserInstall,
    score: i32,
};

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) ![]types.BrowserInstall {
    const requested_kinds = if (prefs.kinds.len == 0) path_table.all_browser_kinds[0..] else prefs.kinds;
    const kinds = try filterEnabledKinds(allocator, requested_kinds);
    defer allocator.free(kinds);

    if (kinds.len == 0) {
        return allocator.alloc(types.BrowserInstall, 0);
    }

    var candidates: std.ArrayList(Candidate) = .empty;
    var keys: std.ArrayList([]u8) = .empty;
    var dedup: std.StringHashMap(usize) = .init(allocator);

    errdefer {
        for (candidates.items) |candidate| {
            allocator.free(candidate.install.path);
            if (candidate.install.version) |v| allocator.free(v);
        }
        candidates.deinit(allocator);

        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
        dedup.deinit();
    }

    if (prefs.explicit_path) |path| {
        const expanded = try util.expandEnvTemplates(allocator, path);
        defer allocator.free(expanded);

        if (!util.exists(expanded)) {
            return error.InvalidExplicitPath;
        }

        const explicit_kind = inferKindFromPath(expanded, kinds);
        try appendCandidate(
            allocator,
            &candidates,
            &dedup,
            &keys,
            .{
                .install = .{
                    .kind = explicit_kind,
                    .engine = catalog.engineFor(explicit_kind),
                    .path = try allocator.dupe(u8, expanded),
                    .version = null,
                    .source = .explicit,
                },
                .score = 1000,
            },
        );
    }

    try appendBundledLightpandaCandidate(allocator, &candidates, &dedup, &keys, kinds);

    if (prefs.allow_managed_download) {
        const managed_hits = try cache_manager.discoverManaged(allocator, kinds, prefs.managed_cache_dir);
        defer {
            for (managed_hits) |hit| allocator.free(hit.path);
            allocator.free(managed_hits);
        }

        for (managed_hits) |hit| {
            try appendCandidate(
                allocator,
                &candidates,
                &dedup,
                &keys,
                .{
                    .install = .{
                        .kind = hit.kind,
                        .engine = hit.engine,
                        .path = try allocator.dupe(u8, hit.path),
                        .version = null,
                        .source = hit.source,
                    },
                    .score = hit.score,
                },
            );
        }
    }

    if (opts.include_path_env) {
        const path_hits = try path_scan.collect(allocator, kinds);
        defer {
            for (path_hits) |hit| allocator.free(hit.path);
            allocator.free(path_hits);
        }

        for (path_hits) |hit| {
            try appendCandidate(
                allocator,
                &candidates,
                &dedup,
                &keys,
                .{
                    .install = .{
                        .kind = hit.kind,
                        .engine = hit.engine,
                        .path = try allocator.dupe(u8, hit.path),
                        .version = null,
                        .source = hit.source,
                    },
                    .score = hit.score,
                },
            );
        }
    }

    if (opts.include_known_paths) {
        for (kinds) |kind| {
            const hints = path_table.hintsFor(kind, catalog.nativePlatform());
            for (hints.known_paths) |raw_path| {
                const expanded = try util.expandEnvTemplates(allocator, raw_path);
                defer allocator.free(expanded);
                if (!util.exists(expanded)) continue;

                try appendCandidate(
                    allocator,
                    &candidates,
                    &dedup,
                    &keys,
                    .{
                        .install = .{
                            .kind = kind,
                            .engine = hints.engine,
                            .path = try allocator.dupe(u8, expanded),
                            .version = null,
                            .source = .known_path,
                        },
                        .score = hints.confidence_weight + 1,
                    },
                );
            }
        }
    }

    if (opts.include_os_probes) {
        try appendWindowsHits(allocator, &candidates, &dedup, &keys, kinds);
        try appendMacHits(allocator, &candidates, &dedup, &keys, kinds);
        try appendLinuxHits(allocator, &candidates, &dedup, &keys, kinds);
    }

    std.sort.heap(Candidate, candidates.items, {}, lessThan);

    const installs = try allocator.alloc(types.BrowserInstall, candidates.items.len);
    for (candidates.items, 0..) |candidate, i| {
        installs[i] = candidate.install;
    }

    candidates.deinit(allocator);
    for (keys.items) |key| allocator.free(key);
    keys.deinit(allocator);
    dedup.deinit();

    return installs;
}

fn lightpandaBundleEnabled() bool {
    return @hasDecl(config, "include_lightpanda_browser") and config.include_lightpanda_browser;
}

fn lightpandaBundleRoot() ?[]const u8 {
    if (!@hasDecl(config, "lightpanda_bundle_root")) return null;
    const root = config.lightpanda_bundle_root;
    if (root.len == 0) return null;
    return root;
}

fn isBrowserKindEnabled(kind: types.BrowserKind) bool {
    return switch (kind) {
        .lightpanda => lightpandaBundleEnabled(),
        else => true,
    };
}

fn filterEnabledKinds(
    allocator: std.mem.Allocator,
    requested: []const types.BrowserKind,
) ![]types.BrowserKind {
    var count: usize = 0;
    for (requested) |kind| {
        if (isBrowserKindEnabled(kind)) count += 1;
    }

    const filtered = try allocator.alloc(types.BrowserKind, count);
    var idx: usize = 0;
    for (requested) |kind| {
        if (!isBrowserKindEnabled(kind)) continue;
        filtered[idx] = kind;
        idx += 1;
    }
    return filtered;
}

fn hasKind(kinds: []const types.BrowserKind, kind: types.BrowserKind) bool {
    for (kinds) |candidate| {
        if (candidate == kind) return true;
    }
    return false;
}

fn appendBundledLightpandaCandidate(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    kinds: []const types.BrowserKind,
) !void {
    if (!lightpandaBundleEnabled()) return;
    if (!hasKind(kinds, .lightpanda)) return;

    const root = lightpandaBundleRoot() orelse return;
    const rel_candidates = switch (catalog.nativePlatform()) {
        .windows => &[_][]const u8{
            "bin/windows/lightpanda.exe",
            "bin/lightpanda.exe",
        },
        .macos => &[_][]const u8{
            "bin/macos/lightpanda",
            "bin/lightpanda",
        },
        .linux => &[_][]const u8{
            "bin/linux/lightpanda",
            "bin/lightpanda",
        },
    };

    for (rel_candidates) |rel| {
        const candidate_path = std.fs.path.join(allocator, &.{ root, rel }) catch continue;
        if (!util.exists(candidate_path)) {
            allocator.free(candidate_path);
            continue;
        }

        try appendCandidate(
            allocator,
            candidates,
            dedup,
            keys,
            .{
                .install = .{
                    .kind = .lightpanda,
                    .engine = .chromium,
                    .path = candidate_path,
                    .version = null,
                    .source = .managed_cache,
                },
                .score = 260,
            },
        );
        return;
    }
}

fn appendWindowsHits(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    kinds: []const types.BrowserKind,
) !void {
    const hits = try windows_registry.collect(allocator, kinds);
    defer {
        for (hits) |hit| allocator.free(hit.path);
        allocator.free(hits);
    }

    for (hits) |hit| {
        try appendCandidate(
            allocator,
            candidates,
            dedup,
            keys,
            .{
                .install = .{
                    .kind = hit.kind,
                    .engine = hit.engine,
                    .path = try allocator.dupe(u8, hit.path),
                    .version = null,
                    .source = hit.source,
                },
                .score = hit.score,
            },
        );
    }
}

fn appendMacHits(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    kinds: []const types.BrowserKind,
) !void {
    const hits = try macos_apps.collect(allocator, kinds);
    defer {
        for (hits) |hit| allocator.free(hit.path);
        allocator.free(hits);
    }

    for (hits) |hit| {
        try appendCandidate(
            allocator,
            candidates,
            dedup,
            keys,
            .{
                .install = .{
                    .kind = hit.kind,
                    .engine = hit.engine,
                    .path = try allocator.dupe(u8, hit.path),
                    .version = null,
                    .source = hit.source,
                },
                .score = hit.score,
            },
        );
    }
}

fn appendLinuxHits(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    kinds: []const types.BrowserKind,
) !void {
    const hits = try linux_sources.collect(allocator, kinds);
    defer {
        for (hits) |hit| allocator.free(hit.path);
        allocator.free(hits);
    }

    for (hits) |hit| {
        try appendCandidate(
            allocator,
            candidates,
            dedup,
            keys,
            .{
                .install = .{
                    .kind = hit.kind,
                    .engine = hit.engine,
                    .path = try allocator.dupe(u8, hit.path),
                    .version = null,
                    .source = hit.source,
                },
                .score = hit.score,
            },
        );
    }
}

fn appendCandidate(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    new_candidate: Candidate,
) !void {
    var candidate = new_candidate;
    candidate.score += extensions.scoreInstall(candidate.install);

    const norm = try util.normalizePathForKey(allocator, candidate.install.path);

    if (dedup.get(norm)) |existing_index| {
        allocator.free(norm);
        const existing = &candidates.items[existing_index];

        if (candidate.score > existing.score) {
            allocator.free(existing.install.path);
            if (existing.install.version) |v| allocator.free(v);
            existing.* = candidate;
        } else {
            allocator.free(candidate.install.path);
            if (candidate.install.version) |v| allocator.free(v);
        }
        return;
    }

    const idx = candidates.items.len;
    try candidates.append(allocator, candidate);
    try dedup.put(norm, idx);
    try keys.append(allocator, norm);
}

fn lessThan(_: void, a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;

    if (a.install.version != null and b.install.version == null) return true;
    if (a.install.version == null and b.install.version != null) return false;

    if (a.install.version) |av| {
        const bv = b.install.version.?;
        const cmp = std.mem.order(u8, av, bv);
        if (cmp != .eq) return cmp == .gt;
    }

    return std.mem.order(u8, a.install.path, b.install.path) == .lt;
}

fn inferKindFromPath(path: []const u8, preferred_kinds: []const types.BrowserKind) types.BrowserKind {
    const base = std.fs.path.basename(path);

    for (preferred_kinds) |kind| {
        const hints = path_table.hintsFor(kind, catalog.nativePlatform());
        for (hints.executable_names) |name| {
            if (std.ascii.eqlIgnoreCase(base, name)) return kind;
        }
    }

    if (string_util.containsIgnoreCase(base, "firefox")) return .firefox;
    if (string_util.containsIgnoreCase(base, "safari")) return .safari;
    if (string_util.containsIgnoreCase(base, "edge") or string_util.containsIgnoreCase(base, "msedge")) return .edge;
    if (string_util.containsIgnoreCase(base, "vivaldi")) return .vivaldi;
    if (string_util.containsIgnoreCase(base, "brave")) return .brave;
    if (string_util.containsIgnoreCase(base, "lightpanda") and hasKind(preferred_kinds, .lightpanda)) return .lightpanda;
    if (string_util.containsIgnoreCase(base, "palemoon")) return .palemoon;

    return if (preferred_kinds.len > 0) preferred_kinds[0] else .chrome;
}

test "sort prioritizes higher score then path" {
    const allocator = std.testing.allocator;

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |candidate| allocator.free(candidate.install.path);
        candidates.deinit(allocator);
    }

    try candidates.append(allocator, .{
        .install = .{ .kind = .chrome, .engine = .chromium, .path = try allocator.dupe(u8, "/tmp/b"), .source = .known_path },
        .score = 10,
    });
    try candidates.append(allocator, .{
        .install = .{ .kind = .chrome, .engine = .chromium, .path = try allocator.dupe(u8, "/tmp/a"), .source = .known_path },
        .score = 10,
    });
    try candidates.append(allocator, .{
        .install = .{ .kind = .chrome, .engine = .chromium, .path = try allocator.dupe(u8, "/tmp/c"), .source = .known_path },
        .score = 11,
    });

    std.sort.heap(Candidate, candidates.items, {}, lessThan);

    try std.testing.expect(std.mem.eql(u8, candidates.items[0].install.path, "/tmp/c"));
    try std.testing.expect(std.mem.eql(u8, candidates.items[1].install.path, "/tmp/a"));
}

test "sort prioritizes version before path when scores tie" {
    const allocator = std.testing.allocator;

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |candidate| {
            allocator.free(candidate.install.path);
            if (candidate.install.version) |v| allocator.free(v);
        }
        candidates.deinit(allocator);
    }

    try candidates.append(allocator, .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, "/tmp/no-version"),
            .version = null,
            .source = .known_path,
        },
        .score = 50,
    });
    try candidates.append(allocator, .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, "/tmp/with-version-low"),
            .version = try allocator.dupe(u8, "120.1"),
            .source = .known_path,
        },
        .score = 50,
    });
    try candidates.append(allocator, .{
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, "/tmp/with-version-high"),
            .version = try allocator.dupe(u8, "121.0"),
            .source = .known_path,
        },
        .score = 50,
    });

    std.sort.heap(Candidate, candidates.items, {}, lessThan);

    try std.testing.expect(std.mem.eql(u8, candidates.items[0].install.path, "/tmp/with-version-high"));
    try std.testing.expect(std.mem.eql(u8, candidates.items[1].install.path, "/tmp/with-version-low"));
    try std.testing.expect(std.mem.eql(u8, candidates.items[2].install.path, "/tmp/no-version"));
}

test "infer kind from path recognizes major browser names case-insensitively" {
    const kinds = [_]types.BrowserKind{
        .chrome,
        .edge,
        .safari,
        .firefox,
        .brave,
        .tor,
        .duckduckgo,
        .mullvad,
        .librewolf,
        .epic,
        .arc,
        .vivaldi,
        .sigmaos,
        .sidekick,
        .shift,
        .operagx,
        .lightpanda,
        .palemoon,
    };

    try std.testing.expectEqual(types.BrowserKind.firefox, inferKindFromPath("/tmp/FireFox", &kinds));
    try std.testing.expectEqual(types.BrowserKind.safari, inferKindFromPath("/Applications/Safari", &kinds));
    try std.testing.expectEqual(types.BrowserKind.edge, inferKindFromPath("C:\\Program Files\\MSEdge.EXE", &kinds));
    try std.testing.expectEqual(types.BrowserKind.vivaldi, inferKindFromPath("/opt/vivaldi-stable", &kinds));
    try std.testing.expectEqual(types.BrowserKind.brave, inferKindFromPath("/usr/bin/brave-browser", &kinds));
    try std.testing.expectEqual(types.BrowserKind.lightpanda, inferKindFromPath("/usr/bin/lightpanda-browser", &kinds));
    try std.testing.expectEqual(types.BrowserKind.palemoon, inferKindFromPath("/usr/bin/PaleMoon", &kinds));
}

test "filterEnabledKinds gates lightpanda by build option" {
    const allocator = std.testing.allocator;
    const filtered = try filterEnabledKinds(allocator, &.{ .chrome, .lightpanda });
    defer allocator.free(filtered);

    if (lightpandaBundleEnabled()) {
        try std.testing.expectEqual(@as(usize, 2), filtered.len);
        try std.testing.expect(hasKind(filtered, .lightpanda));
    } else {
        try std.testing.expectEqual(@as(usize, 1), filtered.len);
        try std.testing.expectEqual(types.BrowserKind.chrome, filtered[0]);
    }
}

test "discover returns explicit path and infers kind" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "firefox",
        .data = "#!/bin/sh\nexit 0\n",
    });

    const explicit_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "firefox" });
    defer allocator.free(explicit_path);

    const installs = try discover(allocator, .{
        .kinds = &.{ .chrome, .firefox },
        .explicit_path = explicit_path,
        .allow_managed_download = false,
    }, .{
        .include_path_env = false,
        .include_os_probes = false,
        .include_known_paths = false,
    });
    defer {
        for (installs) |install| allocator.free(install.path);
        allocator.free(installs);
    }

    try std.testing.expectEqual(@as(usize, 1), installs.len);
    try std.testing.expectEqual(types.BrowserInstallSource.explicit, installs[0].source);
    try std.testing.expectEqual(types.BrowserKind.firefox, installs[0].kind);
    try std.testing.expectEqual(types.EngineKind.gecko, installs[0].engine);
}

test "discover managed cache candidate when enabled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("chrome/current");
    try tmp.dir.writeFile(.{
        .sub_path = "chrome/current/google-chrome",
        .data = "stub\n",
    });

    const cache_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(cache_root);

    const installs = try discover(allocator, .{
        .kinds = &.{.chrome},
        .allow_managed_download = true,
        .managed_cache_dir = cache_root,
    }, .{
        .include_path_env = false,
        .include_os_probes = false,
        .include_known_paths = false,
    });
    defer {
        for (installs) |install| allocator.free(install.path);
        allocator.free(installs);
    }

    try std.testing.expectEqual(@as(usize, 1), installs.len);
    try std.testing.expectEqual(types.BrowserInstallSource.managed_cache, installs[0].source);
    try std.testing.expect(std.mem.endsWith(u8, installs[0].path, "chrome/current/google-chrome"));
}

test "discover deduplicates same path preferring explicit over managed cache" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("chrome/current");
    try tmp.dir.writeFile(.{
        .sub_path = "chrome/current/google-chrome",
        .data = "stub\n",
    });

    const cache_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(cache_root);
    const explicit = try std.fs.path.join(allocator, &.{ cache_root, "chrome", "current", "google-chrome" });
    defer allocator.free(explicit);

    const installs = try discover(allocator, .{
        .kinds = &.{.chrome},
        .explicit_path = explicit,
        .allow_managed_download = true,
        .managed_cache_dir = cache_root,
    }, .{
        .include_path_env = false,
        .include_os_probes = false,
        .include_known_paths = false,
    });
    defer {
        for (installs) |install| allocator.free(install.path);
        allocator.free(installs);
    }

    try std.testing.expectEqual(@as(usize, 1), installs.len);
    try std.testing.expectEqual(types.BrowserInstallSource.explicit, installs[0].source);
}

test "discover rejects invalid explicit path" {
    const allocator = std.testing.allocator;
    const result = discover(allocator, .{
        .kinds = &.{.chrome},
        .explicit_path = "/this/path/does/not/exist/browser",
        .allow_managed_download = false,
    }, .{
        .include_path_env = false,
        .include_os_probes = false,
        .include_known_paths = false,
    });
    try std.testing.expectError(error.InvalidExplicitPath, result);
}
