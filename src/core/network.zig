const std = @import("std");
const Session = @import("session.zig").Session;
const types = @import("../types.zig");
const executor = @import("../protocol/executor.zig");
const json_util = @import("../util/json.zig");
const events = @import("events.zig");
const compat = @import("../util/compat.zig");

pub const NetworkRule = types.NetworkRule;
pub const InterceptAction = types.InterceptAction;
pub const RequestEvent = types.RequestEvent;
pub const ResponseEvent = types.ResponseEvent;

pub fn enableInterception(session: *Session) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    _ = try ensureObserver(session);
    try executor.enableNetworkInterception(session);
}

pub fn disableInterception(session: *Session) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    try clearInterceptRules(session);
    stopObserver(session);
}

pub fn addInterceptRule(session: *Session, rule: NetworkRule) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;

    const owned = try cloneRule(session.allocator, rule);
    errdefer freeRule(session.allocator, owned);

    try session.rules.ensureUnusedCapacity(session.allocator, 1);
    try executor.addNetworkRule(session, owned);
    session.rules.appendAssumeCapacity(owned);
}

pub fn removeInterceptRule(session: *Session, rule_id: []const u8) !bool {
    var i: usize = 0;
    while (i < session.rules.items.len) : (i += 1) {
        if (std.mem.eql(u8, session.rules.items[i].id, rule_id)) {
            const removed = session.rules.orderedRemove(i);
            errdefer session.rules.insertAssumeCapacity(i, removed);
            try syncRemoteRules(session);
            freeRule(session.allocator, removed);
            return true;
        }
    }
    return false;
}

pub fn clearInterceptRules(session: *Session) !void {
    if (session.supports(.network_intercept)) {
        executor.disableNetworkInterception(session) catch |err| switch (err) {
            error.UnsupportedProtocol => {},
            else => return err,
        };
    }

    while (session.rules.items.len > 0) {
        const rule = session.rules.pop().?;
        freeRule(session.allocator, rule);
    }
}

/// Registration is pending until enableInterception or subscribe succeeds.
pub fn onRequest(session: *Session, callback: *const fn (RequestEvent) void) void {
    session.network_observer_lock.lock();
    defer session.network_observer_lock.unlock();
    session.on_request = callback;
    if (session.network_observer) |observer| observer.setRequest(callback);
}

pub fn onResponse(session: *Session, callback: *const fn (ResponseEvent) void) void {
    session.network_observer_lock.lock();
    defer session.network_observer_lock.unlock();
    session.on_response = callback;
    if (session.network_observer) |observer| observer.setResponse(callback);
}

pub fn clearRequest(session: *Session) void {
    session.network_observer_lock.lock();
    defer session.network_observer_lock.unlock();
    session.on_request = null;
    if (session.network_observer) |observer| observer.setRequest(null);
}

pub fn clearResponse(session: *Session) void {
    session.network_observer_lock.lock();
    defer session.network_observer_lock.unlock();
    session.on_response = null;
    if (session.network_observer) |observer| observer.setResponse(null);
}

pub fn subscribe(session: *Session, callback: *const fn (event_json: []const u8) void) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    const observer = try ensureObserver(session);
    session.network_observer_lock.lock();
    defer session.network_observer_lock.unlock();
    session.on_network_raw = callback;
    observer.setRaw(callback);
}

pub fn unsubscribe(session: *Session) void {
    session.network_observer_lock.lock();
    defer session.network_observer_lock.unlock();
    session.on_network_raw = null;
    if (session.network_observer) |observer| observer.setRaw(null);
}

pub fn ensureObserver(session: *Session) !*@import("network_observer.zig").Observer {
    // Resolve outside the observer lock: protocol notifications may call back
    // into this module while the page endpoint is being discovered.
    const endpoint = try executor.pageWebSocketEndpoint(session);
    defer session.allocator.free(endpoint);
    session.network_observer_lock.lock();
    defer session.network_observer_lock.unlock();
    if (session.network_observer) |observer| {
        try observer.check();
        return observer;
    }
    const observer = try @import("network_observer.zig").Observer.create(session.allocator, endpoint, .{
        .request = session.on_request,
        .response = session.on_response,
        .raw = session.on_network_raw,
    });
    session.network_observer = observer;
    return observer;
}

pub fn stopObserver(session: *Session) void {
    session.network_observer_lock.lock();
    const observer = session.network_observer;
    session.network_observer = null;
    session.network_observer_lock.unlock();
    if (observer) |worker| worker.destroy();
}

pub fn emitDebugEvent(session: *Session, event_json: []const u8) void {
    emitRequestObserved(session, .{
        .request_id = "debug",
        .method = "DEBUG",
        .url = event_json,
        .headers_json = "{}",
    });
}

/// Lifecycle hooks here are dispatched as command RPCs drain CDP notifications.
/// Use onRequest/onResponse or subscribe with enable for idle push delivery.
pub fn emitRequestObserved(session: *Session, event: RequestEvent) void {
    upsertNetworkRecordFromRequest(session, event) catch {};
    session.network_observer_lock.lock();
    const callback = if (session.network_observer == null) session.on_request else null;
    session.network_observer_lock.unlock();
    if (callback) |cb| cb(event);
    events.emit(session, .{
        .network_request_observed = .{
            .request_id = event.request_id,
            .method = event.method,
            .url = event.url,
            .headers_json = event.headers_json,
        },
    });
}

