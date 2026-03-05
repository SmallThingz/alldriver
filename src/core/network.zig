const std = @import("std");
const Session = @import("session.zig").Session;
const types = @import("../types.zig");
const executor = @import("../protocol/executor.zig");
const json_util = @import("../util/json.zig");
const events = @import("events.zig");

pub const NetworkRule = types.NetworkRule;
pub const InterceptAction = types.InterceptAction;
pub const RequestEvent = types.RequestEvent;
pub const ResponseEvent = types.ResponseEvent;

pub fn enableInterception(session: *Session) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    try executor.enableNetworkInterception(session);
}

pub fn disableInterception(session: *Session) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    try clearInterceptRules(session);
}

pub fn addInterceptRule(session: *Session, rule: NetworkRule) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;

    const owned = try cloneRule(session.allocator, rule);
    errdefer freeRule(session.allocator, owned);

    try executor.addNetworkRule(session, owned);
    try session.rules.append(session.allocator, owned);
}

pub fn removeInterceptRule(session: *Session, rule_id: []const u8) !bool {
    var i: usize = 0;
    while (i < session.rules.items.len) : (i += 1) {
        if (std.mem.eql(u8, session.rules.items[i].id, rule_id)) {
            const removed = session.rules.swapRemove(i);
            defer freeRule(session.allocator, removed);
            try syncRemoteRules(session);
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

pub fn onRequest(session: *Session, callback: *const fn (RequestEvent) void) void {
    session.on_request = callback;
}

pub fn onResponse(session: *Session, callback: *const fn (ResponseEvent) void) void {
    session.on_response = callback;
}

pub fn subscribe(session: *Session, callback: *const fn (event_json: []const u8) void) !void {
    if (!session.supports(.network_intercept)) return error.UnsupportedCapability;
    try enableInterception(session);
    callback("{\"event\":\"network.subscription.active\"}");
}

pub fn emitDebugEvent(session: *Session, event_json: []const u8) void {
    emitRequestObserved(session, .{
        .request_id = "debug",
        .method = "DEBUG",
        .url = event_json,
        .headers_json = "{}",
    });
}

pub fn emitRequestObserved(session: *Session, event: RequestEvent) void {
    upsertNetworkRecordFromRequest(session, event) catch {};
    if (session.on_request) |cb| cb(event);
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
    if (session.on_response) |cb| cb(event);
    events.emit(session, .{
        .network_response_observed = .{
            .request_id = event.request_id,
            .status = event.status,
            .url = event.url,
            .headers_json = event.headers_json,
        },
    });
}

pub fn recordRedirect(
    session: *Session,
    request_id: []const u8,
    from_url: []const u8,
    to_url: []const u8,
    status: u16,
    at_ms: u64,
) !void {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = try ensureNetworkRecordLocked(session, request_id);
    var record = &session.network_records.items[index];

    const redirect = types.RedirectHop{
        .from_url = try session.allocator.dupe(u8, from_url),
        .to_url = try session.allocator.dupe(u8, to_url),
        .status = status,
        .at_ms = at_ms,
    };
    try appendRedirectLocked(session, record, redirect);
    try appendStatusPointLocked(session, record, status, at_ms);
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
                return hop.status;
            }
        }
    }
    return null;
}

