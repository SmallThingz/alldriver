const std = @import("std");
const common = @import("../protocol/common.zig");
const io_util = @import("../util/io.zig");
const compat = @import("../util/compat.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    receive_timeout_ms: u32 = 30_000,
    failed: bool = false,
    pub const max_message_size = 64 * 1024 * 1024;

    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
    ) !Client {
        const address = if (std.mem.eql(u8, host, "localhost"))
            try std.Io.net.IpAddress.parseIp4("127.0.0.1", port)
        else
            std.Io.net.IpAddress.parse(host, port) catch try std.Io.net.IpAddress.resolve(compat.io(), host, port);
        var stream = try address.connect(compat.io(), .{ .mode = .stream });
        errdefer stream.close(compat.io());

        var key_src: [16]u8 = undefined;
        compat.io().random(&key_src);
        var key_buf: [std.base64.standard.Encoder.calcSize(16)]u8 = undefined;
        const ws_key = std.base64.standard.Encoder.encode(&key_buf, &key_src);
        const authority = try common.formatHostPortAuthority(allocator, host, port);
        defer allocator.free(authority);

        const handshake = try std.fmt.allocPrint(
            allocator,
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, authority, ws_key },
        );
        defer allocator.free(handshake);

        try io_util.writeAll(&stream, handshake);

        var client = Client{ .allocator = allocator, .stream = stream };
        const response = try client.receiveWithTimeout(allocator, true);
        defer allocator.free(response);

        if (!isStatus101(response)) return error.HandshakeFailed;
        if (!headerHasToken(response, "Upgrade", "websocket") or !headerHasToken(response, "Connection", "upgrade"))
            return error.HandshakeFailed;

        const accept = getHeaderValue(response, "Sec-WebSocket-Accept") orelse return error.HandshakeFailed;
        var expected_accept: [28]u8 = undefined;
        try computeAcceptKey(ws_key, &expected_accept);
        if (!std.mem.eql(u8, std.mem.trim(u8, accept, " \t"), &expected_accept)) {
            return error.HandshakeFailed;
        }

        return client;
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(compat.io());
        self.* = undefined;
    }

    pub fn sendText(self: *Client, payload: []const u8) !void {
        if (self.failed) return error.ConnectionClosed;
        if (payload.len > max_message_size) return error.FrameTooLarge;
        var header: [14]u8 = undefined;
        var hlen: usize = 0;

        header[0] = 0x81;
        hlen += 1;

        if (payload.len <= 125) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
            hlen += 1;
        } else if (payload.len <= 0xffff) {
            header[1] = 0x80 | 126;
            header[2] = @as(u8, @intCast((payload.len >> 8) & 0xff));
            header[3] = @as(u8, @intCast(payload.len & 0xff));
            hlen += 3;
        } else {
            header[1] = 0x80 | 127;
            const payload_len_u64: u64 = @intCast(payload.len);
            std.mem.writeInt(u64, header[2..10], payload_len_u64, .big);
            hlen += 9;
        }

        var mask: [4]u8 = undefined;
        compat.io().random(&mask);
        @memcpy(header[hlen .. hlen + 4], &mask);
        hlen += 4;

        try io_util.writeAll(&self.stream, header[0..hlen]);

        var masked = try self.allocator.alloc(u8, payload.len);
        defer self.allocator.free(masked);

        for (payload, 0..) |b, i| {
            masked[i] = b ^ mask[i % 4];
        }
        try io_util.writeAll(&self.stream, masked);
    }

    pub fn recvText(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        return self.receiveWithTimeout(allocator, false);
    }

    fn receiveWithTimeout(self: *Client, allocator: std.mem.Allocator, comptime headers: bool) ![]u8 {
        if (self.failed) return error.ConnectionClosed;
        const Result = union(enum) { message: anyerror![]u8, timeout: anyerror!void };
        var buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(compat.io(), &buffer);
        defer while (select.cancel()) |result| {
            switch (result) {
                .message => |message| if (message) |bytes| {
                    allocator.free(bytes);
                } else |_| {},
                .timeout => {},
            }
        };
        if (headers) {
            try select.concurrent(.message, readHeadersTask, .{ self, allocator });
        } else {
            try select.concurrent(.message, receiveMessage, .{ self, allocator });
        }
        try select.concurrent(.timeout, receiveTimeout, .{self.receive_timeout_ms});
        const result = try select.await();
        return switch (result) {
            .message => |message| message catch |err| {
                self.failed = true;
                return err;
            },
            .timeout => |done| {
                try done;
                self.failed = true;
                return error.Timeout;
            },
        };
    }

    fn readHeadersTask(self: *Client, allocator: std.mem.Allocator) anyerror![]u8 {
        return readHttpHeaders(allocator, &self.stream);
    }

    fn receiveTimeout(milliseconds: u32) anyerror!void {
        try std.Io.sleep(compat.io(), .fromMilliseconds(milliseconds), .awake);
    }

    fn receiveMessage(self: *Client, allocator: std.mem.Allocator) anyerror![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var expecting_continuation = false;

        while (true) {
            var first2: [2]u8 = undefined;
            try io_util.readExact(&self.stream, &first2);

            const fin = (first2[0] & 0x80) != 0;
            const opcode = first2[0] & 0x0f;
            const masked = (first2[1] & 0x80) != 0;
            if ((first2[0] & 0x70) != 0 or masked) return error.InvalidFrame;
            if (opcode != 0 and opcode != 1 and opcode != 8 and opcode != 9 and opcode != 10)
                return error.InvalidFrame;
            if (opcode >= 8 and (!fin or (first2[1] & 0x7f) > 125)) return error.InvalidFrame;
            var len: usize = first2[1] & 0x7f;

            if (len == 126) {
                var ext: [2]u8 = undefined;
                try io_util.readExact(&self.stream, &ext);
                len = (@as(usize, ext[0]) << 8) | @as(usize, ext[1]);
                if (len < 126) return error.InvalidFrame;
            } else if (len == 127) {
                var ext: [8]u8 = undefined;
                try io_util.readExact(&self.stream, &ext);
                const length = std.mem.readInt(u64, &ext, .big);
                if (length < 65536 or length >> 63 != 0) return error.InvalidFrame;
                if (length > max_message_size) return error.FrameTooLarge;
                len = @intCast(length);
            }
            if (len > max_message_size - out.items.len) return error.FrameTooLarge;

            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (masked) {
                try io_util.readExact(&self.stream, &mask);
            }

            var payload = try allocator.alloc(u8, len);
            defer allocator.free(payload);
            try io_util.readExact(&self.stream, payload);

            if (masked) {
                for (payload, 0..) |b, i| {
                    payload[i] = b ^ mask[i % 4];
                }
            }

            switch (opcode) {
                0x1 => {
                    if (expecting_continuation) return error.InvalidFrame;
                    try out.appendSlice(allocator, payload);
                    if (fin) {
                        if (!std.unicode.utf8ValidateSlice(out.items)) return error.InvalidFrame;
                        return out.toOwnedSlice(allocator);
                    }
                    expecting_continuation = true;
                },
                0x0 => {
                    if (!expecting_continuation) return error.InvalidFrame;
                    try out.appendSlice(allocator, payload);
                    if (fin) {
                        if (!std.unicode.utf8ValidateSlice(out.items)) return error.InvalidFrame;
                        return out.toOwnedSlice(allocator);
                    }
                },
                0x8 => {
                    if (payload.len == 1) return error.InvalidFrame;
                    if (payload.len >= 2) {
                        const code = std.mem.readInt(u16, payload[0..2], .big);
                        if (code < 1000 or code >= 5000 or code == 1004 or code == 1005 or code == 1006 or (code >= 1015 and code < 3000))
                            return error.InvalidFrame;
                        if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidFrame;
                    }
                    try self.sendControlFrame(0x8, payload);
                    return error.ConnectionClosed;
                },
                0x9 => {
                    try self.sendControlFrame(0xA, payload);
                },
                0xA => {},
                else => {
                    // Ignore non-text frames by default.
                },
            }
        }
    }

    fn sendControlFrame(self: *Client, opcode: u8, payload: []const u8) !void {
        if (payload.len > 125) return error.FrameTooLarge;

        var header: [6]u8 = undefined;
        header[0] = 0x80 | (opcode & 0x0f);
        header[1] = 0x80 | @as(u8, @intCast(payload.len));

        var mask: [4]u8 = undefined;
        compat.io().random(&mask);
        @memcpy(header[2..6], &mask);

        try io_util.writeAll(&self.stream, &header);

        var masked = try self.allocator.alloc(u8, payload.len);
        defer self.allocator.free(masked);
        for (payload, 0..) |b, i| masked[i] = b ^ mask[i % 4];
        try io_util.writeAll(&self.stream, masked);
    }
};