pub fn emitResponseObserved(session: *Session, event: ResponseEvent) void {
    upsertNetworkRecordFromResponse(session, event) catch {};
    session.network_observer_lock.lock();
    const callback = if (session.network_observer == null) session.on_response else null;
    session.network_observer_lock.unlock();
    if (callback) |cb| cb(event);
    events.emit(session, .{
        .network_response_observed = .{
            .request_id = event.request_id,
            .status = event.status,
            .url = event.url,
            .headers_json = event.headers_json,
        },
    });
}

pub fn recordRedirect(session: *Session, request_id: []const u8, from_url: []const u8, to_url: []const u8, status: u16, at_ms: u64) !void {
    const redirect = try cloneOwned(types.RedirectHop, session.allocator, .{ .from_url = from_url, .to_url = to_url, .status = status, .at_ms = at_ms });
    errdefer freeOwned(types.RedirectHop, session.allocator, redirect);
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = try ensureNetworkRecordLocked(session, request_id);
    const record = &session.network_records.items[index];
    const grown = try session.allocator.alloc(types.RedirectHop, record.redirects.len + 1);
    errdefer session.allocator.free(grown);
    @memcpy(grown[0..record.redirects.len], record.redirects);
    grown[record.redirects.len] = redirect;
    try appendStatusPointLocked(session, record, status, at_ms);
    session.allocator.free(record.redirects);
    record.redirects = grown;
    record.final_status = status;
}

pub fn recordStatus(session: *Session, request_id: []const u8, status: u16, at_ms: u64) !void {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = try ensureNetworkRecordLocked(session, request_id);
    var record = &session.network_records.items[index];
    try appendStatusPointLocked(session, record, status, at_ms);
    record.final_status = status;
}

pub fn lastResponseStatusForUrl(session: *Session, url: []const u8) ?u16 {
    session.network_lock.lock();
    defer session.network_lock.unlock();

    var i: usize = session.network_records.items.len;
    while (i > 0) {
        i -= 1;
        const record = session.network_records.items[i];
        if (std.mem.eql(u8, record.url, url)) {
            if (record.final_status) |status| return status;
            if (record.status_timeline.len > 0) {
                return record.status_timeline[record.status_timeline.len - 1].status;
            }
        }
        var j: usize = record.redirects.len;
        while (j > 0) {
            j -= 1;
            const hop = record.redirects[j];
            if (std.mem.eql(u8, hop.to_url, url) or std.mem.eql(u8, hop.from_url, url)) {
                if (record.final_status) |status| return status;
                return hop.status;
            }
        }
    }
    return null;
}

pub fn upsertFrameInfo(session: *Session, frame: types.FrameInfo) !void {
    var owned = try cloneOwned(types.FrameInfo, session.allocator, frame);
    errdefer freeFrameInfo(session.allocator, &owned);
    session.frames_lock.lock();
    defer session.frames_lock.unlock();
    for (session.frames.items) |*existing| {
        if (!std.mem.eql(u8, existing.frame_id, frame.frame_id)) continue;
        freeFrameInfo(session.allocator, existing);
        existing.* = owned;
        return;
    }
    try session.frames.append(session.allocator, owned);
}

pub fn removeFrameInfo(session: *Session, frame_id: []const u8) void {
    session.frames_lock.lock();
    defer session.frames_lock.unlock();
    var i: usize = 0;
    while (i < session.frames.items.len) : (i += 1) {
        if (!std.mem.eql(u8, session.frames.items[i].frame_id, frame_id)) continue;
        var removed = session.frames.swapRemove(i);
        freeFrameInfo(session.allocator, &removed);
        return;
    }
}

pub fn upsertServiceWorkerInfo(session: *Session, worker: types.ServiceWorkerInfo) !void {
    var owned = try cloneOwned(types.ServiceWorkerInfo, session.allocator, worker);
    errdefer freeServiceWorkerInfo(session.allocator, &owned);
    session.service_workers_lock.lock();
    defer session.service_workers_lock.unlock();
    for (session.service_workers.items) |*existing| {
        if (!std.mem.eql(u8, existing.worker_id, worker.worker_id)) continue;
        freeServiceWorkerInfo(session.allocator, existing);
        existing.* = owned;
        return;
    }
    try session.service_workers.append(session.allocator, owned);
}

pub fn removeServiceWorkerInfo(session: *Session, worker_id: []const u8) void {
    session.service_workers_lock.lock();
    defer session.service_workers_lock.unlock();
    var i: usize = 0;
    while (i < session.service_workers.items.len) : (i += 1) {
        if (!std.mem.eql(u8, session.service_workers.items[i].worker_id, worker_id)) continue;
        var removed = session.service_workers.swapRemove(i);
        freeServiceWorkerInfo(session.allocator, &removed);
        return;
    }
}

pub fn listNetworkRecords(
    session: *Session,
    allocator: std.mem.Allocator,
    include_bodies: bool,
) ![]types.NetworkRecord {
    const out = blk: {
        session.network_lock.lock();
        defer session.network_lock.unlock();

        var copied_out = try allocator.alloc(types.NetworkRecord, session.network_records.items.len);
        var copied_count: usize = 0;
        errdefer {
            for (copied_out[0..copied_count]) |*record| freeNetworkRecord(allocator, record);
            allocator.free(copied_out);
        }
        for (session.network_records.items, 0..) |record, idx| {
            copied_out[idx] = try cloneNetworkRecord(allocator, record, include_bodies);
            copied_count = idx + 1;
        }
        break :blk copied_out;
    };

    errdefer freeNetworkRecords(allocator, out);
    if (!include_bodies or session.transport != .cdp_ws) return out;

    for (out) |*record| {
        if (record.response_body != null) continue;
        const fetched_opt = executor.getResponseBody(session, record.request_id) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (fetched_opt) |fetched| {
            defer session.allocator.free(fetched);
            record.response_body = try allocator.dupe(u8, fetched);
            cacheResponseBody(session, record.request_id, fetched) catch {};
        }
    }
    return out;
}

