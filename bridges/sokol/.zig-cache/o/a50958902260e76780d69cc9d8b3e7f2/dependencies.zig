pub const packages = struct {
    pub const @"12203cad7061e35c3112e720991e183eea0e5c67976c5c863ef4ca7c11620f3d2623" = struct {
        pub const build_root = "/Users/alexandrecalvao/.cache/zig/p/sokol-0.1.0-pb1HKxTaNgA8rXBh41wxEucgmR4YPuoOXGeXbFyGPvTK";
        pub const build_zig = @import("12203cad7061e35c3112e720991e183eea0e5c67976c5c863ef4ca7c11620f3d2623");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "emsdk", "N-V-__8AAMGsDwC6L1OfDgzRF1zFI2t-CaR0sVhEm8pmrpxm" },
            .{ "shdc", "sokolshdc-0.1.0-r2KZDhCTcARkWp7-FHBGPghlpM9lLOxPaccqSdy5Cr-R" },
        };
    };
    pub const @"N-V-__8AAMGsDwC6L1OfDgzRF1zFI2t-CaR0sVhEm8pmrpxm" = struct {
        pub const build_root = "/Users/alexandrecalvao/.cache/zig/p/N-V-__8AAMGsDwC6L1OfDgzRF1zFI2t-CaR0sVhEm8pmrpxm";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"cimgui-0.1.0-44ClkXnYlwBKnil7TfCWL9z1Zo_2YJCJREzrpdFiGvA1" = struct {
        pub const build_root = "/Users/alexandrecalvao/.cache/zig/p/cimgui-0.1.0-44ClkXnYlwBKnil7TfCWL9z1Zo_2YJCJREzrpdFiGvA1";
        pub const build_zig = @import("cimgui-0.1.0-44ClkXnYlwBKnil7TfCWL9z1Zo_2YJCJREzrpdFiGvA1");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"sokolshdc-0.1.0-r2KZDhCTcARkWp7-FHBGPghlpM9lLOxPaccqSdy5Cr-R" = struct {
        pub const build_root = "/Users/alexandrecalvao/.cache/zig/p/sokolshdc-0.1.0-r2KZDhCTcARkWp7-FHBGPghlpM9lLOxPaccqSdy5Cr-R";
        pub const build_zig = @import("sokolshdc-0.1.0-r2KZDhCTcARkWp7-FHBGPghlpM9lLOxPaccqSdy5Cr-R");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "sokol", "12203cad7061e35c3112e720991e183eea0e5c67976c5c863ef4ca7c11620f3d2623" },
    .{ "cimgui", "cimgui-0.1.0-44ClkXnYlwBKnil7TfCWL9z1Zo_2YJCJREzrpdFiGvA1" },
};