fn computeAcceptKey(client_key: []const u8, out: *[28]u8) !void {
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    var buf: [60]u8 = undefined;
    const combined = try std.fmt.bufPrint(&buf, "{s}{s}", .{ client_key, guid });

    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &digest, .{});

    _ = std.base64.standard.Encoder.encode(out, &digest);
}

fn isStatus101(response: []const u8) bool {
    const first_line_end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
    const first_line = response[0..first_line_end];

    if (!std.mem.startsWith(u8, first_line, "HTTP/")) return false;
    var it = std.mem.tokenizeScalar(u8, first_line, ' ');
    _ = it.next() orelse return false;
    const code = it.next() orelse return false;
    return std.mem.eql(u8, code, "101");
}

fn getHeaderValue(headers: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, key)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }

    return null;
}

fn headerHasToken(headers: []const u8, key: []const u8, token: []const u8) bool {
    const value = getHeaderValue(headers, key) orelse return false;
    var tokens = std.mem.splitScalar(u8, value, ',');
    while (tokens.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

fn readHttpHeaders(allocator: std.mem.Allocator, stream: *std.Io.net.Stream) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        try io_util.readExact(stream, &byte);
        try out.append(allocator, byte[0]);

        if (out.items.len > 64 * 1024) return error.HeaderTooLarge;

        if (out.items.len >= 4 and std.mem.endsWith(u8, out.items, "\r\n\r\n")) {
            return out.toOwnedSlice(allocator);
        }
    }
}