pub fn freeNetworkRecords(allocator: std.mem.Allocator, records: []types.NetworkRecord) void {
    for (records) |*record| freeNetworkRecord(allocator, record);
    allocator.free(records);
}

pub fn clearNetworkRecords(session: *Session) void {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    while (session.network_records.items.len > 0) {
        var record = session.network_records.pop().?;
        freeNetworkRecord(session.allocator, &record);
    }
}

pub fn listFrames(session: *Session, allocator: std.mem.Allocator) ![]types.FrameInfo {
    session.frames_lock.lock();
    defer session.frames_lock.unlock();
    return cloneOwned([]types.FrameInfo, allocator, session.frames.items);
}

pub fn freeFrames(allocator: std.mem.Allocator, frames: []types.FrameInfo) void {
    for (frames) |*frame| freeFrameInfo(allocator, frame);
    allocator.free(frames);
}

pub fn listServiceWorkers(session: *Session, allocator: std.mem.Allocator) ![]types.ServiceWorkerInfo {
    session.service_workers_lock.lock();
    defer session.service_workers_lock.unlock();
    return cloneOwned([]types.ServiceWorkerInfo, allocator, session.service_workers.items);
}

pub fn freeServiceWorkers(allocator: std.mem.Allocator, workers: []types.ServiceWorkerInfo) void {
    for (workers) |*worker| freeServiceWorkerInfo(allocator, worker);
    allocator.free(workers);
}

pub fn captureSnapshot(
    session: *Session,
    allocator: std.mem.Allocator,
    phase: types.SnapshotPhase,
    url_override: ?[]const u8,
) !types.SnapshotBundle {
    const url = if (url_override) |override|
        try allocator.dupe(u8, override)
    else
        try snapshotCurrentUrl(session, allocator);
    errdefer allocator.free(url);

    const dom_html = captureDomHtml(session, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try allocator.dupe(u8, ""),
    };
    errdefer allocator.free(dom_html);

    const response_headers_json = try snapshotHeadersForUrl(session, allocator, url);
    errdefer allocator.free(response_headers_json);

    const cookies = captureCookies(session, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try allocator.alloc(types.Cookie, 0),
    };
    errdefer freeCookies(allocator, cookies);

    const local_storage = captureStorageArea(session, allocator, "localStorage") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try allocator.alloc(types.StorageValue, 0),
    };
    errdefer freeStorageValues(allocator, local_storage);

    const session_storage = captureStorageArea(session, allocator, "sessionStorage") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try allocator.alloc(types.StorageValue, 0),
    };
    errdefer freeStorageValues(allocator, session_storage);

    return .{
        .phase = phase,
        .url = url,
        .captured_at_ms = nowMs(),
        .dom_html = dom_html,
        .response_headers_json = response_headers_json,
        .cookies = cookies,
        .local_storage = local_storage,
        .session_storage = session_storage,
    };
}

pub fn appendNavigationSnapshot(session: *Session, bundle: types.SnapshotBundle) !void {
    session.snapshot_lock.lock();
    defer session.snapshot_lock.unlock();
    try session.snapshots.append(session.allocator, bundle);
}

pub fn listNavigationSnapshots(session: *Session, allocator: std.mem.Allocator) ![]types.SnapshotBundle {
    session.snapshot_lock.lock();
    defer session.snapshot_lock.unlock();
    var out = try allocator.alloc(types.SnapshotBundle, session.snapshots.items.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |*bundle| freeSnapshot(allocator, bundle);
        allocator.free(out);
    }
    for (session.snapshots.items, 0..) |bundle, idx| {
        out[idx] = try cloneSnapshotBundle(allocator, bundle);
        copied = idx + 1;
    }
    return out;
}

pub fn freeSnapshots(allocator: std.mem.Allocator, bundles: []types.SnapshotBundle) void {
    for (bundles) |*bundle| freeSnapshot(allocator, bundle);
    allocator.free(bundles);
}

pub fn clearNavigationSnapshots(session: *Session) void {
    session.snapshot_lock.lock();
    defer session.snapshot_lock.unlock();
    while (session.snapshots.items.len > 0) {
        var bundle = session.snapshots.pop().?;
        freeSnapshot(session.allocator, &bundle);
    }
}

pub fn freeSnapshot(allocator: std.mem.Allocator, bundle: *types.SnapshotBundle) void {
    allocator.free(bundle.url);
    allocator.free(bundle.dom_html);
    allocator.free(bundle.response_headers_json);
    freeCookies(allocator, bundle.cookies);
    freeStorageValues(allocator, bundle.local_storage);
    freeStorageValues(allocator, bundle.session_storage);
    bundle.* = undefined;
}

pub fn deinitTelemetry(session: *Session) void {
    clearNetworkRecords(session);
    clearNavigationSnapshots(session);

    session.frames_lock.lock();
    while (session.frames.items.len > 0) {
        var frame = session.frames.pop().?;
        freeFrameInfo(session.allocator, &frame);
    }
    session.frames_lock.unlock();

    session.service_workers_lock.lock();
    while (session.service_workers.items.len > 0) {
        var worker = session.service_workers.pop().?;
        freeServiceWorkerInfo(session.allocator, &worker);
    }
    session.service_workers_lock.unlock();

    session.network_records.deinit(session.allocator);
    session.frames.deinit(session.allocator);
    session.service_workers.deinit(session.allocator);
    session.snapshots.deinit(session.allocator);
}

