//! Dense, generation-tagged slot table mapping ImGui `ImTextureID`s to bgfx
//! `TextureHandle.idx` values for the bgfx bridge.
//!
//! Pure Zig, no bgfx or cimgui import, so it is unit-testable on the host
//! (`zig build test`) without a GPU context. The bridge (`bridge.zig`) owns
//! the only GPU side effect — destroying handles it created — and does that
//! on the `Entry` this table hands back from `release`.
//!
//! ## Why a dense table
//!
//! bgfx allocates `TextureHandle.idx` from a GLOBAL pool (up to 4096). A
//! texture-heavy game can hand ImGui's font atlas an idx well above any small
//! array bound, so `handle.idx` must NOT be used as an array index. Instead we
//! keep our own dense table and store an encoded slot reference in ImGui's
//! `TexID`.
//!
//! ## Why generations (labelle-imgui#30)
//!
//! A slot-index-only id has no way to know its slot has been recycled. After
//! a device loss the bridge frees every slot; on the next frame it re-creates
//! its font atlas into the FIRST free slot — and the host's stale lend id, if
//! it pointed at that slot, silently resolved to the font atlas (or, when the
//! bridge's invalidate pass wasn't run, to whatever texture bgfx had given
//! the recycled idx). Nothing failed; the wrong pixels drew.
//!
//! Every slot now carries a generation that bumps each time the slot goes
//! live -> free. The generation is baked into the returned id, so an id
//! minted before a release can never match the slot's next occupant: it
//! decodes, fails the generation check, and resolves to "not registered".
//! The render path then skips the draw (and logs once) instead of sampling
//! another texture, and hosts can ask `isLive` to detect a dropped lend.
//!
//! ## Id layout (64-bit `ImTextureID`)
//!
//! ```text
//!   bits  0..15   slot + 1      (1 ..= MAX_TEXTURES; 0 keeps ImTextureID_Invalid)
//!   bits 16..47   generation    (u32, starts at 0 -> first-generation ids are
//!                                numerically identical to the pre-#30 ids)
//!   bits 48..63   must be zero  (anything else is rejected as garbage)
//! ```
//!
//! `MAX_TEXTURES` only needs to cover ImGui's *concurrent* textures (the font
//! atlas plus any host lends) — not the game's global texture count — so a
//! modest fixed table is plenty.

const std = @import("std");

/// Sentinel matching bgfx's `kInvalidHandle`.
pub const INVALID_HANDLE: u16 = std.math.maxInt(u16);

pub const MAX_TEXTURES: usize = 64;

const SLOT_BITS: u6 = 16;
const GEN_BITS: u6 = 32;
const SLOT_MASK: u64 = (1 << SLOT_BITS) - 1;
const GEN_MASK: u64 = (1 << GEN_BITS) - 1;

comptime {
    // Slot field must be able to hold MAX_TEXTURES (+1 offset).
    std.debug.assert(MAX_TEXTURES < SLOT_MASK);
}

/// What lived in a slot before it was released. `owned` tells the bridge
/// whether IT created the handle (and so must destroy it) or merely
/// borrowed it from the host.
pub const Entry = struct {
    handle_idx: u16,
    owned: bool,
};

/// Decoded fields of a well-formed id (not necessarily a live one).
pub const Decoded = struct {
    slot: usize,
    gen: u32,
};

/// Reason an id does not resolve — surfaced so the bridge can log a precise
/// one-shot diagnostic for a stale lend versus plain garbage.
pub const Miss = enum {
    /// `0`, out-of-range slot, or non-zero reserved bits.
    malformed,
    /// Well-formed, but the slot's generation moved on: the id was minted
    /// before a release (device-lost invalidate / unregister / destroy).
    stale,
    /// Well-formed and current generation, but the slot is empty. Only
    /// reachable through a bug (a slot freed without a bump), kept distinct
    /// so such a bug is visible rather than folded into `stale`.
    empty,
};

