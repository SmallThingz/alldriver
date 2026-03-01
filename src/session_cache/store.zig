const std = @import("std");
const types = @import("../types.zig");

const schema_version: u32 = 1;

pub const SessionCacheStore = struct {
    allocator: std.mem.Allocator,
    root_dir: []u8,

    pub fn open(allocator: std.mem.Allocator, root_dir: []const u8) !SessionCacheStore {
        const owned_root = try allocator.dupe(u8, root_dir);
        errdefer allocator.free(owned_root);
        try std.fs.cwd().makePath(owned_root);
        return .{
            .allocator = allocator,
            .root_dir = owned_root,
        };
    }

    pub fn deinit(self: *SessionCacheStore) void {
        self.allocator.free(self.root_dir);
        self.* = undefined;
    }

    pub fn load(
        self: *SessionCacheStore,
        allocator: std.mem.Allocator,
        domain: []const u8,
        profile_key: []const u8,
    ) !?types.SessionCacheEntry {
        const path = try cachePathFor(self.allocator, self.root_dir, domain, profile_key);
        defer self.allocator.free(path);

        const payload = readFileAlloc(allocator, path, 8 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(payload);

        var entry = try parseEntry(allocator, payload);
        errdefer deinitEntry(allocator, &entry);

        if (entry.expires_at_ms) |expires_at| {
            if (expires_at <= nowMs()) {
                _ = self.invalidate(domain, profile_key) catch {};
                deinitEntry(allocator, &entry);
                return null;
            }
        }

        return entry;
    }

    pub fn save(
        self: *SessionCacheStore,
        entry: types.SessionCacheEntry,
        ttl_ms: ?u64,
        force_refresh: bool,
    ) !void {
        try self.saveWithOptions(entry, ttl_ms, force_refresh, .{});
    }

    pub fn saveWithOptions(
        self: *SessionCacheStore,
        entry: types.SessionCacheEntry,
        ttl_ms: ?u64,
        force_refresh: bool,
        options: types.SessionCacheOptions,
    ) !void {
        const path = try cachePathFor(self.allocator, self.root_dir, entry.domain, entry.profile_key);
        defer self.allocator.free(path);

        if (!force_refresh) {
            if (try self.load(self.allocator, entry.domain, entry.profile_key)) |existing| {
                var mutable = existing;
                deinitEntry(self.allocator, &mutable);
                return;
            }
        }

        var materialized = try materializeEntryForSave(self.allocator, entry, ttl_ms, options);
        defer deinitEntry(self.allocator, &materialized);

        const payload = try serializeEntry(self.allocator, materialized);
        defer self.allocator.free(payload);

        try atomicWriteFile(path, payload);
    }

    pub fn invalidate(
        self: *SessionCacheStore,
        domain: []const u8,
        profile_key: []const u8,
    ) !bool {
        const path = try cachePathFor(self.allocator, self.root_dir, domain, profile_key);
        defer self.allocator.free(path);
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub fn cleanupExpired(self: *SessionCacheStore) !u32 {
        var dir = try std.fs.cwd().openDir(self.root_dir, .{ .iterate = true });
        defer dir.close();

        var removed: u32 = 0;
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const file_path = try std.fs.path.join(self.allocator, &.{ self.root_dir, entry.name });
            defer self.allocator.free(file_path);

            const payload = readFileAlloc(self.allocator, file_path, 8 * 1024 * 1024) catch continue;
            defer self.allocator.free(payload);

            const expires = parseExpiresFromPayload(self.allocator, payload) catch continue;
            if (expires) |expires_at| {
                if (expires_at <= nowMs()) {
                    std.fs.cwd().deleteFile(file_path) catch continue;
                    removed += 1;
                }
            }
        }

        return removed;
    }
};

pub fn deinitEntry(allocator: std.mem.Allocator, entry: *types.SessionCacheEntry) void {
    allocator.free(entry.domain);
    allocator.free(entry.profile_key);
    allocator.free(entry.user_agent);

    for (entry.cookies) |cookie| {
        allocator.free(cookie.name);
        allocator.free(cookie.value);
        allocator.free(cookie.domain);
        allocator.free(cookie.path);
    }
    allocator.free(entry.cookies);

    for (entry.local_storage) |item| {
        allocator.free(item.key);
        allocator.free(item.value);
    }
    allocator.free(entry.local_storage);

    for (entry.session_storage) |item| {
        allocator.free(item.key);
        allocator.free(item.value);
    }
    allocator.free(entry.session_storage);

    if (entry.current_url) |url| allocator.free(url);

    for (entry.extra_headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(entry.extra_headers);

    entry.* = undefined;
}

fn materializeEntryForSave(
    allocator: std.mem.Allocator,
    source: types.SessionCacheEntry,
    ttl_ms: ?u64,
    options: types.SessionCacheOptions,
) !types.SessionCacheEntry {
    const mask = resolveMask(options);
    const captured_at = if (source.captured_at_ms == 0) nowMs() else source.captured_at_ms;
    const expires_at = if (ttl_ms) |ttl| captured_at + ttl else source.expires_at_ms;

    var out: types.SessionCacheEntry = .{
        .domain = try allocator.dupe(u8, source.domain),
        .profile_key = try allocator.dupe(u8, source.profile_key),
        .user_agent = if (mask.user_agent) try allocator.dupe(u8, source.user_agent) else try allocator.dupe(u8, ""),
        .cookies = if (mask.cookies) try cloneCookies(allocator, source.cookies) else try allocator.alloc(types.Cookie, 0),
        .local_storage = if (mask.local_storage) try cloneStorageValues(allocator, source.local_storage) else try allocator.alloc(types.StorageValue, 0),
        .session_storage = if (mask.session_storage) try cloneStorageValues(allocator, source.session_storage) else try allocator.alloc(types.StorageValue, 0),
        .current_url = if (mask.current_url and source.current_url != null) try allocator.dupe(u8, source.current_url.?) else null,
        .extra_headers = if (mask.extra_headers) try cloneHeaders(allocator, source.extra_headers) else try allocator.alloc(types.Header, 0),
        .captured_at_ms = captured_at,
        .expires_at_ms = expires_at,
        .schema_version = schema_version,
    };
    errdefer deinitEntry(allocator, &out);
    return out;
}

fn serializeEntry(allocator: std.mem.Allocator, entry: types.SessionCacheEntry) ![]u8 {
    var root = std.json.ObjectMap.init(allocator);
    defer root.deinit();

    try root.put("schema_version", .{ .integer = entry.schema_version });
    try root.put("domain", .{ .string = entry.domain });
    try root.put("profile_key", .{ .string = entry.profile_key });
    try root.put("captured_at_ms", .{ .integer = @intCast(entry.captured_at_ms) });
    if (entry.expires_at_ms) |expires_at| {
        try root.put("expires_at_ms", .{ .integer = @intCast(expires_at) });
    } else {
        try root.put("expires_at_ms", .null);
    }
    try root.put("user_agent", .{ .string = entry.user_agent });
    try root.put("cookies", try cookiesToJson(allocator, entry.cookies));
    try root.put("local_storage", try storageToJson(allocator, entry.local_storage));
    try root.put("session_storage", try storageToJson(allocator, entry.session_storage));
    if (entry.current_url) |url| {
        try root.put("current_url", .{ .string = url });
    } else {
        try root.put("current_url", .null);
    }
    try root.put("extra_headers", try headersToJson(allocator, entry.extra_headers));

    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{});
}

fn parseEntry(allocator: std.mem.Allocator, payload: []const u8) !types.SessionCacheEntry {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.CorruptEntry;
    const obj = parsed.value.object;

    const schema = getIntField(obj, "schema_version") orelse return error.CorruptEntry;
    if (schema < 0 or schema > std.math.maxInt(u32)) return error.IncompatibleSchema;
    if (schema != schema_version) return error.IncompatibleSchema;

    var entry: types.SessionCacheEntry = .{
        .domain = try allocator.dupe(u8, getStringField(obj, "domain") orelse return error.CorruptEntry),
        .profile_key = try allocator.dupe(u8, getStringField(obj, "profile_key") orelse return error.CorruptEntry),
        .user_agent = try allocator.dupe(u8, getStringField(obj, "user_agent") orelse ""),
        .cookies = if (obj.get("cookies")) |value| try parseCookies(allocator, value) else try allocator.alloc(types.Cookie, 0),
        .local_storage = if (obj.get("local_storage")) |value|
            try parseStorageValues(allocator, value)
        else
            try allocator.alloc(types.StorageValue, 0),
        .session_storage = if (obj.get("session_storage")) |value|
            try parseStorageValues(allocator, value)
        else
            try allocator.alloc(types.StorageValue, 0),
        .current_url = if (getStringField(obj, "current_url")) |url| try allocator.dupe(u8, url) else null,
        .extra_headers = if (obj.get("extra_headers")) |value| try parseHeaders(allocator, value) else try allocator.alloc(types.Header, 0),
        .captured_at_ms = intFieldAsU64(obj, "captured_at_ms") orelse 0,
        .expires_at_ms = intFieldAsU64(obj, "expires_at_ms"),
        .schema_version = @intCast(schema),
    };
    errdefer deinitEntry(allocator, &entry);
    return entry;
}

fn resolveMask(options: types.SessionCacheOptions) types.SessionCachePayloadMask {
    var mask: types.SessionCachePayloadMask = switch (options.preset orelse .http_session) {
        .minimal => .{
            .cookies = true,
            .user_agent = false,
        },
        .http_session => .{
            .cookies = true,
            .user_agent = true,
        },
        .rich_state => .{
            .cookies = true,
            .user_agent = true,
            .local_storage = true,
            .session_storage = true,
            .current_url = true,
            .extra_headers = true,
        },
    };
    if (options.include) |include| mask = include;
    return mask;
}

fn cachePathFor(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    domain: []const u8,
    profile_key: []const u8,
) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(domain);
    hasher.update("|");
    hasher.update(profile_key);
    const key = hasher.final();
    const file_name = try std.fmt.allocPrint(allocator, "{x}.json", .{key});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ root_dir, file_name });
}

