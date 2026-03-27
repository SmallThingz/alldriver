const std = @import("std");
const builtin = @import("builtin");

const types = @import("../types.zig");
const common = @import("../protocol/common.zig");
const core_session = @import("../core/session.zig");
const core_actions = @import("../core/actions.zig");
const core_artifacts = @import("../core/artifacts.zig");
const core_storage = @import("../core/storage.zig");
const browser_kind = @import("../catalog/browser_kind.zig");
const path_table = @import("../catalog/path_table.zig");
const discovery_util = @import("../discovery/util.zig");
const errors = @import("../errors.zig");
const modern_session_mod = @import("../modern/session.zig");
const modern_log = @import("../modern/log.zig");
const runtime_client = @import("../modern/runtime_client.zig");
const input_client = @import("../modern/input.zig");
const network_client = @import("../modern/network.zig");
const storage_client = @import("../modern/storage.zig");
const page_client = @import("../modern/page.zig");
const session_common = @import("../tier/session_common.zig");
const modern_executor = @import("../protocol/modern_executor.zig");
const compat = @import("../util/compat.zig");
const io_util = @import("../util/io.zig");

fn makeSession(
    allocator: std.mem.Allocator,
    transport: common.TransportKind,
    capability_set: types.CapabilitySet,
    endpoint: ?[]const u8,
) !core_session.Session {
    const install_kind: types.BrowserKind = switch (transport) {
        .cdp_ws => .chrome,
        .bidi_ws => .firefox,
    };
    const install_engine: types.EngineKind = switch (transport) {
        .cdp_ws => .chromium,
        .bidi_ws => .gecko,
    };
    return .{
        .allocator = allocator,
        .id = 1,
        .mode = .browser,
        .transport = transport,
        .install = .{
            .kind = install_kind,
            .engine = install_engine,
            .path = try allocator.dupe(u8, "synthetic-browser"),
            .version = try allocator.dupe(u8, "0"),
            .source = .explicit,
        },
        .capability_set = capability_set,
        .adapter_kind = switch (transport) {
            .cdp_ws => .cdp,
            .bidi_ws => .bidi,
        },
        .endpoint = if (endpoint) |value| try allocator.dupe(u8, value) else null,
    };
}

fn makeModernSession(
    allocator: std.mem.Allocator,
    transport: common.TransportKind,
    capability_set: types.CapabilitySet,
    endpoint: ?[]const u8,
) !modern_session_mod.ModernSession {
    return modern_session_mod.ModernSession.fromBase(try makeSession(allocator, transport, capability_set, endpoint));
}

fn dummyLogCallback(_: modern_log.LogEntry) void {}
fn dummyRequestCallback(_: types.RequestEvent) void {}
fn dummyResponseCallback(_: types.ResponseEvent) void {}

test "surface coverage for catalog, type filters, and formatted errors" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(browser_kind.BrowserKind.lightpanda, browser_kind.parseBrowserKind("Lightpanda Browser").?);
    try std.testing.expect(browser_kind.parseBrowserKind("definitely-not-a-browser") == null);

    inline for (.{ types.Platform.windows, .macos, .linux }) |platform| {
        for (path_table.all_browser_kinds) |kind| {
            const hints = path_table.hintsFor(kind, platform);
            try std.testing.expectEqual(kind, hints.kind);
            try std.testing.expectEqual(platform, hints.platform);
            try std.testing.expectEqual(browser_kind.engineFor(kind), hints.engine);
        }
    }

    var installs = types.BrowserInstallList{
        .allocator = allocator,
        .items = try allocator.alloc(types.BrowserInstall, 2),
        .owned_len = 2,
    };
    defer installs.deinit();
    installs.items[0] = .{
        .kind = .chrome,
        .engine = .chromium,
        .path = try allocator.dupe(u8, "chrome"),
        .version = null,
        .source = .explicit,
    };
    installs.items[1] = .{
        .kind = .safari,
        .engine = .webkit,
        .path = try allocator.dupe(u8, "safari"),
        .version = try allocator.dupe(u8, "17"),
        .source = .known_path,
    };
    installs.retainByTier(.modern);
    try std.testing.expectEqual(@as(usize, 1), installs.items.len);
    try std.testing.expectEqual(types.BrowserKind.chrome, installs.items[0].kind);

    var webviews = types.WebViewRuntimeList{
        .allocator = allocator,
        .items = try allocator.alloc(types.WebViewRuntime, 1),
        .owned_len = 1,
    };
    defer webviews.deinit();
    webviews.items[0] = .{
        .kind = .electron,
        .engine = .chromium,
        .platform = .linux,
        .runtime_path = try allocator.dupe(u8, "electron"),
        .bridge_tool_path = null,
        .source = .explicit,
        .version = try allocator.dupe(u8, "1"),
    };
    webviews.retainByTier(.modern);
    try std.testing.expectEqual(@as(usize, 1), webviews.items.len);
    try std.testing.expectEqual(types.WebViewKind.electron, webviews.items[0].kind);

    try std.testing.expectEqual(types.WaitTargetTag.dom_ready, std.meta.activeTag(types.WaitTarget{ .dom_ready = {} }));

    const msg = try errors.formatUnsupported(allocator, .{
        .engine = .chromium,
        .browser = .chrome,
        .feature = .downloads,
        .reason = "feature gated",
    });
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "feature=downloads") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "browser=chrome") != null);

    _ = errors.ProtocolError;
    _ = errors.TransportError;
    _ = errors.CapabilityError;
    _ = errors.TimeoutError;
    _ = errors.WaitError;
    _ = errors.CancellationError;
    _ = errors.DiscoveryError;
    _ = errors.LaunchError;
    _ = errors.WebViewError;
    _ = errors.SessionCacheError;
}

