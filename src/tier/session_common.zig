const core_session = @import("../core/session.zig");
const support_tier = @import("../catalog/support_tier.zig");
const types = @import("../types.zig");

pub fn fromBase(base: core_session.Session, expected_tier: types.ApiTier) !core_session.Session {
    if (support_tier.transportTier(base.transport) != expected_tier) {
        var tmp = base;
        tmp.deinit();
        return error.UnsupportedProtocol;
    }
    return base;
}

pub fn deinit(base: *core_session.Session) void {
    base.deinit();
    base.* = undefined;
}

pub fn intoBase(base: *core_session.Session) core_session.Session {
    const moved = base.*;
    base.* = undefined;
    return moved;
}

pub fn capabilities(base: *const core_session.Session) types.CapabilitySet {
    return base.capabilities();
}

pub fn supports(base: *const core_session.Session, feature: types.CapabilityFeature) bool {
    return base.supports(feature);
}
