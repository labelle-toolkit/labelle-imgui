/// bgfx bridge for labelle-imgui — provides the four `extern` C functions
/// the generic adapter (`src/adapter.zig`) calls, backed by a hand-rolled
/// Dear ImGui render backend on top of bgfx (the standard
/// `imgui_impl_bgfx` pattern).
///
/// bgfx ships no packaged imgui renderer (unlike sokol's `simgui`), so this
/// file implements the render backend manually: it creates its OWN sprite
/// shader program, vertex layout, and `s_tex` sampler uniform (a ~30-line
/// duplication of the bgfx gfx backend's `programs.zig` — deliberately
/// kept self-contained so the bridge is a standalone module with no
/// cross-module coupling to the backend's private statics), then walks
/// ImGui's draw data each `imgui_bridge_end` and submits transient
/// vertex/index buffers on a dedicated bgfx view (200), rendered after the
/// game's view 0.
///
/// Vertex format note: the bgfx sprite vertex (`PosTexColorVertex`:
/// pos vec2 / uv vec2 / abgr u32, 20 bytes) is byte-identical to ImGui's
/// `ImDrawVert` (pos vec2 / uv vec2 / col IM_COL32 packed = ABGR on
/// little-endian), so draw-list vertices are copied straight into the
/// transient buffer with no per-vertex conversion.
///
/// Texture handling uses the modern 1.92 `ImGuiBackendFlags_RendererHasTextures`
/// path (mirrors sokol_imgui.h): each frame we walk `draw_data.Textures[]`
/// and honour WantCreate / WantUpdates / WantDestroy, storing our bgfx
/// `TextureHandle.idx` in the texture's `TexID`. The font atlas is created
/// this way on the first frame — no explicit `GetTexDataAsRGBA32` call.
///
/// INPUT forwarding (mouse → `io.AddMousePosEvent` etc.) is implemented via
/// the `imgui_bridge_mouse_pos` / `imgui_bridge_mouse_button` /
/// `imgui_bridge_mouse_wheel` externs at the bottom of this file. The
/// embedding backend (labelle-assembler's bgfx GLFW desktop / NDK Android
/// input layer) drives its per-frame mouse/touch state into them, matching
/// the contract the sokol bridge already exposes (and the headless-preview
/// input feed in labelle-assembler). Keyboard / text-input forwarding is a
/// follow-up — FP's UI is mouse/touch driven, so mouse pos + click + wheel
/// is the must-have that makes the overlay interactive.
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const shaders_data = @import("shaders.zig");
const ig = @import("cimgui");

// Separate-root-module panic override. This file is compiled as its own
// static-library root by `build.zig`, so the panic-handler override the
// assembler applies to the generated `main.zig` doesn't cover it.
// `std.debug.no_panic` is a tiny abort-on-panic stub (acceptable: a panic
// here already means a fatal bug), and keeping it in sync with the other
// bridges keeps the wasm/Android panic path consistent.
//
// NOTE: unlike the sokol bridge, we deliberately do NOT set
// `std_options_debug_io = std.Io.failing`. That override is a sokol-bridge
// wasm32-emscripten workaround (labelle-imgui#10) for `std.Io.Threaded`'s
// broken posix wrappers. On the bgfx desktop path it actively breaks the
// screenshot capture: bgfx's built-in default `screenShot` callback writes
// the `.tga`, and a "failing" debug-IO root makes that path panic at
// capture time (verified: the imgui window renders, then the program traps
// the moment a screenshot is requested). bgfx never needs the sokol
// workaround, so omit it.
pub const panic = std.debug.no_panic;

// ── bgfx render state ──────────────────────────────────────────────────

/// Dedicated view id for the imgui overlay. Higher than the game's view 0
/// so bgfx draws it after the scene (bgfx sorts views by id ascending).
const IMGUI_VIEW_ID: u16 = 200;

const INVALID: u16 = std.math.maxInt(u16);

var sprite_program: bgfx.ProgramHandle = .{ .idx = INVALID };
var s_tex_uniform: bgfx.UniformHandle = .{ .idx = INVALID };
var vertex_layout: bgfx.VertexLayout = undefined;
var initialized: bool = false;
/// Monotonic-clock timestamp (ns) of the previous `imgui_bridge_begin`,
/// used to derive the real per-frame `io.DeltaTime` (and hence
/// `io.Framerate`). Zero until the first frame establishes a baseline.
var last_frame_ns: i128 = 0;