pub fn serializeBlockRule(allocator: std.mem.Allocator, glob: []const u8) ![]u8 {
    const escaped = try json_util.escapeJsonString(allocator, glob);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "{{\"action\":\"block\",\"urlPattern\":\"{s}\"}}", .{escaped});
}

fn upsertNetworkRecordFromRequest(session: *Session, event: RequestEvent) !void {
    const owned = try cloneOwned(RequestEvent, session.allocator, event);
    defer session.allocator.free(owned.request_id);
    errdefer {
        session.allocator.free(owned.method);
        session.allocator.free(owned.url);
        session.allocator.free(owned.headers_json);
        if (owned.body) |body| session.allocator.free(body);
    }
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = try ensureNetworkRecordLocked(session, event.request_id);
    const record = &session.network_records.items[index];
    session.allocator.free(record.method);
    session.allocator.free(record.url);
    session.allocator.free(record.request_headers_json);
    if (record.request_body) |body| session.allocator.free(body);
    record.method = owned.method;
    record.url = owned.url;
    record.request_headers_json = owned.headers_json;
    record.request_body = owned.body;
}

fn upsertNetworkRecordFromResponse(session: *Session, event: ResponseEvent) !void {
    const owned = try cloneOwned(ResponseEvent, session.allocator, event);
    defer session.allocator.free(owned.request_id);
    errdefer {
        session.allocator.free(owned.url);
        session.allocator.free(owned.headers_json);
        if (owned.body) |body| session.allocator.free(body);
    }
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = try ensureNetworkRecordLocked(session, event.request_id);
    const record = &session.network_records.items[index];
    try appendStatusPointLocked(session, record, event.status, nowMs());
    session.allocator.free(record.url);
    session.allocator.free(record.response_headers_json);
    if (record.response_body) |body| session.allocator.free(body);
    record.url = owned.url;
    record.response_headers_json = owned.headers_json;
    record.response_body = owned.body;
    record.final_status = owned.status;
}

fn cacheResponseBody(session: *Session, request_id: []const u8, body: []const u8) !void {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = findNetworkRecordIndex(session.network_records.items, request_id) orelse return;
    var record = &session.network_records.items[index];
    const owned = try session.allocator.dupe(u8, body);
    if (record.response_body) |existing| session.allocator.free(existing);
    record.response_body = owned;
}

fn ensureNetworkRecordLocked(session: *Session, request_id: []const u8) !usize {
    if (findNetworkRecordIndex(session.network_records.items, request_id)) |index| return index;
    var record = try cloneOwned(types.NetworkRecord, session.allocator, .{
        .request_id = request_id,
        .method = "",
        .url = "",
    });
    errdefer freeNetworkRecord(session.allocator, &record);
    try session.network_records.append(session.allocator, record);
    return session.network_records.items.len - 1;
}

fn findNetworkRecordIndex(records: []const types.NetworkRecord, request_id: []const u8) ?usize {
    for (records, 0..) |record, idx| {
        if (std.mem.eql(u8, record.request_id, request_id)) return idx;
    }
    return null;
}

fn appendStatusPointLocked(
    session: *Session,
    record: *types.NetworkRecord,
    status: u16,
    at_ms: u64,
) !void {
    const old = record.status_timeline;
    const grown = try session.allocator.alloc(types.NetworkStatusTimelinePoint, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = .{ .status = status, .at_ms = at_ms };
    if (old.len > 0) session.allocator.free(old);
    record.status_timeline = grown;
}

fn cloneNetworkRecord(allocator: std.mem.Allocator, src: types.NetworkRecord, include_bodies: bool) !types.NetworkRecord {
    var selected = src;
    if (!include_bodies) {
        selected.request_body = null;
        selected.response_body = null;
    }
    return cloneOwned(types.NetworkRecord, allocator, selected);
}

fn freeNetworkRecord(allocator: std.mem.Allocator, record: *types.NetworkRecord) void {
    allocator.free(record.request_id);
    allocator.free(record.method);
    allocator.free(record.url);
    allocator.free(record.request_headers_json);
    allocator.free(record.response_headers_json);
    if (record.request_body) |body| allocator.free(body);
    if (record.response_body) |body| allocator.free(body);
    for (record.redirects) |hop| {
        allocator.free(hop.from_url);
        allocator.free(hop.to_url);
    }
    if (record.redirects.len > 0) allocator.free(record.redirects);
    if (record.status_timeline.len > 0) allocator.free(record.status_timeline);
    record.* = undefined;
}

fn freeFrameInfo(allocator: std.mem.Allocator, frame: *types.FrameInfo) void {
    allocator.free(frame.frame_id);
    if (frame.parent_frame_id) |parent_id| allocator.free(parent_id);
    allocator.free(frame.url);
    frame.* = undefined;
}

fn freeServiceWorkerInfo(allocator: std.mem.Allocator, worker: *types.ServiceWorkerInfo) void {
    allocator.free(worker.worker_id);
    if (worker.scope_url) |scope| allocator.free(scope);
    if (worker.script_url) |script| allocator.free(script);
    if (worker.state) |state| allocator.free(state);
    worker.* = undefined;
}

fn cloneSnapshotBundle(allocator: std.mem.Allocator, src: types.SnapshotBundle) !types.SnapshotBundle {
    return cloneOwned(types.SnapshotBundle, allocator, src);
}

fn freeCookies(allocator: std.mem.Allocator, cookies: []types.Cookie) void {
    for (cookies) |cookie| {
        allocator.free(cookie.name);
        allocator.free(cookie.value);
        allocator.free(cookie.domain);
        allocator.free(cookie.path);
    }
    allocator.free(cookies);
}

fn freeStorageValues(allocator: std.mem.Allocator, values: []types.StorageValue) void {
    for (values) |value| {
        allocator.free(value.key);
        allocator.free(value.value);
    }
    allocator.free(values);
}

fn captureDomHtml(session: *Session, allocator: std.mem.Allocator) ![]u8 {
    if (!session.supports(.js_eval)) return allocator.dupe(u8, "");
    const payload = try executor.evaluate(
        session,
        "(function(){return document.documentElement ? document.documentElement.outerHTML : '';})();",
    );
    defer session.allocator.free(payload);
    return extractEvaluationString(allocator, payload);
}

fn snapshotCurrentUrl(session: *Session, allocator: std.mem.Allocator) ![]u8 {
    session.state_lock.lock();
    if (session.current_url) |current| {
        defer session.state_lock.unlock();
        return allocator.dupe(u8, current);
    }
    session.state_lock.unlock();
    if (!session.supports(.js_eval)) return allocator.dupe(u8, "");
    const payload = executor.evaluate(session, "location.href") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return allocator.dupe(u8, ""),
    };
    defer session.allocator.free(payload);
    return extractEvaluationString(allocator, payload);
}

