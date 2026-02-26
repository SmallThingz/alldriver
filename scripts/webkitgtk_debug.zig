const std = @import("std");

const TestCase = struct {
    name: []const u8,
    capabilities_json: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cases = [_]TestCase{
        .{
            .name = "Test 1: No Browser Options (Auto)",
            .capabilities_json = "{\"capabilities\":{\"alwaysMatch\":{\"acceptInsecureCerts\":true},\"firstMatch\":[{}]}}",
        },
        .{
            .name = "Test 2: Binary Specified",
            .capabilities_json = "{\"capabilities\":{\"alwaysMatch\":{\"acceptInsecureCerts\":true,\"webkitgtk:browserOptions\":{\"binary\":\"/usr/lib/webkitgtk-6.0/MiniBrowser\"}},\"firstMatch\":[{}]}}",
        },
        .{
            .name = "Test 3: Binary + Automation",
            .capabilities_json = "{\"capabilities\":{\"alwaysMatch\":{\"acceptInsecureCerts\":true,\"webkitgtk:browserOptions\":{\"binary\":\"/usr/lib/webkitgtk-6.0/MiniBrowser\",\"args\":[\"--automation\"]}},\"firstMatch\":[{}]}}",
        },
    };

    for (cases) |tc| {
        std.debug.print("\n--- {s} ---\n", .{tc.name});
        try runCase(allocator, tc.capabilities_json);
    }
}

fn runCase(allocator: std.mem.Allocator, caps_json: []const u8) !void {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1");

    var driver = std.process.Child.init(&.{ "WebKitWebDriver", "--port=4450", "--host=127.0.0.1" }, allocator);
    driver.stdin_behavior = .Ignore;
    driver.stdout_behavior = .Ignore;
    driver.stderr_behavior = .Ignore;
    driver.env_map = &env_map;
    try driver.spawn();
    defer {
        _ = driver.kill() catch {};
        _ = driver.wait() catch {};
    }

    std.Thread.sleep(1 * std.time.ns_per_s);

    std.debug.print("Testing payload: {s}\n", .{caps_json});

    const create_cmd = try std.fmt.allocPrint(
        allocator,
        "curl -sS -X POST http://127.0.0.1:4450/session -H 'Content-Type: application/json' --data '{s}'",
        .{caps_json},
    );
    defer allocator.free(create_cmd);

    const create_out = runShellCapture(allocator, create_cmd) catch |err| {
        std.debug.print("Error during session create: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(create_out);

    const sid = parseSessionId(allocator, create_out) orelse {
        std.debug.print("Session failed: {s}\n", .{create_out});
        return;
    };
    defer allocator.free(sid);
    std.debug.print("Session created. SID: {s}\n", .{sid});

    const nav_cmd = try std.fmt.allocPrint(
        allocator,
        "curl -sS -o /dev/null -w '%{{http_code}}' -X POST http://127.0.0.1:4450/session/{s}/url -H 'Content-Type: application/json' --data '{\"url\":\"https://example.com/\"}'",
        .{sid},
    );
    defer allocator.free(nav_cmd);
    const nav_code = runShellCapture(allocator, nav_cmd) catch |err| {
        std.debug.print("Nav command failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(nav_code);
    std.debug.print("Nav command: {s}\n", .{std.mem.trim(u8, nav_code, " \r\n\t")});

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const url_cmd = try std.fmt.allocPrint(
            allocator,
            "curl -sS http://127.0.0.1:4450/session/{s}/url",
            .{sid},
        );
        defer allocator.free(url_cmd);

        const url_out = runShellCapture(allocator, url_cmd) catch |err| {
            std.debug.print("url check failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(url_out);

        if (parseValueString(allocator, url_out)) |current_url| {
            defer allocator.free(current_url);
            std.debug.print("[{d}] Current URL: {s}\n", .{ i, current_url });
            if (current_url.len > 0 and !std.mem.eql(u8, current_url, "about:blank")) {
                std.debug.print("Successfully navigated!\n", .{});
                return;
            }
        } else {
            std.debug.print("[{d}] Current URL: \n", .{i});
        }
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

fn runShellCapture(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-lc", command },
        .max_output_bytes = 4 * 1024 * 1024,
    });
    defer allocator.free(res.stderr);
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        allocator.free(res.stdout);
        return error.CommandFailed;
    }
    return res.stdout;
}

fn parseSessionId(allocator: std.mem.Allocator, json_text: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    const value_obj = root.object.get("value") orelse return null;
    const sid = value_obj.object.get("sessionId") orelse return null;
    if (sid != .string) return null;
    return allocator.dupe(u8, sid.string) catch null;
}

fn parseValueString(allocator: std.mem.Allocator, json_text: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    const value = root.object.get("value") orelse return null;
    if (value != .string) return null;
    return allocator.dupe(u8, value.string) catch null;
}