test "surface coverage for discovery helpers and compat filesystem wrappers" {
    const allocator = std.testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-surface-{d}", .{compat.nanoTimestamp()});
    defer allocator.free(root);
    defer compat.cwd().deleteTree(root) catch {};

    const file_rel = try std.fmt.allocPrint(allocator, "{s}/payload.txt", .{root});
    defer allocator.free(file_rel);
    const copied_rel = try std.fmt.allocPrint(allocator, "{s}/payload-copy.txt", .{root});
    defer allocator.free(copied_rel);
    const moved_rel = try std.fmt.allocPrint(allocator, "{s}/payload-moved.txt", .{root});
    defer allocator.free(moved_rel);
    const created_rel = try std.fmt.allocPrint(allocator, "{s}/created.txt", .{root});
    defer allocator.free(created_rel);

    try compat.cwd().makePath(root);
    try compat.cwd().writeFile(.{ .sub_path = file_rel, .data = "hello" });
    try std.testing.expect(discovery_util.exists(file_rel));
    try std.testing.expect(!discovery_util.exists("this/path/should/not/exist"));

    const file_contents = try compat.cwd().readFileAlloc(allocator, file_rel, 64);
    defer allocator.free(file_contents);
    try std.testing.expectEqualStrings("hello", file_contents);

    try compat.cwd().copyFile(file_rel, compat.cwd(), copied_rel, .{});
    try compat.cwd().rename(copied_rel, moved_rel);
    const moved_real = try compat.cwd().realpathAlloc(allocator, moved_rel);
    defer allocator.free(moved_real);
    try std.testing.expect(std.mem.endsWith(u8, moved_real, "payload-moved.txt"));

    const created = try compat.cwd().createFile(created_rel, .{ .truncate = true });
    created.close(compat.io());
    const opened = try compat.cwd().openFile(file_rel, .{});
    opened.close(compat.io());

    const normalized = try discovery_util.normalizePathForKey(allocator, "MiXeD/Path");
    defer allocator.free(normalized);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("mixed/path", normalized);
        try std.testing.expect(discovery_util.isLaunchable(file_rel));
    } else {
        try std.testing.expectEqualStrings("MiXeD/Path", normalized);
        try std.testing.expect(!discovery_util.isLaunchable(file_rel));
    }

    const expanded = try discovery_util.expandEnvTemplates(allocator, "%ALLDRIVER_SURFACE_TEST_MISSING_ENV%/driver");
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("%ALLDRIVER_SURFACE_TEST_MISSING_ENV%/driver", expanded);
    try std.testing.expectError(
        error.EnvironmentVariableMissing,
        compat.getEnvVarOwned(allocator, "ALLDRIVER_SURFACE_TEST_MISSING_ENV"),
    );

    const abs_root = try compat.cwd().realpathAlloc(allocator, root);
    defer allocator.free(abs_root);
    var abs_dir = try compat.openDirAbsolute(abs_root, .{});
    defer abs_dir.close(compat.io());
    try compat.dirMakePath(abs_dir, "nested");
    try compat.dirWriteFile(abs_dir, .{ .sub_path = "nested/from-dir.txt", .data = "dir-write" });
    const nested_real = try compat.dirRealpathAlloc(abs_dir, allocator, "nested/from-dir.txt");
    defer allocator.free(nested_real);
    try std.testing.expect(std.mem.endsWith(u8, nested_real, "from-dir.txt"));

    const abs_created_path = try std.fmt.allocPrint(allocator, "{s}/abs-created.txt", .{abs_root});
    defer allocator.free(abs_created_path);
    const abs_created = try compat.createFileAbsolute(abs_created_path, .{ .truncate = true });
    abs_created.close(compat.io());
    const abs_opened = try compat.openFileAbsolute(abs_created_path, .{});
    abs_opened.close(compat.io());

    var mutex: compat.Mutex = .{};
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
    mutex.lock();
    mutex.unlock();

    var cond: compat.Condition = .{};
    cond.signal();
    cond.broadcast();

    try std.testing.expect(compat.milliTimestamp() > 0);
    try std.testing.expect(compat.nanoTimestamp() > 0);
    try std.testing.expect(compat.timestamp() > 0);
    compat.sleepMs(0);
    compat.sleepNs(0);
}