// `std.time.nanoTimestamp` / `std.time.Instant` / `std.time.Timer` were all
// removed in Zig 0.16, so roll a small cross-platform monotonic clock.
// Each OS's externs live INSIDE its `comptime`-folded `switch` arm, so the
// other platform's symbols are never referenced — `clock_gettime` (libc)
// would otherwise fail to link a Windows game exe (Cursor Bugbot flagged
// this; `std.time.Timer` isn't available here to replace it). Only the
// `std.time.ns_per_s` constant survives the std.time strip.
const builtin = @import("builtin");
fn nowNs() i128 {
    switch (builtin.os.tag) {
        .windows => {
            const k32 = struct {
                extern "kernel32" fn QueryPerformanceCounter(c: *u64) callconv(.winapi) c_int;
                extern "kernel32" fn QueryPerformanceFrequency(f: *u64) callconv(.winapi) c_int;
            };
            var counter: u64 = 0;
            var freq: u64 = 0;
            _ = k32.QueryPerformanceCounter(&counter);
            _ = k32.QueryPerformanceFrequency(&freq);
            if (freq == 0) return 0;
            return @divTrunc(@as(i128, counter) * std.time.ns_per_s, @as(i128, freq));
        },
        else => {
            const Timespec = extern struct { sec: i64, nsec: i64 };
            const libc = struct {
                extern "c" fn clock_gettime(clk: c_int, tp: *Timespec) c_int;
            };
            const clk_id: c_int = switch (builtin.os.tag) {
                .macos, .ios, .watchos, .tvos => 6, // _CLOCK_MONOTONIC
                else => 1, // CLOCK_MONOTONIC (Linux/Android)
            };
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            if (libc.clock_gettime(clk_id, &ts) != 0) return 0;
            return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
        },
    }
}
/// Permanent give-up latch: set when render init can't succeed on a later
/// frame — an unsupported renderer (no embedded shader variant, D3D/etc.) OR
/// a hard shader/program creation failure on a supported renderer. Distinct
/// from "not initialized yet" (`.Noop`, bgfx not up): that retries. Without
/// this latch the per-frame lazy retry in `imgui_bridge_begin` would
/// re-attempt (and re-log) a doomed init every frame, forever.
var render_disabled: bool = false;

/// Alpha-blend state (matches the bgfx gfx backend's STATE_BLEND_ALPHA).
/// BGFX_STATE_BLEND_FUNC_SEPARATE(srcRGB,dstRGB,srcA,dstA) =
///   (srcRGB | (dstRGB<<4)) | ((srcA | (dstA<<4)) << 8)
fn blendAlpha() u64 {
    const src = bgfx.StateFlags_BlendSrcAlpha;
    const dst = bgfx.StateFlags_BlendInvSrcAlpha;
    return (src | (dst << 4)) | ((src | (dst << 4)) << 8);
}

fn isValid(idx: u16) bool {
    return idx != INVALID;
}

// ── Setup / teardown ───────────────────────────────────────────────────

export fn imgui_bridge_setup(dark_theme: bool) void {
    _ = ig.igCreateContext(null);
    const io = ig.igGetIO();

    // Modern texture path: we honour ImTextureData create/update/destroy
    // requests in imgui_bridge_end (see processTextures). VtxOffset lets us
    // render meshes >64K verts with 16-bit indices without splitting.
    io.*.BackendFlags |= ig.ImGuiBackendFlags_RendererHasTextures;
    io.*.BackendFlags |= ig.ImGuiBackendFlags_RendererHasVtxOffset;
    // No platform window/event loop is wired (input is a follow-up), so a
    // null ini filename avoids touching the filesystem.
    io.*.IniFilename = null;

    if (!dark_theme) {
        ig.igStyleColorsLight(null);
    } else {
        ig.igStyleColorsDark(null);
    }

    ensureRenderResources();
}

