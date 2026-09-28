//! Recognises sokol-zig's one-time emsdk setup commands (labelle-imgui#39).
//!
//! For a web target, sokol-zig's `buildLibSokol` makes `sokol_clib` depend on
//! `emsdk install latest` + `emsdk activate latest`, run on sokol-zig's OWN
//! `emsdk` Zig package whenever that package has no `.emscripten` yet. The
//! helper is private and has no opt-out, so a game that already has a valid
//! `EMSDK` (labelle-web 0.3 exports one) would still download a second
//! ~1.5 GB emsdk. The bridge therefore finds those two Run steps on
//! `sokol_clib` and, with an external EMSDK, drops them; with the package
//! emsdk it only renames them so `--summary all` shows that they ran.
//!
//! sokol-zig builds the commands as `bash <emsdk>/emsdk <verb> latest`
//! (`<emsdk>/emsdk.bat <verb> latest` on Windows). This file decides, from a
//! Run step's plain string arguments, whether it is one of them. std-only and
//! pure, so it runs as a host unit test in `zig build test`.
const std = @import("std");

pub const Kind = enum {
    install,
    activate,

    /// Step name for `--summary all`; CI greps for "(zig-pkg emsdk)".
    pub fn stepName(self: Kind) []const u8 {
        return switch (self) {
            .install => "sokol-zig: emsdk install latest (zig-pkg emsdk)",
            .activate => "sokol-zig: emsdk activate latest (zig-pkg emsdk)",
        };
    }
};

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

test "step names carry the (zig-pkg emsdk) marker CI greps for" {
    try testing.expect(std.mem.indexOf(u8, Kind.install.stepName(), "(zig-pkg emsdk)") != null);
    try testing.expect(std.mem.indexOf(u8, Kind.activate.stepName(), "(zig-pkg emsdk)") != null);
}