test "status 101 parser" {
    const ok = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
    try std.testing.expect(isStatus101(ok));

    const bad = "HTTP/1.1 200 OK\r\n\r\n";
    try std.testing.expect(!isStatus101(bad));
}

test "header lookup" {
    const headers = "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: abc\r\n\r\n";
    try std.testing.expect(getHeaderValue(headers, "sec-websocket-accept") != null);
    try std.testing.expect(std.mem.eql(u8, getHeaderValue(headers, "Sec-WebSocket-Accept").?, "abc"));
}

test "format host authority brackets ipv6 literals" {
    const allocator = std.testing.allocator;
    const formatted = try common.formatHostPortAuthority(allocator, "::1", 9222);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("[::1]:9222", formatted);
}

const TestPair = struct {
    client: Client,
    peer: std.Io.net.Stream,

    fn init() !TestPair {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = try address.listen(compat.io(), .{});
        defer server.deinit(compat.io());
        const stream = try server.socket.address.connect(compat.io(), .{ .mode = .stream });
        errdefer stream.close(compat.io());
        return .{
            .client = .{ .allocator = std.testing.allocator, .stream = stream, .receive_timeout_ms = 1000 },
            .peer = try server.accept(compat.io()),
        };
    }

    fn deinit(self: *TestPair) void {
        self.client.deinit();
        self.peer.close(compat.io());
    }
};