fn snapshotHeadersForUrl(session: *Session, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    var i: usize = session.network_records.items.len;
    while (i > 0) {
        i -= 1;
        const record = session.network_records.items[i];
        if (std.mem.eql(u8, record.url, url) and record.response_headers_json.len > 0) {
            return allocator.dupe(u8, record.response_headers_json);
        }
    }
    return allocator.dupe(u8, "{}");
}

fn captureCookies(session: *Session, allocator: std.mem.Allocator) ![]types.Cookie {
    const raw = try executor.getCookies(session);
    defer session.allocator.free(raw);
    return parseCookiesFromPayload(allocator, raw);
}

fn captureStorageArea(
    session: *Session,
    allocator: std.mem.Allocator,
    area_name: []const u8,
) ![]types.StorageValue {
    if (!session.supports(.js_eval)) return allocator.alloc(types.StorageValue, 0);
    const script = try std.fmt.allocPrint(
        session.allocator,
        "(function(){{try{{const s={s}; const out=[]; for(let i=0;i<s.length;i++){{const k=s.key(i); out.push([String(k), String(s.getItem(k) ?? '')]);}} return JSON.stringify(out);}}catch(_err){{return '[]';}}}})();",
        .{area_name},
    );
    defer session.allocator.free(script);
    const payload = try executor.evaluate(session, script);
    defer session.allocator.free(payload);
    const encoded = try extractEvaluationString(allocator, payload);
    defer allocator.free(encoded);
    return parseStorageValuesFromJson(allocator, encoded);
}

fn parseCookiesFromPayload(allocator: std.mem.Allocator, payload: []const u8) ![]types.Cookie {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.alloc(types.Cookie, 0);
    const result = parsed.value.object.get("result") orelse return allocator.alloc(types.Cookie, 0);
    if (result != .object) return allocator.alloc(types.Cookie, 0);
    const cookies_value = result.object.get("cookies") orelse return allocator.alloc(types.Cookie, 0);
    if (cookies_value != .array) return allocator.alloc(types.Cookie, 0);

    var out: std.ArrayList(types.Cookie) = .empty;
    errdefer {
        for (out.items) |cookie| {
            allocator.free(cookie.name);
            allocator.free(cookie.value);
            allocator.free(cookie.domain);
            allocator.free(cookie.path);
        }
        out.deinit(allocator);
    }

    for (cookies_value.array.items) |item| {
        if (item != .object) continue;
        const name = json_util.getStringField(item.object, "name") orelse continue;
        const value = json_util.getStringField(item.object, "value") orelse "";
        const domain = json_util.getStringField(item.object, "domain") orelse "";
        const path = json_util.getStringField(item.object, "path") orelse "/";
        const secure = json_util.getBoolField(item.object, "secure") orelse true;
        const http_only = json_util.getBoolField(item.object, "httpOnly") orelse true;
        const expires = json_util.getI64Field(item.object, "expires");
        const same_site = json_util.parseCookieSameSite(json_util.getStringField(item.object, "sameSite"));
        const owned = try cloneOwned(types.Cookie, allocator, .{
            .name = name,
            .value = value,
            .domain = domain,
            .path = path,
            .secure = secure,
            .http_only = http_only,
            .expires_unix_seconds = expires,
            .same_site = same_site,
        });
        errdefer freeOwned(types.Cookie, allocator, owned);
        try out.append(allocator, owned);
    }
    return out.toOwnedSlice(allocator);
}

fn parseStorageValuesFromJson(allocator: std.mem.Allocator, payload: []const u8) ![]types.StorageValue {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(types.StorageValue, 0);

    var out: std.ArrayList(types.StorageValue) = .empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        out.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .array or item.array.items.len < 2) continue;
        const key_val = item.array.items[0];
        const value_val = item.array.items[1];
        if (key_val != .string or value_val != .string) continue;
        const owned = try cloneOwned(types.StorageValue, allocator, .{ .key = key_val.string, .value = value_val.string });
        errdefer freeOwned(types.StorageValue, allocator, owned);
        try out.append(allocator, owned);
    }
    return out.toOwnedSlice(allocator);
}

