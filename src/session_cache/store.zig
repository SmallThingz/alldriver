const std = @import("std");
const types = @import("../types.zig");
const compat = @import("../util/compat.zig");

const schema_version: u32 = 1;

pub const SessionCacheStore = struct {
    allocator: std.mem.Allocator,
    root_dir: []u8,

    pub fn open(allocator: std.mem.Allocator, root_dir: []const u8) !SessionCacheStore {
        try compat.cwd().makePath(root_dir);
        const owned_root = try compat.cwd().realpathAlloc(allocator, root_dir);
        errdefer allocator.free(owned_root);
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

        var entry = parseEntry(allocator, payload) catch |err| switch (err) {
            error.CorruptEntry, error.IncompatibleSchema => {
                _ = self.invalidate(domain, profile_key) catch {};
                return null;
            },
            else => return err,
        };
        errdefer deinitEntry(allocator, &entry);
        if (!std.mem.eql(u8, entry.domain, domain) or !std.mem.eql(u8, entry.profile_key, profile_key)) {
            _ = self.invalidate(domain, profile_key) catch {};
            deinitEntry(allocator, &entry);
            return null;
        }

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
        compat.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub fn cleanupExpired(self: *SessionCacheStore) !u32 {
        var dir = try compat.cwd().openDir(self.root_dir, .{ .iterate = true });
        defer dir.close(compat.io());

        var removed: u32 = 0;
        var it = dir.iterate();
        while (try it.next(compat.io())) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const file_path = try std.fs.path.join(self.allocator, &.{ self.root_dir, entry.name });
            defer self.allocator.free(file_path);

            const payload = readFileAlloc(self.allocator, file_path, 8 * 1024 * 1024) catch continue;
            defer self.allocator.free(payload);

            const expires = parseExpiresFromPayload(self.allocator, payload) catch |err| {
                if (err == error.OutOfMemory) return err;
                compat.cwd().deleteFile(file_path) catch continue;
                removed += 1;
                continue;
            };
            if (expires) |expires_at| {
                if (expires_at <= nowMs()) {
                    compat.cwd().deleteFile(file_path) catch continue;
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
    const expires_at = if (ttl_ms) |ttl| try std.math.add(u64, captured_at, ttl) else source.expires_at_ms;

    var selected = source;
    selected.captured_at_ms = captured_at;
    selected.expires_at_ms = expires_at;
    selected.schema_version = schema_version;
    if (!mask.user_agent) selected.user_agent = "";
    if (!mask.cookies) selected.cookies = &.{};
    if (!mask.local_storage) selected.local_storage = &.{};
    if (!mask.session_storage) selected.session_storage = &.{};
    if (!mask.current_url) selected.current_url = null;
    if (!mask.extra_headers) selected.extra_headers = &.{};
    return cloneOwned(types.SessionCacheEntry, allocator, selected);
}

fn serializeEntry(output_allocator: std.mem.Allocator, entry: types.SessionCacheEntry) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(output_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var root: std.json.ObjectMap = .empty;

    try root.put(allocator, "schema_version", .{ .integer = entry.schema_version });
    try root.put(allocator, "domain", .{ .string = entry.domain });
    try root.put(allocator, "profile_key", .{ .string = entry.profile_key });
    try root.put(allocator, "captured_at_ms", .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{entry.captured_at_ms}) });
    if (entry.expires_at_ms) |expires_at| {
        try root.put(allocator, "expires_at_ms", .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{expires_at}) });
    } else {
        try root.put(allocator, "expires_at_ms", .null);
    }
    try root.put(allocator, "user_agent", .{ .string = entry.user_agent });
    try root.put(allocator, "cookies", try cookiesToJson(allocator, entry.cookies));
    try root.put(allocator, "local_storage", try storageToJson(allocator, entry.local_storage));
    try root.put(allocator, "session_storage", try storageToJson(allocator, entry.session_storage));
    if (entry.current_url) |url| {
        try root.put(allocator, "current_url", .{ .string = url });
    } else {
        try root.put(allocator, "current_url", .null);
    }
    try root.put(allocator, "extra_headers", try headersToJson(allocator, entry.extra_headers));

    return std.json.Stringify.valueAlloc(output_allocator, std.json.Value{ .object = root }, .{});
}

