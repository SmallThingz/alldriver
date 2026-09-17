const std = @import("std");
const session_mod = @import("session.zig");
const executor = @import("../protocol/executor.zig");
const json_util = @import("../util/json.zig");

pub const InputClient = struct {
    session: *session_mod.ModernSession,

    pub fn click(self: *InputClient, selector: []const u8) !void {
        try self.session.base.click(selector);
    }

    pub fn typeText(self: *InputClient, selector: []const u8, text: []const u8) !void {
        try self.session.base.typeText(selector, text);
    }

    pub fn keyDown(self: *InputClient, key: []const u8) !void {
        try dispatchKeyboard(self.session, key, true);
    }

    pub fn keyUp(self: *InputClient, key: []const u8) !void {
        try dispatchKeyboard(self.session, key, false);
    }

    pub fn mouseMove(self: *InputClient, x: i32, y: i32) !void {
        const base = &self.session.base;
        base.input_lock.lock();
        defer base.input_lock.unlock();
        const params = try std.fmt.allocPrint(base.allocator, "{{\"type\":\"mouseMoved\",\"x\":{d},\"y\":{d},\"modifiers\":{d}}}", .{ x, y, base.input_modifiers });
        defer base.allocator.free(params);
        const result = try executor.callCdp(base, "Input.dispatchMouseEvent", params);
        base.allocator.free(result);
        base.input_mouse_x = x;
        base.input_mouse_y = y;
    }

    pub fn wheel(self: *InputClient, delta_x: i32, delta_y: i32) !void {
        const base = &self.session.base;
        base.input_lock.lock();
        defer base.input_lock.unlock();
        const params = try std.fmt.allocPrint(base.allocator, "{{\"type\":\"mouseWheel\",\"x\":{d},\"y\":{d},\"deltaX\":{d},\"deltaY\":{d},\"modifiers\":{d}}}", .{ base.input_mouse_x, base.input_mouse_y, delta_x, delta_y, base.input_modifiers });
        defer base.allocator.free(params);
        const result = try executor.callCdp(base, "Input.dispatchMouseEvent", params);
        base.allocator.free(result);
    }
};

const Key = struct {
    key: []const u8,
    code: []const u8,
    vk: u16,
    text: []const u8 = "",
    modifier: u8 = 0,
    location: u8 = 0,
};

const named_keys = [_]Key{
    .{ .key = "Enter", .code = "Enter", .vk = 13, .text = "\r" },
    .{ .key = "Tab", .code = "Tab", .vk = 9 },
    .{ .key = "Backspace", .code = "Backspace", .vk = 8 },
    .{ .key = "Delete", .code = "Delete", .vk = 46 },
    .{ .key = "Escape", .code = "Escape", .vk = 27 },
    .{ .key = "ArrowLeft", .code = "ArrowLeft", .vk = 37 },
    .{ .key = "ArrowUp", .code = "ArrowUp", .vk = 38 },
    .{ .key = "ArrowRight", .code = "ArrowRight", .vk = 39 },
    .{ .key = "ArrowDown", .code = "ArrowDown", .vk = 40 },
    .{ .key = "Home", .code = "Home", .vk = 36 },
    .{ .key = "End", .code = "End", .vk = 35 },
    .{ .key = "PageUp", .code = "PageUp", .vk = 33 },
    .{ .key = "PageDown", .code = "PageDown", .vk = 34 },
    .{ .key = "Insert", .code = "Insert", .vk = 45 },
    .{ .key = "Shift", .code = "ShiftLeft", .vk = 16, .modifier = 8, .location = 1 },
    .{ .key = "Control", .code = "ControlLeft", .vk = 17, .modifier = 2, .location = 1 },
    .{ .key = "Alt", .code = "AltLeft", .vk = 18, .modifier = 1, .location = 1 },
    .{ .key = "Meta", .code = "MetaLeft", .vk = 91, .modifier = 4, .location = 1 },
    .{ .key = "CapsLock", .code = "CapsLock", .vk = 20 },
    .{ .key = " ", .code = "Space", .vk = 32, .text = " " },
};

