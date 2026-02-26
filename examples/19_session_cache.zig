const std = @import("std");
const driver = @import("alldriver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var store = try driver.SessionCacheStore.open(allocator, "/tmp/alldriver-session-cache-demo");
    defer store.deinit();

    var http_cookies = [_]driver.Cookie{.{
        .name = "sid",
        .value = "abc123",
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .http_only = true,
    }};

    try store.saveWithOptions(.{
        .domain = "example.com",
        .profile_key = "scraper-default",
        .user_agent = "Mozilla/5.0 demo",
        .cookies = http_cookies[0..],
        .captured_at_ms = @intCast(std.time.milliTimestamp()),
        .expires_at_ms = null,
        .schema_version = 1,
    }, 86_400_000, true, .{
        .preset = .http_session,
    });

    if (try store.load(allocator, "example.com", "scraper-default")) |loaded| {
        var entry = loaded;
        defer driver.session_cache.deinitEntry(allocator, &entry);
        std.debug.print("loaded HTTP session cache: cookies={d} ua={s}\n", .{ entry.cookies.len, entry.user_agent });
    }

    var rich_cookies = [_]driver.Cookie{.{
        .name = "sid",
        .value = "xyz999",
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .http_only = true,
    }};
    var rich_local = [_]driver.StorageValue{.{ .key = "token", .value = "v1" }};
    var rich_session = [_]driver.StorageValue{.{ .key = "nonce", .value = "n1" }};
    var rich_headers = [_]driver.Header{.{ .name = "x-demo", .value = "1" }};

    try store.saveWithOptions(.{
        .domain = "example.com",
        .profile_key = "scraper-rich",
        .user_agent = "Mozilla/5.0 demo",
        .cookies = rich_cookies[0..],
        .local_storage = rich_local[0..],
        .session_storage = rich_session[0..],
        .current_url = "https://example.com/app",
        .extra_headers = rich_headers[0..],
        .captured_at_ms = @intCast(std.time.milliTimestamp()),
        .expires_at_ms = null,
        .schema_version = 1,
    }, 86_400_000, true, .{
        .include = .{
            .cookies = true,
            .user_agent = true,
            .local_storage = true,
            .session_storage = false,
            .current_url = true,
            .extra_headers = true,
        },
    });

    if (try store.load(allocator, "example.com", "scraper-rich")) |loaded| {
        var entry = loaded;
        defer driver.session_cache.deinitEntry(allocator, &entry);
        std.debug.print(
            "loaded custom cache: cookies={d} local={d} session={d} url={s} headers={d}\n",
            .{
                entry.cookies.len,
                entry.local_storage.len,
                entry.session_storage.len,
                entry.current_url orelse "",
                entry.extra_headers.len,
            },
        );
    }
}
