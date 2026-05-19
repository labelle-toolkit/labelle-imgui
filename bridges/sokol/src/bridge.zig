/// Sokol bridge for labelle-imgui — provides the extern C functions
/// that the generic adapter calls, backed by sokol_imgui (simgui).
const sokol = @import("sokol");
const simgui = sokol.imgui;
const sapp = sokol.app;
const ig = @import("cimgui");

export fn imgui_bridge_setup(dark_theme: bool) void {
    // Leave pipeline formats at `.DEFAULT` / `0` so sokol-gfx infers
    // them from the environment passed to `sg.setup` per-backend. We
    // briefly hardcoded `.color_format = .BGRA8` + `.depth_format =
    // .DEPTH_STENCIL` + `.sample_count = 1` chasing the headless preview
    // bug in labelle-assembler#142, but the real culprit was `sapp` returning
    // bogus 1×1 dims when `SOKOL_IMGUI_NO_SOKOL_APP` is defined — fixed
    // by the `imgui_bridge_set_dims` setter below. Inference is safe now:
    // the Metal/IOSurface headless path supplies BGRA8 via `sg.setup`'s
    // environment, windowed Metal/D3D11 backends default to BGRA8 too,
    // and GL/GLES (Android) gets its native RGBA8 default. Hardcoding
    // BGRA8 unconditionally produced a pipeline-vs-swapchain mismatch
    // on GLES — credit @cursor for catching it on PR #10.
    simgui.setup(.{
        .ini_filename = null,
        .no_default_font = false,
        .logger = .{ .func = sokol.log.func },
    });
    if (!dark_theme) {
        ig.igStyleColorsLight(null);
    }
}

// Headless preview override. `sapp.width()`/`height()`/`dpiScale()` are
// unreliable when `SOKOL_IMGUI_NO_SOKOL_APP` is defined — on macOS they
// return 1/1/0 (not 0/0/0 as you'd hope), which silently bypasses an
// "is sapp running" check. The embedder calls `imgui_bridge_set_dims`
// from the headless render loop to give simgui the actual render-target
// size; otherwise simgui's vertex shader maps every vertex to NDC ~40
// and the GPU clips the entire ImGui draw away. See labelle-assembler#142.
var override_w: i32 = 0;
var override_h: i32 = 0;
var override_dpi: f32 = 0;

export fn imgui_bridge_set_dims(w: i32, h: i32, dpi: f32) void {
    override_w = w;
    override_h = h;
    override_dpi = dpi;
}

export fn imgui_bridge_begin() void {
    var w = if (override_w > 0) override_w else sapp.width();
    var h = if (override_h > 0) override_h else sapp.height();
    var dt = sapp.frameDuration();
    var dpi = if (override_dpi > 0) override_dpi else sapp.dpiScale();
    // sokol_imgui's simgui_new_frame asserts width/height > 0 and ImGui
    // asserts DeltaTime > 0 past frame 0. Defaults below keep the asserts
    // happy when an embedder forgets to call `imgui_bridge_set_dims` — but
    // they don't paper over the real bug (clipped draws); they at least
    // produce a visible canvas. Fall through with sane defaults.
    if (w <= 1) w = 800;
    if (h <= 1) h = 600;
    if (dt <= 0) dt = 1.0 / 60.0;
    if (dpi <= 0) dpi = 1.0;
    simgui.newFrame(.{
        .width = w,
        .height = h,
        .delta_time = dt,
        .dpi_scale = dpi,
    });
}

export fn imgui_bridge_end() void {
    simgui.render();
}

export fn imgui_bridge_shutdown() void {
    simgui.shutdown();
}

