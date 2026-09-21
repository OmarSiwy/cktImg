//! `cktimg-json` — the command line front end for the structured export.
//!
//! `json.zig` calls itself "the seam for every tool that post-processes geometry", but a
//! Python script cannot call a Zig function any more than a `.tex` document can. This
//! file is the missing edge of that graph, exactly as `tex_main.zig` is for TikZ: bytes
//! in (a SPICE deck), bytes out (the placed schematic as JSON), so a Makefile or an
//! interpreter can drive the library without linking it.
//!
//! ## Why an executable and not the C ABI
//!
//! `cktimg_run_json` already exists and is the right call for a C consumer. It is the
//! wrong shape for everyone else: a Python, Tcl or shell consumer would need an FFI
//! binding, a build step and a copy of the static library to reach a function whose
//! entire contract is "text in, text out". One binary on `$PATH` costs those consumers
//! nothing and costs this repository forty lines.
//!
//! The first such consumer is an xschem `.sch` emitter — schematic-editor formats are
//! narrow, quirky and change on someone else's schedule, which is precisely the kind of
//! knowledge that should live in a script next to the flow that needs it rather than in
//! the placement engine.
//!
//! ## Not gated on a build option
//!
//! Unlike `tex_main.zig`, this front end is always built. `root.json` is a real module
//! regardless of build options — only `root.latex` is `void` without its flag — so there
//! is no configuration in which compiling this file fails.
//!
//! ## Data flow and allocation
//!
//! ```
//! argv ──► Options
//! file ──► source bytes ──► Pipeline.run ──► Placed ──► json.writeWith ──► Writer
//! ```
//!
//! One arena for everything with the process's lifetime, plus the `Pipeline`'s own
//! arenas. Output streams straight to the destination and is never materialized — the
//! property `json.zig` was written around, and the reason this is not a thin wrapper over
//! `cktimg_run_json`, which allocates the whole document as a string.

const std = @import("std");
const ckt = @import("cktimg");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What the command line asked for.
///
/// All slices are borrowed from the argv arena and are valid for the whole process.
pub const Options = struct {
    /// The netlist to place. Required; a pipeline user can name `/dev/stdin`.
    netlist: []const u8,
    /// Where to write. `null` means stdout, so the program composes in a shell pipeline.
    out: ?[]const u8 = null,
    /// Path to a `lint.zon`. `null` means built-in defaults.
    config: ?[]const u8 = null,
};

const usage =
    \\cktimg-json — place a SPICE netlist and emit the geometry as JSON
    \\
    \\Usage: cktimg-json [options] <netlist.spice> [out.json]
    \\
    \\Writes the placed schematic to <out.json>, or to stdout when no output path is
    \\given. The document carries devices (class, position, orientation, pins), nets,
    \\routed wire polylines, junction dots and labels — see src/json.zig for the schema.
    \\
    \\Options:
    \\  --config <path>   read layout settings from a lint.zon file
    \\  -h, --help        show this message
    \\
    \\Exit status is 0 on success, non-zero if the netlist is missing or unreadable.
    \\
;

/// Parse argv, place the netlist, emit the document.
///
/// Exit status: 0 when the document was written, 1 when the command line was malformed or
/// the netlist could not be read. A netlist the front end only partly understands is
/// *not* a failure — it still places, and the ignored/skipped counts go to stderr as a
/// note, because partial geometry is more useful than a refusal (same policy as
/// `Pipeline.run` and `cktimg-tex`).
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
    // be named with its path. 4 MiB is well past any hand-written deck.
    const raw = cwd.readFileAlloc(io, opts.netlist, arena, .limited(1 << 22)) catch |err| {
        std.log.err("cannot read netlist '{s}': {t}", .{ opts.netlist, err });
        std.process.exit(1);
    };

    // A *named* config that is absent is an error: the user asked for those settings, and
    // silently placing with defaults would look like the file was honoured.
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

    // An empty host table, for the reason `cktimg-tex` gives: `Pipeline.run` owns the
    // table it builds internally and never hands it out, so every `SymbolIdx` that
    // reaches here resolves out of the comptime catalog. `writeWith` rather than `write`
    // because it degrades by lookup rather than by assert if that ever stops holding.
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

    try ckt.json.writeWith(placed, &table, &cfg, &dest_w.interface);
    try dest_w.interface.flush();
    // Closed here rather than by `defer` so that stdout — which this process does not own
    // — is left alone.
    if (opts.out != null) dest.close(io);

    if (report.ignored.len > 0 or report.skipped.len > 0) {
        std.log.warn("{s}: {d} card(s) ignored, {d} skipped", .{
            opts.netlist,
            report.ignored.len,
            report.skipped.len,
        });
    }
}

/// Parse `argv`, or print usage and return `null`.
///
/// `null` means "nothing left to do, exit 0" — that is `--help`. A malformed command line
/// exits 1 from inside, because there is no useful value to return.
///
/// The first non-option argument is the netlist, the second is the output path, and a
/// third is an error rather than being ignored.
///
/// Returned slices are borrowed from `argv`.
pub fn parseArgs(io: std.Io, argv: []const [:0]const u8) ?Options {
    var netlist: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var config: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            writeUsage(io, .stdout());
            return null;
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
    return .{ .netlist = n, .out = out, .config = config };
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
/// See `tex_main.withRails` for why this exists. It is duplicated here for the reason
/// given there: promoting an input fix-up into the public API would make it a supported
/// library behaviour nobody asked for. The copy is load-bearing rather than incidental —
/// omitting it would make `cktimg-json` report *different geometry* for the same deck
/// than `cktimg-tex` and the gallery draw, which is a far worse bug than the duplication.
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
/// Token-wise rather than a substring search, so a model named `gndcap` does not conjure a
/// ground rail.
fn hasToken(src: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, src, " \t\r\n");
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(t, word)) return true;
    }
    return false;
}
