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
