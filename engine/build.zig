const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const latex_renderer = b.option(bool, "latex_renderer", "Build the TikZ emitter and cktimg-tex") orelse false;
    const zon_config = b.option(bool, "zon_config", "Let the C ABI read lint.zon settings and .zon symbol files (links Zig's ZON parser)") orelse true;
    const options = b.addOptions();
    options.addOption(bool, "latex_renderer", latex_renderer);
    options.addOption(bool, "zon_config", zon_config);

    const mod = b.addModule("NetlistParser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // A host that links libcktimg.a into a PIE or a shared object (gcc's and Rust's
        // default executables on Linux) needs position-independent code.
        .pic = b.option(bool, "pic", "Compile position-independent code (to link libcktimg.a into a PIE or a shared object)"),
    });
    mod.addOptions("build_options", options);

    // libcktimg.a and its header: the C ABI (src/abi.zig). `zig build lib` installs only
    // these, for a host that links the library (and on targets the tools do not build for).
    const static = b.addLibrary(.{ .name = "cktimg", .linkage = .static, .root_module = mod });
    // A freestanding host (a wasm guest) has no C runtime to supply compiler-rt's f128
    // helpers (`__divtf3`, `truncl`, ...), so the archive carries them.
    if (target.result.os.tag == .freestanding) static.bundle_compiler_rt = true;
    b.installArtifact(static);
    b.installFile("include/cktimg.h", "include/cktimg.h");
    const lib_step = b.step("lib", "Build libcktimg.a and install it with include/cktimg.h");
    lib_step.dependOn(&b.addInstallArtifact(static, .{}).step);
    lib_step.dependOn(&b.addInstallFile(b.path("include/cktimg.h"), "include/cktimg.h").step);
    // The tools need an OS (files, a clock); a freestanding target (wasm) gets the library only.
    if (target.result.os.tag == .freestanding) return;

    // The standard symbol set, for the tools (the library itself has none).
    const sym_files = b.addWriteFiles();
    _ = sym_files.addCopyFile(b.path("tests/symbols.zon"), "symbols.zon");
    const symbols = b.createModule(.{ .root_source_file = sym_files.add("symbols.zig", "pub const text = @embedFile(\"symbols.zon\");\n") });

    // Unit tests inside the library (netlist, csr, library, config, …).
    const lib_tests = b.addTest(.{ .root_module = mod });

    // The algorithm and API suites, as a consumer sees the module.
    const tool_imports: []const std.Build.Module.Import = &.{.{ .name = "NetlistParser", .module = mod }};
    const cases = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/cases.zig"),
        .target = target,
        .optimize = optimize,
        .imports = tool_imports,
    }) });
    // The example decks, for the API suite's connectivity check.
    const ex_files = b.addWriteFiles();
    _ = ex_files.addCopyFile(b.path("examples/blocks.spice"), "blocks.spice");
    _ = ex_files.addCopyFile(b.path("examples/latex/cs.cir"), "cs.cir");
    const examples = b.createModule(.{ .root_source_file = ex_files.add("examples.zig", "pub const all = [_][]const u8{ @embedFile(\"blocks.spice\"), @embedFile(\"cs.cir\") };\n") });
    const api = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "NetlistParser", .module = mod }, .{ .name = "examples", .module = examples } },
    }) });

    // The C ABI as a C program uses it.
    const abi_test = b.addExecutable(.{ .name = "abi_test", .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    abi_test.root_module.addCSourceFile(.{ .file = b.path("tests/abi_test.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    abi_test.root_module.addIncludePath(b.path("include"));
    abi_test.root_module.linkLibrary(static);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(cases).step);
    test_step.dependOn(&b.addRunArtifact(api).step);
    test_step.dependOn(&b.addRunArtifact(abi_test).step);

    const fuzz = b.addExecutable(.{ .name = "fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = tool_imports,
    }) });
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.addPassthruArgs();
    b.step("fuzz", "Random netlists through the pipeline; smallest example per rare case").dependOn(&fuzz_run.step);

    const gallery = b.addExecutable(.{ .name = "gallery", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/gallery.zig"),
        .target = target,
        .optimize = optimize,
        .imports = tool_imports,
    }) });
    b.installArtifact(gallery);
    const gallery_run = b.addRunArtifact(gallery);
    gallery_run.addPassthruArgs();
    b.step("gallery", "Draw the textbook circuits (--svgs dir | --gallery out.html | in.cir out.svg)").dependOn(&gallery_run.step);

    // cktimg-json: the placed schematic as JSON (and SVG) for scripts.
    const svg_mod = b.createModule(.{ .root_source_file = b.path("tests/svg.zig"), .imports = tool_imports });
    const json_mod = b.createModule(.{
        .root_source_file = b.path("tools/json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "NetlistParser", .module = mod }, .{ .name = "symbols", .module = symbols }, .{ .name = "svg", .module = svg_mod } },
    });
    b.installArtifact(b.addExecutable(.{ .name = "cktimg-json", .root_module = json_mod }));
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = json_mod })).step);

    if (latex_renderer) {
        const tex = b.addExecutable(.{ .name = "cktimg-tex", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tex.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "NetlistParser", .module = mod }, .{ .name = "symbols", .module = symbols } },
        }) });
        b.installArtifact(tex);
        b.installFile("latex/cktimg.sty", "share/latex/cktimg.sty");
    }
}
