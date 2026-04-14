const std = @import("std");

/// Bridge between Dear ImGui (cimgui) and sokol via sokol_imgui.
///
/// Unlike the raylib bridge (which compiles rlImGui.cpp into a static
/// library), sokol_imgui is part of sokol itself — it ships as
/// `simgui_*` functions inside `sokol_clib` when sokol is built with
/// `-Dwith_sokol_imgui=true`. This bridge therefore does NOT compile
/// or link sokol; it only emits a thin C wrapper that re-exports the
/// `imgui_bridge_*` symbol contract by calling `simgui_*` (which the
/// sokol backend's `sokol_clib` provides at the final exe link step).
///
/// The sokol dependency declared below is used purely to expose
/// sokol_gfx.h / sokol_app.h / sokol_imgui.h at compile time so the
/// bridge.c can see `simgui_desc_t` and friends. It must stay pinned
/// to the same commit as labelle-assembler/backends/sokol/build.zig.zon
/// so the struct layouts match the backend's compiled `sokol_clib`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{ .target = target, .optimize = optimize });

    const bridge_mod = b.addModule("mod_sokol_imgui_bridge", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    bridge_mod.addCSourceFile(.{
        .file = b.path("src/bridge.c"),
        .flags = &.{},
    });

    bridge_mod.addIncludePath(dep_sokol.path("src/sokol/c"));

    const bridge_clib = b.addLibrary(.{
        .name = "sokol_imgui_bridge",
        .root_module = bridge_mod,
        .linkage = .static,
    });
    b.installArtifact(bridge_clib);
}
