const std = @import("std");
const compat = @import("compat.zig");

pub fn readExact(stream: *std.Io.net.Stream, buf: []u8) !void {
    var reader = stream.reader(compat.io(), &.{});
    reader.interface.readSliceAll(buf) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.EndOfStream => return error.ConnectionClosed,
    };
}

pub fn read(stream: *std.Io.net.Stream, buf: []u8) !usize {
    var reader = stream.reader(compat.io(), &.{});
    return reader.interface.readSliceShort(buf) catch {
        return reader.err.?;
    };
}

pub fn readByte(stream: *std.Io.net.Stream) !u8 {
    var reader = stream.reader(compat.io(), &.{});
    return reader.interface.takeByte() catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.EndOfStream => return error.ConnectionClosed,
    };
}

pub fn writeAll(stream: *std.Io.net.Stream, bytes: []const u8) !void {
    var writer = stream.writer(compat.io(), &.{});
    writer.interface.writeAll(bytes) catch {
        return writer.err.?;
    };
    writer.interface.flush() catch {
        return writer.err.?;
    };
}
