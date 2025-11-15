const std = @import("std");

pub fn makePage(b: *std.Build, name: []const u8, path: []const u8, wasm_target: std.Build.ResolvedTarget, wasm_optimize: std.builtin.OptimizeMode, wasm_symbols: ?bool, wsr: *std.Build.Module) void {
    const wasm_exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = wasm_target,
            .optimize = wasm_optimize,
        })
    });
    wasm_exe.root_module.addImport("wsr", wsr);

    wasm_exe.entry = .disabled;

    // FIXME: Mega too large surely
    wasm_exe.stack_size = 10 * 1024 * 1024;
    wasm_exe.max_memory = 20 * 1024 * 1024;

    wasm_exe.rdynamic = true;
    wasm_exe.want_lto = true;
    wasm_exe.root_module.strip = if (wasm_symbols) |s| !s else null;
    b.installArtifact(wasm_exe);
}

pub fn build(b: *std.Build) void {
    const wsr_dep = b.dependency("wsr", .{});
    const wsr = wsr_dep.module("wsr");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-opt", "") orelse .Debug;
    const wasm_symbols = b.option(bool, "wasm-symbols", "");

    // FIXME: struct me up fam
    makePage(b, "item-list", "src/item_list.zig", wasm_target, wasm_optimize, wasm_symbols, wsr);
    makePage(b, "craft-tree", "src/craft_tree.zig", wasm_target, wasm_optimize, wasm_symbols, wsr);
}
