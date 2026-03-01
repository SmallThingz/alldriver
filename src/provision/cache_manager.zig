const std = @import("std");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("../discovery/util.zig");
const http = @import("../transport/http_client.zig");
const process_util = @import("../util/process.zig");

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
    archive_executable_name: ?[]const u8 = null,
};

pub fn defaultCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".cache", "alldriver", "browsers" });
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

    const selected = if (isArchiveFileName(filename))
        try extractAndSelectExecutable(
            allocator,
            kind,
            version_dir,
            staged_path,
            options.archive_executable_name,
        )
    else
        .{
            .path = try allocator.dupe(u8, staged_path),
            .basename = try allocator.dupe(u8, std.fs.path.basename(staged_path)),
        };
    defer {
        allocator.free(selected.path);
        allocator.free(selected.basename);
    }

    const current_dir = try std.fs.path.join(allocator, &.{ kind_root, "current" });
    defer allocator.free(current_dir);
    std.fs.cwd().deleteTree(current_dir) catch {};
    try std.fs.cwd().makePath(current_dir);

    const current_file = try std.fs.path.join(allocator, &.{ current_dir, selected.basename });
    defer allocator.free(current_file);
    try std.fs.cwd().copyFile(selected.path, std.fs.cwd(), current_file, .{});
    ensureExecutablePermissions(current_file);
}

fn downloadToMemory(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const parsed = try parseDownloadUrl(url);
    return switch (parsed.scheme) {
        .file => std.fs.cwd().readFileAlloc(allocator, parsed.path, 1024 * 1024 * 256),
        .http => blk: {
            const resp = try http.getJson(allocator, parsed.host, parsed.port, parsed.path);
            if (resp.status_code < 200 or resp.status_code >= 300) {
                allocator.free(resp.body);
                return error.DownloadFailed;
            }
            break :blk resp.body;
        },
        .https => downloadHttpsWithCurl(allocator, url),
    };
}

const DownloadScheme = enum {
    file,
    http,
    https,
};

const ParsedUrl = struct {
    scheme: DownloadScheme,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseDownloadUrl(url: []const u8) !ParsedUrl {
    if (std.mem.startsWith(u8, url, "file://")) {
        const local = url[7..];
        if (local.len == 0) return error.InvalidUrl;
        return .{
            .scheme = .file,
            .host = "",
            .port = 0,
            .path = local,
        };
    }

    const scheme_and_default_port: struct { scheme: DownloadScheme, port: u16, prefix_len: usize } = blk: {
        if (std.mem.startsWith(u8, url, "http://")) break :blk .{ .scheme = .http, .port = 80, .prefix_len = 7 };
        if (std.mem.startsWith(u8, url, "https://")) break :blk .{ .scheme = .https, .port = 443, .prefix_len = 8 };
        return error.UnsupportedUrlScheme;
    };
    const rest = url[scheme_and_default_port.prefix_len..];

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |idx| host_port[0..idx] else host_port;
    if (host.len == 0) return error.InvalidUrl;

    const port: u16 = if (colon) |idx|
        try std.fmt.parseInt(u16, host_port[idx + 1 ..], 10)
    else
        scheme_and_default_port.port;

    return .{ .scheme = scheme_and_default_port.scheme, .host = host, .port = port, .path = path };
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

const SelectedExecutable = struct {
    path: []u8,
    basename: []u8,
};

fn extractAndSelectExecutable(
    allocator: std.mem.Allocator,
    kind: types.BrowserKind,
    version_dir: []const u8,
    staged_archive_path: []const u8,
    preferred_name: ?[]const u8,
) !SelectedExecutable {
    const extract_root = try std.fs.path.join(allocator, &.{ version_dir, "extract" });
    defer allocator.free(extract_root);
    try std.fs.cwd().makePath(extract_root);

    try extractArchive(allocator, staged_archive_path, extract_root);

    if (preferred_name) |name| {
        if (findPathByBasename(allocator, extract_root, name)) |path| {
            return .{
                .path = path,
                .basename = try allocator.dupe(u8, std.fs.path.basename(path)),
            };
        } else |_| {}
    }

    const hints = path_table.hintsFor(kind, catalog.nativePlatform());
    for (hints.executable_names) |exec_name| {
        if (findPathByBasename(allocator, extract_root, exec_name)) |path| {
            return .{
                .path = path,
                .basename = try allocator.dupe(u8, std.fs.path.basename(path)),
            };
        } else |_| {}
    }

    return error.ExecutableNotFound;
}

fn findPathByBasename(
    allocator: std.mem.Allocator,
    root: []const u8,
    want_basename: []const u8,
) ![]u8 {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), want_basename)) continue;
        return std.fs.path.join(allocator, &.{ root, entry.path });
    }
    return error.ExecutableNotFound;
}

