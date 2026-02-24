const std = @import("std");
const driver = @import("browser_driver");

const Allocator = std.mem.Allocator;

const ToolError = error{
    InvalidArgs,
    CommandFailed,
    MissingDependency,
    NotFound,
    VerificationFailed,
};

const VmEnv = struct {
    vm_name: []const u8,
    vm_user: []const u8,
    ssh_port: []const u8,
    ssh_key: []const u8,
    run_script: []const u8,
    project_dir: []const u8,
    cloud_init_port: []const u8,
};

fn printUsage() void {
    std.debug.print(
        \\browser_driver_tools
        \\usage: browser_driver_tools <command> [args]
        \\
        \\commands:
        \\  matrix-run
        \\  matrix-collect
        \\  matrix-run-remote
        \\  matrix-ga
        \\  release-gate
        \\  production-gate
        \\  release-bundle
        \\  test-behavioral-matrix
        \\  adversarial-detection-gate
        \\  vm-check-prereqs
        \\  vm-init-lab
        \\  vm-register-host
        \\  vm-create-linux
        \\  vm-run-linux-matrix
        \\  vm-run-remote-matrix
        \\  vm-ga-collect-and-bundle
        \\  vm-image-sources
        \\  vm-qemu-create
        \\  vm-qemu-list
        \\  vm-qemu-start
        \\  self-test
        \\
    , .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return ToolError.InvalidArgs;
    }

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const cmd = args[1];
    const sub = args[2..];

    if (std.mem.eql(u8, cmd, "matrix-run")) {
        try cmdMatrixRun(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "matrix-collect")) {
        try cmdMatrixCollect(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "matrix-run-remote")) {
        try cmdMatrixRunRemote(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "matrix-ga")) {
        try cmdMatrixGa(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "release-gate")) {
        try cmdReleaseGate(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "production-gate")) {
        try cmdProductionGate(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "release-bundle")) {
        try cmdReleaseBundle(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "test-behavioral-matrix")) {
        try cmdTestBehavioral(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "adversarial-detection-gate")) {
        try cmdAdversarialDetectionGate(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-check-prereqs")) {
        try cmdVmCheckPrereqs(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-init-lab")) {
        try cmdVmInitLab(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-register-host")) {
        try cmdVmRegisterHost(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-create-linux")) {
        try cmdVmCreateLinux(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-run-linux-matrix")) {
        try cmdVmRunLinuxMatrix(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-run-remote-matrix")) {
        try cmdVmRunRemoteMatrix(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-ga-collect-and-bundle")) {
        try cmdVmGaCollectAndBundle(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-image-sources")) {
        try cmdVmImageSources(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-qemu-create")) {
        try cmdVmQemuCreate(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-qemu-list")) {
        try cmdVmQemuList(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "vm-qemu-start")) {
        try cmdVmQemuStart(allocator, root, sub);
    } else if (std.mem.eql(u8, cmd, "self-test")) {
        std.debug.print("ok\n", .{});
    } else {
        printUsage();
        return ToolError.InvalidArgs;
    }
}

fn defaultVmLabDir() []const u8 {
    return std.posix.getenv("VM_LAB_DIR") orelse "/home/a/vm_lab";
}

fn isWindowsHost() bool {
    return switch (@import("builtin").os.tag) {
        .windows => true,
        else => false,
    };
}

fn ensureDir(path: []const u8) !void {
    try std.fs.makeDirAbsolute(path);
}

fn ensurePath(path: []const u8) !void {
    var dir = std.fs.cwd();
    try dir.makePath(path);
}

fn pathJoin(allocator: Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

fn toAbsolutePath(allocator: Allocator, root: []const u8, maybe_rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(maybe_rel)) return allocator.dupe(u8, maybe_rel);
    return try pathJoin(allocator, &.{ root, maybe_rel });
}

fn nowStamp(allocator: Allocator) ![]u8 {
    return try runCaptureTrimmed(allocator, &.{ "date", "-u", "+%Y%m%dT%H%M%SZ" }, null, null);
}

fn nowRfc3339(allocator: Allocator) ![]u8 {
    return try runCaptureTrimmed(allocator, &.{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" }, null, null);
}

fn getHostPlatform() []const u8 {
    return switch (@import("builtin").os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "unknown",
    };
}

fn commandExists(allocator: Allocator, command: []const u8) !bool {
    const which_cmd = if (isWindowsHost()) "where" else "which";
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

fn runCaptureTrimmed(
    allocator: Allocator,
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
        return ToolError.CommandFailed;
    }
    const out = res.stdout;
    const trimmed = std.mem.trimRight(u8, out, "\r\n\t ");
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(out);
    return duped;
}

fn runInherit(
    allocator: Allocator,
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
    if (!ok) return ToolError.CommandFailed;
}

fn runCollect(
    allocator: Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.EnvMap,
) !struct { ok: bool, stdout: []u8, stderr: []u8 } {
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

fn writeFile(path: []const u8, contents: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents });
}

fn writeFileAbs(path: []const u8, contents: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "/";
    try std.fs.cwd().makePath(dir_path);
    var f = try std.fs.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(contents);
}

fn readFileAlloc(allocator: Allocator, path: []const u8, max: usize) ![]u8 {
    return try std.fs.cwd().readFileAlloc(allocator, path, max);
}

fn parseKvFile(allocator: Allocator, path: []const u8) !std.StringHashMap([]u8) {
    var map = std.StringHashMap([]u8).init(allocator);
    const data = try readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        const idx_opt = std.mem.indexOfScalar(u8, line, '=');
        if (idx_opt == null) continue;
        const idx = idx_opt.?;
        const k = std.mem.trim(u8, line[0..idx], " \t");
        var v = std.mem.trim(u8, line[idx + 1 ..], " \t");
        if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
            v = v[1 .. v.len - 1];
        }
        try map.put(try allocator.dupe(u8, k), try allocator.dupe(u8, v));
    }
    return map;
}

fn freeStringMap(allocator: Allocator, map: *std.StringHashMap([]u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn mapGetRequired(map: *const std.StringHashMap([]u8), key: []const u8) ![]const u8 {
    const v = map.get(key) orelse return ToolError.InvalidArgs;
    return v;
}

fn mapGetOr(map: *const std.StringHashMap([]u8), key: []const u8, fallback: []const u8) []const u8 {
    return map.get(key) orelse fallback;
}

fn strictGaEnabled(flags: *const std.StringHashMap([]u8), env_default: []const u8) bool {
    return std.mem.eql(u8, mapGetOr(flags, "strict-ga", env_default), "1");
}

fn parseFlags(allocator: Allocator, args: []const []const u8) !std.StringHashMap([]u8) {
    var map = std.StringHashMap([]u8).init(allocator);
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            return ToolError.InvalidArgs;
        }
        const key = a[2..];
        if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
            try map.put(try allocator.dupe(u8, key), try allocator.dupe(u8, args[i + 1]));
            i += 2;
        } else {
            try map.put(try allocator.dupe(u8, key), try allocator.dupe(u8, "1"));
            i += 1;
        }
    }
    return map;
}

fn setDefaultZigGlobalCache(allocator: Allocator, root: []const u8) !std.process.EnvMap {
    var env = try std.process.getEnvMap(allocator);
    if (env.get("ZIG_GLOBAL_CACHE_DIR") == null) {
        const cache = try pathJoin(allocator, &.{ root, ".zig-global-cache" });
        try ensurePath(cache);
        try env.put("ZIG_GLOBAL_CACHE_DIR", cache);
    }
    return env;
}

fn runStepWithLog(
    allocator: Allocator,
    root: []const u8,
    env: ?*const std.process.EnvMap,
    out_dir: []const u8,
    name: []const u8,
    argv: []const []const u8,
) !bool {
    const logs_dir = try pathJoin(allocator, &.{ out_dir, "logs" });
    defer allocator.free(logs_dir);
    try ensurePath(logs_dir);

    const log_path = try pathJoin(allocator, &.{ logs_dir, try std.fmt.allocPrint(allocator, "{s}.log", .{name}) });
    defer allocator.free(log_path);

    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(allocator);
    try log.writer(allocator).print("[matrix] running: {s}\n", .{name});

    const res = try runCollect(allocator, argv, root, env);
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    try log.appendSlice(allocator, res.stdout);
    try log.appendSlice(allocator, res.stderr);

    try writeFile(log_path, log.items);

    const status = if (res.ok) "PASS" else "FAIL";
    const status_path = try pathJoin(allocator, &.{ logs_dir, try std.fmt.allocPrint(allocator, "{s}.status", .{name}) });
    defer allocator.free(status_path);
    try writeFile(status_path, status);

    return res.ok;
}

fn listReports(allocator: Allocator, matrix_root: []const u8) !std.ArrayList([]u8) {
    var reports: std.ArrayList([]u8) = .empty;
    var dir = try std.fs.openDirAbsolute(matrix_root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, std.fs.path.basename(entry.path), "matrix-report.txt")) {
            const full = try pathJoin(allocator, &.{ matrix_root, entry.path });
            try reports.append(allocator, full);
        }
    }

    std.mem.sort([]u8, reports.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    return reports;
}

fn lineValue(allocator: Allocator, data: []const u8, prefix: []const u8) ![]u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), prefix)) {
            const raw = std.mem.trim(u8, line[prefix.len..], " \t\r");
            return try allocator.dupe(u8, raw);
        }
    }
    return try allocator.dupe(u8, "");
}

fn containsLine(data: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, "\r"), needle)) return true;
    }
    return false;
}

fn containsPrefixNonNotFound(data: []const u8, prefix: []const u8) bool {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return !std.mem.endsWith(u8, std.mem.trim(u8, line, "\r"), "NOT_FOUND");
        }
    }
    return false;
}

fn cmdMatrixCollect(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    var matrix_root_default: ?[]u8 = null;
    defer if (matrix_root_default) |p| allocator.free(p);
    const matrix_root_raw = flags.get("matrix-root") orelse blk: {
        matrix_root_default = try pathJoin(allocator, &.{ root, "artifacts", "matrix" });
        break :blk matrix_root_default.?;
    };
    const matrix_root = try toAbsolutePath(allocator, root, matrix_root_raw);
    defer allocator.free(matrix_root);
    const strict_ga = std.mem.eql(u8, mapGetOr(&flags, "strict-ga", "0"), "1");

    var out_file = flags.get("out");

    var dir = std.fs.openDirAbsolute(matrix_root, .{}) catch {
        std.debug.print("matrix root not found: {s}\n", .{matrix_root});
        return ToolError.NotFound;
    };
    dir.close();

    var reports = try listReports(allocator, matrix_root);
    defer {
        for (reports.items) |p| allocator.free(p);
        reports.deinit(allocator);
    }

    if (reports.items.len == 0) {
        std.debug.print("no matrix reports found under {s}\n", .{matrix_root});
        return ToolError.NotFound;
    }

    const ts = try nowStamp(allocator);
    defer allocator.free(ts);

    if (out_file == null) {
        out_file = try pathJoin(allocator, &.{ matrix_root, try std.fmt.allocPrint(allocator, "matrix-summary-{s}.txt", .{ts}) });
    }
    const out = out_file.?;

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    try content.writer(allocator).print("Matrix Summary\ntimestamp_utc: {s}\nroot: {s}\nstrict_ga: {d}\n\n", .{ ts, matrix_root, @intFromBool(strict_ga) });

    var overall_pass = true;
    var strict_overall = true;
    var linux_ok = false;
    var windows_ok = false;
    var macos_ok = false;
    var linux_android_ok = false;
    var macos_ios_ok = false;
    var strict_report_seen = false;

    for (reports.items) |report| {
        const report_data = try readFileAlloc(allocator, report, 8 * 1024 * 1024);
        defer allocator.free(report_data);

        const report_dir = std.fs.path.dirname(report) orelse report;
        const platform_run = std.fs.path.basename(report_dir);

        var status = try lineValue(allocator, report_data, "OVERALL:");
        defer allocator.free(status);
        if (status.len == 0) {
            allocator.free(status);
            status = try allocator.dupe(u8, "UNKNOWN");
        }

        if (!std.mem.eql(u8, status, "PASS")) overall_pass = false;

        var sig_status: []const u8 = "N/A";
        const asc_path = try std.fmt.allocPrint(allocator, "{s}.asc", .{report});
        defer allocator.free(asc_path);
        if (std.fs.openFileAbsolute(asc_path, .{}) catch null) |f| {
            f.close();
            if (try commandExists(allocator, "gpg")) {
                const verify_res = try runCollect(allocator, &.{ "gpg", "--verify", asc_path, report }, null, null);
                defer allocator.free(verify_res.stdout);
                defer allocator.free(verify_res.stderr);
                if (verify_res.ok) {
                    sig_status = "VALID";
                } else {
                    sig_status = "INVALID";
                    overall_pass = false;
                }
            }
        }

        const platform = try lineValue(allocator, report_data, "platform:");
        defer allocator.free(platform);
        const strict_marker = try lineValue(allocator, report_data, "strict_ga:");
        defer allocator.free(strict_marker);
        const is_strict_report = std.mem.eql(u8, strict_marker, "1");

        const behavioral_pass = containsLine(report_data, "- behavioral_matrix: PASS");
        const adversarial_pass = containsLine(report_data, "- adversarial_detection_gate: PASS");
        const android_bridge_ok = containsPrefixNonNotFound(report_data, "adb=") or
            containsPrefixNonNotFound(report_data, "shizuku=") or
            containsPrefixNonNotFound(report_data, "rish=");
        const ios_ok = containsPrefixNonNotFound(report_data, "ios_webkit_debug_proxy=") or containsPrefixNonNotFound(report_data, "tidevice=");

        const strict_report_ok = std.mem.eql(u8, status, "PASS") and
            std.mem.eql(u8, sig_status, "VALID") and
            behavioral_pass and
            adversarial_pass and
            is_strict_report;

        if (strict_ga) {
            if (is_strict_report) {
                strict_report_seen = true;

                if (std.mem.eql(u8, platform, "linux")) {
                    if (strict_report_ok) {
                        linux_ok = true;
                        if (android_bridge_ok) linux_android_ok = true;
                    }
                } else if (std.mem.eql(u8, platform, "windows")) {
                    if (strict_report_ok) windows_ok = true;
                } else if (std.mem.eql(u8, platform, "macos")) {
                    if (strict_report_ok) {
                        macos_ok = true;
                        if (ios_ok) macos_ios_ok = true;
                    }
                }
            }
        }

        try content.writer(allocator).print(
            "run: {s}\nreport: {s}\nplatform: {s}\nstatus: {s}\nsignature: {s}\nstrict_report_ok: {d}\nbehavioral_pass: {d}\nadversarial_pass: {d}\nandroid_bridge_tool_present: {d}\nios_bridge_tool_present: {d}\n\n",
            .{
                platform_run,
                report,
                if (platform.len == 0) "unknown" else platform,
                status,
                sig_status,
                @intFromBool(strict_report_ok),
                @intFromBool(behavioral_pass),
                @intFromBool(adversarial_pass),
                @intFromBool(android_bridge_ok),
                @intFromBool(ios_ok),
            },
        );
    }

    if (strict_ga) {
        if (!strict_report_seen) {
            strict_overall = false;
        }
        if (!(linux_ok and windows_ok and macos_ok and linux_android_ok and macos_ios_ok)) {
            strict_overall = false;
        }
    }

    try content.writer(allocator).print("OVERALL: {s}\n", .{if (overall_pass) "PASS" else "FAIL"});
    if (strict_ga) {
        try content.writer(allocator).print(
            "STRICT_OVERALL: {s}\nSTRICT_PLATFORM_LINUX: {d}\nSTRICT_PLATFORM_WINDOWS: {d}\nSTRICT_PLATFORM_MACOS: {d}\nSTRICT_ANDROID_BRIDGE: {d}\nSTRICT_IOS_BRIDGE: {d}\n",
            .{
                if (strict_overall) "PASS" else "FAIL",
                @intFromBool(linux_ok),
                @intFromBool(windows_ok),
                @intFromBool(macos_ok),
                @intFromBool(linux_android_ok),
                @intFromBool(macos_ios_ok),
            },
        );
    }

    try writeFile(out, content.items);

    if (!overall_pass) {
        std.debug.print("matrix summary failed: {s}\n", .{out});
        return ToolError.VerificationFailed;
    }
    if (strict_ga and !strict_overall) {
        std.debug.print("strict GA matrix summary failed: {s}\n", .{out});
        return ToolError.VerificationFailed;
    }

    std.debug.print("matrix summary: {s}\n", .{out});
}

