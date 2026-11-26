//! Which mouse buttons imgui was last told are down, so the bridge forwards
//! a button only when it changes. The desktop host sends every button's
//! state each frame; imgui drops the repeats itself, except on macOS, where
//! it turns Ctrl+left click into a right click (`ConfigMacOSXBehaviors`):
//! the host's "right is up" then contradicted it every frame, the right
//! button flipped down and up each frame, and imgui's trickled input queue
//! held the mouse moves behind those changes, so the pointer lagged further
//! and further behind while Ctrl was held.
//!
//! Pure (no cimgui), so it runs on the host.

const std = @import("std");

/// imgui's `ImGuiMouseButton_COUNT`.
pub const COUNT = 5;

pub const Buttons = struct {
    down: [COUNT]bool = @splat(false),

    /// Record `button` as `down`: true when that is a change imgui must
    /// hear about, false for a repeat (or a button imgui doesn't have).
    pub fn changed(self: *Buttons, button: i32, down: bool) bool {
        if (button < 0 or button >= COUNT) return false;
        const i: usize = @intCast(button);
        if (self.down[i] == down) return false;
        self.down[i] = down;
        return true;
    }
};

test "only a change is forwarded" {
    var buttons: Buttons = .{};
    try std.testing.expect(!buttons.changed(1, false));
    try std.testing.expect(buttons.changed(0, true));
    try std.testing.expect(!buttons.changed(0, true));
    try std.testing.expect(buttons.changed(0, false));
    try std.testing.expect(!buttons.changed(0, false));
}

test "a held left button with the right one up every frame stays quiet" {
    var buttons: Buttons = .{};
    try std.testing.expect(buttons.changed(0, true));
    for (0..3) |_| {
        try std.testing.expect(!buttons.changed(0, true));
        try std.testing.expect(!buttons.changed(1, false));
        try std.testing.expect(!buttons.changed(2, false));
    }
}

test "buttons imgui doesn't have are ignored" {
    var buttons: Buttons = .{};
    try std.testing.expect(!buttons.changed(-1, true));
    try std.testing.expect(!buttons.changed(COUNT, true));
}
