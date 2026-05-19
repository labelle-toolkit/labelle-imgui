/// Sokol bridge for labelle-imgui — provides the extern C functions
/// that the generic adapter calls, backed by sokol_imgui (simgui).
const sokol = @import("sokol");
const simgui = sokol.imgui;
const sapp = sokol.app;
const ig = @import("cimgui");

export fn imgui_bridge_setup(dark_theme: bool) void {
    // Pin pipeline formats so simgui's pipeline matches the headless
    // preview render target (BGRA8 IOSurface w/ DEPTH_STENCIL, no MSAA).
    // The sokol-gfx env defaults to these for both windowed and headless
    // builds, but specifying them explicitly avoids relying on swapchain
    // inference, which is brittle when sokol_app isn't running.
    simgui.setup(.{
        .ini_filename = null,
        .no_default_font = false,
        .color_format = .BGRA8,
        .depth_format = .DEPTH_STENCIL,
        .sample_count = 1,
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
        // Keyboard input intentionally not forwarded. `simgui_map_keycode`
        // (the GLFW-keycode → ImGuiKey_* translation table) is excluded
        // by SOKOL_IMGUI_NO_SOKOL_APP, and ImGui asserts on un-mapped
        // key ids (`IsNamedKeyOrMod`). Writing the table inline is doable
        // but out of scope for #143's mouse-driven menus. KEY_DOWN /
        // KEY_UP / CHAR fall through to the `else` and report unhandled.
        else => return false,
    }
    return true;
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
