const std = @import("std");
const builtin = @import("builtin");
const cache_manager = @import("cache_manager.zig");
const util_strings = @import("../util/strings.zig");

pub const DownloadOptions = struct {
    cache_dir: ?[]const u8 = null,
    /// Optional release tag (e.g. "v1.2.3"). Null means GitHub "latest".
    tag: ?[]const u8 = null,
    /// Optional payload hash verification passed through to managed install.
    expected_sha256_hex: ?[]const u8 = null,
};

const NativeOs = enum { windows, macos, linux };
const NativeArch = enum { amd64, arm64 };

const SelectedAsset = struct {
    name: []u8,
    download_url: []u8,
};

pub fn downloadLatest(allocator: std.mem.Allocator, opts: DownloadOptions) ![]u8 {
    const cache_dir = if (opts.cache_dir) |dir|
        try allocator.dupe(u8, dir)
    else
        try cache_manager.defaultCacheDir(allocator);
    defer allocator.free(cache_dir);

    const metadata_url = if (opts.tag) |tag|
        try std.fmt.allocPrint(allocator, "https://api.github.com/repos/lightpanda-io/browser/releases/tags/{s}", .{tag})
    else
        try allocator.dupe(u8, "https://api.github.com/repos/lightpanda-io/browser/releases/latest");
    defer allocator.free(metadata_url);

    const metadata_json = try fetchJson(allocator, metadata_url);
    defer allocator.free(metadata_json);

    const target = try nativeTarget();
    const selected = try selectAssetForTarget(allocator, metadata_json, target.os, target.arch);
    defer {
        allocator.free(selected.name);
        allocator.free(selected.download_url);
    }

    try cache_manager.installManagedBrowserWithOptions(
        allocator,
        .lightpanda,
        cache_dir,
        selected.download_url,
        .{
            .expected_sha256_hex = opts.expected_sha256_hex,
            .executable_name = defaultExecutableNameForTarget(target.os),
            .archive_executable_name = defaultExecutableNameForTarget(target.os),
        },
    );

    return findInstalledLightpanda(allocator, cache_dir);
}

fn fetchJson(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var collecting_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer collecting_writer.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "alldriver" },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
    };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &collecting_writer.writer,
        .extra_headers = &headers,
        .keep_alive = false,
    });

    if (result.status.class() != .success) return error.DownloadFailed;
    var collected = collecting_writer.toArrayList();
    return collected.toOwnedSlice(allocator);
}

fn findInstalledLightpanda(allocator: std.mem.Allocator, cache_dir: []const u8) ![]u8 {
    const hits = try cache_manager.discoverManaged(allocator, &.{.lightpanda}, cache_dir);
    defer {
        for (hits) |hit| allocator.free(hit.path);
        allocator.free(hits);
    }
    if (hits.len == 0) return error.ExecutableNotFound;

    var best_index: usize = 0;
    var best_score: i32 = hits[0].score;
    var i: usize = 1;
    while (i < hits.len) : (i += 1) {
        if (hits[i].score > best_score) {
            best_index = i;
            best_score = hits[i].score;
        }
    }
    return allocator.dupe(u8, hits[best_index].path);
}

fn nativeTarget() !struct { os: NativeOs, arch: NativeArch } {
    const os: NativeOs = switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => .linux,
        else => return error.UnsupportedPlatform,
    };
    const arch: NativeArch = switch (builtin.cpu.arch) {
        .x86_64 => .amd64,
        .aarch64 => .arm64,
        else => return error.UnsupportedPlatform,
    };
    return .{ .os = os, .arch = arch };
}

fn defaultExecutableNameForTarget(os: NativeOs) []const u8 {
    return switch (os) {
        .windows => "lightpanda.exe",
        .macos, .linux => "lightpanda",
    };
}

fn selectAssetForTarget(
    allocator: std.mem.Allocator,
    release_json: []const u8,
    os: NativeOs,
    arch: NativeArch,
) !SelectedAsset {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, release_json, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidReleaseMetadata,
    };
    const assets_value = root_obj.get("assets") orelse return error.InvalidReleaseMetadata;
    const assets = switch (assets_value) {
        .array => |arr| arr,
        else => return error.InvalidReleaseMetadata,
    };

    var best_score: i32 = std.math.minInt(i32);
    var best: ?SelectedAsset = null;
    errdefer if (best) |asset| {
        allocator.free(asset.name);
        allocator.free(asset.download_url);
    };

    for (assets.items) |entry| {
        const asset_obj = switch (entry) {
            .object => |obj| obj,
            else => continue,
        };
        const name_value = asset_obj.get("name") orelse continue;
        const url_value = asset_obj.get("browser_download_url") orelse continue;
        const name = switch (name_value) {
            .string => |s| s,
            else => continue,
        };
        const url = switch (url_value) {
            .string => |s| s,
            else => continue,
        };

        const score = scoreAsset(name, url, os, arch);
        if (score < 0 or score <= best_score) continue;

        if (best) |existing| {
            allocator.free(existing.name);
            allocator.free(existing.download_url);
        }
        best = .{
            .name = try allocator.dupe(u8, name),
            .download_url = try allocator.dupe(u8, url),
        };
        best_score = score;
    }

    return best orelse error.NoCompatibleAsset;
}

