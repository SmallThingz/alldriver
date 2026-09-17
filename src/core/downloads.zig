const std = @import("std");
const compat = @import("../util/compat.zig");
const ws = @import("../transport/ws_client.zig");
const rpc = @import("../transport/json_rpc.zig");
const common = @import("../protocol/common.zig");
const json_util = @import("../util/json.zig");
const DownloadItem = @import("artifacts.zig").DownloadItem;

const Record = struct {
    guid: []u8,
    filename: []u8,
    path: []u8,
    state: enum { in_progress, completed, canceled } = .in_progress,
};

/// Heap-stable owner of the browser connection and its notification reader.
/// The worker never retains a pointer to a movable Session value.
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    client: ?ws.Client = null,
    worker: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: compat.Mutex = .{},
    records: std.ArrayList(Record) = .empty,
    failure: ?anyerror = null,
    next_id: u64 = 1,

    /// Download files use Chromium GUID names; snapshots retain the server's
    /// suggested filename separately. The directory belongs to the caller and
    /// is never removed on teardown.
    pub fn create(allocator: std.mem.Allocator, browser_endpoint: []const u8, directory: []const u8) !*Tracker {
        if (directory.len == 0) return error.InvalidDownloadDirectory;
        const endpoint = try common.parseEndpoint(browser_endpoint, .cdp);
        if (!std.mem.startsWith(u8, endpoint.path, "/devtools/browser/")) return error.InvalidEndpoint;
        try compat.cwd().makePath(directory);
        const browser_directory = try compat.cwd().realpathAlloc(allocator, directory);
        defer allocator.free(browser_directory);
        const self = try allocator.create(Tracker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .directory = try allocator.dupe(u8, directory) };
        errdefer allocator.free(self.directory);
        self.client = try ws.Client.connect(allocator, endpoint.host, endpoint.port, endpoint.path);
        errdefer self.client.?.deinit();
        // Every receive waits on an outstanding heartbeat or command, never
        // on indefinite idleness. A dead browser therefore bounds teardown.
        self.client.?.receive_timeout_ms = 5_000;
        const escaped = try json_util.escapeJsonString(allocator, browser_directory);
        defer allocator.free(escaped);
        const params = try std.fmt.allocPrint(allocator, "{{\"behavior\":\"allowAndName\",\"downloadPath\":\"{s}\",\"eventsEnabled\":true}}", .{escaped});
        defer allocator.free(params);
        errdefer self.clearRecords();
        try self.command("Browser.setDownloadBehavior", params);
        errdefer self.command("Browser.setDownloadBehavior", "{\"behavior\":\"default\",\"eventsEnabled\":false}") catch {};
        self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *Tracker) void {
        self.stopping.store(true, .release);
        if (self.worker) |thread| thread.join();
        if (self.client) |*client| client.deinit();
        self.clearRecords();
        self.allocator.free(self.directory);
        self.allocator.destroy(self);
    }

    /// A snapshot owns its array and strings; release it with freeItems.
    /// A failed reader is an error, never an invented empty download list.
    pub fn list(self: *Tracker, allocator: std.mem.Allocator) ![]DownloadItem {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |err| return err;
        const items = try allocator.alloc(DownloadItem, self.records.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| {
                allocator.free(item.suggested_filename);
                allocator.free(item.save_path);
            }
            allocator.free(items);
        }
        for (self.records.items, items) |record, *item| {
            const filename = try allocator.dupe(u8, record.filename);
            errdefer allocator.free(filename);
            const path = try allocator.dupe(u8, record.path);
            item.* = .{ .suggested_filename = filename, .save_path = path, .completed = record.state == .completed, .canceled = record.state == .canceled };
            initialized += 1;
        }
        return items;
    }

    fn clearRecords(self: *Tracker) void {
        for (self.records.items) |record| {
            self.allocator.free(record.guid);
            self.allocator.free(record.filename);
            self.allocator.free(record.path);
        }
        self.records.deinit(self.allocator);
    }

    fn run(self: *Tracker) void {
        while (!self.stopping.load(.acquire)) {
            self.command("Browser.getVersion", "{}") catch |err| {
                self.mutex.lock();
                self.failure = err;
                self.mutex.unlock();
                return;
            };
            compat.sleepMs(50);
        }
        // Restore browser defaults from the sole socket-owning worker.
        self.command("Browser.setDownloadBehavior", "{\"behavior\":\"default\",\"eventsEnabled\":false}") catch {};
    }

    fn command(self: *Tracker, method: []const u8, params: []const u8) !void {
        const id = self.next_id;
        self.next_id += 1;
        const request = try rpc.encodeRequest(self.allocator, id, method, params);
        defer self.allocator.free(request);
        const client = if (self.client) |*client| client else return error.SessionNotReady;
        try client.sendText(request);
        const started = compat.milliTimestamp();
        while (true) {
            if (compat.milliTimestamp() - started > 5_000) return error.Timeout;
            const response = try client.recvText(self.allocator);
            defer self.allocator.free(response);
            var envelope = try rpc.decodeEnvelope(self.allocator, response);
            defer envelope.deinit(self.allocator);
            if (envelope.id) |response_id| {
                if (response_id != id) return error.InvalidResponse;
                if (envelope.has_error) return error.ProtocolCommandFailed;
                return;
            }
            try self.acceptEvent(response);
        }
    }

    fn acceptEvent(self: *Tracker, payload: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const method = try stringField(parsed.value.object, "method");
        const begin = std.mem.eql(u8, method, "Browser.downloadWillBegin");
        const progress = std.mem.eql(u8, method, "Browser.downloadProgress");
        if (!begin and !progress) return;
        const params = parsed.value.object.get("params") orelse return error.InvalidResponse;
        if (params != .object) return error.InvalidResponse;
        const guid = try stringField(params.object, "guid");
        if (guid.len == 0 or guid.len > 128) return error.InvalidResponse;
        for (guid) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '-') return error.InvalidResponse;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (begin) {
            const filename = try stringField(params.object, "suggestedFilename");
            for (self.records.items) |record| if (std.mem.eql(u8, record.guid, guid)) return;
            const owned_guid = try self.allocator.dupe(u8, guid);
            errdefer self.allocator.free(owned_guid);
            const owned_filename = try self.allocator.dupe(u8, filename);
            errdefer self.allocator.free(owned_filename);
            const path = try std.fs.path.join(self.allocator, &.{ self.directory, guid });
            errdefer self.allocator.free(path);
            try self.records.append(self.allocator, .{ .guid = owned_guid, .filename = owned_filename, .path = path });
        } else {
            const state = try stringField(params.object, "state");
            const next: @FieldType(Record, "state") = if (std.mem.eql(u8, state, "completed")) .completed else if (std.mem.eql(u8, state, "canceled")) .canceled else if (std.mem.eql(u8, state, "inProgress")) .in_progress else return error.InvalidResponse;
            for (self.records.items) |*record| {
                if (std.mem.eql(u8, record.guid, guid)) {
                    if (record.state == .in_progress) record.state = next;
                    return;
                }
            }
            // Existing downloads may predate this connection's subscription;
            // progress alone has no trustworthy suggested filename to publish.
        }
    }
};