pub fn upsertFrameInfo(session: *Session, frame: types.FrameInfo) !void {
    session.frames_lock.lock();
    defer session.frames_lock.unlock();
    for (session.frames.items) |*existing| {
        if (!std.mem.eql(u8, existing.frame_id, frame.frame_id)) continue;
        replaceOwnedString(session.allocator, &existing.url, frame.url);
        if (existing.parent_frame_id) |parent_id| session.allocator.free(parent_id);
        existing.parent_frame_id = if (frame.parent_frame_id) |parent_id|
            try session.allocator.dupe(u8, parent_id)
        else
            null;
        return;
    }

    try session.frames.append(session.allocator, .{
        .frame_id = try session.allocator.dupe(u8, frame.frame_id),
        .parent_frame_id = if (frame.parent_frame_id) |parent_id| try session.allocator.dupe(u8, parent_id) else null,
        .url = try session.allocator.dupe(u8, frame.url),
    });
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
    session.service_workers_lock.lock();
    defer session.service_workers_lock.unlock();
    for (session.service_workers.items) |*existing| {
        if (!std.mem.eql(u8, existing.worker_id, worker.worker_id)) continue;
        replaceOptionalOwnedString(session.allocator, &existing.scope_url, worker.scope_url);
        replaceOptionalOwnedString(session.allocator, &existing.script_url, worker.script_url);
        replaceOptionalOwnedString(session.allocator, &existing.state, worker.state);
        return;
    }
    try session.service_workers.append(session.allocator, .{
        .worker_id = try session.allocator.dupe(u8, worker.worker_id),
        .scope_url = if (worker.scope_url) |scope| try session.allocator.dupe(u8, scope) else null,
        .script_url = if (worker.script_url) |script| try session.allocator.dupe(u8, script) else null,
        .state = if (worker.state) |state| try session.allocator.dupe(u8, state) else null,
    });
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
    session.network_lock.lock();
    var out = try allocator.alloc(types.NetworkRecord, session.network_records.items.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |*record| freeNetworkRecord(allocator, record);
        allocator.free(out);
    }
    for (session.network_records.items, 0..) |record, idx| {
        out[idx] = try cloneNetworkRecord(allocator, record, include_bodies);
        copied = idx + 1;
    }
    session.network_lock.unlock();

    if (!include_bodies or session.transport != .cdp_ws) return out;

    for (out) |*record| {
        if (record.response_body != null) continue;
        const fetched_opt = executor.getResponseBody(session, record.request_id) catch null;
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
    var out = try allocator.alloc(types.FrameInfo, session.frames.items.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |*frame| freeFrameInfo(allocator, frame);
        allocator.free(out);
    }
    for (session.frames.items, 0..) |frame, idx| {
        out[idx] = .{
            .frame_id = try allocator.dupe(u8, frame.frame_id),
            .parent_frame_id = if (frame.parent_frame_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .url = try allocator.dupe(u8, frame.url),
        };
        copied = idx + 1;
    }
    return out;
}

pub fn freeFrames(allocator: std.mem.Allocator, frames: []types.FrameInfo) void {
    for (frames) |*frame| freeFrameInfo(allocator, frame);
    allocator.free(frames);
}

pub fn listServiceWorkers(session: *Session, allocator: std.mem.Allocator) ![]types.ServiceWorkerInfo {
    session.service_workers_lock.lock();
    defer session.service_workers_lock.unlock();
    var out = try allocator.alloc(types.ServiceWorkerInfo, session.service_workers.items.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |*worker| freeServiceWorkerInfo(allocator, worker);
        allocator.free(out);
    }
    for (session.service_workers.items, 0..) |worker, idx| {
        out[idx] = .{
            .worker_id = try allocator.dupe(u8, worker.worker_id),
            .scope_url = if (worker.scope_url) |scope| try allocator.dupe(u8, scope) else null,
            .script_url = if (worker.script_url) |script| try allocator.dupe(u8, script) else null,
            .state = if (worker.state) |state| try allocator.dupe(u8, state) else null,
        };
        copied = idx + 1;
    }
    return out;
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

    const dom_html = captureDomHtml(session, allocator) catch try allocator.dupe(u8, "");
    errdefer allocator.free(dom_html);

    const response_headers_json = try snapshotHeadersForUrl(session, allocator, url);
    errdefer allocator.free(response_headers_json);

    const cookies = captureCookies(session, allocator) catch try allocator.alloc(types.Cookie, 0);
    errdefer freeCookies(allocator, cookies);

    const local_storage = captureStorageArea(session, allocator, "localStorage") catch try allocator.alloc(types.StorageValue, 0);
    errdefer freeStorageValues(allocator, local_storage);

    const session_storage = captureStorageArea(session, allocator, "sessionStorage") catch try allocator.alloc(types.StorageValue, 0);
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
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = try ensureNetworkRecordLocked(session, event.request_id);
    var record = &session.network_records.items[index];
    replaceOwnedString(session.allocator, &record.method, event.method);
    replaceOwnedString(session.allocator, &record.url, event.url);
    replaceOwnedString(session.allocator, &record.request_headers_json, event.headers_json);
    if (record.request_body) |body| session.allocator.free(body);
    record.request_body = if (event.body) |body| try session.allocator.dupe(u8, body) else null;
}

fn upsertNetworkRecordFromResponse(session: *Session, event: ResponseEvent) !void {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = try ensureNetworkRecordLocked(session, event.request_id);
    var record = &session.network_records.items[index];
    replaceOwnedString(session.allocator, &record.url, event.url);
    replaceOwnedString(session.allocator, &record.response_headers_json, event.headers_json);
    record.final_status = event.status;
    try appendStatusPointLocked(session, record, event.status, nowMs());
    if (record.response_body) |body| session.allocator.free(body);
    record.response_body = if (event.body) |body| try session.allocator.dupe(u8, body) else null;
}

fn cacheResponseBody(session: *Session, request_id: []const u8, body: []const u8) !void {
    session.network_lock.lock();
    defer session.network_lock.unlock();
    const index = findNetworkRecordIndex(session.network_records.items, request_id) orelse return;
    var record = &session.network_records.items[index];
    if (record.response_body) |existing| session.allocator.free(existing);
    record.response_body = try session.allocator.dupe(u8, body);
}

fn ensureNetworkRecordLocked(session: *Session, request_id: []const u8) !usize {
    if (findNetworkRecordIndex(session.network_records.items, request_id)) |index| return index;
    try session.network_records.append(session.allocator, .{
        .request_id = try session.allocator.dupe(u8, request_id),
        .method = try session.allocator.dupe(u8, ""),
        .url = try session.allocator.dupe(u8, ""),
        .request_headers_json = try session.allocator.dupe(u8, "{}"),
        .response_headers_json = try session.allocator.dupe(u8, "{}"),
        .request_body = null,
        .response_body = null,
        .final_status = null,
        .redirects = &.{},
        .status_timeline = &.{},
    });
    return session.network_records.items.len - 1;
}

fn findNetworkRecordIndex(records: []const types.NetworkRecord, request_id: []const u8) ?usize {
    for (records, 0..) |record, idx| {
        if (std.mem.eql(u8, record.request_id, request_id)) return idx;
    }
    return null;
}

fn appendRedirectLocked(
    session: *Session,
    record: *types.NetworkRecord,
    redirect: types.RedirectHop,
) !void {
    const old = record.redirects;
    const grown = try session.allocator.alloc(types.RedirectHop, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = redirect;
    if (old.len > 0) session.allocator.free(old);
    record.redirects = grown;
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

fn replaceOwnedString(allocator: std.mem.Allocator, field: *[]const u8, value: []const u8) void {
    if (std.mem.eql(u8, field.*, value)) return;
    const dupe = allocator.dupe(u8, value) catch return;
    allocator.free(field.*);
    field.* = dupe;
}

fn replaceOptionalOwnedString(
    allocator: std.mem.Allocator,
    field: *?[]const u8,
    value: ?[]const u8,
) void {
    if (field.*) |existing| allocator.free(existing);
    field.* = if (value) |new_value| allocator.dupe(u8, new_value) catch null else null;
}

fn cloneNetworkRecord(
    allocator: std.mem.Allocator,
    src: types.NetworkRecord,
    include_bodies: bool,
) !types.NetworkRecord {
    var redirects = try allocator.alloc(types.RedirectHop, src.redirects.len);
    var redirect_copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < redirect_copied) : (i += 1) {
            allocator.free(redirects[i].from_url);
            allocator.free(redirects[i].to_url);
        }
        allocator.free(redirects);
    }
    for (src.redirects, 0..) |hop, idx| {
        redirects[idx] = .{
            .from_url = try allocator.dupe(u8, hop.from_url),
            .to_url = try allocator.dupe(u8, hop.to_url),
            .status = hop.status,
            .at_ms = hop.at_ms,
        };
        redirect_copied = idx + 1;
    }

    const timeline = try allocator.alloc(types.NetworkStatusTimelinePoint, src.status_timeline.len);
    errdefer allocator.free(timeline);
    @memcpy(timeline, src.status_timeline);

    return .{
        .request_id = try allocator.dupe(u8, src.request_id),
        .method = try allocator.dupe(u8, src.method),
        .url = try allocator.dupe(u8, src.url),
        .request_headers_json = try allocator.dupe(u8, src.request_headers_json),
        .response_headers_json = try allocator.dupe(u8, src.response_headers_json),
        .request_body = if (include_bodies and src.request_body != null) try allocator.dupe(u8, src.request_body.?) else null,
        .response_body = if (include_bodies and src.response_body != null) try allocator.dupe(u8, src.response_body.?) else null,
        .final_status = src.final_status,
        .redirects = redirects,
        .status_timeline = timeline,
    };
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
    const cookies = try cloneCookies(allocator, src.cookies);
    errdefer freeCookies(allocator, cookies);
    const local_storage = try cloneStorageValues(allocator, src.local_storage);
    errdefer freeStorageValues(allocator, local_storage);
    const session_storage = try cloneStorageValues(allocator, src.session_storage);
    errdefer freeStorageValues(allocator, session_storage);

    return .{
        .phase = src.phase,
        .url = try allocator.dupe(u8, src.url),
        .captured_at_ms = src.captured_at_ms,
        .dom_html = try allocator.dupe(u8, src.dom_html),
        .response_headers_json = try allocator.dupe(u8, src.response_headers_json),
        .cookies = cookies,
        .local_storage = local_storage,
        .session_storage = session_storage,
    };
}

fn cloneCookies(allocator: std.mem.Allocator, cookies: []const types.Cookie) ![]types.Cookie {
    var out = try allocator.alloc(types.Cookie, cookies.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |cookie| {
            allocator.free(cookie.name);
            allocator.free(cookie.value);
            allocator.free(cookie.domain);
            allocator.free(cookie.path);
        }
        allocator.free(out);
    }
    for (cookies, 0..) |cookie, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, cookie.name),
            .value = try allocator.dupe(u8, cookie.value),
            .domain = try allocator.dupe(u8, cookie.domain),
            .path = try allocator.dupe(u8, cookie.path),
            .secure = cookie.secure,
            .http_only = cookie.http_only,
            .expires_unix_seconds = cookie.expires_unix_seconds,
            .same_site = cookie.same_site,
        };
        copied = idx + 1;
    }
    return out;
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