fn cmdTestBehavioral(allocator: Allocator, root: []const u8, _: []const []const u8) !void {
    var env = try setDefaultZigGlobalCache(allocator, root);
    defer env.deinit();

    if (env.get("BROWSER_DRIVER_BEHAVIORAL") == null) try env.put("BROWSER_DRIVER_BEHAVIORAL", "0");
    if (env.get("BROWSER_DRIVER_BEHAVIORAL_STRICT") == null) try env.put("BROWSER_DRIVER_BEHAVIORAL_STRICT", "0");
    if (env.get("WEBVIEW_BRIDGE_BEHAVIORAL") == null) try env.put("WEBVIEW_BRIDGE_BEHAVIORAL", "0");
    if (env.get("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT") == null) try env.put("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT", "0");
    if (env.get("ELECTRON_BEHAVIORAL") == null) try env.put("ELECTRON_BEHAVIORAL", "0");
    if (env.get("ELECTRON_BEHAVIORAL_STRICT") == null) try env.put("ELECTRON_BEHAVIORAL_STRICT", "0");
    if (env.get("WEBKITGTK_BEHAVIORAL") == null) try env.put("WEBKITGTK_BEHAVIORAL", "0");
    if (env.get("WEBKITGTK_BEHAVIORAL_STRICT") == null) try env.put("WEBKITGTK_BEHAVIORAL_STRICT", "0");

    try runInherit(allocator, &.{ "zig", "build", "test" }, root, &env);
}

const GateExpectation = enum {
    undetected,
    detected,
};

const GateTotals = struct {
    targeted: usize = 0,
    discovered: usize = 0,
    launched: usize = 0,
    probed: usize = 0,
    detected: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

const DetectionSignals = struct {
    js_webdriver_true: bool = false,
    js_webdriver_prop_present: bool = false,
    js_webdriver_descriptor_present: bool = false,
    js_headless_ua_true: bool = false,
    js_automation_globals_present: bool = false,
    js_dom_automation_present: bool = false,
    js_languages_empty: bool = false,
    js_plugins_empty: bool = false,

    endpoint_cdp: bool = false,
    endpoint_webdriver: bool = false,
    endpoint_bidi: bool = false,
    endpoint_webview: bool = false,

    transport_cdp: bool = false,
    transport_webdriver: bool = false,
    transport_bidi: bool = false,

    launch_arg_remote_debugging: bool = false,
    launch_arg_headless: bool = false,
    launch_arg_automation: bool = false,
    launch_arg_disable_blink_automation: bool = false,
    launch_arg_profile: bool = false,
    profile_ephemeral_dir: bool = false,

    runtime_msedgewebview2: bool = false,
    runtime_safaridriver: bool = false,
    runtime_webkitwebdriver: bool = false,
    runtime_minibrowser: bool = false,
    runtime_electron: bool = false,

    bridge_adb: bool = false,
    bridge_shizuku: bool = false,
    bridge_rish: bool = false,
    bridge_ios_webkit_debug_proxy: bool = false,
    bridge_tidevice: bool = false,
    webview_mobile_runtime: bool = false,

    fn signalCount(self: DetectionSignals) usize {
        var count: usize = 0;
        inline for (std.meta.fields(DetectionSignals)) |field| {
            if (@field(self, field.name)) count += 1;
        }
        return count;
    }

    fn highConfidenceCount(self: DetectionSignals) usize {
        var count: usize = 0;
        if (self.js_webdriver_true) count += 1;
        if (self.js_automation_globals_present) count += 1;
        if (self.js_dom_automation_present) count += 1;
        return count;
    }

    fn webObservableCount(self: DetectionSignals) usize {
        var count: usize = 0;
        if (self.js_webdriver_true) count += 1;
        if (self.js_headless_ua_true) count += 1;
        if (self.js_automation_globals_present) count += 1;
        if (self.js_dom_automation_present) count += 1;
        if (self.js_languages_empty) count += 1;
        if (self.js_plugins_empty) count += 1;
        return count;
    }
};

const DetectionClassification = struct {
    signals: DetectionSignals,
    signal_count: usize,
    high_confidence_count: usize,
    detected: bool,
};

const WebViewSessionProbe = struct {
    session: driver.Session,
    launched: bool,
};

fn cmdAdversarialDetectionGate(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    _ = root;

    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const allow_missing_browser = std.mem.eql(u8, mapGetOr(&flags, "allow-missing-browser", "0"), "1");
    const expectation: GateExpectation = if (std.mem.eql(u8, mapGetOr(&flags, "expect-detected", "0"), "1"))
        .detected
    else
        .undetected;
    const out_path = flags.get("out");

    const host_platform = getHostPlatform();
    const target_browser_kinds = try targetBrowserKindsForHost(allocator);
    defer allocator.free(target_browser_kinds);
    const target_webview_kinds = try targetWebViewKindsForHost(allocator, host_platform);
    defer allocator.free(target_webview_kinds);

    const installs = try driver.discover(allocator, .{
        .kinds = target_browser_kinds,
        .allow_managed_download = false,
    }, .{
        .include_path_env = true,
        .include_os_probes = true,
        .include_known_paths = true,
    });
    defer driver.freeInstalls(allocator, installs);

    const webview_runtimes = try driver.discoverWebViews(allocator, .{
        .kinds = target_webview_kinds,
        .include_path_env = true,
        .include_known_paths = true,
        .include_mobile_bridges = true,
    });
    defer driver.freeWebViewRuntimes(allocator, webview_runtimes);

    var totals: GateTotals = .{};
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(allocator);
    try report.writer(allocator).print(
        "Adversarial Detection Gate\nplatform={s}\nexpectation={s}\n\n",
        .{
            host_platform,
            if (expectation == .detected) "detected" else "undetected",
        },
    );

    try report.writer(allocator).writeAll("[browser_targets]\n");
    for (target_browser_kinds) |kind| {
        totals.targeted += 1;
        const install_opt = firstInstallForKind(installs, kind);
        if (install_opt == null) {
            totals.skipped += 1;
            try report.writer(allocator).print(
                "target=browser kind={s} engine={s} platform={s} status=SKIP discovered=0 launched=0 probed=0 detected=0 signal_count=0 high_confidence_count=0 reason=missing_install\n",
                .{ @tagName(kind), @tagName(driver.engineFor(kind)), host_platform },
            );
            continue;
        }

        const install = install_opt.?;
        totals.discovered += 1;

        var session = driver.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
            .args = &.{},
        }) catch |err| {
            totals.failed += 1;
            try report.writer(allocator).print(
                "target=browser kind={s} engine={s} platform={s} status=FAIL discovered=1 launched=0 probed=0 detected=0 signal_count=0 high_confidence_count=0 reason=launch_error error={s}\n",
                .{ @tagName(kind), @tagName(install.engine), host_platform, @errorName(err) },
            );
            continue;
        };
        defer session.deinit();

        totals.launched += 1;

        const classification = probeSessionForSignals(
            &session,
            allocator,
            true,
            null,
            null,
            null,
        ) catch |err| {
            totals.failed += 1;
            try report.writer(allocator).print(
                "target=browser kind={s} engine={s} platform={s} status=FAIL discovered=1 launched=1 probed=0 detected=0 signal_count=0 high_confidence_count=0 reason=probe_error error={s}\n",
                .{ @tagName(kind), @tagName(install.engine), host_platform, @errorName(err) },
            );
            continue;
        };

        totals.probed += 1;
        if (classification.detected) totals.detected += 1;
        const passed = expectationSatisfied(expectation, classification.detected);
        if (!passed) totals.failed += 1;

        try report.writer(allocator).print(
            "target=browser kind={s} engine={s} platform={s} status={s} discovered=1 launched=1 probed=1 detected={d} signal_count={d} high_confidence_count={d} reason={s}\n",
            .{
                @tagName(kind),
                @tagName(install.engine),
                host_platform,
                if (passed) "PASS" else "FAIL",
                @intFromBool(classification.detected),
                classification.signal_count,
                classification.high_confidence_count,
                if (classification.detected) "detection_signals_present" else "detection_signals_absent",
            },
        );
    }

    try report.writer(allocator).writeAll("\n[webview_targets]\n");
    for (target_webview_kinds) |kind| {
        totals.targeted += 1;
        const runtime_opt = bestWebViewRuntimeForKind(webview_runtimes, kind);
        if (runtime_opt == null) {
            totals.skipped += 1;
            try report.writer(allocator).print(
                "target=webview kind={s} engine={s} platform={s} status=SKIP discovered=0 launched=0 probed=0 detected=0 signal_count=0 high_confidence_count=0 reason=missing_runtime\n",
                .{ @tagName(kind), @tagName(webviewEngineForKind(kind)), webViewPlatformName(kind, host_platform) },
            );
            continue;
        }

        const runtime = runtime_opt.?;
        totals.discovered += 1;

        var probe_session = launchOrAttachWebViewForProbe(allocator, runtime) catch |err| {
            totals.failed += 1;
            try report.writer(allocator).print(
                "target=webview kind={s} engine={s} platform={s} status=FAIL discovered=1 launched=0 probed=0 detected=0 signal_count=0 high_confidence_count=0 reason=launch_or_attach_error error={s}\n",
                .{ @tagName(kind), @tagName(runtime.engine), webViewPlatformName(kind, host_platform), @errorName(err) },
            );
            continue;
        };
        defer probe_session.session.deinit();

        if (probe_session.launched) totals.launched += 1;

        const classification = probeSessionForSignals(
            &probe_session.session,
            allocator,
            true,
            kind,
            runtime.runtime_path,
            runtime.bridge_tool_path,
        ) catch |err| {
            totals.failed += 1;
            try report.writer(allocator).print(
                "target=webview kind={s} engine={s} platform={s} status=FAIL discovered=1 launched={d} probed=0 detected=0 signal_count=0 high_confidence_count=0 reason=probe_error error={s}\n",
                .{
                    @tagName(kind),
                    @tagName(runtime.engine),
                    webViewPlatformName(kind, host_platform),
                    @intFromBool(probe_session.launched),
                    @errorName(err),
                },
            );
            continue;
        };

        totals.probed += 1;
        if (classification.detected) totals.detected += 1;
        const passed = expectationSatisfied(expectation, classification.detected);
        if (!passed) totals.failed += 1;

        try report.writer(allocator).print(
            "target=webview kind={s} engine={s} platform={s} status={s} discovered=1 launched={d} probed=1 detected={d} signal_count={d} high_confidence_count={d} reason={s}\n",
            .{
                @tagName(kind),
                @tagName(runtime.engine),
                webViewPlatformName(kind, host_platform),
                if (passed) "PASS" else "FAIL",
                @intFromBool(probe_session.launched),
                @intFromBool(classification.detected),
                classification.signal_count,
                classification.high_confidence_count,
                if (classification.detected) "detection_signals_present" else "detection_signals_absent",
            },
        );
    }

    if (totals.discovered == 0) {
        if (allow_missing_browser) {
            try report.writer(allocator).print(
                "\ntotals targeted={d} discovered={d} launched={d} probed={d} detected={d} failed={d} skipped={d}\n",
                .{
                    totals.targeted,
                    totals.discovered,
                    totals.launched,
                    totals.probed,
                    totals.detected,
                    totals.failed,
                    totals.skipped,
                },
            );
            try report.writer(allocator).writeAll("OVERALL: SKIP\n");
            if (out_path) |out| {
                try writeFile(out, report.items);
                std.debug.print("adversarial-detection-gate report: {s}\n", .{out});
            }
            std.debug.print("adversarial-detection-gate: no targets discovered; skipping by request\n", .{});
            return;
        }
        try report.writer(allocator).writeAll("OVERALL: FAIL\n");
        if (out_path) |out| try writeFile(out, report.items);
        return ToolError.NotFound;
    }

    try report.writer(allocator).print(
        "\ntotals targeted={d} discovered={d} launched={d} probed={d} detected={d} failed={d} skipped={d}\n",
        .{
            totals.targeted,
            totals.discovered,
            totals.launched,
            totals.probed,
            totals.detected,
            totals.failed,
            totals.skipped,
        },
    );

    const overall_pass = totals.failed == 0;
    try report.writer(allocator).print("OVERALL: {s}\n", .{if (overall_pass) "PASS" else "FAIL"});
    if (out_path) |out| {
        try writeFile(out, report.items);
        std.debug.print("adversarial-detection-gate report: {s}\n", .{out});
    }

    if (!overall_pass) {
        return ToolError.VerificationFailed;
    }
}

fn expectationSatisfied(expectation: GateExpectation, detected: bool) bool {
    return switch (expectation) {
        .undetected => !detected,
        .detected => detected,
    };
}

fn classifySignals(signals: DetectionSignals) DetectionClassification {
    const signal_count = signals.signalCount();
    const high_confidence_count = signals.highConfidenceCount();
    const web_observable_count = signals.webObservableCount();
    return .{
        .signals = signals,
        .signal_count = signal_count,
        .high_confidence_count = high_confidence_count,
        .detected = high_confidence_count > 0 or web_observable_count >= 3,
    };
}

fn targetBrowserKindsForHost(allocator: Allocator) ![]driver.BrowserKind {
    const list = switch (@import("builtin").os.tag) {
        .windows => &[_]driver.BrowserKind{
            .chrome, .edge, .firefox, .brave, .tor, .duckduckgo, .mullvad, .librewolf,
            .epic,   .arc,  .vivaldi, .sidekick, .shift, .operagx, .lightpanda, .palemoon,
        },
        .macos => &[_]driver.BrowserKind{
            .chrome, .edge, .safari, .firefox, .brave, .tor, .duckduckgo, .mullvad,
            .librewolf, .epic, .arc, .vivaldi, .sigmaos, .sidekick, .shift, .operagx,
            .lightpanda, .palemoon,
        },
        else => &[_]driver.BrowserKind{
            .chrome, .edge, .firefox, .brave, .tor, .duckduckgo, .mullvad, .librewolf,
            .epic,   .arc,  .vivaldi, .sidekick, .shift, .operagx, .lightpanda, .palemoon,
        },
    };

    const out = try allocator.alloc(driver.BrowserKind, list.len);
    @memcpy(out, list);
    return out;
}

fn targetWebViewKindsForHost(allocator: Allocator, host_platform: []const u8) ![]driver.WebViewKind {
    const list = if (std.mem.eql(u8, host_platform, "windows"))
        &[_]driver.WebViewKind{ .webview2, .electron, .android_webview }
    else if (std.mem.eql(u8, host_platform, "macos"))
        &[_]driver.WebViewKind{ .wkwebview, .electron, .android_webview, .ios_wkwebview }
    else
        &[_]driver.WebViewKind{ .webkitgtk, .electron, .android_webview };

    const out = try allocator.alloc(driver.WebViewKind, list.len);
    @memcpy(out, list);
    return out;
}

fn firstInstallForKind(installs: []const driver.BrowserInstall, kind: driver.BrowserKind) ?driver.BrowserInstall {
    for (installs) |install| {
        if (install.kind == kind) return install;
    }
    return null;
}

