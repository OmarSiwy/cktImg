//! The dev gallery driver. **Not shipped with the library.**
//!
//! Walks a directory of SPICE fixtures, places each one, writes an SVG per fixture and
//! an `index.html` that shows them all together. Built by `zig build gallery`.
//!
//! ## What this program is for
//!
//! Two things, and the second one is the reason it is in the repository rather than in
//! somebody's scratch directory.
//!
//! 1. **Looking at the output.** Golden-file comparison catches every change but tells
//!    you nothing about whether a drawing is *readable*. A router can be correct at
//!    every function and produce a schematic no engineer would accept. Twenty-one
//!    fixtures on one page is the only check for that, and it takes five seconds.
//!
//! 2. **Proving the public API is sufficient.** This program imports exactly
//!    `@import("cktimg")` and nothing else from the project. It reaches into no
//!    internals, has no privileged accessor, and shares no support module with `src/`.
//!    That is a deliberate constraint, restated here because it is the kind of rule
//!    that erodes one convenient exception at a time:
//!
//!    > **If the gallery needs something the public API lacks, that is an API bug.**
//!    > Fix `src/`. Do not work around it here.
//!
//!    The bundled renderer having no special access is what makes the library's claim
//!    credible — if this can draw a schematic, a third-party adapter over the C ABI
//!    can too, because it is working from the same surface. Promoting an emitter into
//!    the library, or letting this one peek at a private field, would let the two paths
//!    diverge silently, and the first symptom would be a bug report from someone whose
//!    adapter cannot reproduce our gallery. See ARCHITECTURE.md, "Format emitters are
//!    not library surface".
//!
//! ## Allocation
//!
//! One `Pipeline` for the whole run, reset between fixtures. That is the fine-grained
//! API's entire purpose — after the first fixture warms the arenas, the remaining
//! twenty allocate essentially nothing — and using it here means the gallery is also a
//! standing check that `Pipeline.reset` really does retain capacity, on real inputs,
//! on every build.
//!
//! ## Output layout
//!
//! ```
//! <out_dir>/
//!   index.html      the viewer
//!   <fixture>.svg   one per input, named after the input stem
//! ```
//!
//! Existing files are overwritten. The directory is created if absent.

const std = @import("std");
const ckt = @import("cktimg");

const svg = @import("svg.zig");
const gallery = @import("gallery.zig");

const Allocator = std.mem.Allocator;

/// Where fixtures are read from when no argument is given.
///
/// The canonical deck set lives beside the Rust tree this port is verified against, so
/// the default points at it rather than duplicating twenty-one files. Relative to the
/// repository directory `zig build` runs in.
pub const default_fixture_dir = "tests/fixtures";

/// Where the gallery is written when no second argument is given.
pub const default_out_dir = "zig-out/gallery";

/// Only files with this extension are treated as fixtures.
pub const fixture_ext = ".spice";

/// Render every fixture and write the index.
///
/// Usage: `gallery [fixture_dir] [out_dir]`, defaulting to `default_fixture_dir` and
/// `default_out_dir`. Both are resolved relative to the current working directory.
///
/// Reads `lint.zon` from the fixture directory when present, so a fixture set can ship
/// its own spacing knobs; a missing file is the normal case and yields defaults.
///
/// Exit status is 0 when every fixture rendered, non-zero when any failed. A fixture
/// that fails to render does not abort the run — the remaining ones are still drawn
/// and the failure is named on stderr, because a gallery that stops at the first
/// problem is useless exactly when it is most needed.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    const fixture_dir_path = if (argv.len > 1) argv[1] else default_fixture_dir;
    const out_dir_path = if (argv.len > 2) argv[2] else default_out_dir;

    const cwd: std.Io.Dir = .cwd();
    var fixtures = cwd.openDir(io, fixture_dir_path, .{ .iterate = true }) catch |err| {
        std.log.err("cannot open fixture directory '{s}': {t}", .{ fixture_dir_path, err });
        return err;
    };
    defer fixtures.close(io);

    // A fixture set may ship its own spacing knobs; absent is the normal case.
    const cfg = try ckt.Config.load(arena, io, fixtures, "lint.zon", null);

    var out = try cwd.createDirPathOpen(io, out_dir_path, .{});
    defer out.close(io);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    const names = try collectFixtures(arena, fixtures);

    var pipeline: ckt.Pipeline = .init(gpa, &cfg);
    defer pipeline.deinit();

    var entries: std.ArrayList(gallery.Entry) = .empty;
    defer entries.deinit(gpa);
    var failures: usize = 0;

    for (names) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, fixture_ext });
        const raw = fixtures.readFileAlloc(io, path, arena, .limited(1 << 22)) catch |err| {
            std.log.err("{s}: cannot read: {t}", .{ name, err });
            failures += 1;
            continue;
        };
        const src = try withRails(arena, raw);

        const entry = renderFixture(&pipeline, arena, out, name, src) catch |err| {
            // A gallery that stops at the first problem is useless exactly when it is
            // most needed, so the remaining fixtures still draw.
            std.log.err("{s}: {t}", .{ name, err });
            failures += 1;
            continue;
        };
        try entries.append(gpa, entry);
        try stdout.print(
            "{s: <28} devices {d: >4}  nets {d: >4}  wires {d: >4}  labels {d: >3}\n",
            .{ entry.name, entry.devices, entry.nets, entry.wires, entry.labels },
        );
    }

    var index_buf: [16 * 1024]u8 = undefined;
    var index_file = try out.createFile(io, "index.html", .{});
    defer index_file.close(io);
    var index_w = index_file.writerStreaming(io, &index_buf);
    try gallery.writeIndex(entries.items, &index_w.interface);
    try index_w.interface.flush();

    try stdout.print("{d} circuits -> {s}/index.html\n", .{ entries.items.len, out_dir_path });
    if (failures > 0) {
        try stdout.print("{d} fixture(s) failed\n", .{failures});
        try stdout.flush();
        return error.FixtureFailed;
    }
}