/// Lazily create the bgfx program, sampler uniform, and vertex layout.
/// Idempotent. Selects the precompiled shader variant by renderer type —
/// the same embedded sprite shaders the bgfx gfx backend uses (Metal /
/// SPIR-V / GLSL); their vertex layout is exactly PosTexColorVertex.
fn ensureRenderResources() void {
    if (initialized or render_disabled) return;

    // Select the precompiled shader variant by renderer. The embedded blobs
    // cover Metal (.mtl), Vulkan (SPIR-V), and GLSL. GLSL is also accepted by
    // OpenGL and OpenGL ES (the bridge's real desktop/Android targets), so
    // those fall through to the GLSL case.
    //
    // Renderers the embedded shaders do NOT cover (Direct3D 9/11/12, AGC,
    // GNM, NVN, WebGPU, Noop) would be fed incompatible bytecode by
    // createShader → an invalid program and silently-broken imgui. So we fail
    // LOUDLY and skip imgui rendering instead. D3D shader parity with the
    // bgfx backend's own shaders.zig (which has the same gap — no D3D
    // bytecode) is a separate follow-up; do not paper over it here.
    const renderer = bgfx.getRendererType();
    const vs_data: []const u8, const fs_data: []const u8 = switch (renderer) {
        .Metal => .{ &shaders_data.vs_sprite_mtl, &shaders_data.fs_sprite_mtl },
        .Vulkan => .{ &shaders_data.vs_sprite_spv, &shaders_data.fs_sprite_spv },
        .OpenGL, .OpenGLES => .{ &shaders_data.vs_sprite_glsl, &shaders_data.fs_sprite_glsl },
        // `.Noop` means bgfx isn't initialized yet (getRendererType before
        // bgfx.init). NOT an error — return silently so the lazy retry in
        // `imgui_bridge_begin` picks it up once the window backend has run
        // bgfx.init. This is the fix for "render init never retried": if
        // `setup` happened to run before bgfx.init, we'd otherwise never
        // build the program.
        .Noop => return,
        else => {
            std.log.err(
                "imgui-bgfx: renderer {} has no embedded shader variant; " ++
                    "imgui rendering disabled (D3D parity is a follow-up, see bridge.zig)",
                .{renderer},
            );
            render_disabled = true;
            return;
        },
    };

    const vs = bgfx.createShader(bgfx.makeRef(vs_data.ptr, @intCast(vs_data.len)));
    const fs = bgfx.createShader(bgfx.makeRef(fs_data.ptr, @intCast(fs_data.len)));
    if (!isValid(vs.idx) or !isValid(fs.idx)) {
        std.log.err("imgui-bgfx: failed to create shaders", .{});
        // Destroy whichever handle succeeded so repeated init attempts don't
        // leak bgfx shader handles.
        if (isValid(vs.idx)) bgfx.destroyShader(vs);
        if (isValid(fs.idx)) bgfx.destroyShader(fs);
        // Latch: the renderer is real (not `.Noop`) and the embedded
        // bytecode is fixed, so this won't succeed on a later frame — without
        // the latch the per-frame retry in `begin` would re-attempt (and
        // re-log) forever.
        render_disabled = true;
        return;
    }
    // createProgram(.., true) takes ownership of vs/fs and destroys them when
    // the program is destroyed — but ONLY if it succeeds. On failure the
    // handles are still ours to clean up.
    sprite_program = bgfx.createProgram(vs, fs, true);
    if (!isValid(sprite_program.idx)) {
        std.log.err("imgui-bgfx: failed to create program", .{});
        bgfx.destroyShader(vs);
        bgfx.destroyShader(fs);
        render_disabled = true; // permanent failure — don't retry forever
        return;
    }

    s_tex_uniform = bgfx.createUniform("s_tex", .Sampler, 1);

    // Layout matches the v1 sprite shader AND ImDrawVert:
    //   a_position  (vec2 float)
    //   a_texcoord0 (vec2 float)
    //   a_color0    (vec4 u8 normalized) — reads the abgr u32 byte-for-byte
    _ = vertex_layout.begin(.Noop);
    _ = vertex_layout.add(.Position, 2, .Float, false, false);
    _ = vertex_layout.add(.TexCoord0, 2, .Float, false, false);
    _ = vertex_layout.add(.Color0, 4, .Uint8, true, false);
    vertex_layout.end();

    initialized = true;
    std.log.info("imgui-bgfx: render resources ready (renderer: {})", .{bgfx.getRendererType()});
}

export fn imgui_bridge_shutdown() void {
    if (isValid(sprite_program.idx)) {
        bgfx.destroyProgram(sprite_program);
        sprite_program = .{ .idx = INVALID };
    }
    if (isValid(s_tex_uniform.idx)) {
        bgfx.destroyUniform(s_tex_uniform);
        s_tex_uniform = .{ .idx = INVALID };
    }
    destroyAllTextures();
    initialized = false;
    render_disabled = false;
    // Reset the frame-time baseline so a later re-init doesn't compute one
    // giant dt from the pre-shutdown timestamp (Cursor Bugbot, low sev).
    last_frame_ns = 0;
    ig.igDestroyContext(null);
}

// ── Frame begin ────────────────────────────────────────────────────────

/// Optional display-size override. The desktop frame loop can call this
/// each frame with the physical framebuffer size; if unset we fall back to
/// bgfx's backbuffer stats. Kept symmetric with the sokol bridge's
/// `imgui_bridge_set_dims` so embedders have a uniform escape hatch.
var override_w: i32 = 0;
var override_h: i32 = 0;

export fn imgui_bridge_set_dims(w: i32, h: i32, dpi: f32) void {
    _ = dpi;
    override_w = w;
    override_h = h;
}

// ── Input feed (mouse / touch) ─────────────────────────────────────────
//
// Thin wrappers that push the embedder's per-frame mouse/touch state into
// Dear ImGui's input queue. The bgfx backend (labelle-assembler) drives
// these from its single per-frame input pump (`backends/bgfx/src/input.zig`
// `newFrame`): GLFW cursor/buttons/scroll on desktop, the NDK touch pointer
// mapped onto mouse-button-0 on Android. The names + signatures match the
// sokol bridge's `imgui_bridge_mouse_pos` / `imgui_bridge_mouse_button`
// exactly so the assembler's codegen can emit one extern set for both
// backends (and so the headless-preview input feed keeps working).
//
// Coordinates are in the SAME physical-framebuffer pixel space the bridge
// renders in (`imgui_bridge_begin` sets `DisplaySize` to the framebuffer
// size with a 1:1 `DisplayFramebufferScale`), so the embedder must forward
// framebuffer-pixel coordinates — which the bgfx input layer already does
// (it scales GLFW's logical cursor pos to framebuffer pixels). No DPI
// conversion happens here.
//
// These are driven by the OS/backend event loop (GLFW callbacks on desktop,
// NDK AInputEvent on Android), which can fire during early init (before
// `imgui_bridge_setup` creates the context) or late shutdown (after
// `imgui_bridge_shutdown` destroys it). `igGetIO()` with no active context is
// UB, so each guards on `igGetCurrentContext()`.

