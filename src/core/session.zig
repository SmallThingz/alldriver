const std = @import("std");
const types = @import("../types.zig");
const common = @import("../protocol/common.zig");
const actions = @import("actions.zig");
const network = @import("network.zig");
const storage = @import("storage.zig");
const artifacts = @import("artifacts.zig");
const async_mod = @import("async.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    id: u64,
    mode: common.SessionMode,
    transport: common.TransportKind,
    install: types.BrowserInstall,
    capability_set: types.CapabilitySet,
    adapter_kind: common.AdapterKind,
    endpoint: ?[]u8,
    current_url: ?[]u8 = null,
    browsing_context_id: ?[]u8 = null,
    request_id: u64 = 0,
    request_id_lock: std.Thread.Mutex = .{},

    child: ?std.process.Child = null,
    owned_argv: ?[]const []const u8 = null,
    ephemeral_profile_dir: ?[]u8 = null,

    rules: std.ArrayList(types.NetworkRule) = .empty,
    on_request: ?*const fn (types.RequestEvent) void = null,
    on_response: ?*const fn (types.ResponseEvent) void = null,

    pub fn deinit(self: *Session) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
        }

        if (self.current_url) |url| self.allocator.free(url);
        if (self.endpoint) |ep| self.allocator.free(ep);
        if (self.browsing_context_id) |ctx| self.allocator.free(ctx);

        if (self.owned_argv) |args| {
            for (args) |arg| self.allocator.free(arg);
            self.allocator.free(args);
        }

        if (self.ephemeral_profile_dir) |profile_dir| {
            std.fs.cwd().deleteTree(profile_dir) catch {};
            self.allocator.free(profile_dir);
        }

        for (self.rules.items) |rule| {
            self.allocator.free(rule.id);
            self.allocator.free(rule.url_pattern);
            freeInterceptAction(self.allocator, rule.action);
        }
        self.rules.deinit(self.allocator);

        self.allocator.free(self.install.path);
        if (self.install.version) |version| self.allocator.free(version);

        self.* = undefined;
    }

    pub fn capabilities(self: *const Session) types.CapabilitySet {
        return self.capability_set;
    }

    pub fn supports(self: *const Session, feature: types.CapabilityFeature) bool {
        return switch (feature) {
            .dom => self.capability_set.dom,
            .js_eval => self.capability_set.js_eval,
            .network_intercept => self.capability_set.network_intercept,
            .tracing => self.capability_set.tracing,
            .downloads => self.capability_set.downloads,
            .bidi_events => self.capability_set.bidi_events,
        };
    }

    pub fn nextRequestId(self: *Session) u64 {
        self.request_id_lock.lock();
        defer self.request_id_lock.unlock();
        self.request_id += 1;
        return self.request_id;
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

    pub fn waitForSelector(self: *Session, selector: []const u8, timeout_ms: u32) !void {
        try actions.waitForSelector(self, selector, timeout_ms);
    }

    pub fn enableNetworkInterception(self: *Session) !void {
        try network.enableInterception(self);
    }

    pub fn addInterceptRule(self: *Session, rule: types.NetworkRule) !void {
        try network.addInterceptRule(self, rule);
    }

    pub fn removeInterceptRule(self: *Session, rule_id: []const u8) !bool {
        return network.removeInterceptRule(self, rule_id);
    }

    pub fn clearInterceptRules(self: *Session) !void {
        try network.clearInterceptRules(self);
    }

    pub fn onRequest(self: *Session, callback: *const fn (types.RequestEvent) void) void {
        network.onRequest(self, callback);
    }

    pub fn onResponse(self: *Session, callback: *const fn (types.ResponseEvent) void) void {
        network.onResponse(self, callback);
    }

    pub fn setCookie(self: *Session, cookie: storage.Cookie) !void {
        try storage.setCookie(self, cookie);
    }

    pub fn screenshot(self: *Session, allocator: std.mem.Allocator, format: artifacts.ScreenshotFormat) ![]u8 {
        return artifacts.screenshot(self, allocator, format);
    }

    pub fn startTracing(self: *Session) !void {
        try artifacts.startTracing(self);
    }

    pub fn stopTracing(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        return artifacts.stopTracing(self, allocator);
    }

    pub fn navigateAsync(self: *Session, url: []const u8) !*async_mod.AsyncResult(void) {
        const Ctx = struct {
            session: *Session,
            url: []u8,
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{
            .session = self,
            .url = try self.allocator.dupe(u8, url),
        };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror!void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                try c.session.navigate(c.url);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.free(c.url);
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult(void).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }

    pub fn clickAsync(self: *Session, selector: []const u8) !*async_mod.AsyncResult(void) {
        const Ctx = struct {
            session: *Session,
            selector: []u8,
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{ .session = self, .selector = try self.allocator.dupe(u8, selector) };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror!void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                try c.session.click(c.selector);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.free(c.selector);
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult(void).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }

    pub fn typeTextAsync(self: *Session, selector: []const u8, text: []const u8) !*async_mod.AsyncResult(void) {
        const Ctx = struct {
            session: *Session,
            selector: []u8,
            text: []u8,
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{
            .session = self,
            .selector = try self.allocator.dupe(u8, selector),
            .text = try self.allocator.dupe(u8, text),
        };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror!void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                try c.session.typeText(c.selector, c.text);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.free(c.selector);
                a.free(c.text);
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult(void).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }

    pub fn evaluateAsync(self: *Session, script: []const u8) !*async_mod.AsyncResult([]u8) {
        const Ctx = struct {
            session: *Session,
            script: []u8,
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{ .session = self, .script = try self.allocator.dupe(u8, script) };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror![]u8 {
                const c: *Ctx = @ptrCast(@alignCast(p));
                return c.session.evaluate(c.script);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.free(c.script);
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult([]u8).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }

    pub fn waitForAsync(self: *Session, condition: actions.WaitCondition, timeout_ms: u32) !*async_mod.AsyncResult(void) {
        const Ctx = struct {
            session: *Session,
            condition: actions.WaitCondition,
            timeout_ms: u32,
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{ .session = self, .condition = condition, .timeout_ms = timeout_ms };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror!void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                try c.session.waitFor(c.condition, c.timeout_ms);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult(void).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }

    pub fn screenshotAsync(self: *Session, format: artifacts.ScreenshotFormat) !*async_mod.AsyncResult([]u8) {
        const Ctx = struct {
            session: *Session,
            format: artifacts.ScreenshotFormat,
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{ .session = self, .format = format };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror![]u8 {
                const c: *Ctx = @ptrCast(@alignCast(p));
                return c.session.screenshot(c.session.allocator, c.format);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult([]u8).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }

    pub fn startTracingAsync(self: *Session) !*async_mod.AsyncResult(void) {
        const Ctx = struct { session: *Session };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{ .session = self };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror!void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                try c.session.startTracing();
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult(void).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }

    pub fn stopTracingAsync(self: *Session) !*async_mod.AsyncResult([]u8) {
        const Ctx = struct { session: *Session };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{ .session = self };

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror![]u8 {
                const c: *Ctx = @ptrCast(@alignCast(p));
                return c.session.stopTracing(c.session.allocator);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                a.destroy(c);
            }
        };

        return async_mod.AsyncResult([]u8).spawn(self.allocator, ctx, Runner.run, Runner.destroy);
    }
};

fn freeInterceptAction(allocator: std.mem.Allocator, action: types.InterceptAction) void {
    switch (action) {
        .block, .continue_request => {},
        .fulfill => |f| {
            for (f.headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(f.headers);
            allocator.free(f.body);
        },
        .modify => |m| {
            for (m.add_headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(m.add_headers);
            for (m.remove_header_names) |name| allocator.free(name);
            allocator.free(m.remove_header_names);
        },
    }
}

pub fn nextSessionId() u64 {
    return @as(u64, @intCast(std.time.milliTimestamp()));
}
