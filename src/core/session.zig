const std = @import("std");
const types = @import("../types.zig");
const common = @import("../protocol/common.zig");
const actions = @import("actions.zig");
const wait_mod = @import("wait.zig");
const network = @import("network.zig");
const storage = @import("storage.zig");
const artifacts = @import("artifacts.zig");
const events = @import("events.zig");
const cancel = @import("cancel.zig");
const async_mod = @import("async.zig");
const logging = @import("../logging.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    id: u64,
    mode: common.SessionMode,
    transport: common.TransportKind,
    install: types.BrowserInstall,
    capability_set: types.CapabilitySet,
    adapter_kind: common.AdapterKind,
    endpoint: ?[]u8,
    cdp_ws_endpoint: ?[]u8 = null,
    current_url: ?[]u8 = null,
    browsing_context_id: ?[]u8 = null,
    request_id: u64 = 0,
    request_id_lock: std.Thread.Mutex = .{},
    timeout_policy: types.TimeoutPolicy = .{},
    last_diagnostic_value: ?types.Diagnostic = null,

    child: ?std.process.Child = null,
    owned_argv: ?[]const []const u8 = null,
    ephemeral_profile_dir: ?[]u8 = null,

    rules: std.ArrayList(types.NetworkRule) = .empty,
    on_request: ?*const fn (types.RequestEvent) void = null,
    on_response: ?*const fn (types.ResponseEvent) void = null,
    event_subscriptions: std.ArrayList(events.EventSubscription) = .empty,
    next_event_subscription_id: u64 = 1,
    challenge_active: bool = false,

    pub fn deinit(self: *Session) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
        }

        if (self.current_url) |url| self.allocator.free(url);
        if (self.endpoint) |ep| self.allocator.free(ep);
        if (self.cdp_ws_endpoint) |ep| self.allocator.free(ep);
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

        events.clear(self);
        self.event_subscriptions.deinit(self.allocator);

        self.clearDiagnostic();

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
        events.emit(self, .{ .navigation_started = .{ .url = url } });
        const started = std.time.milliTimestamp();
        actions.navigate(self, url) catch |err| {
            self.recordDiagnostic(.{
                .phase = .navigate,
                .code = @errorName(err),
                .message = "navigation failed",
                .transport = @tagName(self.transport),
                .elapsed_ms = elapsedSince(started),
            });
            return err;
        };
        self.clearDiagnostic();
        const final_url = self.current_url orelse url;
        events.emit(self, .{ .navigation_completed = .{ .url = final_url } });
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
        const started = std.time.milliTimestamp();
        return actions.evaluate(self, script) catch |err| {
            self.recordDiagnostic(.{
                .phase = .overall,
                .code = @errorName(err),
                .message = "script evaluation failed",
                .transport = @tagName(self.transport),
                .elapsed_ms = elapsedSince(started),
            });
            return err;
        };
    }

    pub fn waitFor(self: *Session, target: types.WaitTarget, opts: types.WaitOptions) !types.WaitResult {
        return wait_mod.waitFor(self, target, opts);
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

    pub fn onEvent(
        self: *Session,
        filter: types.EventFilter,
        callback: *const fn (types.LifecycleEvent) void,
    ) !u64 {
        return events.register(self, filter, callback);
    }

    pub fn offEvent(self: *Session, id: u64) bool {
        return events.unregister(self, id);
    }

    pub fn setTimeoutPolicy(self: *Session, policy: types.TimeoutPolicy) void {
        self.timeout_policy = policy;
    }

    pub fn timeoutPolicy(self: *const Session) types.TimeoutPolicy {
        return self.timeout_policy;
    }

    pub fn lastDiagnostic(self: *const Session) ?types.Diagnostic {
        return self.last_diagnostic_value;
    }

    pub fn recordDiagnostic(self: *Session, diag: types.Diagnostic) void {
        self.clearDiagnostic();
        const code = self.allocator.dupe(u8, diag.code) catch return;
        errdefer self.allocator.free(code);
        const message = self.allocator.dupe(u8, diag.message) catch return;
        errdefer self.allocator.free(message);
        const transport = if (diag.transport) |t| self.allocator.dupe(u8, t) catch null else null;
        self.last_diagnostic_value = .{
            .phase = diag.phase,
            .code = code,
            .message = message,
            .transport = transport,
            .elapsed_ms = diag.elapsed_ms,
        };
        logging.emitHardError(.{
            .session_id = self.id,
            .phase = diag.phase,
            .code = diag.code,
            .message = diag.message,
            .transport = diag.transport,
        });
    }

    pub fn clearDiagnostic(self: *Session) void {
        if (self.last_diagnostic_value) |diag| {
            self.allocator.free(diag.code);
            self.allocator.free(diag.message);
            if (diag.transport) |transport| self.allocator.free(transport);
            self.last_diagnostic_value = null;
        }
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

    pub fn waitForAsync(
        self: *Session,
        target: types.WaitTarget,
        opts: types.WaitOptions,
    ) !*async_mod.AsyncResult(types.WaitResult) {
        const Ctx = struct {
            session: *Session,
            target: types.WaitTarget,
            opts: types.WaitOptions,
            owned_cancel_token: ?*cancel.CancelToken = null,
        };
        const ctx = try self.allocator.create(Ctx);
        ctx.* = .{
            .session = self,
            .target = try cloneWaitTarget(self.allocator, target),
            .opts = opts,
            .owned_cancel_token = null,
        };
        if (ctx.opts.cancel_token == null) {
            const token = try self.allocator.create(cancel.CancelToken);
            token.* = cancel.CancelToken.init();
            ctx.owned_cancel_token = token;
            ctx.opts.cancel_token = token;
        }

        const Runner = struct {
            fn run(_: std.mem.Allocator, p: *anyopaque) anyerror!types.WaitResult {
                const c: *Ctx = @ptrCast(@alignCast(p));
                return c.session.waitFor(c.target, c.opts);
            }
            fn destroy(a: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                freeWaitTarget(a, c.target);
                if (c.owned_cancel_token) |token| a.destroy(token);
                a.destroy(c);
            }
        };

        const Canceler = struct {
            fn call(_: std.mem.Allocator, p: *anyopaque) void {
                const c: *Ctx = @ptrCast(@alignCast(p));
                if (c.opts.cancel_token) |token| token.cancel();
            }
        };

        return async_mod.AsyncResult(types.WaitResult).spawnWithCancel(
            self.allocator,
            ctx,
            Runner.run,
            Runner.destroy,
            Canceler.call,
        );
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

fn cloneWaitTarget(allocator: std.mem.Allocator, target: types.WaitTarget) !types.WaitTarget {
    return switch (target) {
        .dom_ready => .{ .dom_ready = {} },
        .network_idle => .{ .network_idle = {} },
        .selector_visible => |selector| .{ .selector_visible = try allocator.dupe(u8, selector) },
        .url_contains => |needle| .{ .url_contains = try allocator.dupe(u8, needle) },
        .cookie_present => |query| .{ .cookie_present = .{
            .name = if (query.name) |name| try allocator.dupe(u8, name) else null,
            .domain = if (query.domain) |domain| try allocator.dupe(u8, domain) else null,
            .path = if (query.path) |path| try allocator.dupe(u8, path) else null,
            .secure_only = query.secure_only,
            .include_expired = query.include_expired,
            .include_http_only = query.include_http_only,
        } },
        .storage_key_present => |query| .{ .storage_key_present = .{
            .key = try allocator.dupe(u8, query.key),
            .area = query.area,
        } },
        .js_truthy => |script| .{ .js_truthy = try allocator.dupe(u8, script) },
    };
}

fn freeWaitTarget(allocator: std.mem.Allocator, target: types.WaitTarget) void {
    switch (target) {
        .dom_ready, .network_idle => {},
        .selector_visible => |selector| allocator.free(selector),
        .url_contains => |needle| allocator.free(needle),
        .cookie_present => |query| {
            if (query.name) |name| allocator.free(name);
            if (query.domain) |domain| allocator.free(domain);
            if (query.path) |path| allocator.free(path);
        },
        .storage_key_present => |query| allocator.free(query.key),
        .js_truthy => |script| allocator.free(script),
    }
}

fn elapsedSince(start_ms: i64) u32 {
    const delta = std.time.milliTimestamp() - start_ms;
    if (delta <= 0) return 0;
    return @intCast(delta);
}

pub fn nextSessionId() u64 {
    return @as(u64, @intCast(std.time.milliTimestamp()));
}
