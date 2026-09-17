const std = @import("std");
const driver = @import("../root.zig");
const compat = @import("../util/compat.zig");
const io_util = @import("../util/io.zig");
const allocator = std.testing.allocator;

/// Every blocking accept/read/write belongs to this cancelable task group.
/// Teardown cancels and joins tasks before closing the listener or freeing state.
pub const LocalServer = struct {
    listener: std.Io.net.Server,
    tasks: std.Io.Group = .init,
    failed: std.atomic.Value(bool) = .init(false),
    blocked_hits: std.atomic.Value(u32) = .init(0),
    fulfilled_hits: std.atomic.Value(u32) = .init(0),
    accepted: std.atomic.Value(u32) = .init(0),

    pub fn start() !*LocalServer {
        const self = try allocator.create(LocalServer);
        errdefer allocator.destroy(self);
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        self.* = .{ .listener = try address.listen(compat.io(), .{ .reuse_address = true }) };
        errdefer self.listener.deinit(compat.io());
        try self.tasks.concurrent(compat.io(), serve, .{self});
        return self;
    }

    pub fn deinit(self: *LocalServer) void {
        self.tasks.cancel(compat.io());
        self.listener.deinit(compat.io());
        allocator.destroy(self);
    }

    fn serve(self: *LocalServer) std.Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(compat.io()) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.failed.store(true, .release);
                return;
            };
            if (self.accepted.fetchAdd(1, .monotonic) >= 64) {
                stream.close(compat.io());
                self.failed.store(true, .release);
                return;
            }
            self.tasks.concurrent(compat.io(), handle, .{ self, stream }) catch {
                stream.close(compat.io());
                self.failed.store(true, .release);
                return;
            };
        }
    }

    fn handle(self: *LocalServer, accepted: std.Io.net.Stream) std.Io.Cancelable!void {
        var stream = accepted;
        defer stream.close(compat.io());
        self.respond(&stream) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            // Browsers may close speculative connections before sending a request.
            if (err != error.ConnectionClosed) self.failed.store(true, .release);
        };
    }

    fn respond(self: *LocalServer, stream: *std.Io.net.Stream) !void {
        var bytes: [16 * 1024]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, bytes[0..used], "\r\n\r\n") == null) {
            if (used == bytes.len) return error.RequestTooLarge;
            const count = try io_util.read(stream, bytes[used..]);
            if (count == 0) return error.ConnectionClosed;
            used += count;
        }
        const request = bytes[0..used];
        var first = std.mem.tokenizeScalar(u8, request[0 .. std.mem.indexOf(u8, request, "\r\n") orelse return error.InvalidRequest], ' ');
        _ = first.next() orelse return error.InvalidRequest;
        const path = first.next() orelse return error.InvalidRequest;
        if (std.mem.startsWith(u8, path, "/blocked")) _ = self.blocked_hits.fetchAdd(1, .release);
        if (std.mem.startsWith(u8, path, "/fulfilled")) _ = self.fulfilled_hits.fetchAdd(1, .release);
        const body = if (std.mem.eql(u8, path, "/"))
            "<!doctype html><meta charset='utf-8'><link rel='icon' href='data:,'><title>network fixture</title>"
        else if (std.mem.startsWith(u8, path, "/modify"))
            request
        else
            "origin response";
        var header_buf: [512]u8 = undefined;
        const headers = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: {s}\r\nX-Origin: local-server\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ body.len, if (std.mem.eql(u8, path, "/")) "text/html" else "text/plain" });
        try io_util.writeAll(stream, headers);
        try io_util.writeAll(stream, body);
    }
};

fn launch(profile: []const u8) !driver.modern.ModernSession {
    var installs = try driver.discover(allocator, .{ .kinds = &.{ .brave, .chrome, .edge }, .allow_managed_download = false }, .{ .include_path_env = true, .include_os_probes = true, .include_known_paths = true });
    defer installs.deinit();
    if (installs.items.len == 0) return error.NoChromiumBrowserFound;
    return driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .profile_mode = .ephemeral,
        .profile_dir = profile,
        .headless = true,
        .args = &.{ "--no-sandbox", "--disable-dev-shm-usage", "--disable-background-networking", "--disable-component-update", "--disable-sync", "--no-first-run", "--password-store=basic", "--disable-features=OptimizationGuideModelDownloading,OptimizationHints,MediaRouter" },
    });
}

fn expectScript(session: *driver.modern.ModernSession, expression: []const u8) !void {
    var runtime = session.runtime();
    const response = try runtime.evaluate(expression);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object.get("result").?;
    const value = result.object.get("value") orelse return error.MissingEvaluationValue;
    if (value != .bool or !value.bool) {
        std.debug.print("Network assertion failed: {s}\nresponse: {s}\n", .{ expression, response });
        return error.TestUnexpectedResult;
    }
}

