/// Raylib bridge for Dear ImGui — re-exports rlImGui functions under the
/// generic imgui_bridge_* symbol contract expected by the imgui adapter.

#include <stdbool.h>

// rlImGui provides these symbols (compiled from rlImGui.cpp)
extern void rlImGuiSetup(bool dark_theme);
extern void rlImGuiBegin(void);
extern void rlImGuiEnd(void);
extern void rlImGuiShutdown(void);

// Generic bridge contract — called by the imgui adapter
void imgui_bridge_setup(bool dark_theme) {
    rlImGuiSetup(dark_theme);
}

void imgui_bridge_begin(void) {
    rlImGuiBegin();
}

void imgui_bridge_end(void) {
    rlImGuiEnd();
}

void imgui_bridge_shutdown(void) {
    rlImGuiShutdown();
}

// External textures — not supported on this bridge.
//
// rlImGui owns the ImTextureID mapping itself (a raylib Texture2D id is
// handed to ImGui directly), so there is no slot table here to register a
// borrowed handle into. Callers that need game art in an ImGui draw list
// on raylib should pass the raylib texture id straight to AddImage.
//
// Returning 0 (ImTextureID_Invalid) is the documented "unsupported"
// answer; the adapter tells callers to check for it.
unsigned long long imgui_bridge_register_texture(unsigned short handle_idx) {
    (void)handle_idx;
    return 0;
}

void imgui_bridge_unregister_texture(unsigned long long tex_id) {
    (void)tex_id;
}
