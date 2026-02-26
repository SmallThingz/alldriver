const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var android_session = driver.modern.attachAndroidWebView(allocator, .{
        .device_id = "emulator-5554",
        .bridge_kind = .adb,
        .pid = 1234,
    }) catch |err| {
        std.debug.print("android attach failed (expected without adb forwarding): {s}\n", .{@errorName(err)});
        return;
    };
    defer android_session.deinit();

    std.debug.print("android webview attached: endpoint={s}\n", .{android_session.base.endpoint.?});

    var shizuku_session = driver.modern.attachAndroidWebView(allocator, .{
        .device_id = "emulator-5554",
        .bridge_kind = .shizuku,
        .host = "127.0.0.1",
        .port = 9322,
        .socket_name = "chrome_devtools_remote",
    }) catch |err| {
        std.debug.print("shizuku attach failed (expected without shizuku relay): {s}\n", .{@errorName(err)});
        return;
    };
    defer shizuku_session.deinit();

    std.debug.print("shizuku android webview attached: endpoint={s}\n", .{shizuku_session.base.endpoint.?});

    var ios_session = driver.legacy.attachIosWebView(allocator, .{
        .udid = "ios-simulator-udid",
        .page_id = "1",
    }) catch |err| {
        std.debug.print("ios attach failed (expected without ios bridge): {s}\n", .{@errorName(err)});
        return;
    };
    defer ios_session.deinit();

    std.debug.print("ios webview attached: endpoint={s}\n", .{ios_session.base.endpoint.?});
}
