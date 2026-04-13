/// Sokol bridge for labelle-imgui — provides the extern C functions
/// that the generic adapter calls, backed by sokol_imgui (simgui).
const sokol = @import("sokol");
const simgui = sokol.imgui;
const sapp = sokol.app;

export fn imgui_bridge_setup(dark_theme: bool) void {
    simgui.setup(.{
        .ini_filename = null,
        .no_default_font = false,
        .logger = .{ .func = sokol.log.func },
    });
    if (dark_theme) {
        // cimgui dark theme is the default for sokol_imgui
    }
}

export fn imgui_bridge_begin() void {
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
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
pub fn handleEvent(ev: [*c]const sapp.Event) bool {
    return simgui.handleEvent(ev.*);
}
