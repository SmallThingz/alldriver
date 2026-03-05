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
const executor = @import("../protocol/executor.zig");
const logging = @import("../logging.zig");
const ws_client = @import("../transport/ws_client.zig");

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
    cdp_target_id: ?[]u8 = null,
    cdp_attached_session_id: ?[]u8 = null,
    cdp_client: ?ws_client.Client = null,
    current_url: ?[]u8 = null,
    state_lock: std.Thread.Mutex = .{},
    browsing_context_id: ?[]u8 = null,
    request_id: u64 = 0,
    request_id_lock: std.Thread.Mutex = .{},
    protocol_lock: std.Thread.Mutex = .{},
    timeout_policy: types.TimeoutPolicy = .{},
    last_diagnostic_value: ?types.Diagnostic = null,

    child: ?std.process.Child = null,
    owned_argv: ?[]const []const u8 = null,
    ephemeral_profile_dir: ?[]u8 = null,

    rules: std.ArrayList(types.NetworkRule) = .empty,
    on_request: ?*const fn (types.RequestEvent) void = null,
    on_response: ?*const fn (types.ResponseEvent) void = null,
    event_lock: std.Thread.Mutex = .{},
    event_subscriptions: std.ArrayList(events.EventSubscription) = .empty,
    next_event_subscription_id: u64 = 1,
    challenge_active: bool = false,
    challenge_lock: std.Thread.Mutex = .{},
    network_lock: std.Thread.Mutex = .{},
    network_records: std.ArrayList(types.NetworkRecord) = .empty,
    frames_lock: std.Thread.Mutex = .{},
    frames: std.ArrayList(types.FrameInfo) = .empty,
    service_workers_lock: std.Thread.Mutex = .{},
    service_workers: std.ArrayList(types.ServiceWorkerInfo) = .empty,
    snapshot_lock: std.Thread.Mutex = .{},
    snapshots: std.ArrayList(types.SnapshotBundle) = .empty,

    pub fn deinit(self: *Session) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
        }

        if (self.current_url) |url| self.allocator.free(url);
        if (self.endpoint) |ep| self.allocator.free(ep);
        if (self.cdp_ws_endpoint) |ep| self.allocator.free(ep);
        if (self.cdp_target_id) |target_id| self.allocator.free(target_id);
        if (self.cdp_attached_session_id) |attached| self.allocator.free(attached);
        if (self.cdp_client) |*client| client.deinit();
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
        network.deinitTelemetry(self);

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
        events.emit(self, .{ .navigation_started = .{ .url = url, .cause = .navigate } });
        capturePhaseSnapshotBestEffort(self, .navigation_started, url);
        const started = std.time.milliTimestamp();
        actions.navigate(self, url) catch |err| {
            self.recordDiagnostic(.{
                .phase = .navigate,
                .code = @errorName(err),
                .message = "navigation failed",
                .transport = @tagName(self.transport),
                .elapsed_ms = elapsedSince(started),
            });
            events.emit(self, .{
                .navigation_failed = .{
                    .url = url,
                    .error_code = @errorName(err),
                    .cause = .navigate,
                },
            });
            capturePhaseSnapshotBestEffort(self, .navigation_failed, url);
            return err;
        };
        try emitNavigationMilestones(self, url, .navigate);
        self.clearDiagnostic();
        events.emit(self, .{ .navigation_completed = .{ .url = url, .cause = .navigate } });
        capturePhaseSnapshotBestEffort(self, .navigation_completed, url);
    }

    pub fn reload(self: *Session) !void {
        const url = try currentUrlForLifecycle(self);
        defer self.allocator.free(url);
        events.emit(self, .{ .navigation_started = .{ .url = url, .cause = .reload } });
        events.emit(self, .{ .reload_started = .{ .url = url, .cause = .reload } });
        capturePhaseSnapshotBestEffort(self, .navigation_started, url);
        const started = std.time.milliTimestamp();
        actions.reload(self) catch |err| {
            self.recordDiagnostic(.{
                .phase = .navigate,
                .code = @errorName(err),
                .message = "reload failed",
                .transport = @tagName(self.transport),
                .elapsed_ms = elapsedSince(started),
            });
            events.emit(self, .{
                .reload_failed = .{
                    .url = url,
                    .error_code = @errorName(err),
                    .cause = .reload,
                },
            });
            events.emit(self, .{
                .navigation_failed = .{
                    .url = url,
                    .error_code = @errorName(err),
                    .cause = .reload,
                },
            });
            capturePhaseSnapshotBestEffort(self, .navigation_failed, url);
            return err;
        };
        try emitNavigationMilestones(self, url, .reload);
        self.clearDiagnostic();
        events.emit(self, .{ .reload_completed = .{ .url = url, .cause = .reload } });
        events.emit(self, .{ .navigation_completed = .{ .url = url, .cause = .reload } });
        capturePhaseSnapshotBestEffort(self, .navigation_completed, url);
    }

    pub fn click(self: *Session, selector: []const u8) !void {
        events.emit(self, .{ .action_started = .{ .kind = .click } });
        actions.click(self, selector) catch |err| {
            events.emit(self, .{
                .action_failed = .{
                    .kind = .click,
                    .error_code = @errorName(err),
                },
            });
            return err;
        };
        events.emit(self, .{ .action_completed = .{ .kind = .click } });
    }

    pub fn typeText(self: *Session, selector: []const u8, text: []const u8) !void {
        events.emit(self, .{ .action_started = .{ .kind = .type_text } });
        actions.typeText(self, selector, text) catch |err| {
            events.emit(self, .{
                .action_failed = .{
                    .kind = .type_text,
                    .error_code = @errorName(err),
                },
            });
            return err;
        };
        events.emit(self, .{ .action_completed = .{ .kind = .type_text } });
    }

    pub fn evaluate(self: *Session, script: []const u8) ![]u8 {
        const started = std.time.milliTimestamp();
        events.emit(self, .{ .action_started = .{ .kind = .evaluate } });
        const payload = actions.evaluate(self, script) catch |err| {
            self.recordDiagnostic(.{
                .phase = .overall,
                .code = @errorName(err),
                .message = "script evaluation failed",
                .transport = @tagName(self.transport),
                .elapsed_ms = elapsedSince(started),
            });
            events.emit(self, .{
                .action_failed = .{
                    .kind = .evaluate,
                    .error_code = @errorName(err),
                },
            });
            return err;
        };
        events.emit(self, .{ .action_completed = .{ .kind = .evaluate } });
        return payload;
    }

    pub fn waitFor(self: *Session, target: types.WaitTarget, opts: types.WaitOptions) !types.WaitResult {
        return wait_mod.waitFor(self, target, opts);
    }

    pub fn waitForCookie(self: *Session, query: types.CookieQuery, opts: types.WaitOptions) !types.WaitResult {
        return wait_mod.waitFor(self, .{ .cookie_present = query }, opts);
    }

    pub fn addInitScript(self: *Session, script: []const u8) ![]u8 {
        return executor.addInitScript(self, script);
    }

    pub fn removeInitScript(self: *Session, script_id: []const u8) !void {
        try executor.removeInitScript(self, script_id);
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

    pub fn emitNetworkRequestObserved(self: *Session, event: types.RequestEvent) void {
        network.emitRequestObserved(self, event);
    }

    pub fn emitNetworkResponseObserved(self: *Session, event: types.ResponseEvent) void {
        network.emitResponseObserved(self, event);
    }

    pub fn recordNetworkRedirect(
        self: *Session,
        request_id: []const u8,
        from_url: []const u8,
        to_url: []const u8,
        status: u16,
        at_ms: u64,
    ) void {
        network.recordRedirect(self, request_id, from_url, to_url, status, at_ms) catch {};
    }

    pub fn recordNetworkStatus(self: *Session, request_id: []const u8, status: u16, at_ms: u64) void {
        network.recordStatus(self, request_id, status, at_ms) catch {};
    }

    pub fn upsertFrameInfo(self: *Session, frame: types.FrameInfo) void {
        network.upsertFrameInfo(self, frame) catch {};
    }

    pub fn removeFrameInfo(self: *Session, frame_id: []const u8) void {
        network.removeFrameInfo(self, frame_id);
    }

    pub fn upsertServiceWorkerInfo(self: *Session, worker: types.ServiceWorkerInfo) void {
        network.upsertServiceWorkerInfo(self, worker) catch {};
    }

    pub fn removeServiceWorkerInfo(self: *Session, worker_id: []const u8) void {
        network.removeServiceWorkerInfo(self, worker_id);
    }

    pub fn networkRecords(self: *Session, allocator: std.mem.Allocator, include_bodies: bool) ![]types.NetworkRecord {
        return network.listNetworkRecords(self, allocator, include_bodies);
    }

    pub fn freeNetworkRecords(_: *Session, allocator: std.mem.Allocator, records: []types.NetworkRecord) void {
        network.freeNetworkRecords(allocator, records);
    }

    pub fn clearNetworkRecords(self: *Session) void {
        network.clearNetworkRecords(self);
    }

    pub fn frameInfos(self: *Session, allocator: std.mem.Allocator) ![]types.FrameInfo {
        return network.listFrames(self, allocator);
    }

    pub fn freeFrameInfos(_: *Session, allocator: std.mem.Allocator, frames: []types.FrameInfo) void {
        network.freeFrames(allocator, frames);
    }

    pub fn serviceWorkerInfos(self: *Session, allocator: std.mem.Allocator) ![]types.ServiceWorkerInfo {
        return network.listServiceWorkers(self, allocator);
    }

    pub fn freeServiceWorkerInfos(_: *Session, allocator: std.mem.Allocator, workers: []types.ServiceWorkerInfo) void {
        network.freeServiceWorkers(allocator, workers);
    }

    pub fn captureSnapshot(
        self: *Session,
        allocator: std.mem.Allocator,
        phase: types.SnapshotPhase,
        url_override: ?[]const u8,
    ) !types.SnapshotBundle {
        return network.captureSnapshot(self, allocator, phase, url_override);
    }

    pub fn freeSnapshot(self: *Session, allocator: std.mem.Allocator, bundle: *types.SnapshotBundle) void {
        _ = self;
        network.freeSnapshot(allocator, bundle);
    }

    pub fn navigationSnapshots(self: *Session, allocator: std.mem.Allocator) ![]types.SnapshotBundle {
        return network.listNavigationSnapshots(self, allocator);
    }

    pub fn freeNavigationSnapshots(_: *Session, allocator: std.mem.Allocator, bundles: []types.SnapshotBundle) void {
        network.freeSnapshots(allocator, bundles);
    }

    pub fn clearNavigationSnapshots(self: *Session) void {
        network.clearNavigationSnapshots(self);
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

    pub fn waitForCookieAsync(
        self: *Session,
        query: types.CookieQuery,
        opts: types.WaitOptions,
    ) !*async_mod.AsyncResult(types.WaitResult) {
        return self.waitForAsync(.{ .cookie_present = query }, opts);
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

fn currentUrlForLifecycle(self: *Session) ![]u8 {
    self.state_lock.lock();
    defer self.state_lock.unlock();
    if (self.current_url) |url| return self.allocator.dupe(u8, url);
    return self.allocator.dupe(u8, "");
}

fn emitNavigationMilestones(self: *Session, url: []const u8, cause: types.NavigationCause) !void {
    const timeout_ms = self.timeout_policy.navigate_ms;
    const response_observed = waitForResponseReceivedMilestone(self, timeout_ms);
    const response_status = network.lastResponseStatusForUrl(self, url);
    events.emit(self, .{
        .response_received = .{
            .url = url,
            .cause = cause,
            .status = response_status,
            .observed = response_observed,
        },
    });
    capturePhaseSnapshotBestEffort(self, .response_received, url);

    const dom_ready_observed = waitForDomReadyMilestone(self, timeout_ms);
    events.emit(self, .{
        .dom_ready = .{
            .url = url,
            .cause = cause,
            .observed = dom_ready_observed,
        },
    });
    capturePhaseSnapshotBestEffort(self, .dom_ready, url);

    const scripts_settled_observed = waitForScriptsSettledMilestone(self, timeout_ms);
    events.emit(self, .{
        .scripts_settled = .{
            .url = url,
            .cause = cause,
            .observed = scripts_settled_observed,
        },
    });
    capturePhaseSnapshotBestEffort(self, .scripts_settled, url);
}

fn capturePhaseSnapshotBestEffort(self: *Session, phase: types.SnapshotPhase, url: []const u8) void {
    var bundle = network.captureSnapshot(self, self.allocator, phase, url) catch return;
    network.appendNavigationSnapshot(self, bundle) catch {
        network.freeSnapshot(self.allocator, &bundle);
        return;
    };
}

fn waitForResponseReceivedMilestone(self: *Session, timeout_ms: u32) bool {
    if (!self.supports(.js_eval)) return false;
    const max_wait_ms: u32 = @min(timeout_ms, 5_000);
    const start = std.time.milliTimestamp();
    while (elapsedSince(start) < max_wait_ms) {
        const payload = executor.evaluate(
            self,
            "(function(){const n=performance.getEntriesByType('navigation'); if(!n||n.length===0) return false; const e=n[n.length-1]; return !!(e.responseStart && e.responseStart>0);})();",
        ) catch return false;
        defer self.allocator.free(payload);
        if (std.mem.indexOf(u8, payload, "true") != null) return true;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return false;
}

fn waitForDomReadyMilestone(self: *Session, timeout_ms: u32) bool {
    if (!self.supports(.js_eval)) return false;
    const max_wait_ms: u32 = @min(timeout_ms, 10_000);
    executor.waitForDomReady(self, max_wait_ms) catch return false;
    return true;
}

fn waitForScriptsSettledMilestone(self: *Session, timeout_ms: u32) bool {
    if (!self.supports(.js_eval)) return false;
    const max_wait_ms: u32 = @min(timeout_ms, 10_000);
    const start = std.time.milliTimestamp();
    while (elapsedSince(start) < max_wait_ms) {
        const payload = executor.evaluate(
            self,
            "(function(){const ready=document.readyState==='complete'; const noReq=(!window.__webdriver_active_requests||window.__webdriver_active_requests===0); return ready && noReq;})();",
        ) catch return false;
        defer self.allocator.free(payload);
        if (std.mem.indexOf(u8, payload, "true") != null) return true;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return false;
}

pub fn nextSessionId() u64 {
    return @as(u64, @intCast(std.time.milliTimestamp()));
}

fn makeTestSession(allocator: std.mem.Allocator, capabilities: types.CapabilitySet) !Session {
    return .{
        .allocator = allocator,
        .id = 42,
        .mode = .browser,
        .transport = .cdp_ws,
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, "test-browser"),
            .version = null,
            .source = .explicit,
        },
        .capability_set = capabilities,
        .adapter_kind = .cdp,
        .endpoint = null,
        .browsing_context_id = null,
    };
}

const SessionEventCapture = struct {
    navigation_started: usize = 0,
    navigation_completed: usize = 0,
    navigation_failed: usize = 0,
    reload_started: usize = 0,
    reload_completed: usize = 0,
    reload_failed: usize = 0,
    wait_started: usize = 0,
    wait_satisfied: usize = 0,
    wait_timeout: usize = 0,
    wait_canceled: usize = 0,
    wait_failed: usize = 0,
    action_started: usize = 0,
    action_completed: usize = 0,
    action_failed: usize = 0,
    response_received: usize = 0,
    dom_ready: usize = 0,
    scripts_settled: usize = 0,
    cookie_updated: usize = 0,
    last_started_url: ?[]const u8 = null,
    last_navigation_started_cause: ?types.NavigationCause = null,
    last_navigation_completed_cause: ?types.NavigationCause = null,
    last_navigation_failed_error: ?[]const u8 = null,
    last_navigation_failed_cause: ?types.NavigationCause = null,
    reload_url_buf: [512]u8 = [_]u8{0} ** 512,
    last_reload_url: ?[]const u8 = null,
    last_reload_failed_error: ?[]const u8 = null,
    last_wait_target: ?types.WaitTargetTag = null,
    last_wait_failed_error: ?[]const u8 = null,
    last_action_started_kind: ?types.ActionKind = null,
    last_action_failed_kind: ?types.ActionKind = null,
    last_action_failed_error: ?[]const u8 = null,
};

var session_event_capture: SessionEventCapture = .{};

fn resetSessionEventCapture() void {
    session_event_capture = .{};
}

fn captureSessionEvent(event: types.LifecycleEvent) void {
    switch (event) {
        .navigation_started => |e| {
            session_event_capture.navigation_started += 1;
            session_event_capture.last_started_url = e.url;
            session_event_capture.last_navigation_started_cause = e.cause;
        },
        .navigation_completed => |e| {
            session_event_capture.navigation_completed += 1;
            session_event_capture.last_navigation_completed_cause = e.cause;
        },
        .navigation_failed => |e| {
            session_event_capture.navigation_failed += 1;
            session_event_capture.last_navigation_failed_error = e.error_code;
            session_event_capture.last_navigation_failed_cause = e.cause;
        },
        .reload_started => |e| {
            session_event_capture.reload_started += 1;
            const copy_len = @min(e.url.len, session_event_capture.reload_url_buf.len);
            @memcpy(session_event_capture.reload_url_buf[0..copy_len], e.url[0..copy_len]);
            session_event_capture.last_reload_url = session_event_capture.reload_url_buf[0..copy_len];
        },
        .reload_completed => session_event_capture.reload_completed += 1,
        .reload_failed => |e| {
            session_event_capture.reload_failed += 1;
            const copy_len = @min(e.url.len, session_event_capture.reload_url_buf.len);
            @memcpy(session_event_capture.reload_url_buf[0..copy_len], e.url[0..copy_len]);
            session_event_capture.last_reload_url = session_event_capture.reload_url_buf[0..copy_len];
            session_event_capture.last_reload_failed_error = e.error_code;
        },
        .wait_started => |e| {
            session_event_capture.wait_started += 1;
            session_event_capture.last_wait_target = e.target;
        },
        .wait_satisfied => |e| {
            session_event_capture.wait_satisfied += 1;
            session_event_capture.last_wait_target = e.target;
        },
        .wait_timeout => |e| {
            session_event_capture.wait_timeout += 1;
            session_event_capture.last_wait_target = e.target;
        },
        .wait_canceled => |e| {
            session_event_capture.wait_canceled += 1;
            session_event_capture.last_wait_target = e.target;
        },
        .wait_failed => |e| {
            session_event_capture.wait_failed += 1;
            session_event_capture.last_wait_target = e.target;
            session_event_capture.last_wait_failed_error = e.error_code;
        },
        .action_started => |e| {
            session_event_capture.action_started += 1;
            session_event_capture.last_action_started_kind = e.kind;
        },
        .action_completed => session_event_capture.action_completed += 1,
        .action_failed => |e| {
            session_event_capture.action_failed += 1;
            session_event_capture.last_action_failed_kind = e.kind;
            session_event_capture.last_action_failed_error = e.error_code;
        },
        .response_received => session_event_capture.response_received += 1,
        .dom_ready => session_event_capture.dom_ready += 1,
        .scripts_settled => session_event_capture.scripts_settled += 1,
        .cookie_updated => session_event_capture.cookie_updated += 1,
        else => {},
    }
}

test "emitNavigationMilestones emits deterministic milestone events and stores snapshots" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = false,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{ .response_received, .dom_ready, .scripts_settled } },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try emitNavigationMilestones(&session, "https://example.com/path", .navigate);

    try std.testing.expectEqual(@as(usize, 1), session_event_capture.response_received);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.dom_ready);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.scripts_settled);

    const snapshots = try session.navigationSnapshots(allocator);
    defer session.freeNavigationSnapshots(allocator, snapshots);
    try std.testing.expectEqual(@as(usize, 3), snapshots.len);
    try std.testing.expectEqual(types.SnapshotPhase.response_received, snapshots[0].phase);
    try std.testing.expectEqual(types.SnapshotPhase.dom_ready, snapshots[1].phase);
    try std.testing.expectEqual(types.SnapshotPhase.scripts_settled, snapshots[2].phase);
}

