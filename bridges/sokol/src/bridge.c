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

// Use SOKOL_DUMMY_BACKEND for header inclusion — we only touch backend-
// agnostic types here (simgui_desc_t / simgui_frame_desc_t), and the
// bridge static lib must not bake in a backend choice. The actual exe's
// sokol_clib (built by labelle-sokol) decides the real backend at its
// own compile time, and link-step ABI stays consistent because the
// types we use are not gated on backend macros.
#define SOKOL_DUMMY_BACKEND
#include "sokol_gfx.h"
#include "sokol_app.h"
#include "sokol_imgui.h"

// Forward declarations from cimgui.h — we only need these two function
// signatures and they're stable plain-C ABI, so we avoid pulling in the
// whole cimgui dep just for the theme switch. NULL means "apply to the
// current global style" (matches cimgui's default-arg semantics).
extern void igStyleColorsDark(void* dst);
extern void igStyleColorsLight(void* dst);

void imgui_bridge_setup(bool dark_theme) {
    simgui_desc_t desc;
    memset(&desc, 0, sizeof(desc));
    simgui_setup(&desc);
    if (dark_theme) {
        igStyleColorsDark(NULL);
    } else {
        igStyleColorsLight(NULL);
    }
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
