const std = @import("std");

/// Bridge between Dear ImGui (cimgui) and bgfx.
///
/// Compiles `src/bridge.zig` as a static library that exports the
/// `imgui_bridge_*` functions the generic adapter (`src/adapter.zig`)
/// calls, backed by a hand-rolled imgui render backend on top of bgfx
/// (the standard `imgui_impl_bgfx` pattern). Unlike the sokol bridge —
/// which wraps sokol's ready-made `simgui` — bgfx ships no packaged imgui
/// renderer, so `bridge.zig` implements the render path itself (own
/// shader program, vertex layout, sampler uniform, transient buffers).
///
/// Linking model (important): the bridge links its OWN `cimgui_clib`
/// (the imgui C++ + the cimgui C shim) so the `ig*` / `Im*` symbols
/// resolve. It does NOT link the bgfx C library — it only imports the
/// `zbgfx` *module* for the `bgfx.*` function declarations and types. The
/// actual `bgfx_*` C symbols are provided by the labelle-bgfx backend the
/// final game executable already links (the backend re-exports the bgfx
/// artifact). Linking bgfx here too would duplicate every bgfx symbol in
/// the game binary. Because the assembler stages this bridge's `zbgfx`
/// pin identically to the backend's pin (same hash), both resolve to the
/// same module, so the `extern` declarations match the linked artifact.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Android cross-compilation: mirror the sokol bridge — suppress system
    // library linking (the game .so owns those links) and force PIC end to
    // end (libgame.so absorbs this archive; ld.lld rejects non-PIC objects
    // inside a shared object). bgfx's own C libs are linked by the backend,
    // not here, so we don't need the NDK sysroot wiring the sokol bridge
    // does for sokol_clib — only cimgui's C++ compile needs it (below).
    const is_android = target.result.os.tag == .linux and
        (target.result.abi == .android or target.result.abi == .androideabi);

    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
    const cimgui_conf = @import("cimgui").getConfig(false);
    const cimgui_artifact = dep_cimgui.artifact(cimgui_conf.clib_name);

    const dep_zbgfx = b.dependency("zbgfx", .{
        .target = target,
        .optimize = optimize,
    });
    const zbgfx_mod = dep_zbgfx.module("zbgfx");

    // On Android, cimgui compiles C++ (imgui.h pulls in <assert.h> etc.)
    // which needs the NDK sysroot include paths Zig doesn't fully ship.
    // Mirror the sokol bridge's injection.
    if (is_android) {
        const ndk_sysroot = findAndroidNdkSysroot(b) orelse
            @panic("Android NDK not found. Set ANDROID_HOME or ANDROID_NDK_HOME.");
        const arch_triple: []const u8 = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-linux-android",
            .x86 => "i686-linux-android",
            .arm => "arm-linux-androideabi",
            else => "aarch64-linux-android",
        };
        const ndk_inc = b.pathJoin(&.{ ndk_sysroot, "usr/include" });
        const ndk_arch_inc = b.pathJoin(&.{ ndk_sysroot, "usr/include", arch_triple });
        cimgui_artifact.root_module.addSystemIncludePath(.{ .cwd_relative = ndk_inc });
        cimgui_artifact.root_module.addSystemIncludePath(.{ .cwd_relative = ndk_arch_inc });
        cimgui_artifact.root_module.pic = true;
    }

    // On Emscripten, the cimgui C++ compile (imgui.h pulls in <assert.h>,
    // <string.h>, <math.h>, etc.) cannot find libc headers because Zig does
    // not ship libc headers for `wasm32-emscripten` — they live in emsdk's
    // sysroot. Mirror the sokol bridge (`bridges/sokol/build.zig`) and
    // `labelle-assembler/backends/sokol/build.zig` (labelle-cli#197): plumb
    // the emsdk sysroot include path into the cimgui C compile artifact.
    // Gated on `.emscripten` so desktop / mobile builds remain untouched.
    // Unlike the sokol bridge, we link no bgfx C library here (the backend
    // owns that), so only cimgui_clib needs the include.
    //
    // The sokol bridge borrows sokol-zig's private `emSdkSetupStep` (chained
    // onto `sokol_clib`) to actually populate/activate the sysroot before the
    // C++ compile runs. This bridge has no sokol dependency, so we replicate
    // that one-time setup ourselves (`emSdkSetupStep` below runs `emsdk
    // install latest` + `emsdk activate latest`) and chain cimgui_clib onto
    // it, so `-isystem ...sysroot/include` points at a populated path by the
    // time `<assert.h>` is resolved. The setup is gated on the `.emscripten`
    // marker file, so when the emsdk cache is already activated (e.g. a prior
    // sokol-backend build in the same shared package cache) it's a no-op.
    if (target.result.os.tag == .emscripten) {
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            const emsdk_sysroot_inc = emsdk_dep.path("upstream/emscripten/cache/sysroot/include");
            cimgui_artifact.root_module.addSystemIncludePath(emsdk_sysroot_inc);
            if (emSdkSetupStep(b, emsdk_dep) catch @panic("emsdk setup failed")) |setup_step| {
                cimgui_artifact.step.dependOn(&setup_step.step);
            }
        }
    }

    const bridge_mod = b.addModule("mod_bgfx_imgui_bridge", .{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .pic = if (is_android) true else null,
    });
    bridge_mod.addImport("zbgfx", zbgfx_mod);
    bridge_mod.addImport("cimgui", dep_cimgui.module(cimgui_conf.module_name));
    // Link cimgui's C library so the imgui symbols resolve. The bgfx C
    // symbols are intentionally left undefined here (provided by the
    // backend at the final game-exe link) — see the module doc-comment.
    bridge_mod.linkLibrary(cimgui_artifact);

    const bridge_lib = b.addLibrary(.{
        .name = "bgfx_imgui_bridge",
        .root_module = bridge_mod,
        .linkage = .static,
    });
    b.installArtifact(bridge_lib);
}

