const std = @import("std");
const builtin = @import("builtin");
const catalog = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const types = @import("../types.zig");
const util = @import("../discovery/util.zig");
const compat = @import("../util/compat.zig");
const io_util = @import("../util/io.zig");

const max_archive_file_bytes = 256 * 1024 * 1024;

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
    switch (builtin.os.tag) {
        .windows => {
            if (compat.getEnvVarOwned(allocator, "LOCALAPPDATA")) |base| {
                defer allocator.free(base);
                return std.fs.path.join(allocator, &.{ base, "alldriver", "browsers" });
            } else |_| {}
            if (compat.getEnvVarOwned(allocator, "USERPROFILE")) |base| {
                defer allocator.free(base);
                return std.fs.path.join(allocator, &.{ base, "AppData", "Local", "alldriver", "browsers" });
            } else |_| {}
            return allocator.dupe(u8, ".\\alldriver\\browsers");
        },
        .macos => {
            if (compat.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                return std.fs.path.join(allocator, &.{ home, "Library", "Caches", "alldriver", "browsers" });
            } else |_| {}
            return allocator.dupe(u8, "/tmp/alldriver/browsers");
        },
        else => {
            if (compat.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |base| {
                defer allocator.free(base);
                return std.fs.path.join(allocator, &.{ base, "alldriver", "browsers" });
            } else |_| {}
            if (compat.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                return std.fs.path.join(allocator, &.{ home, ".cache", "alldriver", "browsers" });
            } else |_| {}
            return allocator.dupe(u8, "/tmp/alldriver/browsers");
        },
    }
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

    if (!util.exists(cache_dir)) return allocator.alloc(ManagedHit, 0);

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

    try compat.cwd().makePath(kind_root);

    const lock_path = try std.fs.path.join(allocator, &.{ kind_root, ".install.lock" });
    defer allocator.free(lock_path);
    const lock_file = try acquireInstallLock(lock_path);
    defer {
        lock_file.close(compat.io());
        compat.cwd().deleteFile(lock_path) catch {};
    }

    var nonce_bytes: [8]u8 = undefined;
    compat.io().random(&nonce_bytes);
    const nonce = std.mem.readInt(u64, &nonce_bytes, .little);
    const stamp = compat.nanoTimestamp();
    const version_leaf = try std.fmt.allocPrint(allocator, "{d}-{x}", .{ stamp, nonce });
    defer allocator.free(version_leaf);
    const version_dir = try std.fs.path.join(allocator, &.{ kind_root, version_leaf });
    defer allocator.free(version_dir);
    try compat.cwd().makePath(version_dir);

    const staged_filename = inferFileName(download_url);
    const staged_path = try std.fs.path.join(allocator, &.{ version_dir, staged_filename });
    defer allocator.free(staged_path);

    const payload = try downloadToMemory(allocator, download_url);
    defer allocator.free(payload);

    if (options.expected_sha256_hex) |expected| {
        try verifySha256(payload, expected);
    }

    try compat.cwd().writeFile(.{ .sub_path = staged_path, .data = payload });

    const selected: SelectedExecutable = if (isArchiveFileName(staged_filename))
        try extractAndSelectExecutable(
            allocator,
            kind,
            version_dir,
            staged_path,
            options.archive_executable_name,
        )
    else blk: {
        const base = std.fs.path.basename(options.executable_name orelse std.fs.path.basename(staged_path));
        break :blk SelectedExecutable{
            .path = try allocator.dupe(u8, staged_path),
            .basename = try allocator.dupe(u8, base),
        };
    };
    defer {
        allocator.free(selected.path);
        allocator.free(selected.basename);
    }

    const current_dir = try std.fs.path.join(allocator, &.{ kind_root, "current" });
    defer allocator.free(current_dir);
    const current_stage_dir = try std.fs.path.join(allocator, &.{ kind_root, ".current.new" });
    defer allocator.free(current_stage_dir);
    const current_prev_dir = try std.fs.path.join(allocator, &.{ kind_root, ".current.prev" });
    defer allocator.free(current_prev_dir);

    compat.cwd().deleteTree(current_stage_dir) catch {};
    compat.cwd().deleteTree(current_prev_dir) catch {};
    try compat.cwd().makePath(current_stage_dir);

    const staged_current_file = try std.fs.path.join(allocator, &.{ current_stage_dir, selected.basename });
    defer allocator.free(staged_current_file);
    try compat.cwd().copyFile(selected.path, compat.cwd(), staged_current_file, .{});
    ensureExecutablePermissions(staged_current_file);

    if (util.exists(current_dir)) {
        compat.cwd().rename(current_dir, current_prev_dir) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    compat.cwd().rename(current_stage_dir, current_dir) catch |err| {
        if (util.exists(current_prev_dir) and !util.exists(current_dir)) {
            compat.cwd().rename(current_prev_dir, current_dir) catch {};
        }
        return err;
    };

    compat.cwd().deleteTree(current_prev_dir) catch {};
}

fn downloadToMemory(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        const local = try localPathFromFileUrl(allocator, url);
        defer allocator.free(local);
        return compat.cwd().readFileAlloc(allocator, local, 1024 * 1024 * 256);
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = compat.io() };
    defer client.deinit();

    var collecting_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer collecting_writer.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &collecting_writer.writer,
        .keep_alive = false,
    });

    if (result.status.class() != .success) return error.DownloadFailed;
    var collected = collecting_writer.toArrayList();
    return collected.toOwnedSlice(allocator);
}

