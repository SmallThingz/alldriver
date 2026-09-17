const std = @import("std");
const driver = @import("../root.zig");
const compat = @import("../util/compat.zig");
const Browser = @import("chromium_behavior.zig").Browser;
const LogEntry = @import("../modern/log.zig").LogEntry;
const allocator = std.testing.allocator;

test "Chromium init scripts execute before page scripts and removal affects future documents" {
    var browser = try Browser.launch();
    defer browser.deinit();
    const id = try browser.session.addInitScript("window.initValue=73;");
    defer allocator.free(id);
    try std.testing.expect(id.len > 0);
    const page = "<!doctype html><script>window.observedInit=window.initValue;</script>";
    try browser.navigateHtml(page);
    try browser.evaluateTrue("observedInit===73 && initValue===73");
    try browser.navigateHtml("<!doctype html><title>next</title><script>window.observedInit=window.initValue;</script>");
    try browser.evaluateTrue("observedInit===73 && initValue===73 && document.title==='next'");
    try browser.session.removeInitScript(id);
    try browser.evaluateTrue("observedInit===73 && initValue===73");
    try browser.navigateHtml(page);
    try browser.evaluateTrue("typeof observedInit==='undefined' && typeof initValue==='undefined'");
}

var console_count: std.atomic.Value(u32) = .init(0);
var exception_count: std.atomic.Value(u32) = .init(0);
var log_values_match: std.atomic.Value(bool) = .init(true);

fn consoleCallback(entry: LogEntry) void {
    if (!std.mem.eql(u8, entry.level, "log") or
        !std.mem.eql(u8, entry.text, "lifecycle-console λ 42 true null undefined") or
        entry.source.len == 0)
        log_values_match.store(false, .release);
    _ = console_count.fetchAdd(1, .release);
}

fn exceptionCallback(entry: LogEntry) void {
    const first_line = entry.text[0 .. std.mem.indexOfScalar(u8, entry.text, '\n') orelse entry.text.len];
    if (!std.mem.eql(u8, entry.level, "error") or
        !std.mem.eql(u8, first_line, "Error: lifecycle-error") or
        entry.source.len == 0)
        log_values_match.store(false, .release);
    _ = exception_count.fetchAdd(1, .release);
}

test "Chromium console and exception callbacks deliver exact values while client is idle" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>logs</title>");
    console_count.store(0, .release);
    exception_count.store(0, .release);
    log_values_match.store(true, .release);
    var log = browser.session.log();
    try log.onConsole(consoleCallback);
    try log.onException(exceptionCallback);
    try browser.evaluateTrue("(setTimeout(()=>console.log('lifecycle-console λ',42,true,null,undefined),100),setTimeout(()=>{throw new Error('lifecycle-error')},150),true)");
    // No driver call is allowed here: callbacks must not depend on another RPC.
    const started = compat.milliTimestamp();
    while (console_count.load(.acquire) == 0 or exception_count.load(.acquire) == 0) {
        if (compat.milliTimestamp() - started > 5000) return error.MissingIdleLogCallback;
        compat.sleepMs(10);
    }
    try std.testing.expectEqual(@as(u32, 1), console_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), exception_count.load(.acquire));
    try std.testing.expect(log_values_match.load(.acquire));
    log.clearConsole();
    log.clearException();
    try browser.evaluateTrue("(setTimeout(()=>console.log('must not be delivered'),20),setTimeout(()=>{throw new Error('also suppressed')},30),true)");
    compat.sleepMs(150);
    try std.testing.expectEqual(@as(u32, 1), console_count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), exception_count.load(.acquire));
    try browser.evaluateTrue("document.title==='logs'");
}

