const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Core library module (dependency-free, wasm-friendly) --------------
    const mod = b.addModule("wazmrt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ---- CLI front-end -----------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "wazmrt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wazmrt", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the CLI (zig build run -- <module.wasm>)");
    run_step.dependOn(&run_cmd.step);

    // ---- C ABI library for universalWasmLoader-* ---------------------------
    // Its own root so the core stays libc-free; this artifact links libc.
    const cabi = b.addLibrary(.{
        .name = "wazmrt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cabi.installHeader(b.path("include/wazmrt.h"), "wazmrt.h");
    b.installArtifact(cabi);

    // ---- Freestanding wasm build (`zig build wasm`) ------------------------
    // Proves the runtime itself compiles to WebAssembly.
    const wasm_exe = b.addExecutable(.{
        .name = "wazmrt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_entry.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm_exe, .{});
    const wasm_step = b.step("wasm", "Build the runtime as a freestanding wasm module");
    wasm_step.dependOn(&install_wasm.step);

    // ---- Tests -------------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