fn inferFileName(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
        const clean = url[0..end];
        if (std.mem.lastIndexOfScalar(u8, clean, '/')) |idx| {
            const name = clean[idx + 1 ..];
            if (name.len > 0) return name;
        }
        return "browser.bin";
    }

    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const clean = url[0..end];
    if (std.mem.lastIndexOfScalar(u8, clean, '/')) |idx| {
        const name = clean[idx + 1 ..];
        if (name.len > 0) return name;
    }

    return "browser.bin";
}

fn acquireInstallLock(lock_path: []const u8) !std.Io.File {
    const deadline_ms = compat.milliTimestamp() + 10_000;
    while (true) {
        return compat.cwd().createFile(lock_path, .{ .exclusive = true, .truncate = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const stat = compat.cwd().statFile(lock_path) catch |stat_err| switch (stat_err) {
                    error.FileNotFound => continue,
                    else => return stat_err,
                };
                const age_ms = compat.milliTimestamp() - @as(i64, @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)));
                if (age_ms > 300_000) {
                    compat.cwd().deleteFile(lock_path) catch {};
                    continue;
                }
                if (compat.milliTimestamp() >= deadline_ms) return err;
                compat.sleepMs(50);
                continue;
            },
            else => return err,
        };
    }
}

fn localPathFromFileUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url);
    const raw_path = switch (uri.path) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    const host = if (uri.host) |component| switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    } else null;

    if (builtin.os.tag == .windows) {
        if (host) |value| {
            if (value.len > 0 and !std.ascii.eqlIgnoreCase(value, "localhost")) {
                return std.fmt.allocPrint(allocator, "\\\\{s}{s}", .{ value, raw_path });
            }
        }
        if (raw_path.len >= 3 and raw_path[0] == '/' and std.ascii.isAlphabetic(raw_path[1]) and raw_path[2] == ':') {
            return allocator.dupe(u8, raw_path[1..]);
        }
        return allocator.dupe(u8, raw_path);
    }

    if (host) |value| {
        if (value.len > 0 and !std.ascii.eqlIgnoreCase(value, "localhost")) {
            return std.fmt.allocPrint(allocator, "//{s}{s}", .{ value, raw_path });
        }
    }
    return allocator.dupe(u8, raw_path);
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
    try compat.cwd().makePath(extract_root);

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
    var dir = try compat.cwd().openDir(root, .{ .iterate = true });
    defer dir.close(compat.io());

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(compat.io())) |entry| {
        switch (entry.kind) {
            .file => {},
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
    var dest = try compat.cwd().openDir(dest_dir, .{});
    defer dest.close(compat.io());

    if (std.mem.endsWith(u8, archive_path, ".zip")) {
        var file = try compat.cwd().openFile(archive_path, .{});
        defer file.close(compat.io());

        var file_reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(compat.io(), &file_reader_buffer);
        try std.zip.extract(dest, &file_reader, .{});
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar")) {
        var file = try compat.cwd().openFile(archive_path, .{});
        defer file.close(compat.io());

        var file_reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(compat.io(), &file_reader_buffer);
        try std.tar.pipeToFileSystem(compat.io(), dest, &file_reader.interface, .{});
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar.gz") or std.mem.endsWith(u8, archive_path, ".tgz")) {
        var file = try compat.cwd().openFile(archive_path, .{});
        defer file.close(compat.io());

        var file_reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(compat.io(), &file_reader_buffer);
        var inflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip_reader = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &inflate_buffer);
        try std.tar.pipeToFileSystem(compat.io(), dest, &gzip_reader.reader, .{});
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar.xz") or std.mem.endsWith(u8, archive_path, ".txz")) {
        const compressed = try compat.cwd().readFileAlloc(allocator, archive_path, max_archive_file_bytes);
        defer allocator.free(compressed);

        var in_reader: std.Io.Reader = .fixed(compressed);
        var xz = try std.compress.xz.Decompress.init(&in_reader, allocator, try allocator.alloc(u8, 8192));
        defer xz.deinit();

        var tar_bytes: std.ArrayList(u8) = .empty;
        defer tar_bytes.deinit(allocator);

        var decode_buffer: [8192]u8 = undefined;
        while (true) {
            const n = try xz.reader.readSliceShort(&decode_buffer);
            if (n == 0) break;
            try tar_bytes.appendSlice(allocator, decode_buffer[0..n]);
        }

        var tar_reader: std.Io.Reader = .fixed(tar_bytes.items);
        try std.tar.pipeToFileSystem(compat.io(), dest, &tar_reader, .{});
        return;
    }

    return error.UnsupportedArchiveFormat;
}

