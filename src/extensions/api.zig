const std = @import("std");
const types = @import("../types.zig");
const config = @import("browser_driver_config");

pub const ScoreInstallHook = fn (install: types.BrowserInstall) i32;
pub const LaunchArgsHook = fn (
    allocator: std.mem.Allocator,
    options: types.LaunchOptions,
    current_args: []const []const u8,
) anyerror![][]const u8;
pub const SessionInitHook = fn (session_id: u64) void;
pub const EventObserverHook = fn (name: []const u8, payload_json: []const u8) void;

pub const Hooks = struct {
    score_install: ?*const ScoreInstallHook = null,
    launch_args: ?*const LaunchArgsHook = null,
    session_init: ?*const SessionInitHook = null,
    event_observer: ?*const EventObserverHook = null,
};

var active_hooks: Hooks = .{};
var initialized = false;

pub fn registerHooks(hooks: Hooks) void {
    ensureInitialized();
    active_hooks = hooks;
}

pub fn currentHooks() Hooks {
    ensureInitialized();
    return active_hooks;
}

pub fn scoreInstall(install: types.BrowserInstall) i32 {
    ensureInitialized();
    if (active_hooks.score_install) |score_fn| {
        return score_fn(install);
    }
    return 0;
}

pub fn applyLaunchArgs(
    allocator: std.mem.Allocator,
    options: types.LaunchOptions,
    args: []const []const u8,
) ![][]const u8 {
    ensureInitialized();
    if (active_hooks.launch_args) |hook| {
        return hook(allocator, options, args);
    }

    const copied = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        copied[i] = try allocator.dupe(u8, arg);
    }
    return copied;
}

pub fn notifySessionInit(session_id: u64) void {
    ensureInitialized();
    if (active_hooks.session_init) |hook| {
        hook(session_id);
    }
}

pub fn notifyEvent(name: []const u8, payload_json: []const u8) void {
    ensureInitialized();
    if (active_hooks.event_observer) |hook| {
        hook(name, payload_json);
    }
}

fn ensureInitialized() void {
    if (initialized) return;
    initialized = true;

    if (config.enable_builtin_extension) {
        active_hooks = .{
            .score_install = builtinScoreInstall,
            .launch_args = builtinLaunchArgs,
            .session_init = null,
            .event_observer = null,
        };
    }
}

fn builtinScoreInstall(install: types.BrowserInstall) i32 {
    return switch (install.kind) {
        .chrome, .edge, .firefox, .safari => 5,
        .brave, .vivaldi, .arc => 3,
        else => 0,
    };
}

fn builtinLaunchArgs(
    allocator: std.mem.Allocator,
    options: types.LaunchOptions,
    current_args: []const []const u8,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    for (current_args) |arg| {
        try list.append(allocator, try allocator.dupe(u8, arg));
    }

    if (options.install.engine == .chromium) {
        try list.append(allocator, try allocator.dupe(u8, "--disable-backgrounding-occluded-windows"));
    }

    return list.toOwnedSlice(allocator);
}

test "registerHooks overrides scoreInstall behavior" {
    const install: types.BrowserInstall = .{
        .kind = .chrome,
        .engine = .chromium,
        .path = "x",
        .version = null,
        .source = .explicit,
    };

    const before = scoreInstall(install);
    registerHooks(.{
        .score_install = testScoreHook,
    });
    defer registerHooks(.{});

    try std.testing.expectEqual(@as(i32, 77), scoreInstall(install));
    try std.testing.expect(before != 77);
}

fn testScoreHook(_: types.BrowserInstall) i32 {
    return 77;
}
