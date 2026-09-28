//! Where a bridge's wasm build takes emscripten from (labelle-imgui#37 for
//! the bgfx bridge, #39 for the sokol bridge; same as labelle-bgfx#159).
//! bridges/bgfx and bridges/sokol hold identical copies (CI `cmp`s them);
//! keep them in sync with labelle-bgfx's copy too.
//!
//! Two sources:
//!
//! - `.external`: `EMSDK` is set and names a valid, activated emsdk: it has
//!   `upstream/emscripten/<emcc>` (from `emsdk install`), `.emscripten` (the
//!   EM_CONFIG from `emsdk activate`) and, unless `-Demsdk_sysroot` overrides
//!   it, `upstream/emscripten/cache/sysroot/include` (the C/C++ compiles need
//!   it before emcc ever runs, so emcc's own cache setup comes too late).
//!   labelle-web 0.3's provider exports `EMSDK`, `EM_CONFIG` and PATH in
//!   exactly this shape. The sysroot headers (for cimgui's C++ compile) come
//!   from there, and the `emsdk` Zig package is neither fetched nor run: no
//!   `emsdk install/activate`, so no second ~1.5 GB download.
//! - `.package`: `EMSDK` is unset, empty or incomplete. The `emsdk` Zig
//!   package is used and, if it isn't activated yet, `emsdk install/activate
//!   latest` runs on it. This is the behavior before #37.
//!
//! std-only and pure (the filesystem is injected), so the decision runs as a
//! host unit test in `zig build test`. The injected `exists` must answer false
//! ONLY for a path that does not exist; any other I/O error (permissions, ...)
//! must be reported by the caller, not read as "missing", or the build would
//! silently fall back to installing the package emsdk.
const std = @import("std");

pub const Source = union(enum) {
    /// The `EMSDK` root (the env value, not copied).
    external: []const u8,
    package,
};

/// `-Demsdk_expect`: fail the build unless this source was chosen. CI uses it
/// to assert which path ran, not only that the build passed.
pub const Expect = enum { external, package };

pub const Options = struct {
    /// The host's emcc wrapper: `emcc`, or `emcc.bat` on Windows.
    emcc_name: []const u8,
    /// Require the default sysroot include dir. False when `-Demsdk_sysroot`
    /// supplies the sysroot instead.
    need_sysroot: bool = true,
};

/// Pick the source. `fs` is any value with `exists(path: []const u8) bool`.
pub fn resolve(gpa: std.mem.Allocator, env_emsdk: ?[]const u8, opts: Options, fs: anytype) Source {
    const root = env_emsdk orelse return .package;
    if (root.len == 0) return .package;
    const required = [_][]const []const u8{
        &.{".emscripten"},
        &.{ "upstream", "emscripten", opts.emcc_name },
        &sysroot_rel,
    };
    const n: usize = if (opts.need_sysroot) required.len else required.len - 1;
    for (required[0..n]) |rel| {
        const path = join(gpa, root, rel) catch return .package;
        defer gpa.free(path);
        if (!fs.exists(path)) return .package;
    }
    return .{ .external = root };
}

const sysroot_rel = [_][]const u8{ "upstream", "emscripten", "cache", "sysroot", "include" };

/// Null when `source` satisfies `expect` (or nothing is expected), else a
/// message saying which path ran instead.
pub fn mismatch(source: Source, expect: ?Expect) ?[]const u8 {
    const want = expect orelse return null;
    return switch (want) {
        .external => if (source == .external) null else "-Demsdk_expect=external, but the emsdk Zig package was chosen: EMSDK is unset, empty, or lacks .emscripten, upstream/emscripten/emcc or the sysroot include dir",
        .package => if (source == .package) null else "-Demsdk_expect=package, but a valid EMSDK was found and used instead of the emsdk Zig package",
    };
}

/// `<root>/upstream/emscripten/cache/sysroot/include`: the same sub-path the
/// package fallback uses.
pub fn sysrootInclude(gpa: std.mem.Allocator, root: []const u8) ![]u8 {
    return join(gpa, root, &sysroot_rel);
}

/// `<root>/upstream/emscripten/<tool>` (pass `emcc.bat` on Windows).
pub fn toolPath(gpa: std.mem.Allocator, root: []const u8, tool: []const u8) ![]u8 {
    return join(gpa, root, &.{ "upstream", "emscripten", tool });
}