test "navigate failure emits navigation_started without completion and records diagnostic" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = false,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{ .navigation_started, .navigation_completed, .navigation_failed } },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(
        error.UnsupportedCapability,
        session.navigate("https://api.example.com/fail"),
    );

    try std.testing.expectEqual(@as(usize, 1), session_event_capture.navigation_started);
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.navigation_completed);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.navigation_failed);
    try std.testing.expectEqualStrings(
        "https://api.example.com/fail",
        session_event_capture.last_started_url.?,
    );
    try std.testing.expectEqualStrings(
        "UnsupportedCapability",
        session_event_capture.last_navigation_failed_error.?,
    );
    try std.testing.expectEqual(types.NavigationCause.navigate, session_event_capture.last_navigation_started_cause.?);
    try std.testing.expectEqual(types.NavigationCause.navigate, session_event_capture.last_navigation_failed_cause.?);

    const diag = session.lastDiagnostic() orelse return error.TestExpectedDiagnostic;
    try std.testing.expectEqual(types.TimeoutPhase.navigate, diag.phase);
    try std.testing.expectEqualStrings("UnsupportedCapability", diag.code);
    try std.testing.expectEqualStrings("navigation failed", diag.message);
    try std.testing.expectEqualStrings("cdp_ws", diag.transport.?);
}