test "Chromium contexts create distinct live pages and targets switch without losing page state" {
    var browser = try Browser.launch();
    defer browser.deinit();
    var contexts = browser.session.contexts();
    var targets = browser.session.targets();
    const initial = try contexts.list(allocator);
    defer contexts.freeList(allocator, initial);
    try std.testing.expect(initial.len > 0);
    const original = initial[0].id;
    try targets.attach(original);
    try browser.navigateHtml("<!doctype html><title>original context</title>");
    try browser.evaluateTrue("(window.pageIdentity='original')==='original'");
    const second = try contexts.create(allocator);
    defer allocator.free(second.id);
    try std.testing.expect(!std.mem.eql(u8, original, second.id));
    try browser.evaluateTrue("typeof pageIdentity==='undefined' && location.href==='about:blank'");
    try browser.navigateHtml("<!doctype html><title>second context</title>");
    try browser.evaluateTrue("(window.pageIdentity='second')==='second'");

    const live_targets = try targets.list(allocator);
    defer targets.freeList(allocator, live_targets);
    var saw_original = false;
    var saw_second = false;
    for (live_targets) |target| {
        if (std.mem.eql(u8, target.id, original)) saw_original = true;
        if (std.mem.eql(u8, target.id, second.id)) saw_second = true;
    }
    try std.testing.expect(saw_original and saw_second);
    try targets.attach(original);
    try browser.evaluateTrue("pageIdentity==='original' && document.title==='original context'");
    try std.testing.expectError(error.ProtocolCommandFailed, targets.attach("nonexistent-alldriver-target"));
    try browser.evaluateTrue("pageIdentity==='original' && document.title==='original context'");
    try targets.attach(second.id);
    try browser.evaluateTrue("pageIdentity==='second' && document.title==='second context'");
    try targets.detach(second.id);
    try targets.attach(original);
    try browser.evaluateTrue("pageIdentity==='original'");
    try contexts.close(second.id);
    try std.testing.expectError(error.ProtocolCommandFailed, contexts.close("nonexistent-alldriver-context"));
    const remaining = try contexts.list(allocator);
    defer contexts.freeList(allocator, remaining);
    saw_original = false;
    for (remaining) |context| {
        try std.testing.expect(!std.mem.eql(u8, context.id, second.id));
        if (std.mem.eql(u8, context.id, original)) saw_original = true;
    }
    try std.testing.expect(saw_original);
    try browser.evaluateTrue("pageIdentity==='original' && document.title==='original context'");
}

fn expectSessionTrue(session: *driver.modern.ModernSession, expression: []const u8) !void {
    var runtime = session.runtime();
    const payload = try runtime.evaluate(expression);
    defer allocator.free(payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("result").?.object.get("result").?.object.get("value").?;
    try std.testing.expect(value == .bool and value.bool);
}

test "Chromium explicit page attachment switches to requested target and preserves failed selections" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>direct original</title>");
    const endpoint = try @import("../protocol/executor.zig").pageWebSocketEndpoint(&browser.session.base);
    defer allocator.free(endpoint);
    var direct = try driver.modern.attach(allocator, endpoint);
    defer direct.deinit();
    try expectSessionTrue(&direct, "document.title==='direct original'");
    var contexts = browser.session.contexts();
    const second = try contexts.create(allocator);
    defer allocator.free(second.id);
    try browser.navigateHtml("<!doctype html><title>direct second</title>");
    var targets = direct.targets();
    try targets.attach(second.id);
    try expectSessionTrue(&direct, "document.title==='direct second'");
    try std.testing.expectError(error.ProtocolCommandFailed, targets.attach("not-a-real-target"));
    try expectSessionTrue(&direct, "document.title==='direct second'");
}

test "Chromium target switching rebinds idle logging and live interception rules" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>before switch</title>");
    console_count.store(0, .release);
    log_values_match.store(true, .release);
    var log = browser.session.log();
    try log.onConsole(consoleCallback);
    var network = browser.session.network();
    try network.addRule(.{
        .id = "retarget-fixture",
        .url_pattern = "https://alldriver.invalid/retarget",
        .action = .{ .fulfill = .{
            .status = 200,
            .body = "retarget-body",
            .headers = &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }},
        } },
    });
    var contexts = browser.session.contexts();
    const second = try contexts.create(allocator);
    defer allocator.free(second.id);
    try browser.navigateHtml("<!doctype html><title>after switch</title>");
    try browser.evaluateTrue("fetch('https://alldriver.invalid/retarget').then(r=>r.text()).then(t=>t==='retarget-body')");
    try browser.evaluateTrue("(setTimeout(()=>console.log('lifecycle-console λ',42,true,null,undefined),50),true)");
    const started = compat.milliTimestamp();
    while (console_count.load(.acquire) == 0) {
        if (compat.milliTimestamp() - started > 5000) return error.MissingRetargetedLogCallback;
        compat.sleepMs(10);
    }
    try std.testing.expectEqual(@as(u32, 1), console_count.load(.acquire));
    try std.testing.expect(log_values_match.load(.acquire));
    try browser.evaluateTrue("document.title==='after switch'");
}