/// Locate the Android NDK sysroot — ported verbatim from the sokol bridge
/// (kept in sync so the Android path behaves identically across bridges).
fn findAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const host_tag: []const u8 = switch (@import("builtin").os.tag) {
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };

    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        return b.pathJoin(&.{ ndk_home, "toolchains/llvm/prebuilt", host_tag, "sysroot" });
    }

    const android_home = b.graph.environ_map.get("ANDROID_HOME") orelse return null;
    const ndk_dir_path = b.pathJoin(&.{ android_home, "ndk" });
    var ndk_dir = std.Io.Dir.cwd().openDir(b.graph.io, ndk_dir_path, .{ .iterate = true }) catch return null;
    defer ndk_dir.close(b.graph.io);

    var latest: ?[]const u8 = null;
    var latest_major: u32 = 0;
    var iter = ndk_dir.iterate();
    while (iter.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse entry.name.len;
        const major = std.fmt.parseInt(u32, entry.name[0..dot], 10) catch 0;
        if (major > latest_major) {
            latest_major = major;
            latest = b.dupe(entry.name);
        }
    }

    const version = latest orelse return null;
    return b.pathJoin(&.{ android_home, "ndk", version, "toolchains/llvm/prebuilt", host_tag, "sysroot" });
}

// ── emsdk one-time setup (ported from sokol-zig) ───────────────────────
//
// Replicates sokol-zig's private `emSdkSetupStep` / `createEmsdkStep` /
// `fileExists` helpers verbatim so the bgfx bridge can populate + activate
// the emsdk sysroot without a sokol dependency. Kept byte-compatible with
// the sokol implementation (same `.emscripten` marker-file gate) so both
// bridges share the emsdk package cache without stepping on each other.

fn createEmsdkStep(b: *std.Build, emsdk: *std.Build.Dependency) *std.Build.Step.Run {
    if (@import("builtin").os.tag == .windows) {
        return b.addSystemCommand(&.{emsdk.path("emsdk.bat").getPath(b)});
    } else {
        const step = b.addSystemCommand(&.{"bash"});
        step.addArg(emsdk.path("emsdk").getPath(b));
        return step;
    }
}

fn fileExists(b: *std.Build, path: []const u8) !bool {
    return !std.meta.isError(std.Io.Dir.cwd().access(b.graph.io, path, .{}));
}

/// One-time setup of the Emscripten SDK (runs `emsdk install + activate`).
/// If the SDK had to be set up, a run step is returned that should be added
/// as a dependency of anything needing the sysroot; if the emsdk was already
/// set up (`.emscripten` marker present), null is returned.
fn emSdkSetupStep(b: *std.Build, emsdk: *std.Build.Dependency) !?*std.Build.Step.Run {
    const dot_emsc_path = emsdk.path(".emscripten").getPath(b);
    const dot_emsc_exists = try fileExists(b, dot_emsc_path);
    if (!dot_emsc_exists) {
        const emsdk_install = createEmsdkStep(b, emsdk);
        emsdk_install.addArgs(&.{ "install", "latest" });
        const emsdk_activate = createEmsdkStep(b, emsdk);
        emsdk_activate.addArgs(&.{ "activate", "latest" });
        emsdk_activate.step.dependOn(&emsdk_install.step);
        return emsdk_activate;
    } else {
        return null;
    }
}