fn scoreAsset(name: []const u8, url: []const u8, os: NativeOs, arch: NativeArch) i32 {
    const lower_name = name;
    const lower_url = url;

    if (util_strings.containsIgnoreCase(lower_name, "sha256") or
        util_strings.containsIgnoreCase(lower_name, "checksum") or
        looksSignatureAsset(lower_name))
    {
        return -1;
    }

    const os_match = hasAny(lower_name, osTokens(os)) or hasAny(lower_url, osTokens(os));
    if (!os_match) return -1;

    const arch_match = hasAny(lower_name, archTokens(arch)) or hasAny(lower_url, archTokens(arch));
    if (!arch_match) return -1;

    var score: i32 = 100;
    if (util_strings.containsIgnoreCase(lower_name, "lightpanda")) score += 10;
    if (util_strings.containsIgnoreCase(lower_url, "lightpanda")) score += 5;

    if (looksRunnableAsset(lower_name, lower_url)) {
        score += 20;
    } else {
        return -1;
    }

    if (std.mem.endsWith(u8, lower_name, ".tar.gz") or std.mem.endsWith(u8, lower_url, ".tar.gz")) score += 8;
    if (std.mem.endsWith(u8, lower_name, ".tgz") or std.mem.endsWith(u8, lower_url, ".tgz")) score += 8;
    if (std.mem.endsWith(u8, lower_name, ".zip") or std.mem.endsWith(u8, lower_url, ".zip")) score += 4;
    if (std.mem.endsWith(u8, lower_name, ".exe") or std.mem.endsWith(u8, lower_url, ".exe")) score += 2;
    if (!endsWithArchiveOrBinary(lower_name) and !endsWithArchiveOrBinary(lower_url)) score += 6;

    return score;
}

fn hasAny(haystack: []const u8, tokens: []const []const u8) bool {
    for (tokens) |token| {
        if (util_strings.containsIgnoreCase(haystack, token)) return true;
    }
    return false;
}

fn endsWithArchiveOrBinary(s: []const u8) bool {
    return std.mem.endsWith(u8, s, ".tar.gz") or
        std.mem.endsWith(u8, s, ".tgz") or
        std.mem.endsWith(u8, s, ".zip") or
        std.mem.endsWith(u8, s, ".exe");
}

fn looksRunnableAsset(name: []const u8, url: []const u8) bool {
    if (endsWithArchiveOrBinary(name) or endsWithArchiveOrBinary(url)) return true;
    if (looksSignatureAsset(name) or looksSignatureAsset(url)) return false;
    const base = std.fs.path.basename(name);
    if (std.ascii.eqlIgnoreCase(base, "lightpanda") or std.ascii.eqlIgnoreCase(base, "lightpanda.exe")) return true;
    const url_base = std.fs.path.basename(url);
    if (std.ascii.eqlIgnoreCase(url_base, "lightpanda") or std.ascii.eqlIgnoreCase(url_base, "lightpanda.exe")) return true;
    return false;
}

fn looksSignatureAsset(s: []const u8) bool {
    return std.mem.endsWith(u8, s, ".sig") or
        std.mem.endsWith(u8, s, ".asc") or
        std.mem.endsWith(u8, s, ".pem") or
        std.mem.endsWith(u8, s, ".sha") or
        std.mem.endsWith(u8, s, ".sha256") or
        std.mem.endsWith(u8, s, ".sha512");
}

fn osTokens(os: NativeOs) []const []const u8 {
    return switch (os) {
        .windows => &.{ "windows", "win32", "pc-windows", "mingw", "msvc" },
        .macos => &.{ "macos", "darwin", "osx", "apple" },
        .linux => &.{"linux"},
    };
}

fn archTokens(arch: NativeArch) []const []const u8 {
    return switch (arch) {
        .amd64 => &.{ "x86_64", "amd64", "x64" },
        .arm64 => &.{ "aarch64", "arm64" },
    };
}

test "select asset for linux amd64" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "assets": [
        \\    {"name":"lightpanda-darwin-arm64.zip","browser_download_url":"https://example/darwin-arm64.zip"},
        \\    {"name":"lightpanda-linux-amd64.tar.gz","browser_download_url":"https://example/linux-amd64.tar.gz"},
        \\    {"name":"checksums.txt","browser_download_url":"https://example/checksums.txt"}
        \\  ]
        \\}
    ;
    const selected = try selectAssetForTarget(allocator, json, .linux, .amd64);
    defer {
        allocator.free(selected.name);
        allocator.free(selected.download_url);
    }
    try std.testing.expectEqualStrings("lightpanda-linux-amd64.tar.gz", selected.name);
}

test "windows token matching does not accept darwin assets" {
    try std.testing.expect(!hasAny("lightpanda-darwin-arm64.zip", osTokens(.windows)));
    try std.testing.expect(hasAny("lightpanda-windows-amd64.zip", osTokens(.windows)));
}

test "select asset fails when no compatible target exists" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "assets": [
        \\    {"name":"lightpanda-darwin-arm64.zip","browser_download_url":"https://example/darwin-arm64.zip"}
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.NoCompatibleAsset, selectAssetForTarget(allocator, json, .linux, .amd64));
}

test "select asset accepts extensionless direct binary" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "assets": [
        \\    {"name":"lightpanda-x86_64-linux","browser_download_url":"https://example/lightpanda-x86_64-linux"}
        \\  ]
        \\}
    ;
    const selected = try selectAssetForTarget(allocator, json, .linux, .amd64);
    defer {
        allocator.free(selected.name);
        allocator.free(selected.download_url);
    }
    try std.testing.expectEqualStrings("lightpanda-x86_64-linux", selected.name);
}

test "signature assets are rejected" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "assets": [
        \\    {"name":"lightpanda-linux-amd64.tar.gz.asc","browser_download_url":"https://example/lightpanda-linux-amd64.tar.gz.asc"},
        \\    {"name":"lightpanda-linux-amd64.sig","browser_download_url":"https://example/lightpanda-linux-amd64.sig"}
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.NoCompatibleAsset, selectAssetForTarget(allocator, json, .linux, .amd64));
}
