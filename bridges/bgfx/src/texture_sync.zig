//! Honours ImGui 1.92's `ImTextureData` requests (the
//! `ImGuiBackendFlags_RendererHasTextures` path) against a GPU backend.
//!
//! Split out of `bridge.zig` so the request handling runs on the host in
//! `zig build test` against a real ImGui context and a counting fake GPU —
//! `bridge.zig` itself needs a live bgfx. The bridge instantiates `Sync`
//! with a thin bgfx wrapper; the test instantiates it with a recorder.
//!
//! ## Why the atlas is updated in place (labelle-imgui#28)
//!
//! `WantUpdates` used to be served by creating a whole new texture and
//! retiring the old one. ImGui 1.92 bakes glyphs lazily and queues a
//! `WantUpdates` whenever it rasterizes one, so a HUD whose text keeps
//! meeting new glyphs/sizes asks for updates often. Each request became a
//! full `createTexture2D` + `destroyTexture` that ping-ponged the atlas
//! between two table slots and gave it a new `TexID` every time.
//!
//! Now a texture is created once, MUTABLE (no initial memory), and every
//! `WantUpdates` uploads the rows holding the queued rectangles into the SAME handle, once.
//! The `TexID` stays stable; the only paths that create a texture are
//! `WantCreate` and an update for a texture we have no live slot for.
const std = @import("std");
const builtin = @import("builtin");
const ig = @import("cimgui");
const tex_table = @import("tex_table.zig");

pub const TextureTable = tex_table.TextureTable;

/// One upload: a band of FULL-WIDTH rows `y .. y + h` of the texture.
/// Full-width rows are contiguous in ImGui's buffer, so `pixels` is tightly
/// packed (`w * 4 * h` bytes) and the GPU side needs no row pitch — bgfx's
/// `UINT16_MAX` "compute from width" pitch works for any texture width
/// (a 16384-wide RGBA row is 65536 bytes, one more than a u16 pitch holds).
pub const Region = struct {
    y: u16,
    w: u16,
    h: u16,
    pixels: []const u8,
};

/// `Gpu` must provide:
///   fn create(self: *Gpu, w: u16, h: u16) ?u16          // mutable RGBA8, handle idx
///   fn upload(self: *Gpu, handle: u16, region: Region) void
///   fn destroy(self: *Gpu, handle: u16) void
pub fn Sync(comptime Gpu: type) type {
    return struct {
        gpu: *Gpu,
        table: *TextureTable,

        const Self = @This();

        /// Release a slot, destroying the texture only if we created it.
        pub fn releaseSlot(self: Self, slot: usize) void {
            const prev = self.table.release(slot) orelse return;
            if (prev.owned) self.gpu.destroy(prev.handle_idx);
        }

        /// Walk `draw_data.Textures[]` and honour every non-OK request.
        /// `invalidated`: the device was lost — every texture re-creates.
        pub fn process(self: Self, dd: *ig.ImDrawData, invalidated: bool) void {
            const tex_vec = dd.*.Textures orelse return;
            const count: usize = @intCast(tex_vec.*.Size);
            if (count == 0) return;
            const items: [*]*ig.ImTextureData = @ptrCast(tex_vec.*.Data);
            for (items[0..count]) |tex| {
                // After a surface loss ImGui still holds `Status == OK` and a
                // TexID for a slot the bridge just cleared; force a re-create
                // so ImGui's own pixels are re-uploaded to the new context.
                // A pending destroy (or an already destroyed texture) is left
                // alone: re-creating it would leak a texture ImGui is dropping.
                if (invalidated) {
                    ig.ImTextureData_SetTexID(tex, 0);
                    if (tex.*.Status == ig.ImTextureStatus_OK or tex.*.Status == ig.ImTextureStatus_WantUpdates)
                        ig.ImTextureData_SetStatus(tex, ig.ImTextureStatus_WantCreate);
                }
                switch (tex.*.Status) {
                    ig.ImTextureStatus_WantCreate => self.create(tex),
                    ig.ImTextureStatus_WantUpdates => self.update(tex),
                    ig.ImTextureStatus_WantDestroy => self.destroy(tex),
                    else => {},
                }
            }
        }

        fn create(self: Self, tex: *ig.ImTextureData) void {
            // ImGui only requests RGBA32 here (we didn't advertise Alpha8).
            const w: u16 = @intCast(tex.*.Width);
            const h: u16 = @intCast(tex.*.Height);
            const handle = self.gpu.create(w, h) orelse {
                logErr("imgui-bgfx: createTexture2D failed ({d}x{d})", .{ w, h });
                return; // status stays WantCreate: retried next frame
            };
            // First free DENSE slot, independent of the global bgfx idx.
            const tex_id = self.table.insert(handle, true) orelse {
                self.gpu.destroy(handle);
                logErr("imgui-bgfx: exceeded MAX_TEXTURES ({d})", .{tex_table.MAX_TEXTURES});
                return;
            };
            self.gpu.upload(handle, fullRegion(tex));
            ig.ImTextureData_SetTexID(tex, @intCast(tex_id));
            ig.ImTextureData_SetStatus(tex, ig.ImTextureStatus_OK);
        }

        fn update(self: Self, tex: *ig.ImTextureData) void {
            const id: u64 = @intCast(ig.ImTextureData_GetTexID(tex));
            const slot: ?usize = switch (self.table.lookup(id)) {
                .live => |s| if (self.table.owned[s]) s else null,
                .miss => null,
            };
            if (slot == null) {
                // No texture of ours to update (e.g. its create failed while
                // ImGui kept queueing updates): build it from the full pixels.
                ig.ImTextureData_SetTexID(tex, 0);
                return self.create(tex);
            }
            // ONE upload per request covering every queued rect: bgfx takes
            // at most one update per texture per frame, so uploading each
            // `Updates[]` rect separately could drop all but one.
            // `UpdateRect` is ImGui's bounding box of the queued rects.
            const r = tex.*.UpdateRect;
            const band = if (r.w == 0 or r.h == 0 or
                @as(u32, r.y) + r.h > @as(u32, @intCast(tex.*.Height)))
                fullRegion(tex)
            else
                rows(tex, r.y, r.h);
            self.gpu.upload(self.table.handles[slot.?], band);
            ig.ImTextureData_SetStatus(tex, ig.ImTextureStatus_OK);
        }

        fn destroy(self: Self, tex: *ig.ImTextureData) void {
            if (self.table.slotOf(@intCast(ig.ImTextureData_GetTexID(tex)))) |slot| self.releaseSlot(slot);
            ig.ImTextureData_SetTexID(tex, 0);
            ig.ImTextureData_SetStatus(tex, ig.ImTextureStatus_Destroyed);
        }
    };
}

fn fullRegion(tex: *ig.ImTextureData) Region {
    return rows(tex, 0, @intCast(tex.*.Height));
}

fn rows(tex: *ig.ImTextureData, y: u16, h: u16) Region {
    const pitch: usize = @as(usize, @intCast(tex.*.Width)) * @as(usize, @intCast(tex.*.BytesPerPixel));
    const base: [*]const u8 = @ptrCast(ig.ImTextureData_GetPixels(tex));
    const start = @as(usize, y) * pitch;
    return .{
        .y = y,
        .w = @intCast(tex.*.Width),
        .h = h,
        .pixels = base[start .. start + pitch * @as(usize, h)],
    };
}

/// The host test drives the failure paths on purpose, and the test runner
/// fails any test that logs at `.err`; production keeps the error log.
fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.log.err(fmt, args);
}