fn parseEntry(output_allocator: std.mem.Allocator, payload: []const u8) !types.SessionCacheEntry {
    var arena = std.heap.ArenaAllocator.init(output_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptEntry,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.CorruptEntry;
    const obj = parsed.value.object;
    if (obj.get("expires_at_ms")) |expires| {
        if (expires != .null and intFieldAsU64(obj, "expires_at_ms") == null) return error.CorruptEntry;
    }
    if (obj.get("captured_at_ms")) |_| {
        if (intFieldAsU64(obj, "captured_at_ms") == null) return error.CorruptEntry;
    }

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
    return cloneOwned(types.SessionCacheEntry, output_allocator, entry);
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
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(domain);
    hasher.update(&[_]u8{0});
    hasher.update(profile_key);
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{digest_hex[0..]});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ root_dir, file_name });
}

fn atomicWriteFile(path: []const u8, data: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse ".";
    try compat.cwd().makePath(dir_name);

    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp.{d}", .{ path, compat.nanoTimestamp() });
    defer std.heap.page_allocator.free(tmp_path);

    errdefer compat.cwd().deleteFile(tmp_path) catch {};
    try compat.cwd().writeFile(.{
        .sub_path = tmp_path,
        .data = data,
    });
    try compat.cwd().rename(tmp_path, path);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    return compat.cwd().readFileAlloc(allocator, path, max_size);
}

fn parseExpiresFromPayload(allocator: std.mem.Allocator, payload: []const u8) !?u64 {
    var entry = try parseEntry(allocator, payload);
    defer deinitEntry(allocator, &entry);
    return entry.expires_at_ms;
}

fn nowMs() u64 {
    const ts = compat.milliTimestamp();
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
                truncated >= @as(f64, @floatFromInt(std.math.maxInt(i64))))
            {
                break :blk null;
            }
            break :blk @intFromFloat(truncated);
        },
        else => null,
    };
}

fn intFieldAsU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    if (obj.get(key)) |value| {
        if (value == .number_string) return std.fmt.parseInt(u64, value.number_string, 10) catch null;
    }
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
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = cookie.name });
        try obj.put(allocator, "value", .{ .string = cookie.value });
        try obj.put(allocator, "domain", .{ .string = cookie.domain });
        try obj.put(allocator, "path", .{ .string = cookie.path });
        try obj.put(allocator, "secure", .{ .bool = cookie.secure });
        try obj.put(allocator, "httpOnly", .{ .bool = cookie.http_only });
        if (cookie.expires_unix_seconds) |expires| {
            try obj.put(allocator, "expires", .{ .integer = expires });
        } else {
            try obj.put(allocator, "expires", .null);
        }
        try obj.put(allocator, "sameSite", .{ .string = @tagName(cookie.same_site) });
        try arr.append(allocator, .{ .object = obj });
    }
    return .{ .array = .{ .items = try arr.toOwnedSlice(allocator), .capacity = arr.items.len, .allocator = allocator } };
}

fn storageToJson(allocator: std.mem.Allocator, values: []const types.StorageValue) !std.json.Value {
    var arr = std.ArrayList(std.json.Value).empty;
    defer arr.deinit(allocator);
    for (values) |item| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "key", .{ .string = item.key });
        try obj.put(allocator, "value", .{ .string = item.value });
        try arr.append(allocator, .{ .object = obj });
    }
    return .{ .array = .{ .items = try arr.toOwnedSlice(allocator), .capacity = arr.items.len, .allocator = allocator } };
}

fn headersToJson(allocator: std.mem.Allocator, headers: []const types.Header) !std.json.Value {
    var arr = std.ArrayList(std.json.Value).empty;
    defer arr.deinit(allocator);
    for (headers) |h| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = h.name });
        try obj.put(allocator, "value", .{ .string = h.value });
        try arr.append(allocator, .{ .object = obj });
    }
    return .{ .array = .{ .items = try arr.toOwnedSlice(allocator), .capacity = arr.items.len, .allocator = allocator } };
}

