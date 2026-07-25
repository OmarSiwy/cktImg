//! `cktimg-tex` — the command line front end for the TikZ emitter.
//!
//! `latex.zig` can write a `tikzpicture`, but a `.tex` document cannot call a Zig
//! function. This file is the missing edge of that graph: bytes in (a SPICE deck), bytes
//! out (a TikZ fragment), so `\write18` or a Makefile can drive the library. It is the
//! whole reason the package in `latex/cktimg.sty` can exist.
//!
//! ## Why an executable and not another library entry point
//!
//! Every LaTeX toolchain already knows how to run a program and `\input` its output. None
//! of them knows how to link a static library. Shipping one small binary per platform is
//! therefore the *only* distribution shape a LaTeX user can consume, which is also why the
//! release workflow cross-compiles it five ways rather than asking anybody to install Zig.
//!
//! ## Data flow and allocation
//!
//! ```
//! argv ──► Options
//! file ──► source bytes ──► Pipeline.run ──► Placed ──► latex.write ──► Writer
//! ```
//!
//! One arena for everything with the process's lifetime (argv, the netlist text, the
//! config), plus the `Pipeline`'s own five arenas for the placement. Nothing is freed
//! individually — the process is short-lived and single-shot, so per-allocation discipline
//! would buy nothing that `arena.deinit()` does not already guarantee. The library itself
//! keeps the stricter rules because it is linked into programs that run for hours; this
//! one runs for milliseconds.
//!
//! Output is streamed straight to the destination `std.Io.File`. A 5,000-device figure is
//! never materialized in memory, which is the property `latex.write` was designed around
//! and would be thrown away by buffering the whole document to pass it along.
//!
//! ## Gated on `latex_renderer`
//!
//! `root.latex` is `void` unless the build option is set, so this file is only added to
//! the build when `-Dlatex_renderer=true`. Referencing it otherwise is a compile error
//! naming the option, which is the intended failure mode.

const std = @import("std");
const ckt = @import("cktimg");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Extension this program expects on an input deck. Only used in the usage text.
pub const netlist_ext = ".spice";

/// What the command line asked for.
///
/// All slices are borrowed from the argv arena and are valid for the whole process.
pub const Options = struct {
    /// The netlist to render. Required; there is no stdin mode, because the `.sty`
    /// always has a path and a pipeline user can name `/dev/stdin`.
    netlist: []const u8,
    /// Where to write. `null` means stdout, so the program composes in a shell pipeline.
    out: ?[]const u8 = null,
    /// Path to a `lint.zon`. `null` means built-in defaults.
    config: ?[]const u8 = null,
    /// Wrap the fragment in a minimal compilable document instead of emitting the bare
    /// `tikzpicture`.
    standalone: bool = false,
};

const usage =
    \\cktimg-tex — render a SPICE netlist as a TikZ figure
    \\
    \\Usage: cktimg-tex [options] <netlist.spice> [out.tex]
    \\
    \\Writes a `tikzpicture` fragment to <out.tex>, or to stdout when no output path
    \\is given. Drop the fragment into a document that loads tikz and xcolor, or
    \\\input it — see the cktimg LaTeX package.
    \\
    \\Options:
    \\  --standalone      wrap the fragment in a complete \documentclass{standalone}
    \\                    document, so it compiles on its own for a quick look
    \\  --config <path>   read layout/render settings from a lint.zon file
    \\  -h, --help        show this message
    \\
    \\Exit status is 0 on success, non-zero if the netlist is missing or unreadable.
    \\
;

/// Parse argv, place the netlist, emit the figure.
///
/// Exit status: 0 when the figure was written, 1 when the command line was malformed or
/// the netlist could not be read. A netlist the front end only partly understands is
/// *not* a failure — it still draws, and the ignored/skipped counts go to stderr as a
/// note, because a partial figure is more useful than a refusal (same policy as
/// `Pipeline.run`).
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(io, argv) orelse return;

    const cwd: std.Io.Dir = .cwd();

    // Read before placing: a missing file is by far the most common failure and it should
    // be named with its path, not surfaced as a bare `error.FileNotFound` from four frames
    // deep. 4 MiB is well past any hand-written deck and stops a stray `/dev/zero`.
    const raw = cwd.readFileAlloc(io, opts.netlist, arena, .limited(1 << 22)) catch |err| {
        std.log.err("cannot read netlist '{s}': {t}", .{ opts.netlist, err });
        std.process.exit(1);
    };

    // Unlike `Config.load`, a *named* config that is absent is an error: the user asked
    // for those settings, and silently rendering with defaults would look like the file
    // was honoured.
    const cfg = if (opts.config) |path| blk: {
        const text = cwd.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
            std.log.err("cannot read config '{s}': {t}", .{ path, err });
            std.process.exit(1);
        };
        break :blk try ckt.Config.parse(arena, text, null);
    } else ckt.Config.default;

    const src = try withRails(arena, raw);

    var pipeline: ckt.Pipeline = .init(gpa, &cfg);
    defer pipeline.deinit();
    const placed, const report = try pipeline.run(src);

    // The fixtures use only builtin symbol classes, and so does anything else this tool
    // is pointed at: `Pipeline.run` owns the host table it builds internally and never
    // hands it out, so an empty table resolves every `SymbolIdx` out of the comptime
    // catalog. This mirrors what the SVG gallery does for the same reason.
    var table: ckt.devices.host.Table = .init(gpa);
    defer table.deinit();

    var buf: [64 * 1024]u8 = undefined;
    const dest: std.Io.File = if (opts.out) |path|
        cwd.createFile(io, path, .{}) catch |err| {
            std.log.err("cannot create '{s}': {t}", .{ path, err });
            std.process.exit(1);
        }
    else
        .stdout();
    var dest_w = dest.writerStreaming(io, &buf);

    try emit(gpa, placed, &table, &cfg, opts.standalone, &dest_w.interface);
    try dest_w.interface.flush();
    // Closed here rather than by `defer` so that stdout — which this process does not own
    // — is left alone. On the error paths above the process is exiting anyway, and the
    // kernel closes it more reliably than a deferred branch would.
    if (opts.out != null) dest.close(io);

    if (report.ignored.len > 0 or report.skipped.len > 0) {
        std.log.warn("{s}: {d} card(s) ignored, {d} skipped", .{
            opts.netlist,
            report.ignored.len,
            report.skipped.len,
        });
    }
}

