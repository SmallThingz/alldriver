const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types.zig");
const util = @import("../util.zig");
const string_util = @import("../../util/strings.zig");

const Candidate = struct {
    runtime: types.WebViewRuntime,
    score: i32,
};

const all_kinds = [_]types.WebViewKind{
    .webview2,
    .electron,
    .android_webview,
};

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) ![]types.WebViewRuntime {
    const kinds = if (prefs.kinds.len == 0) all_kinds[0..] else prefs.kinds;

    var candidates: std.ArrayList(Candidate) = .empty;
    var keys: std.ArrayList([]u8) = .empty;
    var dedup: std.StringHashMap(usize) = .init(allocator);

    errdefer {
        for (candidates.items) |candidate| freeRuntimeFields(allocator, candidate.runtime);
        candidates.deinit(allocator);

        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
        dedup.deinit();
    }

    if (prefs.explicit_runtime_path) |raw| {
        const expanded = try util.expandEnvTemplates(allocator, raw);
        defer allocator.free(expanded);

        if (!util.exists(expanded)) return error.InvalidExplicitPath;

        const kind = inferKindFromPath(expanded, kinds);
        try appendCandidate(allocator, &candidates, &dedup, &keys, .{
            .runtime = .{
                .kind = kind,
                .engine = engineForWebView(kind),
                .platform = platformForWebView(kind),
                .runtime_path = try allocator.dupe(u8, expanded),
                .bridge_tool_path = null,
                .source = .explicit,
                .version = null,
            },
            .score = 1000,
        });
    }

    if (prefs.include_known_paths) {
        try appendKnownPaths(allocator, &candidates, &dedup, &keys, kinds);
    }

    if (prefs.include_path_env) {
        try appendPathEnv(allocator, &candidates, &dedup, &keys, kinds);
    }

    if (prefs.include_mobile_bridges) {
        try appendMobileBridgeCandidates(allocator, &candidates, &dedup, &keys, kinds);
    }

    std.sort.heap(Candidate, candidates.items, {}, lessThan);

    const runtimes = try allocator.alloc(types.WebViewRuntime, candidates.items.len);
    for (candidates.items, 0..) |candidate, idx| {
        runtimes[idx] = candidate.runtime;
    }

    candidates.deinit(allocator);
    for (keys.items) |key| allocator.free(key);
    keys.deinit(allocator);
    dedup.deinit();

    return runtimes;
}

pub fn freeRuntimes(allocator: std.mem.Allocator, runtimes: []types.WebViewRuntime) void {
    for (runtimes) |runtime| {
        freeRuntimeFields(allocator, runtime);
    }
    allocator.free(runtimes);
}

fn appendKnownPaths(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    kinds: []const types.WebViewKind,
) !void {
    const native_os = builtin.os.tag;

    for (kinds) |kind| {
        switch (kind) {
            .webview2 => if (native_os == .windows) {
                const known = [_][]const u8{
                    "C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\msedgewebview2.exe",
                    "C:\\Program Files\\Microsoft\\EdgeWebView\\Application\\msedgewebview2.exe",
                };
                for (known) |raw| {
                    const expanded = try util.expandEnvTemplates(allocator, raw);
                    defer allocator.free(expanded);
                    if (!util.exists(expanded)) continue;

                    try appendCandidate(allocator, candidates, dedup, keys, .{
                        .runtime = .{
                            .kind = .webview2,
                            .engine = .chromium,
                            .platform = .windows,
                            .runtime_path = try allocator.dupe(u8, expanded),
                            .bridge_tool_path = null,
                            .source = .known_path,
                            .version = null,
                        },
                        .score = 120,
                    });
                }
            },
            .electron => {
                const known: []const []const u8 = switch (native_os) {
                    .windows => &.{
                        "C:\\Program Files\\Electron\\electron.exe",
                        "C:\\Program Files (x86)\\Electron\\electron.exe",
                    },
                    .macos => &.{
                        "/Applications/Electron.app/Contents/MacOS/Electron",
                    },
                    else => &.{
                        "/usr/bin/electron",
                        "/usr/local/bin/electron",
                    },
                };
                for (known) |raw| {
                    const expanded = try util.expandEnvTemplates(allocator, raw);
                    defer allocator.free(expanded);
                    if (!util.exists(expanded)) continue;

                    try appendCandidate(allocator, candidates, dedup, keys, .{
                        .runtime = .{
                            .kind = .electron,
                            .engine = .chromium,
                            .platform = platformForWebView(.electron),
                            .runtime_path = try allocator.dupe(u8, expanded),
                            .bridge_tool_path = null,
                            .source = .known_path,
                            .version = null,
                        },
                        .score = 115,
                    });
                }
            },
            .android_webview => {},
        }
    }
}