fn parseCookies(allocator: std.mem.Allocator, value: std.json.Value) ![]types.Cookie {
    if (value != .array) return error.CorruptEntry;
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
        if (item != .object) return error.CorruptEntry;
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
            .name = try allocator.dupe(u8, getStringField(obj, "name") orelse return error.CorruptEntry),
            .value = try allocator.dupe(u8, getStringField(obj, "value") orelse return error.CorruptEntry),
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
    if (value != .array) return error.CorruptEntry;
    var out: std.ArrayList(types.StorageValue) = .empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.key);
            allocator.free(item.value);
        }
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .object) return error.CorruptEntry;
        const obj = item.object;
        try out.append(allocator, .{
            .key = try allocator.dupe(u8, getStringField(obj, "key") orelse return error.CorruptEntry),
            .value = try allocator.dupe(u8, getStringField(obj, "value") orelse return error.CorruptEntry),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseHeaders(allocator: std.mem.Allocator, value: std.json.Value) ![]types.Header {
    if (value != .array) return error.CorruptEntry;
    var out: std.ArrayList(types.Header) = .empty;
    errdefer {
        for (out.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        out.deinit(allocator);
    }
    for (value.array.items) |item| {
        if (item != .object) return error.CorruptEntry;
        const obj = item.object;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, getStringField(obj, "name") orelse return error.CorruptEntry),
            .value = try allocator.dupe(u8, getStringField(obj, "value") orelse return error.CorruptEntry),
        });
    }
    return out.toOwnedSlice(allocator);
}

// Clone with cleanup at every partially initialized aggregate boundary.
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
        .optional => |info| if (value) |item| {
            freeOwned(info.child, allocator, item);
        },
        else => {},
    }
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
        .cookies = @constCast(&[_]types.Cookie{.{
            .name = "sid",
            .value = "abc",
            .domain = "example.com",
            .path = "/",
        }}),
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

test "session cache load rejects mismatched identity payload" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "cache-identity" });
    defer allocator.free(root);

    var store = try SessionCacheStore.open(allocator, root);
    defer store.deinit();

    const path = try cachePathFor(allocator, store.root_dir, "example.com", "default");
    defer allocator.free(path);

    const payload =
        \\{"schema_version":1,"domain":"wrong.example","profile_key":"default","captured_at_ms":1,"expires_at_ms":null,"user_agent":"ua","cookies":[],"local_storage":[],"session_storage":[],"current_url":null,"extra_headers":[]}
    ;
    try atomicWriteFile(path, payload);

    const loaded = try store.load(allocator, "example.com", "default");
    try std.testing.expect(loaded == null);
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
    compat.sleepMs(5);

    const loaded = try store.load(allocator, "expired.example", "p");
    try std.testing.expect(loaded == null);
}

fn richFixture() types.SessionCacheEntry {
    return .{
        .domain = "example.com",
        .profile_key = "profile",
        .user_agent = "Agent",
        .cookies = @constCast(&[_]types.Cookie{.{ .name = "session", .value = "quoted\"\nvalue", .domain = ".example.com", .path = "/private", .secure = true, .http_only = false, .same_site = .strict, .expires_unix_seconds = 123456789 }}),
        .local_storage = @constCast(&[_]types.StorageValue{.{ .key = "local", .value = "λ" }}),
        .session_storage = @constCast(&[_]types.StorageValue{.{ .key = "session", .value = "value" }}),
        .current_url = "https://example.com/private",
        .extra_headers = @constCast(&[_]types.Header{.{ .name = "X-Test", .value = "yes" }}),
        .captured_at_ms = 1234,
        .expires_at_ms = null,
        .schema_version = schema_version,
    };
}

fn allocationRoundtrip(allocator: std.mem.Allocator) !void {
    var saved = try materializeEntryForSave(allocator, richFixture(), 1000, .{ .preset = .rich_state });
    defer deinitEntry(allocator, &saved);
    const bytes = try serializeEntry(allocator, saved);
    defer allocator.free(bytes);
    var loaded = try parseEntry(allocator, bytes);
    defer deinitEntry(allocator, &loaded);
    try std.testing.expectEqualDeep(saved, loaded);
}

test "rich session payload roundtrips every field with allocation failures" {
    try allocationRoundtrip(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRoundtrip, .{});
}