fn webviewRuntimeScore(runtime: driver.WebViewRuntime) i32 {
    var score: i32 = 0;
    if (runtime.runtime_path != null) score += 10;
    if (runtime.bridge_tool_path != null) score += 10;

    if (runtime.runtime_path) |path| {
        if (containsIgnoreCase(path, "msedgewebview2")) score += 40;
        if (containsIgnoreCase(path, "safaridriver")) score += 40;
        if (containsIgnoreCase(path, "webkitwebdriver")) score += 40;
        if (containsIgnoreCase(path, "minibrowser")) score += 20;
        if (containsIgnoreCase(path, "electron")) score += 40;
        if (containsIgnoreCase(path, ".framework")) score -= 50;
    }

    if (runtime.bridge_tool_path) |path| {
        if (containsIgnoreCase(path, "shizuku")) score += 30;
        if (containsIgnoreCase(path, "rish")) score += 30;
        if (containsIgnoreCase(path, "adb")) score += 30;
        if (containsIgnoreCase(path, "ios_webkit_debug_proxy")) score += 30;
        if (containsIgnoreCase(path, "tidevice")) score += 30;
    }

    return score;
}

fn bestWebViewRuntimeForKind(runtimes: []const driver.WebViewRuntime, kind: driver.WebViewKind) ?driver.WebViewRuntime {
    var best: ?driver.WebViewRuntime = null;
    var best_score: i32 = std.math.minInt(i32);

    for (runtimes) |runtime| {
        if (runtime.kind != kind) continue;
        const score = webviewRuntimeScore(runtime);
        if (best == null or score > best_score) {
            best = runtime;
            best_score = score;
        }
    }

    return best;
}

fn launchOrAttachWebViewForProbe(allocator: Allocator, runtime: driver.WebViewRuntime) !WebViewSessionProbe {
    switch (runtime.kind) {
        .electron => {
            const executable = runtime.runtime_path orelse return error.InvalidExplicitPath;
            const session = try driver.launchElectronWebView(allocator, .{
                .executable_path = executable,
                .profile_mode = .ephemeral,
                .headless = true,
            });
            return .{ .session = session, .launched = true };
        },
        .webkitgtk => {
            var opts: driver.WebKitGtkWebViewLaunchOptions = .{
                .profile_mode = .ephemeral,
                .browser_args = &.{"about:blank"},
            };
            if (runtime.runtime_path) |path| {
                if (containsIgnoreCase(path, "webkitwebdriver")) {
                    opts.driver_executable_path = path;
                } else if (containsIgnoreCase(path, "minibrowser")) {
                    opts.browser_target = .custom_binary;
                    opts.browser_binary_path = path;
                }
            }
            const session = try driver.launchWebKitGtkWebView(allocator, opts);
            return .{ .session = session, .launched = true };
        },
        .webview2 => {
            const executable = runtime.runtime_path orelse return error.InvalidExplicitPath;
            const session = try driver.launchWebViewHost(allocator, .{
                .kind = .webview2,
                .host_executable = executable,
                .args = &.{ "--headless=new", "--disable-gpu", "--remote-debugging-port=9222", "about:blank" },
                .endpoint = "cdp://127.0.0.1:9222/",
            });
            return .{ .session = session, .launched = true };
        },
        .wkwebview => {
            const executable = runtime.runtime_path orelse return error.InvalidExplicitPath;
            const session = try driver.launchWebViewHost(allocator, .{
                .kind = .wkwebview,
                .host_executable = executable,
                .endpoint = "webdriver://127.0.0.1:4444/session/adversarial-gate",
            });
            return .{ .session = session, .launched = true };
        },
        .android_webview => {
            const session = try driver.attachAndroidWebView(allocator, .{
                .device_id = "adversarial-gate",
                .bridge_kind = inferAndroidBridgeKind(runtime.bridge_tool_path),
                .socket_name = "chrome_devtools_remote",
            });
            return .{ .session = session, .launched = false };
        },
        .ios_wkwebview => {
            const session = try driver.attachIosWebView(allocator, .{
                .udid = "adversarial-gate",
                .page_id = "1",
            });
            return .{ .session = session, .launched = false };
        },
    }
}

fn inferAndroidBridgeKind(path: ?[]const u8) driver.AndroidBridgeKind {
    const p = path orelse return .adb;
    if (containsIgnoreCase(p, "shizuku")) return .shizuku;
    if (containsIgnoreCase(p, "rish")) return .shizuku;
    return .adb;
}

fn webviewEngineForKind(kind: driver.WebViewKind) driver.EngineKind {
    return switch (kind) {
        .webview2, .electron, .android_webview => .chromium,
        .wkwebview, .webkitgtk, .ios_wkwebview => .webkit,
    };
}

fn webViewPlatformName(kind: driver.WebViewKind, host_platform: []const u8) []const u8 {
    return switch (kind) {
        .webview2 => "windows",
        .wkwebview => "macos",
        .webkitgtk => "linux",
        .electron => host_platform,
        .android_webview => "android",
        .ios_wkwebview => "ios",
    };
}

fn probeSessionForSignals(
    session: *driver.Session,
    allocator: Allocator,
    require_js_eval: bool,
    webview_kind: ?driver.WebViewKind,
    runtime_path: ?[]const u8,
    bridge_path: ?[]const u8,
) !DetectionClassification {
    var signals: DetectionSignals = .{};
    collectSessionSignals(&signals, session);
    collectRuntimeSignals(&signals, webview_kind, runtime_path, bridge_path);

    if (require_js_eval) {
        if (!session.supports(.js_eval)) return error.UnsupportedCapability;
        session.navigate("data:text/html,<html><body>gate</body></html>") catch {};
        session.waitFor(.dom_ready, 5_000) catch {};

        const js_payload = try session.evaluate(
            "(function(){var s=[];" ++
                "try{s.push(navigator.webdriver===true?'BROWSER_DRIVER_SIG_WEBDRIVER_TRUE':'BROWSER_DRIVER_SIG_WEBDRIVER_FALSE');}catch(e){s.push('BROWSER_DRIVER_SIG_WEBDRIVER_ERROR');}" ++
                "try{s.push(('webdriver' in navigator)?'BROWSER_DRIVER_SIG_WEBDRIVER_PROP_PRESENT':'BROWSER_DRIVER_SIG_WEBDRIVER_PROP_ABSENT');}catch(e){s.push('BROWSER_DRIVER_SIG_WEBDRIVER_PROP_ERROR');}" ++
                "try{var d=Object.getOwnPropertyDescriptor(Navigator.prototype,'webdriver');s.push(d?'BROWSER_DRIVER_SIG_WEBDRIVER_DESCRIPTOR_PRESENT':'BROWSER_DRIVER_SIG_WEBDRIVER_DESCRIPTOR_ABSENT');}catch(e){s.push('BROWSER_DRIVER_SIG_WEBDRIVER_DESCRIPTOR_ERROR');}" ++
                "try{s.push(/Headless/i.test(navigator.userAgent)?'BROWSER_DRIVER_SIG_HEADLESS_UA_TRUE':'BROWSER_DRIVER_SIG_HEADLESS_UA_FALSE');}catch(e){s.push('BROWSER_DRIVER_SIG_HEADLESS_UA_ERROR');}" ++
                "try{var g=false;for(var k in window){if(k.indexOf('cdc_')===0||k.indexOf('__webdriver')===0){g=true;break;}}s.push(g?'BROWSER_DRIVER_SIG_AUTOMATION_GLOBAL_TRUE':'BROWSER_DRIVER_SIG_AUTOMATION_GLOBAL_FALSE');}catch(e){s.push('BROWSER_DRIVER_SIG_AUTOMATION_GLOBAL_ERROR');}" ++
                "try{s.push((window.domAutomation||window.domAutomationController)?'BROWSER_DRIVER_SIG_DOM_AUTOMATION_TRUE':'BROWSER_DRIVER_SIG_DOM_AUTOMATION_FALSE');}catch(e){s.push('BROWSER_DRIVER_SIG_DOM_AUTOMATION_ERROR');}" ++
                "try{s.push((navigator.languages&&navigator.languages.length===0)?'BROWSER_DRIVER_SIG_LANG_EMPTY_TRUE':'BROWSER_DRIVER_SIG_LANG_EMPTY_FALSE');}catch(e){s.push('BROWSER_DRIVER_SIG_LANG_EMPTY_ERROR');}" ++
                "try{s.push((navigator.plugins&&navigator.plugins.length===0)?'BROWSER_DRIVER_SIG_PLUGINS_EMPTY_TRUE':'BROWSER_DRIVER_SIG_PLUGINS_EMPTY_FALSE');}catch(e){s.push('BROWSER_DRIVER_SIG_PLUGINS_EMPTY_ERROR');}" ++
                "return s.join('|');})();",
        );
        defer allocator.free(js_payload);

        signals.js_webdriver_true = containsToken(js_payload, "BROWSER_DRIVER_SIG_WEBDRIVER_TRUE");
        signals.js_webdriver_prop_present = containsToken(js_payload, "BROWSER_DRIVER_SIG_WEBDRIVER_PROP_PRESENT");
        signals.js_webdriver_descriptor_present = containsToken(js_payload, "BROWSER_DRIVER_SIG_WEBDRIVER_DESCRIPTOR_PRESENT");
        signals.js_headless_ua_true = containsToken(js_payload, "BROWSER_DRIVER_SIG_HEADLESS_UA_TRUE");
        signals.js_automation_globals_present = containsToken(js_payload, "BROWSER_DRIVER_SIG_AUTOMATION_GLOBAL_TRUE");
        signals.js_dom_automation_present = containsToken(js_payload, "BROWSER_DRIVER_SIG_DOM_AUTOMATION_TRUE");
        signals.js_languages_empty = containsToken(js_payload, "BROWSER_DRIVER_SIG_LANG_EMPTY_TRUE");
        signals.js_plugins_empty = containsToken(js_payload, "BROWSER_DRIVER_SIG_PLUGINS_EMPTY_TRUE");
    }

    return classifySignals(signals);
}

fn collectSessionSignals(signals: *DetectionSignals, session: *const driver.Session) void {
    if (session.endpoint) |endpoint| {
        signals.endpoint_cdp = std.mem.startsWith(u8, endpoint, "cdp://") or std.mem.startsWith(u8, endpoint, "ws://");
        signals.endpoint_webdriver = std.mem.startsWith(u8, endpoint, "webdriver://") or std.mem.startsWith(u8, endpoint, "http://");
        signals.endpoint_bidi = std.mem.startsWith(u8, endpoint, "bidi://");
        signals.endpoint_webview = std.mem.startsWith(u8, endpoint, "webview://");
    }

    signals.transport_cdp = session.transport == .cdp_ws;
    signals.transport_webdriver = session.transport == .webdriver_http;
    signals.transport_bidi = session.transport == .bidi_ws;

    if (session.owned_argv) |argv| {
        for (argv) |arg| {
            if (std.mem.startsWith(u8, arg, "--remote-debugging-port=")) signals.launch_arg_remote_debugging = true;
            if (std.mem.startsWith(u8, arg, "--user-data-dir=") or std.mem.eql(u8, arg, "-profile")) signals.launch_arg_profile = true;
            if (containsIgnoreCase(arg, "headless")) signals.launch_arg_headless = true;
            if (containsIgnoreCase(arg, "--automation")) signals.launch_arg_automation = true;
            if (containsIgnoreCase(arg, "automationcontrolled")) signals.launch_arg_disable_blink_automation = true;
        }
    }

    signals.profile_ephemeral_dir = session.ephemeral_profile_dir != null;
}

fn collectRuntimeSignals(
    signals: *DetectionSignals,
    webview_kind: ?driver.WebViewKind,
    runtime_path: ?[]const u8,
    bridge_path: ?[]const u8,
) void {
    if (runtime_path) |path| {
        if (containsIgnoreCase(path, "msedgewebview2")) signals.runtime_msedgewebview2 = true;
        if (containsIgnoreCase(path, "safaridriver")) signals.runtime_safaridriver = true;
        if (containsIgnoreCase(path, "webkitwebdriver")) signals.runtime_webkitwebdriver = true;
        if (containsIgnoreCase(path, "minibrowser")) signals.runtime_minibrowser = true;
        if (containsIgnoreCase(path, "electron")) signals.runtime_electron = true;
    }

    if (bridge_path) |path| {
        if (containsIgnoreCase(path, "adb")) signals.bridge_adb = true;
        if (containsIgnoreCase(path, "shizuku")) signals.bridge_shizuku = true;
        if (containsIgnoreCase(path, "rish")) signals.bridge_rish = true;
        if (containsIgnoreCase(path, "ios_webkit_debug_proxy")) signals.bridge_ios_webkit_debug_proxy = true;
        if (containsIgnoreCase(path, "tidevice")) signals.bridge_tidevice = true;
    }

    if (webview_kind) |kind| {
        switch (kind) {
            .android_webview, .ios_wkwebview => signals.webview_mobile_runtime = true,
            else => {},
        }
    }
}

fn containsToken(payload: []const u8, token: []const u8) bool {
    return std.mem.indexOf(u8, payload, token) != null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn cmdReleaseGate(allocator: Allocator, root: []const u8, _: []const []const u8) !void {
    var env = try setDefaultZigGlobalCache(allocator, root);
    defer env.deinit();

    const strict_ga = std.mem.eql(u8, env.get("STRICT_GA") orelse "0", "1");

    try runInherit(allocator, &.{ "zig", "build", "test" }, root, &env);
    try runInherit(allocator, &.{ "zig", "build", "test" }, root, &env);
    try runInherit(allocator, &.{ "zig", "build", "test", "-Denable_builtin_extension=true" }, root, &env);
    try runInherit(allocator, &.{ "zig", "build", "run" }, root, &env);

    if (strict_ga) {
        try cmdMatrixCollect(allocator, root, &.{"--strict-ga"});
    }

    std.debug.print("release-gate: local checks passed\n", .{});
}

fn isIgnoredScanPath(rel_path: []const u8) bool {
    return std.mem.startsWith(u8, rel_path, ".git/") or
        std.mem.startsWith(u8, rel_path, ".zig-cache/") or
        std.mem.startsWith(u8, rel_path, ".zig-global-cache/") or
        std.mem.startsWith(u8, rel_path, "zig-out/") or
        std.mem.startsWith(u8, rel_path, "artifacts/");
}

fn scanForbiddenMarkers(allocator: Allocator, root: []const u8, max_hits: usize) !std.ArrayList([]u8) {
    const markers = [_][]const u8{
        "TO" ++ "DO:",
        "FIX" ++ "ME:",
        "HA" ++ "CK:",
        "XX" ++ "X:",
    };

    var hits: std.ArrayList([]u8) = .empty;
    errdefer {
        for (hits.items) |h| allocator.free(h);
        hits.deinit(allocator);
    }

    var dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (isIgnoredScanPath(entry.path)) continue;

        const ext = std.fs.path.extension(entry.path);
        if (!(std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".txt"))) continue;

        const abs = try pathJoin(allocator, &.{ root, entry.path });
        defer allocator.free(abs);
        const data = blk: {
            var f = std.fs.openFileAbsolute(abs, .{}) catch continue;
            defer f.close();
            break :blk f.readToEndAlloc(allocator, 4 * 1024 * 1024) catch continue;
        };
        defer allocator.free(data);

        var line_no: usize = 1;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| : (line_no += 1) {
            for (markers) |marker| {
                if (std.mem.indexOf(u8, line, marker) != null) {
                    const hit = try std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ entry.path, line_no, marker });
                    try hits.append(allocator, hit);
                    if (hits.items.len >= max_hits) return hits;
                    break;
                }
            }
        }
    }

    return hits;
}

