const std = @import("std");
const driver = @import("../root.zig");
const compat = @import("../util/compat.zig");

const allocator = std.testing.allocator;
const fixture =
    \\<!doctype html><meta charset="utf-8"><title>input fixture</title>
    \\<style>body{margin:0;height:4000px}button,input{display:block;margin:20px;width:240px;height:40px}</style>
    \\<button id="button">Press</button><input id="text"><input id="other">
    \\<script>
    \\window.events=[];
    \\for(const type of ['pointerdown','mousedown','mouseup','click','focusin','keydown','keyup','beforeinput','input','wheel','mousemove']){
    \\ document.addEventListener(type,e=>events.push({type:e.type,trusted:e.isTrusted,target:e.target.id,key:e.key||'',ctrl:e.ctrlKey||false,x:e.clientX||0,y:e.clientY||0}),{passive:true});
    \\}
    \\</script>
;

const Browser = struct {
    session: driver.modern.ModernSession,
    profile: []u8,

    fn launch() !Browser {
        var installs = try driver.discover(allocator, .{
            .kinds = &.{ .brave, .chrome, .edge },
            .allow_managed_download = false,
        }, .{ .include_path_env = true, .include_os_probes = true, .include_known_paths = true });
        defer installs.deinit();
        if (installs.items.len == 0) return error.NoChromiumBrowserFound;
        const profile = try std.fmt.allocPrint(allocator, ".tmp/chromium-behavior-{x}", .{compat.nanoTimestamp()});
        errdefer allocator.free(profile);
        errdefer compat.cwd().deleteTree(profile) catch {};
        const session = try driver.modern.launch(allocator, .{
            .install = installs.items[0],
            .profile_mode = .ephemeral,
            .profile_dir = profile,
            .headless = true,
            .args = &.{
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-sync",
                "--no-first-run",
                "--password-store=basic",
                "--disable-features=OptimizationGuideModelDownloading,OptimizationHints,MediaRouter",
            },
        });
        return .{ .session = session, .profile = profile };
    }

    fn deinit(self: *Browser) void {
        self.session.deinit();
        compat.cwd().deleteTree(self.profile) catch {};
        allocator.free(self.profile);
    }

    fn navigateHtml(self: *Browser, html: []const u8) !void {
        const prefix = "data:text/html;charset=utf-8;base64,";
        const url = try allocator.alloc(u8, prefix.len + std.base64.standard.Encoder.calcSize(html.len));
        defer allocator.free(url);
        @memcpy(url[0..prefix.len], prefix);
        _ = std.base64.standard.Encoder.encode(url[prefix.len..], html);
        var page = self.session.page();
        try page.navigate(url);
    }

    fn evaluateTrue(self: *Browser, expression: []const u8) !void {
        var runtime = self.session.runtime();
        const payload = try runtime.evaluate(expression);
        defer allocator.free(payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        const remote = try remoteResult(parsed.value);
        const value = remote.object.get("value") orelse return error.MissingEvaluationValue;
        if (value != .bool or !value.bool) {
            std.debug.print("Chromium assertion failed: {s}\nresponse: {s}\n", .{ expression, payload });
            return error.TestUnexpectedResult;
        }
    }

    fn waitTrue(self: *Browser, expression: []const u8) !void {
        const start = compat.milliTimestamp();
        while (true) {
            self.evaluateTrue(expression) catch |err| {
                if (err != error.TestUnexpectedResult or compat.milliTimestamp() - start > 5000) return err;
                compat.sleepMs(20);
                continue;
            };
            return;
        }
    }
};

fn remoteResult(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidEvaluationResponse;
    const result = value.object.get("result") orelse return error.InvalidEvaluationResponse;
    if (result != .object) return error.InvalidEvaluationResponse;
    const remote = result.object.get("result") orelse return error.InvalidEvaluationResponse;
    if (remote != .object) return error.InvalidEvaluationResponse;
    return remote;
}

test "Chromium viewport modifies layout and screenshot contains matching PNG dimensions" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><style>body{margin:0;background:rgb(10,80,190)}</style>");
    var page = browser.session.page();
    for ([_][2]u32{ .{ 913, 617 }, .{ 375, 667 } }) |size| {
        try page.setViewport(size[0], size[1]);
        const expression = try std.fmt.allocPrint(allocator, "innerWidth==={d} && innerHeight==={d} && devicePixelRatio===1 && document.documentElement.clientWidth==={d}", .{ size[0], size[1], size[0] });
        defer allocator.free(expression);
        try browser.evaluateTrue(expression);
        const png = try page.screenshot(allocator, .png);
        defer allocator.free(png);
        try std.testing.expect(png.len > 100);
        try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
        try std.testing.expectEqualStrings("IHDR", png[12..16]);
        try std.testing.expectEqual(size[0], std.mem.readInt(u32, png[16..20], .big));
        try std.testing.expectEqual(size[1], std.mem.readInt(u32, png[20..24], .big));
    }
    const jpeg = try page.screenshot(allocator, .jpeg);
    defer allocator.free(jpeg);
    try std.testing.expect(jpeg.len > 100);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd8, 0xff }, jpeg[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd9 }, jpeg[jpeg.len - 2 ..]);
    try std.testing.expectError(error.InvalidViewport, page.setViewport(0, 600));
    try browser.evaluateTrue("innerWidth===375 && innerHeight===667");
}

