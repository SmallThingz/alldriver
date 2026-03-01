const std = @import("std");
const browser_kind = @import("browser_kind.zig");
const types = @import("../types.zig");
const common = @import("../protocol/common.zig");

pub const ApiTier = types.ApiTier;

pub fn engineTier(engine: types.EngineKind) ApiTier {
    return switch (engine) {
        .chromium, .gecko => .modern,
        .webkit, .unknown => .unsupported,
    };
}

pub fn browserTier(kind: types.BrowserKind) ApiTier {
    return engineTier(browser_kind.engineFor(kind));
}

pub fn webViewTier(kind: types.WebViewKind) ApiTier {
    return switch (kind) {
        .webview2, .electron, .android_webview => .modern,
    };
}

pub fn transportTier(transport: common.TransportKind) ApiTier {
    return switch (transport) {
        .cdp_ws, .bidi_ws => .modern,
    };
}

pub fn endpointTier(endpoint: []const u8) ApiTier {
    if (std.mem.startsWith(u8, endpoint, "cdp://") or
        std.mem.startsWith(u8, endpoint, "ws://") or
        std.mem.startsWith(u8, endpoint, "wss://"))
    {
        return .modern;
    }
    if (std.mem.startsWith(u8, endpoint, "bidi://")) return .modern;
    return .unsupported;
}

test "tier mappings stay stable" {
    try std.testing.expectEqual(ApiTier.modern, browserTier(.chrome));
    try std.testing.expectEqual(ApiTier.modern, browserTier(.firefox));
    try std.testing.expectEqual(ApiTier.unsupported, browserTier(.safari));
    try std.testing.expectEqual(ApiTier.modern, webViewTier(.electron));
    try std.testing.expectEqual(ApiTier.modern, transportTier(.cdp_ws));
    try std.testing.expectEqual(ApiTier.modern, endpointTier("wss://127.0.0.1/devtools/browser/abc"));
    try std.testing.expectEqual(ApiTier.unsupported, endpointTier("http://127.0.0.1:4444/session/1"));
}