fn cmdProductionGate(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const strict_ga = strictGaEnabled(&flags, std.posix.getenv("STRICT_GA") orelse "0");
    const skip_marker_scan = std.mem.eql(u8, mapGetOr(&flags, "skip-marker-scan", "0"), "1");
    const skip_bundle = std.mem.eql(u8, mapGetOr(&flags, "skip-bundle", "0"), "1");

    var matrix_root_default: ?[]u8 = null;
    defer if (matrix_root_default) |p| allocator.free(p);
    const matrix_root_raw = flags.get("matrix-root") orelse blk: {
        matrix_root_default = try pathJoin(allocator, &.{ root, "artifacts", "matrix" });
        break :blk matrix_root_default.?;
    };
    const matrix_root = try toAbsolutePath(allocator, root, matrix_root_raw);
    defer allocator.free(matrix_root);
    try ensurePath(matrix_root);

    const ts = try nowStamp(allocator);
    defer allocator.free(ts);

    var out_default: ?[]u8 = null;
    defer if (out_default) |p| allocator.free(p);
    const out_raw = flags.get("out") orelse blk: {
        out_default = try pathJoin(allocator, &.{ root, "artifacts", "reports", try std.fmt.allocPrint(allocator, "production-gate-{s}.txt", .{ts}) });
        break :blk out_default.?;
    };
    const out = try toAbsolutePath(allocator, root, out_raw);
    defer allocator.free(out);
    if (std.fs.path.dirname(out)) |parent| try ensurePath(parent);

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(allocator);
    try report.writer(allocator).print("Production Gate\ntimestamp_utc: {s}\nroot: {s}\nstrict_ga: {d}\nmatrix_root: {s}\n\n", .{ ts, root, @intFromBool(strict_ga), matrix_root });

    var all_pass = true;

    const Step = struct {
        name: []const u8,
        ok: bool,
        detail: []const u8,
    };

    var steps: std.ArrayList(Step) = .empty;
    defer steps.deinit(allocator);

    {
        var ok = true;
        runInherit(allocator, &.{ "zig", "build", "test" }, root, null) catch {
            ok = false;
        };
        if (!ok) all_pass = false;
        try steps.append(allocator, .{ .name = "unit_and_contract_tests", .ok = ok, .detail = if (ok) "zig build test passed" else "zig build test failed" });
    }
    {
        var ok = true;
        runInherit(allocator, &.{ "zig", "build", "test", "-Denable_builtin_extension=true" }, root, null) catch {
            ok = false;
        };
        if (!ok) all_pass = false;
        try steps.append(allocator, .{ .name = "builtin_extension_tests", .ok = ok, .detail = if (ok) "extension tests passed" else "extension tests failed" });
    }
    {
        var ok = true;
        runInherit(allocator, &.{ "zig", "build", "run" }, root, null) catch {
            ok = false;
        };
        if (!ok) all_pass = false;
        try steps.append(allocator, .{ .name = "binary_smoke", .ok = ok, .detail = if (ok) "binary run smoke passed" else "binary run smoke failed" });
    }

    var reports = listReports(allocator, matrix_root) catch std.ArrayList([]u8).empty;
    defer {
        for (reports.items) |p| allocator.free(p);
        reports.deinit(allocator);
    }

    if (reports.items.len == 0 and !strict_ga) {
        const host = getHostPlatform();
        const run_out = try pathJoin(allocator, &.{ matrix_root, try std.fmt.allocPrint(allocator, "{s}-{s}", .{ host, ts }) });
        var ran = true;
        cmdMatrixRun(allocator, root, &.{ "--platform", host, "--allow-platform-mismatch", "--out", run_out }) catch {
            ran = false;
        };
        if (!ran) all_pass = false;
        try steps.append(allocator, .{
            .name = "matrix_bootstrap_local",
            .ok = ran,
            .detail = if (ran) "generated local matrix evidence" else "failed to generate local matrix evidence",
        });
    }

    {
        var collect_ok = true;
        if (strict_ga) {
            cmdMatrixCollect(allocator, root, &.{ "--strict-ga", "--matrix-root", matrix_root }) catch {
                collect_ok = false;
            };
        } else {
            cmdMatrixCollect(allocator, root, &.{ "--matrix-root", matrix_root }) catch {
                collect_ok = false;
            };
        }
        if (!collect_ok) all_pass = false;
        try steps.append(allocator, .{
            .name = "matrix_summary",
            .ok = collect_ok,
            .detail = if (collect_ok) "matrix summary check passed" else "matrix summary check failed",
        });
    }

    {
        const required_files = [_][]const u8{
            "README.md",
            "docs/support-matrix.md",
            "docs/path-discovery.md",
            "docs/compat-nodriver.md",
            "docs/extensions.md",
            "docs/migration-v1.md",
            "docs/known-limitations.md",
            "docs/vm-matrix.md",
            "docs/vm-image-sources.md",
        };
        var docs_ok = true;
        for (required_files) |rel| {
            const p = try pathJoin(allocator, &.{ root, rel });
            defer allocator.free(p);
            if (std.fs.openFileAbsolute(p, .{}) catch null == null) {
                docs_ok = false;
                try report.writer(allocator).print("missing_doc: {s}\n", .{rel});
            }
        }
        if (!docs_ok) all_pass = false;
        try steps.append(allocator, .{
            .name = "required_docs",
            .ok = docs_ok,
            .detail = if (docs_ok) "required docs present" else "one or more required docs missing",
        });
    }

    if (!skip_marker_scan) {
        var hits = try scanForbiddenMarkers(allocator, root, 100);
        defer {
            for (hits.items) |h| allocator.free(h);
            hits.deinit(allocator);
        }
        const marker_ok = hits.items.len == 0;
        if (!marker_ok) {
            all_pass = false;
            try report.writer(allocator).print("forbidden_marker_hits:\n", .{});
            for (hits.items) |hit| {
                try report.writer(allocator).print("- {s}\n", .{hit});
            }
        }
        try steps.append(allocator, .{
            .name = "forbidden_markers",
            .ok = marker_ok,
            .detail = if (marker_ok) "no blocker markers in source/docs" else "forbidden markers found",
        });
    } else {
        try steps.append(allocator, .{
            .name = "forbidden_markers",
            .ok = true,
            .detail = "skipped by --skip-marker-scan",
        });
    }

    if (!skip_bundle) {
        const release_id = try std.fmt.allocPrint(allocator, "prod-gate-{s}", .{ts});
        defer allocator.free(release_id);

        var bundle_ok = true;
        if (strict_ga) {
            cmdReleaseBundle(allocator, root, &.{ "--release-id", release_id, "--matrix-root", matrix_root }) catch {
                bundle_ok = false;
            };
        } else {
            cmdReleaseBundle(allocator, root, &.{ "--release-id", release_id, "--matrix-root", matrix_root, "--no-strict-ga" }) catch {
                bundle_ok = false;
            };
        }
        if (!bundle_ok) all_pass = false;
        try steps.append(allocator, .{
            .name = "release_bundle",
            .ok = bundle_ok,
            .detail = if (bundle_ok) "release bundle generated" else "release bundle generation failed",
        });
    } else {
        try steps.append(allocator, .{
            .name = "release_bundle",
            .ok = true,
            .detail = "skipped by --skip-bundle",
        });
    }

    try report.writer(allocator).print("checks:\n", .{});
    for (steps.items) |s| {
        try report.writer(allocator).print("- {s}: {s} ({s})\n", .{
            s.name,
            if (s.ok) "PASS" else "FAIL",
            s.detail,
        });
    }
    try report.writer(allocator).print("\nOVERALL: {s}\n", .{if (all_pass) "PASS" else "FAIL"});

    try writeFile(out, report.items);

    if (!all_pass) {
        std.debug.print("production gate failed: {s}\n", .{out});
        return ToolError.VerificationFailed;
    }

    std.debug.print("production gate passed: {s}\n", .{out});
}

fn cmdMatrixRun(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const host_platform = getHostPlatform();
    const platform: []const u8 = flags.get("platform") orelse host_platform;
    const profile_mode = mapGetOr(&flags, "profile-mode", "ephemeral");
    const strict_ga = strictGaEnabled(&flags, std.posix.getenv("STRICT_GA") orelse "0");
    const allow_platform_mismatch = std.mem.eql(u8, mapGetOr(&flags, "allow-platform-mismatch", "0"), "1");

    if (!allow_platform_mismatch and !std.mem.eql(u8, platform, host_platform) and !std.mem.eql(u8, host_platform, "unknown")) {
        std.debug.print("requested platform '{s}' does not match host '{s}'\n", .{ platform, host_platform });
        return ToolError.InvalidArgs;
    }

    var env = try setDefaultZigGlobalCache(allocator, root);
    defer env.deinit();

    if (strict_ga) {
        if (!(try commandExists(allocator, "gpg"))) {
            std.debug.print("strict GA requires gpg for signed matrix reports\n", .{});
            return ToolError.MissingDependency;
        }
        if (env.get("MATRIX_GPG_KEY_ID") == null) {
            std.debug.print("strict GA requires MATRIX_GPG_KEY_ID\n", .{});
            return ToolError.InvalidArgs;
        }
    }

    const ts = try nowStamp(allocator);
    defer allocator.free(ts);

    var out_dir_default: ?[]u8 = null;
    defer if (out_dir_default) |p| allocator.free(p);
    const out_dir_raw = flags.get("out") orelse blk: {
        out_dir_default = try pathJoin(allocator, &.{ root, "artifacts", "matrix", try std.fmt.allocPrint(allocator, "{s}-{s}", .{ platform, ts }) });
        break :blk out_dir_default.?;
    };
    const out_dir = try toAbsolutePath(allocator, root, out_dir_raw);
    defer allocator.free(out_dir);

    try ensurePath(out_dir);
    const logs_dir_init = try pathJoin(allocator, &.{ out_dir, "logs" });
    defer allocator.free(logs_dir_init);
    try ensurePath(logs_dir_init);

    var ok_all = true;
    if (!(try runStepWithLog(allocator, root, &env, out_dir, "test_pass_1", &.{ "zig", "build", "test" }))) ok_all = false;
    if (!(try runStepWithLog(allocator, root, &env, out_dir, "test_pass_2", &.{ "zig", "build", "test" }))) ok_all = false;
    if (!(try runStepWithLog(allocator, root, &env, out_dir, "test_extension", &.{ "zig", "build", "test", "-Denable_builtin_extension=true" }))) ok_all = false;
    if (!(try runStepWithLog(allocator, root, &env, out_dir, "run_binary", &.{ "zig", "build", "run" }))) ok_all = false;

    // Matrix runs may execute with STRICT_GA=1, but release-gate performs
    // strict matrix collection and would become cyclic inside matrix-run.
    var env_release_gate = try setDefaultZigGlobalCache(allocator, root);
    defer env_release_gate.deinit();
    try env_release_gate.put("STRICT_GA", "0");
    if (!(try runStepWithLog(allocator, root, &env_release_gate, out_dir, "release_gate", &.{ "zig", "build", "tools", "--", "release-gate" }))) ok_all = false;

    var enable_behavioral = std.mem.eql(u8, env.get("MATRIX_ENABLE_BEHAVIORAL") orelse "0", "1");
    if (strict_ga) enable_behavioral = true;

    if (enable_behavioral) {
        try env.put("BROWSER_DRIVER_BEHAVIORAL", "1");
        try env.put("WEBVIEW_BRIDGE_BEHAVIORAL", "1");

        if (strict_ga) {
            try env.put("BROWSER_DRIVER_BEHAVIORAL_STRICT", "1");
            try env.put("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT", "0");
            try env.put("WEBVIEW_BRIDGE_REQUIRED", "none");
            try env.put("ELECTRON_BEHAVIORAL", "1");
            try env.put("ELECTRON_BEHAVIORAL_STRICT", "1");
            try env.put("WEBKITGTK_BEHAVIORAL", "0");
            try env.put("WEBKITGTK_BEHAVIORAL_STRICT", "0");

            if (std.mem.eql(u8, platform, "linux")) {
                try env.put("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT", "1");
                try env.put("WEBVIEW_BRIDGE_REQUIRED", "android");
                try env.put("WEBKITGTK_BEHAVIORAL", "1");
                try env.put("WEBKITGTK_BEHAVIORAL_STRICT", "1");
            } else if (std.mem.eql(u8, platform, "macos")) {
                try env.put("WEBVIEW_BRIDGE_BEHAVIORAL_STRICT", "1");
                try env.put("WEBVIEW_BRIDGE_REQUIRED", "ios");
            }
        }

        if (!(try runStepWithLog(allocator, root, &env, out_dir, "behavioral_matrix", &.{ "zig", "build", "tools", "--", "test-behavioral-matrix" }))) ok_all = false;
    }

    const adversarial_report_path = try pathJoin(allocator, &.{ out_dir, "adversarial-detection.txt" });
    defer allocator.free(adversarial_report_path);
    if (!(try runStepWithLog(
        allocator,
        root,
        &env,
        out_dir,
        "adversarial_detection_gate",
        &.{ "zig", "build", "tools", "--", "adversarial-detection-gate", "--out", adversarial_report_path },
    ))) ok_all = false;

    const env_txt_path = try pathJoin(allocator, &.{ out_dir, "environment.txt" });
    const head_commit = runCaptureTrimmed(allocator, &.{ "git", "rev-parse", "HEAD" }, root, null) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(head_commit);
    const zig_ver = runCaptureTrimmed(allocator, &.{ "zig", "version" }, root, null) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(zig_ver);

    var env_txt: std.ArrayList(u8) = .empty;
    defer env_txt.deinit(allocator);
    try env_txt.writer(allocator).print(
        "platform={s}\nhost_uname={s}\nprofile_mode={s}\nstrict_ga={d}\ntimestamp_utc={s}\ngit_commit={s}\nzig_version={s}\n\n[browser_versions]\n",
        .{ platform, host_platform, profile_mode, @intFromBool(strict_ga), ts, head_commit, zig_ver },
    );

    const browser_cmds = [_][]const u8{
        "google-chrome --version",
        "google-chrome-stable --version",
        "chromium --version",
        "msedge --version",
        "firefox --version",
        "brave-browser --version",
        "vivaldi --version",
        "opera --version",
        "librewolf --version",
        "tor-browser --version",
        "electron --version",
        "WebKitWebDriver --version",
        "MiniBrowser --version",
    };

    for (browser_cmds) |cmd| {
        const res = runCaptureTrimmed(allocator, &.{ "bash", "-lc", cmd }, root, null) catch null;
        if (res) |line| {
            defer allocator.free(line);
            try env_txt.writer(allocator).print("{s} => {s}\n", .{ cmd, line });
        } else {
            try env_txt.writer(allocator).print("{s} => NOT_FOUND\n", .{cmd});
        }
    }

    try env_txt.appendSlice(allocator, "\n[mobile_bridge_tools]\n");
    for ([_][]const u8{ "adb", "shizuku", "rish", "ios_webkit_debug_proxy", "tidevice" }) |tool| {
        if (try commandExists(allocator, tool)) {
            const tool_path = try runCaptureTrimmed(allocator, &.{ if (isWindowsHost()) "where" else "which", tool }, null, null);
            defer allocator.free(tool_path);
            const first_line = std.mem.sliceTo(tool_path, '\n');
            try env_txt.writer(allocator).print("{s}={s}\n", .{ tool, first_line });
        } else {
            try env_txt.writer(allocator).print("{s}=NOT_FOUND\n", .{tool});
        }
    }

    try writeFile(env_txt_path, env_txt.items);

    const logs_dir = try pathJoin(allocator, &.{ out_dir, "logs" });
    defer allocator.free(logs_dir);

    var overall = true;
    var logs_abs = try std.fs.openDirAbsolute(logs_dir, .{ .iterate = true });
    defer logs_abs.close();
    var it = logs_abs.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".status")) continue;
        const status_path = try pathJoin(allocator, &.{ logs_dir, entry.name });
        defer allocator.free(status_path);
        const status_data = try readFileAlloc(allocator, status_path, 64);
        defer allocator.free(status_data);
        if (!std.mem.eql(u8, std.mem.trim(u8, status_data, "\r\n\t "), "PASS")) {
            overall = false;
            break;
        }
    }

    const report = try pathJoin(allocator, &.{ out_dir, "matrix-report.txt" });
    var rpt: std.ArrayList(u8) = .empty;
    defer rpt.deinit(allocator);
    try rpt.writer(allocator).print("Matrix Report\nplatform: {s}\ntimestamp_utc: {s}\ncommit: {s}\nprofile_mode: {s}\nstrict_ga: {d}\n\nChecks:\n", .{
        platform,
        ts,
        head_commit,
        profile_mode,
        @intFromBool(strict_ga),
    });

    var logs_abs2 = try std.fs.openDirAbsolute(logs_dir, .{ .iterate = true });
    defer logs_abs2.close();
    var it2 = logs_abs2.iterate();
    var status_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (status_paths.items) |p| allocator.free(p);
        status_paths.deinit(allocator);
    }
    while (try it2.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".status")) continue;
        const p = try pathJoin(allocator, &.{ logs_dir, entry.name });
        try status_paths.append(allocator, p);
    }
    std.mem.sort([]u8, status_paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (status_paths.items) |p| {
        const name = std.fs.path.stem(p);
        const status_data = try readFileAlloc(allocator, p, 64);
        defer allocator.free(status_data);
        const st = std.mem.trim(u8, status_data, "\r\n\t ");
        try rpt.writer(allocator).print("- {s}: {s}\n", .{ name, st });
    }

    try rpt.writer(allocator).print("\nOVERALL: {s}\n\n", .{if (overall) "PASS" else "FAIL"});
    const env_data = try readFileAlloc(allocator, env_txt_path, 4 * 1024 * 1024);
    defer allocator.free(env_data);
    try rpt.appendSlice(allocator, env_data);

    try writeFile(report, rpt.items);

    if ((try commandExists(allocator, "gpg")) and env.get("MATRIX_GPG_KEY_ID") != null) {
        const key = env.get("MATRIX_GPG_KEY_ID").?;
        const asc = try std.fmt.allocPrint(allocator, "{s}.asc", .{report});
        defer allocator.free(asc);
        try runInherit(allocator, &.{ "gpg", "--batch", "--yes", "--local-user", key, "--armor", "--detach-sign", "--output", asc, report }, root, null);
    }

    if (strict_ga) {
        const asc = try std.fmt.allocPrint(allocator, "{s}.asc", .{report});
        defer allocator.free(asc);
        if (std.fs.openFileAbsolute(asc, .{}) catch null == null) {
            std.debug.print("strict GA requires a signed report (.asc missing)\n", .{});
            return ToolError.VerificationFailed;
        }
    }

    if (!overall) {
        std.debug.print("matrix run failed: {s}\n", .{out_dir});
        return ToolError.VerificationFailed;
    }

    std.debug.print("matrix run complete: {s}\n", .{out_dir});
}

