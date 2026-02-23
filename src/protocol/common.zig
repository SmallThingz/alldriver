const types = @import("../types.zig");

pub const AdapterKind = enum {
    cdp,
    webdriver,
    bidi,
};

pub fn defaultCapabilityForEngine(engine: types.EngineKind) types.CapabilitySet {
    return switch (engine) {
        .chromium => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = true,
            .downloads = true,
            .bidi_events = true,
        },
        .gecko => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = true,
            .tracing = false,
            .downloads = true,
            .bidi_events = true,
        },
        .webkit => .{
            .dom = true,
            .js_eval = true,
            .network_intercept = false,
            .tracing = false,
            .downloads = true,
            .bidi_events = false,
        },
        .unknown => .{
            .dom = false,
            .js_eval = false,
            .network_intercept = false,
            .tracing = false,
            .downloads = false,
            .bidi_events = false,
        },
    };
}

pub fn preferredAdapterForEngine(engine: types.EngineKind) AdapterKind {
    return switch (engine) {
        .chromium => .cdp,
        .gecko => .bidi,
        .webkit => .webdriver,
        .unknown => .webdriver,
    };
}
