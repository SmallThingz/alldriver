const std = @import("std");

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,

    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
    ) !Client {
        var stream = try std.net.tcpConnectToHost(allocator, host, port);
        errdefer stream.close();

        var key_src: [16]u8 = undefined;
        std.crypto.random.bytes(&key_src);
        var key_buf: [std.base64.standard.Encoder.calcSize(16)]u8 = undefined;
        const ws_key = std.base64.standard.Encoder.encode(&key_buf, &key_src);

        const handshake = try std.fmt.allocPrint(
            allocator,
            "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ path, host, port, ws_key },
        );
        defer allocator.free(handshake);

        try stream.writeAll(handshake);

        const response = try readHttpHeaders(allocator, &stream);
        defer allocator.free(response);

        if (!isStatus101(response)) return error.HandshakeFailed;

        const accept = getHeaderValue(response, "Sec-WebSocket-Accept") orelse return error.HandshakeFailed;
        var expected_accept: [28]u8 = undefined;
        try computeAcceptKey(ws_key, &expected_accept);
        if (!std.mem.eql(u8, std.mem.trim(u8, accept, " \t"), &expected_accept)) {
            return error.HandshakeFailed;
        }

        return .{ .allocator = allocator, .stream = stream };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close();
        self.* = undefined;
    }

    pub fn sendText(self: *Client, payload: []const u8) !void {
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
        std.crypto.random.bytes(&mask);
        @memcpy(header[hlen .. hlen + 4], &mask);
        hlen += 4;

        try self.stream.writeAll(header[0..hlen]);

        var masked = try self.allocator.alloc(u8, payload.len);
        defer self.allocator.free(masked);

        for (payload, 0..) |b, i| {
            masked[i] = b ^ mask[i % 4];
        }
        try self.stream.writeAll(masked);
    }

    pub fn recvText(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var expecting_continuation = false;

        while (true) {
            var first2: [2]u8 = undefined;
            try readExact(&self.stream, &first2);

            const fin = (first2[0] & 0x80) != 0;
            const opcode = first2[0] & 0x0f;
            const masked = (first2[1] & 0x80) != 0;
            var len: usize = first2[1] & 0x7f;

            if (len == 126) {
                var ext: [2]u8 = undefined;
                try readExact(&self.stream, &ext);
                len = (@as(usize, ext[0]) << 8) | @as(usize, ext[1]);
            } else if (len == 127) {
                var ext: [8]u8 = undefined;
                try readExact(&self.stream, &ext);
                len = 0;
                for (ext) |b| {
                    len = (len << 8) | @as(usize, b);
                }
            }

            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (masked) {
                try readExact(&self.stream, &mask);
            }

            var payload = try allocator.alloc(u8, len);
            defer allocator.free(payload);
            try readExact(&self.stream, payload);

            if (masked) {
                for (payload, 0..) |b, i| {
                    payload[i] = b ^ mask[i % 4];
                }
            }

            switch (opcode) {
                0x1 => {
                    if (expecting_continuation) return error.InvalidFrame;
                    try out.appendSlice(allocator, payload);
                    if (fin) return out.toOwnedSlice(allocator);
                    expecting_continuation = true;
                },
                0x0 => {
                    if (!expecting_continuation) return error.InvalidFrame;
                    try out.appendSlice(allocator, payload);
                    if (fin) return out.toOwnedSlice(allocator);
                },
                0x8 => return error.ConnectionClosed,
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
        std.crypto.random.bytes(&mask);
        @memcpy(header[2..6], &mask);

        try self.stream.writeAll(&header);

        var masked = try self.allocator.alloc(u8, payload.len);
        defer self.allocator.free(masked);
        for (payload, 0..) |b, i| masked[i] = b ^ mask[i % 4];
        try self.stream.writeAll(masked);
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

fn readHttpHeaders(allocator: std.mem.Allocator, stream: *std.net.Stream) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var b: [1]u8 = undefined;
    while (true) {
        const n = try stream.read(&b);
        if (n == 0) return error.ConnectionClosed;
        try out.append(allocator, b[0]);

        if (out.items.len > 64 * 1024) return error.HeaderTooLarge;

        if (out.items.len >= 4 and std.mem.endsWith(u8, out.items, "\r\n\r\n")) {
            return out.toOwnedSlice(allocator);
        }
    }
}

fn readExact(stream: *std.net.Stream, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const n = try stream.read(buf[read..]);
        if (n == 0) return error.ConnectionClosed;
        read += n;
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
