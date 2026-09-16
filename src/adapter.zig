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
extern fn imgui_bridge_texture_registered(tex_id: u64) bool;
extern fn imgui_bridge_display_scale() f32;

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

/// The factor to multiply HUD/menu metrics by so a control renders at a
/// consistent PHYSICAL size on every device, instead of keying off pixel
/// counts (which mis-size across DPIs). Always > 0.
///
/// THE CONTRACT IS "what callers multiply by", not "what the display's
/// density is" — the two differ per bridge, because the bridges do not all
/// hand ImGui the same coordinate space:
///
///   * bgfx — `DisplaySize` is the PHYSICAL framebuffer with a 1:1
///     `DisplayFramebufferScale`, so the density is NOT yet applied and this
///     returns it (desktop content scale, Android density/160, browser
///     devicePixelRatio). Callers multiply.
///   * sokol — sokol_imgui converts the framebuffer to LOGICAL units via
///     `newFrame(.dpi_scale)`, so metrics arrive already normalised and this
///     returns 1.0. Multiplying again made controls DPI times too large
///     (Codex P1 on #32).
///   * raylib — rlImGui exposes no DPI here, so this returns 1.0 and UI
///     renders 1:1, exactly as before the factor existed.
///
/// A caller writes the same code on all three and gets the right physical
/// size; only the number differs.
pub fn displayScale() f32 {
    const s = imgui_bridge_display_scale();
    return if (s > 0) s else 1.0;
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
//
// ## Lifetime contract — lends do NOT survive device loss
//
// A registered id is valid only for the life of the current GPU device.
// On Android the surface (and with it every bgfx texture) dies on
// background/resume; the bridge frees its whole texture table in its
// device-lost pass and re-uploads only the textures IT owns (the font
// atlas). It cannot re-lend yours. The host owns both ends:
//
//   engine__surface_lost      -> `unregisterTexture(id)`, then free your
//                                texture (the event is synchronous since
//                                labelle-engine 2.13.0 — labelle-engine#820
//                                / #823 — so the handle is still alive and
//                                the bridge's invalidate has not yet run);
//   engine__surface_restored  -> re-upload, `registerTexture(new_handle)`,
//                                and draw with the NEW id from then on.
//
// Ids are generation-tagged (labelle-imgui#30): an id minted before a
// device loss no longer matches its slot afterwards, so drawing with it
// draws NOTHING (the bridge logs once per stale id) instead of sampling
// whichever texture now occupies the slot, and `isTextureRegistered(id)`
// returns false — use it as a cheap per-frame probe for "my lend was
// dropped, re-register" in place of an ad-hoc latch reset.

/// Register a renderer-native texture handle and get an `ImTextureID` for
/// it. Returns 0 when the handle is invalid, the table is full, or the
/// active bridge does not support external textures.
///
/// This is a **borrow**: the caller keeps ownership and must call
/// `unregisterTexture` before destroying the texture, or ImGui may sample
/// a dead handle. The borrow ends with the GPU device — see the lifetime
/// contract above; after a device loss you hold a stale id and must
/// register again.
pub fn registerTexture(handle_idx: u16) u64 {
    return imgui_bridge_register_texture(handle_idx);
}

/// Release a previously registered external texture. The underlying
/// texture is left untouched — only ImGui's mapping is dropped. Safe to
/// call with an unknown, stale, or already-released id: a stale id can
/// never release whatever texture has since taken its slot.
pub fn unregisterTexture(tex_id: u64) void {
    imgui_bridge_unregister_texture(tex_id);
}

/// Whether `tex_id` still resolves to a live texture in the active bridge.
///
/// False for 0, for an id released by `unregisterTexture`, and for an id
/// whose slot was dropped by the bridge's device-lost pass — even if the
/// slot has been re-occupied since. Pure table lookup (no renderer call),
/// so it is cheap enough to ask every frame before drawing. Bridges
/// without external-texture support always return false.
pub fn isTextureRegistered(tex_id: u64) bool {
    return imgui_bridge_texture_registered(tex_id);
}
