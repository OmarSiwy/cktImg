//! Place-and-route benchmark over the fixture set.
//!
//! `zig build bench` (always ReleaseFast). One line per fixture: device/net counts
//! and the best-of-5 wall time for a full `Pipeline.run`, default config and strict
//! mode. Best-of, not mean: the minimum is the run least polluted by the OS, and the
//! question here is "what does the algorithm cost", not "what does the machine do".

const std = @import("std");
const cktimg = @import("cktimg");

const iters = 5;
const fixture_dir = "tests/fixtures";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd: std.Io.Dir = .cwd();
    var dir = try cwd.openDir(io, fixture_dir, .{ .iterate = true });
    defer dir.close(io);

    // Directory order is filesystem-defined; sorted names keep two runs comparable
    // line by line.
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .directory or !std.mem.endsWith(u8, e.name, ".spice")) continue;
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var strict = cktimg.Config.default;
    strict.layout.strict_geometry = true;

    std.debug.print("{s:<34} {s:>4} {s:>4} {s:>12} {s:>12}\n", .{
        "fixture", "dev", "net", "default", "strict",
    });
    var total_def: u64 = 0;
    var total_strict: u64 = 0;
    for (names.items) |name| {
        const src = try dir.readFileAlloc(io, name, arena, .limited(1 << 22));

        const def_ns, const nd, const nn = try best(gpa, io, &cktimg.Config.default, src);
        const strict_ns, _, _ = try best(gpa, io, &strict, src);
        total_def += def_ns;
        total_strict += strict_ns;
        std.debug.print("{s:<34} {d:>4} {d:>4} {d:>9}us {d:>9}us\n", .{
            name, nd, nn, def_ns / 1000, strict_ns / 1000,
        });
    }
    std.debug.print("{s:<34} {s:>4} {s:>4} {d:>9}us {d:>9}us\n", .{
        "TOTAL", "", "", total_def / 1000, total_strict / 1000,
    });
}

/// Best-of-`iters` wall time for one fixture, plus its device and net counts.
fn best(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const cktimg.Config,
    src: []const u8,
) !struct { u64, usize, usize } {
    var p = cktimg.Pipeline.init(gpa, cfg);
    defer p.deinit();

    var min_ns: u64 = std.math.maxInt(u64);
    var nd: usize = 0;
    var nn: usize = 0;
    for (0..iters) |_| {
        p.reset();
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);
        const placed, _ = try p.run(src);
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).raw.nanoseconds);
        min_ns = @min(min_ns, ns);
        nd = placed.ir.dev_pin0.len -| 1;
        nn = placed.ir.net_name.len;
    }
    return .{ min_ns, nd, nn };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