fn expectRecord(session: *driver.modern.ModernSession, path: []const u8, status: u16, body: []const u8) !void {
    var network = session.network();
    const started = compat.milliTimestamp();
    while (true) {
        const records = try network.records(allocator, true);
        defer network.freeRecords(allocator, records);
        for (records) |record| {
            if (!std.mem.endsWith(u8, record.url, path)) continue;
            if (record.final_status != status or record.response_body == null) continue;
            try std.testing.expectEqualStrings("GET", record.method);
            try std.testing.expectEqualStrings(body, record.response_body.?);
            try std.testing.expect(record.request_id.len > 0);
            return;
        }
        if (compat.milliTimestamp() - started > 5000) return error.MissingCompletedNetworkRecord;
        compat.sleepMs(20);
    }
}

test "Chromium interception changes real requests and records actual responses" {
    const server = try LocalServer.start();
    defer server.deinit();
    const profile = try std.fmt.allocPrint(allocator, ".tmp/chromium-network-{x}", .{compat.nanoTimestamp()});
    defer allocator.free(profile);
    defer compat.cwd().deleteTree(profile) catch {};
    var session = try launch(profile);
    defer session.deinit();
    const origin = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server.listener.socket.address.getPort()});
    defer allocator.free(origin);
    var page = session.page();
    try page.navigate(origin);
    var network = session.network();
    try network.enable();
    try network.addRule(.{ .id = "blocked", .url_pattern = "*/blocked*", .action = .{ .block = {} } });
    try network.addRule(.{ .id = "fulfilled", .url_pattern = "*/fulfilled*", .action = .{ .fulfill = .{
        .status = 201,
        .body = "intercepted λ response",
        .headers = &.{ .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }, .{ .name = "X-Intercepted", .value = "yes" } },
    } } });
    try network.addRule(.{ .id = "modified", .url_pattern = "*/modify*", .action = .{ .modify = .{
        .add_headers = &.{.{ .name = "X-Added", .value = "added" }},
        .remove_header_names = &.{"X-Remove"},
    } } });
    try network.addRule(.{ .id = "continued", .url_pattern = "*/continued*", .action = .{ .continue_request = {} } });

    try expectScript(&session, "(async()=>{try{await fetch('/blocked');return false}catch(e){return e instanceof TypeError}})()");
    try std.testing.expectEqual(@as(u32, 0), server.blocked_hits.load(.acquire));
    try expectScript(&session, "(async()=>{const r=await fetch('/fulfilled');return r.status===201&&r.headers.get('x-intercepted')==='yes'&&(await r.text())==='intercepted λ response'})()");
    try std.testing.expectEqual(@as(u32, 0), server.fulfilled_hits.load(.acquire));
    try expectRecord(&session, "/fulfilled", 201, "intercepted λ response");
    try expectScript(&session, "(async()=>{const r=await fetch('/modify',{headers:{'X-Remove':'remove-me','X-Keep':'kept'}});const t=await r.text();return r.status===200&&/x-added: added/i.test(t)&&/x-keep: kept/i.test(t)&&!/x-remove:/i.test(t)})()");
    try expectScript(&session, "(async()=>{const r=await fetch('/continued');return r.status===200&&r.headers.get('x-origin')==='local-server'&&(await r.text())==='origin response'})()");
    try expectRecord(&session, "/continued", 200, "origin response");
    // Requests not matching any interception rule must also continue normally.
    try expectScript(&session, "(async()=>{const r=await fetch('/unmatched');return r.status===200&&(await r.text())==='origin response'})()");
    try std.testing.expect(try network.removeRule("fulfilled"));
    try std.testing.expect(!(try network.removeRule("fulfilled")));
    try expectScript(&session, "(async()=>{const r=await fetch('/fulfilled?removed');return r.status===200&&!r.headers.has('x-intercepted')&&(await r.text())==='origin response'})()");
    try std.testing.expectEqual(@as(u32, 1), server.fulfilled_hits.load(.acquire));
    // Removing one rule must not remove another active rule.
    try expectScript(&session, "(async()=>{try{await fetch('/blocked?still-active');return false}catch(e){return e instanceof TypeError}})()");
    try std.testing.expectEqual(@as(u32, 0), server.blocked_hits.load(.acquire));
    try network.disable();
    try expectScript(&session, "(async()=>{const r=await fetch('/blocked?disabled');return r.status===200&&(await r.text())==='origin response'})()");
    try std.testing.expectEqual(@as(u32, 1), server.blocked_hits.load(.acquire));
    try std.testing.expect(!server.failed.load(.acquire));
}

test "local Chromium fixture cancels idle and partial HTTP connections" {
    const server = try LocalServer.start();
    var cleaned = false;
    defer if (!cleaned) server.deinit();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", server.listener.socket.address.getPort());
    var idle = try address.connect(compat.io(), .{ .mode = .stream });
    defer idle.close(compat.io());
    var partial = try address.connect(compat.io(), .{ .mode = .stream });
    defer partial.close(compat.io());
    try io_util.writeAll(&partial, "GET / HTTP/1.1");
    const start = compat.milliTimestamp();
    while (server.accepted.load(.acquire) < 2) {
        if (compat.milliTimestamp() - start > 2000) return error.ServerAcceptTimeout;
        compat.sleepMs(5);
    }
    server.deinit();
    cleaned = true;
    try std.testing.expect(compat.milliTimestamp() - start < 2000);
}
