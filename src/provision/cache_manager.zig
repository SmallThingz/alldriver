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

    const selected: SelectedExecutable = if (isArchiveFileName(filename))
        try extractAndSelectExecutable(
            allocator,
            kind,
            version_dir,
            staged_path,
            options.archive_executable_name,
        )
    else
        SelectedExecutable{
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
    if (std.mem.startsWith(u8, url, "file://")) {
        const local = url[7..];
        if (local.len == 0) return error.InvalidUrl;
        return std.fs.cwd().readFileAlloc(allocator, local, 1024 * 1024 * 256);
    }

    var client: std.http.Client = .{ .allocator = allocator };
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
    var dest = try std.fs.cwd().openDir(dest_dir, .{});
    defer dest.close();

    if (std.mem.endsWith(u8, archive_path, ".zip")) {
        var file = try std.fs.cwd().openFile(archive_path, .{});
        defer file.close();

        var file_reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&file_reader_buffer);
        try std.zip.extract(dest, &file_reader, .{});
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar")) {
        var file = try std.fs.cwd().openFile(archive_path, .{});
        defer file.close();

        var file_reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&file_reader_buffer);
        try std.tar.pipeToFileSystem(dest, &file_reader.interface, .{});
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar.gz") or std.mem.endsWith(u8, archive_path, ".tgz")) {
        var file = try std.fs.cwd().openFile(archive_path, .{});
        defer file.close();

        var file_reader_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(&file_reader_buffer);
        var inflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip_reader = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &inflate_buffer);
        try std.tar.pipeToFileSystem(dest, &gzip_reader.reader, .{});
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar.xz") or std.mem.endsWith(u8, archive_path, ".txz")) {
        const compressed = try std.fs.cwd().readFileAlloc(allocator, archive_path, std.math.maxInt(usize));
        defer allocator.free(compressed);

        var in_stream = std.io.fixedBufferStream(compressed);
        var xz = try std.compress.xz.decompress(allocator, in_stream.reader());
        defer xz.deinit();

        var tar_bytes: std.ArrayList(u8) = .empty;
        defer tar_bytes.deinit(allocator);

        var xz_reader = xz.reader();
        var decode_buffer: [8192]u8 = undefined;
        while (true) {
            const n = try xz_reader.read(&decode_buffer);
            if (n == 0) break;
            try tar_bytes.appendSlice(allocator, decode_buffer[0..n]);
        }

        var tar_reader: std.Io.Reader = .fixed(tar_bytes.items);
        try std.tar.pipeToFileSystem(dest, &tar_reader, .{});
        return;
    }

    return error.UnsupportedArchiveFormat;
}

fn ensureExecutablePermissions(path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    file.chmod(0o755) catch {};
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
    server: std.net.Server,
    body: []const u8,
    failed: bool = false,

    fn port(self: *const OneShotHttpServer) u16 {
        const real = self.server.listen_address.in.sa;
        return std.mem.bigToNative(u16, real.port);
    }
};

fn runOneShotHttpServer(ctx: *OneShotHttpServer) void {
    defer ctx.server.deinit();
    const conn = ctx.server.accept() catch {
        ctx.failed = true;
        return;
    };
    defer conn.stream.close();

    var req_buf: [2048]u8 = undefined;
    _ = conn.stream.read(&req_buf) catch {
        ctx.failed = true;
        return;
    };

    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ctx.body.len},
    ) catch {
        ctx.failed = true;
        return;
    };

    conn.stream.writeAll(head) catch {
        ctx.failed = true;
        return;
    };
    conn.stream.writeAll(ctx.body) catch {
        ctx.failed = true;
    };
}

test "managed install downloads over HTTP and extracts zip without external tools" {
    const allocator = std.testing.allocator;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const cache_dir = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cache_dir);

    const zip_bytes = try decodeHexAlloc(allocator, zip_fixture_hex);
    defer allocator.free(zip_bytes);

    var addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try addr.listen(.{});

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
    const installed_bytes = try std.fs.cwd().readFileAlloc(allocator, installed, 1024);
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
