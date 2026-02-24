const std = @import("std");
const types = @import("../types.zig");
const runtime = @import("../runtime.zig");
const config = @import("browser_driver_config");

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
    preference: types.BrowserPreference = .{
        .kinds = defaultNodriverKinds(),
        .allow_managed_download = false,
    },
    discovery: types.DiscoveryOptions = .{},
    profile_mode: types.ProfileMode = .ephemeral,
    profile_dir: ?[]const u8 = null,
    headless: bool = false,
    args: []const []const u8 = &.{},
};

fn defaultNodriverKinds() []const types.BrowserKind {
    if (@hasDecl(config, "include_lightpanda_browser") and config.include_lightpanda_browser) {
        return &.{ .chrome, .edge, .brave, .lightpanda };
    }
    return &.{ .chrome, .edge, .brave };
}

fn isNodriverEngine(engine: types.EngineKind) bool {
    return engine == .chromium;
}

pub fn start(allocator: std.mem.Allocator, options: StartOptions) !NodriverFacade {
    const installs = try runtime.discover(allocator, options.preference, options.discovery);
    defer runtime.freeInstalls(allocator, installs);

    if (installs.len == 0) return error.NoBrowserFound;

    const selected = installs[0];
    if (!isNodriverEngine(selected.engine)) return error.UnsupportedNodriverEngine;

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

test "nodriver facade only accepts chromium engine installs" {
    try std.testing.expect(isNodriverEngine(.chromium));
    try std.testing.expect(!isNodriverEngine(.gecko));
    try std.testing.expect(!isNodriverEngine(.webkit));
    try std.testing.expect(!isNodriverEngine(.unknown));
}

test "default nodriver kinds respect lightpanda build flag" {
    if (@hasDecl(config, "include_lightpanda_browser") and config.include_lightpanda_browser) {
        try std.testing.expect(defaultNodriverKinds().len == 4);
    } else {
        try std.testing.expect(defaultNodriverKinds().len == 3);
    }
}