fn extractEvaluationString(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const value = extractEvaluationValue(parsed.value) orelse return allocator.dupe(u8, "");
    return switch (value) {
        .string => allocator.dupe(u8, value.string),
        else => std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}

fn extractEvaluationValue(value: std.json.Value) ?std.json.Value {
    if (value != .object) return null;
    if (value.object.get("result")) |result| {
        if (result == .object) {
            if (result.object.get("result")) |nested| {
                if (nested == .object) {
                    if (nested.object.get("value")) |raw| return raw;
                }
            }
            if (result.object.get("value")) |raw| return raw;
        }
    }
    if (value.object.get("result")) |result| {
        if (result == .object) {
            if (result.object.get("value")) |raw| return raw;
        }
    }
    if (value.object.get("value")) |raw| return raw;
    return null;
}

fn nowMs() u64 {
    const ts = compat.milliTimestamp();
    if (ts <= 0) return 0;
    return @intCast(ts);
}

fn cloneRule(allocator: std.mem.Allocator, rule: NetworkRule) !NetworkRule {
    return cloneOwned(NetworkRule, allocator, rule);
}

fn freeRule(allocator: std.mem.Allocator, rule: NetworkRule) void {
    allocator.free(rule.id);
    allocator.free(rule.url_pattern);

    switch (rule.action) {
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
            for (m.remove_header_names) |n| allocator.free(n);
            allocator.free(m.remove_header_names);
        },
    }
}

fn syncRemoteRules(session: *Session) !void {
    if (!session.supports(.network_intercept)) return;
    try executor.syncNetworkRules(session);
}

const TestCapture = struct {
    request_cb_count: usize = 0,
    response_cb_count: usize = 0,
    request_lifecycle_count: usize = 0,
    response_lifecycle_count: usize = 0,
    last_request_headers_json: ?[]const u8 = null,
    last_response_headers_json: ?[]const u8 = null,
};

var test_capture: TestCapture = .{};

fn resetTestCapture() void {
    test_capture = .{};
}

fn requestTestCallback(event: RequestEvent) void {
    test_capture.request_cb_count += 1;
    test_capture.last_request_headers_json = event.headers_json;
}

fn responseTestCallback(event: ResponseEvent) void {
    test_capture.response_cb_count += 1;
    test_capture.last_response_headers_json = event.headers_json;
}

fn lifecycleTestCallback(event: types.LifecycleEvent) void {
    switch (event) {
        .network_request_observed => |e| {
            test_capture.request_lifecycle_count += 1;
            test_capture.last_request_headers_json = e.headers_json;
        },
        .network_response_observed => |e| {
            test_capture.response_lifecycle_count += 1;
            test_capture.last_response_headers_json = e.headers_json;
        },
        else => {},
    }
}

fn makeNetworkTestSession(allocator: std.mem.Allocator) !Session {
    return .{
        .allocator = allocator,
        .id = 100,
        .mode = .browser,
        .transport = .cdp_ws,
        .install = .{
            .kind = .chrome,
            .engine = .chromium,
            .path = try allocator.dupe(u8, "test-browser"),
            .version = null,
            .source = .explicit,
        },
        .capability_set = .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = false,
            .downloads = false,
            .bidi_events = false,
        },
        .adapter_kind = .cdp,
        .endpoint = null,
        .browsing_context_id = null,
    };
}

test "emit observed request/response forwards headers to callbacks and lifecycle hooks" {
    const allocator = std.testing.allocator;
    var session = try makeNetworkTestSession(allocator);
    defer session.deinit();

    resetTestCapture();
    onRequest(&session, requestTestCallback);
    onResponse(&session, responseTestCallback);
    const sub_id = try session.onEvent(
        .{ .kinds = &.{ .network_request_observed, .network_response_observed } },
        lifecycleTestCallback,
    );
    defer _ = session.offEvent(sub_id);

    emitRequestObserved(&session, .{
        .request_id = "req-1",
        .method = "GET",
        .url = "https://example.com/data",
        .headers_json = "{\"accept\":\"application/json\"}",
    });
    emitResponseObserved(&session, .{
        .request_id = "req-1",
        .status = 200,
        .url = "https://example.com/data",
        .headers_json = "{\"content-type\":\"application/json\"}",
    });

    try std.testing.expectEqual(@as(usize, 1), test_capture.request_cb_count);
    try std.testing.expectEqual(@as(usize, 1), test_capture.response_cb_count);
    try std.testing.expectEqual(@as(usize, 1), test_capture.request_lifecycle_count);
    try std.testing.expectEqual(@as(usize, 1), test_capture.response_lifecycle_count);
    try std.testing.expectEqualStrings("{\"content-type\":\"application/json\"}", test_capture.last_response_headers_json.?);
}

