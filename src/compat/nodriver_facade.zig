const std = @import("std");
const types = @import("../types.zig");
const runtime = @import("../runtime.zig");

pub const NodriverFacade = struct {
    allocator: std.mem.Allocator,
    session: runtime.Session,

    pub fn deinit(self: *NodriverFacade) void {
        self.session.deinit();
        self.* = undefined;
    }

    pub fn get(self: *NodriverFacade, url: []const u8) !void {
        try self.session.navigate(url);
    }

    pub fn click(self: *NodriverFacade, selector: []const u8) !void {
        try self.session.click(selector);
    }

    pub fn typeText(self: *NodriverFacade, selector: []const u8, text: []const u8) !void {
        try self.session.typeText(selector, text);
    }

    pub fn eval(self: *NodriverFacade, script: []const u8) ![]u8 {
        return self.session.evaluate(script);
    }
};

pub const StartOptions = struct {
    preference: types.BrowserPreference,
    discovery: types.DiscoveryOptions = .{},
    profile_mode: types.ProfileMode,
    profile_dir: ?[]const u8 = null,
    headless: bool = false,
    args: []const []const u8 = &.{},
};

pub fn start(allocator: std.mem.Allocator, options: StartOptions) !NodriverFacade {
    const installs = try runtime.discover(allocator, options.preference, options.discovery);
    defer runtime.freeInstalls(allocator, installs);

    if (installs.len == 0) return error.NoBrowserFound;

    const selected = installs[0];
    const session = try runtime.launch(allocator, .{
        .install = selected,
        .profile_mode = options.profile_mode,
        .profile_dir = options.profile_dir,
        .headless = options.headless,
        .args = options.args,
    });

    return .{
        .allocator = allocator,
        .session = session,
    };
}
