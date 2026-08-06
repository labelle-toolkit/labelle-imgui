/// Dear ImGui GUI adapter — satisfies the engine GuiInterface contract
/// including the standard widget API for debug tooling.
///
/// Game code accesses the full ImGui API through GuiBackend.ig (the cimgui module).
pub const ig = @import("cimgui");

// Bridge contract
extern fn imgui_bridge_setup(dark_theme: bool) void;
extern fn imgui_bridge_begin() void;
extern fn imgui_bridge_end() void;
extern fn imgui_bridge_shutdown() void;
extern fn imgui_bridge_register_texture(handle_idx: u16) u64;
extern fn imgui_bridge_unregister_texture(tex_id: u64) void;

pub fn init() void {
    imgui_bridge_setup(true);
}

pub fn shutdown() void {
    imgui_bridge_shutdown();
}

pub fn begin() void {
    imgui_bridge_begin();
}

pub fn end() void {
    imgui_bridge_end();
}

pub fn wantsMouse() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureMouse;
}

pub fn wantsKeyboard() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureKeyboard;
}

// ── Standard widget API (for GuiInterface) ─────────────────

pub fn beginWindow(name: [*:0]const u8) bool {
    return ig.igBegin(name, null, 0);
}

pub fn endWindow() void {
    ig.igEnd();
}

pub fn separator() void {
    ig.igSeparator();
}

pub fn spacing() void {
    ig.igSpacing();
}

pub fn sameLine() void {
    ig.igSameLine();
}

pub fn label(str: [*:0]const u8) void {
    ig.igTextUnformatted(str);
}

pub fn textFmt(fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, ig.igText, .{fmt} ++ args);
}

pub fn button(str: [*:0]const u8) bool {
    return ig.igButton(str);
}

pub fn checkbox(str: [*:0]const u8, val: *bool) bool {
    return ig.igCheckbox(str, val);
}

pub fn sliderFloat(str: [*:0]const u8, val: *f32, min: f32, max: f32) bool {
    return ig.igSliderFloat(str, val, min, max);
}

pub fn treeNode(str: [*:0]const u8) bool {
    return ig.igTreeNodeEx(str, 0);
}

pub fn treePop() void {
    ig.igTreePop();
}

pub fn beginTable(str: [*:0]const u8, columns: i32) bool {
    return ig.igBeginTable(str, columns, 0);
}

pub fn endTable() void {
    ig.igEndTable();
}

pub fn tableNextRow() void {
    ig.igTableNextRow();
}

pub fn tableNextColumn() bool {
    return ig.igTableNextColumn();
}

// ── External textures ──────────────────────────────────────────────────
//
// Hand ImGui a texture the application already has on the GPU, so overlay
// code can draw game art with `ImDrawList::AddImage`. Without this, the
// only textures ImGui can sample are the ones it uploaded itself from its
// own pixel buffers — which leaves `AddImage` unusable for a sprite atlas
// the renderer loaded.
//
// Support is per-bridge: bgfx implements it, raylib and sokol return 0
// (see each bridge's stub for why). Always check for 0 before drawing.

/// Register a renderer-native texture handle and get an `ImTextureID` for
/// it. Returns 0 when the handle is invalid, the table is full, or the
/// active bridge does not support external textures.
///
/// This is a **borrow**: the caller keeps ownership and must call
/// `unregisterTexture` before destroying the texture, or ImGui may sample
/// a dead handle.
pub fn registerTexture(handle_idx: u16) u64 {
    return imgui_bridge_register_texture(handle_idx);
}

/// Release a previously registered external texture. The underlying
/// texture is left untouched — only ImGui's mapping is dropped. Safe to
/// call with an unknown or already-released id.
pub fn unregisterTexture(tex_id: u64) void {
    imgui_bridge_unregister_texture(tex_id);
}
