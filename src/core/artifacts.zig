const std = @import("std");
const Session = @import("session.zig").Session;
const executor = @import("../protocol/executor.zig");

pub const ScreenshotFormat = enum {
    png,
    jpeg,
};

pub const DownloadItem = struct {
    suggested_filename: []const u8,
    save_path: []const u8,
    completed: bool,
};

pub fn screenshot(session: *Session, allocator: std.mem.Allocator, format: ScreenshotFormat) ![]u8 {
    _ = format;
    if (!session.supports(.dom)) return error.UnsupportedCapability;

    const raw = try executor.screenshot(session);
    defer session.allocator.free(raw);

    if (try extractBase64Screenshot(allocator, raw)) |bytes| {
        return bytes;
    }

    return allocator.dupe(u8, raw);
}

pub fn startTracing(session: *Session) !void {
    if (!session.supports(.tracing)) return error.UnsupportedCapability;
    try executor.startTracing(session);
}

pub fn stopTracing(session: *Session, allocator: std.mem.Allocator) ![]u8 {
    if (!session.supports(.tracing)) return error.UnsupportedCapability;

    const raw = try executor.stopTracing(session);
    defer session.allocator.free(raw);
    return allocator.dupe(u8, raw);
}

pub fn listDownloads(session: *Session, allocator: std.mem.Allocator) ![]DownloadItem {
    if (!session.supports(.downloads)) return error.UnsupportedCapability;
    return allocator.alloc(DownloadItem, 0);
}

fn extractBase64Screenshot(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    var b64: ?[]const u8 = null;

    if (root.object.get("result")) |result| {
        if (result == .object) {
            if (result.object.get("data")) |data| {
                if (data == .string) b64 = data.string;
            }
        }
    }

    if (b64 == null) {
        if (root.object.get("value")) |value| {
            if (value == .string) b64 = value.string;
        }
    }

    if (b64 == null) return null;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64.?) catch return error.InvalidResponse;
    var out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);

    const actual_len = std.base64.standard.Decoder.decode(out, b64.?) catch return error.InvalidResponse;
    return out[0..actual_len];
}

test "extract base64 screenshot payload" {
    const allocator = std.testing.allocator;
    const raw = "{\"result\":{\"data\":\"aGVsbG8=\"}}";

    const data = try extractBase64Screenshot(allocator, raw);
    defer if (data) |d| allocator.free(d);

    try std.testing.expect(data != null);
    try std.testing.expect(std.mem.eql(u8, data.?, "hello"));
}