test "navigate failure still honors domain filter for navigation_started hooks" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = false,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{
            .domain = "example.com",
            .kinds = &.{.navigation_started},
        },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(
        error.UnsupportedCapability,
        session.navigate("https://api.example.com/fail"),
    );
    try std.testing.expectError(
        error.UnsupportedCapability,
        session.navigate("https://outside.test/fail"),
    );

    try std.testing.expectEqual(@as(usize, 1), session_event_capture.navigation_started);
    try std.testing.expectEqualStrings(
        "https://api.example.com/fail",
        session_event_capture.last_started_url.?,
    );
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.navigation_failed);
}

test "reload failure emits reload_started and reload_failed hooks" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = false,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    session.current_url = try allocator.dupe(u8, "https://example.com/origin");

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{ .reload_started, .reload_completed, .reload_failed } },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(error.UnsupportedCapability, session.reload());

    try std.testing.expectEqual(@as(usize, 1), session_event_capture.reload_started);
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.reload_completed);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.reload_failed);
    try std.testing.expectEqualStrings("https://example.com/origin", session_event_capture.last_reload_url.?);
    try std.testing.expectEqualStrings("UnsupportedCapability", session_event_capture.last_reload_failed_error.?);
}

test "reload failure emits navigation hooks with reload cause" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = false,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    session.current_url = try allocator.dupe(u8, "https://example.com/origin");

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{ .navigation_started, .navigation_failed } },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(error.UnsupportedCapability, session.reload());

    try std.testing.expectEqual(@as(usize, 1), session_event_capture.navigation_started);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.navigation_failed);
    try std.testing.expectEqual(types.NavigationCause.reload, session_event_capture.last_navigation_started_cause.?);
    try std.testing.expectEqual(types.NavigationCause.reload, session_event_capture.last_navigation_failed_cause.?);
}

