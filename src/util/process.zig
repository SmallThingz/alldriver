const std = @import("std");

pub const RunCollectResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,
};

pub fn commandExists(allocator: std.mem.Allocator, command: []const u8) !bool {
    const which_cmd = if (@import("builtin").os.tag == .windows) "where" else "which";
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ which_cmd, command },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

pub fn runCaptureTrimmed(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.EnvMap,
) ![]u8 {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .env_map = env_map,
        .max_output_bytes = 8 * 1024 * 1024,
    });
    defer allocator.free(res.stderr);
    if (switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    } == false) {
        defer allocator.free(res.stdout);
        return error.CommandFailed;
    }

    const out = res.stdout;
    const trimmed = std.mem.trimRight(u8, out, "\r\n\t ");
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(out);
    return duped;
}

pub fn runInherit(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.EnvMap,
) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.cwd = cwd;
    child.env_map = env_map;
    const term = try child.spawnAndWait();
    const ok = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) return error.CommandFailed;
}

pub fn runCollect(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.EnvMap,
) !RunCollectResult {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .env_map = env_map,
        .max_output_bytes = 64 * 1024 * 1024,
    });
    const ok = switch (res.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = res.stdout, .stderr = res.stderr };
}

test "runCaptureTrimmed trims newline" {
    const allocator = std.testing.allocator;
    const out = try runCaptureTrimmed(allocator, &.{ "bash", "-lc", "printf 'ok\\n'" }, null, null);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "runCollect returns stdout" {
    const allocator = std.testing.allocator;
    const res = try runCollect(allocator, &.{ "bash", "-lc", "printf 'x'" }, null, null);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    try std.testing.expect(res.ok);
    try std.testing.expectEqualStrings("x", res.stdout);
}