fn copyTree(allocator: Allocator, src_root: []const u8, dst_root: []const u8) !void {
    try ensurePath(dst_root);
    var src = try std.fs.openDirAbsolute(src_root, .{ .iterate = true });
    defer src.close();

    var walker = try src.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const src_path = try pathJoin(allocator, &.{ src_root, entry.path });
        defer allocator.free(src_path);
        const dst_path = try pathJoin(allocator, &.{ dst_root, entry.path });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .directory => try ensurePath(dst_path),
            .file => {
                if (std.fs.path.dirname(dst_path)) |parent| {
                    try ensurePath(parent);
                }
                try std.fs.copyFileAbsolute(src_path, dst_path, .{});
            },
            else => {},
        }
    }
}

fn sha256FileHex(allocator: Allocator, path: []const u8) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try allocator.dupe(u8, hex[0..]);
}

fn cmdReleaseBundle(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    var env = try setDefaultZigGlobalCache(allocator, root);
    defer env.deinit();

    const strict_ga_bundle = !std.mem.eql(u8, mapGetOr(&flags, "no-strict-ga", "0"), "1");

    var release_id = flags.get("release-id");
    const matrix_root = mapGetOr(&flags, "matrix-root", try pathJoin(allocator, &.{ root, "artifacts", "matrix" }));

    if (release_id == null) {
        const short = try runCaptureTrimmed(allocator, &.{ "git", "rev-parse", "--short", "HEAD" }, root, null);
        defer allocator.free(short);
        const ts = try nowStamp(allocator);
        defer allocator.free(ts);
        release_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ short, ts });
    }

    const summary_path = try pathJoin(allocator, &.{ matrix_root, try std.fmt.allocPrint(allocator, "matrix-summary-{s}.txt", .{release_id.?}) });
    if (std.mem.eql(u8, mapGetOr(&flags, "no-strict-ga", "0"), "1")) {
        try cmdMatrixCollect(allocator, root, &.{ "--matrix-root", matrix_root, "--out", summary_path });
    } else {
        try cmdMatrixCollect(allocator, root, &.{ "--strict-ga", "--matrix-root", matrix_root, "--out", summary_path });
    }

    try runInherit(allocator, &.{ "zig", "build", "-Doptimize=ReleaseSafe" }, root, &env);

    const bundle_dir = try pathJoin(allocator, &.{ root, "artifacts", "release", release_id.? });
    try ensurePath(bundle_dir);
    try ensurePath(try pathJoin(allocator, &.{ bundle_dir, "bin" }));
    try ensurePath(try pathJoin(allocator, &.{ bundle_dir, "docs" }));
    try ensurePath(try pathJoin(allocator, &.{ bundle_dir, "logs" }));

    const bin_unix = try pathJoin(allocator, &.{ root, "zig-out", "bin", "browser_driver" });
    const bin_win = try pathJoin(allocator, &.{ root, "zig-out", "bin", "browser_driver.exe" });
    const out_bin_unix = try pathJoin(allocator, &.{ bundle_dir, "bin", "browser_driver" });
    const out_bin_win = try pathJoin(allocator, &.{ bundle_dir, "bin", "browser_driver.exe" });
    defer {
        allocator.free(bin_unix);
        allocator.free(bin_win);
        allocator.free(out_bin_unix);
        allocator.free(out_bin_win);
    }

    if (std.fs.openFileAbsolute(bin_unix, .{}) catch null) |f| {
        f.close();
        try std.fs.copyFileAbsolute(bin_unix, out_bin_unix, .{});
    } else if (std.fs.openFileAbsolute(bin_win, .{}) catch null) |f| {
        f.close();
        try std.fs.copyFileAbsolute(bin_win, out_bin_win, .{});
    } else {
        std.debug.print("release binary not found in zig-out/bin\n", .{});
        return ToolError.NotFound;
    }

    const required_docs = [_][]const u8{ "known-limitations.md", "migration-v1.md", "support-matrix.md" };
    for (required_docs) |doc| {
        const src_doc = try pathJoin(allocator, &.{ root, "docs", doc });
        defer allocator.free(src_doc);
        const dst_doc = try pathJoin(allocator, &.{ bundle_dir, "docs", doc });
        defer allocator.free(dst_doc);
        try std.fs.copyFileAbsolute(src_doc, dst_doc, .{});
    }

    const summary_dst = try pathJoin(allocator, &.{ bundle_dir, "logs", std.fs.path.basename(summary_path) });
    defer allocator.free(summary_dst);
    try std.fs.copyFileAbsolute(summary_path, summary_dst, .{});

    const matrix_runs_dst = try pathJoin(allocator, &.{ bundle_dir, "logs", "matrix-runs" });
    defer allocator.free(matrix_runs_dst);
    try copyTree(allocator, matrix_root, matrix_runs_dst);

    const release_manifest = try pathJoin(allocator, &.{ bundle_dir, "release-manifest.txt" });
    defer allocator.free(release_manifest);
    const commit = runCaptureTrimmed(allocator, &.{ "git", "rev-parse", "HEAD" }, root, null) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(commit);
    const zig_ver = runCaptureTrimmed(allocator, &.{ "zig", "version" }, root, null) catch try allocator.dupe(u8, "unknown");
    defer allocator.free(zig_ver);
    const ts = try nowRfc3339(allocator);
    defer allocator.free(ts);
    const strict_val = if (strict_ga_bundle) "1" else "0";
    const manifest_data = try std.fmt.allocPrint(allocator, "release_id={s}\ngit_commit={s}\nzig_version={s}\ntimestamp_utc={s}\nstrict_ga_bundle={s}\n", .{ release_id.?, commit, zig_ver, ts, strict_val });
    defer allocator.free(manifest_data);
    try writeFile(release_manifest, manifest_data);

    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }
    var bdir = try std.fs.openDirAbsolute(bundle_dir, .{ .iterate = true });
    defer bdir.close();
    var walker = try bdir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, "SHA256SUMS") or std.mem.eql(u8, entry.path, "SHA256SUMS.asc")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]u8, files.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const sums_path = try pathJoin(allocator, &.{ bundle_dir, "SHA256SUMS" });
    defer allocator.free(sums_path);
    var sums: std.ArrayList(u8) = .empty;
    defer sums.deinit(allocator);
    for (files.items) |rel| {
        const abs = try pathJoin(allocator, &.{ bundle_dir, rel });
        defer allocator.free(abs);
        const hash = try sha256FileHex(allocator, abs);
        defer allocator.free(hash);
        try sums.writer(allocator).print("{s}  ./{s}\n", .{ hash, rel });
    }
    try writeFile(sums_path, sums.items);

    if ((try commandExists(allocator, "gpg")) and env.get("RELEASE_GPG_KEY_ID") != null) {
        const asc = try pathJoin(allocator, &.{ bundle_dir, "SHA256SUMS.asc" });
        defer allocator.free(asc);
        try runInherit(allocator, &.{ "gpg", "--batch", "--yes", "--local-user", env.get("RELEASE_GPG_KEY_ID").?, "--armor", "--detach-sign", "--output", asc, sums_path }, root, null);
    }

    const tarball = try pathJoin(allocator, &.{ root, "artifacts", "release", try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{release_id.?}) });
    defer allocator.free(tarball);
    try runInherit(allocator, &.{ "tar", "-C", try pathJoin(allocator, &.{ root, "artifacts", "release" }), "-czf", tarball, release_id.? }, root, null);

    std.debug.print("release bundle ready\nbundle_dir={s}\ntarball={s}\n", .{ bundle_dir, tarball });
}

fn cmdMatrixRunRemote(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const host = flags.get("host") orelse {
        std.debug.print("usage: matrix-run-remote --host <user@host> --platform <linux|windows|macos> --repo-path <remote path> [--port N] [--run-id ID] [--matrix-root DIR]\n", .{});
        return ToolError.InvalidArgs;
    };
    const platform = flags.get("platform") orelse return ToolError.InvalidArgs;
    const repo_path = flags.get("repo-path") orelse return ToolError.InvalidArgs;
    const port = mapGetOr(&flags, "port", "22");
    const matrix_root = mapGetOr(&flags, "matrix-root", try pathJoin(allocator, &.{ root, "artifacts", "matrix" }));
    const strict_ga = !std.mem.eql(u8, mapGetOr(&flags, "no-strict-ga", "0"), "1");

    var run_id = flags.get("run-id");
    if (run_id == null) {
        const ts = try nowStamp(allocator);
        defer allocator.free(ts);
        run_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ platform, ts });
    }

    try ensurePath(matrix_root);

    const strict_flag = if (strict_ga) " --strict-ga" else "";
    const matrix_key = std.posix.getenv("MATRIX_GPG_KEY_ID") orelse "";
    const remote_cmd = try std.fmt.allocPrint(
        allocator,
        "cd '{s}' && MATRIX_GPG_KEY_ID='{s}' MATRIX_ENABLE_BEHAVIORAL=1 zig build tools -- matrix-run --platform '{s}'{s} --out 'artifacts/matrix/{s}'",
        .{ repo_path, matrix_key, platform, strict_flag, run_id.? },
    );
    defer allocator.free(remote_cmd);

    try runInherit(allocator, &.{ "ssh", "-p", port, host, remote_cmd }, root, null);

    const src = try std.fmt.allocPrint(allocator, "{s}:{s}/artifacts/matrix/{s}", .{ host, repo_path, run_id.? });
    defer allocator.free(src);
    try runInherit(allocator, &.{ "scp", "-P", port, "-r", src, matrix_root }, root, null);

    const local_dir = try pathJoin(allocator, &.{ matrix_root, run_id.? });
    std.debug.print("remote matrix run collected\nrun_id={s}\nlocal_dir={s}\n", .{ run_id.?, local_dir });
}

fn readEnvConfig(allocator: Allocator, path: []const u8) !std.StringHashMap([]u8) {
    return try parseKvFile(allocator, path);
}

fn cmdMatrixGa(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const config_raw = flags.get("config") orelse {
        std.debug.print("usage: matrix-ga --config <env file> [--release-id ID] [--matrix-root DIR]\n", .{});
        return ToolError.InvalidArgs;
    };
    const config = try toAbsolutePath(allocator, root, config_raw);
    defer allocator.free(config);

    const cfg_file = std.fs.openFileAbsolute(config, .{}) catch {
        std.debug.print("config not found: {s}\n", .{config});
        return ToolError.NotFound;
    };
    cfg_file.close();

    var cfg = try readEnvConfig(allocator, config);
    defer freeStringMap(allocator, &cfg);

    var release_id = flags.get("release-id");
    var matrix_root = flags.get("matrix-root");
    if (matrix_root == null) matrix_root = try pathJoin(allocator, &.{ root, "artifacts", "matrix" });
    try ensurePath(matrix_root.?);

    if (release_id == null) {
        const ts = try nowStamp(allocator);
        defer allocator.free(ts);
        release_id = try std.fmt.allocPrint(allocator, "ga-{s}", .{ts});
    }

    const linux_mode = mapGetOr(&cfg, "LINUX_MODE", "local");
    const windows_mode = mapGetOr(&cfg, "WINDOWS_MODE", "ssh");
    const macos_mode = mapGetOr(&cfg, "MACOS_MODE", "ssh");

    if (std.mem.eql(u8, linux_mode, "local")) {
        const run_id = try std.fmt.allocPrint(allocator, "linux-{s}", .{release_id.?});
        defer allocator.free(run_id);
        try cmdMatrixRun(allocator, root, &.{ "--platform", "linux", "--strict-ga", "--out", try pathJoin(allocator, &.{ matrix_root.?, run_id }) });
    } else if (std.mem.eql(u8, linux_mode, "ssh")) {
        try cmdMatrixRunRemote(allocator, root, &.{ "--host", mapGetRequired(&cfg, "LINUX_SSH_HOST") catch return ToolError.InvalidArgs, "--port", mapGetOr(&cfg, "LINUX_SSH_PORT", "22"), "--platform", "linux", "--repo-path", mapGetRequired(&cfg, "LINUX_REPO_PATH") catch return ToolError.InvalidArgs, "--run-id", try std.fmt.allocPrint(allocator, "linux-{s}", .{release_id.?}), "--matrix-root", matrix_root.? });
    } else return ToolError.InvalidArgs;

    if (std.mem.eql(u8, windows_mode, "local")) {
        const run_id = try std.fmt.allocPrint(allocator, "windows-{s}", .{release_id.?});
        defer allocator.free(run_id);
        try cmdMatrixRun(allocator, root, &.{ "--platform", "windows", "--strict-ga", "--allow-platform-mismatch", "--out", try pathJoin(allocator, &.{ matrix_root.?, run_id }) });
    } else if (std.mem.eql(u8, windows_mode, "ssh")) {
        try cmdMatrixRunRemote(allocator, root, &.{ "--host", mapGetRequired(&cfg, "WINDOWS_SSH_HOST") catch return ToolError.InvalidArgs, "--port", mapGetOr(&cfg, "WINDOWS_SSH_PORT", "22"), "--platform", "windows", "--repo-path", mapGetRequired(&cfg, "WINDOWS_REPO_PATH") catch return ToolError.InvalidArgs, "--run-id", try std.fmt.allocPrint(allocator, "windows-{s}", .{release_id.?}), "--matrix-root", matrix_root.? });
    } else return ToolError.InvalidArgs;

    if (std.mem.eql(u8, macos_mode, "local")) {
        const run_id = try std.fmt.allocPrint(allocator, "macos-{s}", .{release_id.?});
        defer allocator.free(run_id);
        try cmdMatrixRun(allocator, root, &.{ "--platform", "macos", "--strict-ga", "--allow-platform-mismatch", "--out", try pathJoin(allocator, &.{ matrix_root.?, run_id }) });
    } else if (std.mem.eql(u8, macos_mode, "ssh")) {
        try cmdMatrixRunRemote(allocator, root, &.{ "--host", mapGetRequired(&cfg, "MACOS_SSH_HOST") catch return ToolError.InvalidArgs, "--port", mapGetOr(&cfg, "MACOS_SSH_PORT", "22"), "--platform", "macos", "--repo-path", mapGetRequired(&cfg, "MACOS_REPO_PATH") catch return ToolError.InvalidArgs, "--run-id", try std.fmt.allocPrint(allocator, "macos-{s}", .{release_id.?}), "--matrix-root", matrix_root.? });
    } else return ToolError.InvalidArgs;

    try cmdMatrixCollect(allocator, root, &.{ "--strict-ga", "--matrix-root", matrix_root.?, "--out", try pathJoin(allocator, &.{ matrix_root.?, try std.fmt.allocPrint(allocator, "matrix-summary-{s}.txt", .{release_id.?}) }) });
    try cmdReleaseBundle(allocator, root, &.{ "--release-id", release_id.?, "--matrix-root", matrix_root.? });

    std.debug.print("GA matrix and bundle complete\nrelease_id={s}\n", .{release_id.?});
}