test "click failure emits action_started and action_failed hooks" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = false,
        .js_eval = true,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{ .action_started, .action_completed, .action_failed } },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(error.UnsupportedCapability, session.click("#submit"));
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.action_started);
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.action_completed);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.action_failed);
    try std.testing.expectEqual(types.ActionKind.click, session_event_capture.last_action_started_kind.?);
    try std.testing.expectEqual(types.ActionKind.click, session_event_capture.last_action_failed_kind.?);
    try std.testing.expectEqualStrings("UnsupportedCapability", session_event_capture.last_action_failed_error.?);
}

test "evaluate failure emits action_failed and records diagnostic" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = true,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{ .action_started, .action_completed, .action_failed } },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(error.UnsupportedCapability, session.evaluate("1+1"));
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.action_started);
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.action_completed);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.action_failed);
    try std.testing.expectEqual(types.ActionKind.evaluate, session_event_capture.last_action_started_kind.?);
    try std.testing.expectEqual(types.ActionKind.evaluate, session_event_capture.last_action_failed_kind.?);
    try std.testing.expectEqualStrings("UnsupportedCapability", session_event_capture.last_action_failed_error.?);

    const diag = session.lastDiagnostic() orelse return error.TestExpectedDiagnostic;
    try std.testing.expectEqual(types.TimeoutPhase.overall, diag.phase);
    try std.testing.expectEqualStrings("UnsupportedCapability", diag.code);
    try std.testing.expectEqualStrings("script evaluation failed", diag.message);
}

