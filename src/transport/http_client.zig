const std = @import("std");

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
    var stream = try std.net.tcpConnectToHost(allocator, host, port);
    defer stream.close();

    const body = body_json orelse "";
    const method_name = switch (method) {
        .GET => "GET",
        .POST => "POST",
        .DELETE => "DELETE",
    };

    const request_payload = try std.fmt.allocPrint(
        allocator,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ method_name, path, host, port, body.len, body },
    );
    defer allocator.free(request_payload);

    try stream.writeAll(request_payload);

    const header_bytes = try readHttpHeaders(allocator, &stream, options.max_header_bytes);
    defer allocator.free(header_bytes);

    const first_line_end = std.mem.indexOf(u8, header_bytes, "\r\n") orelse header_bytes.len;
    const first_line = header_bytes[0..first_line_end];
    const status_code = parseStatusCode(first_line) catch return error.InvalidResponse;

    const maybe_content_length = parseContentLength(header_bytes);
    const response_body = if (maybe_content_length) |content_length|
        try readFixedBody(allocator, &stream, content_length)
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

fn readHttpHeaders(allocator: std.mem.Allocator, stream: *std.net.Stream, max_header_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var b: [1]u8 = undefined;
    while (true) {
        const n = try stream.read(&b);
        if (n == 0) return error.ConnectionClosed;
        try out.append(allocator, b[0]);

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

fn readFixedBody(allocator: std.mem.Allocator, stream: *std.net.Stream, content_length: usize) ![]u8 {
    var body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);

    var read_total: usize = 0;
    while (read_total < content_length) {
        const n = try stream.read(body[read_total..]);
        if (n == 0) return error.ConnectionClosed;
        read_total += n;
    }

    return body;
}

fn readBodyUntilClose(allocator: std.mem.Allocator, stream: *std.net.Stream, max_body_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;

        if (out.items.len + n > max_body_bytes) return error.BodyTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }

    return out.toOwnedSlice(allocator);
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
