const std = @import("std");
const Session = @import("session.zig").Session;

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
    if (!session.capabilities.dom) return error.UnsupportedCapability;
    return allocator.dupe(u8, "screenshot-not-captured-in-scaffold");
}

pub fn startTracing(session: *Session) !void {
    if (!session.capabilities.tracing) return error.UnsupportedCapability;
}

pub fn stopTracing(session: *Session, allocator: std.mem.Allocator) ![]u8 {
    if (!session.capabilities.tracing) return error.UnsupportedCapability;
    return allocator.dupe(u8, "trace-not-captured-in-scaffold");
}

pub fn listDownloads(session: *Session, allocator: std.mem.Allocator) ![]DownloadItem {
    if (!session.capabilities.downloads) return error.UnsupportedCapability;
    return allocator.alloc(DownloadItem, 0);
}
