//! Host test for `texture_sync.zig` (labelle-imgui#28): runs real ImGui
//! frames of a HUD-only UI against a counting fake GPU and asserts the font
//! atlas is created exactly once, never destroyed, keeps its TexID, and that
//! newly baked glyphs reach it as in-place sub-uploads.
const std = @import("std");
const ig = @import("cimgui");
const texture_sync = @import("texture_sync.zig");

const FakeGpu = struct {
    creates: usize = 0,
    destroys: usize = 0,
    uploads: usize = 0,
    /// Uploads that were not the full texture (i.e. WantUpdates rects).
    partial_uploads: usize = 0,
    next_handle: u16 = 7,
    fail_create: bool = false,
    /// Handles uploaded to during the current frame, and how often a
    /// handle got a second upload in one frame (must stay 0).
    frame_uploads: HandleSet = .{},
    double_uploads: usize = 0,
    last_w: u16 = 0,
    last_h: u16 = 0,

    pub fn create(self: *FakeGpu, w: u16, h: u16) ?u16 {
        if (self.fail_create) return null;
        self.creates += 1;
        self.last_w = w;
        self.last_h = h;
        defer self.next_handle += 1;
        return self.next_handle;
    }

    pub fn upload(self: *FakeGpu, handle: u16, r: texture_sync.Region) void {
        // bgfx takes one update per texture per frame (Codex on #43).
        if (self.frame_uploads.get(handle)) |_| self.double_uploads += 1;
        self.frame_uploads.put(handle) catch unreachable;
        self.uploads += 1;
        if (r.h != self.last_h) self.partial_uploads += 1;
        // Full-width rows, tightly packed.
        std.debug.assert(r.w == self.last_w);
        std.debug.assert(r.pixels.len == @as(usize, r.w) * 4 * r.h);
    }

    pub fn destroy(self: *FakeGpu, handle: u16) void {
        _ = handle;
        self.destroys += 1;
    }
};

const HandleSet = struct {
    items: [8]u16 = undefined,
    len: usize = 0,
    fn get(self: *const HandleSet, h: u16) ?void {
        for (self.items[0..self.len]) |x| if (x == h) return {};
        return null;
    }
    fn put(self: *HandleSet, h: u16) !void {
        if (self.len == self.items.len) return error.Full;
        self.items[self.len] = h;
        self.len += 1;
    }
};

const Sync = texture_sync.Sync(FakeGpu);

const Harness = struct {
    gpu: FakeGpu = .{},
    table: texture_sync.TextureTable = .empty,
    frame: usize = 0,

    fn init() void {
        _ = ig.igCreateContext(null);
        const io = ig.igGetIO();
        io.*.BackendFlags |= ig.ImGuiBackendFlags_RendererHasTextures;
        io.*.IniFilename = null;
        io.*.DisplaySize = .{ .x = 800, .y = 600 };
        io.*.DeltaTime = 1.0 / 60.0;
    }

    fn deinit() void {
        ig.igDestroyContext(null);
    }

    fn sync(self: *Harness) Sync {
        return .{ .gpu = &self.gpu, .table = &self.table };
    }

    /// One HUD frame: rectangles + text on the foreground draw list, no
    /// windows, no font pushes. `text` is what the HUD prints this frame.
    fn hudFrame(self: *Harness, text: [:0]const u8) void {
        self.gpu.frame_uploads = .{};
        ig.igNewFrame();
        const dl = ig.igGetForegroundDrawList();
        ig.ImDrawList_AddRectFilled(dl, .{ .x = 10, .y = 10 }, .{ .x = 200, .y = 40 }, 0x80000000);
        ig.ImDrawList_AddRect(dl, .{ .x = 10, .y = 10 }, .{ .x = 200, .y = 40 }, 0xffffffff);
        ig.ImDrawList_AddText(dl, .{ .x = 16, .y = 16 }, 0xffffffff, text.ptr);
        ig.igRender();
        const dd = ig.igGetDrawData() orelse unreachable;
        self.sync().process(dd, false);
        self.frame += 1;
    }

    fn fontTexId() u64 {
        const io = ig.igGetIO();
        const tex = io.*.Fonts.*.TexData;
        return @intCast(ig.ImTextureData_GetTexID(tex));
    }

    fn fontStatus() ig.ImTextureStatus {
        return ig.igGetIO().*.Fonts.*.TexData.*.Status;
    }
};

