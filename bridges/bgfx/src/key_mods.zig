//! imgui (1.87+) reads Ctrl / Shift / Alt / Super only from `ImGuiMod_*`
//! key events, never from the left / right modifier keys, so a host that
//! forwards just GLFW's LEFT_CONTROL etc. (`imgui_bridge_key`) leaves
//! `io.KeyCtrl` false: Ctrl+A / C / V and Shift+arrows did nothing in a text
//! field. This tracks which of the eight GLFW modifier keys are held and
//! says what the matching `ImGuiMod_*` should be after each one changes, so
//! left and right Shift together still read as Shift until both are up.
//!
//! A modifier can also be held with no key event to say so: one pressed
//! before the window had focus, or a chord sent by an automation tool, which
//! arrives as the plain key with the modifier only in the event's flags.
//! `flags` takes those flags (GLFW's `mods`, which the host has on every key
//! and mouse-button event) and says which `ImGuiMod_*` no longer agree.
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

/// Up to one change per modifier.
pub const Changes = struct {
    items: [4]Change = undefined,
    len: u3 = 0,

    pub fn slice(self: *const Changes) []const Change {
        return self.items[0..self.len];
    }
};

/// The modifier keys held (`bits`, bit `key - 340`) and the modifiers imgui
/// was last told are down (`told`, bit per `Mod`).
pub const Held = struct {
    bits: u8 = 0,
    told: u4 = 0,

    /// Record `key` going `down` / up. For a modifier key, the state its
    /// `ImGuiMod_*` should now have (held while either side is); null for
    /// any other key.
    pub fn update(self: *Held, key: i32, down: bool) ?Change {
        if (key < FIRST or key > LAST) return null;
        const index: u3 = @intCast(key - FIRST);
        const bit = @as(u8, 1) << index;
        self.bits = if (down) self.bits | bit else self.bits & ~bit;
        const side: u2 = @truncate(index);
        const now = self.bits & sides(side) != 0;
        self.tell(side, now);
        return .{ .mod = @enumFromInt(side), .down = now };
    }

    /// The modifier flags an event carried (GLFW's `mods`: Shift 1, Control
    /// 2, Alt 4, Super 8; other bits ignored): the changes that bring imgui's
    /// modifiers in line with them. A modifier the flags say is up has
    /// neither of its keys held, whatever was seen before.
    ///
    /// Safe to call ahead of `update` for the modifier key's own event,
    /// where platforms disagree on whether the flags already count that key
    /// (macOS and Windows: yes; X11 and Wayland: not yet): `update` runs
    /// second and has the last word on its modifier.
    pub fn flags(self: *Held, mods: i32) Changes {
        var changes: Changes = .{};
        for (0..4) |i| {
            const mod: u2 = @intCast(i);
            const want = mods & (@as(i32, 1) << mod) != 0;
            if (!want) self.bits &= ~sides(mod);
            if (want == self.isTold(mod)) continue;
            self.tell(mod, want);
            changes.items[changes.len] = .{ .mod = @enumFromInt(mod), .down = want };
            changes.len += 1;
        }
        return changes;
    }

    /// The left and right key bits of one modifier.
    fn sides(mod: u2) u8 {
        return (@as(u8, 1) << mod) | (@as(u8, 1) << (@as(u3, mod) + 4));
    }

    fn isTold(self: *const Held, mod: u2) bool {
        return self.told & (@as(u4, 1) << mod) != 0;
    }

    fn tell(self: *Held, mod: u2, down: bool) void {
        const bit = @as(u4, 1) << mod;
        self.told = if (down) self.told | bit else self.told & ~bit;
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

test "flags: a chord with no modifier key event still sets the modifier" {
    var held: Held = .{};
    // Shift+Left from an automation tool: the arrow key, Shift only a flag.
    const down = held.flags(0x1);
    try std.testing.expectEqualSlices(Change, &.{.{ .mod = .shift, .down = true }}, down.slice());
    try std.testing.expect(held.update(263, true) == null);
    // The next key carries no flag: Shift is let go before it is handled.
    const up = held.flags(0);
    try std.testing.expectEqualSlices(Change, &.{.{ .mod = .shift, .down = false }}, up.slice());
}

test "flags: nothing to say while they agree with the keys" {
    var held: Held = .{};
    _ = held.update(341, true); // left ctrl
    try std.testing.expectEqual(@as(usize, 0), held.flags(0x2).slice().len);
    try std.testing.expectEqual(@as(usize, 0), held.flags(0x2).slice().len);
    _ = held.update(341, false);
    try std.testing.expectEqual(@as(usize, 0), held.flags(0).slice().len);
}

test "flags: several modifiers at once, lock bits ignored" {
    var held: Held = .{};
    // Ctrl + Super, with Caps Lock (0x10) and Num Lock (0x20) set.
    const changes = held.flags(0x2 | 0x8 | 0x10 | 0x20);
    try std.testing.expectEqualSlices(Change, &.{
        .{ .mod = .ctrl, .down = true },
        .{ .mod = .super, .down = true },
    }, changes.slice());
    try std.testing.expectEqual(@as(usize, 0), held.flags(0x2 | 0x8).slice().len);
}

test "flags: a key whose release never arrived is let go" {
    var held: Held = .{};
    _ = held.update(340, true); // left shift down, its release lost
    const changes = held.flags(0);
    try std.testing.expectEqualSlices(Change, &.{.{ .mod = .shift, .down = false }}, changes.slice());
    // The stale left key does not keep Shift down after the right one is used.
    _ = held.update(344, true);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = false }, held.update(344, false).?);
}

test "flags before the modifier key's own event, on either kind of platform" {
    // macOS / Windows: the flags already count the key.
    var after: Held = .{};
    try std.testing.expectEqual(@as(usize, 1), after.flags(0x1).slice().len);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = true }, after.update(340, true).?);
    try std.testing.expectEqual(@as(usize, 1), after.flags(0).slice().len);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = false }, after.update(340, false).?);
    try std.testing.expectEqual(@as(u4, 0), after.told);

    // X11 / Wayland: the flags are from just before the key.
    var before: Held = .{};
    try std.testing.expectEqual(@as(usize, 0), before.flags(0).slice().len);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = true }, before.update(340, true).?);
    try std.testing.expectEqual(@as(usize, 0), before.flags(0x1).slice().len);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = false }, before.update(340, false).?);
    try std.testing.expectEqual(@as(u4, 0), before.told);
}

test "flags: one side released while the other is held keeps the modifier" {
    var held: Held = .{};
    _ = held.update(340, true);
    _ = held.update(344, true);
    try std.testing.expectEqual(@as(usize, 0), held.flags(0x1).slice().len);
    try std.testing.expectEqual(Change{ .mod = .shift, .down = true }, held.update(340, false).?);
}