/// Handle sokol_app events for imgui input (mouse, scroll, keyboard).
/// `SOKOL_IMGUI_NO_SOKOL_APP` removed `simgui_handle_event` (the
/// one-call shortcut that reads from sapp internally), but the
/// per-event-type APIs (`simgui_add_mouse_pos_event` etc.) are still
/// available — they don't touch sokol_app. We translate `sapp.Event`
/// to those calls manually so windowed sokol-app builds keep working.
/// In headless preview mode no sapp events fire, so this is a no-op.
export fn imgui_bridge_handle_event(ev: ?*const sapp.Event) bool {
    const e = ev orelse return false;
    switch (e.type) {
        .MOUSE_MOVE => simgui.addMousePosEvent(e.mouse_x, e.mouse_y),
        .MOUSE_DOWN => {
            simgui.addMousePosEvent(e.mouse_x, e.mouse_y);
            simgui.addMouseButtonEvent(@intFromEnum(e.mouse_button), true);
        },
        .MOUSE_UP => {
            simgui.addMousePosEvent(e.mouse_x, e.mouse_y);
            simgui.addMouseButtonEvent(@intFromEnum(e.mouse_button), false);
        },
        .MOUSE_SCROLL => simgui.addMouseWheelEvent(e.scroll_x, e.scroll_y),
        // Touch. Mirrors upstream `simgui_handle_event`'s TOUCHES_* cases
        // (sokol_imgui.h ~line 3093) — translates touches to ImGui mouse
        // events via the `addTouch*Event` wrappers, which tag the event as
        // `ImGuiMouseSource_TouchScreen` so ImGui can render the cursor
        // appropriately. This is the primary input path on Android (the
        // sokol bridge's GLES3/NDK target). Without these cases all touch
        // events fell through to `else => return false` and ImGui was
        // non-interactive on mobile — credit @cursor on PR #10.
        //
        // Multi-touch limitation: ImGui IO is single-pointer, so we only
        // forward `touches[0]`; multi-touch gestures (pinch, two-finger
        // pan) would need higher-level handling outside this bridge.
        // Guard `num_touches >= 1` defensively against malformed events.
        .TOUCHES_BEGAN => {
            if (e.num_touches < 1) return false;
            simgui.addTouchPosEvent(e.touches[0].pos_x, e.touches[0].pos_y);
            simgui.addTouchButtonEvent(0, true);
        },
        .TOUCHES_MOVED => {
            if (e.num_touches < 1) return false;
            simgui.addTouchPosEvent(e.touches[0].pos_x, e.touches[0].pos_y);
        },
        .TOUCHES_ENDED => {
            if (e.num_touches < 1) return false;
            simgui.addTouchPosEvent(e.touches[0].pos_x, e.touches[0].pos_y);
            simgui.addTouchButtonEvent(0, false);
        },
        // Cancellation: no pos update — "forget this gesture" — just
        // release the synthesized left button so ImGui doesn't stick.
        .TOUCHES_CANCELLED => simgui.addTouchButtonEvent(0, false),
        // Keyboard. `simgui_map_keycode` (the GLFW-keycode → ImGuiKey_*
        // translation table) is excluded by SOKOL_IMGUI_NO_SOKOL_APP, so
        // we port that table inline as `mapKeycode` below. ImGui asserts
        // on un-mapped key ids (`IsNamedKeyOrMod`); per upstream notes,
        // it's safe to pass `ImGuiKey_None` (it's silently dropped), so
        // we forward unconditionally.
        .KEY_DOWN => {
            updateModifiers(e.modifiers);
            simgui.addKeyEvent(mapKeycode(e.key_code), true);
        },
        .KEY_UP => {
            updateModifiers(e.modifiers);
            simgui.addKeyEvent(mapKeycode(e.key_code), false);
        },
        .CHAR => {
            // Mirror upstream: drop control chars and chars carrying
            // Alt/Ctrl/Super modifiers (those should produce key events,
            // not text input).
            updateModifiers(e.modifiers);
            const mod_mask: u32 = sapp.modifier_alt | sapp.modifier_ctrl | sapp.modifier_super;
            if (e.char_code >= 32 and e.char_code != 127 and (e.modifiers & mod_mask) == 0) {
                simgui.addInputCharacter(e.char_code);
            }
        },
        else => return false,
    }
    return true;
}