fn appendPathEnv(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    kinds: []const types.WebViewKind,
) !void {
    for (kinds) |kind| {
        const platform = platformForWebView(kind);
        if (!isNativePlatform(platform)) continue;

        const names = switch (kind) {
            .webview2 => &[_][]const u8{ "msedgewebview2", "msedgewebview2.exe" },
            .electron => &[_][]const u8{ "electron", "electron.exe" },
            .android_webview => &[_][]const u8{},
        };

        for (names) |name| {
            const found = findInPath(allocator, name) catch continue;
            defer allocator.free(found);

            try appendCandidate(allocator, candidates, dedup, keys, .{
                .runtime = .{
                    .kind = kind,
                    .engine = engineForWebView(kind),
                    .platform = platform,
                    .runtime_path = try allocator.dupe(u8, found),
                    .bridge_tool_path = null,
                    .source = .path_env,
                    .version = null,
                },
                .score = switch (kind) {
                    else => 100,
                },
            });
        }
    }
}

fn appendMobileBridgeCandidates(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    kinds: []const types.WebViewKind,
) !void {
    for (kinds) |kind| {
        switch (kind) {
            .android_webview => {
                const bridge_tools = [_]struct {
                    name: []const u8,
                    score: i32,
                }{
                    .{ .name = "adb", .score = 90 },
                    .{ .name = "shizuku", .score = 86 },
                    .{ .name = "rish", .score = 84 },
                };

                for (bridge_tools) |bridge| {
                    const tool = findInPath(allocator, bridge.name) catch continue;
                    defer allocator.free(tool);

                    try appendCandidate(allocator, candidates, dedup, keys, .{
                        .runtime = .{
                            .kind = .android_webview,
                            .engine = .chromium,
                            .platform = .android,
                            .runtime_path = null,
                            .bridge_tool_path = try allocator.dupe(u8, tool),
                            .source = .bridge_tool,
                            .version = null,
                        },
                        .score = bridge.score,
                    });
                }
            },
            .webview2, .electron => {},
        }
    }
}

fn appendCandidate(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    dedup: *std.StringHashMap(usize),
    keys: *std.ArrayList([]u8),
    candidate: Candidate,
) !void {
    const key = try dedupKey(allocator, candidate.runtime);

    if (dedup.get(key)) |existing_idx| {
        allocator.free(key);
        const existing = &candidates.items[existing_idx];
        if (candidate.score > existing.score) {
            freeRuntimeFields(allocator, existing.runtime);
            existing.* = candidate;
        } else {
            freeRuntimeFields(allocator, candidate.runtime);
        }
        return;
    }

    const idx = candidates.items.len;
    try candidates.append(allocator, candidate);
    try dedup.put(key, idx);
    try keys.append(allocator, key);
}

