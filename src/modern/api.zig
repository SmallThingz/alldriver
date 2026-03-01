const std = @import("std");
const types = @import("../types.zig");
const runtime = @import("runtime.zig");
const session_mod = @import("session.zig");
const lightpanda = @import("../provision/lightpanda.zig");
const async_mod = @import("../core/async.zig");
const logging = @import("../logging.zig");

pub const ModernInstall = types.BrowserInstall;
pub const ModernSession = session_mod.ModernSession;
pub const ModernWebViewRuntime = types.WebViewRuntime;
pub const HardErrorLog = logging.HardErrorLog;
pub const HardErrorLogger = logging.HardErrorLogger;

pub fn setHardErrorLogger(callback: ?*const HardErrorLogger) void {
    logging.setHardErrorLogger(callback);
}

pub fn discover(
    allocator: std.mem.Allocator,
    prefs: types.BrowserPreference,
    opts: types.DiscoveryOptions,
) !types.BrowserInstallList {
    return runtime.discover(allocator, prefs, opts);
}

pub fn launch(allocator: std.mem.Allocator, opts: types.LaunchOptions) !ModernSession {
    return runtime.launch(allocator, opts);
}

pub fn launchAsync(
    allocator: std.mem.Allocator,
    opts: types.LaunchOptions,
) !*async_mod.AsyncResult(ModernSession) {
    const Ctx = struct {
        opts: types.LaunchOptions,
    };
    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .opts = try cloneLaunchOptions(allocator, opts) };

    const Runner = struct {
        fn run(a: std.mem.Allocator, p: *anyopaque) anyerror!ModernSession {
            const c: *Ctx = @ptrCast(@alignCast(p));
            return runtime.launch(a, c.opts);
        }

        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(p));
            freeLaunchOptions(a, &c.opts);
            a.destroy(c);
        }
    };

    return async_mod.AsyncResult(ModernSession).spawn(allocator, ctx, Runner.run, Runner.destroy);
}

pub fn attach(allocator: std.mem.Allocator, endpoint: []const u8) !ModernSession {
    return runtime.attach(allocator, endpoint);
}

pub fn discoverWebViews(
    allocator: std.mem.Allocator,
    prefs: types.WebViewPreference,
) !types.WebViewRuntimeList {
    return runtime.discoverWebViews(allocator, prefs);
}

pub fn attachWebView(allocator: std.mem.Allocator, opts: types.WebViewAttachOptions) !ModernSession {
    return runtime.attachWebView(allocator, opts);
}

pub fn launchWebViewHost(allocator: std.mem.Allocator, opts: types.WebViewLaunchOptions) !ModernSession {
    return runtime.launchWebViewHost(allocator, opts);
}

pub fn attachAndroidWebView(
    allocator: std.mem.Allocator,
    opts: types.AndroidWebViewAttachOptions,
) !ModernSession {
    return runtime.attachAndroidWebView(allocator, opts);
}

pub fn attachElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewAttachOptions,
) !ModernSession {
    return runtime.attachElectronWebView(allocator, opts);
}

pub fn launchElectronWebView(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewLaunchOptions,
) !ModernSession {
    return runtime.launchElectronWebView(allocator, opts);
}

pub fn launchElectronWebViewAsync(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewLaunchOptions,
) !*async_mod.AsyncResult(ModernSession) {
    const Ctx = struct {
        opts: types.ElectronWebViewLaunchOptions,
    };
    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .opts = try cloneElectronLaunchOptions(allocator, opts) };

    const Runner = struct {
        fn run(a: std.mem.Allocator, p: *anyopaque) anyerror!ModernSession {
            const c: *Ctx = @ptrCast(@alignCast(p));
            return runtime.launchElectronWebView(a, c.opts);
        }

        fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
            const c: *Ctx = @ptrCast(@alignCast(p));
            freeElectronLaunchOptions(a, &c.opts);
            a.destroy(c);
        }
    };

    return async_mod.AsyncResult(ModernSession).spawn(allocator, ctx, Runner.run, Runner.destroy);
}