test "network telemetry keeps request bodies, redirect timeline, and status timeline" {
    const allocator = std.testing.allocator;
    var session = try makeNetworkTestSession(allocator);
    defer session.deinit();

    emitRequestObserved(&session, .{
        .request_id = "req-1",
        .method = "POST",
        .url = "https://example.com/start",
        .headers_json = "{\"content-type\":\"application/x-www-form-urlencoded\"}",
        .body = "a=1",
    });
    try recordRedirect(
        &session,
        "req-1",
        "https://example.com/start",
        "https://example.com/next",
        302,
        1_000,
    );
    emitResponseObserved(&session, .{
        .request_id = "req-1",
        .status = 200,
        .url = "https://example.com/next",
        .headers_json = "{\"content-type\":\"text/html\"}",
        .body = "<html>ok</html>",
    });

    const slim_records = try listNetworkRecords(&session, allocator, false);
    defer freeNetworkRecords(allocator, slim_records);
    try std.testing.expectEqual(@as(usize, 1), slim_records.len);
    try std.testing.expect(slim_records[0].request_body == null);
    try std.testing.expect(slim_records[0].response_body == null);

    const records = try listNetworkRecords(&session, allocator, true);
    defer freeNetworkRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("req-1", records[0].request_id);
    try std.testing.expectEqualStrings("POST", records[0].method);
    try std.testing.expectEqualStrings("https://example.com/next", records[0].url);
    try std.testing.expect(records[0].request_body != null);
    try std.testing.expectEqualStrings("a=1", records[0].request_body.?);
    try std.testing.expectEqual(@as(usize, 1), records[0].redirects.len);
    try std.testing.expectEqualStrings("https://example.com/start", records[0].redirects[0].from_url);
    try std.testing.expectEqualStrings("https://example.com/next", records[0].redirects[0].to_url);
    try std.testing.expectEqual(@as(usize, 2), records[0].status_timeline.len);
    try std.testing.expectEqual(@as(?u16, 200), records[0].final_status);
}

test "frame and service worker telemetry upsert and remove work" {
    const allocator = std.testing.allocator;
    var session = try makeNetworkTestSession(allocator);
    defer session.deinit();

    try upsertFrameInfo(&session, .{
        .frame_id = "root",
        .parent_frame_id = null,
        .url = "https://example.com",
    });
    try upsertFrameInfo(&session, .{
        .frame_id = "child",
        .parent_frame_id = "root",
        .url = "https://example.com/frame",
    });
    removeFrameInfo(&session, "child");

    const frames = try listFrames(&session, allocator);
    defer freeFrames(allocator, frames);
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("root", frames[0].frame_id);

    try upsertServiceWorkerInfo(&session, .{
        .worker_id = "sw-1",
        .scope_url = "https://example.com/",
        .script_url = "https://example.com/sw.js",
        .state = "activated",
    });
    removeServiceWorkerInfo(&session, "sw-1");

    const workers = try listServiceWorkers(&session, allocator);
    defer freeServiceWorkers(allocator, workers);
    try std.testing.expectEqual(@as(usize, 0), workers.len);
}

// Data-only telemetry types contain owned slices, optionals, structs, and tagged
// unions. Clone every aggregate transactionally, including its partial child.
fn cloneOwned(comptime T: type, allocator: std.mem.Allocator, source: T) !T {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            const out = try allocator.alloc(ptr.child, source.len);
            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |value| freeOwned(ptr.child, allocator, value);
                allocator.free(out);
            }
            for (source, 0..) |value, i| {
                out[i] = try cloneOwned(ptr.child, allocator, value);
                initialized += 1;
            }
            return out;
        },
        .@"struct" => |info| {
            var out: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (info.fields, 0..) |field, i| {
                if (i < initialized) freeOwned(field.type, allocator, @field(out, field.name));
            };
            inline for (info.fields) |field| {
                @field(out, field.name) = try cloneOwned(field.type, allocator, @field(source, field.name));
                initialized += 1;
            }
            return out;
        },
        .@"union" => return switch (source) {
            inline else => |value, tag| @unionInit(T, @tagName(tag), try cloneOwned(@TypeOf(value), allocator, value)),
        },
        .optional => |info| return if (source) |value| try cloneOwned(info.child, allocator, value) else null,
        else => return source,
    }
}

fn freeOwned(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            for (value) |item| freeOwned(ptr.child, allocator, item);
            allocator.free(value);
        },
        .@"struct" => |info| inline for (info.fields) |field| {
            freeOwned(field.type, allocator, @field(value, field.name));
        },
        .@"union" => switch (value) {
            inline else => |payload| freeOwned(@TypeOf(payload), allocator, payload),
        },
        .optional => |info| if (value) |item| {
            freeOwned(info.child, allocator, item);
        },
        else => {},
    }
}

fn ruleAllocationCase(allocator: std.mem.Allocator) !void {
    const rules = [_]NetworkRule{
        .{ .id = "block", .url_pattern = "*/blocked*", .action = .{ .block = {} } },
        .{ .id = "continue", .url_pattern = "*/continue*", .action = .{ .continue_request = {} } },
        .{ .id = "fulfill", .url_pattern = "*/fulfilled*", .action = .{ .fulfill = .{
            .status = 201,
            .body = "body λ",
            .headers = &.{ .{ .name = "First", .value = "1" }, .{ .name = "Second", .value = "2" } },
        } } },
        .{ .id = "modify", .url_pattern = "*/modified*", .action = .{ .modify = .{
            .add_headers = &.{ .{ .name = "First", .value = "1" }, .{ .name = "Second", .value = "2" } },
            .remove_header_names = &.{ "Remove-One", "Remove-Two" },
        } } },
    };
    for (rules) |rule| {
        const owned = try cloneRule(allocator, rule);
        defer freeRule(allocator, owned);
        try std.testing.expectEqualDeep(rule, owned);
        try std.testing.expect(rule.id.ptr != owned.id.ptr);
    }
}

