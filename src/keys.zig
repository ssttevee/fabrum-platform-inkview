//! What the reader's hardware keys mean to fabrum: `IV_KEY_*` codes to
//! `app.KeyEvent.Key`. The mapping is a value, so a host can change it in
//! `Options.keys`.
const std = @import("std");
const fabrum = @import("fabrum");
const KeyEvent = fabrum.app.KeyEvent;
const inkview = @import("inkview.zig");

/// Which fabrum key each hardware key stands for, or null to leave it to
/// the library's default action (the power key's sleep, Home's main
/// menu).
pub const KeyMap = struct {
    /// Both pairs of page keys turn pages: Page Up and Page Down, which
    /// scroll containers and lists take.
    prev: ?KeyEvent.Key = .page_up,
    next: ?KeyEvent.Key = .page_down,
    prev2: ?KeyEvent.Key = .page_up,
    next2: ?KeyEvent.Key = .page_down,
    up: ?KeyEvent.Key = .up,
    down: ?KeyEvent.Key = .down,
    left: ?KeyEvent.Key = .left,
    right: ?KeyEvent.Key = .right,
    /// The centre key clicks what has focus, as Enter does.
    ok: ?KeyEvent.Key = .enter,
    /// Escape: fabrum clears drawn focus with it.
    back: ?KeyEvent.Key = .escape,
    /// F10, as GTK's menu key.
    menu: ?KeyEvent.Key = .{ .f = 10 },
    /// Left to the library, which opens the main menu with it.
    home: ?KeyEvent.Key = null,
    tab: ?KeyEvent.Key = .tab,
    delete: ?KeyEvent.Key = .backspace,
    plus: ?KeyEvent.Key = .{ .char = '+' },
    minus: ?KeyEvent.Key = .{ .char = '-' },
    /// Left to the library: sleep.
    power: ?KeyEvent.Key = null,

    pub const default: KeyMap = .{};

    /// The fabrum key for a hardware key, or null for keys the map leaves
    /// to the library. Every named `inkview.Key` is a field here, which
    /// the switch checks at compile time.
    pub fn of(self: KeyMap, key: inkview.Key) ?KeyEvent.Key {
        return switch (key) {
            inline else => |tag| @field(self, @tagName(tag)),
            _ => null,
        };
    }
};

test "the page keys turn pages and the rest are left alone or named" {
    const map: KeyMap = .default;
    try std.testing.expectEqual(KeyEvent.Key.page_up, map.of(.prev).?);
    try std.testing.expectEqual(KeyEvent.Key.page_down, map.of(.next).?);
    try std.testing.expectEqual(KeyEvent.Key.page_down, map.of(.next2).?);
    try std.testing.expectEqual(KeyEvent.Key.enter, map.of(.ok).?);
    try std.testing.expectEqual(KeyEvent.Key{ .f = 10 }, map.of(.menu).?);
    try std.testing.expectEqual(@as(?KeyEvent.Key, null), map.of(.power));
    try std.testing.expectEqual(@as(?KeyEvent.Key, null), map.of(@fromBackingInt(0x30)));
    const swapped: KeyMap = .{ .prev = .page_down, .next = .page_up };
    try std.testing.expectEqual(KeyEvent.Key.page_down, swapped.of(.prev).?);
}