fn cmdVmCheckPrereqs(allocator: Allocator, _: []const u8, _: []const []const u8) !void {
    var missing = false;
    const cmds = [_][]const u8{ "qemu-system-x86_64", "qemu-img", "ssh", "rsync", "curl", "python3", "ssh-keygen" };
    for (cmds) |cmd| {
        if (try commandExists(allocator, cmd)) {
            const p = try runCaptureTrimmed(allocator, &.{ if (isWindowsHost()) "where" else "which", cmd }, null, null);
            defer allocator.free(p);
            const first = std.mem.sliceTo(p, '\n');
            std.debug.print("OK: {s}={s}\n", .{ cmd, first });
        } else {
            std.debug.print("MISSING: {s}\n", .{cmd});
            missing = true;
        }
    }

    if (!isWindowsHost()) {
        if (std.fs.openFileAbsolute("/dev/kvm", .{}) catch null) |f| {
            f.close();
            std.debug.print("OK: /dev/kvm present\n", .{});
        } else {
            std.debug.print("WARN: /dev/kvm missing, VM will run with TCG only\n", .{});
        }
    }

    if (missing) return ToolError.MissingDependency;
}

fn vmProjectDir(allocator: Allocator, vm_lab_dir: []const u8, project: []const u8) ![]u8 {
    return try pathJoin(allocator, &.{ vm_lab_dir, "projects", project });
}

fn cmdVmInitLab(allocator: Allocator, _: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const project = mapGetOr(&flags, "project", "browser_driver");
    const vm_lab_dir = mapGetOr(&flags, "lab-dir", defaultVmLabDir());

    try ensurePath(try pathJoin(allocator, &.{ vm_lab_dir, "images" }));
    try ensurePath(try pathJoin(allocator, &.{ vm_lab_dir, "projects" }));
    try ensurePath(try pathJoin(allocator, &.{ vm_lab_dir, "hosts" }));
    try ensurePath(try pathJoin(allocator, &.{ vm_lab_dir, "artifacts" }));

    const project_dir = try vmProjectDir(allocator, vm_lab_dir, project);
    defer allocator.free(project_dir);
    try ensurePath(project_dir);
    try ensurePath(try pathJoin(allocator, &.{ project_dir, "logs" }));
    try ensurePath(try pathJoin(allocator, &.{ project_dir, "matrix" }));
    try ensurePath(try pathJoin(allocator, &.{ project_dir, "release" }));

    const readme = try pathJoin(allocator, &.{ vm_lab_dir, "README.md" });
    defer allocator.free(readme);
    try writeFile(
        readme,
        "# Shared VM Lab\n\nThis directory is reusable across projects.\n\n## Layout\n- images/: base and overlay images\n- projects/<name>/: project-specific VM state, logs, matrix reports, bundles\n- hosts/: remote host registration manifests\n- artifacts/: shared exports\n\nSet VM_LAB_DIR to override this location.\n",
    );

    std.debug.print("vm lab initialized\nvm_lab_dir={s}\nproject_dir={s}\n", .{ vm_lab_dir, project_dir });
}

fn cmdVmRegisterHost(allocator: Allocator, _: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const host_name = flags.get("name") orelse return ToolError.InvalidArgs;
    const os_name = flags.get("os") orelse return ToolError.InvalidArgs;
    const arch = flags.get("arch") orelse return ToolError.InvalidArgs;
    const address = flags.get("address") orelse return ToolError.InvalidArgs;
    const transport = mapGetOr(&flags, "transport", "ssh");
    const vm_lab_dir = mapGetOr(&flags, "lab-dir", defaultVmLabDir());

    try ensurePath(try pathJoin(allocator, &.{ vm_lab_dir, "hosts", host_name }));
    const manifest = try pathJoin(allocator, &.{ vm_lab_dir, "hosts", host_name, "host.env" });
    defer allocator.free(manifest);
    const data = try std.fmt.allocPrint(
        allocator,
        "HOST_NAME={s}\nOS_NAME={s}\nARCH={s}\nTRANSPORT={s}\nADDRESS={s}\n",
        .{ host_name, os_name, arch, transport, address },
    );
    defer allocator.free(data);
    try writeFile(manifest, data);

    std.debug.print("host registered\nmanifest={s}\n", .{manifest});
}

fn cmdVmCreateLinux(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const project = mapGetOr(&flags, "project", "browser_driver");
    const vm_name = mapGetOr(&flags, "name", "linux-matrix");
    const vm_user = mapGetOr(&flags, "user", "vmrunner");
    const ssh_port = mapGetOr(&flags, "ssh-port", "2222");
    const cloud_init_port = mapGetOr(&flags, "cloud-init-port", "8920");
    const vm_mem_mb = mapGetOr(&flags, "memory-mb", "8192");
    const vm_cpus = mapGetOr(&flags, "cpus", "4");
    const base_url = mapGetOr(&flags, "base-url", "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img");
    const base_sha256 = mapGetOr(&flags, "base-sha256", "");
    const vm_lab_dir = mapGetOr(&flags, "lab-dir", defaultVmLabDir());

    try cmdVmInitLab(allocator, root, &.{ "--project", project, "--lab-dir", vm_lab_dir });

    for ([_][]const u8{ "qemu-img", "qemu-system-x86_64", "curl", "ssh-keygen", "python3" }) |cmd| {
        if (!(try commandExists(allocator, cmd))) {
            std.debug.print("missing required command: {s}\n", .{cmd});
            return ToolError.MissingDependency;
        }
    }

    const project_dir = try vmProjectDir(allocator, vm_lab_dir, project);
    defer allocator.free(project_dir);
    const vm_dir = try pathJoin(allocator, &.{ project_dir, vm_name });
    defer allocator.free(vm_dir);
    try ensurePath(vm_dir);
    try ensurePath(try pathJoin(allocator, &.{ vm_lab_dir, "images" }));

    const base_img = try pathJoin(allocator, &.{ vm_lab_dir, "images", "ubuntu-noble-amd64.qcow2" });
    defer allocator.free(base_img);
    const overlay_img = try pathJoin(allocator, &.{ vm_dir, "disk.qcow2" });
    defer allocator.free(overlay_img);
    const cloud_init_dir = try pathJoin(allocator, &.{ vm_dir, "cloud-init" });
    defer allocator.free(cloud_init_dir);
    const user_data = try pathJoin(allocator, &.{ cloud_init_dir, "user-data" });
    defer allocator.free(user_data);
    const meta_data = try pathJoin(allocator, &.{ cloud_init_dir, "meta-data" });
    defer allocator.free(meta_data);
    const run_script = try pathJoin(allocator, &.{ vm_dir, "run.sh" });
    defer allocator.free(run_script);

    if (std.fs.openFileAbsolute(base_img, .{}) catch null == null) {
        std.debug.print("downloading base image: {s}\n", .{base_url});
        const tmp = try std.fmt.allocPrint(allocator, "{s}.partial", .{base_img});
        defer allocator.free(tmp);
        _ = std.fs.deleteFileAbsolute(tmp) catch {};
        try runInherit(allocator, &.{ "curl", "-fL", base_url, "-o", tmp }, root, null);
        if (base_sha256.len > 0) {
            if (!(try commandExists(allocator, "sha256sum"))) return ToolError.MissingDependency;
            const sh_cmd = try std.fmt.allocPrint(allocator, "echo '{s}  {s}' | sha256sum -c -", .{ base_sha256, tmp });
            defer allocator.free(sh_cmd);
            try runInherit(allocator, &.{ "bash", "-lc", sh_cmd }, root, null);
        }
        try std.fs.renameAbsolute(tmp, base_img);
    }

    if (std.fs.openFileAbsolute(overlay_img, .{}) catch null == null) {
        try runInherit(allocator, &.{ "qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", base_img, overlay_img, "80G" }, root, null);
    }

    const ssh_key = try pathJoin(allocator, &.{ vm_dir, "id_ed25519" });
    defer allocator.free(ssh_key);
    if (std.fs.openFileAbsolute(ssh_key, .{}) catch null == null) {
        try runInherit(allocator, &.{ "ssh-keygen", "-t", "ed25519", "-N", "", "-f", ssh_key }, root, null);
    }

    const pub_key_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{ssh_key});
    defer allocator.free(pub_key_path);
    const pub_key_raw = try readFileAlloc(allocator, pub_key_path, 8 * 1024);
    defer allocator.free(pub_key_raw);
    const pub_key = std.mem.trim(u8, pub_key_raw, "\r\n\t ");

    try ensurePath(cloud_init_dir);

    const user_data_text = try std.fmt.allocPrint(
        allocator,
        "#cloud-config\nusers:\n  - name: {s}\n    shell: /bin/bash\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys:\n      - {s}\npackage_update: true\npackages:\n  - git\n  - curl\n  - unzip\n  - build-essential\n  - gpg\n  - openssh-server\nruncmd:\n  - [ systemctl, enable, ssh ]\n  - [ systemctl, restart, ssh ]\n",
        .{ vm_user, pub_key },
    );
    defer allocator.free(user_data_text);
    try writeFile(user_data, user_data_text);

    const meta_data_text = try std.fmt.allocPrint(allocator, "instance-id: {s}\nlocal-hostname: {s}\n", .{ vm_name, vm_name });
    defer allocator.free(meta_data_text);
    try writeFile(meta_data, meta_data_text);

    const run_text = try std.fmt.allocPrint(
        allocator,
        "#!/usr/bin/env bash\nset -euo pipefail\n\nSCRIPT_DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\nCI_DIR=\"$SCRIPT_DIR/cloud-init\"\n\npython3 -m http.server {s} --bind 127.0.0.1 --directory \"$CI_DIR\" >\"/tmp/{s}-cloud-init.log\" 2>&1 &\nCI_PID=$!\ncleanup() {{\n  kill \"$CI_PID\" >/dev/null 2>&1 || true\n}}\ntrap cleanup EXIT\n\nqemu-system-x86_64 \\\n  -name \"{s}\" \\\n  -machine q35,accel=kvm:tcg \\\n  -cpu host \\\n  -smp {s} \\\n  -m {s} \\\n  -drive if=virtio,file=\"{s}\",format=qcow2 \\\n  -netdev user,id=n1,hostfwd=tcp::{s}-:22 \\\n  -device virtio-net-pci,netdev=n1 \\\n  -smbios type=1,serial=ds=nocloud-net;s=http://10.0.2.2:{s}/ \\\n  -nographic\n",
        .{ cloud_init_port, vm_name, vm_name, vm_cpus, vm_mem_mb, overlay_img, ssh_port, cloud_init_port },
    );
    defer allocator.free(run_text);
    try writeFile(run_script, run_text);
    if (!isWindowsHost()) {
        try runInherit(allocator, &.{ "chmod", "+x", run_script }, root, null);
    }

    const vm_env_path = try pathJoin(allocator, &.{ vm_dir, "vm.env" });
    defer allocator.free(vm_env_path);
    const vm_env = try std.fmt.allocPrint(
        allocator,
        "VM_NAME={s}\nVM_USER={s}\nSSH_PORT={s}\nSSH_KEY={s}\nRUN_SCRIPT={s}\nPROJECT_DIR={s}\nCLOUD_INIT_PORT={s}\n",
        .{ vm_name, vm_user, ssh_port, ssh_key, run_script, project_dir, cloud_init_port },
    );
    defer allocator.free(vm_env);
    try writeFile(vm_env_path, vm_env);

    std.debug.print("linux vm created\nvm_dir={s}\nrun_script={s}\nssh: ssh -i {s} -p {s} {s}@127.0.0.1\n", .{ vm_dir, run_script, ssh_key, ssh_port, vm_user });
}

fn loadVmEnv(allocator: Allocator, vm_env_path: []const u8) !VmEnv {
    var map = try parseKvFile(allocator, vm_env_path);
    defer freeStringMap(allocator, &map);

    return .{
        .vm_name = try allocator.dupe(u8, map.get("VM_NAME") orelse ""),
        .vm_user = try allocator.dupe(u8, map.get("VM_USER") orelse ""),
        .ssh_port = try allocator.dupe(u8, map.get("SSH_PORT") orelse ""),
        .ssh_key = try allocator.dupe(u8, map.get("SSH_KEY") orelse ""),
        .run_script = try allocator.dupe(u8, map.get("RUN_SCRIPT") orelse ""),
        .project_dir = try allocator.dupe(u8, map.get("PROJECT_DIR") orelse ""),
        .cloud_init_port = try allocator.dupe(u8, map.get("CLOUD_INIT_PORT") orelse ""),
    };
}

fn freeVmEnv(allocator: Allocator, vm: *const VmEnv) void {
    allocator.free(vm.vm_name);
    allocator.free(vm.vm_user);
    allocator.free(vm.ssh_port);
    allocator.free(vm.ssh_key);
    allocator.free(vm.run_script);
    allocator.free(vm.project_dir);
    allocator.free(vm.cloud_init_port);
}