test "surface coverage for core and modern wrapper modules" {
    const allocator = std.testing.allocator;
    const no_caps: types.CapabilitySet = .{
        .dom = false,
        .js_eval = false,
        .network_intercept = false,
        .tracing = false,
        .downloads = false,
        .bidi_events = false,
    };
    var restricted = try makeSession(allocator, .cdp_ws, no_caps, null);
    defer restricted.deinit();

    try std.testing.expectError(error.UnsupportedCapability, core_actions.navigate(&restricted, "https://example.com"));
    try std.testing.expectError(error.UnsupportedCapability, core_actions.reload(&restricted));
    try std.testing.expectError(error.UnsupportedCapability, core_actions.click(&restricted, "#btn"));
    try std.testing.expectError(error.UnsupportedCapability, core_actions.typeText(&restricted, "#btn", "abc"));
    try std.testing.expectError(error.UnsupportedCapability, core_actions.evaluate(&restricted, "1 + 1"));
    try std.testing.expectError(error.UnsupportedCapability, core_artifacts.screenshot(&restricted, allocator, .png));
    try std.testing.expectError(error.UnsupportedCapability, core_artifacts.startTracing(&restricted));
    try std.testing.expectError(error.UnsupportedCapability, core_artifacts.stopTracing(&restricted, allocator));
    try std.testing.expectError(error.UnsupportedCapability, core_artifacts.listDownloads(&restricted, allocator));
    try std.testing.expectError(error.UnsupportedCapability, core_storage.setCookie(&restricted, .{
        .name = "sid",
        .value = "abc",
        .domain = "example.com",
    }));
    try std.testing.expectError(error.UnsupportedCapability, core_storage.getCookies(&restricted, allocator));
    try std.testing.expectError(error.UnsupportedCapability, core_storage.setLocalStorage(&restricted, "k", "v"));
    try std.testing.expectError(error.UnsupportedCapability, core_storage.clearStorage(&restricted));

    var modern = try makeModernSession(allocator, .cdp_ws, common.defaultCapabilityForEngine(.chromium), null);
    defer modern.deinit();

    try std.testing.expect(modern.supports(.dom));
    try std.testing.expect(modern.capabilities().network_intercept);
    modern.setTimeoutPolicy(.{ .wait_ms = 1234 });
    try std.testing.expectEqual(@as(u32, 1234), modern.timeoutPolicy().wait_ms);
    try std.testing.expect(modern.lastDiagnostic() == null);
    try std.testing.expect(!modern.offEvent(999));

    var page = modern.page();
    try std.testing.expectEqual(@TypeOf(page), page_client.PageClient);
    try std.testing.expectError(error.MissingEndpoint, page.navigate("https://example.com"));
    try std.testing.expectError(error.MissingEndpoint, page.goBack());
    try std.testing.expectError(error.MissingEndpoint, page.goForward());
    try std.testing.expectError(error.MissingEndpoint, page.setViewport(1280, 720));
    try std.testing.expectError(error.MissingEndpoint, modern.screenshot(allocator, .png));

    var runtime = modern.runtime();
    try std.testing.expectEqual(@TypeOf(runtime), runtime_client.RuntimeClient);
    try std.testing.expectError(error.MissingEndpoint, runtime.evaluate("1 + 1"));
    try std.testing.expectError(error.MissingEndpoint, runtime.callFunction("(x) => x", "[1]"));
    try std.testing.expectError(error.MissingEndpoint, runtime.releaseHandle("handle-1"));

    var input = modern.input();
    try std.testing.expectEqual(@TypeOf(input), input_client.InputClient);
    try std.testing.expectError(error.MissingEndpoint, input.click("#btn"));
    try std.testing.expectError(error.MissingEndpoint, input.typeText("#btn", "abc"));
    try std.testing.expectError(error.MissingEndpoint, input.keyDown("A"));
    try std.testing.expectError(error.MissingEndpoint, input.keyUp("A"));
    try std.testing.expectError(error.MissingEndpoint, input.mouseMove(10, 20));
    try std.testing.expectError(error.MissingEndpoint, input.wheel(1, -1));

    var network = modern.network();
    try std.testing.expectEqual(@TypeOf(network), network_client.NetworkClient);
    network.onRequest(dummyRequestCallback);
    network.onResponse(dummyResponseCallback);
    try std.testing.expectError(error.MissingEndpoint, network.enable());
    try network.disable();
    try std.testing.expect(!(try network.removeRule("missing-rule")));
    const records = try network.records(allocator, false);
    defer network.freeRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
    const frames = try network.frames(allocator);
    defer network.freeFrames(allocator, frames);
    try std.testing.expectEqual(@as(usize, 0), frames.len);
    const workers = try network.serviceWorkers(allocator);
    defer network.freeServiceWorkers(allocator, workers);
    try std.testing.expectEqual(@as(usize, 0), workers.len);
    network.clearRecords();
    network.clearNavigationSnapshots();

    var storage = modern.storage();
    try std.testing.expectEqual(@TypeOf(storage), storage_client.StorageClient);
    try std.testing.expectError(error.MissingEndpoint, storage.setCookie(.{
        .name = "sid",
        .value = "abc",
        .domain = "example.com",
    }));
    try std.testing.expectError(error.MissingEndpoint, storage.getCookies(allocator));
    try std.testing.expectError(error.MissingEndpoint, storage.queryCookies(allocator, .{ .name = "sid" }));
    try std.testing.expectError(error.MissingEndpoint, storage.buildCookieHeaderForUrl(allocator, "https://example.com", .{}));
    try std.testing.expectError(error.MissingEndpoint, storage.setLocalStorage("k", "v"));
    try std.testing.expectError(error.MissingEndpoint, storage.getLocalStorage("k"));
    try std.testing.expectError(error.MissingEndpoint, storage.setSessionStorage("k", "v"));
    try std.testing.expectError(error.MissingEndpoint, storage.getSessionStorage("k"));
    try std.testing.expectError(error.MissingEndpoint, storage.clear());

    var log = modern.log();
    try std.testing.expectEqual(@TypeOf(log), modern_log.LogClient);
    try std.testing.expectError(error.UnsupportedProtocol, log.onConsole(dummyLogCallback));
    try std.testing.expectError(error.UnsupportedProtocol, log.onException(dummyLogCallback));

    try std.testing.expectError(error.MissingEndpoint, modern.addInitScript("window.__driver = true;"));
    try std.testing.expectError(error.MissingEndpoint, modern.removeInitScript("script-1"));
}

