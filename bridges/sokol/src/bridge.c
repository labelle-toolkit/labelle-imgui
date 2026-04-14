/// Sokol bridge for Dear ImGui — re-exports sokol_imgui's simgui_*
/// functions under the generic imgui_bridge_* symbol contract expected
/// by the imgui adapter.
///
/// This bridge is a static library with unresolved references to
/// simgui_setup/new_frame/render/shutdown and sapp_width/height/etc.
/// Those symbols are provided at the final exe link step by sokol_clib,
/// which the labelle-sokol backend builds with `with_sokol_imgui=true`.
///
/// The bridge needs sokol's headers at compile time (for simgui_desc_t
/// and friends) but does NOT link sokol itself — that's the backend's job.

#include <string.h>
#include <stdbool.h>

#define SOKOL_GLCORE
#include "sokol_gfx.h"
#include "sokol_app.h"
#include "sokol_imgui.h"

void imgui_bridge_setup(bool dark_theme) {
    (void)dark_theme; // sokol_imgui has no built-in theme; defaults to dark
    simgui_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    simgui_setup(&desc);
}

void imgui_bridge_begin(void) {
    simgui_frame_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.width = sapp_width();
    desc.height = sapp_height();
    desc.delta_time = sapp_frame_duration();
    desc.dpi_scale = sapp_dpi_scale();
    simgui_new_frame(&desc);
}

void imgui_bridge_end(void) {
    simgui_render();
}

void imgui_bridge_shutdown(void) {
    simgui_shutdown();
}
