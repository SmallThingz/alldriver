const std = @import("std");
const driver = @import("browser_driver");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var android_session = driver.attachAndroidWebView(allocator, .{
        .device_id = "emulator-5554",
        .pid = 1234,
    }) catch |err| {
        std.debug.print("android attach failed (expected without adb forwarding): {s}\n", .{@errorName(err)});
        return;
    };
    defer android_session.deinit();

    std.debug.print("android webview attached: endpoint={s}\n", .{android_session.endpoint.?});

    var ios_session = driver.attachIosWebView(allocator, .{
        .udid = "ios-simulator-udid",
        .page_id = "1",
    }) catch |err| {
        std.debug.print("ios attach failed (expected without ios bridge): {s}\n", .{@errorName(err)});
        return;
    };
    defer ios_session.deinit();

    std.debug.print("ios webview attached: endpoint={s}\n", .{ios_session.endpoint.?});
}
