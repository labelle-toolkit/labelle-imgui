const std = @import("std");

/// Bridge between Dear ImGui (cimgui) and sokol via sokol_imgui.
///
/// Compiles bridge.zig as a static library that exports imgui_bridge_*
/// functions. Sokol is built with `with_sokol_imgui = true` so the
/// sokol_imgui integration is included in the C library.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    const cimgui_conf = @import("cimgui").getConfig(false);

    // Build sokol with imgui support enabled
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
    });

    // Inject the cimgui header search path into sokol's C library
    // so sokol_imgui can find the imgui headers.
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(
        dep_cimgui.path(cimgui_conf.include_dir),
    );

    const sokol_mod = dep_sokol.module("sokol");
    const sokol_artifact = dep_sokol.artifact("sokol_clib");
    const cimgui_artifact = dep_cimgui.artifact(cimgui_conf.clib_name);

    // Build bridge as static library
    const bridge_mod = b.addModule("mod_sokol_imgui_bridge", .{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_mod.addImport("sokol", sokol_mod);
    bridge_mod.linkLibrary(sokol_artifact);
    bridge_mod.linkLibrary(cimgui_artifact);

    const bridge_lib = b.addLibrary(.{
        .name = "sokol_imgui_bridge",
        .root_module = bridge_mod,
        .linkage = .static,
    });
    b.installArtifact(bridge_lib);
}