fn cmdVmRunLinuxMatrix(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const project = mapGetOr(&flags, "project", "browser_driver");
    const vm_name = mapGetOr(&flags, "name", "linux-matrix");
    const workspace_repo = mapGetOr(&flags, "workspace", root);
    const remote_repo = mapGetOr(&flags, "remote-repo", "~/browser_driver");
    const strict_ga = mapGetOr(&flags, "strict-ga", "1");
    const matrix_behavioral = mapGetOr(&flags, "behavioral", "1");
    const vm_lab_dir = mapGetOr(&flags, "lab-dir", defaultVmLabDir());

    const vm_dir = try pathJoin(allocator, &.{ vm_lab_dir, "projects", project, vm_name });
    defer allocator.free(vm_dir);
    const vm_env_path = try pathJoin(allocator, &.{ vm_dir, "vm.env" });
    defer allocator.free(vm_env_path);

    if (std.fs.openFileAbsolute(vm_env_path, .{}) catch null == null) {
        std.debug.print("vm metadata missing: {s}\ncreate vm first: vm-create-linux\n", .{vm_env_path});
        return ToolError.NotFound;
    }

    var vm = try loadVmEnv(allocator, vm_env_path);
    defer freeVmEnv(allocator, &vm);

    if (!(try commandExists(allocator, "ssh")) or !(try commandExists(allocator, "rsync"))) {
        return ToolError.MissingDependency;
    }

    try runInherit(
        allocator,
        &.{
            "rsync",      "-a",                                                                                                                                             "--delete",
            "--exclude",  ".git",                                                                                                                                           "--exclude",
            ".zig-cache", "--exclude",                                                                                                                                      "zig-out",
            "--exclude",  "artifacts",                                                                                                                                      workspace_repo,
            "-e",         try std.fmt.allocPrint(allocator, "ssh -i {s} -p {s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null", .{ vm.ssh_key, vm.ssh_port }), try std.fmt.allocPrint(allocator, "{s}@127.0.0.1:{s}/", .{ vm.vm_user, remote_repo }),
        },
        root,
        null,
    );

    const remote_cmd = try std.fmt.allocPrint(
        allocator,
        "cd {s} && MATRIX_ENABLE_BEHAVIORAL={s} STRICT_GA={s} zig build tools -- matrix-run --platform linux",
        .{ remote_repo, matrix_behavioral, strict_ga },
    );
    defer allocator.free(remote_cmd);

    try runInherit(allocator, &.{ "ssh", "-i", vm.ssh_key, "-p", vm.ssh_port, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", try std.fmt.allocPrint(allocator, "{s}@127.0.0.1", .{vm.vm_user}), remote_cmd }, root, null);

    const ts = try nowStamp(allocator);
    defer allocator.free(ts);
    const local_matrix_dir = try pathJoin(allocator, &.{ vm_lab_dir, "projects", project, "matrix", try std.fmt.allocPrint(allocator, "{s}-{s}", .{ vm_name, ts }) });
    try ensurePath(local_matrix_dir);

    try runInherit(
        allocator,
        &.{
            "rsync",                                                                                                "-a",
            "-e",                                                                                                   try std.fmt.allocPrint(allocator, "ssh -i {s} -p {s} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null", .{ vm.ssh_key, vm.ssh_port }),
            try std.fmt.allocPrint(allocator, "{s}@127.0.0.1:{s}/artifacts/matrix/", .{ vm.vm_user, remote_repo }), local_matrix_dir,
        },
        root,
        null,
    );

    std.debug.print("linux vm matrix run complete\ncollected_matrix={s}\n", .{local_matrix_dir});
}

fn cmdVmRunRemoteMatrix(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const project = mapGetOr(&flags, "project", "browser_driver");
    const host_name = flags.get("host") orelse return ToolError.InvalidArgs;
    const remote_repo = mapGetOr(&flags, "remote-repo", "~/browser_driver");
    const strict_ga = mapGetOr(&flags, "strict-ga", "1");
    const matrix_behavioral = mapGetOr(&flags, "behavioral", "1");
    const ssh_key = mapGetOr(&flags, "ssh-key", "");
    const vm_lab_dir = mapGetOr(&flags, "lab-dir", defaultVmLabDir());

    const manifest = try pathJoin(allocator, &.{ vm_lab_dir, "hosts", host_name, "host.env" });
    defer allocator.free(manifest);
    if (std.fs.openFileAbsolute(manifest, .{}) catch null == null) {
        std.debug.print("host not registered: {s}\n", .{host_name});
        return ToolError.NotFound;
    }

    var host_map = try parseKvFile(allocator, manifest);
    defer freeStringMap(allocator, &host_map);

    const transport = host_map.get("TRANSPORT") orelse "";
    if (!std.mem.eql(u8, transport, "ssh")) {
        std.debug.print("unsupported transport in this script: {s}\n", .{transport});
        return ToolError.InvalidArgs;
    }
    const address = host_map.get("ADDRESS") orelse return ToolError.InvalidArgs;
    const os_name = host_map.get("OS_NAME") orelse "linux";

    var ssh_opts: std.ArrayList([]const u8) = .empty;
    defer ssh_opts.deinit(allocator);
    try ssh_opts.appendSlice(allocator, &.{ "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null" });
    if (ssh_key.len > 0) {
        try ssh_opts.appendSlice(allocator, &.{ "-i", ssh_key });
    }

    var ssh_opt_str: std.ArrayList(u8) = .empty;
    defer ssh_opt_str.deinit(allocator);
    var first = true;
    for (ssh_opts.items) |opt| {
        if (!first) try ssh_opt_str.append(allocator, ' ');
        first = false;
        try ssh_opt_str.writer(allocator).print("{s}", .{opt});
    }

    try runInherit(
        allocator,
        &.{
            "rsync",                                                            "-a",                                               "--delete",
            "--exclude",                                                        ".git",                                             "--exclude",
            ".zig-cache",                                                       "--exclude",                                        "zig-out",
            "--exclude",                                                        "artifacts",                                        "-e",
            try std.fmt.allocPrint(allocator, "ssh {s}", .{ssh_opt_str.items}), try std.fmt.allocPrint(allocator, "{s}/", .{root}), try std.fmt.allocPrint(allocator, "{s}:{s}/", .{ address, remote_repo }),
        },
        root,
        null,
    );

    var platform: []const u8 = "linux";
    if (std.mem.eql(u8, os_name, "macos")) platform = "macos";
    if (std.mem.eql(u8, os_name, "windows")) platform = "windows";

    const remote_cmd = try std.fmt.allocPrint(
        allocator,
        "cd {s} && MATRIX_ENABLE_BEHAVIORAL={s} STRICT_GA={s} zig build tools -- matrix-run --platform {s}",
        .{ remote_repo, matrix_behavioral, strict_ga, platform },
    );
    defer allocator.free(remote_cmd);

    var ssh_argv: std.ArrayList([]const u8) = .empty;
    defer ssh_argv.deinit(allocator);
    try ssh_argv.append(allocator, "ssh");
    try ssh_argv.appendSlice(allocator, ssh_opts.items);
    try ssh_argv.append(allocator, address);
    try ssh_argv.append(allocator, remote_cmd);
    try runInherit(allocator, ssh_argv.items, root, null);

    const ts = try nowStamp(allocator);
    defer allocator.free(ts);
    const local_matrix_dir = try pathJoin(allocator, &.{ vm_lab_dir, "projects", project, "matrix", try std.fmt.allocPrint(allocator, "{s}-{s}", .{ host_name, ts }) });
    try ensurePath(local_matrix_dir);

    try runInherit(
        allocator,
        &.{
            "rsync",                                                                                   "-a",
            "-e",                                                                                      try std.fmt.allocPrint(allocator, "ssh {s}", .{ssh_opt_str.items}),
            try std.fmt.allocPrint(allocator, "{s}:{s}/artifacts/matrix/", .{ address, remote_repo }), local_matrix_dir,
        },
        root,
        null,
    );

    std.debug.print("remote matrix run complete\ncollected_matrix={s}\n", .{local_matrix_dir});
}

fn cmdVmGaCollectAndBundle(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const project = mapGetOr(&flags, "project", "browser_driver");
    const linux_host = flags.get("linux-host") orelse return ToolError.InvalidArgs;
    const macos_host = flags.get("macos-host") orelse return ToolError.InvalidArgs;
    const windows_host = flags.get("windows-host") orelse return ToolError.InvalidArgs;
    const vm_lab_dir = mapGetOr(&flags, "lab-dir", defaultVmLabDir());

    var release_id = flags.get("release-id");
    if (release_id == null) {
        const ts = try nowStamp(allocator);
        defer allocator.free(ts);
        release_id = try std.fmt.allocPrint(allocator, "ga-{s}", .{ts});
    }

    const project_matrix_root = try pathJoin(allocator, &.{ vm_lab_dir, "projects", project, "matrix" });
    defer allocator.free(project_matrix_root);
    if (std.fs.openDirAbsolute(project_matrix_root, .{}) catch null == null) {
        std.debug.print("matrix root missing: {s}\n", .{project_matrix_root});
        return ToolError.NotFound;
    }

    const stage_matrix_root = try pathJoin(allocator, &.{ root, "artifacts", "matrix-ga", release_id.? });
    try ensurePath(stage_matrix_root);

    const hosts = [_][]const u8{ linux_host, macos_host, windows_host };
    for (hosts) |host| {
        var pdir = try std.fs.openDirAbsolute(project_matrix_root, .{ .iterate = true });
        defer pdir.close();
        var it = pdir.iterate();
        var matches: std.ArrayList([]u8) = .empty;
        defer {
            for (matches.items) |m| allocator.free(m);
            matches.deinit(allocator);
        }
        while (try it.next()) |e| {
            if (e.kind != .directory) continue;
            if (std.mem.startsWith(u8, e.name, host) and e.name.len > host.len and e.name[host.len] == '-') {
                try matches.append(allocator, try allocator.dupe(u8, e.name));
            }
        }
        if (matches.items.len == 0) {
            std.debug.print("no matrix evidence found for host: {s}\n", .{host});
            return ToolError.NotFound;
        }
        std.mem.sort([]u8, matches.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        const latest = matches.items[matches.items.len - 1];

        const src = try pathJoin(allocator, &.{ project_matrix_root, latest });
        defer allocator.free(src);
        const dst = try pathJoin(allocator, &.{ stage_matrix_root, latest });
        defer allocator.free(dst);
        try copyTree(allocator, src, dst);
    }

    const out = try pathJoin(allocator, &.{ stage_matrix_root, try std.fmt.allocPrint(allocator, "matrix-summary-{s}.txt", .{release_id.?}) });
    try cmdMatrixCollect(allocator, root, &.{ "--matrix-root", stage_matrix_root, "--out", out });
    try cmdReleaseBundle(allocator, root, &.{ "--release-id", release_id.?, "--matrix-root", stage_matrix_root });

    std.debug.print("ga bundle complete\nrelease_id={s}\nstage_matrix_root={s}\n", .{ release_id.?, stage_matrix_root });
}

fn cmdVmImageSources(allocator: Allocator, _: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const arch = mapGetOr(&flags, "arch", "amd64");
    if (!(std.mem.eql(u8, arch, "amd64") or std.mem.eql(u8, arch, "arm64"))) {
        std.debug.print("--arch must be amd64 or arm64\n", .{});
        return ToolError.InvalidArgs;
    }

    const vm_lab_dir = defaultVmLabDir();
    const out_dir = mapGetOr(&flags, "out-dir", try pathJoin(allocator, &.{ vm_lab_dir, "images" }));
    const check = std.mem.eql(u8, mapGetOr(&flags, "check", "0"), "1");
    const download = std.mem.eql(u8, mapGetOr(&flags, "download-ubuntu", "0"), "1");

    const ubuntu_current = try std.fmt.allocPrint(allocator, "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-{s}.img", .{arch});
    defer allocator.free(ubuntu_current);
    const ubuntu_release = try std.fmt.allocPrint(allocator, "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-{s}.img", .{arch});
    defer allocator.free(ubuntu_release);

    const windows_11 = "https://www.microsoft.com/software-download/windows11";
    const windows_11_arm64 = "https://www.microsoft.com/software-download/windows11arm64";
    const windows_eval = "https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise";
    const macos_downloads = "https://support.apple.com/en-us/102662";
    const macos_virtualization = "https://developer.apple.com/documentation/virtualization";
    const macos_deploy = "https://support.apple.com/guide/deployment/dep5980c3e3d/web";

    std.debug.print(
        "Linux (Ubuntu cloud images)\n  current: {s}\n  release: {s}\n\nWindows images (official Microsoft download pages)\n  Windows 11: {s}\n  Windows 11 ARM64: {s}\n  Windows 11 Enterprise Evaluation: {s}\n\nmacOS (official Apple docs)\n  Download paths: {s}\n  Virtualization framework docs: {s}\n  Enterprise deployment guidance: {s}\n",
        .{ ubuntu_current, ubuntu_release, windows_11, windows_11_arm64, windows_eval, macos_downloads, macos_virtualization, macos_deploy },
    );

    if (check) {
        if (!(try commandExists(allocator, "curl"))) return ToolError.MissingDependency;
        std.debug.print("\nHTTP checks:\n", .{});
        const urls = [_][]const u8{ ubuntu_current, ubuntu_release, windows_11, windows_11_arm64, windows_eval, macos_downloads, macos_virtualization, macos_deploy };
        for (urls) |u| {
            const code = runCaptureTrimmed(allocator, &.{ "curl", "-L", "-s", "-o", "/dev/null", "-A", "Mozilla/5.0", "--connect-timeout", "8", "--max-time", "40", "-w", "%{http_code}", u }, null, null) catch try allocator.dupe(u8, "000");
            defer allocator.free(code);
            if (std.mem.eql(u8, code, "000")) {
                std.debug.print("  {s} {s} (network/CDN blocked in current environment)\n", .{ code, u });
            } else {
                std.debug.print("  {s} {s}\n", .{ code, u });
            }
        }
    }

    if (download) {
        if (!(try commandExists(allocator, "curl"))) return ToolError.MissingDependency;
        try ensurePath(out_dir);
        const out_file = try pathJoin(allocator, &.{ out_dir, try std.fmt.allocPrint(allocator, "noble-server-cloudimg-{s}.img", .{arch}) });
        defer allocator.free(out_file);
        const tmp = try std.fmt.allocPrint(allocator, "{s}.partial", .{out_file});
        defer allocator.free(tmp);
        _ = std.fs.deleteFileAbsolute(tmp) catch {};
        std.debug.print("\ndownloading {s}\n", .{ubuntu_current});
        try runInherit(allocator, &.{ "curl", "-fL", ubuntu_current, "-o", tmp }, null, null);
        try std.fs.renameAbsolute(tmp, out_file);
        std.debug.print("saved: {s}\n", .{out_file});
    }
}

fn cmdVmQemuCreate(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const vm_root = std.posix.getenv("BROWSER_DRIVER_VM_ROOT") orelse "/tmp/codex-vms";
    const name = flags.get("name") orelse {
        std.debug.print("usage: vm-qemu-create --name <name> --platform <linux|windows|macos> [--iso <path>] [--disk-gb N] [--memory-mb N] [--cpus N] [--ssh-port N]\n", .{});
        return ToolError.InvalidArgs;
    };
    const platform = flags.get("platform") orelse return ToolError.InvalidArgs;
    const iso_path = mapGetOr(&flags, "iso", "");
    const disk_gb = mapGetOr(&flags, "disk-gb", "80");
    const memory_mb = mapGetOr(&flags, "memory-mb", "8192");
    const cpus = mapGetOr(&flags, "cpus", "4");
    const host_share = mapGetOr(&flags, "host-share-path", std.posix.getenv("BROWSER_DRIVER_VM_SHARE_PATH") orelse root);

    if (!(std.mem.eql(u8, platform, "linux") or std.mem.eql(u8, platform, "windows") or std.mem.eql(u8, platform, "macos"))) {
        std.debug.print("invalid platform: {s}\n", .{platform});
        return ToolError.InvalidArgs;
    }

    if (!(try commandExists(allocator, "qemu-img")) or !(try commandExists(allocator, "qemu-system-x86_64"))) {
        return ToolError.MissingDependency;
    }

    const ssh_port: []const u8 = flags.get("ssh-port") orelse if (std.mem.eql(u8, platform, "linux")) "2222" else if (std.mem.eql(u8, platform, "windows")) "2223" else "2224";

    const vm_dir = try pathJoin(allocator, &.{ vm_root, "browser_driver", platform, name });
    try ensurePath(vm_dir);
    const image_path = try pathJoin(allocator, &.{ vm_dir, "disk.qcow2" });
    if (std.fs.openFileAbsolute(image_path, .{}) catch null == null) {
        try runInherit(allocator, &.{ "qemu-img", "create", "-f", "qcow2", image_path, try std.fmt.allocPrint(allocator, "{s}G", .{disk_gb}) }, root, null);
    }

    if ((std.mem.eql(u8, platform, "windows") or std.mem.eql(u8, platform, "macos")) and iso_path.len == 0) {
        std.debug.print("platform '{s}' requires --iso for installer media\n", .{platform});
        return ToolError.InvalidArgs;
    }
    if (iso_path.len > 0 and std.fs.openFileAbsolute(iso_path, .{}) catch null == null) {
        std.debug.print("iso not found: {s}\n", .{iso_path});
        return ToolError.NotFound;
    }

    const vm_env = try pathJoin(allocator, &.{ vm_dir, "vm.env" });
    const vm_env_txt = try std.fmt.allocPrint(
        allocator,
        "VM_NAME=\"{s}\"\nVM_PLATFORM=\"{s}\"\nVM_DIR=\"{s}\"\nVM_IMAGE=\"{s}\"\nVM_ISO=\"{s}\"\nVM_MEMORY_MB=\"{s}\"\nVM_CPUS=\"{s}\"\nVM_SSH_PORT=\"{s}\"\nVM_HOST_SHARE_PATH=\"{s}\"\n",
        .{ name, platform, vm_dir, image_path, iso_path, memory_mb, cpus, ssh_port, host_share },
    );
    defer allocator.free(vm_env_txt);
    try writeFile(vm_env, vm_env_txt);

    const start = try pathJoin(allocator, &.{ vm_dir, "start.sh" });
    const start_txt =
        "#!/usr/bin/env bash\n" ++
        "set -euo pipefail\n\n" ++
        "SCRIPT_DIR=\"$(cd \"$(dirname \"$0\")\" && pwd)\"\n" ++
        "source \"$SCRIPT_DIR/vm.env\"\n\n" ++
        "args=(\n" ++
        "  -name \"$VM_NAME\"\n" ++
        "  -machine q35,accel=kvm:tcg\n" ++
        "  -cpu host\n" ++
        "  -smp \"$VM_CPUS\"\n" ++
        "  -m \"$VM_MEMORY_MB\"\n" ++
        "  -drive \"file=$VM_IMAGE,if=virtio,format=qcow2\"\n" ++
        "  -netdev \"user,id=net0,hostfwd=tcp::${VM_SSH_PORT}-:22\"\n" ++
        "  -device virtio-net-pci,netdev=net0\n" ++
        "  -virtfs \"local,path=$VM_HOST_SHARE_PATH,mount_tag=hostshare,security_model=none\"\n" ++
        ")\n\n" ++
        "if [[ -n \"$VM_ISO\" ]]; then\n" ++
        "  args+=( -cdrom \"$VM_ISO\" )\n" ++
        "fi\n\n" ++
        "if [[ \"${1:-}\" == \"--foreground\" ]]; then\n" ++
        "  qemu-system-x86_64 \"${args[@]}\"\n" ++
        "else\n" ++
        "  qemu-system-x86_64 \"${args[@]}\" -daemonize -display none\n" ++
        "fi\n";
    try writeFile(start, start_txt);
    if (!isWindowsHost()) {
        try runInherit(allocator, &.{ "chmod", "+x", start }, root, null);
    }

    std.debug.print("vm created\nvm_dir={s}\nstart_cmd={s}\n", .{ vm_dir, start });
}

fn cmdVmQemuList(allocator: Allocator, _: []const u8, _: []const []const u8) !void {
    const vm_root = std.posix.getenv("BROWSER_DRIVER_VM_ROOT") orelse "/tmp/codex-vms";
    const base = try pathJoin(allocator, &.{ vm_root, "browser_driver" });

    if (std.fs.openDirAbsolute(base, .{}) catch null == null) {
        std.debug.print("no VMs registered under {s}\n", .{base});
        return;
    }

    var root_dir = try std.fs.openDirAbsolute(base, .{ .iterate = true });
    defer root_dir.close();
    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "vm.env")) continue;
        const env_path = try pathJoin(allocator, &.{ base, entry.path });
        defer allocator.free(env_path);
        var kv = try parseKvFile(allocator, env_path);
        defer freeStringMap(allocator, &kv);
        std.debug.print("platform={s} name={s} dir={s} ssh_port={s}\n", .{
            kv.get("VM_PLATFORM") orelse "",
            kv.get("VM_NAME") orelse "",
            kv.get("VM_DIR") orelse "",
            kv.get("VM_SSH_PORT") orelse "",
        });
    }
}

