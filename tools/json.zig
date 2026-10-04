//! `cktimg-json`: a SPICE netlist in, the placed schematic as one JSON
//! document out (`src/json.zig` has the shape), for a script that would
//! rather read a file than link the library.
//!
//!     cktimg-json [--config lint.zon] [--target manifest.json] [--svg out.svg] deck.spice [out.json]
//!
//! The symbol set is the tests' (`tests/symbols.zon`), embedded at build
//! time. `--target` adds a `"target"` block that maps each device's class to
//! the backend's symbol and pin order (docs/TARGETS.md); `--svg` also draws
//! the placement, headless, with the gallery's renderer.
//!
//! Two things a subcircuit library file needs and SPICE does not give it:
//! a file whose first line is `.subckt` has no title line, so the file name
//! is used as one; and a deck with no top-level devices draws the body of
//! its last `.subckt` (the top cell), its ports as nets and its instances as
//! blocks.

const std = @import("std");
const np = @import("NetlistParser");
const symbols = @import("symbols").text;
const svg = @import("svg");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;

const usage =
    \\cktimg-json — place a SPICE netlist and write the geometry as JSON
    \\
    \\Usage: cktimg-json [options] <netlist.spice> [out.json]
    \\
    \\Options:
    \\  --config <path>   layout settings and lint severities from a lint.zon file
    \\  --target <path>   map classes to a backend's symbols (docs/TARGETS.md) and
    \\                    add a "target" block to the document
    \\  --svg <path>      also draw the placed schematic as SVG
    \\  -h, --help        this message
    \\
    \\Exit status: 0 written; 1 bad command line, netlist, config or manifest
    \\(nothing written).
    \\
;

const Options = struct {
    netlist: []const u8,
    out: ?[]const u8 = null,
    config: ?[]const u8 = null,
    target: ?[]const u8 = null,
    svg: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd: std.Io.Dir = .cwd();

    const opts = parseArgs(try init.minimal.args.toSlice(arena)) orelse return;

    const raw = cwd.readFileAlloc(io, opts.netlist, arena, .limited(1 << 22)) catch |err| fatal("cannot read netlist '{s}': {t}", .{ opts.netlist, err });
    const cfg: np.Config = if (opts.config) |path| blk: {
        const t = cwd.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| fatal("cannot read config '{s}': {t}", .{ path, err });
        var diags: std.ArrayList(np.config.Diagnostic) = .empty;
        const c = try np.Config.parse(arena, t, &diags);
        for (diags.items) |d| std.log.warn("{s}:{d}: {t} '{s}'", .{ path, d.line, d.kind, d.key });
        break :blk c;
    } else .default;
    // Read before placing: a manifest typo is reported before any work.
    const target: ?Target = if (opts.target) |path| blk: {
        const t = cwd.readFileAlloc(io, path, arena, .limited(1 << 22)) catch |err| fatal("cannot read target manifest '{s}': {t}", .{ path, err });
        break :blk Target.parse(arena, t) catch fatal("{s}: {s}", .{ path, Target.why });
    } else null;

    var lib = np.Library.init(gpa);
    defer lib.deinit();
    var sym_diags: std.ArrayList(np.library.ZonDiagnostic) = .empty;
    try lib.loadZon(arena, symbols, &sym_diags);
    if (sym_diags.items.len > 0) fatal("symbols: {s}: {t}", .{ sym_diags.items[0].class, sym_diags.items[0].err });

    var diag: np.netlist.Diagnostic = .{};
    const srcs = deckSources(gpa, arena, opts.netlist, raw, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => fatal("{s}:{d}: {t} near '{s}'", .{ opts.netlist, diag.line, err, diag.token() }),
    };
    var placed = np.place(gpa, &cfg, &lib, srcs, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => fatal("{s}:{d}: {t} near '{s}'", .{ opts.netlist, diag.line, err, diag.token() }),
    };
    defer placed.deinit();

    if (opts.svg) |path| {
        const pic = try svg.alloc(gpa, &placed, &lib, .{});
        defer gpa.free(pic);
        cwd.writeFile(io, .{ .sub_path = path, .data = pic }) catch |err| fatal("cannot write '{s}': {t}", .{ path, err });
    }

    // The rails and ports the layout added have no name; a consumer that
    // keys symbols by name needs one.
    const names = try arena.alloc([:0]const u8, placed.deviceCount());
    for (names, placed.dev_name, placed.dev_class, 0..) |*n, old, c, d| {
        n.* = if (old.len > 0) old else try std.fmt.allocPrintSentinel(arena, "_{s}{d}", .{ lib.at(c).name, d }, 0);
    }
    placed.dev_name = names;

    // Resolved before a byte is written, so a refusal leaves no half file.
    const block: ?[]u8 = if (target) |t| t.block(arena, &placed, &lib) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => fatal("{s}: {s}", .{ opts.target.?, Target.why }),
    } else null;

    var aw: Writer.Allocating = .init(arena);
    try np.json.write(&placed, &lib, &aw.writer);
    var doc = aw.written();
    if (block) |b| {
        // `json.write` ends the document with "\n}\n": add one member before it.
        doc = try std.mem.concat(arena, u8, &.{ doc[0 .. doc.len - 3], ",\n  \"target\": ", b, "\n}\n" });
    }
    if (opts.out) |path| {
        cwd.writeFile(io, .{ .sub_path = path, .data = doc }) catch |err| fatal("cannot write '{s}': {t}", .{ path, err });
    } else {
        var buf: [64 * 1024]u8 = undefined;
        var sw = std.Io.File.stdout().writerStreaming(io, &buf);
        try sw.interface.writeAll(doc);
        try sw.interface.flush();
    }
}