/// Append the rail devices the placer needs but a SPICE deck does not carry.
///
/// The fixtures reference power and ground as bare net names (`vdd`, `gnd`). Placement
/// anchors a spine on an explicit rail *symbol*, and net classification refuses to infer
/// a rail from a net's name — a net called `vdd` that no supply symbol touches is a
/// signal, deliberately (see `devices/catalog.zig`, `SymbolRole`). So the harness that
/// produced the Rust goldens appends `XVDD vdd vdd` / `XGND gnd gnd` when those names
/// appear, and this does the same thing for the same reason: without it every fixture
/// places as one unanchored blob and the two galleries would not be comparable.
///
/// Returns `src` unchanged when neither name occurs; otherwise a fresh buffer from
/// `arena`, owned by it.
fn withRails(arena: Allocator, src: []const u8) Allocator.Error![]const u8 {
    const has_vdd = hasToken(src, "vdd");
    const has_gnd = hasToken(src, "gnd");
    if (!has_vdd and !has_gnd) return src;
    return std.fmt.allocPrint(arena, "{s}\n{s}{s}", .{
        src,
        if (has_vdd) "XVDD vdd vdd\n" else "",
        if (has_gnd) "XGND gnd gnd\n" else "",
    });
}

/// Does `src` contain `word` as a whole whitespace-delimited token, ignoring case?
///
/// Token-wise rather than a substring search, so a model named `gndcap` does not
/// conjure a ground rail. Matches the Rust harness's `split_whitespace` test exactly.
fn hasToken(src: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, src, " \t\r\n");
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(t, word)) return true;
    }
    return false;
}

/// Render one fixture through `pipeline` and write its SVG into `out_dir`.
///
/// `src` is the fixture's bytes, borrowed for the duration of the call. `name` is the
/// filename stem, used both for the output filename and for the index card heading.
///
/// Returns the `gallery.Entry` describing what was drawn. Its `name` and `svg_path`
/// fields are borrowed from `arena`, so the caller's arena must outlive the
/// `writeIndex` call that consumes them.
///
/// Resets `pipeline` before running, so the caller need not — the reset is part of
/// this function's contract precisely so that a caller cannot forget it and end up
/// reading one fixture's geometry while rendering the next.
///
/// Errors: `OutOfMemory` from placement, or a file error from writing the SVG. A
/// netlist the front end cannot fully represent is *not* an error: it produces a
/// `Report`, whose counts land on the entry so the page can show them.
pub fn renderFixture(
    pipeline: *ckt.Pipeline,
    arena: Allocator,
    out_dir: std.Io.Dir,
    name: []const u8,
    src: []const u8,
) !gallery.Entry {
    // Blocking file I/O needs no thread pool, and a local instance keeps this program
    // free of the process-global state the library itself refuses to carry.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Part of the contract, not the caller's: a caller that forgot would render one
    // fixture's geometry into the next one's file.
    pipeline.reset();
    // Both are borrowed from the pipeline's arenas and die with the next `reset`;
    // nothing here is owned, so nothing here is freed.
    const placed, const report = try pipeline.run(src);

    const svg_path = try std.fmt.allocPrint(arena, "{s}.svg", .{name});

    var buf: [64 * 1024]u8 = undefined;
    var file = try out_dir.createFile(io, svg_path, .{});
    defer file.close(io);
    var fw = file.writerStreaming(io, &buf);
    try svg.write(placed, pipeline.cfg, &fw.interface);
    try fw.interface.flush();

    _, _, const width, const height = svg.viewBox(svg.contentRect(placed), pipeline.cfg.render.pad);
    return .{
        .name = try arena.dupe(u8, name),
        .svg_path = svg_path,
        .width = width,
        .height = height,
        .devices = placed.ir.deviceCount(),
        .nets = placed.ir.netCount(),
        // `seg_pt` is the segment→point CSR, so it carries one entry past the last
        // segment.
        .wires = placed.physical.seg_pt.len -| 1,
        .labels = placed.physical.labels.len,
        .ignored = report.ignored.len,
        .skipped = report.skipped.len,
    };
}

/// Collect the fixture file names in `dir`, sorted.
///
/// Returns the stems (no extension) of every entry ending in `fixture_ext`, allocated
/// from `arena` and owned by it. Sorted with `std.mem.lessThan` so the page order is
/// reproducible: directory iteration order is filesystem-defined and would otherwise
/// reshuffle the gallery between machines, which is the same determinism rule the
/// library follows for hash maps.
///
/// An empty or absent directory yields an empty slice rather than an error; the index
/// then says there was nothing to draw.
pub fn collectFixtures(arena: Allocator, dir: std.Io.Dir) ![]const []const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .directory) continue;
        if (!std.mem.endsWith(u8, e.name, fixture_ext)) continue;
        const stem = e.name[0 .. e.name.len - fixture_ext.len];
        try names.append(arena, try arena.dupe(u8, stem));
    }
    // Directory order is filesystem-defined; sorting is what keeps the page identical
    // between two machines, the same determinism rule the library follows for maps.
    std.mem.sort([]const u8, names.items, {}, lessThanName);
    return names.items;
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