pub fn downloadLightpandaLatest(
    allocator: std.mem.Allocator,
    opts: lightpanda.DownloadOptions,
) ![]u8 {
    return lightpanda.downloadLatest(allocator, opts);
}

fn cloneLaunchOptions(allocator: std.mem.Allocator, opts: types.LaunchOptions) !types.LaunchOptions {
    var args = try allocator.alloc([]const u8, opts.args.len);
    var args_copied: usize = 0;
    errdefer {
        for (args[0..args_copied]) |arg| allocator.free(arg);
        allocator.free(args);
    }
    for (opts.args) |arg| {
        args[args_copied] = try allocator.dupe(u8, arg);
        args_copied += 1;
    }

    const install_path = try allocator.dupe(u8, opts.install.path);
    errdefer allocator.free(install_path);
    const install_version = if (opts.install.version) |version| try allocator.dupe(u8, version) else null;
    errdefer if (install_version) |version| allocator.free(version);
    const profile_dir = if (opts.profile_dir) |dir| try allocator.dupe(u8, dir) else null;
    errdefer if (profile_dir) |dir| allocator.free(dir);

    return .{
        .install = .{
            .kind = opts.install.kind,
            .engine = opts.install.engine,
            .path = install_path,
            .version = install_version,
            .source = opts.install.source,
        },
        .profile_mode = opts.profile_mode,
        .profile_dir = profile_dir,
        .headless = opts.headless,
        .ignore_tls_errors = opts.ignore_tls_errors,
        .include_lightpanda_browser = opts.include_lightpanda_browser,
        .gecko_stealth_prefs = opts.gecko_stealth_prefs,
        .timeout_policy = opts.timeout_policy,
        .args = args,
    };
}

fn freeLaunchOptions(allocator: std.mem.Allocator, opts: *types.LaunchOptions) void {
    allocator.free(opts.install.path);
    if (opts.install.version) |version| allocator.free(version);
    if (opts.profile_dir) |dir| allocator.free(dir);
    for (opts.args) |arg| allocator.free(arg);
    allocator.free(opts.args);
}

fn cloneElectronLaunchOptions(
    allocator: std.mem.Allocator,
    opts: types.ElectronWebViewLaunchOptions,
) !types.ElectronWebViewLaunchOptions {
    var args = try allocator.alloc([]const u8, opts.args.len);
    var args_copied: usize = 0;
    errdefer {
        for (args[0..args_copied]) |arg| allocator.free(arg);
        allocator.free(args);
    }
    for (opts.args) |arg| {
        args[args_copied] = try allocator.dupe(u8, arg);
        args_copied += 1;
    }

    const executable_path = try allocator.dupe(u8, opts.executable_path);
    errdefer allocator.free(executable_path);
    const app_path = if (opts.app_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (app_path) |path| allocator.free(path);
    const profile_dir = if (opts.profile_dir) |dir| try allocator.dupe(u8, dir) else null;
    errdefer if (profile_dir) |dir| allocator.free(dir);
    return .{
        .executable_path = executable_path,
        .app_path = app_path,
        .debug_port = opts.debug_port,
        .profile_mode = opts.profile_mode,
        .profile_dir = profile_dir,
        .headless = opts.headless,
        .ignore_tls_errors = opts.ignore_tls_errors,
        .args = args,
    };
}

fn freeElectronLaunchOptions(allocator: std.mem.Allocator, opts: *types.ElectronWebViewLaunchOptions) void {
    allocator.free(opts.executable_path);
    if (opts.app_path) |app_path| allocator.free(app_path);
    if (opts.profile_dir) |dir| allocator.free(dir);
    for (opts.args) |arg| allocator.free(arg);
    allocator.free(opts.args);
}

test "launchAsync propagates launch errors" {
    const allocator = std.testing.allocator;
    var op = try launchAsync(allocator, .{
        .install = .{
            .kind = .safari,
            .engine = .webkit,
            .path = "/bin/false",
            .version = null,
            .source = .explicit,
        },
        .profile_mode = .ephemeral,
        .headless = true,
        .args = &.{},
    });
    defer op.deinit();
    try std.testing.expectError(error.UnsupportedEngine, op.await(5_000));
}
