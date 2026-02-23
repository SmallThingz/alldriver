const std = @import("std");
const types = @import("../types.zig");
const common = @import("../protocol/common.zig");
const actions = @import("actions.zig");
const network = @import("network.zig");
const storage = @import("storage.zig");
const artifacts = @import("artifacts.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    id: u64,
    install: types.BrowserInstall,
    capabilities: types.CapabilitySet,
    adapter_kind: common.AdapterKind,
    endpoint: ?[]u8,
    current_url: ?[]u8 = null,
    child: ?std.process.Child = null,
    owned_argv: ?[]const []const u8 = null,

    pub fn deinit(self: *Session) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
        }

        if (self.current_url) |url| {
            self.allocator.free(url);
        }
        if (self.endpoint) |ep| {
            self.allocator.free(ep);
        }
        if (self.owned_argv) |args| {
            for (args) |arg| {
                self.allocator.free(arg);
            }
            self.allocator.free(args);
        }

        self.allocator.free(self.install.path);
        if (self.install.version) |version| {
            self.allocator.free(version);
        }

        self.* = undefined;
    }

    pub fn navigate(self: *Session, url: []const u8) !void {
        try actions.navigate(self, url);
    }

    pub fn reload(self: *Session) !void {
        try actions.reload(self);
    }

    pub fn click(self: *Session, selector: []const u8) !void {
        try actions.click(self, selector);
    }

    pub fn typeText(self: *Session, selector: []const u8, text: []const u8) !void {
        try actions.typeText(self, selector, text);
    }

    pub fn evaluate(self: *Session, script: []const u8) ![]u8 {
        return actions.evaluate(self, script);
    }

    pub fn waitFor(self: *Session, condition: actions.WaitCondition, timeout_ms: u32) !void {
        try actions.waitFor(self, condition, timeout_ms);
    }

    pub fn enableNetworkInterception(self: *Session) !void {
        try network.enableInterception(self);
    }

    pub fn setCookie(self: *Session, cookie: storage.Cookie) !void {
        try storage.setCookie(self, cookie);
    }

    pub fn screenshot(self: *Session, allocator: std.mem.Allocator, format: artifacts.ScreenshotFormat) ![]u8 {
        return artifacts.screenshot(self, allocator, format);
    }
};

pub fn nextSessionId() u64 {
    return @as(u64, @intCast(std.time.milliTimestamp()));
}