test "HUD-only frames create the font atlas exactly once (#28)" {
    Harness.init();
    defer Harness.deinit();
    var h: Harness = .{};

    h.hudFrame("HP 100");
    try std.testing.expectEqual(@as(usize, 1), h.gpu.creates);
    const id = Harness.fontTexId();
    try std.testing.expect(id != 0);
    try std.testing.expect(h.table.isLive(id));

    // A steady HUD: same text for many frames.
    for (0..30) |_| h.hudFrame("HP 100");
    try std.testing.expectEqual(@as(usize, 1), h.gpu.creates);
    try std.testing.expectEqual(@as(usize, 0), h.gpu.destroys);
    try std.testing.expectEqual(id, Harness.fontTexId());
    try std.testing.expectEqual(@as(usize, 1), h.table.liveCount());
    try std.testing.expectEqual(@as(ig.ImTextureStatus, ig.ImTextureStatus_OK), Harness.fontStatus());
}

test "new glyphs sub-upload into the same atlas texture, no re-create (#28)" {
    Harness.init();
    defer Harness.deinit();
    var h: Harness = .{};

    h.hudFrame("HP 100");
    for (0..5) |_| h.hudFrame("HP 100");
    const id = Harness.fontTexId();
    const uploads_before = h.gpu.uploads;

    // Glyphs never drawn before: ImGui bakes them and queues WantUpdates.
    h.hudFrame("QUEST: wyvern @ 42% {}");
    try std.testing.expect(h.gpu.partial_uploads > 0); // the WantUpdates path ran
    try std.testing.expectEqual(@as(usize, 0), h.gpu.double_uploads);
    try std.testing.expect(h.gpu.uploads > uploads_before);
    try std.testing.expectEqual(@as(usize, 1), h.gpu.creates);
    try std.testing.expectEqual(@as(usize, 0), h.gpu.destroys);
    try std.testing.expectEqual(id, Harness.fontTexId());
    try std.testing.expectEqual(@as(ig.ImTextureStatus, ig.ImTextureStatus_OK), Harness.fontStatus());

    // Once baked, the same text is steady: no further uploads at all.
    const uploads_after = h.gpu.uploads;
    for (0..10) |_| h.hudFrame("QUEST: wyvern @ 42% {}");
    try std.testing.expectEqual(uploads_after, h.gpu.uploads);
    try std.testing.expectEqual(@as(usize, 1), h.gpu.creates);
}

test "device loss re-creates the atlas once, then stays put" {
    Harness.init();
    defer Harness.deinit();
    var h: Harness = .{};

    for (0..3) |_| h.hudFrame("HP 100");
    // What `imgui_bridge_invalidate_textures` does: free every slot, then
    // the next frame's process runs with `invalidated = true`.
    for (0..@import("tex_table.zig").MAX_TEXTURES) |i| h.sync().releaseSlot(i);
    try std.testing.expectEqual(@as(usize, 1), h.gpu.destroys);

    ig.igNewFrame();
    ig.igRender();
    h.sync().process(ig.igGetDrawData() orelse unreachable, true);
    try std.testing.expectEqual(@as(usize, 2), h.gpu.creates);

    for (0..10) |_| h.hudFrame("HP 100");
    try std.testing.expectEqual(@as(usize, 2), h.gpu.creates);
    try std.testing.expectEqual(@as(usize, 1), h.gpu.destroys);
}

test "device loss does not re-create a texture ImGui is destroying" {
    Harness.init();
    defer Harness.deinit();
    var h: Harness = .{};

    h.hudFrame("HP 100");
    for (0..@import("tex_table.zig").MAX_TEXTURES) |i| h.sync().releaseSlot(i);
    ig.igNewFrame();
    ig.igRender();
    // A destroy ImGui queued for this frame (e.g. an atlas replaced by a
    // repack) must be acknowledged, not turned into a fresh texture.
    const tex = ig.igGetIO().*.Fonts.*.TexData;
    ig.ImTextureData_SetStatus(tex, ig.ImTextureStatus_WantDestroy);
    h.sync().process(ig.igGetDrawData() orelse unreachable, true);
    try std.testing.expectEqual(@as(usize, 1), h.gpu.creates);
    try std.testing.expectEqual(@as(usize, 0), Harness.fontTexId());
    try std.testing.expect(Harness.fontStatus() != ig.ImTextureStatus_WantDestroy);
}

test "a failed create is retried next frame, not re-created every frame after" {
    Harness.init();
    defer Harness.deinit();
    var h: Harness = .{};

    h.gpu.fail_create = true;
    h.hudFrame("HP 100");
    try std.testing.expectEqual(@as(usize, 0), h.gpu.creates);
    try std.testing.expectEqual(@as(usize, 0), Harness.fontTexId());

    h.gpu.fail_create = false;
    for (0..10) |_| h.hudFrame("HP 100");
    try std.testing.expectEqual(@as(usize, 1), h.gpu.creates);
    try std.testing.expectEqual(@as(usize, 0), h.gpu.destroys);
}