test "Chromium listing empty contexts does not silently create a page" {
    var browser = try Browser.launch();
    defer browser.deinit();
    var contexts = browser.session.contexts();
    const original = try contexts.list(allocator);
    defer contexts.freeList(allocator, original);
    for (original) |context| try contexts.close(context.id);
    const empty = try contexts.list(allocator);
    defer contexts.freeList(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    var targets = browser.session.targets();
    const actual = try targets.list(allocator);
    defer targets.freeList(allocator, actual);
    for (actual) |target| {
        try std.testing.expect(!std.mem.eql(u8, target.kind, "page") and !std.mem.eql(u8, target.kind, "tab"));
    }
    const still_empty = try contexts.list(allocator);
    defer contexts.freeList(allocator, still_empty);
    try std.testing.expectEqual(@as(usize, 0), still_empty.len);
}

test "Chromium async cancellation stops pending wait and abandoned evaluation releases owned result" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>async</title>");
    const wait = try browser.session.waitForAsync(.{ .js_truthy = "false" }, .{ .timeout_ms = 30_000, .poll_interval_ms = 10 });
    var wait_destroyed = false;
    defer if (!wait_destroyed) {
        wait.cancel();
        wait.deinit();
    };
    try std.testing.expectError(error.Timeout, wait.await(5));
    try std.testing.expect(wait.isCancelable());
    const cancel_started = compat.milliTimestamp();
    try std.testing.expect(wait.requestCancel());
    try std.testing.expectError(error.Canceled, wait.await(1000));
    wait.deinit();
    wait_destroyed = true;
    try std.testing.expect(compat.milliTimestamp() - cancel_started < 2000);
    try browser.evaluateTrue("document.title==='async'");

    // Deliberately do not await: deinit must join and free the returned JSON.
    const abandoned = try browser.session.evaluateAsync("new Promise(resolve=>setTimeout(()=>{window.abandonedFinished=true;resolve('owned result λ')},30))");
    abandoned.deinit();
    try browser.evaluateTrue("abandonedFinished===true");
    const completed = try browser.session.evaluateAsync("42");
    defer completed.deinit();
    const response = try completed.await(5000);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("result").?.object.get("result").?.object.get("value").?.integer);
    try std.testing.expectError(error.AlreadyConsumed, completed.await(100));
}

test "Chromium tracing returns actual timestamped browser events" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>trace</title>");
    var start = try browser.session.startTracingAsync();
    defer start.deinit();
    try start.await(5000);
    try browser.evaluateTrue("(()=>{performance.mark('alldriver-trace-probe');let sum=0;for(let i=0;i<10000;i++)sum+=i;return sum===49995000})()");
    var stop = try browser.session.stopTracingAsync();
    defer stop.deinit();
    const trace = try stop.await(10_000);
    defer allocator.free(trace);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trace, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const events = parsed.value.object.get("traceEvents") orelse return error.MissingTraceEvents;
    try std.testing.expect(events == .array and events.array.items.len > 0);
    var timestamped_event = false;
    for (events.array.items) |event| {
        if (event != .object) continue;
        const name = event.object.get("name") orelse continue;
        const phase = event.object.get("ph") orelse continue;
        const ts = event.object.get("ts") orelse continue;
        if (name != .string or name.string.len == 0 or phase != .string or std.mem.eql(u8, phase.string, "M")) continue;
        if ((ts == .integer and ts.integer > 0) or (ts == .float and ts.float > 0)) timestamped_event = true;
    }
    try std.testing.expect(timestamped_event);
    try browser.evaluateTrue("document.title==='trace'");
}

test "Chromium late launch failure releases process profile and allocations exactly once" {
    var installs = try driver.discover(allocator, .{ .kinds = &.{.brave}, .allow_managed_download = false }, .{});
    defer installs.deinit();
    if (installs.items.len == 0) return error.NoChromiumBrowserFound;
    try std.testing.expectError(error.Timeout, driver.modern.launch(allocator, .{
        .install = installs.items[0],
        .headless = true,
        .profile_mode = .ephemeral,
        .timeout_policy = .{ .attach_ms = 0 },
        .args = &.{ "--no-sandbox", "--disable-dev-shm-usage", "--disable-background-networking" },
    }));
}