fn describeKey(raw: []const u8, shifted: bool) !Key {
    const key = if (std.mem.eql(u8, raw, "Space")) " " else raw;
    for (named_keys) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry;
    }
    const lower = "abcdefghijklmnopqrstuvwxyz";
    const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const codes = "KeyAKeyBKeyCKeyDKeyEKeyFKeyGKeyHKeyIKeyJKeyKKeyLKeyMKeyNKeyOKeyPKeyQKeyRKeySKeyTKeyUKeyVKeyWKeyXKeyYKeyZ";
    if (key.len == 1 and std.ascii.isAlphabetic(key[0])) {
        const index: usize = std.ascii.toLower(key[0]) - 'a';
        const chars = if (shifted or std.ascii.isUpper(key[0])) upper else lower;
        return .{ .key = chars[index..][0..1], .text = chars[index..][0..1], .code = codes[index * 4 ..][0..4], .vk = @intCast(65 + index) };
    }
    const plain = "0123456789;=,-./`[\\]'";
    const shifted_chars = ")!@#$%^&*(:+<_>?~{|}\"";
    const punctuation_codes = [_][]const u8{ "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Semicolon", "Equal", "Comma", "Minus", "Period", "Slash", "Backquote", "BracketLeft", "Backslash", "BracketRight", "Quote" };
    const vks = [_]u16{ 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 186, 187, 188, 189, 190, 191, 192, 219, 220, 221, 222 };
    if (key.len == 1) {
        for (plain, shifted_chars, 0..) |normal, upper_char, i| {
            if (key[0] == normal or key[0] == upper_char) {
                const chars = if (shifted or key[0] == upper_char) shifted_chars else plain;
                return .{ .key = chars[i..][0..1], .text = chars[i..][0..1], .code = punctuation_codes[i], .vk = vks[i] };
            }
        }
    }
    const function_keys = [_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };
    for (function_keys, 0..) |name, i| {
        if (std.mem.eql(u8, name, key)) return .{ .key = name, .code = name, .vk = @intCast(112 + i) };
    }
    // A single Unicode scalar is valid keyboard text even without a US physical key.
    if (key.len > 0 and std.unicode.utf8ValidateSlice(key) and (std.unicode.utf8CountCodepoints(key) catch 0) == 1) {
        if (key.len == 1 and key[0] < 32) return error.InvalidKey;
        return .{ .key = key, .code = "", .vk = 0, .text = key };
    }
    return error.InvalidKey;
}

fn keyboardParams(allocator: std.mem.Allocator, key: Key, down: bool, modifiers: u8) ![]u8 {
    const text = if (down and modifiers & 7 == 0) key.text else "";
    const escaped_key = try json_util.escapeJsonString(allocator, key.key);
    defer allocator.free(escaped_key);
    const escaped_text = try json_util.escapeJsonString(allocator, text);
    defer allocator.free(escaped_text);
    return std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"key\":\"{s}\",\"code\":\"{s}\",\"windowsVirtualKeyCode\":{d},\"text\":\"{s}\",\"modifiers\":{d},\"location\":{d}}}", .{ if (!down) "keyUp" else if (text.len > 0) "keyDown" else "rawKeyDown", escaped_key, key.code, key.vk, escaped_text, modifiers, key.location });
}

fn dispatchKeyboard(session: *session_mod.ModernSession, raw: []const u8, down: bool) !void {
    const base = &session.base;
    base.input_lock.lock();
    defer base.input_lock.unlock();
    const key = try describeKey(raw, base.input_modifiers & 8 != 0);
    const modifiers = if (down) base.input_modifiers | key.modifier else base.input_modifiers & ~key.modifier;
    const params = try keyboardParams(base.allocator, key, down, modifiers);
    defer base.allocator.free(params);
    const result = try executor.callCdp(base, "Input.dispatchKeyEvent", params);
    base.allocator.free(result);
    base.input_modifiers = modifiers;
}

test "keyboard mapping preserves physical keys and shifted text" {
    const a = try describeKey("a", false);
    try std.testing.expectEqualStrings("KeyA", a.code);
    try std.testing.expectEqual(@as(u16, 65), a.vk);
    try std.testing.expectEqualStrings("a", a.text);
    try std.testing.expectEqualStrings("A", (try describeKey("a", true)).text);
    try std.testing.expectEqualStrings("!", (try describeKey("1", true)).text);
    try std.testing.expectEqualStrings("Digit1", (try describeKey("!", false)).code);
    try std.testing.expectEqualStrings("\r", (try describeKey("Enter", false)).text);
    try std.testing.expectEqualStrings("é", (try describeKey("é", false)).text);
    try std.testing.expectEqual(@as(u16, 123), (try describeKey("F12", false)).vk);
    try std.testing.expectError(error.InvalidKey, describeKey("not-a-key", false));
    try std.testing.expectError(error.InvalidKey, describeKey("", false));
    try std.testing.expectError(error.InvalidKey, describeKey("\xff", false));
}

test "keyboard command suppresses text on release and shortcuts" {
    const allocator = std.testing.allocator;
    const key = try describeKey("a", false);
    const cases = [_]struct { down: bool, modifiers: u8, kind: []const u8, text: []const u8 }{
        .{ .down = true, .modifiers = 0, .kind = "keyDown", .text = "a" },
        .{ .down = false, .modifiers = 0, .kind = "keyUp", .text = "" },
        .{ .down = true, .modifiers = 2, .kind = "rawKeyDown", .text = "" },
    };
    for (cases) |case| {
        const params = try keyboardParams(allocator, key, case.down, case.modifiers);
        defer allocator.free(params);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.kind, parsed.value.object.get("type").?.string);
        try std.testing.expectEqualStrings(case.text, parsed.value.object.get("text").?.string);
        try std.testing.expectEqual(@as(i64, case.modifiers), parsed.value.object.get("modifiers").?.integer);
    }
}
