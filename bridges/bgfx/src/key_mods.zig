//! imgui (1.87+) reads Ctrl / Shift / Alt / Super only from `ImGuiMod_*`
//! key events, never from the left / right modifier keys, so a host that
//! forwards just GLFW's LEFT_CONTROL etc. (`imgui_bridge_key`) leaves
//! `io.KeyCtrl` false: Ctrl+A / C / V and Shift+arrows did nothing in a text
//! field. This tracks which of the eight GLFW modifier keys are held and
//! says what the matching `ImGuiMod_*` should be after each one changes, so
//! left and right Shift together still read as Shift until both are up.
//!
//! Pure (no cimgui), so it runs on the host.

const std = @import("std");

/// GLFW_KEY_LEFT_SHIFT; the eight modifier keys are 340..347 in the order
/// left shift, ctrl, alt, super, then right shift, ctrl, alt, super.
const FIRST = 340;
const LAST = 347;

/// The four imgui modifiers, in GLFW's order.
pub const Mod = enum(u2) { shift, ctrl, alt, super };

pub const Change = struct { mod: Mod, down: bool };

/// The modifier keys held (bit `key - 340`).
pub const Held = struct {
    bits: u8 = 0,

    /// Record `key` going `down` / up. For a modifier key, the state its
    /// `ImGuiMod_*` should now have (held while either side is); null for
    /// any other key.
    pub fn update(self: *Held, key: i32, down: bool) ?Change {
        if (key < FIRST or key > LAST) return null;
        const index: u3 = @intCast(key - FIRST);
        const bit = @as(u8, 1) << index;
        self.bits = if (down) self.bits | bit else self.bits & ~bit;
        const side: u2 = @truncate(index);
        const both = (@as(u8, 1) << side) | (@as(u8, 1) << (@as(u3, side) + 4));
        return .{ .mod = @enumFromInt(side), .down = self.bits & both != 0 };
    }
};

test "a modifier key drives its imgui modifier" {
    var held: Held = .{};
    try std.testing.expectEqual(Change{ .mod = .ctrl, .down = true }, held.update(341, true).?);
    try std.testing.expectEqual(Change{ .mod = .ctrl, .down = false }, held.update(341, false).?);
    try std.testing.expectEqual(Change{ .mod = .super, .down = true }, held.update(347, true).?);
    try std.testing.expectEqual(Change{ .mod = .alt, .down = true }, held.update(342, true).?);
}

test "left and right together: the modifier holds until both are up" {
    var held: Held = .{};
    _ = held.update(340, true);
    _ = held.update(344, true);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = true }, held.update(340, false).?);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = false }, held.update(344, false).?);
}

test "other keys are not modifiers" {
    var held: Held = .{};
    try std.testing.expect(held.update('A', true) == null);
    try std.testing.expect(held.update(339, true) == null);
    try std.testing.expect(held.update(348, true) == null); // MENU
    try std.testing.expectEqual(@as(u8, 0), held.bits);
}