/// The sources to place for deck `raw` (see the module comment): itself, or
/// its top cell's body followed by the deck for the definitions.
fn deckSources(gpa: Allocator, arena: Allocator, path: []const u8, raw: []const u8, diag: *np.netlist.Diagnostic) ![]const []const u8 {
    const first = std.mem.trimStart(u8, raw, " \t\r\n");
    const text = if (std.ascii.startsWithIgnoreCase(first, ".subckt")) try std.fmt.allocPrint(arena, "{s}\n{s}", .{ path, raw }) else raw;
    var nl = try np.netlist.parse(gpa, &.{text}, diag);
    defer nl.deinit(gpa);
    if (nl.graph.edgeCount() > 0 or nl.defs.len == 0) return try arena.dupe([]const u8, &.{text});
    const top = nl.defs[nl.defs.len - 1];
    const title_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const body = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ text[0..title_end], top.body });
    return try arena.dupe([]const u8, &.{ body, text[@min(title_end + 1, text.len)..] });
}

/// A target manifest (docs/TARGETS.md): class → the backend's symbol and
/// the order it wants the pins in.
const Target = struct {
    root: std.json.ObjectMap,
    classes: std.json.ObjectMap,
    /// `unmapped.mode`.
    mode: enum { box, skip, @"error" },

    /// The reason for the last `error.Bad`, for the message.
    var why: []const u8 = "";
    var why_buf: [256]u8 = undefined;

    fn bad(comptime fmt: []const u8, args: anytype) error{Bad} {
        why = std.fmt.bufPrint(&why_buf, fmt, args) catch &why_buf;
        return error.Bad;
    }

    fn parse(arena: Allocator, text: []const u8) !Target {
        const root = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| return bad("malformed JSON ({t})", .{err});
        if (root != .object) return bad("top level must be an object", .{});
        const o = root.object;
        if (o.get("target") == null or o.get("target").? != .string) return bad("\"target\" must be a string", .{});
        const v = o.get("version") orelse return bad("missing \"version\"", .{});
        if (v != .integer or v.integer != 1) return bad("\"version\" must be 1", .{});
        const u = o.get("unmapped") orelse return bad("missing \"unmapped\"", .{});
        if (u != .object) return bad("\"unmapped\" must be an object", .{});
        const m = u.object.get("mode") orelse return bad("\"unmapped\" has no \"mode\"", .{});
        const mode = if (m == .string) std.meta.stringToEnum(@FieldType(Target, "mode"), m.string) else null;
        if (mode == null) return bad("\"unmapped.mode\" must be box, skip or error", .{});
        if (mode.? == .box) try checkEntry("unmapped", u);
        const c = o.get("classes") orelse return bad("missing \"classes\"", .{});
        if (c != .object) return bad("\"classes\" must be an object", .{});
        var it = c.object.iterator();
        while (it.next()) |e| try checkEntry(e.key_ptr.*, e.value_ptr.*);
        return .{ .root = o, .classes = c.object, .mode = mode.? };
    }

    fn checkEntry(key: []const u8, e: Value) !void {
        if (e != .object) return bad("class \"{s}\" must be an object", .{key});
        const s = e.object.get("sym") orelse return bad("class \"{s}\" has no \"sym\"", .{key});
        if (s != .string or s.string.len == 0) return bad("class \"{s}\": \"sym\" must be a non-empty string", .{key});
        if (e.object.get("pins")) |p| {
            if (p != .array) return bad("class \"{s}\": \"pins\" must be an array of terminal names", .{key});
            for (p.array.items) |t| if (t != .string) return bad("class \"{s}\": \"pins\" must be an array of terminal names", .{key});
        }
    }

    /// The mapping for `class`: by its name, or for a subcircuit block
    /// (`block:<name>`) by the subcircuit's name.
    fn lookup(t: *const Target, class: []const u8) ?Value {
        if (t.classes.get(class)) |e| return e;
        if (std.mem.startsWith(u8, class, "block:")) return t.classes.get(class["block:".len..]);
        return null;
    }

    /// The `"target"` member's value for `p`. Fails when `unmapped` is
    /// `error` and a class has no mapping, or a `pins` list is not a
    /// permutation of that class's terminals.
    fn block(t: *const Target, arena: Allocator, p: *const np.Placed, lib: *const np.Library) ![]u8 {
        var aw: Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.beginObject();
        try s.objectField("name");
        try s.write(t.root.get("target").?);
        try s.objectField("version");
        try s.write(1);
        inline for (.{ "units", "style" }) |k| if (t.root.get(k)) |v| {
            try s.objectField(k);
            try s.write(v);
        };
        try s.objectField("devices");
        try s.beginArray();
        for (0..p.deviceCount()) |d| {
            const class = lib.at(p.dev_class[d]);
            const entry = t.lookup(class.name) orelse switch (t.mode) {
                .box => t.root.get("unmapped").?,
                .skip => continue,
                .@"error" => return bad("no mapping for class \"{s}\", and \"unmapped\" is \"error\"", .{class.name}),
            };
            // The pins the document lists: one per class terminal the card has.
            const lo, const hi = p.pinRange(d);
            const n = @min(hi - lo, class.terminals.len);
            const order = try arena.alloc(usize, n);
            for (order, 0..) |*o, k| o.* = k;
            if (entry.object.get("pins")) |pins| {
                if (pins.array.items.len != n) return bad("class \"{s}\": \"pins\" has {d} names, the class has {d} terminals", .{ class.name, pins.array.items.len, n });
                for (pins.array.items, order, 0..) |name, *o, j| {
                    o.* = for (class.terminals[0..n], 0..) |term, k| {
                        if (std.mem.eql(u8, term.name, name.string)) break k;
                    } else return bad("class \"{s}\": \"{s}\" is not one of its terminals", .{ class.name, name.string });
                    for (order[0..j]) |earlier| if (earlier == o.*) return bad("class \"{s}\": \"{s}\" is listed twice", .{ class.name, name.string });
                }
            }
            try s.beginObject();
            try s.objectField("device");
            try s.write(d);
            try s.objectField("name");
            try s.write(p.dev_name[d]);
            try s.objectField("class");
            try s.write(class.name);
            try s.objectField("sym");
            try s.write(entry.object.get("sym").?);
            if (entry.object.get("style")) |st| {
                try s.objectField("style");
                try s.write(st);
            }
            try s.objectField("pins");
            try s.write(order);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        return aw.written();
    }
};

fn parseArgs(argv: []const [:0]const u8) ?Options {
    var opts: Options = .{ .netlist = "" };
    var positional: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return null;
        }
        const slot: ?*?[]const u8 = if (std.mem.eql(u8, a, "--config")) &opts.config else if (std.mem.eql(u8, a, "--target")) &opts.target else if (std.mem.eql(u8, a, "--svg")) &opts.svg else null;
        if (slot) |s| {
            i += 1;
            if (i >= argv.len) fatal("{s} needs a path", .{a});
            s.* = argv[i];
        } else if (a.len > 1 and a[0] == '-') {
            fatal("unknown option '{s}'\n{s}", .{ a, usage });
        } else {
            switch (positional) {
                0 => opts.netlist = a,
                1 => opts.out = a,
                else => fatal("too many arguments\n{s}", .{usage}),
            }
            positional += 1;
        }
    }
    if (positional == 0) fatal("no netlist\n{s}", .{usage});
    return opts;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