fn telemetryAllocationCase(allocator: std.mem.Allocator) !void {
    var session = try makeNetworkTestSession(allocator);
    defer session.deinit();
    try upsertNetworkRecordFromRequest(&session, .{ .request_id = "one", .method = "POST", .url = "https://example.test/start", .headers_json = "{\"x\":\"request\"}", .body = "request body" });
    try recordRedirect(&session, "one", "https://example.test/start", "https://example.test/final", 302, 1000);
    try upsertNetworkRecordFromResponse(&session, .{ .request_id = "one", .status = 200, .url = "https://example.test/final", .headers_json = "{\"x\":\"response\"}", .body = "response body" });
    try cacheResponseBody(&session, "one", "replaced response");
    const full = try listNetworkRecords(&session, allocator, true);
    defer freeNetworkRecords(allocator, full);
    try std.testing.expectEqualStrings("replaced response", full[0].response_body.?);
    try std.testing.expectEqual(@as(usize, 1), full[0].redirects.len);
    try std.testing.expectEqual(@as(usize, 2), full[0].status_timeline.len);
    const slim = try listNetworkRecords(&session, allocator, false);
    defer freeNetworkRecords(allocator, slim);
    try std.testing.expect(slim[0].request_body == null and slim[0].response_body == null);

    try upsertFrameInfo(&session, .{ .frame_id = "frame", .parent_frame_id = "parent", .url = "before" });
    try upsertFrameInfo(&session, .{ .frame_id = "frame", .parent_frame_id = "new parent", .url = "after" });
    const frames = try listFrames(&session, allocator);
    defer freeFrames(allocator, frames);
    try std.testing.expectEqualStrings("after", frames[0].url);
    try std.testing.expectEqualStrings("new parent", frames[0].parent_frame_id.?);

    try upsertServiceWorkerInfo(&session, .{ .worker_id = "worker", .scope_url = "scope", .script_url = "script", .state = "installing" });
    try upsertServiceWorkerInfo(&session, .{ .worker_id = "worker", .scope_url = "new scope", .script_url = "new script", .state = "activated" });
    const workers = try listServiceWorkers(&session, allocator);
    defer freeServiceWorkers(allocator, workers);
    try std.testing.expectEqualStrings("activated", workers[0].state.?);
}

fn snapshotAllocationCase(allocator: std.mem.Allocator) !void {
    const cookies = try parseCookiesFromPayload(allocator,
        \\{"result":{"cookies":[{"name":"one","value":"1","domain":"example.test","path":"/"},{"name":"two","value":"2","domain":".example.test","path":"/app"}]}}
    );
    defer freeCookies(allocator, cookies);
    const local = try parseStorageValuesFromJson(allocator, "[[\"a\",\"one\"],[\"b\",\"two\"]]");
    defer freeStorageValues(allocator, local);
    const tab = try parseStorageValuesFromJson(allocator, "[[\"c\",\"three\"]]");
    defer freeStorageValues(allocator, tab);
    const source: types.SnapshotBundle = .{
        .phase = .manual,
        .url = "https://example.test/",
        .captured_at_ms = 123,
        .dom_html = "<html>actual</html>",
        .response_headers_json = "{\"header\":\"value\"}",
        .cookies = cookies,
        .local_storage = local,
        .session_storage = tab,
    };
    var owned = try cloneSnapshotBundle(allocator, source);
    defer freeSnapshot(allocator, &owned);
    try std.testing.expectEqualDeep(source, owned);
    var session = try makeNetworkTestSession(allocator);
    defer session.deinit();
    var stored = try cloneSnapshotBundle(allocator, source);
    var transferred = false;
    defer if (!transferred) freeSnapshot(allocator, &stored);
    try appendNavigationSnapshot(&session, stored);
    transferred = true;
    const listed = try listNavigationSnapshots(&session, allocator);
    defer freeSnapshots(allocator, listed);
    try std.testing.expectEqualDeep(source, listed[0]);
}

test "network rule variants free every partially initialized allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ruleAllocationCase, .{});
}

test "network telemetry insertion update and copying survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, telemetryAllocationCase, .{});
}

test "network snapshot parsing and cloning survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotAllocationCase, .{});
}

test "network failed replacements retain existing owned telemetry" {
    const allocator = std.testing.allocator;
    var session = try makeNetworkTestSession(allocator);
    defer session.deinit();
    try upsertFrameInfo(&session, .{ .frame_id = "frame", .parent_frame_id = "parent", .url = "original" });
    try upsertServiceWorkerInfo(&session, .{ .worker_id = "worker", .state = "active", .scope_url = "scope", .script_url = "script" });
    try upsertNetworkRecordFromRequest(&session, .{ .request_id = "request", .method = "GET", .url = "original", .headers_json = "{}" });
    try upsertNetworkRecordFromResponse(&session, .{ .request_id = "request", .status = 200, .url = "original", .headers_json = "{}", .body = "owned" });
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    session.allocator = failing.allocator();
    defer session.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, upsertFrameInfo(&session, .{ .frame_id = "frame", .parent_frame_id = "new-parent", .url = "changed" }));
    try std.testing.expectError(error.OutOfMemory, upsertServiceWorkerInfo(&session, .{ .worker_id = "worker", .state = "changed" }));
    try std.testing.expectError(error.OutOfMemory, cacheResponseBody(&session, "request", "changed"));
    try std.testing.expectError(error.OutOfMemory, upsertNetworkRecordFromResponse(&session, .{ .request_id = "request", .status = 404, .url = "changed", .headers_json = "{}", .body = "changed" }));
    try std.testing.expectEqualStrings("original", session.frames.items[0].url);
    try std.testing.expectEqualStrings("parent", session.frames.items[0].parent_frame_id.?);
    try std.testing.expectEqualStrings("active", session.service_workers.items[0].state.?);
    try std.testing.expectEqualStrings("owned", session.network_records.items[0].response_body.?);
    try std.testing.expectEqual(@as(?u16, 200), session.network_records.items[0].final_status);
}