test "wait failure emits wait_started and wait_failed hooks" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = true,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{ .wait_started, .wait_satisfied, .wait_timeout, .wait_canceled, .wait_failed } },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(
        error.UnsupportedCapability,
        session.waitFor(.{ .js_truthy = "true" }, .{ .timeout_ms = 1000, .poll_interval_ms = 10 }),
    );

    try std.testing.expectEqual(@as(usize, 1), session_event_capture.wait_started);
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.wait_satisfied);
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.wait_timeout);
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.wait_canceled);
    try std.testing.expectEqual(@as(usize, 1), session_event_capture.wait_failed);
    try std.testing.expectEqual(types.WaitTargetTag.js_truthy, session_event_capture.last_wait_target.?);
    try std.testing.expectEqualStrings("UnsupportedCapability", session_event_capture.last_wait_failed_error.?);
}

test "setCookie failure does not emit cookie_updated hook" {
    const allocator = std.testing.allocator;
    var session = try makeTestSession(allocator, .{
        .dom = false,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    });
    defer session.deinit();

    resetSessionEventCapture();
    const subscription_id = try session.onEvent(
        .{ .kinds = &.{.cookie_updated} },
        captureSessionEvent,
    );
    defer _ = session.offEvent(subscription_id);

    try std.testing.expectError(
        error.UnsupportedCapability,
        session.setCookie(.{
            .name = "sid",
            .value = "abc",
            .domain = "example.com",
            .path = "/",
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), session_event_capture.cookie_updated);
}
