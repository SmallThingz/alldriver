const std = @import("std");
const common = @import("../protocol/common.zig");
const io_util = @import("../util/io.zig");
const compat = @import("../util/compat.zig");

pub const HttpMethod = enum {
    GET,
    POST,
    DELETE,
};

pub const RequestOptions = struct {
    max_header_bytes: usize = 64 * 1024,
    max_body_bytes: usize = 16 * 1024 * 1024,
    timeout_ms: u32 = 30_000,
};

pub const Response = struct {
    status_code: u16,
    body: []u8,
};

pub fn requestJsonWithOptions(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: HttpMethod,
    path: []const u8,
    body_json: ?[]const u8,
    options: RequestOptions,
) !Response {
    const Result = union(enum) { response: anyerror!Response, timeout: anyerror!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(compat.io(), &buffer);
    defer while (select.cancel()) |result| {
        switch (result) {
            .response => |response| if (response) |value| {
                allocator.free(value.body);
            } else |_| {},
            .timeout => {},
        }
    };
    try select.concurrent(.response, requestBlocking, .{ allocator, host, port, method, path, body_json, options });
    try select.concurrent(.timeout, requestTimeout, .{options.timeout_ms});
    return switch (try select.await()) {
        .response => |response| response,
        .timeout => |done| {
            try done;
            return error.Timeout;
        },
    };
}

fn requestTimeout(milliseconds: u32) anyerror!void {
    try std.Io.sleep(compat.io(), .fromMilliseconds(milliseconds), .awake);
}

pub fn requestJson(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: HttpMethod,
    path: []const u8,
    body_json: ?[]const u8,
) !Response {
    return requestJsonWithOptions(allocator, host, port, method, path, body_json, .{});
}

fn requestBlocking(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: HttpMethod,
    path: []const u8,
    body_json: ?[]const u8,
    options: RequestOptions,
) anyerror!Response {
    if (std.mem.indexOfAny(u8, path, "\r\n ") != null or std.mem.indexOfAny(u8, host, "\r\n") != null)
        return error.InvalidRequest;
    const address = if (std.mem.eql(u8, host, "localhost"))
        try std.Io.net.IpAddress.parseIp4("127.0.0.1", port)
    else
        std.Io.net.IpAddress.parse(host, port) catch try std.Io.net.IpAddress.resolve(compat.io(), host, port);
    var stream = try address.connect(compat.io(), .{ .mode = .stream });
    defer stream.close(compat.io());

    const body = body_json orelse "";
    const method_name = switch (method) {
        .GET => "GET",
        .POST => "POST",
        .DELETE => "DELETE",
    };
    const authority = try common.formatHostPortAuthority(allocator, host, port);
    defer allocator.free(authority);

    const request_payload = try std.fmt.allocPrint(
        allocator,
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ method_name, path, authority, body.len, body },
    );
    defer allocator.free(request_payload);

    try io_util.writeAll(&stream, request_payload);

    const header_bytes = try readHttpHeaders(allocator, &stream, options.max_header_bytes);
    defer allocator.free(header_bytes);

    const first_line_end = std.mem.indexOf(u8, header_bytes, "\r\n") orelse header_bytes.len;
    const first_line = header_bytes[0..first_line_end];
    const status_code = parseStatusCode(first_line) catch return error.InvalidResponse;

    const maybe_content_length = try parseContentLength(header_bytes);
    const is_chunked = try hasChunkedTransferEncoding(header_bytes);
    if (is_chunked and maybe_content_length != null) return error.InvalidResponse;
    const response_body = if (status_code == 204 or status_code == 304)
        try allocator.alloc(u8, 0)
    else if (is_chunked)
        try readChunkedBody(allocator, &stream, options.max_body_bytes, options.max_header_bytes)
    else if (maybe_content_length) |content_length|
        try readFixedBody(allocator, &stream, content_length, options.max_body_bytes)
    else
        try readBodyUntilClose(allocator, &stream, options.max_body_bytes);

    return .{
        .status_code = status_code,
        .body = response_body,
    };
}

pub fn getJson(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) !Response {
    return requestJson(allocator, host, port, .GET, path, null);
}

pub fn postJson(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8, body: []const u8) !Response {
    return requestJson(allocator, host, port, .POST, path, body);
}

pub fn deleteJson(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) !Response {
    return requestJson(allocator, host, port, .DELETE, path, null);
}

