const std = @import("std");
const executor = @import("executor.zig");
const support_tier = @import("../catalog/support_tier.zig");
const Session = @import("../core/session.zig").Session;
const types = @import("../types.zig");

fn assertModern(session: *Session) !void {
    if (support_tier.transportTier(session.transport) != .modern) return error.UnsupportedProtocol;
}

pub fn navigate(session: *Session, url: []const u8) !void {
    try assertModern(session);
    try executor.navigate(session, url);
}

pub fn reload(session: *Session) !void {
    try assertModern(session);
    try executor.reload(session);
}

pub fn click(session: *Session, selector: []const u8) !void {
    try assertModern(session);
    try executor.click(session, selector);
}

pub fn typeText(session: *Session, selector: []const u8, text: []const u8) !void {
    try assertModern(session);
    try executor.typeText(session, selector, text);
}

pub fn evaluate(session: *Session, script: []const u8) ![]u8 {
    try assertModern(session);
    return executor.evaluate(session, script);
}

pub fn waitForDomReady(session: *Session, timeout_ms: u32) !void {
    try assertModern(session);
    try executor.waitForDomReady(session, timeout_ms);
}

pub fn waitForSelector(session: *Session, selector: []const u8, timeout_ms: u32) !void {
    try assertModern(session);
    try executor.waitForSelector(session, selector, timeout_ms);
}

pub fn screenshot(session: *Session) ![]u8 {
    try assertModern(session);
    return executor.screenshot(session);
}

pub fn startTracing(session: *Session) !void {
    try assertModern(session);
    try executor.startTracing(session);
}

pub fn stopTracing(session: *Session) ![]u8 {
    try assertModern(session);
    return executor.stopTracing(session);
}

pub fn enableNetworkInterception(session: *Session) !void {
    try assertModern(session);
    try executor.enableNetworkInterception(session);
}

pub fn disableNetworkInterception(session: *Session) !void {
    try assertModern(session);
    try executor.disableNetworkInterception(session);
}

pub fn addNetworkRule(session: *Session, rule: types.NetworkRule) !void {
    try assertModern(session);
    try executor.addNetworkRule(session, rule);
}