fn atomicWriteFile(path: []const u8, data: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir_name);

    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp.{d}", .{ path, std.time.nanoTimestamp() });
    defer std.heap.page_allocator.free(tmp_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = tmp_path,
        .data = data,
    });
    try std.fs.cwd().rename(tmp_path, path);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_size);
}

fn parseExpiresFromPayload(allocator: std.mem.Allocator, payload: []const u8) !?u64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    return intFieldAsU64(parsed.value.object, "expires_at_ms");
}

fn nowMs() u64 {
    const ts = std.time.milliTimestamp();
    if (ts <= 0) return 0;
    return @intCast(ts);
}

fn getStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getIntField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |n| blk: {
            if (!std.math.isFinite(n)) break :blk null;
            const truncated = @trunc(n);
            if (truncated != n) break :blk null;
            if (truncated < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                truncated > @as(f64, @floatFromInt(std.math.maxInt(i64))))
            {
                break :blk null;
            }
            break :blk @intFromFloat(truncated);
        },
        else => null,
    };
}

fn intFieldAsU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const raw = getIntField(obj, key) orelse return null;
    if (raw < 0) return null;
    return std.math.cast(u64, raw);
}

fn getBoolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn cookiesToJson(allocator: std.mem.Allocator, cookies: []const types.Cookie) !std.json.Value {
    var arr = std.ArrayList(std.json.Value).empty;
    defer arr.deinit(allocator);
    for (cookies) |cookie| {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("name", .{ .string = cookie.name });
        try obj.put("value", .{ .string = cookie.value });
        try obj.put("domain", .{ .string = cookie.domain });
        try obj.put("path", .{ .string = cookie.path });
        try obj.put("secure", .{ .bool = cookie.secure });
        try obj.put("httpOnly", .{ .bool = cookie.http_only });
        if (cookie.expires_unix_seconds) |expires| {
            try obj.put("expires", .{ .integer = expires });
        } else {
            try obj.put("expires", .null);
        }
        try obj.put("sameSite", .{ .string = @tagName(cookie.same_site) });
        try arr.append(allocator, .{ .object = obj });
    }
    return .{ .array = .{ .items = try arr.toOwnedSlice(allocator), .capacity = arr.items.len, .allocator = allocator } };
}