fn ensureExecutablePermissions(path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const file = compat.cwd().openFile(path, .{}) catch return;
    defer file.close(compat.io());
    file.setPermissions(compat.io(), .executable_file) catch {};
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
    try std.testing.expect(std.mem.eql(u8, inferFileName("https://example.com/download/browser.tar.gz?token=abc#frag"), "browser.tar.gz"));
}

test "archive file detection" {
    try std.testing.expect(isArchiveFileName("browser.zip"));
    try std.testing.expect(isArchiveFileName("browser.tar.gz"));
    try std.testing.expect(isArchiveFileName("browser.tgz"));
    try std.testing.expect(isArchiveFileName("browser.tar.xz"));
    try std.testing.expect(!isArchiveFileName("browser.bin"));
}

test "verify sha256 detects mismatch" {
    try std.testing.expectError(error.HashMismatch, verifySha256("abc", "0000000000000000000000000000000000000000000000000000000000000000"));
}

const zip_fixture_hex =
    "504b0304140000000000079f615c56abff5e09000000090000000b00000062696e2f62726f7773657268656c6c6f2d7a6970504b01021403140000000000079f615c56abff5e09000000090000000b000000000000000000000080010000000062696e2f62726f77736572504b0506000000000100010039000000320000000000";

const OneShotHttpServer = struct {
    server: std.Io.net.Server,
    body: []const u8,
    failed: bool = false,

    fn port(self: *const OneShotHttpServer) u16 {
        return self.server.socket.address.getPort();
    }
};

fn runOneShotHttpServer(ctx: *OneShotHttpServer) void {
    defer ctx.server.deinit(compat.io());
    var stream = ctx.server.accept(compat.io()) catch {
        ctx.failed = true;
        return;
    };
    defer stream.close(compat.io());

    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ctx.body.len},
    ) catch {
        ctx.failed = true;
        return;
    };

    io_util.writeAll(&stream, head) catch {
        ctx.failed = true;
        return;
    };
    io_util.writeAll(&stream, ctx.body) catch {
        ctx.failed = true;
    };
}

fn canCreateIpv4TcpSocket() bool {
    if (builtin.os.tag != .linux) return true;
    const linux = std.os.linux;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {
            _ = linux.close(@intCast(rc));
            return true;
        },
        .PERM, .ACCES => return false,
        else => return true,
    }
}

test "managed install downloads over HTTP and extracts zip without external tools" {
    const allocator = std.testing.allocator;
    if (!canCreateIpv4TcpSocket()) return error.SkipZigTest;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const cache_dir = try compat.dirRealpathAlloc(temp.dir, allocator, ".");
    defer allocator.free(cache_dir);

    const zip_bytes = try decodeHexAlloc(allocator, zip_fixture_hex);
    defer allocator.free(zip_bytes);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    const server = addr.listen(compat.io(), .{ .reuse_address = true }) catch |err| switch (err) {
        error.Unexpected,
        error.NetworkDown,
        error.SystemResources,
        error.AddressFamilyUnsupported,
        error.ProtocolUnsupportedBySystem,
        error.ProtocolUnsupportedByAddressFamily,
        error.SocketModeUnsupported,
        error.OptionUnsupported,
        => return error.SkipZigTest,
        else => return err,
    };

    var ctx = OneShotHttpServer{
        .server = server,
        .body = zip_bytes,
    };
    const thread = try std.Thread.spawn(.{}, runOneShotHttpServer, .{&ctx});
    var joined = false;
    defer if (!joined) thread.join();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/browser.zip", .{ctx.port()});
    defer allocator.free(url);

    try installManagedBrowserWithOptions(allocator, .chrome, cache_dir, url, .{
        .archive_executable_name = "browser",
    });
    thread.join();
    joined = true;
    try std.testing.expect(!ctx.failed);

    const installed = try std.fs.path.join(allocator, &.{ cache_dir, "chrome", "current", "browser" });
    defer allocator.free(installed);
    const installed_bytes = try compat.cwd().readFileAlloc(allocator, installed, 1024);
    defer allocator.free(installed_bytes);
    try std.testing.expectEqualStrings("hello-zip", installed_bytes);
}

fn decodeHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}
