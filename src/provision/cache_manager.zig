const std = @import("std");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("../discovery/util.zig");
const http = @import("../transport/http_client.zig");

pub const ManagedHit = struct {
    kind: types.BrowserKind,
    engine: types.EngineKind,
    path: []u8,
    source: types.BrowserInstallSource,
    score: i32,
};

pub const InstallOptions = struct {
    expected_sha256_hex: ?[]const u8 = null,
    executable_name: ?[]const u8 = null,
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
    return installManagedBrowserWithOptions(allocator, kind, cache_dir, download_url, .{});
}

pub fn installManagedBrowserWithOptions(
    allocator: std.mem.Allocator,
    kind: types.BrowserKind,
    cache_dir: []const u8,
    download_url: []const u8,
    options: InstallOptions,
) !void {
    const kind_name = @tagName(kind);
    const kind_root = try std.fs.path.join(allocator, &.{ cache_dir, kind_name });
    defer allocator.free(kind_root);

    try std.fs.cwd().makePath(kind_root);

    const lock_path = try std.fs.path.join(allocator, &.{ kind_root, ".install.lock" });
    defer allocator.free(lock_path);
    const lock_file = try std.fs.cwd().createFile(lock_path, .{ .exclusive = true, .truncate = true });
    defer {
        lock_file.close();
        std.fs.cwd().deleteFile(lock_path) catch {};
    }

    const stamp = std.time.timestamp();
    const version_dir = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ kind_root, stamp });
    defer allocator.free(version_dir);
    try std.fs.cwd().makePath(version_dir);

    const filename = options.executable_name orelse inferFileName(download_url);
    const staged_path = try std.fs.path.join(allocator, &.{ version_dir, filename });
    defer allocator.free(staged_path);

    const payload = try downloadToMemory(allocator, download_url);
    defer allocator.free(payload);

    if (options.expected_sha256_hex) |expected| {
        try verifySha256(payload, expected);
    }

    try std.fs.cwd().writeFile(.{ .sub_path = staged_path, .data = payload });

    const current_dir = try std.fs.path.join(allocator, &.{ kind_root, "current" });
    defer allocator.free(current_dir);
    std.fs.cwd().deleteTree(current_dir) catch {};
    try std.fs.cwd().makePath(current_dir);

    const current_file = try std.fs.path.join(allocator, &.{ current_dir, filename });
    defer allocator.free(current_file);
    try std.fs.cwd().copyFile(staged_path, std.fs.cwd(), current_file, .{});
}

fn downloadToMemory(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        const local = url[7..];
        return std.fs.cwd().readFileAlloc(allocator, local, 1024 * 1024 * 256);
    }

    const parsed = try parseHttpUrl(url);
    const resp = try http.getJson(allocator, parsed.host, parsed.port, parsed.path);
    if (resp.status_code < 200 or resp.status_code >= 300) {
        allocator.free(resp.body);
        return error.DownloadFailed;
    }
    return resp.body;
}

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseHttpUrl(url: []const u8) !ParsedUrl {
    if (!std.mem.startsWith(u8, url, "http://")) return error.UnsupportedUrlScheme;
    const rest = url[7..];

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |idx| host_port[0..idx] else host_port;
    if (host.len == 0) return error.InvalidUrl;

    const port: u16 = if (colon) |idx|
        try std.fmt.parseInt(u16, host_port[idx + 1 ..], 10)
    else
        80;

    return .{ .host = host, .port = port, .path = path };
}

fn inferFileName(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        const local = url[7..];
        return std.fs.path.basename(local);
    }

    if (std.mem.lastIndexOfScalar(u8, url, '/')) |idx| {
        const name = url[idx + 1 ..];
        if (name.len > 0) return name;
    }

    return "browser.bin";
}

fn verifySha256(data: []const u8, expected_hex: []const u8) !void {
    if (expected_hex.len != 64) return error.HashMismatch;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});

    const actual_hex_buf = std.fmt.bytesToHex(hash, .lower);

    if (!std.ascii.eqlIgnoreCase(expected_hex, actual_hex_buf[0..])) {
        return error.HashMismatch;
    }
}

test "infer file name" {
    try std.testing.expect(std.mem.eql(u8, inferFileName("http://example.com/path/browser"), "browser"));
    try std.testing.expect(std.mem.eql(u8, inferFileName("http://example.com/path/"), "browser.bin"));
}

test "parse http url defaults port" {
    const parsed = try parseHttpUrl("http://example.com/path");
    try std.testing.expect(std.mem.eql(u8, parsed.host, "example.com"));
    try std.testing.expectEqual(@as(u16, 80), parsed.port);
    try std.testing.expect(std.mem.eql(u8, parsed.path, "/path"));
}

test "verify sha256 detects mismatch" {
    try std.testing.expectError(error.HashMismatch, verifySha256("abc", "0000000000000000000000000000000000000000000000000000000000000000"));
}