fn storageToJson(allocator: std.mem.Allocator, values: []const types.StorageValue) !std.json.Value {
    var arr = std.ArrayList(std.json.Value).empty;
    defer arr.deinit(allocator);
    for (values) |item| {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("key", .{ .string = item.key });
        try obj.put("value", .{ .string = item.value });
        try arr.append(allocator, .{ .object = obj });
    }
    return .{ .array = .{ .items = try arr.toOwnedSlice(allocator), .capacity = arr.items.len, .allocator = allocator } };
}

fn headersToJson(allocator: std.mem.Allocator, headers: []const types.Header) !std.json.Value {
    var arr = std.ArrayList(std.json.Value).empty;
    defer arr.deinit(allocator);
    for (headers) |h| {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("name", .{ .string = h.name });
        try obj.put("value", .{ .string = h.value });
        try arr.append(allocator, .{ .object = obj });
    }
    return .{ .array = .{ .items = try arr.toOwnedSlice(allocator), .capacity = arr.items.len, .allocator = allocator } };
}

fn parseCookies(allocator: std.mem.Allocator, value: std.json.Value) ![]types.Cookie {
    if (value != .array) return allocator.alloc(types.Cookie, 0);
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
    for (value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const raw_same_site = getStringField(obj, "sameSite") orelse "unspecified";
        const same_site: types.CookieSameSite = if (std.ascii.eqlIgnoreCase(raw_same_site, "strict"))
            .strict
        else if (std.ascii.eqlIgnoreCase(raw_same_site, "lax"))
            .lax
        else if (std.ascii.eqlIgnoreCase(raw_same_site, "none"))
            .none
        else
            .unspecified;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, getStringField(obj, "name") orelse ""),
            .value = try allocator.dupe(u8, getStringField(obj, "value") orelse ""),
            .domain = try allocator.dupe(u8, getStringField(obj, "domain") orelse ""),
            .path = try allocator.dupe(u8, getStringField(obj, "path") orelse "/"),
            .secure = getBoolField(obj, "secure") orelse false,
            .http_only = getBoolField(obj, "httpOnly") orelse true,
            .expires_unix_seconds = getIntField(obj, "expires"),
            .same_site = same_site,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseStorageValues(allocator: std.mem.Allocator, value: std.json.Value) ![]types.StorageValue {
    if (value != .array) return allocator.alloc(types.StorageValue, 0);
    var out: std.ArrayList(types.StorageValue) = .empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.key);
            allocator.free(item.value);
        }
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        try out.append(allocator, .{
            .key = try allocator.dupe(u8, getStringField(obj, "key") orelse ""),
            .value = try allocator.dupe(u8, getStringField(obj, "value") orelse ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseHeaders(allocator: std.mem.Allocator, value: std.json.Value) ![]types.Header {
    if (value != .array) return allocator.alloc(types.Header, 0);
    var out: std.ArrayList(types.Header) = .empty;
    errdefer {
        for (out.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, getStringField(obj, "name") orelse ""),
            .value = try allocator.dupe(u8, getStringField(obj, "value") orelse ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneCookies(allocator: std.mem.Allocator, src: []const types.Cookie) ![]types.Cookie {
    const out = try allocator.alloc(types.Cookie, src.len);
    var initialized: usize = 0;
    errdefer {
        var idx: usize = 0;
        while (idx < initialized) : (idx += 1) {
            allocator.free(out[idx].name);
            allocator.free(out[idx].value);
            allocator.free(out[idx].domain);
            allocator.free(out[idx].path);
        }
        allocator.free(out);
    }
    for (src, 0..) |cookie, idx| {
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
        initialized += 1;
    }
    return out;
}

fn cloneStorageValues(allocator: std.mem.Allocator, src: []const types.StorageValue) ![]types.StorageValue {
    const out = try allocator.alloc(types.StorageValue, src.len);
    var initialized: usize = 0;
    errdefer {
        var idx: usize = 0;
        while (idx < initialized) : (idx += 1) {
            allocator.free(out[idx].key);
            allocator.free(out[idx].value);
        }
        allocator.free(out);
    }
    for (src, 0..) |item, idx| {
        out[idx] = .{
            .key = try allocator.dupe(u8, item.key),
            .value = try allocator.dupe(u8, item.value),
        };
        initialized += 1;
    }
    return out;
}

fn cloneHeaders(allocator: std.mem.Allocator, src: []const types.Header) ![]types.Header {
    const out = try allocator.alloc(types.Header, src.len);
    var initialized: usize = 0;
    errdefer {
        var idx: usize = 0;
        while (idx < initialized) : (idx += 1) {
            allocator.free(out[idx].name);
            allocator.free(out[idx].value);
        }
        allocator.free(out);
    }
    for (src, 0..) |h, idx| {
        out[idx] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value),
        };
        initialized += 1;
    }
    return out;
}

test "session cache round-trip load/save" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "cache-store" });
    defer allocator.free(root);

    var store = try SessionCacheStore.open(allocator, root);
    defer store.deinit();

    const entry: types.SessionCacheEntry = .{
        .domain = "example.com",
        .profile_key = "default",
        .user_agent = "UA",
        .cookies = &.{.{
            .name = "sid",
            .value = "abc",
            .domain = "example.com",
            .path = "/",
        }},
        .captured_at_ms = nowMs(),
        .expires_at_ms = null,
        .schema_version = schema_version,
    };

    try store.save(entry, null, true);
    const loaded = try store.load(allocator, "example.com", "default");
    try std.testing.expect(loaded != null);
    var mutable = loaded.?;
    defer deinitEntry(allocator, &mutable);
    try std.testing.expectEqualStrings("example.com", mutable.domain);
    try std.testing.expectEqual(@as(usize, 1), mutable.cookies.len);
}

test "session cache payload mask supports custom combos" {
    const mask = resolveMask(.{
        .preset = .minimal,
        .include = .{
            .cookies = true,
            .user_agent = true,
            .local_storage = true,
            .session_storage = false,
            .current_url = true,
            .extra_headers = false,
        },
    });
    try std.testing.expect(mask.cookies);
    try std.testing.expect(mask.user_agent);
    try std.testing.expect(mask.local_storage);
    try std.testing.expect(!mask.session_storage);
    try std.testing.expect(mask.current_url);
    try std.testing.expect(!mask.extra_headers);
}

test "session cache ttl expiry invalidates on load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "cache-expiry" });
    defer allocator.free(root);

    var store = try SessionCacheStore.open(allocator, root);
    defer store.deinit();

    const entry: types.SessionCacheEntry = .{
        .domain = "expired.example",
        .profile_key = "p",
        .user_agent = "ua",
        .cookies = &.{},
        .captured_at_ms = nowMs(),
        .expires_at_ms = null,
        .schema_version = schema_version,
    };
    try store.save(entry, 1, true);
    std.Thread.sleep(5 * std.time.ns_per_ms);

    const loaded = try store.load(allocator, "expired.example", "p");
    try std.testing.expect(loaded == null);
}