fn readHttpHeaders(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_header_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        try out.append(allocator, try io_util.readByte(stream));

        if (out.items.len > max_header_bytes) return error.HeaderTooLarge;

        if (out.items.len >= 4 and std.mem.endsWith(u8, out.items, "\r\n\r\n")) {
            return out.toOwnedSlice(allocator);
        }
    }
}

fn parseStatusCode(line: []const u8) !u16 {
    if (!std.mem.startsWith(u8, line, "HTTP/")) return error.InvalidResponse;

    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return error.InvalidResponse;
    const code = it.next() orelse return error.InvalidResponse;
    if (code.len != 3) return error.InvalidResponse;
    const status = std.fmt.parseInt(u16, code, 10) catch return error.InvalidResponse;
    if (status < 100 or status > 599) return error.InvalidResponse;
    return status;
}

fn parseContentLength(header_bytes: []const u8) !?usize {
    var length: ?usize = null;
    var it = std.mem.splitSequence(u8, header_bytes, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return error.InvalidResponse;
        for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResponse;
        const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidResponse;
        if (length) |previous| {
            if (previous != parsed) return error.InvalidResponse;
        }
        length = parsed;
    }

    return length;
}

fn hasChunkedTransferEncoding(header_bytes: []const u8) !bool {
    var chunked = false;
    var it = std.mem.splitSequence(u8, header_bytes, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (chunked or !std.ascii.eqlIgnoreCase(value, "chunked")) return error.InvalidResponse;
        chunked = true;
    }
    return chunked;
}

fn readFixedBody(
    allocator: std.mem.Allocator,
    stream: *std.Io.net.Stream,
    content_length: usize,
    max_body_bytes: usize,
) ![]u8 {
    if (content_length > max_body_bytes) return error.BodyTooLarge;
    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);

    try io_util.readExact(stream, body);

    return body;
}

fn readChunkedBody(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_body_bytes: usize, max_header_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        const line = try readHttpLine(allocator, stream, 8 * 1024);
        defer allocator.free(line);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) return error.InvalidResponse;

        const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        const size_hex = std.mem.trim(u8, trimmed[0..semi], " \t");
        const size = std.fmt.parseInt(usize, size_hex, 16) catch return error.InvalidResponse;
        if (size == 0) {
            // Consume trailers until blank line.
            var trailer_bytes: usize = 0;
            while (true) {
                const trailer = try readHttpLine(allocator, stream, 8 * 1024);
                defer allocator.free(trailer);
                if (trailer.len + 2 > max_header_bytes -| trailer_bytes) return error.HeaderTooLarge;
                trailer_bytes += trailer.len + 2;
                if (std.mem.trim(u8, trailer, " \t").len == 0) break;
            }
            break;
        }

        if (size > max_body_bytes - out.items.len) return error.BodyTooLarge;
        const offset = out.items.len;
        try out.resize(allocator, offset + size);
        try io_util.readExact(stream, out.items[offset .. offset + size]);

        var crlf: [2]u8 = undefined;
        try io_util.readExact(stream, &crlf);
        if (!(crlf[0] == '\r' and crlf[1] == '\n')) return error.InvalidResponse;
    }

    return out.toOwnedSlice(allocator);
}

fn readBodyUntilClose(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_body_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try io_util.read(stream, &buf);
        if (n == 0) break;

        if (out.items.len + n > max_body_bytes) return error.BodyTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }

    return out.toOwnedSlice(allocator);
}

test "format host authority brackets ipv6 literals" {
    const allocator = std.testing.allocator;
    const formatted = try common.formatHostPortAuthority(allocator, "::1", 9222);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("[::1]:9222", formatted);
}

fn readHttpLine(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_line_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        const b = try io_util.readByte(stream);
        if (b == '\n') {
            if (out.items.len > 0 and out.items[out.items.len - 1] == '\r') {
                _ = out.pop();
            } else return error.InvalidResponse;
            return out.toOwnedSlice(allocator);
        }
        if (out.items.len >= max_line_bytes) return error.HeaderTooLarge;
        try out.append(allocator, b);
    }
}

test "parse status code" {
    try std.testing.expectEqual(@as(u16, 200), try parseStatusCode("HTTP/1.1 200 OK"));
}

test "parse status code invalid" {
    try std.testing.expectError(error.InvalidResponse, parseStatusCode("200 OK"));
}

test "parse content length" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n";
    try std.testing.expectEqual(@as(?usize, 12), try parseContentLength(raw));
}

