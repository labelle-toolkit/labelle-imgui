//! Takes sokol-zig's emsdk handling off `sokol_clib` (labelle-imgui#39, #41).
//!
//! For a web target, sokol-zig's `buildLibSokol` gives `sokol_clib`:
//!   - a dependency on `emsdk install latest` + `emsdk activate latest`, run on
//!     sokol-zig's OWN `emsdk` Zig package (5.0.x) whenever that package has no
//!     `.emscripten` yet, and
//!   - that package's `upstream/emscripten/cache/sysroot/include` as `-isystem`.
//! Both are private and have no opt-out. But the game links with a DIFFERENT
//! emsdk: a valid `EMSDK` (labelle-web 0.3), or else the emsdk pinned by the
//! game's root and by this package (4.0.9). So sokol-zig's setup was a second
//! ~1.5 GB download, and its headers belonged to another SDK than the linker's.
//!
//! `takeOver` fixes both for either source: it removes sokol-zig's setup steps
//! and its sysroot include from `sokol_clib`, adds the chosen emsdk's sysroot
//! instead, and (for the package source) makes `sokol_clib` wait for that
//! emsdk's own setup. sokol-zig's emsdk package is still fetched (its
//! dependency is not lazy) but never installed or activated.
//!
//! This file is shared: labelle-sokol's build.zig carries an identical copy,
//! because both packages build the SAME `sokol_clib` (Zig keys the dependency by
//! its options, which must match). Whichever runs first takes over; the second
//! finds nothing left to remove and only adds the same include again
//! (`Outcome.already_taken_over`).
//!
//! The decisions (`classify`, `outcome`) are pure and run as host unit tests.
const std = @import("std");

pub const Kind = enum { install, activate };

/// `argv` holds a Run step's arguments; non-string arguments (artifacts, lazy
/// paths, outputs) are null. `scripts` are sokol-zig's emsdk entry points
/// (`<emsdk>/emsdk` and `<emsdk>/emsdk.bat`). Returns which setup command the
/// step is, or null when it is anything else (including an emsdk command on
/// some other emsdk).
pub fn classify(argv: []const ?[]const u8, scripts: []const []const u8) ?Kind {
    for (argv, 0..) |arg_opt, i| {
        const arg = arg_opt orelse continue;
        if (!isOneOf(arg, scripts)) continue;
        // The verb and its argument follow the script.
        const rest = argv[i + 1 ..];
        if (rest.len != 2) return null;
        const verb = rest[0] orelse return null;
        const version = rest[1] orelse return null;
        if (!std.mem.eql(u8, version, "latest")) return null;
        if (std.mem.eql(u8, verb, "install")) return .install;
        if (std.mem.eql(u8, verb, "activate")) return .activate;
        return null;
    }
    return null;
}

fn isOneOf(arg: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, arg, s)) return true;
    return false;
}

pub const Outcome = enum {
    /// sokol-zig's include (and its setup, unless its package was already
    /// activated) were found and removed.
    taken_over,
    /// Neither was found: another package building the same `sokol_clib`
    /// (labelle-sokol or this bridge) already took over.
    already_taken_over,
};

/// What removing sokol-zig's emsdk handling found. An error means sokol-zig
/// changed shape (e.g. a pin bump), so the takeover can't be trusted: fail the
/// configure rather than silently downloading or mixing SDK headers.
pub fn outcome(setup_removed: usize, include_removed: usize, sokol_pkg_activated: bool) error{SokolZigShapeChanged}!Outcome {
    if (include_removed == 0 and setup_removed == 0) return .already_taken_over;
    if (include_removed == 0) return error.SokolZigShapeChanged; // setup, but no include
    // sokol-zig adds the setup only while its package is not activated.
    if (setup_removed == 0 and !sokol_pkg_activated) return error.SokolZigShapeChanged;
    return .taken_over;
}

pub const SetupPlan = enum {
    /// Another package building the same `sokol_clib` already attached the
    /// package emsdk's setup: wait on THAT step. Creating a second one would
    /// run two `emsdk install` commands on one directory at once.
    reuse,
    /// First caller, package not activated: create the setup and attach it.
    create,
    /// Already activated: nothing to run.
    none,
};

/// How to get the package emsdk's setup step for `sokol_clib`.
pub fn setupPlan(already_attached: bool, package_activated: bool) SetupPlan {
    if (already_attached) return .reuse;
    return if (package_activated) .none else .create;
}

// ── build-graph side (configure time) ────────────────────────────────────

pub const Result = struct {
    outcome: Outcome,
    /// The package emsdk's install/activate step that `sokol_clib` now waits
    /// on (null for an external EMSDK, or an already-activated package). Every
    /// other C/C++ compile that uses the same sysroot must wait on it too.
    setup: ?*std.Build.Step,
};

