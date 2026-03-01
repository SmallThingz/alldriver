const std = @import("std");

pub fn readExact(stream: *std.net.Stream, buf: []u8) !void {
    var read_total: usize = 0;
    while (read_total < buf.len) {
        const n = try stream.read(buf[read_total..]);
        if (n == 0) return error.ConnectionClosed;
        read_total += n;
    }
}