/// GLFW-keycode (sapp.Keycode) → ImGuiKey_* translation. Ported inline
/// from `_simgui_map_keycode` in sokol_imgui.h (the upstream symbol is
/// gated behind `!SOKOL_IMGUI_NO_SOKOL_APP`). Returns `ImGuiKey_None`
/// for unmapped keys; ImGui accepts that as a no-op key event.
fn mapKeycode(k: sapp.Keycode) i32 {
    return switch (k) {
        .SPACE => ig.ImGuiKey_Space,
        .APOSTROPHE => ig.ImGuiKey_Apostrophe,
        .COMMA => ig.ImGuiKey_Comma,
        .MINUS => ig.ImGuiKey_Minus,
        .PERIOD => ig.ImGuiKey_Period,
        .SLASH => ig.ImGuiKey_Slash,
        ._0 => ig.ImGuiKey_0,
        ._1 => ig.ImGuiKey_1,
        ._2 => ig.ImGuiKey_2,
        ._3 => ig.ImGuiKey_3,
        ._4 => ig.ImGuiKey_4,
        ._5 => ig.ImGuiKey_5,
        ._6 => ig.ImGuiKey_6,
        ._7 => ig.ImGuiKey_7,
        ._8 => ig.ImGuiKey_8,
        ._9 => ig.ImGuiKey_9,
        .SEMICOLON => ig.ImGuiKey_Semicolon,
        .EQUAL => ig.ImGuiKey_Equal,
        .A => ig.ImGuiKey_A,
        .B => ig.ImGuiKey_B,
        .C => ig.ImGuiKey_C,
        .D => ig.ImGuiKey_D,
        .E => ig.ImGuiKey_E,
        .F => ig.ImGuiKey_F,
        .G => ig.ImGuiKey_G,
        .H => ig.ImGuiKey_H,
        .I => ig.ImGuiKey_I,
        .J => ig.ImGuiKey_J,
        .K => ig.ImGuiKey_K,
        .L => ig.ImGuiKey_L,
        .M => ig.ImGuiKey_M,
        .N => ig.ImGuiKey_N,
        .O => ig.ImGuiKey_O,
        .P => ig.ImGuiKey_P,
        .Q => ig.ImGuiKey_Q,
        .R => ig.ImGuiKey_R,
        .S => ig.ImGuiKey_S,
        .T => ig.ImGuiKey_T,
        .U => ig.ImGuiKey_U,
        .V => ig.ImGuiKey_V,
        .W => ig.ImGuiKey_W,
        .X => ig.ImGuiKey_X,
        .Y => ig.ImGuiKey_Y,
        .Z => ig.ImGuiKey_Z,
        .LEFT_BRACKET => ig.ImGuiKey_LeftBracket,
        .BACKSLASH => ig.ImGuiKey_Backslash,
        .RIGHT_BRACKET => ig.ImGuiKey_RightBracket,
        .GRAVE_ACCENT => ig.ImGuiKey_GraveAccent,
        .ESCAPE => ig.ImGuiKey_Escape,
        .ENTER => ig.ImGuiKey_Enter,
        .TAB => ig.ImGuiKey_Tab,
        .BACKSPACE => ig.ImGuiKey_Backspace,
        .INSERT => ig.ImGuiKey_Insert,
        .DELETE => ig.ImGuiKey_Delete,
        .RIGHT => ig.ImGuiKey_RightArrow,
        .LEFT => ig.ImGuiKey_LeftArrow,
        .DOWN => ig.ImGuiKey_DownArrow,
        .UP => ig.ImGuiKey_UpArrow,
        .PAGE_UP => ig.ImGuiKey_PageUp,
        .PAGE_DOWN => ig.ImGuiKey_PageDown,
        .HOME => ig.ImGuiKey_Home,
        .END => ig.ImGuiKey_End,
        .CAPS_LOCK => ig.ImGuiKey_CapsLock,
        .SCROLL_LOCK => ig.ImGuiKey_ScrollLock,
        .NUM_LOCK => ig.ImGuiKey_NumLock,
        .PRINT_SCREEN => ig.ImGuiKey_PrintScreen,
        .PAUSE => ig.ImGuiKey_Pause,
        .F1 => ig.ImGuiKey_F1,
        .F2 => ig.ImGuiKey_F2,
        .F3 => ig.ImGuiKey_F3,
        .F4 => ig.ImGuiKey_F4,
        .F5 => ig.ImGuiKey_F5,
        .F6 => ig.ImGuiKey_F6,
        .F7 => ig.ImGuiKey_F7,
        .F8 => ig.ImGuiKey_F8,
        .F9 => ig.ImGuiKey_F9,
        .F10 => ig.ImGuiKey_F10,
        .F11 => ig.ImGuiKey_F11,
        .F12 => ig.ImGuiKey_F12,
        .KP_0 => ig.ImGuiKey_Keypad0,
        .KP_1 => ig.ImGuiKey_Keypad1,
        .KP_2 => ig.ImGuiKey_Keypad2,
        .KP_3 => ig.ImGuiKey_Keypad3,
        .KP_4 => ig.ImGuiKey_Keypad4,
        .KP_5 => ig.ImGuiKey_Keypad5,
        .KP_6 => ig.ImGuiKey_Keypad6,
        .KP_7 => ig.ImGuiKey_Keypad7,
        .KP_8 => ig.ImGuiKey_Keypad8,
        .KP_9 => ig.ImGuiKey_Keypad9,
        .KP_DECIMAL => ig.ImGuiKey_KeypadDecimal,
        .KP_DIVIDE => ig.ImGuiKey_KeypadDivide,
        .KP_MULTIPLY => ig.ImGuiKey_KeypadMultiply,
        .KP_SUBTRACT => ig.ImGuiKey_KeypadSubtract,
        .KP_ADD => ig.ImGuiKey_KeypadAdd,
        .KP_ENTER => ig.ImGuiKey_KeypadEnter,
        .KP_EQUAL => ig.ImGuiKey_KeypadEqual,
        .LEFT_SHIFT => ig.ImGuiKey_LeftShift,
        .LEFT_CONTROL => ig.ImGuiKey_LeftCtrl,
        .LEFT_ALT => ig.ImGuiKey_LeftAlt,
        .LEFT_SUPER => ig.ImGuiKey_LeftSuper,
        .RIGHT_SHIFT => ig.ImGuiKey_RightShift,
        .RIGHT_CONTROL => ig.ImGuiKey_RightCtrl,
        .RIGHT_ALT => ig.ImGuiKey_RightAlt,
        .RIGHT_SUPER => ig.ImGuiKey_RightSuper,
        .MENU => ig.ImGuiKey_Menu,
        else => ig.ImGuiKey_None,
    };
}

