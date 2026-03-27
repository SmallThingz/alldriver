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
};

pub const Response = struct {
    status_code: u16,
    body: []u8,
};

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

pub fn requestJsonWithOptions(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: HttpMethod,
    path: []const u8,
    body_json: ?[]const u8,
    options: RequestOptions,
) !Response {
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

    const maybe_content_length = parseContentLength(header_bytes);
    const is_chunked = hasChunkedTransferEncoding(header_bytes);
    const response_body = if (is_chunked)
        try readChunkedBody(allocator, &stream, options.max_body_bytes)
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
    return std.fmt.parseInt(u16, code, 10);
}

fn parseContentLength(header_bytes: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, header_bytes, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }

    return null;
}

fn hasChunkedTransferEncoding(header_bytes: []const u8) bool {
    var it = std.mem.splitSequence(u8, header_bytes, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        var enc_it = std.mem.splitScalar(u8, value, ',');
        while (enc_it.next()) |enc_raw| {
            const enc = std.mem.trim(u8, enc_raw, " \t");
            if (std.ascii.eqlIgnoreCase(enc, "chunked")) return true;
        }
        return false;
    }
    return false;
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

fn readChunkedBody(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_body_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        const line = try readHttpLine(allocator, stream, 8 * 1024);
        defer allocator.free(line);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        const size_hex = std.mem.trim(u8, trimmed[0..semi], " \t");
        const size = std.fmt.parseInt(usize, size_hex, 16) catch return error.InvalidResponse;
        if (size == 0) {
            // Consume trailers until blank line.
            while (true) {
                const trailer = try readHttpLine(allocator, stream, 8 * 1024);
                defer allocator.free(trailer);
                if (std.mem.trim(u8, trailer, " \t").len == 0) break;
            }
            break;
        }

        if (out.items.len + size > max_body_bytes) return error.BodyTooLarge;
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
            }
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
    try std.testing.expectEqual(@as(?usize, 12), parseContentLength(raw));
}

test "parse transfer encoding chunked" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    try std.testing.expect(hasChunkedTransferEncoding(raw));
    try std.testing.expect(!hasChunkedTransferEncoding("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"));
}