pub fn freeItems(allocator: std.mem.Allocator, items: []DownloadItem) void {
    for (items) |item| {
        allocator.free(item.suggested_filename);
        allocator.free(item.save_path);
    }
    allocator.free(items);
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.InvalidResponse;
    if (value != .string) return error.InvalidResponse;
    return value.string;
}

test "download events preserve GUID identity and terminal states with independent snapshots" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{ .allocator = allocator, .directory = try allocator.dupe(u8, "downloads") };
    defer allocator.free(tracker.directory);
    defer tracker.clearRecords();
    try tracker.acceptEvent("{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"first-1\",\"suggestedFilename\":\"résumé.txt\"}}");
    const before = try tracker.list(allocator);
    defer freeItems(allocator, before);
    try std.testing.expect(!before[0].completed);
    try tracker.acceptEvent("{\"method\":\"Browser.downloadProgress\",\"params\":{\"guid\":\"first-1\",\"state\":\"completed\"}}");
    try tracker.acceptEvent("{\"method\":\"Browser.downloadProgress\",\"params\":{\"guid\":\"first-1\",\"state\":\"inProgress\"}}");
    try tracker.acceptEvent("{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"first-1\",\"suggestedFilename\":\"duplicate\"}}");
    try tracker.acceptEvent("{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"second-2\",\"suggestedFilename\":\"résumé.txt\"}}");
    try tracker.acceptEvent("{\"method\":\"Browser.downloadProgress\",\"params\":{\"guid\":\"second-2\",\"state\":\"canceled\"}}");
    const after = try tracker.list(allocator);
    defer freeItems(allocator, after);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expect(after[0].completed);
    try std.testing.expect(!before[0].completed);
    try std.testing.expect(after[1].canceled);
    try std.testing.expect(!after[1].completed);
    try std.testing.expectEqualStrings("résumé.txt", after[0].suggested_filename);
    const expected_path = try std.fs.path.join(allocator, &.{ "downloads", "first-1" });
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, after[0].save_path);
}

test "download parser refuses unsafe GUID paths and malformed events without publishing records" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{ .allocator = allocator, .directory = try allocator.dupe(u8, "downloads") };
    defer allocator.free(tracker.directory);
    defer tracker.clearRecords();
    for ([_][]const u8{
        "{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"../escape\",\"suggestedFilename\":\"x\"}}",
        "{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"\",\"suggestedFilename\":\"x\"}}",
        "{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"a\"}}",
        "{\"method\":\"Browser.downloadProgress\",\"params\":{\"guid\":\"a\",\"state\":\"invented\"}}",
    }) |payload| try std.testing.expectError(error.InvalidResponse, tracker.acceptEvent(payload));
    try std.testing.expectEqual(@as(usize, 0), tracker.records.items.len);
    tracker.failure = error.ConnectionClosed;
    try std.testing.expectError(error.ConnectionClosed, tracker.list(allocator));
}

test "download event and snapshot allocations roll back without leaks" {
    const Case = struct {
        fn exercise(allocator: std.mem.Allocator) !void {
            var tracker: Tracker = .{ .allocator = allocator, .directory = try allocator.dupe(u8, "downloads") };
            defer allocator.free(tracker.directory);
            defer tracker.clearRecords();
            try tracker.acceptEvent("{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"one\",\"suggestedFilename\":\"one.txt\"}}");
            try tracker.acceptEvent("{\"method\":\"Browser.downloadWillBegin\",\"params\":{\"guid\":\"two\",\"suggestedFilename\":\"two.txt\"}}");
            const items = try tracker.list(allocator);
            defer freeItems(allocator, items);
            try std.testing.expectEqual(@as(usize, 2), items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.exercise, .{});
}

test "download configuration rejects missing directory and nonbrowser endpoints" {
    try std.testing.expectError(error.InvalidDownloadDirectory, Tracker.create(std.testing.allocator, "ws://127.0.0.1:1/devtools/browser/test", ""));
    try std.testing.expectError(error.InvalidEndpoint, Tracker.create(std.testing.allocator, "ws://127.0.0.1:1/devtools/page/test", "downloads"));
}