export fn imgui_bridge_mouse_pos(x: f32, y: f32) void {
    if (ig.igGetCurrentContext() == null) return;
    const io = ig.igGetIO();
    ig.ImGuiIO_AddMousePosEvent(io, x, y);
}

export fn imgui_bridge_mouse_button(button: i32, down: bool) void {
    if (ig.igGetCurrentContext() == null) return;
    const io = ig.igGetIO();
    ig.ImGuiIO_AddMouseButtonEvent(io, button, down);
}

export fn imgui_bridge_mouse_wheel(wheel_x: f32, wheel_y: f32) void {
    if (ig.igGetCurrentContext() == null) return;
    const io = ig.igGetIO();
    ig.ImGuiIO_AddMouseWheelEvent(io, wheel_x, wheel_y);
}

// ── Keyboard input forwarding ──────────────────────────────────────────
// Text input (and edit-navigation: backspace/enter/arrows/…) needs BOTH
// character events (`AddInputCharacter`) AND key events (`AddKeyEvent`)
// forwarded to imgui. Mouse-only forwarding let you click but not type —
// e.g. the flying-platform save-name field ignored every key on bgfx. The
// host (bgfx backend `input.zig`) feeds these from the GLFW char + key
// callbacks. Keys arrive as raw GLFW keycodes and are translated to
// `ImGuiKey` here (the bridge owns cimgui), mirroring how the sokol bridge
// maps `sapp.Keycode` inline.

/// A typed character (Unicode codepoint) from the GLFW char callback.
/// Control chars are dropped (they belong to key events, not text).
export fn imgui_bridge_char(codepoint: u32) void {
    if (ig.igGetCurrentContext() == null) return;
    if (codepoint < 32 or codepoint == 127) return;
    const io = ig.igGetIO();
    ig.ImGuiIO_AddInputCharacter(io, codepoint);
}

/// A key down/up from the GLFW key callback (`key` is a raw GLFW keycode).
/// Forwarded so imgui sees Backspace/Enter/Delete/arrows/Home/End and the
/// Ctrl/Shift/Super modifiers (select-all, copy/paste, shift-select). An
/// unmapped key resolves to `ImGuiKey_None`, which imgui silently drops.
export fn imgui_bridge_key(key: i32, down: bool) void {
    if (ig.igGetCurrentContext() == null) return;
    const io = ig.igGetIO();
    ig.ImGuiIO_AddKeyEvent(io, glfwToImguiKey(key), down);
}

/// Raw GLFW keycode → `ImGuiKey`. Covers the text-editing + common keys; a
/// GLFW keycode with no imgui equivalent maps to `ImGuiKey_None`.
fn glfwToImguiKey(key: i32) ig.ImGuiKey {
    // Letters A–Z (GLFW 65..90) and digits 0–9 (GLFW 48..57) are dense
    // ranges in both encodings, so offset off the base ImGuiKey.
    if (key >= 65 and key <= 90) return @intCast(ig.ImGuiKey_A + (key - 65));
    if (key >= 48 and key <= 57) return @intCast(ig.ImGuiKey_0 + (key - 48));
    if (key >= 290 and key <= 301) return @intCast(ig.ImGuiKey_F1 + (key - 290)); // F1..F12
    return switch (key) {
        32 => ig.ImGuiKey_Space,
        39 => ig.ImGuiKey_Apostrophe,
        44 => ig.ImGuiKey_Comma,
        45 => ig.ImGuiKey_Minus,
        46 => ig.ImGuiKey_Period,
        47 => ig.ImGuiKey_Slash,
        59 => ig.ImGuiKey_Semicolon,
        61 => ig.ImGuiKey_Equal,
        91 => ig.ImGuiKey_LeftBracket,
        92 => ig.ImGuiKey_Backslash,
        93 => ig.ImGuiKey_RightBracket,
        96 => ig.ImGuiKey_GraveAccent,
        256 => ig.ImGuiKey_Escape,
        257 => ig.ImGuiKey_Enter,
        258 => ig.ImGuiKey_Tab,
        259 => ig.ImGuiKey_Backspace,
        260 => ig.ImGuiKey_Insert,
        261 => ig.ImGuiKey_Delete,
        262 => ig.ImGuiKey_RightArrow,
        263 => ig.ImGuiKey_LeftArrow,
        264 => ig.ImGuiKey_DownArrow,
        265 => ig.ImGuiKey_UpArrow,
        266 => ig.ImGuiKey_PageUp,
        267 => ig.ImGuiKey_PageDown,
        268 => ig.ImGuiKey_Home,
        269 => ig.ImGuiKey_End,
        280 => ig.ImGuiKey_CapsLock,
        340 => ig.ImGuiKey_LeftShift,
        341 => ig.ImGuiKey_LeftCtrl,
        342 => ig.ImGuiKey_LeftAlt,
        343 => ig.ImGuiKey_LeftSuper,
        344 => ig.ImGuiKey_RightShift,
        345 => ig.ImGuiKey_RightCtrl,
        346 => ig.ImGuiKey_RightAlt,
        347 => ig.ImGuiKey_RightSuper,
        else => ig.ImGuiKey_None,
    };
}