fn join(gpa: std.mem.Allocator, root: []const u8, rel: []const []const u8) ![]u8 {
    var parts: [8][]const u8 = undefined;
    parts[0] = root;
    for (rel, 1..) |p, i| parts[i] = p;
    return std.fs.path.join(gpa, parts[0 .. rel.len + 1]);
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Fake filesystem: only the listed paths exist. Records every probe.
const FakeFs = struct {
    present: []const []const u8,
    probes: *usize,

    fn exists(self: @This(), path: []const u8) bool {
        self.probes.* += 1;
        for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

const unix_opts: Options = .{ .emcc_name = "emcc" };

/// The three required paths of a valid layout: .emscripten, emcc, sysroot.
fn validLayout(root: []const u8) ![3][]u8 {
    return .{
        try std.fs.path.join(testing.allocator, &.{ root, ".emscripten" }),
        try std.fs.path.join(testing.allocator, &.{ root, "upstream", "emscripten", "emcc" }),
        try std.fs.path.join(testing.allocator, &.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
    };
}

fn freeLayout(layout: [3][]u8) void {
    for (layout) |p| testing.allocator.free(p);
}

test "EMSDK unset: package, and the filesystem is not probed" {
    var probes: usize = 0;
    const src = resolve(testing.allocator, null, unix_opts, FakeFs{ .present = &.{}, .probes = &probes });
    try testing.expect(src == .package);
    try testing.expectEqual(@as(usize, 0), probes);
}

test "EMSDK empty: package (treated as unset)" {
    var probes: usize = 0;
    const src = resolve(testing.allocator, "", unix_opts, FakeFs{ .present = &.{}, .probes = &probes });
    try testing.expect(src == .package);
    try testing.expectEqual(@as(usize, 0), probes);
}

test "EMSDK valid (.emscripten + emcc + sysroot): external, root passed through" {
    const root = "/home/u/.cache/labelle-web/emsdk/v1/x86_64-linux/4.0.9-tag";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    var probes: usize = 0;
    const src = resolve(testing.allocator, root, unix_opts, FakeFs{ .present = &.{ layout[0], layout[1], layout[2] }, .probes = &probes });
    switch (src) {
        .external => |r| try testing.expectEqualStrings(root, r),
        .package => return error.TestExpectedExternal,
    }
    // Every required path was checked, not just one.
    try testing.expectEqual(@as(usize, 3), probes);
}

test "EMSDK missing any one required path: package" {
    const root = "/opt/emsdk";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    // Drop each required path in turn (not activated / not installed / no
    // sysroot): each alone must send the build to the package.
    for (0..3) |missing| {
        var present: [2][]const u8 = undefined;
        var n: usize = 0;
        for (layout, 0..) |p, i| if (i != missing) {
            present[n] = p;
            n += 1;
        };
        var probes: usize = 0;
        const src = resolve(testing.allocator, root, unix_opts, FakeFs{ .present = &present, .probes = &probes });
        try testing.expect(src == .package);
    }
}

test "EMSDK with only upstream/emscripten (no emcc for this host): package" {
    const root = "/opt/emsdk";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    const bare = try std.fs.path.join(testing.allocator, &.{ root, "upstream", "emscripten" });
    defer testing.allocator.free(bare);
    var probes: usize = 0;
    const win: Options = .{ .emcc_name = "emcc.bat" };
    // A Linux/macOS layout (emcc, no emcc.bat) is not valid for a Windows host.
    const src = resolve(testing.allocator, root, win, FakeFs{ .present = &.{ layout[0], layout[1], layout[2], bare }, .probes = &probes });
    try testing.expect(src == .package);
}

test "-Demsdk_sysroot override: the default sysroot dir is not required" {
    const root = "/opt/emsdk";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    var probes: usize = 0;
    const no_sysroot: Options = .{ .emcc_name = "emcc", .need_sysroot = false };
    const src = resolve(testing.allocator, root, no_sysroot, FakeFs{ .present = &.{ layout[0], layout[1] }, .probes = &probes });
    try testing.expect(src == .external);
    try testing.expectEqual(@as(usize, 2), probes);
    // ...while without the override the same layout falls back.
    try testing.expect(resolve(testing.allocator, root, unix_opts, FakeFs{ .present = &.{ layout[0], layout[1] }, .probes = &probes }) == .package);
}

test "mismatch: -Demsdk_expect gates the chosen source both ways" {
    try testing.expect(mismatch(.package, null) == null);
    try testing.expect(mismatch(.{ .external = "/e" }, null) == null);
    try testing.expect(mismatch(.{ .external = "/e" }, .external) == null);
    try testing.expect(mismatch(.package, .package) == null);
    try testing.expect(mismatch(.package, .external) != null);
    try testing.expect(mismatch(.{ .external = "/e" }, .package) != null);
}

test "sysrootInclude and toolPath sit under upstream/emscripten" {
    const inc = try sysrootInclude(testing.allocator, "/e");
    defer testing.allocator.free(inc);
    const want_inc = try std.fs.path.join(testing.allocator, &.{ "/e", "upstream", "emscripten", "cache", "sysroot", "include" });
    defer testing.allocator.free(want_inc);
    try testing.expectEqualStrings(want_inc, inc);

    const emcc = try toolPath(testing.allocator, "/e", "emcc");
    defer testing.allocator.free(emcc);
    const want_emcc = try std.fs.path.join(testing.allocator, &.{ "/e", "upstream", "emscripten", "emcc" });
    defer testing.allocator.free(want_emcc);
    try testing.expectEqualStrings(want_emcc, emcc);
}