/// Mirror `_simgui_update_modifiers`: keep ImGui's modifier-key state
/// in sync with sapp's modifier bitmask by emitting key events for the
/// four ImGuiMod_* aliases. Called from KEY_DOWN/KEY_UP/CHAR.
fn updateModifiers(mods: u32) void {
    simgui.addKeyEvent(ig.ImGuiMod_Ctrl, (mods & sapp.modifier_ctrl) != 0);
    simgui.addKeyEvent(ig.ImGuiMod_Shift, (mods & sapp.modifier_shift) != 0);
    simgui.addKeyEvent(ig.ImGuiMod_Alt, (mods & sapp.modifier_alt) != 0);
    simgui.addKeyEvent(ig.ImGuiMod_Super, (mods & sapp.modifier_super) != 0);
}

// Headless-preview input feed (labelle-assembler#143). The embedder
// drains Preview's input ring each frame and pushes events here; these
// thin wrappers forward to simgui's add_*_event family, which is
// available regardless of SOKOL_IMGUI_NO_SOKOL_APP since it doesn't
// touch sokol_app at all.

export fn imgui_bridge_mouse_pos(x: f32, y: f32) void {
    simgui.addMousePosEvent(x, y);
}

export fn imgui_bridge_mouse_button(button: i32, down: bool) void {
    simgui.addMouseButtonEvent(button, down);
}
