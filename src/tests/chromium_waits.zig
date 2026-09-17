const std = @import("std");
const driver = @import("../root.zig");
const compat = @import("../util/compat.zig");
const Browser = @import("chromium_behavior.zig").Browser;
const LocalServer = @import("chromium_network.zig").LocalServer;
const allocator = std.testing.allocator;

comptime {
    _ = @import("../core/wait.zig");
}

test "Chromium waits honor JavaScript truthiness and preserve a single asynchronous evaluation" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>wait truthiness</title>");
    for ([_][]const u8{ "'hello'", "'false'", "[]", "({})", "Infinity", "2n" }) |script| {
        const result = try browser.session.waitFor(.{ .js_truthy = script }, .{ .timeout_ms = 2000 });
        try std.testing.expect(result.matched);
    }
    for ([_][]const u8{ "undefined", "NaN", "-0", "0n", "''", "null", "false" }) |script| {
        try std.testing.expectError(error.Timeout, browser.session.waitFor(.{ .js_truthy = script }, .{ .timeout_ms = 60, .poll_interval_ms = 5 }));
    }
    const started = compat.milliTimestamp();
    _ = try browser.session.waitFor(.{ .js_truthy = "new Promise(resolve=>{window.promiseExecutions=(window.promiseExecutions||0)+1;setTimeout(()=>resolve(true),250)})" }, .{ .timeout_ms = 2000, .poll_interval_ms = 10 });
    try std.testing.expect(compat.milliTimestamp() - started >= 200);
    try browser.evaluateTrue("promiseExecutions===1");
}

test "Chromium selector wait requires visible geometry and follows later visibility changes" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><div id='hidden' style='display:none'>hidden</div><div id='invisible' style='visibility:hidden'>invisible</div><div id='zero' style='width:0;height:0;overflow:hidden'></div>");
    for ([_][]const u8{ "#hidden", "#invisible", "#zero", "#missing" }) |selector| {
        try std.testing.expectError(error.Timeout, browser.session.waitFor(.{ .selector_visible = selector }, .{ .timeout_ms = 60, .poll_interval_ms = 5 }));
    }
    try browser.evaluateTrue("(setTimeout(()=>document.querySelector('#hidden').style.display='block',100),true)");
    _ = try browser.session.waitFor(.{ .selector_visible = "#hidden" }, .{ .timeout_ms = 2000, .poll_interval_ms = 5 });
    try browser.evaluateTrue("document.querySelector('#hidden').getBoundingClientRect().height>0");
    try std.testing.expectError(error.JavaScriptException, browser.session.waitFor(.{ .selector_visible = "[" }, .{ .timeout_ms = 2000 }));
}

test "Chromium cookie waits preserve exact names and query scope without document cookie fallback" {
    const server = try LocalServer.start();
    defer server.deinit();
    var browser = try Browser.launch();
    defer browser.deinit();
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{server.listener.socket.address.getPort()});
    defer allocator.free(url);
    var page = browser.session.page();
    try page.navigate(url);
    var storage = browser.session.storage();
    try storage.setCookie(.{ .name = "notsid", .value = "suffix", .domain = "127.0.0.1", .secure = false, .http_only = false });
    try browser.evaluateTrue("document.cookie.includes('notsid=suffix')");
    try std.testing.expectError(error.Timeout, browser.session.waitForCookie(.{ .name = "sid" }, .{ .timeout_ms = 80, .poll_interval_ms = 5 }));
    try storage.setCookie(.{ .name = "sid", .value = "exact", .domain = "127.0.0.1", .secure = false, .http_only = false });
    for ([_]driver.CookieQuery{
        .{ .name = "sid", .domain = "other.invalid" },
        .{ .name = "sid", .secure_only = true },
    }) |query| try std.testing.expectError(error.Timeout, browser.session.waitForCookie(query, .{ .timeout_ms = 80, .poll_interval_ms = 5 }));
    _ = try browser.session.waitForCookie(.{ .name = "sid", .domain = "127.0.0.1", .path = "/" }, .{ .timeout_ms = 1000 });
    try storage.setCookie(.{ .name = "scoped", .value = "path", .domain = "127.0.0.1", .path = "/private", .secure = false, .http_only = false });
    const private_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/private", .{server.listener.socket.address.getPort()});
    defer allocator.free(private_url);
    try page.navigate(private_url);
    try browser.evaluateTrue("document.cookie.includes('scoped=path')");
    try std.testing.expectError(error.Timeout, browser.session.waitForCookie(.{ .name = "scoped", .path = "/different" }, .{ .timeout_ms = 80, .poll_interval_ms = 5 }));
}

var pending_probe: std.atomic.Value(bool) = .init(false);
fn onProbe(entry: @import("../modern/log.zig").LogEntry) void {
    if (std.mem.eql(u8, entry.text, "wait-promise-pending")) pending_probe.store(true, .release);
}

test "Chromium wait deadlines and cancellation interrupt long polls and unresolved promises" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>bounded wait</title>");
    var started = compat.milliTimestamp();
    try std.testing.expectError(error.Timeout, browser.session.waitFor(.{ .js_truthy = "false" }, .{ .timeout_ms = 100, .poll_interval_ms = 60_000 }));
    try std.testing.expect(compat.milliTimestamp() - started < 2000);
    started = compat.milliTimestamp();
    try std.testing.expectError(error.Timeout, browser.session.waitFor(.{ .js_truthy = "new Promise(()=>{})" }, .{ .timeout_ms = 100 }));
    try std.testing.expect(compat.milliTimestamp() - started < 2000);
    try browser.evaluateTrue("document.title==='bounded wait'");

    pending_probe.store(false, .release);
    var logs = browser.session.log();
    try logs.onConsole(onProbe);
    defer logs.clearConsole();
    const op = try browser.session.waitForAsync(.{ .js_truthy = "new Promise(()=>console.log('wait-promise-pending'))" }, .{ .timeout_ms = 30_000, .poll_interval_ms = 60_000 });
    var released = false;
    defer if (!released) {
        op.cancel();
        op.deinit();
    };
    started = compat.milliTimestamp();
    while (!pending_probe.load(.acquire)) {
        if (compat.milliTimestamp() - started > 3000) return error.PendingProbeNeverStarted;
        compat.sleepMs(5);
    }
    started = compat.milliTimestamp();
    try std.testing.expect(op.requestCancel());
    try std.testing.expectError(error.Canceled, op.await(1000));
    op.deinit();
    released = true;
    try std.testing.expect(compat.milliTimestamp() - started < 2000);
    try browser.evaluateTrue("document.title==='bounded wait'");
}