test "surface coverage for modern executor and session_common wrappers" {
    const allocator = std.testing.allocator;
    const caps = common.defaultCapabilityForEngine(.chromium);

    var cdp_session = try makeSession(allocator, .cdp_ws, caps, null);
    defer cdp_session.deinit();
    try std.testing.expectError(error.MissingEndpoint, modern_executor.navigate(&cdp_session, "https://example.com"));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.reload(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.click(&cdp_session, "#btn"));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.typeText(&cdp_session, "#btn", "abc"));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.evaluate(&cdp_session, "1 + 1"));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.screenshot(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.startTracing(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.stopTracing(&cdp_session));
    try std.testing.expectError(error.MissingEndpoint, modern_executor.enableNetworkInterception(&cdp_session));
    try modern_executor.disableNetworkInterception(&cdp_session);
    try std.testing.expectError(error.MissingEndpoint, modern_executor.addNetworkRule(&cdp_session, .{
        .id = "rule-1",
        .url_pattern = "*",
        .action = .{ .block = {} },
    }));

    var passthrough = try session_common.fromBase(try makeSession(allocator, .cdp_ws, caps, null), .modern);
    defer passthrough.deinit();
    try std.testing.expect(session_common.capabilities(&passthrough).dom);
    try std.testing.expect(session_common.supports(&passthrough, .js_eval));

    var moved_source = try makeSession(allocator, .cdp_ws, caps, null);
    var moved = session_common.intoBase(&moved_source);
    moved.deinit();

    var deinit_source = try makeSession(allocator, .cdp_ws, caps, null);
    session_common.deinit(&deinit_source);

    try std.testing.expectError(
        error.UnsupportedProtocol,
        session_common.fromBase(try makeSession(allocator, .cdp_ws, caps, null), .unsupported),
    );
}

test "io helper signatures stay covered without socket setup" {
    _ = .{
        io_util.readExact,
        io_util.read,
        io_util.readByte,
        io_util.writeAll,
    };
}