fn cloneStorageValues(allocator: std.mem.Allocator, values: []const types.StorageValue) ![]types.StorageValue {
    var out = try allocator.alloc(types.StorageValue, values.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(out);
    }
    for (values, 0..) |value, idx| {
        out[idx] = .{
            .key = try allocator.dupe(u8, value.key),
            .value = try allocator.dupe(u8, value.value),
        };
        copied = idx + 1;
    }
    return out;
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
    const payload = executor.evaluate(session, "location.href") catch return allocator.dupe(u8, "");
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
        const name = getJsonString(item.object, "name") orelse continue;
        const value = getJsonString(item.object, "value") orelse "";
        const domain = getJsonString(item.object, "domain") orelse "";
        const path = getJsonString(item.object, "path") orelse "/";
        const secure = getJsonBool(item.object, "secure") orelse true;
        const http_only = getJsonBool(item.object, "httpOnly") orelse true;
        const expires = getJsonI64(item.object, "expires");
        const same_site = parseSameSite(getJsonString(item.object, "sameSite"));
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
            .domain = try allocator.dupe(u8, domain),
            .path = try allocator.dupe(u8, path),
            .secure = secure,
            .http_only = http_only,
            .expires_unix_seconds = expires,
            .same_site = same_site,
        });
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
        try out.append(allocator, .{
            .key = try allocator.dupe(u8, key_val.string),
            .value = try allocator.dupe(u8, value_val.string),
        });
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

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getJsonBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn getJsonI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |n| @intFromFloat(n),
        else => null,
    };
}