/// Remove sokol-zig's emsdk setup and sysroot from `sokol_clib`, then give it
/// `sysroot` (the chosen emsdk's `cache/sysroot/include`). With the package
/// source (`package_emsdk` non-null), `sokol_clib` also waits for that
/// package's own install/activate: the one another package already attached to
/// this shared `sokol_clib` if there is one, else a new one (see `setupPlan`).
/// `dep_sokol` is the `b.dependency("sokol", ...)` that built `sokol_clib`.
pub fn takeOver(
    b: *std.Build,
    dep_sokol: *std.Build.Dependency,
    sokol_clib: *std.Build.Step.Compile,
    sysroot: std.Build.LazyPath,
    package_emsdk: ?*std.Build.Dependency,
) Result {
    const sokol_emsdk = dep_sokol.builder.dependency("emsdk", .{});
    const scripts = [_][]const u8{
        sokol_emsdk.path("emsdk").getPath(b),
        sokol_emsdk.path("emsdk.bat").getPath(b),
    };
    // Find an existing setup for OUR package first: sokol-zig's removal below
    // only matches sokol-zig's own emsdk scripts, never these.
    const existing: ?*std.Build.Step = if (package_emsdk) |e| blk: {
        const own = [_][]const u8{ e.path("emsdk").getPath(b), e.path("emsdk.bat").getPath(b) };
        for (sokol_clib.step.dependencies.items) |dep| {
            if (setupKind(b, dep, &own) == .activate) break :blk dep;
        }
        break :blk null;
    } else null;
    const setup_removed = removeSetupSteps(b, &sokol_clib.step, &scripts);
    const include_removed = removeSystemIncludeDir(
        b,
        sokol_clib.root_module,
        sokol_emsdk.path("upstream/emscripten/cache/sysroot/include").getPath(b),
    );
    const activated = if (std.Io.Dir.cwd().access(b.graph.io, sokol_emsdk.path(".emscripten").getPath(b), .{})) |_| true else |_| false;
    const result = outcome(setup_removed, include_removed, activated) catch std.debug.panic(
        "emsdk: sokol-zig's emsdk handling on sokol_clib is not the expected shape (setup steps removed: {d}, sysroot includes removed: {d}); did the sokol pin change? see sokol_emsdk_setup.zig",
        .{ setup_removed, include_removed },
    );
    sokol_clib.root_module.addSystemIncludePath(sysroot);
    const setup: ?*std.Build.Step = if (package_emsdk) |e| switch (setupPlan(existing != null, isActivated(b, e))) {
        .reuse => existing,
        .none => null,
        .create => blk: {
            const s = packageSetupStep(b, e);
            sokol_clib.step.dependOn(s);
            break :blk s;
        },
    } else null;
    return .{ .outcome = result, .setup = setup };
}

fn isActivated(b: *std.Build, emsdk: *std.Build.Dependency) bool {
    return if (std.Io.Dir.cwd().access(b.graph.io, emsdk.path(".emscripten").getPath(b), .{})) |_| true else |_| false;
}

fn removeSetupSteps(b: *std.Build, step: *std.Build.Step, scripts: []const []const u8) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < step.dependencies.items.len) {
        if (setupKind(b, step.dependencies.items[i], scripts) != null) {
            _ = step.dependencies.orderedRemove(i);
            removed += 1;
        } else i += 1;
    }
    return removed;
}

fn setupKind(b: *std.Build, dep: *std.Build.Step, scripts: []const []const u8) ?Kind {
    const run = dep.cast(std.Build.Step.Run) orelse return null;
    const argv = b.allocator.alloc(?[]const u8, run.argv.items.len) catch @panic("OOM");
    defer b.allocator.free(argv);
    for (run.argv.items, argv) |arg, *out| out.* = switch (arg) {
        .bytes => |bytes| bytes,
        else => null,
    };
    return classify(argv, scripts);
}

/// Remove every `-isystem` entry of `module` that resolves to `abs_path`
/// (source, dependency or absolute paths; a generated path can't be resolved
/// at configure time, and sokol-zig's sysroot is a dependency path).
fn removeSystemIncludeDir(b: *std.Build, module: *std.Build.Module, abs_path: []const u8) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < module.include_dirs.items.len) {
        const match = switch (module.include_dirs.items[i]) {
            .path_system => |lp| switch (lp) {
                .src_path, .dependency, .cwd_relative => std.mem.eql(u8, lp.getPath(b), abs_path),
                .generated => false,
            },
            else => false,
        };
        if (match) {
            _ = module.include_dirs.orderedRemove(i);
            removed += 1;
        } else i += 1;
    }
    return removed;
}

// ── an emsdk package's own one-time setup ────────────────────────────────

