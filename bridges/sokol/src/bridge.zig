/// Sokol bridge for labelle-imgui — provides the extern C functions
/// that the generic adapter calls, backed by sokol_imgui (simgui).
const sokol = @import("sokol");
const simgui = sokol.imgui;
const sapp = sokol.app;
const ig = @import("cimgui");

export fn imgui_bridge_setup(dark_theme: bool) void {
    simgui.setup(.{
        .ini_filename = null,
        .no_default_font = false,
        .logger = .{ .func = sokol.log.func },
    });
    if (!dark_theme) {
        ig.igStyleColorsLight(null);
    }
}

export fn imgui_bridge_begin() void {
    // sokol_imgui's simgui_new_frame asserts width/height > 0. In
    // headless preview mode (labelle-assembler#140) sokol_app never
    // ran so sapp.width()/height() return 0. Fall back to sensible
    // defaults so the assert (and ImGui's own sanity checks) pass.
    // The fallback dims affect ImGui's coordinate space only; the
    // actual render-target size lives in the IOSurface ring on the
    // editor side.
    var w = sapp.width();
    var h = sapp.height();
    var dt = sapp.frameDuration();
    var dpi = sapp.dpiScale();
    // Each field has its own fallback — sokol-app returns zero for any
    // of these in headless mode, and ImGui asserts on DeltaTime == 0
    // past frame 0 even if width/height are valid.
    if (w <= 0) w = 1024;
    if (h <= 0) h = 768;
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

/// Handle sokol_app events for imgui input (mouse, keyboard, etc.).
/// The sokol backend template should call this from its event callback.
export fn imgui_bridge_handle_event(ev: ?*const sapp.Event) bool {
    if (ev) |e| {
        return simgui.handleEvent(e.*);
    }
    return false;
}
