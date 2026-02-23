const std = @import("std");

pub const BrowserKind = enum {
    chrome,
    edge,
    safari,
    firefox,
    brave,
    tor,
    duckduckgo,
    mullvad,
    librewolf,
    epic,
    arc,
    vivaldi,
    sigmaos,
    sidekick,
    shift,
    operagx,
    palemoon,
};

pub const EngineKind = enum {
    chromium,
    gecko,
    webkit,
    unknown,
};

pub const Platform = enum {
    windows,
    macos,
    linux,
};

pub fn nativePlatform() Platform {
    return switch (@import("builtin").os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}

pub fn engineFor(kind: BrowserKind) EngineKind {
    return switch (kind) {
        .chrome,
        .edge,
        .brave,
        .duckduckgo,
        .epic,
        .arc,
        .vivaldi,
        .sidekick,
        .shift,
        .operagx,
        => .chromium,
        .firefox,
        .tor,
        .mullvad,
        .librewolf,
        .palemoon,
        => .gecko,
        .safari,
        => .webkit,
        .sigmaos,
        => .unknown,
    };
}

pub fn parseBrowserKind(name: []const u8) ?BrowserKind {
    const lowered = std.ascii.allocLowerString(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(lowered);

    if (std.mem.eql(u8, lowered, "chrome")) return .chrome;
    if (std.mem.eql(u8, lowered, "edge")) return .edge;
    if (std.mem.eql(u8, lowered, "safari")) return .safari;
    if (std.mem.eql(u8, lowered, "firefox")) return .firefox;
    if (std.mem.eql(u8, lowered, "brave")) return .brave;
    if (std.mem.eql(u8, lowered, "tor")) return .tor;
    if (std.mem.eql(u8, lowered, "duckduckgo")) return .duckduckgo;
    if (std.mem.eql(u8, lowered, "mullvad")) return .mullvad;
    if (std.mem.eql(u8, lowered, "librewolf")) return .librewolf;
    if (std.mem.eql(u8, lowered, "epic")) return .epic;
    if (std.mem.eql(u8, lowered, "arc")) return .arc;
    if (std.mem.eql(u8, lowered, "vivaldi")) return .vivaldi;
    if (std.mem.eql(u8, lowered, "sigmaos")) return .sigmaos;
    if (std.mem.eql(u8, lowered, "sidekick")) return .sidekick;
    if (std.mem.eql(u8, lowered, "shift")) return .shift;
    if (std.mem.eql(u8, lowered, "operagx")) return .operagx;
    if (std.mem.eql(u8, lowered, "pale moon") or std.mem.eql(u8, lowered, "palemoon")) return .palemoon;

    return null;
}