fn isArchiveFileName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zip") or
        std.mem.endsWith(u8, name, ".tar") or
        std.mem.endsWith(u8, name, ".tar.gz") or
        std.mem.endsWith(u8, name, ".tgz") or
        std.mem.endsWith(u8, name, ".tar.xz") or
        std.mem.endsWith(u8, name, ".txz");
}

fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    if (std.mem.endsWith(u8, archive_path, ".zip")) {
        const res = try process_util.runCollect(allocator, &.{ "unzip", "-o", archive_path, "-d", dest_dir }, null, null);
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (!res.ok) return error.ArchiveExtractFailed;
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar") or
        std.mem.endsWith(u8, archive_path, ".tar.gz") or
        std.mem.endsWith(u8, archive_path, ".tgz") or
        std.mem.endsWith(u8, archive_path, ".tar.xz") or
        std.mem.endsWith(u8, archive_path, ".txz"))
    {
        const res = try process_util.runCollect(allocator, &.{ "tar", "-xf", archive_path, "-C", dest_dir }, null, null);
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (!res.ok) return error.ArchiveExtractFailed;
        return;
    }

    return error.UnsupportedArchiveFormat;
}

fn downloadHttpsWithCurl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const res = try process_util.runCollect(
        allocator,
        &.{ "curl", "--fail", "--location", "--silent", "--show-error", url },
        null,
        null,
    );
    defer allocator.free(res.stderr);
    if (!res.ok) {
        allocator.free(res.stdout);
        return error.DownloadFailed;
    }
    return res.stdout;
}

fn ensureExecutablePermissions(path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    std.fs.cwd().chmod(path, 0o755) catch {};
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

test "parse download url defaults ports" {
    const parsed_http = try parseDownloadUrl("http://example.com/path");
    try std.testing.expectEqual(DownloadScheme.http, parsed_http.scheme);
    try std.testing.expect(std.mem.eql(u8, parsed_http.host, "example.com"));
    try std.testing.expectEqual(@as(u16, 80), parsed_http.port);
    try std.testing.expect(std.mem.eql(u8, parsed_http.path, "/path"));

    const parsed_https = try parseDownloadUrl("https://example.com/path");
    try std.testing.expectEqual(DownloadScheme.https, parsed_https.scheme);
    try std.testing.expect(std.mem.eql(u8, parsed_https.host, "example.com"));
    try std.testing.expectEqual(@as(u16, 443), parsed_https.port);
    try std.testing.expect(std.mem.eql(u8, parsed_https.path, "/path"));

    const parsed_file = try parseDownloadUrl("file:///tmp/browser");
    try std.testing.expectEqual(DownloadScheme.file, parsed_file.scheme);
    try std.testing.expectEqual(@as(u16, 0), parsed_file.port);
    try std.testing.expect(std.mem.eql(u8, parsed_file.path, "/tmp/browser"));
}

test "parse download url rejects unsupported scheme" {
    try std.testing.expectError(error.UnsupportedUrlScheme, parseDownloadUrl("ftp://example.com/file"));
}

test "archive file detection" {
    try std.testing.expect(isArchiveFileName("browser.zip"));
    try std.testing.expect(isArchiveFileName("browser.tar.gz"));
    try std.testing.expect(isArchiveFileName("browser.tgz"));
    try std.testing.expect(isArchiveFileName("browser.tar.xz"));
    try std.testing.expect(!isArchiveFileName("browser.bin"));
}

test "parse download url host and path" {
    const parsed = try parseDownloadUrl("http://example.com/path");
    try std.testing.expectEqual(DownloadScheme.http, parsed.scheme);
    try std.testing.expect(std.mem.eql(u8, parsed.host, "example.com"));
    try std.testing.expectEqual(@as(u16, 80), parsed.port);
    try std.testing.expect(std.mem.eql(u8, parsed.path, "/path"));
}

test "verify sha256 detects mismatch" {
    try std.testing.expectError(error.HashMismatch, verifySha256("abc", "0000000000000000000000000000000000000000000000000000000000000000"));
}