test "websocket fragmented UTF8 text survives interleaved ping and sends masked pong" {
    var pair = try TestPair.init();
    defer pair.deinit();
    try io_util.writeAll(&pair.peer, "\x01\x02h\xc3\x89\x01?\x80\x01\xa9");
    const result = try pair.client.recvText(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hé", result);
    var pong: [7]u8 = undefined;
    try io_util.readExact(&pair.peer, &pong);
    try std.testing.expectEqual(@as(u8, 0x8a), pong[0]);
    try std.testing.expectEqual(@as(u8, 0x81), pong[1]);
    try std.testing.expectEqual(@as(u8, '?'), pong[6] ^ pong[2]);
}

test "websocket rejects invalid framing and oversized messages before allocating payload" {
    const cases = .{
        .{ "\xc1\x00", error.InvalidFrame }, // Reserved bit without an extension.
        .{ "\x81\x80", error.InvalidFrame }, // Servers must not mask.
        .{ "\x09\x00", error.InvalidFrame }, // Fragmented control message.
        .{ "\x89\x7e", error.InvalidFrame }, // Oversized control message.
        .{ "\x80\x00", error.InvalidFrame }, // Unsolicited continuation.
        .{ "\x82\x00", error.InvalidFrame }, // CDP requires text frames.
        .{ "\x81\x01\xff", error.InvalidFrame }, // Invalid UTF8.
        .{ "\x81\x7e\x00\x01", error.InvalidFrame }, // Nonminimal length.
        .{ "\x81\x7f\x80\x00\x00\x00\x00\x00\x00\x00", error.InvalidFrame },
        .{ "\x81\x7f\x00\x00\x00\x00\x04\x00\x00\x01", error.FrameTooLarge },
        .{ "\x88\x01x", error.InvalidFrame }, // Incomplete close status.
    };
    inline for (cases) |case| {
        var pair = try TestPair.init();
        defer pair.deinit();
        try io_util.writeAll(&pair.peer, case[0]);
        try std.testing.expectError(case[1], pair.client.recvText(std.testing.allocator));
        try std.testing.expectError(error.ConnectionClosed, pair.client.recvText(std.testing.allocator));
    }
}

test "websocket timeout cancels stalled partial frame and prevents stream reuse" {
    var pair = try TestPair.init();
    defer pair.deinit();
    pair.client.receive_timeout_ms = 20;
    try io_util.writeAll(&pair.peer, "\x81\x05ab");
    try std.testing.expectError(error.Timeout, pair.client.recvText(std.testing.allocator));
    try std.testing.expectError(error.ConnectionClosed, pair.client.sendText("next"));
}

test "websocket acknowledges normal close and releases stream" {
    var pair = try TestPair.init();
    defer pair.deinit();
    try io_util.writeAll(&pair.peer, "\x88\x02\x03\xe8");
    try std.testing.expectError(error.ConnectionClosed, pair.client.recvText(std.testing.allocator));
    var reply: [8]u8 = undefined;
    try io_util.readExact(&pair.peer, &reply);
    try std.testing.expectEqual(@as(u8, 0x88), reply[0]);
    try std.testing.expectEqual(@as(u8, 0x82), reply[1]);
    try std.testing.expectEqual(@as(u8, 3), reply[6] ^ reply[2]);
    try std.testing.expectEqual(@as(u8, 0xe8), reply[7] ^ reply[3]);
}

fn handshakeTestServer(server: *std.Io.net.Server) void {
    var peer = server.accept(compat.io()) catch return;
    defer peer.close(compat.io());
    const request = readHttpHeaders(std.testing.allocator, &peer) catch return;
    defer std.testing.allocator.free(request);
    const key = getHeaderValue(request, "Sec-WebSocket-Key") orelse return;
    var accept: [28]u8 = undefined;
    computeAcceptKey(key, &accept) catch return;
    const response = std.fmt.allocPrint(
        std.testing.allocator,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n\x81\x02ok",
        .{accept},
    ) catch return;
    defer std.testing.allocator.free(response);
    io_util.writeAll(&peer, response) catch return;
}

test "websocket upgrade reads real headers without consuming coalesced first frame" {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(compat.io(), .{});
    defer server.deinit(compat.io());
    const thread = try std.Thread.spawn(.{}, handshakeTestServer, .{&server});
    defer thread.join();
    var client = try Client.connect(std.testing.allocator, "127.0.0.1", server.socket.address.getPort(), "/devtools/page/test");
    defer client.deinit();
    const text = try client.recvText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ok", text);
    try std.testing.expect(!headerHasToken("HTTP/1.1 101\r\nConnection: upgrade-invalid\r\n\r\n", "Connection", "upgrade"));
}