test "parse transfer encoding chunked" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    try std.testing.expect(try hasChunkedTransferEncoding(raw));
    try std.testing.expect(!try hasChunkedTransferEncoding("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"));
}

const TestServer = struct {
    server: *std.Io.net.Server,
    fragments: []const []const u8,
    stall: bool = false,

    fn run(self: *TestServer) void {
        var peer = self.server.accept(compat.io()) catch return;
        defer peer.close(compat.io());
        const request = readHttpHeaders(std.testing.allocator, &peer, 4096) catch return;
        defer std.testing.allocator.free(request);
        for (self.fragments) |fragment| io_util.writeAll(&peer, fragment) catch return;
        if (self.stall) {
            var byte: [1]u8 = undefined;
            _ = io_util.read(&peer, &byte) catch return;
        }
    }
};

fn testRequest(fragments: []const []const u8, stall: bool, options: RequestOptions) !Response {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(compat.io(), .{});
    defer server.deinit(compat.io());
    var context = TestServer{ .server = &server, .fragments = fragments, .stall = stall };
    var server_task = try std.Io.concurrent(compat.io(), TestServer.run, .{&context});
    defer server_task.cancel(compat.io());
    return requestJsonWithOptions(std.testing.allocator, "127.0.0.1", server.socket.address.getPort(), .GET, "/json/version", null, options);
}

test "HTTP reads fragmented content-length and chunked bodies through real sockets" {
    const fixed = try testRequest(&.{ "HTTP/1.1 200 OK\r", "\nContent-Length: 5\r\n\r\nhe", "llo" }, true, .{});
    defer std.testing.allocator.free(fixed.body);
    try std.testing.expectEqual(@as(u16, 200), fixed.status_code);
    try std.testing.expectEqualStrings("hello", fixed.body);
    const chunked = try testRequest(&.{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "2;ext=value\r\nhe\r", "\n3\r\nllo\r\n0\r\nX-Trailer: yes\r\n\r\n" }, true, .{});
    defer std.testing.allocator.free(chunked.body);
    try std.testing.expectEqualStrings("hello", chunked.body);
    const closed = try testRequest(&.{ "HTTP/1.0 200 OK\r\n\r\n", "closed" }, false, .{});
    defer std.testing.allocator.free(closed.body);
    try std.testing.expectEqualStrings("closed", closed.body);
}

test "HTTP rejects premature EOF and malformed length and chunk framing" {
    const cases = .{
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab", error.ConnectionClosed },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: invalid\r\n\r\n", error.InvalidResponse },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", error.InvalidResponse },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", error.InvalidResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n", error.InvalidResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n", error.InvalidResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na", error.ConnectionClosed },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\na", error.InvalidResponse },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabXX", error.InvalidResponse },
        .{ "HTTP/1.1 999 Nope\r\n\r\n", error.InvalidResponse },
    };
    inline for (cases) |case| try std.testing.expectError(case[1], testRequest(&.{case[0]}, false, .{}));
}

test "HTTP bounds headers fixed chunked close-delimited bodies and trailers" {
    try std.testing.expectError(error.HeaderTooLarge, testRequest(&.{"HTTP/1.1 200 OK\r\nLong: header\r\n\r\n"}, false, .{ .max_header_bytes = 20 }));
    try std.testing.expectError(error.BodyTooLarge, testRequest(&.{"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n"}, false, .{ .max_body_bytes = 8 }));
    try std.testing.expectError(error.BodyTooLarge, testRequest(&.{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffff\r\n"}, false, .{ .max_body_bytes = 8 }));
    try std.testing.expectError(error.BodyTooLarge, testRequest(&.{"HTTP/1.1 200 OK\r\n\r\n123456789"}, false, .{ .max_body_bytes = 8 }));
    try std.testing.expectError(error.HeaderTooLarge, testRequest(&.{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX: 1234567890123456789012345678901234567890\r\nX: 1234567890123456789012345678901234567890\r\n\r\n"}, false, .{ .max_header_bytes = 64 }));
}

test "HTTP deadline cancels stalled headers and partial bodies without leaking" {
    try std.testing.expectError(error.Timeout, testRequest(&.{"HTTP/1.1 200 OK\r\n"}, true, .{ .timeout_ms = 50 }));
    try std.testing.expectError(error.Timeout, testRequest(&.{"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nab"}, true, .{ .timeout_ms = 50 }));
    try std.testing.expectError(error.Timeout, testRequest(&.{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab"}, true, .{ .timeout_ms = 50 }));
}