fn dedupKey(allocator: std.mem.Allocator, runtime: types.WebViewRuntime) ![]u8 {
    if (runtime.runtime_path) |path| {
        return util.normalizePathForKey(allocator, path);
    }

    if (runtime.bridge_tool_path) |bridge| {
        return std.fmt.allocPrint(
            allocator,
            "{s}|{s}|{s}",
            .{ @tagName(runtime.kind), @tagName(runtime.platform), bridge },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{s}|{s}|none",
        .{ @tagName(runtime.kind), @tagName(runtime.platform) },
    );
}

fn lessThan(_: void, a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;

    const ap = a.runtime.runtime_path orelse "";
    const bp = b.runtime.runtime_path orelse "";
    return std.mem.order(u8, ap, bp) == .lt;
}

fn inferKindFromPath(path: []const u8, allowed: []const types.WebViewKind) types.WebViewKind {
    const base = std.fs.path.basename(path);
    for (allowed) |kind| {
        switch (kind) {
            .webview2 => if (string_util.containsIgnoreCase(base, "webview2")) return .webview2,
            .electron => if (string_util.containsIgnoreCase(base, "electron")) return .electron,
            .android_webview => if (string_util.containsIgnoreCase(base, "adb") or string_util.containsIgnoreCase(base, "shizuku") or string_util.containsIgnoreCase(base, "rish")) return .android_webview,
        }
    }

    return if (allowed.len > 0) allowed[0] else .webview2;
}

fn findInPath(allocator: std.mem.Allocator, exe_name: []const u8) ![]u8 {
    const path_env = try std.process.getEnvVarOwned(allocator, "PATH");
    defer allocator.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir_raw| {
        const dir = std.mem.trim(u8, dir_raw, " \t\r\n\"");
        if (dir.len == 0) continue;

        const candidate = std.fs.path.join(allocator, &.{ dir, exe_name }) catch continue;
        if (util.exists(candidate)) return candidate;
        allocator.free(candidate);
    }

    return error.NotFound;
}

pub fn engineForWebView(kind: types.WebViewKind) types.EngineKind {
    return switch (kind) {
        .webview2, .electron, .android_webview => .chromium,
    };
}

pub fn platformForWebView(kind: types.WebViewKind) types.WebViewPlatform {
    return switch (kind) {
        .webview2 => .windows,
        .electron => switch (builtin.os.tag) {
            .windows => .windows,
            .macos => .macos,
            else => .linux,
        },
        .android_webview => .android,
    };
}

fn isNativePlatform(platform: types.WebViewPlatform) bool {
    return switch (platform) {
        .windows => builtin.os.tag == .windows,
        .macos => builtin.os.tag == .macos,
        .linux => builtin.os.tag == .linux,
        .android, .ios => false,
    };
}

fn freeRuntimeFields(allocator: std.mem.Allocator, runtime: types.WebViewRuntime) void {
    if (runtime.runtime_path) |p| allocator.free(p);
    if (runtime.bridge_tool_path) |p| allocator.free(p);
    if (runtime.version) |v| allocator.free(v);
}

test "webview discover explicit path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "msedgewebview2.exe",
        .data = "stub\n",
    });

    const explicit = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "msedgewebview2.exe" });
    defer allocator.free(explicit);

    const runtimes = try discover(allocator, .{
        .kinds = &.{.webview2},
        .explicit_runtime_path = explicit,
        .include_path_env = false,
        .include_known_paths = false,
        .include_mobile_bridges = false,
    });
    defer freeRuntimes(allocator, runtimes);

    try std.testing.expectEqual(@as(usize, 1), runtimes.len);
    try std.testing.expectEqual(types.WebViewRuntimeSource.explicit, runtimes[0].source);
    try std.testing.expectEqual(types.WebViewKind.webview2, runtimes[0].kind);
}

test "webview discover can skip mobile bridge probing" {
    const allocator = std.testing.allocator;

    const runtimes = try discover(allocator, .{
        .kinds = &.{.android_webview},
        .include_path_env = false,
        .include_known_paths = false,
        .include_mobile_bridges = false,
    });
    defer freeRuntimes(allocator, runtimes);

    try std.testing.expectEqual(@as(usize, 0), runtimes.len);
}

test "webview discover explicit path infers electron kind" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "electron",
        .data = "stub\n",
    });

    const explicit = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "electron" });
    defer allocator.free(explicit);

    const runtimes = try discover(allocator, .{
        .kinds = &.{.electron},
        .explicit_runtime_path = explicit,
        .include_path_env = false,
        .include_known_paths = false,
        .include_mobile_bridges = false,
    });
    defer freeRuntimes(allocator, runtimes);

    try std.testing.expectEqual(@as(usize, 1), runtimes.len);
    try std.testing.expectEqual(types.WebViewKind.electron, runtimes[0].kind);
    try std.testing.expectEqual(types.EngineKind.chromium, runtimes[0].engine);
    try std.testing.expectEqual(platformForWebView(.electron), runtimes[0].platform);
}

test "webview discover explicit path infers android bridge kind from shizuku binary name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "shizuku",
        .data = "stub\n",
    });

    const explicit = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "shizuku" });
    defer allocator.free(explicit);

    const runtimes = try discover(allocator, .{
        .kinds = &.{.android_webview},
        .explicit_runtime_path = explicit,
        .include_path_env = false,
        .include_known_paths = false,
        .include_mobile_bridges = false,
    });
    defer freeRuntimes(allocator, runtimes);

    try std.testing.expectEqual(@as(usize, 1), runtimes.len);
    try std.testing.expectEqual(types.WebViewKind.android_webview, runtimes[0].kind);
    try std.testing.expectEqual(types.EngineKind.chromium, runtimes[0].engine);
    try std.testing.expectEqual(types.WebViewPlatform.android, runtimes[0].platform);
}