fn cmdVmQemuStart(allocator: Allocator, root: []const u8, args: []const []const u8) !void {
    var flags = try parseFlags(allocator, args);
    defer freeStringMap(allocator, &flags);

    const vm_root = std.posix.getenv("BROWSER_DRIVER_VM_ROOT") orelse "/tmp/codex-vms";
    const name = flags.get("name") orelse {
        std.debug.print("usage: vm-qemu-start --name <name> --platform <linux|windows|macos> [--foreground]\n", .{});
        return ToolError.InvalidArgs;
    };
    const platform = flags.get("platform") orelse return ToolError.InvalidArgs;
    const foreground = std.mem.eql(u8, mapGetOr(&flags, "foreground", "0"), "1");

    const vm_dir = try pathJoin(allocator, &.{ vm_root, "browser_driver", platform, name });
    defer allocator.free(vm_dir);
    const start = try pathJoin(allocator, &.{ vm_dir, "start.sh" });
    defer allocator.free(start);

    if (std.fs.openFileAbsolute(start, .{}) catch null == null) {
        std.debug.print("vm start script not found: {s}\n", .{start});
        return ToolError.NotFound;
    }

    if (foreground) {
        try runInherit(allocator, &.{ start, "--foreground" }, root, null);
    } else {
        try runInherit(allocator, &.{start}, root, null);
    }
}

fn tmpAbsPath(allocator: Allocator, tmp: anytype, suffix: []const u8) ![]u8 {
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(base);
    if (suffix.len == 0) return std.fs.path.join(allocator, &.{base});
    return std.fs.path.join(allocator, &.{ base, suffix });
}

test "parseFlags parses valued and boolean flags" {
    const allocator = std.testing.allocator;
    var flags = try parseFlags(allocator, &.{ "--platform", "linux", "--strict-ga", "--out", "/tmp/out" });
    defer freeStringMap(allocator, &flags);

    try std.testing.expect(std.mem.eql(u8, flags.get("platform").?, "linux"));
    try std.testing.expect(std.mem.eql(u8, flags.get("strict-ga").?, "1"));
    try std.testing.expect(std.mem.eql(u8, flags.get("out").?, "/tmp/out"));
}

test "strictGaEnabled honors env default and explicit override" {
    const allocator = std.testing.allocator;

    var flags_env_only = try parseFlags(allocator, &.{ "--platform", "linux" });
    defer freeStringMap(allocator, &flags_env_only);
    try std.testing.expect(strictGaEnabled(&flags_env_only, "1"));
    try std.testing.expect(!strictGaEnabled(&flags_env_only, "0"));

    var flags_override = try parseFlags(allocator, &.{ "--platform", "linux", "--strict-ga", "0" });
    defer freeStringMap(allocator, &flags_override);
    try std.testing.expect(!strictGaEnabled(&flags_override, "1"));

    var flags_enable = try parseFlags(allocator, &.{ "--platform", "linux", "--strict-ga" });
    defer freeStringMap(allocator, &flags_enable);
    try std.testing.expect(strictGaEnabled(&flags_enable, "0"));
}

test "parseKvFile strips optional quotes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "env.txt",
        .data =
        \\KEY_A=value
        \\KEY_B="quoted value"
        \\KEY_C='single quoted'
        \\
        ,
    });

    const env_path = try tmpAbsPath(allocator, tmp, "env.txt");
    defer allocator.free(env_path);

    var kv = try parseKvFile(allocator, env_path);
    defer freeStringMap(allocator, &kv);

    try std.testing.expect(std.mem.eql(u8, kv.get("KEY_A").?, "value"));
    try std.testing.expect(std.mem.eql(u8, kv.get("KEY_B").?, "quoted value"));
    try std.testing.expect(std.mem.eql(u8, kv.get("KEY_C").?, "single quoted"));
}

test "matrix collect non-strict pass with single report" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("matrix/linux-run");
    try tmp.dir.writeFile(.{
        .sub_path = "matrix/linux-run/matrix-report.txt",
        .data =
        \\Matrix Report
        \\platform: linux
        \\strict_ga: 0
        \\Checks:
        \\- behavioral_matrix: PASS
        \\OVERALL: PASS
        \\adb=/usr/bin/adb
        \\ios_webkit_debug_proxy=NOT_FOUND
        \\tidevice=NOT_FOUND
        \\
        ,
    });

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const matrix_root = try tmpAbsPath(allocator, tmp, "matrix");
    defer allocator.free(matrix_root);
    const out = try tmpAbsPath(allocator, tmp, "matrix/summary.txt");
    defer allocator.free(out);

    try cmdMatrixCollect(allocator, root, &.{ "--matrix-root", matrix_root, "--out", out });

    const summary = try readFileAlloc(allocator, out, 1024 * 1024);
    defer allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "OVERALL: PASS") != null);
}

test "matrix collect strict mode fails without signed strict reports" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("matrix/linux-run");
    try tmp.dir.makePath("matrix/windows-run");
    try tmp.dir.makePath("matrix/macos-run");

    const report_data =
        \\Matrix Report
        \\strict_ga: 1
        \\Checks:
        \\- behavioral_matrix: PASS
        \\OVERALL: PASS
        \\adb=/usr/bin/adb
        \\ios_webkit_debug_proxy=/usr/bin/ios_webkit_debug_proxy
        \\tidevice=NOT_FOUND
        \\
    ;

    try tmp.dir.writeFile(.{ .sub_path = "matrix/linux-run/matrix-report.txt", .data = "platform: linux\n" ++ report_data });
    try tmp.dir.writeFile(.{ .sub_path = "matrix/windows-run/matrix-report.txt", .data = "platform: windows\n" ++ report_data });
    try tmp.dir.writeFile(.{ .sub_path = "matrix/macos-run/matrix-report.txt", .data = "platform: macos\n" ++ report_data });

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const matrix_root = try tmpAbsPath(allocator, tmp, "matrix");
    defer allocator.free(matrix_root);
    const out = try tmpAbsPath(allocator, tmp, "matrix/summary-strict.txt");
    defer allocator.free(out);

    try std.testing.expectError(
        ToolError.VerificationFailed,
        cmdMatrixCollect(allocator, root, &.{ "--strict-ga", "--matrix-root", matrix_root, "--out", out }),
    );
}

test "vm image sources rejects unsupported arch" {
    const allocator = std.testing.allocator;
    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try std.testing.expectError(
        ToolError.InvalidArgs,
        cmdVmImageSources(allocator, root, &.{ "--arch", "ppc64" }),
    );
}

test "forbidden marker scan detects source markers and ignores artifacts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.makePath("artifacts");

    try tmp.dir.writeFile(.{
        .sub_path = "src/file.zig",
        .data = "const x = 1; // " ++ ("TO" ++ "DO:") ++ " remove\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "artifacts/generated.txt",
        .data = ("TO" ++ "DO:") ++ " should be ignored in artifacts\n",
    });

    const cwd_abs = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_abs);
    const rel_root = try tmpAbsPath(allocator, tmp, "");
    defer allocator.free(rel_root);
    const abs_root = try pathJoin(allocator, &.{ cwd_abs, rel_root });
    defer allocator.free(abs_root);

    var hits = try scanForbiddenMarkers(allocator, abs_root, 20);
    defer {
        for (hits.items) |h| allocator.free(h);
        hits.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expect(std.mem.indexOf(u8, hits.items[0], "src/file.zig:1") != null);
}

test "adversarial classification marks webdriver signal as detected" {
    var signals: DetectionSignals = .{};
    signals.js_webdriver_true = true;

    const classification = classifySignals(signals);
    try std.testing.expect(classification.detected);
    try std.testing.expectEqual(@as(usize, 1), classification.signal_count);
    try std.testing.expectEqual(@as(usize, 1), classification.high_confidence_count);
}

test "adversarial classification requires threshold when no high confidence signals" {
    var signals: DetectionSignals = .{};
    signals.runtime_minibrowser = true;
    signals.runtime_electron = true;
    signals.launch_arg_profile = true;

    const classification = classifySignals(signals);
    try std.testing.expect(!classification.detected);
    try std.testing.expectEqual(@as(usize, 3), classification.signal_count);
    try std.testing.expectEqual(@as(usize, 0), classification.high_confidence_count);
}

test "adversarial classification ignores transport and endpoint markers without web observable signals" {
    var signals: DetectionSignals = .{};
    signals.endpoint_cdp = true;
    signals.transport_cdp = true;
    signals.launch_arg_remote_debugging = true;
    signals.profile_ephemeral_dir = true;

    const classification = classifySignals(signals);
    try std.testing.expect(!classification.detected);
    try std.testing.expectEqual(@as(usize, 4), classification.signal_count);
    try std.testing.expectEqual(@as(usize, 0), classification.high_confidence_count);
}

test "collectSessionSignals captures endpoint and launch argument markers" {
    const allocator = std.testing.allocator;
    var session = try driver.attach(allocator, "cdp://127.0.0.1:9222/devtools/page/1");
    defer session.deinit();

    const argv = try allocator.alloc([]const u8, 4);
    argv[0] = try allocator.dupe(u8, "/usr/bin/chrome");
    argv[1] = try allocator.dupe(u8, "--remote-debugging-port=9222");
    argv[2] = try allocator.dupe(u8, "--headless=new");
    argv[3] = try allocator.dupe(u8, "--disable-blink-features=AutomationControlled");
    session.owned_argv = argv;
    session.ephemeral_profile_dir = try allocator.dupe(u8, "/tmp/browser-driver-ephemeral-test");

    var signals: DetectionSignals = .{};
    collectSessionSignals(&signals, &session);

    try std.testing.expect(signals.endpoint_cdp);
    try std.testing.expect(signals.transport_cdp);
    try std.testing.expect(signals.launch_arg_remote_debugging);
    try std.testing.expect(signals.launch_arg_headless);
    try std.testing.expect(signals.launch_arg_disable_blink_automation);
    try std.testing.expect(signals.profile_ephemeral_dir);
}

test "collectRuntimeSignals captures webview runtime and bridge markers" {
    var signals: DetectionSignals = .{};
    collectRuntimeSignals(
        &signals,
        .android_webview,
        "/opt/msedgewebview2/msedgewebview2.exe",
        "/usr/local/bin/shizuku",
    );

    try std.testing.expect(signals.runtime_msedgewebview2);
    try std.testing.expect(signals.bridge_shizuku);
    try std.testing.expect(signals.webview_mobile_runtime);
}

test "targetBrowserKindsForHost returns host-specific deterministic list" {
    const allocator = std.testing.allocator;
    const kinds = try targetBrowserKindsForHost(allocator);
    defer allocator.free(kinds);

    try std.testing.expect(kinds.len > 0);
    if (@import("builtin").os.tag == .macos) {
        try std.testing.expect(std.mem.indexOfScalar(driver.BrowserKind, kinds, .safari) != null);
    } else {
        try std.testing.expect(std.mem.indexOfScalar(driver.BrowserKind, kinds, .safari) == null);
    }
}

test "matrix collect summary records adversarial step status" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("matrix/linux-run");
    try tmp.dir.writeFile(.{
        .sub_path = "matrix/linux-run/matrix-report.txt",
        .data =
        \\Matrix Report
        \\platform: linux
        \\strict_ga: 0
        \\Checks:
        \\- behavioral_matrix: PASS
        \\- adversarial_detection_gate: PASS
        \\OVERALL: PASS
        \\adb=/usr/bin/adb
        \\ios_webkit_debug_proxy=NOT_FOUND
        \\tidevice=NOT_FOUND
        \\
        ,
    });

    const root = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const matrix_root = try tmpAbsPath(allocator, tmp, "matrix");
    defer allocator.free(matrix_root);
    const out = try tmpAbsPath(allocator, tmp, "matrix/summary.txt");
    defer allocator.free(out);

    try cmdMatrixCollect(allocator, root, &.{ "--matrix-root", matrix_root, "--out", out });

    const summary = try readFileAlloc(allocator, out, 1024 * 1024);
    defer allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "adversarial_pass: 1") != null);
}