/// Emit the figure, optionally wrapped in a compilable document.
///
/// `w` receives the bytes and is not flushed here — the caller owns the flush, because it
/// also owns whether the destination is a file to close or stdout to leave alone.
///
/// The standalone wrapper is deliberately the smallest document that can hold the
/// fragment: `standalone` crops to the picture, and `tikz` + `xcolor` are exactly the two
/// packages `latex.write` documents as its requirements. Anything more would be this
/// tool inventing a house style for someone else's paper.
///
/// Errors: `WriteFailed` from `w`, `OutOfMemory` from the two order-dependent layout
/// passes inside `latex.write`.
pub fn emit(
    gpa: Allocator,
    placed: ckt.Placed,
    table: *const ckt.devices.host.Table,
    cfg: *const ckt.Config,
    standalone: bool,
    w: *Writer,
) ckt.latex.Error!void {
    if (standalone) try w.writeAll(
        \\\documentclass{standalone}
        \\\usepackage{tikz}
        \\\usepackage{xcolor}
        \\\begin{document}
        \\
    );
    try ckt.latex.write(gpa, placed, table, cfg, w);
    if (standalone) try w.writeAll("\\end{document}\n");
}

/// Parse `argv`, or print usage and return `null`.
///
/// `null` means "nothing left to do, exit 0" — that is `--help`. A malformed command line
/// exits 1 from inside, because there is no useful value to return and every caller would
/// only forward the failure.
///
/// The first non-option argument is the netlist, the second is the output path, and a
/// third is an error rather than being ignored: silently dropping an argument is how a
/// user ends up wondering why their `--config` never applied.
///
/// `io` is only used to print the usage text; it is a parameter rather than a global for
/// the same reason `Config` is (docs/CONVENTIONS.md, "no hidden control flow").
///
/// Returned slices are borrowed from `argv`.
pub fn parseArgs(io: std.Io, argv: []const [:0]const u8) ?Options {
    var netlist: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var config: ?[]const u8 = null;
    var standalone = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            writeUsage(io, .stdout());
            return null;
        } else if (std.mem.eql(u8, a, "--standalone")) {
            standalone = true;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i == argv.len) fatalUsage(io, "--config needs a path");
            config = argv[i];
        } else if (a.len > 1 and a[0] == '-') {
            std.log.err("unknown option '{s}'", .{a});
            fatalUsage(io, "see --help");
        } else if (netlist == null) {
            netlist = a;
        } else if (out == null) {
            out = a;
        } else {
            fatalUsage(io, "too many arguments");
        }
    }

    const n = netlist orelse fatalUsage(io, "no netlist given");
    return .{ .netlist = n, .out = out, .config = config, .standalone = standalone };
}

/// Name the problem on stderr, print the usage, exit 1.
fn fatalUsage(io: std.Io, msg: []const u8) noreturn {
    std.log.err("{s}", .{msg});
    writeUsage(io, .stderr());
    std.process.exit(1);
}

/// Print the usage text to `file`, ignoring write failures — there is nowhere left to
/// report a failure to write the error message itself.
fn writeUsage(io: std.Io, file: std.Io.File) void {
    var buf: [512]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    w.interface.writeAll(usage) catch {};
    w.interface.flush() catch {};
}

/// Append the rail devices the placer needs but a SPICE deck does not carry.
///
/// Decks reference power and ground as bare net names (`vdd`, `gnd`). Placement anchors a
/// spine on an explicit rail *symbol*, and net classification refuses to infer a rail from
/// a net's name — a net called `vdd` that no supply symbol touches is a signal,
/// deliberately (see `devices/catalog.zig`, `SymbolRole`). Without this, every deck places
/// as one unanchored blob.
///
/// Returns `src` unchanged when neither name occurs; otherwise a fresh buffer from
/// `arena`, owned by it.
///
/// This is a near-copy of the gallery's `withRails`, and deliberately so: the gallery's
/// standing constraint is that it imports nothing but the public API, and promoting a
/// fixture-shaped input fix-up into that API would make it a supported library behaviour
/// nobody asked for. Fifteen duplicated lines are cheaper than that promise.
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
/// Token-wise rather than a substring search, so a model named `gndcap` does not conjure a
/// ground rail.
fn hasToken(src: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, src, " \t\r\n");
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(t, word)) return true;
    }
    return false;
}
