const std = @import("std");
// Which emsdk a wasm build uses (external EMSDK vs the emsdk package, #39).
const emsdk_source = @import("emsdk_source.zig");
// Takes sokol-zig's own emsdk setup + sysroot off sokol_clib (#39, #41).
const sokol_emsdk_setup = @import("sokol_emsdk_setup.zig");

/// Bridge between Dear ImGui (cimgui) and sokol via sokol_imgui.
///
/// Compiles bridge.zig as a static library that exports imgui_bridge_*
/// functions. Sokol is built with `with_sokol_imgui = true` so the
/// sokol_imgui integration is included in the C library.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Android cross-compilation: sokol must not attempt to link system libs
    // (GLESv3/EGL/android/log) because the NDK library paths are only known
    // to the top-level game build. The game .so handles those links.
    // Note: std.Target.isAndroid() is not available in build.zig in Zig 0.15;
    // check the ABI directly (.android = arm64/x86_64, .androideabi = arm/x86).
    const is_android = target.result.os.tag == .linux and
        (target.result.abi == .android or target.result.abi == .androideabi);

    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    const cimgui_conf = @import("cimgui").getConfig(false);

    // Build sokol with imgui support enabled.
    // On Android, suppress automatic system-library linking — the final .so
    // already links android/log/GLESv3/EGL via its own root_module.
    //
    // labelle-assembler#140: compile sokol_imgui with SOKOL_IMGUI_NO_SOKOL_APP
    // defined so headless preview mode (no sokol_app, no NSWindow) can drive
    // simgui by injecting width/height/dpi_scale into simgui_new_frame.
    // Backward compatible — keyboard/mouse-cursor hooks that the flag
    // disables are unused in the windowed path anyway (the gui adapter
    // doesn't call them). Requires the `with_sokol_imgui_no_app` option
    // in sokol-zig's build.zig — provided by the `labelle-toolkit/sokol-zig`
    // fork branch `feat/with-sokol-imgui-no-app` that this repo pins (see
    // `build.zig.zon` and `patches/sokol-zig-no-sokol-app.diff`).
    //
    // The option set here MUST stay symmetric with
    // labelle-assembler `backends/sokol/build.zig` — Zig keys
    // `b.dependency("sokol", .{...})` by its option struct, so a mismatch
    // produces *two* separately compiled `sokol_clib` artifacts in the
    // same binary, which manifests as `cimgui.h file not found` when only
    // one of the two artifacts has the cimgui include path injected.
    //
    // Android skips `with_sokol_imgui_no_app` because the device runs
    // sokol_app natively via ANativeActivity — there's no headless preview
    // path on-device — and historically the Android sokol-zig fetch was a
    // separate pin without the patch (`labelle-assembler#146`). Symmetric
    // option sets per-target (this branch + `labelle_sokol`'s) keep the
    // single-`_sg`-state invariant on every target.
    const dep_sokol = if (is_android)
        b.dependency("sokol", .{
            .target = target,
            .optimize = optimize,
            .with_sokol_imgui = true,
            .dont_link_system_libs = is_android,
        })
    else
        b.dependency("sokol", .{
            .target = target,
            .optimize = optimize,
            .with_sokol_imgui = true,
            .with_sokol_imgui_no_app = true,
            .dont_link_system_libs = is_android,
        });

    // Inject the cimgui header search path into sokol's C library
    // so sokol_imgui can find the imgui headers.
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(
        dep_cimgui.path(cimgui_conf.include_dir),
    );

    const sokol_mod = dep_sokol.module("sokol");
    const sokol_artifact = dep_sokol.artifact("sokol_clib");
    const cimgui_artifact = dep_cimgui.artifact(cimgui_conf.clib_name);

    // On Android, cimgui compiles C++ (imgui.h includes <assert.h> etc.)
    // which requires the NDK sysroot include paths. Zig ships Android libc
    // headers but not all NDK extensions — inject from ANDROID_HOME/NDK.
    if (is_android) {
        const ndk_sysroot = findAndroidNdkSysroot(b) orelse
            @panic("Android NDK not found. Set ANDROID_HOME or ANDROID_NDK_HOME.");
        const arch_triple: []const u8 = switch (target.result.cpu.arch) {
            .x86_64 => "x86_64-linux-android",
            .x86 => "i686-linux-android",
            .arm => "arm-linux-androideabi",
            else => "aarch64-linux-android", // .aarch64 and any future arch
        };
        const ndk_inc = b.pathJoin(&.{ ndk_sysroot, "usr/include" });
        const ndk_arch_inc = b.pathJoin(&.{ ndk_sysroot, "usr/include", arch_triple });
        for (&[_]*std.Build.Step.Compile{ sokol_artifact, cimgui_artifact }) |artifact| {
            artifact.root_module.addSystemIncludePath(.{ .cwd_relative = ndk_inc });
            artifact.root_module.addSystemIncludePath(.{ .cwd_relative = ndk_arch_inc });
            // Android shared libs (libgame.so) absorb these static
            // archives. ld.lld rejects AArch64 R_AARCH64_ABS64 /
            // R_AARCH64_ADR_PREL_PG_HI21 relocations from non-PIC .o
            // files inside a shared object, so every TU here must be
            // PIC. See labelle-assembler#147.
            artifact.root_module.pic = true;
        }
    }

    // On Emscripten, the cimgui C++ compile (imgui.h pulls in <assert.h>,
    // <string.h>, <math.h>, etc.) cannot find libc headers because Zig
    // does not ship libc headers for `wasm32-emscripten` — they live in
    // emsdk's sysroot. Mirror what sokol-zig does for `sokol_clib` and
    // what `labelle-assembler/backends/sokol/build.zig` does for gfx/audio
    // (labelle-cli#197): plumb the emsdk sysroot include path into both
    // the sokol and cimgui C compile artifacts. Gated on `.emscripten`
    // so desktop / mobile builds remain untouched.
    //
    // ONE emsdk provides the headers for both, and it is the one the game
    // links with (see emsdk_source.zig):
    //   - a valid `EMSDK` (labelle-imgui#39; labelle-web 0.3 exports EMSDK,
    //     EM_CONFIG and PATH in that shape), whose sysroot is used as is, and
    //     this bridge's emsdk package is not fetched; or
    //   - this bridge's `emsdk` package (#41), pinned identically to the
    //     game's root emsdk (the one its emcc link uses). Its own
    //     install/activate (`sokol_emsdk_setup.packageSetupStep`) runs when it
    //     isn't activated yet, and both C compiles wait for it.
    // Either way sokol-zig's OWN emsdk handling is taken off sokol_clib
    // (`sokol_emsdk_setup.takeOver`): its install/activate steps, which ran on
    // sokol-zig's different emsdk pin (5.0.x) as a second ~1.5 GB download,
    // and its sysroot include, which put that other SDK's headers first.
    // Before #41 the package path added the 4.0.9 sysroot BEHIND sokol-zig's,
    // and nothing activated 4.0.9, so it could point at an empty directory.
    // `-Demsdk_expect=external|package` fails the configure unless that source
    // was chosen, so CI can assert which path ran.
    if (target.result.os.tag == .emscripten) {
        const emsdk_expect = b.option(
            emsdk_source.Expect,
            "emsdk_expect",
            "Fail unless the wasm build takes emscripten from this source (external = a valid EMSDK, package = the emsdk Zig package)",
        );
        const fs: BuildFs = .{ .b = b };
        // The bridge never runs emcc itself (the backend links), but a valid
        // emsdk has one, so the same layout check as labelle-bgfx applies.
        const source = emsdk_source.resolve(b.allocator, b.graph.environ_map.get("EMSDK"), .{
            .emcc_name = if (@import("builtin").os.tag == .windows) "emcc.bat" else "emcc",
        }, fs);
        if (emsdk_source.mismatch(source, emsdk_expect)) |msg| std.debug.panic("emsdk: {s}", .{msg});

        // The chosen emsdk's sysroot, and (package only) its pending setup.
        var sysroot: std.Build.LazyPath = undefined;
        var setup: ?*std.Build.Step = null;
        switch (source) {
            .external => |root| sysroot = .{
                .cwd_relative = emsdk_source.sysrootInclude(b.allocator, root) catch @panic("OOM"),
            },
            .package => {
                // Lazy: on the first configure the build runner fetches it and
                // re-runs build().
                const emsdk_dep = b.lazyDependency("emsdk", .{}) orelse return;
                sysroot = emsdk_dep.path("upstream/emscripten/cache/sysroot/include");
                setup = sokol_emsdk_setup.packageSetupStep(b, emsdk_dep);
            },
        }
        _ = sokol_emsdk_setup.takeOver(b, dep_sokol, sokol_artifact, sysroot, setup);
        cimgui_artifact.root_module.addSystemIncludePath(sysroot);
        if (setup) |s| cimgui_artifact.step.dependOn(s);
    }

    // Build bridge as static library. Android forces PIC end-to-end —
    // libgame.so (the APK entrypoint) absorbs this archive, and ld.lld
    // rejects non-PIC .o files inside a shared object. The bridge.zig
    // TUs didn't surface relocation errors during initial verification
    // because they don't take absolute references that R_AARCH64_ABS64
    // would flag, but pinning it explicitly keeps every artifact on the
    // Android path consistent (sokol_clib + cimgui_clib already do it
    // above) and removes the implicit "Zig happens to emit PIC-friendly
    // code here" assumption.
    const bridge_mod = b.addModule("mod_sokol_imgui_bridge", .{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .pic = if (is_android) true else null,
    });
    bridge_mod.addImport("sokol", sokol_mod);
    bridge_mod.addImport("cimgui", dep_cimgui.module(cimgui_conf.module_name));
    bridge_mod.linkLibrary(sokol_artifact);
    bridge_mod.linkLibrary(cimgui_artifact);

    const bridge_lib = b.addLibrary(.{
        .name = "sokol_imgui_bridge",
        .root_module = bridge_mod,
        .linkage = .static,
    });
    b.installArtifact(bridge_lib);

    // ── Unit tests ─────────────────────────────────────────────────────
    // The wasm emsdk decisions (#39, #41) are pure Zig, so they run on the host
    // (pinned so `zig build test` still runs under `-Dtarget=` cross builds).
    const host_target = b.resolveTargetQuery(.{});
    const test_step = b.step("test", "Run sokol bridge unit tests");
    for ([_][]const u8{ "emsdk_source.zig", "sokol_emsdk_setup.zig" }) |file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = host_target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}

