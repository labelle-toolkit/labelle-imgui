const std = @import("std");
const cimgui = @import("cimgui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });

    const cimgui_conf = cimgui.getConfig(false);
    const cimgui_mod = dep_cimgui.module(cimgui_conf.module_name);

    // GUI adapter module — satisfies GuiInterface contract.
    // Does NOT depend on any backend. The bridge wires the backend connection.
    const gui_mod = b.addModule("labelle_imgui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("cimgui", cimgui_mod);

    // Re-export cimgui artifact so it can be linked into the final executable
    const cimgui_artifact = dep_cimgui.artifact(cimgui_conf.clib_name);
    b.installArtifact(cimgui_artifact);

    // ── Unit tests ─────────────────────────────────────────────────────
    // The adapter is a thin extern shim with nothing to test headless. The
    // bgfx bridge's texture slot table (`bridges/bgfx/src/tex_table.zig`)
    // is pure Zig — no zbgfx/cimgui import — so it runs from the repo root
    // too, without pulling the bridge's own dependency tree. Kept in sync
    // with `bridges/bgfx/build.zig`'s `test` step (same file, same tests).
    const host_target = b.resolveTargetQuery(.{});
    const tex_table_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("bridges/bgfx/src/tex_table.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run labelle-imgui unit tests");
    test_step.dependOn(&b.addRunArtifact(tex_table_tests).step);
}