pub const TextureTable = struct {
    handles: [MAX_TEXTURES]u16 = [_]u16{INVALID_HANDLE} ** MAX_TEXTURES,
    owned: [MAX_TEXTURES]bool = [_]bool{false} ** MAX_TEXTURES,
    generation: [MAX_TEXTURES]u32 = [_]u32{0} ** MAX_TEXTURES,

    pub const empty: TextureTable = .{};

    // ── Id codec (pure) ────────────────────────────────────────────────

    /// Encode a dense slot index (0-based) + generation into an `ImTextureID`.
    pub fn encode(slot: usize, gen: u32) u64 {
        std.debug.assert(slot < MAX_TEXTURES);
        return (@as(u64, gen) << SLOT_BITS) | (@as(u64, @intCast(slot)) + 1);
    }

    /// Decode an id into its fields, or null when it is not one this table
    /// could have minted (0, slot out of range, reserved high bits set).
    pub fn decode(id: u64) ?Decoded {
        if (id == 0) return null;
        if ((id >> (SLOT_BITS + GEN_BITS)) != 0) return null;
        const slot_field = id & SLOT_MASK;
        if (slot_field == 0 or slot_field > MAX_TEXTURES) return null;
        return .{
            .slot = @intCast(slot_field - 1),
            .gen = @intCast((id >> SLOT_BITS) & GEN_MASK),
        };
    }

    // ── Table operations ───────────────────────────────────────────────

    /// First unused slot, or null when the table is full.
    pub fn findFreeSlot(self: *const TextureTable) ?usize {
        for (0..MAX_TEXTURES) |i| {
            if (self.handles[i] == INVALID_HANDLE) return i;
        }
        return null;
    }

    /// Occupy the first free slot with `handle_idx` and return its id (the
    /// slot's CURRENT generation). Null when the handle is invalid or the
    /// table is full.
    pub fn insert(self: *TextureTable, handle_idx: u16, owned: bool) ?u64 {
        if (handle_idx == INVALID_HANDLE) return null;
        const slot = self.findFreeSlot() orelse return null;
        self.handles[slot] = handle_idx;
        self.owned[slot] = owned;
        return encode(slot, self.generation[slot]);
    }

    /// Slot index for a LIVE id (well-formed, current generation, occupied),
    /// else null.
    pub fn slotOf(self: *const TextureTable, id: u64) ?usize {
        return switch (self.lookup(id)) {
            .live => |slot| slot,
            .miss => null,
        };
    }

    pub const Lookup = union(enum) {
        live: usize,
        miss: Miss,
    };

    /// Full classification of an id: the live slot, or why it does not
    /// resolve. The render path uses the `Miss` to log precisely.
    pub fn lookup(self: *const TextureTable, id: u64) Lookup {
        const d = decode(id) orelse return .{ .miss = .malformed };
        if (self.generation[d.slot] != d.gen) return .{ .miss = .stale };
        if (self.handles[d.slot] == INVALID_HANDLE) return .{ .miss = .empty };
        return .{ .live = d.slot };
    }

    /// The bgfx handle idx a live id maps to, or `INVALID_HANDLE`.
    pub fn resolve(self: *const TextureTable, id: u64) u16 {
        const slot = self.slotOf(id) orelse return INVALID_HANDLE;
        return self.handles[slot];
    }

    /// True while `id` still points at a live texture in this table. This
    /// is the host-facing "did my lend survive?" query.
    pub fn isLive(self: *const TextureTable, id: u64) bool {
        return self.slotOf(id) != null;
    }

    /// Whether the live id refers to a texture the bridge created (vs a host
    /// lend). Null for a non-live id.
    pub fn isOwned(self: *const TextureTable, id: u64) ?bool {
        const slot = self.slotOf(id) orelse return null;
        return self.owned[slot];
    }

    /// Free a slot. Returns what was there so the caller can destroy an owned
    /// handle; null if the slot was already free (no generation bump then —
    /// a free slot has no outstanding ids, so bumping would be pure churn).
    ///
    /// The bump on live -> free is the whole invariant: any id minted for
    /// the old occupant now fails `lookup` as `.stale`, and the NEXT
    /// occupant's id carries the new generation.
    pub fn release(self: *TextureTable, slot: usize) ?Entry {
        std.debug.assert(slot < MAX_TEXTURES);
        if (self.handles[slot] == INVALID_HANDLE) return null;
        const prev: Entry = .{ .handle_idx = self.handles[slot], .owned = self.owned[slot] };
        self.handles[slot] = INVALID_HANDLE;
        self.owned[slot] = false;
        self.generation[slot] +%= 1;
        return prev;
    }

    /// `release` addressed by id. A stale or malformed id is a no-op and
    /// returns null — crucially it can never free the slot's NEWER occupant.
    pub fn releaseId(self: *TextureTable, id: u64) ?Entry {
        const slot = self.slotOf(id) orelse return null;
        return self.release(slot);
    }

    /// Number of occupied slots (diagnostics / tests).
    pub fn liveCount(self: *const TextureTable) usize {
        var n: usize = 0;
        for (self.handles) |h| {
            if (h != INVALID_HANDLE) n += 1;
        }
        return n;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const T = TextureTable;

test "encode: first generation is numerically the legacy slot+1 id" {
    // Pre-#30 ids were `slot + 1`; generation 0 keeps that value so existing
    // logs / debugger habits still read the same on a fresh process.
    try testing.expectEqual(@as(u64, 1), T.encode(0, 0));
    try testing.expectEqual(@as(u64, 64), T.encode(63, 0));
}

test "encode/decode round-trip across slots and generations" {
    const gens = [_]u32{ 0, 1, 2, 1000, std.math.maxInt(u32) };
    for (0..MAX_TEXTURES) |slot| {
        for (gens) |gen| {
            const id = T.encode(slot, gen);
            try testing.expect(id != 0);
            const d = T.decode(id).?;
            try testing.expectEqual(slot, d.slot);
            try testing.expectEqual(gen, d.gen);
        }
    }
}

test "decode rejects 0, out-of-range slots and reserved high bits" {
    try testing.expectEqual(@as(?Decoded, null), T.decode(0));
    // slot field 65 (> MAX_TEXTURES)
    try testing.expectEqual(@as(?Decoded, null), T.decode(MAX_TEXTURES + 1));
    // slot field 0xFFFF
    try testing.expectEqual(@as(?Decoded, null), T.decode(0xFFFF));
    // valid slot, garbage above bit 48
    try testing.expectEqual(@as(?Decoded, null), T.decode((1 << 48) | 1));
    try testing.expectEqual(@as(?Decoded, null), T.decode(std.math.maxInt(u64)));
}

test "insert fills lowest free slot and refuses an invalid handle" {
    var t: T = .empty;
    try testing.expectEqual(@as(?u64, null), t.insert(INVALID_HANDLE, false));
    try testing.expectEqual(@as(usize, 0), t.liveCount());

    const a = t.insert(1234, false).?;
    const b = t.insert(7, true).?;
    try testing.expectEqual(@as(usize, 0), T.decode(a).?.slot);
    try testing.expectEqual(@as(usize, 1), T.decode(b).?.slot);
    try testing.expectEqual(@as(u16, 1234), t.resolve(a));
    try testing.expectEqual(@as(u16, 7), t.resolve(b));
    try testing.expectEqual(@as(?bool, false), t.isOwned(a));
    try testing.expectEqual(@as(?bool, true), t.isOwned(b));
    try testing.expectEqual(@as(usize, 2), t.liveCount());
}

test "insert returns null when the table is full" {
    var t: T = .empty;
    for (0..MAX_TEXTURES) |i| {
        try testing.expect(t.insert(@intCast(i + 1), false) != null);
    }
    try testing.expectEqual(@as(?u64, null), t.insert(9999, false));
    try testing.expectEqual(@as(usize, MAX_TEXTURES), t.liveCount());
}

test "release bumps the generation so the old id goes stale" {
    var t: T = .empty;
    const id = t.insert(42, false).?;
    try testing.expect(t.isLive(id));

    const prev = t.release(T.decode(id).?.slot).?;
    try testing.expectEqual(@as(u16, 42), prev.handle_idx);
    try testing.expect(!prev.owned);

    try testing.expect(!t.isLive(id));
    try testing.expectEqual(INVALID_HANDLE, t.resolve(id));
    try testing.expectEqual(T.Lookup{ .miss = .stale }, t.lookup(id));
    // Releasing an already-free slot is a no-op: no entry, no extra bump.
    try testing.expectEqual(@as(?Entry, null), t.release(0));
    try testing.expectEqual(@as(u32, 1), t.generation[0]);
}

test "the #30 scenario: host lend in slot 0, device-lost, font atlas recycles slot 0" {
    // Order of events on flying-platform: `initAtlas` runs inside drawGui,
    // BEFORE the first processTextures, so the host lend takes slot 0 and
    // the bridge's font atlas slot 1.
    var t: T = .empty;
    const host_lend = t.insert(300, false).?; // host atlas, bgfx idx 300
    const font_atlas = t.insert(301, true).?; // bridge font atlas
    try testing.expectEqual(@as(usize, 0), T.decode(host_lend).?.slot);
    try testing.expectEqual(@as(usize, 1), T.decode(font_atlas).?.slot);

    // Device lost: the bridge's invalidate pass frees EVERY slot.
    var owned_destroyed: usize = 0;
    for (0..MAX_TEXTURES) |i| {
        if (t.release(i)) |e| {
            if (e.owned) owned_destroyed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), owned_destroyed); // only the font atlas
    try testing.expectEqual(@as(usize, 0), t.liveCount());

    // Next frame: font atlas re-created into the FIRST free slot = slot 0,
    // the slot the host's stale id names. With slot-only ids the host would
    // now draw glyphs; with generations the stale id fails to resolve.
    const new_font = t.insert(17, true).?;
    try testing.expectEqual(@as(usize, 0), T.decode(new_font).?.slot);
    try testing.expect(new_font != host_lend);
    try testing.expect(t.isLive(new_font));
    try testing.expect(!t.isLive(host_lend));
    try testing.expectEqual(INVALID_HANDLE, t.resolve(host_lend));
    try testing.expectEqual(T.Lookup{ .miss = .stale }, t.lookup(host_lend));

    // A late `unregisterTexture(stale)` from the host must NOT free the
    // font atlas now living in that slot.
    try testing.expectEqual(@as(?Entry, null), t.releaseId(host_lend));
    try testing.expect(t.isLive(new_font));
    try testing.expectEqual(@as(u16, 17), t.resolve(new_font));

    // Host re-registers after restore: fresh id, new generation, and
    // distinct from both the stale id and the font atlas id.
    const relend = t.insert(302, false).?;
    try testing.expect(relend != host_lend);
    try testing.expect(relend != new_font);
    try testing.expect(t.isLive(relend));
    try testing.expectEqual(@as(u16, 302), t.resolve(relend));
}

test "generation survives many recycles and wraps without ever aliasing" {
    var t: T = .empty;
    var last: u64 = 0;
    // Pre-set the slot's generation near the u32 limit to exercise wrap.
    t.generation[0] = std.math.maxInt(u32) - 2;
    for (0..6) |_| {
        const id = t.insert(5, false).?;
        try testing.expectEqual(@as(usize, 0), T.decode(id).?.slot);
        try testing.expect(id != last);
        try testing.expect(t.isLive(id));
        if (last != 0) try testing.expect(!t.isLive(last));
        _ = t.release(0).?;
        last = id;
    }
}

test "lookup classifies malformed vs stale vs empty" {
    var t: T = .empty;
    try testing.expectEqual(T.Lookup{ .miss = .malformed }, t.lookup(0));
    try testing.expectEqual(T.Lookup{ .miss = .malformed }, t.lookup(1 << 50));

    const id = t.insert(9, false).?;
    try testing.expectEqual(T.Lookup{ .live = 0 }, t.lookup(id));
    _ = t.release(0);
    try testing.expectEqual(T.Lookup{ .miss = .stale }, t.lookup(id));

    // Current-generation id for an empty slot: only reachable by minting the
    // id by hand — a freed slot never hands one out.
    try testing.expectEqual(T.Lookup{ .miss = .empty }, t.lookup(T.encode(0, t.generation[0])));
}

test "releaseId on a stale id never touches the slot's newer occupant" {
    var t: T = .empty;
    const first = t.insert(1, false).?;
    _ = t.releaseId(first).?;
    const second = t.insert(2, false).?;
    try testing.expectEqual(@as(?Entry, null), t.releaseId(first));
    try testing.expectEqual(@as(u16, 2), t.resolve(second));
    // And the real owner can still release it.
    try testing.expectEqual(@as(u16, 2), t.releaseId(second).?.handle_idx);
    try testing.expect(!t.isLive(second));
}
