//! The Zig package at the repository root, so `zig fetch git+https://github.com/OmarSiwy/cktImg`
//! and release tarballs both give a consumer `NetlistParser`. The build is engine/build.zig;
//! this file only forwards its options, module, installed artifacts and steps.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const engine = b.dependency("engine", .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .latex_renderer = b.option(bool, "latex_renderer", "Build the TikZ emitter and cktimg-tex"),
        .zon_config = b.option(bool, "zon_config", "Let the C ABI read lint.zon settings and .zon symbol files (links Zig's ZON parser)"),
        .pic = b.option(bool, "pic", "Compile position-independent code (to link libcktimg.a into a PIE or a shared object)"),
    });
    b.modules.put(b.graph.arena, "NetlistParser", engine.module("NetlistParser")) catch @panic("OOM");
    // The engine's install steps themselves, so `dependency.artifact("cktimg")` finds them here.
    for (engine.builder.install_tls.step.dependencies.items) |step| b.getInstallStep().dependOn(step);
    for (engine.builder.top_level_steps.values()) |tls| {
        if (tls == &engine.builder.install_tls or tls == &engine.builder.uninstall_tls) continue;
        b.step(tls.step.name, tls.description).dependOn(&tls.step);
    }
}
