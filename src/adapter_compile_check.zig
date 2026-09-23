//! Compile check for the adapter (CI, `zig build check` / `zig build test`).
//!
//! `src/adapter.zig` is the package's main source but no artifact in this
//! repo imports it, so a syntax or cimgui API break used to pass every build.
//! Forcing analysis of every public declaration fixes that. This is built as
//! an OBJECT, not a test binary: the adapter's `extern fn imgui_bridge_*`
//! symbols are provided by a bridge at game link time, so a linked binary
//! would fail on them here while an object just leaves them unresolved.
const adapter = @import("labelle_imgui");

// Not `std.testing.refAllDecls`: it returns early unless `builtin.is_test`,
// so in this object build it was a silent no-op (a canary type error in
// `wantsMouse` passed). Taking a function's address is what forces its body
// to be analysed. Generic functions (`anytype` parameters) cannot be
// instantiated without arguments and are skipped by the loop, then
// instantiated below with representative arguments.
comptime {
    for (@typeInfo(adapter).@"struct".decls) |d| {
        const field = @field(adapter, d.name);
        const info = @typeInfo(@TypeOf(field));
        if (info == .@"fn" and !info.@"fn".is_generic) _ = &field;
    }
}

// `textFmt(fmt, args: anytype)` is the adapter's only generic function. It
// forwards to cimgui's variadic `igText`, so instantiate it with a typical
// argument tuple: a change to `igText` or to the wrapper then fails here.
fn instantiateGenerics() void {
    adapter.textFmt("%d / %d %s", .{ @as(c_int, 1), @as(c_int, 2), @as([*:0]const u8, "x") });
    adapter.textFmt("plain", .{});
}

comptime {
    _ = &instantiateGenerics;
}
