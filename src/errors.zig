const std = @import("std");
const types = @import("types.zig");

pub const ProtocolError = error{
    InvalidEndpoint,
    InvalidResponse,
    ProtocolCommandFailed,
    SessionNotReady,
    UnsupportedProtocol,
};

pub const TransportError = error{
    ConnectFailed,
    WriteFailed,
    ReadFailed,
    HandshakeFailed,
    Timeout,
    ConnectionClosed,
    InvalidStatus,
};

pub const CapabilityError = error{
    UnsupportedCapability,
};

pub const TimeoutError = error{
    Timeout,
};

pub const DiscoveryError = error{
    InvalidExplicitPath,
    OutOfMemory,
};

pub const LaunchError = error{
    SpawnFailed,
    UnsupportedEngine,
    OutOfMemory,
    PersistentProfileDirRequired,
};

pub const WebViewError = error{
    BridgeUnavailable,
    InvalidEndpoint,
    UnsupportedWebViewKind,
};

pub const UnsupportedCapabilityInfo = struct {
    engine: types.EngineKind,
    browser: types.BrowserKind,
    feature: types.CapabilityFeature,
    reason: []const u8,
};

pub fn formatUnsupported(
    allocator: std.mem.Allocator,
    info: UnsupportedCapabilityInfo,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "unsupported capability feature={s} engine={s} browser={s} reason={s}",
        .{ @tagName(info.feature), @tagName(info.engine), @tagName(info.browser), info.reason },
    );
}