test "cache rejects malformed JSON and malformed nested payloads without leaks" {
    for ([_][]const u8{
        "{",                                                                                                    "[]",
        "{\"schema_version\":1,\"domain\":\"x\"}",                                                              "{\"schema_version\":1,\"domain\":\"x\",\"profile_key\":\"p\",\"cookies\":[1]}",
        "{\"schema_version\":1,\"domain\":\"x\",\"profile_key\":\"p\",\"local_storage\":[{\"key\":\"x\"}]}",    "{\"schema_version\":1,\"domain\":\"x\",\"profile_key\":\"p\",\"expires_at_ms\":-1}",
        "{\"schema_version\":1,\"domain\":\"x\",\"profile_key\":\"p\",\"expires_at_ms\":9.223372036854776e18}",
    }) |payload| {
        try std.testing.expectError(error.CorruptEntry, parseEntry(std.testing.allocator, payload));
    }
}

test "cache masks omit data and TTL overflow is an error" {
    var saved = try materializeEntryForSave(std.testing.allocator, richFixture(), null, .{ .preset = .minimal });
    defer deinitEntry(std.testing.allocator, &saved);
    try std.testing.expectEqual(@as(usize, 1), saved.cookies.len);
    try std.testing.expectEqualStrings("", saved.user_agent);
    try std.testing.expectEqual(@as(usize, 0), saved.local_storage.len);
    try std.testing.expectEqual(@as(usize, 0), saved.session_storage.len);
    try std.testing.expectEqual(@as(usize, 0), saved.extra_headers.len);
    try std.testing.expect(saved.current_url == null);
    try std.testing.expectError(error.Overflow, materializeEntryForSave(std.testing.allocator, richFixture(), std.math.maxInt(u64), .{}));
}

test "cache timestamp serialization preserves full unsigned range" {
    var fixture = richFixture();
    fixture.captured_at_ms = std.math.maxInt(u64);
    fixture.expires_at_ms = std.math.maxInt(u64);
    const bytes = try serializeEntry(std.testing.allocator, fixture);
    defer std.testing.allocator.free(bytes);
    var parsed = try parseEntry(std.testing.allocator, bytes);
    defer deinitEntry(std.testing.allocator, &parsed);
    try std.testing.expectEqual(fixture.captured_at_ms, parsed.captured_at_ms);
    try std.testing.expectEqual(fixture.expires_at_ms, parsed.expires_at_ms);
}

test "cache disk refresh corruption cleanup and invalidation contracts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "contracts" });
    defer allocator.free(root);
    var store = try SessionCacheStore.open(allocator, root);
    defer store.deinit();
    var fixture = richFixture();
    try store.saveWithOptions(fixture, null, true, .{ .preset = .rich_state });
    fixture.user_agent = "replacement";
    try store.saveWithOptions(fixture, null, false, .{ .preset = .rich_state });
    var original = (try store.load(allocator, fixture.domain, fixture.profile_key)).?;
    defer deinitEntry(allocator, &original);
    try std.testing.expectEqualStrings("Agent", original.user_agent);
    try std.testing.expectEqualDeep(richFixture().local_storage, original.local_storage);
    try store.save(fixture, null, true);
    var refreshed = (try store.load(allocator, fixture.domain, fixture.profile_key)).?;
    defer deinitEntry(allocator, &refreshed);
    try std.testing.expectEqualStrings("replacement", refreshed.user_agent);
    try std.testing.expectEqual(@as(usize, 0), refreshed.local_storage.len);
    const path = try cachePathFor(allocator, store.root_dir, fixture.domain, fixture.profile_key);
    defer allocator.free(path);
    try atomicWriteFile(path, "{");
    try std.testing.expect((try store.load(allocator, fixture.domain, fixture.profile_key)) == null);
    try std.testing.expect(!(try store.invalidate(fixture.domain, fixture.profile_key)));
    try atomicWriteFile(path, "[]");
    try std.testing.expectEqual(@as(u32, 1), try store.cleanupExpired());
    try store.save(fixture, 0, true);
    try std.testing.expectEqual(@as(u32, 1), try store.cleanupExpired());
    try store.save(fixture, null, true);
    try std.testing.expectEqual(@as(u32, 0), try store.cleanupExpired());
    try std.testing.expect(try store.invalidate(fixture.domain, fixture.profile_key));
    try std.testing.expect(!(try store.invalidate(fixture.domain, fixture.profile_key)));
}