export fn imgui_bridge_begin() void {
    // Lazy retry: if `setup` ran before bgfx.init (renderer was `.Noop`),
    // the program wasn't built yet. Idempotent once `initialized`, and a
    // no-op once `render_disabled`, so this is cheap every frame.
    ensureRenderResources();

    const io = ig.igGetIO();

    var w = override_w;
    var h = override_h;
    if (w <= 0 or h <= 0) {
        // bgfx backbuffer size in physical pixels. Valid once bgfx.init has
        // run (the window backend inits bgfx before the game loop, so this
        // is always populated by the time the first frame begins).
        const stats = bgfx.getStats();
        w = @intCast(stats.*.width);
        h = @intCast(stats.*.height);
    }
    // ImGui asserts DisplaySize > 0; fall back to a sane canvas so a frame
    // before bgfx reports a size doesn't trip the assert (matches the sokol
    // bridge's defensive defaults).
    if (w <= 0) w = 800;
    if (h <= 0) h = 600;

    io.*.DisplaySize = .{ .x = @floatFromInt(w), .y = @floatFromInt(h) };
    // We render directly in framebuffer pixels (coords already physical), so
    // the framebuffer scale is 1:1 — DisplaySize is the physical size.
    io.*.DisplayFramebufferScale = .{ .x = 1.0, .y = 1.0 };
    // Feed imgui the REAL frame period (measured between consecutive
    // `begin` calls with a monotonic clock) so `io.Framerate` reflects the
    // actual present rate. Previously this was hardcoded to 1/60, which
    // pinned every imgui FPS readout to 60 on bgfx regardless of the true
    // rate (e.g. a 100 Hz vsync'd window, or an uncapped one) — making an
    // in-game FPS graph and the vsync toggle's effect invisible. The span
    // between `begin` calls includes the previous frame's present wait
    // (`bgfx.frame` in endDrawing), so it's the true frame period. Clamped
    // to (0, 1] s: ImGui asserts DeltaTime > 0, and a huge first/stall
    // delta would otherwise spike animations.
    var dt: f32 = 1.0 / 60.0;
    const now_ns = nowNs();
    if (now_ns != 0) {
        if (last_frame_ns != 0) {
            const elapsed = now_ns - last_frame_ns;
            if (elapsed > 0) {
                dt = @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, std.time.ns_per_s));
            }
        }
        // Only advance the baseline on a good reading — a transient clock
        // failure (nowNs == 0) must not zero it and lose the baseline
        // (Cursor Bugbot, low sev).
        last_frame_ns = now_ns;
    }
    if (dt <= 0) dt = 1.0 / 60.0;
    if (dt > 1.0) dt = 1.0;
    io.*.DeltaTime = dt;

    ig.igNewFrame();
}

// ── Frame end / render ─────────────────────────────────────────────────

export fn imgui_bridge_end() void {
    ig.igRender();
    const dd = ig.igGetDrawData() orelse return;
    if (!dd.*.Valid) return;

    // Honour texture create/update/destroy requests BEFORE the early-out on
    // an empty command list, otherwise a texture can get stuck in
    // WantCreate (mirrors the simgui ordering).
    processTextures(dd);

    if (dd.*.CmdListsCount <= 0) return;
    if (!isValid(sprite_program.idx)) return;

    const disp_w = dd.*.DisplaySize.x;
    const disp_h = dd.*.DisplaySize.y;
    if (disp_w <= 0 or disp_h <= 0) return;

    const fb_scale_x = dd.*.FramebufferScale.x;
    const fb_scale_y = dd.*.FramebufferScale.y;
    const fb_w: u16 = @intFromFloat(disp_w * fb_scale_x);
    const fb_h: u16 = @intFromFloat(disp_h * fb_scale_y);

    // Ortho projection: map (DisplayPos .. DisplayPos+DisplaySize) to clip
    // space. L=pos.x, R=pos.x+size.x, T=pos.y, B=pos.y+size.y so y grows
    // downward (ImGui's convention). View matrix is identity.
    const disp_x = dd.*.DisplayPos.x;
    const disp_y = dd.*.DisplayPos.y;
    const ortho = orthoMatrix(
        disp_x,
        disp_x + disp_w,
        disp_y + disp_h,
        disp_y,
    );
    const identity = [16]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    bgfx.setViewTransform(IMGUI_VIEW_ID, &identity, &ortho);
    bgfx.setViewRect(IMGUI_VIEW_ID, 0, 0, fb_w, fb_h);
    // No clear: the imgui overlay draws on top of view 0's already-rendered
    // scene. setViewMode sequential keeps draw order stable within the view.
    bgfx.setViewMode(IMGUI_VIEW_ID, .Sequential);

    const cmd_lists_count: usize = @intCast(dd.*.CmdListsCount);
    const cmd_lists: [*]*ig.ImDrawList = @ptrCast(dd.*.CmdLists.Data);

    var li: usize = 0;
    while (li < cmd_lists_count) : (li += 1) {
        renderDrawList(cmd_lists[li], disp_x, disp_y, fb_scale_x, fb_scale_y, fb_w, fb_h);
    }
}

