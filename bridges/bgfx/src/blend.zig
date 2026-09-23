//! The bridge's blend state, kept free of the bgfx/cimgui link so it is
//! unit-testable on the host (`zig build test`): it takes the bgfx binding
//! namespace as a comptime parameter instead of importing it.

/// Straight-alpha "over" (matches labelle-bgfx's `STATE_BLEND_ALPHA`): colour
/// blends by the source alpha; the ALPHA channel composites as coverage
/// (`One, InvSrcAlpha`), so imgui drawn over an opaque frame leaves it opaque.
///
/// Alpha used to blend like colour (`SrcAlpha, InvSrcAlpha` -> srcA² + ...),
/// leaving translucent panels with framebuffer alpha < 1. The web canvas has an
/// alpha channel (premultipliedAlpha: false), so the page behind the canvas
/// showed through every translucent imgui panel (menus, HUD bars). Colour is
/// unchanged, so desktop/Android pixels are identical.
///
/// BGFX_STATE_BLEND_FUNC_SEPARATE(srcRGB,dstRGB,srcA,dstA) =
///   (srcRGB | (dstRGB<<4)) | ((srcA | (dstA<<4)) << 8)
pub fn alphaOver(comptime B: type) u64 {
    const src_rgb: u64 = B.StateFlags_BlendSrcAlpha;
    const dst_rgb: u64 = B.StateFlags_BlendInvSrcAlpha;
    const src_a: u64 = B.StateFlags_BlendOne;
    const dst_a: u64 = B.StateFlags_BlendInvSrcAlpha;
    return (src_rgb | (dst_rgb << 4)) | ((src_a | (dst_a << 4)) << 8);
}

test "alphaOver composites alpha as coverage, not srcA² (web canvas stays opaque)" {
    const std = @import("std");
    // bgfx's own values (bindings/zig/bgfx.zig).
    const B = struct {
        const StateFlags_BlendShift: u64 = 12;
        const StateFlags_BlendOne: u64 = 0x2000;
        const StateFlags_BlendSrcAlpha: u64 = 0x5000;
        const StateFlags_BlendInvSrcAlpha: u64 = 0x6000;
    };
    const state = alphaOver(B);
    const rgb = (state >> B.StateFlags_BlendShift) & 0xff;
    const alpha = (state >> (B.StateFlags_BlendShift + 8)) & 0xff;
    try std.testing.expectEqual(@as(u64, 0x65), rgb); // SrcAlpha, InvSrcAlpha
    try std.testing.expectEqual(@as(u64, 0x62), alpha); // One, InvSrcAlpha
}