/// Filesystem probe for emsdk_source.resolve.
const BuildFs = struct {
    b: *std.Build,
    pub fn exists(self: @This(), path: []const u8) bool {
        std.Io.Dir.cwd().access(self.b.graph.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            // Anything else (permissions, I/O) is not "missing": report it
            // rather than silently falling back to installing the package emsdk.
            else => std.debug.panic("emsdk: cannot check path '{s}': {s}", .{ path, @errorName(err) }),
        };
        return true;
    }
};

/// Locate the Android NDK sysroot by scanning ANDROID_HOME/ndk/ for the
/// latest installed NDK version. Falls back to ANDROID_NDK_HOME if set.
/// Returns a heap-allocated path owned by the Build arena, or null.
fn findAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const host_tag: []const u8 = switch (@import("builtin").os.tag) {
        .macos => "darwin-x86_64",
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };

    // Try ANDROID_NDK_HOME directly first.
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        return b.pathJoin(&.{ ndk_home, "toolchains/llvm/prebuilt", host_tag, "sysroot" });
    }

    // Scan $ANDROID_HOME/ndk/ for the latest version directory.
    const android_home = b.graph.environ_map.get("ANDROID_HOME") orelse return null;
    const ndk_dir_path = b.pathJoin(&.{ android_home, "ndk" });
    var ndk_dir = std.Io.Dir.cwd().openDir(b.graph.io, ndk_dir_path, .{ .iterate = true }) catch return null;
    defer ndk_dir.close(b.graph.io);

    var latest: ?[]const u8 = null;
    var latest_major: u32 = 0;
    var iter = ndk_dir.iterate();
    while (iter.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        // NDK dirs are named like "27.2.12479018" — compare by major version
        // number to avoid string-order bugs with multi-digit versions (e.g. "9" > "27").
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