fn renderDrawList(
    cl: *ig.ImDrawList,
    disp_x: f32,
    disp_y: f32,
    fb_scale_x: f32,
    fb_scale_y: f32,
    fb_w: u16,
    fb_h: u16,
) void {
    const vtx_count: u32 = @intCast(cl.*.VtxBuffer.Size);
    const idx_count: u32 = @intCast(cl.*.IdxBuffer.Size);
    if (vtx_count == 0 or idx_count == 0) return;

    // Transient index-buffer width flag. NOTE on the review thread that flagged
    // this: this zbgfx binding's parameter is `_index32` (bgfx >= the 1.92-era
    // rename), NOT the older `_index16` — i.e. its meaning is INVERTED. The
    // bgfx C header documents it as: "Set to `true` if input indices are
    // 32-bit." cimgui's imconfig.h leaves ImDrawIdx as the default
    // `unsigned short` (verified: @sizeOf(ig.ImDrawIdx) == 2), so our indices
    // are 16-bit and the correct flag is `false`. Passing `true` here requests
    // a 32-bit buffer and bgfx reads our 16-bit data two indices at a time →
    // garbled/blank geometry (verified empirically: `true` blanks the overlay,
    // `false` renders correctly). The flag is derived from @sizeOf so it stays
    // correct if cimgui is ever rebuilt with 32-bit indices.
    comptime std.debug.assert(@sizeOf(ig.ImDrawIdx) == 2 or @sizeOf(ig.ImDrawIdx) == 4);
    const index32: bool = @sizeOf(ig.ImDrawIdx) == 4;

    // bgfx requires the transient buffers fit the frame's transient budget;
    // skip the list if either can't be allocated (rare; degrades gracefully).
    if (bgfx.getAvailTransientVertexBuffer(vtx_count, &vertex_layout) < vtx_count) return;
    if (bgfx.getAvailTransientIndexBuffer(idx_count, index32) < idx_count) return;

    var tvb: bgfx.TransientVertexBuffer = undefined;
    var tib: bgfx.TransientIndexBuffer = undefined;
    bgfx.allocTransientVertexBuffer(&tvb, vtx_count, &vertex_layout);
    bgfx.allocTransientIndexBuffer(&tib, idx_count, index32); // matches ImDrawIdx width

    // ImDrawVert is byte-identical to PosTexColorVertex (20 bytes), so a raw
    // copy is correct — no per-vertex conversion.
    const src_vtx: [*]const u8 = @ptrCast(cl.*.VtxBuffer.Data);
    const dst_vtx: [*]u8 = @ptrCast(tvb.data);
    @memcpy(dst_vtx[0 .. vtx_count * @sizeOf(ig.ImDrawVert)], src_vtx[0 .. vtx_count * @sizeOf(ig.ImDrawVert)]);

    // ImDrawIdx is u16 (default), matching bgfx's 16-bit transient index buffer.
    const src_idx: [*]const u8 = @ptrCast(cl.*.IdxBuffer.Data);
    const dst_idx: [*]u8 = @ptrCast(tib.data);
    @memcpy(dst_idx[0 .. idx_count * @sizeOf(ig.ImDrawIdx)], src_idx[0 .. idx_count * @sizeOf(ig.ImDrawIdx)]);

    const cmd_count: usize = @intCast(cl.*.CmdBuffer.Size);
    const cmds: [*]ig.ImDrawCmd = @ptrCast(cl.*.CmdBuffer.Data);

    var ci: usize = 0;
    while (ci < cmd_count) : (ci += 1) {
        const cmd = &cmds[ci];

        // User callbacks: skip defensively. The render-state reset sentinel
        // is a no-op for us (we re-set all state per submit anyway); any
        // other callback is application-specific and not supported here.
        if (cmd.*.UserCallback != null) continue;

        if (cmd.*.ElemCount == 0) continue;

        // Scissor from clip rect, offset by DisplayPos and scaled to the
        // framebuffer. Clip rects can be negative (partially off-screen
        // windows) or extend past the framebuffer, so clamp each corner into
        // [0, fb_dim] BEFORE converting to int. Doing the @intFromFloat on raw
        // coords could panic, and computing w/h from unclamped negative
        // origins would over-expand the scissor.
        const fb_w_f: f32 = @floatFromInt(fb_w);
        const fb_h_f: f32 = @floatFromInt(fb_h);
        const clip_x = std.math.clamp((cmd.*.ClipRect.x - disp_x) * fb_scale_x, 0.0, fb_w_f);
        const clip_y = std.math.clamp((cmd.*.ClipRect.y - disp_y) * fb_scale_y, 0.0, fb_h_f);
        const clip_z = std.math.clamp((cmd.*.ClipRect.z - disp_x) * fb_scale_x, 0.0, fb_w_f);
        const clip_w = std.math.clamp((cmd.*.ClipRect.w - disp_y) * fb_scale_y, 0.0, fb_h_f);
        if (clip_z <= clip_x or clip_w <= clip_y) continue;

        const sx: u16 = @intFromFloat(clip_x);
        const sy: u16 = @intFromFloat(clip_y);
        const sw: u16 = @intFromFloat(clip_z - clip_x);
        const sh: u16 = @intFromFloat(clip_w - clip_y);
        _ = bgfx.setScissor(sx, sy, sw, sh);

        // Resolve the bgfx texture handle stored in this cmd's TexID.
        const tex_id = ig.ImDrawCmd_GetTexID(cmd);
        const tex_handle = bgfx.TextureHandle{ .idx = texIdToHandleIdx(tex_id) };
        if (!isValid(tex_handle.idx)) continue;
        bgfx.setTexture(0, s_tex_uniform, tex_handle, 0);

        bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | blendAlpha(), 0);

        // VtxOffset selects the base vertex; IdxOffset/ElemCount the index
        // range. bgfx's setTransient*Buffer takes (start, count).
        bgfx.setTransientVertexBuffer(0, &tvb, cmd.*.VtxOffset, vtx_count - cmd.*.VtxOffset);
        bgfx.setTransientIndexBuffer(&tib, cmd.*.IdxOffset, cmd.*.ElemCount);

        bgfx.submit(IMGUI_VIEW_ID, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
    }
}