fn parseSameSite(raw: ?[]const u8) types.CookieSameSite {
    const value = raw orelse return .unspecified;
    if (std.ascii.eqlIgnoreCase(value, "strict")) return .strict;
    if (std.ascii.eqlIgnoreCase(value, "lax")) return .lax;
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    return .unspecified;
}

fn nowMs() u64 {
    const ts = std.time.milliTimestamp();
    if (ts <= 0) return 0;
    return @intCast(ts);
}

fn cloneRule(allocator: std.mem.Allocator, rule: NetworkRule) !NetworkRule {
    return .{
        .id = try allocator.dupe(u8, rule.id),
        .url_pattern = try allocator.dupe(u8, rule.url_pattern),
        .action = try cloneAction(allocator, rule.action),
    };
}

fn cloneAction(allocator: std.mem.Allocator, action: InterceptAction) !InterceptAction {
    return switch (action) {
        .block => .{ .block = {} },
        .continue_request => .{ .continue_request = {} },
        .fulfill => |f| blk: {
            const headers = try allocator.alloc(types.Header, f.headers.len);
            errdefer allocator.free(headers);

            var i: usize = 0;
            errdefer {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    allocator.free(headers[j].name);
                    allocator.free(headers[j].value);
                }
            }

            for (f.headers, 0..) |h, idx| {
                headers[idx] = .{
                    .name = try allocator.dupe(u8, h.name),
                    .value = try allocator.dupe(u8, h.value),
                };
                i = idx + 1;
            }

            break :blk .{ .fulfill = .{
                .status = f.status,
                .body = try allocator.dupe(u8, f.body),
                .headers = headers,
            } };
        },
        .modify => |m| blk: {
            const add_headers = try allocator.alloc(types.Header, m.add_headers.len);
            errdefer allocator.free(add_headers);

            var i: usize = 0;
            errdefer {
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    allocator.free(add_headers[j].name);
                    allocator.free(add_headers[j].value);
                }
            }

            for (m.add_headers, 0..) |h, idx| {
                add_headers[idx] = .{
                    .name = try allocator.dupe(u8, h.name),
                    .value = try allocator.dupe(u8, h.value),
                };
                i = idx + 1;
            }

            const remove_names = try allocator.alloc([]const u8, m.remove_header_names.len);
            errdefer allocator.free(remove_names);

            var k: usize = 0;
            errdefer {
                var j: usize = 0;
                while (j < k) : (j += 1) allocator.free(remove_names[j]);
            }

            for (m.remove_header_names, 0..) |n, idx| {
                remove_names[idx] = try allocator.dupe(u8, n);
                k = idx + 1;
            }

            break :blk .{ .modify = .{
                .add_headers = add_headers,
                .remove_header_names = remove_names,
            } };
        },
    };
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
    executor.disableNetworkInterception(session) catch |err| switch (err) {
        error.UnsupportedProtocol => return,
        else => return err,
    };
    if (session.rules.items.len == 0) return;
    try executor.enableNetworkInterception(session);
    for (session.rules.items) |rule| {
        try executor.addNetworkRule(session, rule);
    }
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
