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
    if (w <= 0) w = 800;
    if (h <= 0) h = 600;
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
/// Stubbed: the bridge compiles sokol_imgui with SOKOL_IMGUI_NO_SOKOL_APP,
/// which excludes `simgui_handle_event` (and the sapp-coupled cursor /
/// keyboard helpers) from the C build. In headless preview mode this is
/// fine because events flow through the editor side, not sokol_app.
/// For a windowed build, a future change can gate this on a build option.
export fn imgui_bridge_handle_event(ev: ?*const sapp.Event) bool {
    _ = ev;
    return false;
}