/// Right-handed orthographic projection (z 0..1), row-major as bgfx expects.
/// Maps x∈[l,r]→[-1,1], y∈[b,t]→[-1,1]. For an ImGui overlay we pass
/// b=DisplayPos.y+h, t=DisplayPos.y so screen-y grows downward.
fn orthoMatrix(l: f32, r: f32, b: f32, t: f32) [16]f32 {
    const near: f32 = 0.0;
    const far: f32 = 1.0;
    var m = [16]f32{
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
    };
    m[0] = 2.0 / (r - l);
    m[5] = 2.0 / (t - b);
    m[10] = 1.0 / (far - near);
    m[12] = (l + r) / (l - r);
    m[13] = (t + b) / (b - t);
    m[14] = near / (near - far);
    m[15] = 1.0;
    return m;
}

// ── Texture management (RendererHasTextures path) ──────────────────────

/// Dense slot map of the bgfx handles we created for ImGui textures.
///
/// CRITICAL: bgfx allocates `TextureHandle.idx` from a GLOBAL pool (up to
/// 4096). A texture-heavy game (e.g. flying-platform with 6+ atlases) can
/// hand ImGui's font texture a handle idx well above any small array bound,
/// so we must NOT use `handle.idx` as an array index. Instead we maintain our
/// own dense, sequential slot table: on create we append the bgfx handle to
/// the first free `imgui_textures` slot and store `(slot + 1)` in ImGui's
/// `TexID`; on lookup we recover the slot via `TexID - 1` and read the real
/// bgfx handle out of the table; on update/destroy we invalidate that slot.
/// `TexID == 0` stays "invalid" (matches ImTextureID_Invalid).
///
/// MAX_TEXTURES only needs to cover ImGui's *concurrent* textures (the font
/// atlas plus any user-supplied textures) — not the game's global texture
/// count — so a modest fixed table is plenty.
const MAX_TEXTURES = 64;
var imgui_textures: [MAX_TEXTURES]bgfx.TextureHandle =
    [_]bgfx.TextureHandle{.{ .idx = INVALID }} ** MAX_TEXTURES;

/// Map a dense slot index (0-based) to the ImGui TexID stored in draw data.
fn slotToTexId(slot: usize) ig.ImTextureID {
    // +1 so slot 0 never maps to ImTextureID 0 (the "invalid" sentinel).
    return @as(ig.ImTextureID, @intCast(slot)) + 1;
}

/// Recover the dense slot index from an ImGui TexID, or null if invalid /
/// out of range.
fn texIdToSlot(tex_id: ig.ImTextureID) ?usize {
    if (tex_id == 0) return null;
    const slot: usize = @intCast(tex_id - 1);
    if (slot >= MAX_TEXTURES) return null;
    return slot;
}

