const std = @import("std");
const driver = @import("browser_driver");

const target_url = "https://www.opensubtitles.com/";
const connect_retry_sleep_ms = 500;
const endpoint_connect_timeout_ms = 8_000;

fn printEvalSection(session: *driver.Session, allocator: std.mem.Allocator, title: []const u8, script: []const u8) !void {
    const payload = try session.evaluate(script);
    defer allocator.free(payload);

    std.debug.print("\n=== {s} ===\n{s}\n", .{ title, payload });
}

fn waitForEndpointReachable(endpoint_opt: ?[]const u8, timeout_ms: u32) !void {
    const endpoint = endpoint_opt orelse return;
    const scheme_end = std.mem.indexOf(u8, endpoint, "://") orelse return;
    const rest = endpoint[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return;
    const host = host_port[0..colon];
    const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return;
    if (host.len == 0) return;

    const deadline = std.time.milliTimestamp() + @as(i64, timeout_ms);
    while (true) {
        const stream = std.net.tcpConnectToHost(std.heap.page_allocator, host, port) catch |err| {
            if (std.time.milliTimestamp() >= deadline) return err;
            std.Thread.sleep(connect_retry_sleep_ms * std.time.ns_per_ms);
            continue;
        };
        stream.close();
        return;
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const installs = try driver.discover(allocator, .{
        .kinds = &.{ .chrome, .edge, .firefox, .brave, .vivaldi },
        .allow_managed_download = false,
    }, .{});
    defer driver.freeInstalls(allocator, installs);

    if (installs.len == 0) {
        std.debug.print("No supported browser install found.\n", .{});
        return;
    }

    var last_error: ?anyerror = null;
    for (installs, 0..) |install, index| {
        std.debug.print("\n=== Attempt {d}/{d} ===\n", .{ index + 1, installs.len });
        std.debug.print("Using browser: {s} ({s}) from {s}\n", .{
            @tagName(install.kind),
            @tagName(install.engine),
            install.path,
        });
        if (install.version) |v| {
            std.debug.print("Browser version: {s}\n", .{v});
        }

        var session = driver.launch(allocator, .{
            .install = install,
            .profile_mode = .ephemeral,
            .headless = true,
            .args = &.{
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-gpu",
            },
        }) catch |err| {
            last_error = err;
            std.debug.print("Launch failed: {s}\n", .{@errorName(err)});
            continue;
        };
        defer session.deinit();

        const caps = session.capabilities();
        std.debug.print(
            "Capabilities: dom={any} js_eval={any} network_intercept={any} tracing={any} downloads={any} bidi_events={any}\n",
            .{ caps.dom, caps.js_eval, caps.network_intercept, caps.tracing, caps.downloads, caps.bidi_events },
        );

        if (session.endpoint) |ep| {
            std.debug.print("Endpoint: {s}\n", .{ep});
        }
        waitForEndpointReachable(session.endpoint, endpoint_connect_timeout_ms) catch |err| {
            last_error = err;
            std.debug.print("Endpoint not reachable yet: {s}\n", .{@errorName(err)});
            continue;
        };

        session.navigate(target_url) catch |err| {
            last_error = err;
            std.debug.print("Navigate failed: {s}\n", .{@errorName(err)});
            continue;
        };
        session.waitFor(.dom_ready, 30_000) catch |err| {
            last_error = err;
            std.debug.print("dom_ready wait failed: {s}\n", .{@errorName(err)});
            continue;
        };
        session.waitFor(.network_idle, 15_000) catch |err| {
            std.debug.print("network_idle wait did not complete cleanly: {s}\n", .{@errorName(err)});
        };

        if (!session.supports(.js_eval)) {
            std.debug.print("JS evaluate is not supported by this adapter.\n", .{});
            return;
        }

        try printEvalSection(&session, allocator, "Site Info",
            \\(function () {
            \\  return JSON.stringify({
            \\    url: window.location.href,
            \\    origin: window.location.origin,
            \\    host: window.location.host,
            \\    protocol: window.location.protocol,
            \\    title: document.title,
            \\    readyState: document.readyState,
            \\    language: document.documentElement.lang || null,
            \\    referrer: document.referrer || null,
            \\    userAgent: navigator.userAgent,
            \\    platform: navigator.platform,
            \\    cookiesEnabled: navigator.cookieEnabled,
            \\    online: navigator.onLine,
            \\    viewport: {
            \\      width: window.innerWidth,
            \\      height: window.innerHeight,
            \\      devicePixelRatio: window.devicePixelRatio
            \\    }
            \\  }, null, 2);
            \\})();
        );

        try printEvalSection(&session, allocator, "DOM Summary",
            \\(function () {
            \\  const links = document.querySelectorAll("a").length;
            \\  const images = document.querySelectorAll("img").length;
            \\  const scripts = document.querySelectorAll("script").length;
            \\  const forms = document.querySelectorAll("form").length;
            \\  const iframes = document.querySelectorAll("iframe").length;
            \\  const stylesheets = document.querySelectorAll("link[rel='stylesheet']").length;
            \\  const totalNodes = document.getElementsByTagName("*").length;
            \\  const textLength = (document.body && document.body.innerText) ? document.body.innerText.length : 0;
            \\  return JSON.stringify({
            \\    links,
            \\    images,
            \\    scripts,
            \\    forms,
            \\    iframes,
            \\    stylesheets,
            \\    totalNodes,
            \\    bodyTextChars: textLength
            \\  }, null, 2);
            \\})();
        );

        try printEvalSection(&session, allocator, "Connection + Performance",
            \\(function () {
            \\  const nav = performance.getEntriesByType("navigation")[0] || null;
            \\  const resources = performance.getEntriesByType("resource") || [];
            \\  const sampleResources = resources.slice(0, 20).map((entry) => ({
            \\    name: entry.name,
            \\    initiatorType: entry.initiatorType,
            \\    transferSize: entry.transferSize ?? null,
            \\    encodedBodySize: entry.encodedBodySize ?? null,
            \\    decodedBodySize: entry.decodedBodySize ?? null,
            \\    duration: entry.duration,
            \\    nextHopProtocol: entry.nextHopProtocol ?? null
            \\  }));
            \\  return JSON.stringify({
            \\    navigation: nav ? {
            \\      type: nav.type,
            \\      redirectCount: nav.redirectCount,
            \\      nextHopProtocol: nav.nextHopProtocol,
            \\      dnsMs: nav.domainLookupEnd - nav.domainLookupStart,
            \\      tcpMs: nav.connectEnd - nav.connectStart,
            \\      tlsStartMs: nav.secureConnectionStart,
            \\      ttfbMs: nav.responseStart - nav.requestStart,
            \\      responseMs: nav.responseEnd - nav.responseStart,
            \\      domContentLoadedMs: nav.domContentLoadedEventEnd,
            \\      loadEventEndMs: nav.loadEventEnd,
            \\      transferSize: nav.transferSize,
            \\      encodedBodySize: nav.encodedBodySize,
            \\      decodedBodySize: nav.decodedBodySize
            \\    } : null,
            \\    resourceCount: resources.length,
            \\    sampleResources
            \\  }, null, 2);
            \\})();
        );
        return;
    }

    if (last_error) |err| return err;
}