test "target: a manifest maps classes and subcircuits, and pins are checked" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lib = np.Library.init(gpa);
    defer lib.deinit();
    try lib.loadZon(arena, symbols, null);
    var placed = try np.place(gpa, &.default, &lib, &.{
        \\t
        \\.subckt amp in out vdd
        \\R1 vdd out 1k
        \\M1 out in 0 0 nch
        \\.ends
        \\V1 vdd 0 1
        \\X1 a b vdd amp
        \\R2 b 0 1k
        \\R3 a vdd 1k
    }, null);
    defer placed.deinit();

    const t = try Target.parse(arena,
        \\{ "target": "t", "version": 1, "units": { "scale": 2 }, "unmapped": { "mode": "skip" },
        \\  "classes": { "res": { "sym": "r.sym", "pins": ["b", "a"] }, "amp": { "sym": "amp.sym", "style": { "k": 1 } } } }
    );
    const out = try t.block(arena, &placed, &lib);
    const doc = try std.json.parseFromSliceLeaky(Value, arena, out, .{});
    try std.testing.expectEqual(2, doc.object.get("units").?.object.get("scale").?.integer);
    var amp = false;
    var res: usize = 0;
    for (doc.object.get("devices").?.array.items) |e| {
        const sym = e.object.get("sym").?.string;
        const pins = e.object.get("pins").?.array.items;
        if (std.mem.eql(u8, sym, "amp.sym")) {
            amp = true;
            try std.testing.expectEqualStrings("block:amp", e.object.get("class").?.string);
            try std.testing.expectEqual(3, pins.len);
        } else {
            try std.testing.expectEqualStrings("r.sym", sym);
            try std.testing.expectEqual(1, pins[0].integer);
            res += 1;
        }
    }
    try std.testing.expect(amp);
    try std.testing.expectEqual(2, res); // nothing else is mapped: skipped

    try std.testing.expectError(error.Bad, Target.parse(arena, "{ \"target\": \"t\", \"version\": 2, \"unmapped\": { \"mode\": \"skip\" }, \"classes\": {} }"));
    try std.testing.expectError(error.Bad, Target.parse(arena, "{ \"target\": \"t\", \"version\": 1, \"unmapped\": { \"mode\": \"box\" }, \"classes\": {} }"));
    const wrong = try Target.parse(arena, "{ \"target\": \"t\", \"version\": 1, \"unmapped\": { \"mode\": \"skip\" }, \"classes\": { \"res\": { \"sym\": \"r\", \"pins\": [\"a\", \"x\"] } } }");
    try std.testing.expectError(error.Bad, wrong.block(arena, &placed, &lib));
    const strict = try Target.parse(arena, "{ \"target\": \"t\", \"version\": 1, \"unmapped\": { \"mode\": \"error\" }, \"classes\": {} }");
    try std.testing.expectError(error.Bad, strict.block(arena, &placed, &lib));
}

test "deck: a subcircuit file draws its top cell" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: np.netlist.Diagnostic = .{};
    const srcs = try deckSources(gpa, arena, "cell.spice",
        \\.subckt inv in out vdd vss
        \\XM1 out in vss vss sky130_fd_pr__nfet_01v8 W=1 L=0.15
        \\XM2 out in vdd vdd sky130_fd_pr__pfet_01v8 W=2 L=0.15
        \\.ends inv
        \\.subckt buf in out vdd vss
        \\X1 in mid vdd vss inv
        \\X2 mid out vdd vss inv
        \\.ends buf
    , &diag);
    var nl = try np.netlist.parse(gpa, srcs, &diag);
    defer nl.deinit(gpa);
    try std.testing.expectEqualStrings("cell.spice", nl.title);
    try std.testing.expectEqual(2, nl.graph.edgeCount()); // buf's x1, x2 as blocks
    try std.testing.expectEqualStrings("inv", nl.defOf(nl.device("x1").?).?.name);
}
