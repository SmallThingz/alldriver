const std = @import("std");
const compat = @import("../util/compat.zig");
const io_util = @import("../util/io.zig");
const Browser = @import("chromium_behavior.zig").Browser;
const allocator = std.testing.allocator;

const DownloadServer = struct {
    listener: std.Io.net.Server,
    tasks: std.Io.Group = .init,
    bytes: []u8,
    served: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn start() !*DownloadServer {
        const server = try allocator.create(DownloadServer);
        errdefer allocator.destroy(server);
        const bytes = try allocator.alloc(u8, 96 * 1024 + 137);
        errdefer allocator.free(bytes);
        for (bytes, 0..) |*byte, index| byte.* = @truncate((index * 71) ^ (index >> 8));
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        server.* = .{ .listener = try address.listen(compat.io(), .{ .reuse_address = true }), .bytes = bytes };
        errdefer server.listener.deinit(compat.io());
        try server.tasks.concurrent(compat.io(), serve, .{server});
        return server;
    }

    fn deinit(self: *DownloadServer) void {
        self.tasks.cancel(compat.io());
        self.listener.deinit(compat.io());
        allocator.free(self.bytes);
        allocator.destroy(self);
    }

    fn serve(self: *DownloadServer) std.Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(compat.io()) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.failed.store(true, .release);
                return;
            };
            self.tasks.concurrent(compat.io(), handle, .{ self, stream }) catch {
                stream.close(compat.io());
                self.failed.store(true, .release);
                return;
            };
        }
    }

    fn handle(self: *DownloadServer, accepted: std.Io.net.Stream) std.Io.Cancelable!void {
        var stream = accepted;
        defer stream.close(compat.io());
        self.respond(&stream) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err != error.ConnectionClosed) self.failed.store(true, .release);
        };
    }

    fn respond(self: *DownloadServer, stream: *std.Io.net.Stream) !void {
        var request: [16 * 1024]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, request[0..used], "\r\n\r\n") == null) {
            if (used == request.len) return error.RequestTooLarge;
            const count = try io_util.read(stream, request[used..]);
            if (count == 0) return error.ConnectionClosed;
            used += count;
        }
        const broken = std.mem.startsWith(u8, request[0..used], "GET /broken ");
        const attachment = broken or std.mem.startsWith(u8, request[0..used], "GET /attachment ");
        const html = "<!doctype html><link rel='icon' href='data:,'><a id='download' href='/attachment'>Download</a><br><a id='broken' href='/broken'>Interrupted download</a>";
        const body: []const u8 = if (attachment) self.bytes else html;
        var header_buffer: [1024]u8 = undefined;
        const disposition = if (broken)
            "Content-Disposition: attachment; filename=\"broken-report.bin\"\r\n"
        else if (attachment)
            "Content-Disposition: attachment; filename=\"browser-report.bin\"\r\n"
        else
            "";
        const headers = try std.fmt.bufPrint(
            &header_buffer,
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}Cache-Control: no-store\r\nConnection: close\r\n\r\n",
            .{ if (attachment) "application/octet-stream" else "text/html", body.len, disposition },
        );
        try io_util.writeAll(stream, headers);
        if (broken) {
            // Advertise the complete attachment but close before even one chunk.
            try io_util.writeAll(stream, body[0..19]);
            return;
        }
        var offset: usize = 0;
        while (offset < body.len) {
            const end = @min(body.len, offset + 997);
            try io_util.writeAll(stream, body[offset..end]);
            offset = end;
        }
        if (attachment) self.served.store(true, .release);
    }
};

test "Chromium downloads preserve binary attachment bytes and report completed and interrupted transfers" {
    const server = try DownloadServer.start();
    defer server.deinit();
    var browser = try Browser.launch();
    defer browser.deinit();
    const downloads_dir = try std.fs.path.join(allocator, &.{ browser.profile, "downloads" });
    defer allocator.free(downloads_dir);
    try browser.session.base.setDownloadDirectory(downloads_dir);
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server.listener.socket.address.getPort()});
    defer allocator.free(url);
    var page = browser.session.page();
    try page.navigate(url);
    var input = browser.session.input();
    try input.click("#download");

    // The transfer must progress with no further driver RPCs.
    const started = compat.milliTimestamp();
    while (!server.served.load(.acquire)) {
        if (compat.milliTimestamp() - started > 5000) return error.DownloadDidNotReachServer;
        compat.sleepMs(10);
    }
    compat.sleepMs(100);
    try expectDownload(&browser, "browser-report.bin", false, server.bytes, 1);
    try input.click("#download");
    try expectDownload(&browser, "browser-report.bin", false, server.bytes, 2);
    try input.click("#broken");
    try expectDownload(&browser, "broken-report.bin", true, null, 1);
    try std.testing.expect(!server.failed.load(.acquire));
    try browser.evaluateTrue("document.querySelector('#download')!==null");
}

fn expectDownload(browser: *Browser, filename: []const u8, canceled: bool, expected_bytes: ?[]const u8, expected_count: usize) !void {
    const started = compat.milliTimestamp();
    while (true) {
        const items = try browser.session.base.listDownloads(allocator);
        defer browser.session.base.freeDownloads(allocator, items);
        var matched: usize = 0;
        var previous_path: ?[]const u8 = null;
        for (items) |item| {
            if (!std.mem.eql(u8, item.suggested_filename, filename)) continue;
            if (!item.completed and !item.canceled) continue;
            try std.testing.expectEqual(!canceled, item.completed);
            try std.testing.expectEqual(canceled, item.canceled);
            if (expected_bytes) |expected| {
                try std.testing.expect(item.save_path.len > 0);
                if (previous_path) |previous| try std.testing.expect(!std.mem.eql(u8, previous, item.save_path));
                previous_path = item.save_path;
                const bytes = try compat.cwd().readFileAlloc(allocator, item.save_path, 1024 * 1024);
                defer allocator.free(bytes);
                try std.testing.expectEqualSlices(u8, expected, bytes);
            }
            matched += 1;
        }
        if (matched == expected_count) return;
        if (compat.milliTimestamp() - started > 15_000) return error.MissingTerminalDownload;
        compat.sleepMs(20);
    }
}
