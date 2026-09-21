const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional shipped emitter. LaTeX/TikZ output
    const latex_renderer = b.option(
        bool,
        "latex_renderer",
        "Compile the TikZ/LaTeX emitter into the library (default: false)",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(bool, "latex_renderer", latex_renderer);
    // One module instance, shared by the library and the test binary. Calling
    // `addOptions` on each would root the same generated file in two modules, which
    // Zig rejects.
    const options_mod = options.createModule();

    // The library module. One module for the whole pipeline
    const cktimg = b.addModule("cktimg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cktimg.addImport("build_options", options_mod);

    // Static library, for the C ABI consumers.
    const lib = b.addLibrary(.{
        .name = "cktimg",
        .linkage = .static,
        .root_module = cktimg,
    });
    lib.installHeader(b.path("include/cktimg.h"), "cktimg.h");
    b.installArtifact(lib);

    // The self-hosted gallery renderer. NOT shipped with the library
    const gallery = b.addExecutable(.{
        .name = "gallery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/self-hosted/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cktimg", .module = cktimg }},
        }),
    });
    const gallery_step = b.step("gallery", "Render the fixture gallery to SVG + HTML");
    gallery_step.dependOn(&b.addRunArtifact(gallery).step);

    // The JSON front end. Ungated: `json.zig` is compiled in every configuration, so
    // unlike `cktimg-tex` there is no build option under which this could fail to build.
    const json_cli = b.addExecutable(.{
        .name = "cktimg-json",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "cktimg", .module = cktimg }},
        }),
    });
    b.installArtifact(json_cli);

    const run_json = b.addRunArtifact(json_cli);
    run_json.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_json.addArgs(args);
    const json_step = b.step("json", "Run cktimg-json (pass args after --)");
    json_step.dependOn(&run_json.step);

    // The LaTeX front end. Gated on the option because it calls `latex.write`, which is
    // `void` without it — building it unconditionally would turn "the option is off" into
    // a compile error in a file the user never asked for.
    if (latex_renderer) {
        const tex = b.addExecutable(.{
            .name = "cktimg-tex",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tex_main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "cktimg", .module = cktimg }},
            }),
        });
        b.installArtifact(tex);

        const run_tex = b.addRunArtifact(tex);
        run_tex.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_tex.addArgs(args);
        const tex_step = b.step("tex", "Run cktimg-tex (pass args after --)");
        tex_step.dependOn(&run_tex.step);
    }

    // Benchmark over the fixture set. Always ReleaseFast — including a *second
    // instance* of the library module, because importing the shared `cktimg` would
    // time Debug-compiled pipeline code whenever the session default is Debug, and a
    // debug number would only ever be misread as a real one.
    const cktimg_fast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cktimg_fast.addImport("build_options", options_mod);
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "cktimg", .module = cktimg_fast }},
        }),
    });
    const bench_step = b.step("bench", "Time place+route per fixture (best of 5)");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // `zig build test` runs tests/test_all.zig, which pulls in both the in-source
    // unit tests and every behavioral suite under tests/.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cktimg", .module = cktimg }},
    });
    test_mod.addImport("build_options", options_mod);
    // `tests/targets.zig` checks every shipped `targets/*.json` against the device
    // catalog. The manifest parser deliberately lives in the front end rather than in the
    // library (see the header of src/json_main.zig), so the suite reaches it by importing
    // the front end's own module — the same one the executable is built from, so the test
    // cannot validate a second copy of the parser.
    test_mod.addImport("json_main", json_cli.root_module);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
