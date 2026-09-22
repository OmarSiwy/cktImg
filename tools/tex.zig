//! `cktimg-tex`: a SPICE netlist in, a TikZ figure out — what `\write18` or a
//! Makefile drives, and what `latex/cktimg.sty` inputs.
//!
//! The library knows no devices, so this tool brings its own: the symbol set
//! embedded at build time (`tests/symbols.zon`), or `--symbols file.zon`.

const std = @import("std");
const np = @import("NetlistParser");
const default_symbols = @import("symbols").text;

const usage =
    \\cktimg-tex — render a SPICE netlist as a TikZ figure
    \\
    \\Usage: cktimg-tex [options] <netlist.cir> [out.tex]
    \\
    \\Writes a tikzpicture fragment to <out.tex>, or to stdout. Needs tikz and
    \\xcolor, or \usepackage{cktimg}.
    \\
    \\Options:
    \\  --standalone      a complete \documentclass{standalone} document
    \\  --config <path>   layout, render and lint settings from a lint.zon file
    \\  --symbols <path>  device symbols from a .zon symbol file (default: built in)
    \\  --lint            run the lint.zon rules and report on stderr
    \\  -h, --help        this message
    \\
    \\Exit status:
    \\  0  written, and --lint found nothing at "err"
    \\  1  bad command line, netlist, config or symbols; nothing written
    \\  2  written, and --lint found at least one "err"
    \\
;

const Options = struct {
    netlist: []const u8,
    out: ?[]const u8 = null,
    config: ?[]const u8 = null,
    symbols: ?[]const u8 = null,
    standalone: bool = false,
    lint: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd: std.Io.Dir = .cwd();

    const opts = parseArgs(io, try init.minimal.args.toSlice(arena)) orelse return;

    const text = cwd.readFileAlloc(io, opts.netlist, arena, .limited(1 << 22)) catch |err| fatal("cannot read netlist '{s}': {t}", .{ opts.netlist, err });
    // A config named on the command line must exist: it was asked for.
    const cfg: np.Config = if (opts.config) |path| blk: {
        const t = cwd.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| fatal("cannot read config '{s}': {t}", .{ path, err });
        var diags: std.ArrayList(np.config.Diagnostic) = .empty;
        const c = try np.Config.parse(arena, t, &diags);
        for (diags.items) |d| std.log.warn("{s}:{d}: {t} '{s}'", .{ path, d.line, d.kind, d.key });
        break :blk c;
    } else .default;

    var lib = np.Library.init(gpa);
    defer lib.deinit();
    const symbols = if (opts.symbols) |path|
        cwd.readFileAlloc(io, path, arena, .limited(1 << 22)) catch |err| fatal("cannot read symbols '{s}': {t}", .{ path, err })
    else
        default_symbols;
    var sym_diags: std.ArrayList(np.library.ZonDiagnostic) = .empty;
    try lib.loadZon(arena, symbols, &sym_diags);
    for (sym_diags.items) |d| std.log.err("symbols: {s}: {t}", .{ d.class, d.err });
    if (sym_diags.items.len > 0) std.process.exit(1);

    var diag: np.netlist.Diagnostic = .{};
    var placed = np.place(gpa, &cfg, &lib, &.{text}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => fatal("{s}:{d}: {t} near '{s}'", .{ opts.netlist, diag.line, err, diag.token() }),
    };
    defer placed.deinit();

    var buf: [64 * 1024]u8 = undefined;
    const dest: std.Io.File = if (opts.out) |path|
        cwd.createFile(io, path, .{}) catch |err| fatal("cannot create '{s}': {t}", .{ path, err })
    else
        .stdout();
    var dw = dest.writerStreaming(io, &buf);
    const w = &dw.interface;
    if (opts.standalone) try w.writeAll("\\documentclass{standalone}\n\\usepackage[american]{circuitikz}\n\\usepackage{xcolor}\n\\begin{document}\n");
    try np.latex.write(gpa, &placed, &lib, &cfg, w);
    if (opts.standalone) try w.writeAll("\\end{document}\n");
    try w.flush();
    if (opts.out != null) dest.close(io);

    // After the figure, so a failing verdict never costs the drawing.
    if (opts.lint) {
        const findings = try np.lint.check(arena, &placed, &lib, cfg.rules);
        var eb: [4096]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &eb);
        var any_err = false;
        for (findings) |f| {
            np.lint.format(f, &placed, &ew.interface) catch {};
            any_err = any_err or f.severity == .err;
        }
        ew.interface.flush() catch {};
        if (any_err) std.process.exit(2);
    }
}

fn parseArgs(io: std.Io, argv: []const [:0]const u8) ?Options {
    var o: Options = .{ .netlist = "" };
    var have = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            writeUsage(io, .stdout());
            return null;
        } else if (std.mem.eql(u8, a, "--standalone")) {
            o.standalone = true;
        } else if (std.mem.eql(u8, a, "--lint")) {
            o.lint = true;
        } else if (std.mem.eql(u8, a, "--config") or std.mem.eql(u8, a, "--symbols")) {
            i += 1;
            if (i == argv.len) fatalUsage(io, "option needs a path");
            if (a[2] == 'c') o.config = argv[i] else o.symbols = argv[i];
        } else if (a.len > 1 and a[0] == '-') {
            fatalUsage(io, "unknown option; see --help");
        } else if (!have) {
            o.netlist = a;
            have = true;
        } else if (o.out == null) {
            o.out = a;
        } else fatalUsage(io, "too many arguments");
    }
    if (!have) fatalUsage(io, "no netlist given");
    return o;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

fn fatalUsage(io: std.Io, msg: []const u8) noreturn {
    std.log.err("{s}", .{msg});
    writeUsage(io, .stderr());
    std.process.exit(1);
}

fn writeUsage(io: std.Io, file: std.Io.File) void {
    var buf: [512]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    w.interface.writeAll(usage) catch {};
    w.interface.flush() catch {};
}
