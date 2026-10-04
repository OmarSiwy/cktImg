const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const latex_renderer = b.option(bool, "latex_renderer", "Build the TikZ emitter and cktimg-tex") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "latex_renderer", latex_renderer);

    const mod = b.addModule("NetlistParser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);

    // libcktimg.a and its header: the C ABI (src/abi.zig).
    const static = b.addLibrary(.{ .name = "cktimg", .linkage = .static, .root_module = mod });
    b.installArtifact(static);
    b.installFile("include/cktimg.h", "include/cktimg.h");

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
    const api = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = tool_imports,
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
    if (b.args) |args| fuzz_run.addArgs(args);
    b.step("fuzz", "Random netlists through the pipeline; smallest example per rare case").dependOn(&fuzz_run.step);

    const gallery = b.addExecutable(.{ .name = "gallery", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/gallery.zig"),
        .target = target,
        .optimize = optimize,
        .imports = tool_imports,
    }) });
    b.installArtifact(gallery);
    const gallery_run = b.addRunArtifact(gallery);
    if (b.args) |args| gallery_run.addArgs(args);
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

    // cktimg-xschem: the xschem target (tools/xschem).
    const xs_files = b.addWriteFiles();
    _ = xs_files.addCopyFile(b.path("tools/xschem/symbols.zon"), "symbols.zon");
    _ = xs_files.addCopyFile(b.path("tools/xschem/xschem.zon"), "xschem.zon");
    const xs_mod = b.createModule(.{ .root_source_file = xs_files.add("files.zig", "pub const symbols = @embedFile(\"symbols.zon\");\npub const map = @embedFile(\"xschem.zon\");\n") });
    const xschem = b.addExecutable(.{ .name = "cktimg-xschem", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/xschem/export.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "NetlistParser", .module = mod }, .{ .name = "xschem_files", .module = xs_mod } },
    }) });
    b.installArtifact(xschem);

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