/// Resolve the bgfx texture handle a draw command references via its TexID.
/// Returns INVALID if the slot is empty/out of range.
fn texIdToHandleIdx(tex_id: ig.ImTextureID) u16 {
    const slot = texIdToSlot(tex_id) orelse return INVALID;
    return imgui_textures[slot].idx;
}

fn processTextures(dd: *ig.ImDrawData) void {
    const tex_vec = dd.*.Textures orelse return;
    const count: usize = @intCast(tex_vec.*.Size);
    const items: [*]*ig.ImTextureData = @ptrCast(tex_vec.*.Data);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const tex = items[i];
        if (tex.*.Status != ig.ImTextureStatus_OK) {
            updateTexture(tex);
        }
    }
}

fn updateTexture(tex: *ig.ImTextureData) void {
    switch (tex.*.Status) {
        ig.ImTextureStatus_WantCreate => createTexture(tex),
        ig.ImTextureStatus_WantUpdates => updateTexturePixels(tex),
        ig.ImTextureStatus_WantDestroy => destroyTexture(tex),
        else => {},
    }
}

fn createTexture(tex: *ig.ImTextureData) void {
    // ImGui only ever requests RGBA32 here (we didn't advertise Alpha8).
    const w: u16 = @intCast(tex.*.Width);
    const h: u16 = @intCast(tex.*.Height);
    const pixels = ig.ImTextureData_GetPixels(tex);
    const size: u32 = @intCast(ig.ImTextureData_GetSizeInBytes(tex));

    // bgfx.copy takes its own copy into the command queue, so the ImGui
    // pixel buffer can be freed/reused after this returns.
    const mem = bgfx.copy(pixels, size);
    const handle = bgfx.createTexture2D(
        w,
        h,
        false,
        1,
        .RGBA8,
        bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
        mem,
        0,
    );
    if (!isValid(handle.idx)) {
        std.log.err("imgui-bgfx: createTexture2D failed ({d}x{d})", .{ w, h });
        return;
    }

    // Find the first free DENSE slot — independent of the bgfx handle idx,
    // which may be any value from the global pool.
    var slot: ?usize = null;
    for (0..MAX_TEXTURES) |i| {
        if (!isValid(imgui_textures[i].idx)) {
            slot = i;
            break;
        }
    }
    if (slot == null) {
        // Out of dense slots — destroy and bail rather than corrupt the map.
        bgfx.destroyTexture(handle);
        std.log.err("imgui-bgfx: exceeded MAX_TEXTURES ({d})", .{MAX_TEXTURES});
        return;
    }
    imgui_textures[slot.?] = handle;
    ig.ImTextureData_SetTexID(tex, slotToTexId(slot.?));
    ig.ImTextureData_SetStatus(tex, ig.ImTextureStatus_OK);
}

fn updateTexturePixels(tex: *ig.ImTextureData) void {
    // We didn't request partial updates with a dynamic texture, so the
    // simplest correct path is to recreate the full texture from the current
    // pixels. Font-atlas updates are rare (DPI/scale change, glyph reload),
    // so the cost is negligible for the MVP. A dynamic-texture + sub-rect
    // updateTexture2D path is a possible optimization follow-up.
    //
    // CREATE FIRST, retire the old texture only on success. `createTexture`
    // resolves a *different* free slot and writes a fresh TexID on success,
    // and leaves TexID/status UNTOUCHED on failure — so a transient
    // createTexture2D failure can't blank the atlas (the old texture stays
    // bound). Destroying the old handle up front would lose it on failure.
    const old_slot = texIdToSlot(ig.ImTextureData_GetTexID(tex));
    const old_texid = ig.ImTextureData_GetTexID(tex);

    createTexture(tex);

    // A fresh TexID + OK status means the replacement is live; retire the old.
    if (tex.*.Status == ig.ImTextureStatus_OK and
        ig.ImTextureData_GetTexID(tex) != old_texid)
    {
        if (old_slot) |slot| {
            if (isValid(imgui_textures[slot].idx)) {
                bgfx.destroyTexture(imgui_textures[slot]);
                imgui_textures[slot] = .{ .idx = INVALID };
            }
        }
    }
    // else: create failed — old texture + slot + TexID left intact.
}

fn destroyTexture(tex: *ig.ImTextureData) void {
    if (texIdToSlot(ig.ImTextureData_GetTexID(tex))) |slot| {
        if (isValid(imgui_textures[slot].idx)) {
            bgfx.destroyTexture(imgui_textures[slot]);
            imgui_textures[slot] = .{ .idx = INVALID };
        }
    }
    ig.ImTextureData_SetTexID(tex, 0);
    ig.ImTextureData_SetStatus(tex, ig.ImTextureStatus_Destroyed);
}

fn destroyAllTextures() void {
    for (0..MAX_TEXTURES) |i| {
        if (isValid(imgui_textures[i].idx)) {
            bgfx.destroyTexture(imgui_textures[i]);
            imgui_textures[i] = .{ .idx = INVALID };
        }
    }
}