test "Chromium history traverses actual documents and reload replaces document state" {
    var browser = try Browser.launch();
    defer browser.deinit();
    var page = browser.session.page();
    try browser.navigateHtml("<!doctype html><title>first document</title><p id='first'>first</p>");
    try browser.evaluateTrue("document.title==='first document' && location.protocol==='data:' && !!document.querySelector('#first')");
    var runtime = browser.session.runtime();
    const first_url = try runtime.evaluate("location.href");
    defer allocator.free(first_url);
    var first = try std.json.parseFromSlice(std.json.Value, allocator, first_url, .{});
    defer first.deinit();
    const first_remote = try remoteResult(first.value);
    const expected_url = try std.json.Stringify.valueAlloc(allocator, first_remote.object.get("value").?.string, .{});
    defer allocator.free(expected_url);
    try browser.navigateHtml("<!doctype html><title>second document</title><p id='second'>second</p>");
    try browser.evaluateTrue("document.title==='second document' && !!document.querySelector('#second')");
    try page.goBack();
    const back = try std.fmt.allocPrint(allocator, "location.href==={s} && document.title==='first document' && !!document.querySelector('#first') && !document.querySelector('#second')", .{expected_url});
    defer allocator.free(back);
    try browser.evaluateTrue(back);
    try page.goForward();
    try browser.evaluateTrue("document.title==='second document' && !!document.querySelector('#second') && !document.querySelector('#first')");
    try browser.evaluateTrue("(window.transientValue=123)===123");
    try page.reload();
    try browser.evaluateTrue("document.title==='second document' && typeof transientValue==='undefined'");
}

test "Chromium runtime awaits promises reports exceptions and preserves typed values" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml("<!doctype html><title>runtime</title>");
    try browser.evaluateTrue("new Promise(resolve=>setTimeout(()=>resolve(true),40))");
    try browser.evaluateTrue("JSON.stringify({text:'λ',n:42,list:[true,null]})==='{\"text\":\"λ\",\"n\":42,\"list\":[true,null]}'");
    var runtime = browser.session.runtime();
    try std.testing.expectError(error.JavaScriptException, runtime.evaluate("throw new Error('deliberate browser exception')"));
    try std.testing.expectError(error.JavaScriptException, runtime.evaluate("Promise.reject(new Error('deliberate rejection'))"));
    const called = try runtime.callFunction("async function(a,b){return a+b}", "[17,25]");
    defer allocator.free(called);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, called, .{});
    defer parsed.deinit();
    const remote = try remoteResult(parsed.value);
    try std.testing.expectEqual(@as(i64, 42), remote.object.get("value").?.integer);
    try browser.evaluateTrue("document.title==='runtime'");
}

test "Chromium input is trusted focuses edits selects and scrolls the real page" {
    var browser = try Browser.launch();
    defer browser.deinit();
    try browser.navigateHtml(fixture);
    var page = browser.session.page();
    try page.setViewport(800, 600);
    var input = browser.session.input();
    try input.click("#button");
    try browser.evaluateTrue("document.activeElement.id==='button' && events.filter(e=>e.type==='click'&&e.target==='button').length===1 && ['pointerdown','mousedown','mouseup','click'].every(type=>events.some(e=>e.type===type&&e.target==='button'&&e.trusted))");
    try input.typeText("#text", "abc");
    try browser.evaluateTrue("document.activeElement.id==='text' && document.querySelector('#text').value==='abc' && events.some(e=>e.type==='input'&&e.target==='text'&&e.trusted)");
    try input.keyDown("Backspace");
    try input.keyUp("Backspace");
    try browser.evaluateTrue("document.querySelector('#text').value==='ab' && events.some(e=>e.type==='keydown'&&e.key==='Backspace'&&e.trusted)");
    try input.keyDown("Control");
    try input.keyDown("a");
    try input.keyUp("a");
    try input.keyUp("Control");
    try browser.evaluateTrue("document.querySelector('#text').selectionStart===0 && document.querySelector('#text').selectionEnd===2 && events.some(e=>e.type==='keydown'&&e.key==='a'&&e.ctrl&&e.trusted)");
    try input.keyDown("x");
    try input.keyUp("x");
    try browser.evaluateTrue("document.querySelector('#text').value==='x'");
    try input.typeText("#text", "λ🙂");
    try browser.evaluateTrue("document.querySelector('#text').value==='λ🙂' && events.filter(e=>e.type==='input').every(e=>e.trusted)");
    try input.keyDown("Tab");
    try input.keyUp("Tab");
    try browser.evaluateTrue("document.activeElement.id==='other'");
    try input.mouseMove(500, 300);
    try input.wheel(0, 450);
    try browser.waitTrue("scrollY>0 && events.some(e=>e.type==='wheel'&&e.trusted&&e.x===500&&e.y===300)");
    try std.testing.expectError(error.InvalidSelector, input.click("["));
    try std.testing.expectError(error.ElementNotEditable, input.typeText("#button", "no"));
    try std.testing.expectError(error.ElementNotFound, input.click("#missing"));
    try std.testing.expectError(error.ElementNotFound, input.typeText("#missing", "not inserted"));
    try browser.evaluateTrue("document.querySelector('#text').value==='λ🙂'");
}