/// `emsdk install latest` + `emsdk activate latest` on `emsdk` (an emsdk Zig
/// package); returns the activate step. Named "(zig-pkg emsdk)" so
/// `--summary all` shows whether it ran. Only `takeOver` calls it, so a shared
/// `sokol_clib` never gets two of them. On Windows, Zig runs `emsdk.bat`
/// through cmd.exe itself (std.Io.Threaded handles .bat/.cmd), as sokol-zig
/// does.
fn packageSetupStep(b: *std.Build, emsdk: *std.Build.Dependency) *std.Build.Step {
    const install = emsdkCommand(b, emsdk);
    install.addArgs(&.{ "install", "latest" });
    install.setName("emsdk install latest (zig-pkg emsdk)");
    const activate = emsdkCommand(b, emsdk);
    activate.addArgs(&.{ "activate", "latest" });
    activate.setName("emsdk activate latest (zig-pkg emsdk)");
    activate.step.dependOn(&install.step);
    return &activate.step;
}

fn emsdkCommand(b: *std.Build, emsdk: *std.Build.Dependency) *std.Build.Step.Run {
    if (@import("builtin").os.tag == .windows) {
        return b.addSystemCommand(&.{emsdk.path("emsdk.bat").getPath(b)});
    }
    const run = b.addSystemCommand(&.{"bash"});
    run.addArg(emsdk.path("emsdk").getPath(b));
    return run;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const test_scripts = [_][]const u8{ "/pkg/sokol-emsdk/emsdk", "/pkg/sokol-emsdk/emsdk.bat" };

test "unix: bash <emsdk> install|activate latest" {
    try testing.expectEqual(Kind.install, classify(&.{ "bash", test_scripts[0], "install", "latest" }, &test_scripts).?);
    try testing.expectEqual(Kind.activate, classify(&.{ "bash", test_scripts[0], "activate", "latest" }, &test_scripts).?);
}

test "windows: <emsdk.bat> install|activate latest" {
    try testing.expectEqual(Kind.install, classify(&.{ test_scripts[1], "install", "latest" }, &test_scripts).?);
    try testing.expectEqual(Kind.activate, classify(&.{ test_scripts[1], "activate", "latest" }, &test_scripts).?);
}

test "an emsdk command on another emsdk is not sokol-zig's setup" {
    // Our own package's setup must never be mistaken for sokol-zig's.
    try testing.expect(classify(&.{ "bash", "/other/emsdk", "install", "latest" }, &test_scripts) == null);
}

test "other verbs, versions or trailing args are left alone" {
    try testing.expect(classify(&.{ "bash", test_scripts[0], "list" }, &test_scripts) == null);
    try testing.expect(classify(&.{ "bash", test_scripts[0], "install", "4.0.9" }, &test_scripts) == null);
    try testing.expect(classify(&.{ "bash", test_scripts[0], "install", "latest", "--shallow" }, &test_scripts) == null);
    try testing.expect(classify(&.{ "bash", test_scripts[0], null, "latest" }, &test_scripts) == null);
}

test "unrelated run steps (emcc, non-string args) are left alone" {
    try testing.expect(classify(&.{ "/e/upstream/emscripten/emcc", null, "-o", null }, &test_scripts) == null);
    try testing.expect(classify(&.{}, &test_scripts) == null);
    try testing.expect(classify(&.{ null, null }, &test_scripts) == null);
}

test "outcome: first takeover, with or without sokol-zig's setup" {
    // Unactivated sokol-zig package: both the setup (install+activate) and the
    // include are there to remove.
    try testing.expectEqual(Outcome.taken_over, try outcome(1, 1, false));
    // Activated sokol-zig package (an earlier build): no setup, include only.
    try testing.expectEqual(Outcome.taken_over, try outcome(0, 1, true));
}

test "outcome: the second package on the shared sokol_clib finds nothing left" {
    // labelle-sokol + this bridge in one game: whichever runs second.
    try testing.expectEqual(Outcome.already_taken_over, try outcome(0, 0, false));
    try testing.expectEqual(Outcome.already_taken_over, try outcome(0, 0, true));
}

test "setupPlan: the second package reuses the first one's setup, never a second install" {
    // labelle-sokol + the imgui bridge on a cold package build: the second
    // caller must wait on the step already on sokol_clib, whether or not the
    // marker exists yet (it doesn't: the step hasn't run at configure time).
    try testing.expectEqual(SetupPlan.reuse, setupPlan(true, false));
    try testing.expectEqual(SetupPlan.reuse, setupPlan(true, true));
    try testing.expectEqual(SetupPlan.create, setupPlan(false, false));
    try testing.expectEqual(SetupPlan.none, setupPlan(false, true));
}

test "outcome: a half-found shape means sokol-zig changed, never a silent pass" {
    // Include there but no setup although the package isn't activated: the
    // setup moved somewhere we don't remove it from, so it would download.
    try testing.expectError(error.SokolZigShapeChanged, outcome(0, 1, false));
    // Setup there but not the include: the headers would come from elsewhere.
    try testing.expectError(error.SokolZigShapeChanged, outcome(1, 0, false));
    try testing.expectError(error.SokolZigShapeChanged, outcome(1, 0, true));
}
