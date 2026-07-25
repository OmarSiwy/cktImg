//! Behavioral suite for the netlist front end.
//!
//! Each test is named after the property it pins, not the function it calls. They are
//! written against the documented contract, including the parts a naive implementation
//! would get away with: that token spans point *into* the source buffer rather than at
//! copies, that case folding has not happened yet at tokenize time, that `1meg` and `1m`
//! differ by nine orders of magnitude, that net `0` survives flattening unscoped, and that
//! two parses of the same bytes assign identical `StrId`s in identical order.

const std = @import("std");
const ckt = @import("cktimg");

const source = ckt.netlist.source;
const token = ckt.netlist.token;
const card = ckt.netlist.card;
const expr = ckt.netlist.expr;
const flatten = ckt.netlist.flatten;
const catalog = ckt.devices.catalog;
const host = ckt.devices.host;

const Source = source.Source;
const Tokens = token.Tokens;
const LineIdx = token.LineIdx;
const TokIdx = token.TokIdx;
const Interner = ckt.strings.Interner;
const Note = ckt.ir.Note;
const Reason = Note.Reason;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// The symbol table the fixtures classify against.
///
/// Every class these fixtures name is a builtin, so the table starts empty and resolution
/// falls through to the catalog. This used to pre-register a list of host classes, back when
/// the catalog held only twelve specimen entries; once the full table was generated those
/// names became builtins and registering them was correctly rejected as `ShadowsBuiltin`.
///
/// The one class registered here is deliberate: a fixture that resolves *only* builtins would
/// never exercise the host path, and the front end must reach both through the same lookup.
/// `hostwidget` is a name no builtin can collide with, which is the point — a host class is
/// for symbols the catalog does not have.
fn testSymbols(gpa: std.mem.Allocator) !host.Table {
    var t = host.Table.init(gpa);
    errdefer t.deinit();
    _ = try t.register(.{ .name = "hostwidget", .terminals = catalog.two });
    return t;
}

/// An in-memory loader, so include tests need no filesystem.
const FileMap = struct {
    const Entry = struct { path: []const u8, text: []const u8 };
    entries: []const Entry,

    fn read(
        ctx: *const anyopaque,
        gpa: std.mem.Allocator,
        path: []const u8,
    ) std.mem.Allocator.Error!?[]u8 {
        const self: *const FileMap = @ptrCast(@alignCast(ctx));
        const want = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.path, want)) return try gpa.dupe(u8, e.text);
        }
        return null;
    }

    fn loader(self: *const FileMap) source.Loader {
        return .{ .ctx = self, .readFn = &FileMap.read };
    }
};

/// Tokenizer + classifier wired over one in-memory deck.
///
/// A struct with an in-place `init` because the classifier holds a pointer to the token
/// table, so both must live at a stable address.
const Harness = struct {
    gpa: std.mem.Allocator,
    it: Interner,
    symbols: host.Table,
    src: Source,
    toks: Tokens,
    models: card.Models,
    cl: card.Classifier,

    fn init(self: *Harness, gpa: std.mem.Allocator, text: []const u8) !void {
        self.gpa = gpa;
        self.it = try Interner.init(gpa);
        self.symbols = try testSymbols(gpa);
        self.src = try Source.fromText(gpa, &self.it, text);
        self.toks = try token.tokenize(gpa, self.src.text());
        self.models = try card.Models.collect(gpa, &self.it, self.toks);
        self.cl = .{
            .toks = &self.toks,
            .symbols = &self.symbols,
            .cfg = &ckt.Config.default,
            .models = self.models,
            .subs = &.{},
            .interner = &self.it,
        };
    }

    fn deinit(self: *Harness) void {
        self.cl.deinit(self.gpa);
        self.models.deinit(self.gpa);
        self.toks.deinit(self.gpa);
        self.src.deinit(self.gpa);
        self.symbols.deinit();
        self.it.deinit(self.gpa);
    }

    fn classify(self: *Harness, line: u32) !card.Card {
        return self.cl.classify(self.gpa, LineIdx.at(line));
    }

    fn nodeText(self: *const Harness, c: card.Card, k: usize) []const u8 {
        return self.toks.text(c.nodes[k]);
    }

    fn className(self: *const Harness, c: card.Card) []const u8 {
        return self.symbols.at(c.symbol).name;
    }
};

fn tokText(t: Tokens, line: u32, k: u32) []const u8 {
    return t.text(t.tok(LineIdx.at(line), k).?);
}

fn countReason(notes: []const Note, r: Reason) usize {
    var n: usize = 0;
    for (notes) |note| {
        if (note.reason == r) n += 1;
    }
    return n;
}

fn hasReason(notes: []const Note, r: Reason) bool {
    return countReason(notes, r) > 0;
}

fn occurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| : (i = at + needle.len) n += 1;
    return n;
}

/// Net name attached to pin `p` of device `d`.
fn netNameOf(b: flatten.Built, d: usize, k: u32) []const u8 {
    const first = b.ir.dev_pin0[d];
    const net = b.ir.pin_net[first + k];
    return b.strings.get(b.ir.net_name[net.i()]);
}

// ---------------------------------------------------------------------------
// source.zig — include expansion and offset mapping
// ---------------------------------------------------------------------------

test "an include splices its file into the one source arena" {
    const gpa = std.testing.allocator;
    const map = FileMap{ .entries = &.{
        .{ .path = "rc.sp", .text = "R1 in out 1k\nC1 out 0 1u\n" },
    } };

    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(gpa);

    var src = try Source.expand(
        gpa,
        &it,
        "deck.sp",
        "V1 in 0 dc 5\n.include rc.sp\nR9 z 0 9k\n",
        map.loader(),
        &notes,
    );
    defer src.deinit(gpa);
    src.assertValid();

    const text = src.text();
    // Root text, then the include's contents, then the rest of the root — in that order,
    // in one buffer, with the directive line itself gone.
    try expectEqualStrings("V1 in 0 dc 5\nR1 in out 1k\nC1 out 0 1u\nR9 z 0 9k\n", text);
    try expect(std.mem.indexOf(u8, text, ".include") == null);
    try expectEqual(@as(usize, 0), notes.items.len);
    // Root before, include, root after: three segments.
    try expectEqual(@as(usize, 3), src.segmentCount());
}

test "an arena offset maps back to the file and line that produced it" {
    const gpa = std.testing.allocator;
    const map = FileMap{ .entries = &.{
        .{ .path = "rc.sp", .text = "R1 in out 1k\nC1 out 0 1u\n" },
    } };

    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(gpa);

    var src = try Source.expand(
        gpa,
        &it,
        "deck.sp",
        "V1 in 0 dc 5\n.include rc.sp\nR9 z 0 9k\n",
        map.loader(),
        &notes,
    );
    defer src.deinit(gpa);

    const text = src.text();

    const at_v1: u32 = @intCast(std.mem.indexOf(u8, text, "V1").?);
    const v1 = src.locate(at_v1);
    try expectEqualStrings("deck.sp", it.get(v1.file));
    try expectEqual(@as(u32, 1), v1.line);
    try expectEqual(@as(u32, 1), v1.col);

    // Second line of the *included* file, not of the concatenation.
    const at_c1: u32 = @intCast(std.mem.indexOf(u8, text, "C1").?);
    const c1 = src.locate(at_c1);
    try expectEqualStrings("rc.sp", it.get(c1.file));
    try expectEqual(@as(u32, 2), c1.line);

    // Back in the root, on the line after the directive — the directive still counts.
    const at_r9: u32 = @intCast(std.mem.indexOf(u8, text, "R9").?);
    const r9 = src.locate(at_r9);
    try expectEqualStrings("deck.sp", it.get(r9.file));
    try expectEqual(@as(u32, 3), r9.line);

    try expectEqualStrings("C1 out 0 1u", src.lineText(at_c1));
}

test "lib section extraction takes only the named block" {
    const lib =
        ".lib tt\nR1 a b 1k\n.endl\n.lib ff\nR1 a b 0.5k\n.endl\n";
    const ff = Source.extractSection(lib, "ff").?;
    try expect(std.mem.indexOf(u8, ff, "0.5k") != null);
    try expect(std.mem.indexOf(u8, ff, "1k\n") == null);
    // Case-insensitive, per SPICE convention.
    try expect(Source.extractSection(lib, "TT") != null);
    try expect(Source.extractSection(lib, "sf") == null);
    // Markers never survive into the extracted text.
    try expect(std.mem.indexOf(u8, ff, ".endl") == null);
}

test "a missing include is reported and the rest of the deck survives" {
    const gpa = std.testing.allocator;
    const map = FileMap{ .entries = &.{} };

    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(gpa);

    var src = try Source.expand(
        gpa,
        &it,
        "deck.sp",
        ".include gone.sp\nR1 a b 1k\n",
        map.loader(),
        &notes,
    );
    defer src.deinit(gpa);

    try expect(std.mem.indexOf(u8, src.text(), "R1 a b 1k") != null);
    try expectEqual(@as(usize, 1), notes.items.len);
    try expectEqual(Reason.include_not_found, notes.items[0].reason);
}

test "an include cycle is reported once and does not recurse" {
    const gpa = std.testing.allocator;
    const map = FileMap{ .entries = &.{
        .{ .path = "a.sp", .text = ".include b.sp\n" },
        .{ .path = "b.sp", .text = ".include a.sp\nR1 a b 1k\n" },
    } };

    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(gpa);

    var src = try Source.expand(gpa, &it, "deck.sp", ".include a.sp\n", map.loader(), &notes);
    defer src.deinit(gpa);

    // Exactly once: the cycle is cut, not unrolled.
    try expectEqual(@as(usize, 1), occurrences(src.text(), "R1 a b 1k"));
    try expectEqual(@as(usize, 1), countReason(notes.items, .include_cycle));
}

// ---------------------------------------------------------------------------
// token.zig — assembly, comments, dialect
// ---------------------------------------------------------------------------

test "continuation lines fold into one logical card" {
    const gpa = std.testing.allocator;
    const src =
        "* title comment\n" ++
        "R1 a b 1k $ inline ngspice comment\n" ++
        "M1 d g s b\n" ++
        "+ nmos\n" ++
        ".tran 1n 1u\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);
    toks.assertValid();

    // Three statements: R1, the folded M1, .tran. The `*` line is not a statement.
    try expectEqual(@as(usize, 3), toks.lineCount());

    try expectEqual(@as(u32, 4), toks.count(LineIdx.at(0)));
    try expectEqualStrings("R1", tokText(toks, 0, 0));
    try expectEqualStrings("1k", tokText(toks, 0, 3));

    // The continuation's tokens belong to the statement it continues, and the leading `+`
    // is not one of them.
    try expectEqual(@as(u32, 6), toks.count(LineIdx.at(1)));
    try expectEqualStrings("M1", tokText(toks, 1, 0));
    try expectEqualStrings("nmos", tokText(toks, 1, 5));

    try expect(toks.headIs(LineIdx.at(2), ".tran"));

    // The folded statement's span reaches across both physical lines.
    const off, const len = toks.lineSpan(LineIdx.at(1));
    try expect(std.mem.indexOf(u8, src[off .. off + len], "nmos") != null);
}

test "token spans point into the source buffer, never at a copy" {
    const gpa = std.testing.allocator;
    const src = "R1 in out 1k\nC1 out 0 1u\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);

    const lo = @intFromPtr(src.ptr);
    const hi = lo + src.len;
    try expect(toks.tokenCount() > 0);

    var t: usize = 0;
    while (t < toks.tokenCount()) : (t += 1) {
        const idx = TokIdx.at(t);
        const txt = toks.text(idx);
        const p = @intFromPtr(txt.ptr);
        // Zero-copy: the token's bytes ARE the source's bytes.
        try expect(p >= lo);
        try expect(p + txt.len <= hi);
        // And the span agrees with the slice it hands out.
        const off, const len = toks.span(idx);
        try expectEqual(@as(usize, len), txt.len);
        try expect(txt.ptr == src[off..].ptr);
    }
}

test "case folding has not happened at tokenize time" {
    const gpa = std.testing.allocator;
    const src = "R1 VDD GND 1K\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);

    // Original spelling is recoverable from the span — this is what a diagnostic quotes.
    try expectEqualStrings("R1", tokText(toks, 0, 0));
    try expectEqualStrings("VDD", tokText(toks, 0, 1));
    try expectEqualStrings("GND", tokText(toks, 0, 2));
    try expectEqualStrings("1K", tokText(toks, 0, 3));
    // Case-insensitive comparison is still available, in place.
    try expect(toks.headIs(LineIdx.at(0), "r1"));
    try expect(toks.eqlFold(toks.tok(LineIdx.at(0), 1).?, "vdd"));
}

test "spice inline comments end the live part of a line" {
    const gpa = std.testing.allocator;
    const src =
        "R1 a b 1k ; trailing semicolon comment\n" ++
        "R2 a b 2k $ trailing dollar comment\n" ++
        "  * indented whole-line comment\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);

    try expectEqual(@as(usize, 2), toks.lineCount());
    try expectEqual(@as(u32, 4), toks.count(LineIdx.at(0)));
    try expectEqual(@as(u32, 4), toks.count(LineIdx.at(1)));
    try expectEqualStrings("2k", tokText(toks, 1, 3));
}

test "a spectre block comment spanning lines disappears entirely" {
    const gpa = std.testing.allocator;
    const src =
        "simulator lang=spectre\n" ++
        "r1 (a b) resistor r=1k\n" ++
        "/* this block\n" ++
        "   spans several\n" ++
        "   lines */\n" ++
        "c1 (b 0) capacitor c=1u\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);

    try expectEqual(@as(usize, 3), toks.lineCount());
    try expect(toks.headIs(LineIdx.at(0), "simulator"));
    try expect(toks.headIs(LineIdx.at(1), "r1"));
    try expect(toks.headIs(LineIdx.at(2), "c1"));
}

test "spectre parentheses split into standalone punct tokens" {
    const gpa = std.testing.allocator;
    const src = "simulator lang=spectre\nm1 (d g s b) nmos // a comment\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);

    const l = LineIdx.at(1);
    try expectEqual(@as(u32, 8), toks.count(l));
    try expectEqualStrings("m1", tokText(toks, 1, 0));
    try expectEqualStrings("(", tokText(toks, 1, 1));
    try expectEqualStrings(")", tokText(toks, 1, 6));
    try expectEqualStrings("nmos", tokText(toks, 1, 7));
    try expectEqual(token.Kind.punct, toks.kindOf(toks.tok(l, 1).?));
    try expectEqual(token.Kind.word, toks.kindOf(toks.tok(l, 7).?));
}

test "spice brackets split so xspice port groups stay whole tokens" {
    const gpa = std.testing.allocator;
    const src = "a1 [d clk] [q qb] myff\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);

    // a1 [ d clk ] [ q qb ] myff
    try expectEqual(@as(u32, 10), toks.count(LineIdx.at(0)));
    try expectEqualStrings("[", tokText(toks, 0, 1));
    try expectEqualStrings("clk", tokText(toks, 0, 3));
    try expectEqualStrings("]", tokText(toks, 0, 4));
    try expectEqualStrings("myff", tokText(toks, 0, 9));
}

test "the simulator lang directive takes effect after its own statement" {
    const gpa = std.testing.allocator;
    const src =
        "R1 a b 1k\n" ++
        "simulator lang=spectre\n" ++
        "r2 (a b) resistor r=2k\n" ++
        "simulator lang = spice\n" ++
        "R3 a b 3k\n";

    var toks = try token.tokenize(gpa, src);
    defer toks.deinit(gpa);

    try expectEqual(token.Lang.spice, toks.langOf(LineIdx.at(0)));
    // The directive itself is read in the outgoing dialect.
    try expectEqual(token.Lang.spice, toks.langOf(LineIdx.at(1)));
    try expectEqual(token.Lang.spectre, toks.langOf(LineIdx.at(2)));
    // And the split `lang = spice` spelling is recognized too.
    try expectEqual(token.Lang.spectre, toks.langOf(LineIdx.at(3)));
    try expectEqual(token.Lang.spice, toks.langOf(LineIdx.at(4)));

    try expectEqual(@as(?token.Lang, .spectre), token.langSwitch(toks, LineIdx.at(1)));
    try expectEqual(@as(?token.Lang, null), token.langSwitch(toks, LineIdx.at(0)));
}

// ---------------------------------------------------------------------------
// expr.zig — SI suffixes, scope, brace resolution
// ---------------------------------------------------------------------------

test "SI suffixes are exact and meg beats m" {
    try expectEqual(@as(f64, 1e6), expr.siMult("meg"));
    try expectEqual(@as(f64, 1e6), expr.siMult("MEG"));
    try expectEqual(@as(f64, 25.4e-6), expr.siMult("mil"));
    try expectEqual(@as(f64, 1e-3), expr.siMult("m"));
    try expectEqual(@as(f64, 1e-3), expr.siMult("meters"));
    try expectEqual(@as(f64, 1e3), expr.siMult("kohm"));
    try expectEqual(@as(f64, 1e12), expr.siMult("t"));
    try expectEqual(@as(f64, 1e-18), expr.siMult("a"));
    // Unknown or absent suffix is a multiplier of one, not a failure.
    try expectEqual(@as(f64, 1.0), expr.siMult(""));
    try expectEqual(@as(f64, 1.0), expr.siMult("z"));
}

test "a spice number is a mantissa plus a suffix, and a bare e is a unit" {
    {
        const v, const n = expr.readNumber("1meg").?;
        try expectEqual(@as(f64, 1e6), v);
        try expectEqual(@as(usize, 4), n);
    }
    {
        const v, const n = expr.readNumber("4.7u").?;
        try expectEqual(@as(f64, 4.7e-6), v);
        try expectEqual(@as(usize, 4), n);
    }
    {
        // Exponent, because a digit follows the sign.
        const v, const n = expr.readNumber("1e-3").?;
        try expectEqual(@as(f64, 1e-3), v);
        try expectEqual(@as(usize, 4), n);
    }
    {
        // No digit follows, so `e` is a unit letter and the value is 1.
        const v, const n = expr.readNumber("1e").?;
        try expectEqual(@as(f64, 1.0), v);
        try expectEqual(@as(usize, 2), n);
    }
    {
        // Trailing unit letters are consumed and ignored past the third.
        const v, const n = expr.readNumber("1kohm").?;
        try expectEqual(@as(f64, 1000.0), v);
        try expectEqual(@as(usize, 5), n);
    }
    try expect(expr.readNumber("abc") == null);
    // `4k7` reads `4k` and leaves `7` — a label convention, not arithmetic.
    {
        const v, const n = expr.readNumber("4k7").?;
        try expectEqual(@as(f64, 4000.0), v);
        try expectEqual(@as(usize, 2), n);
    }
}

test "param scope shadows innermost-out and pops back to the outer binding" {
    const gpa = std.testing.allocator;
    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var sc: expr.Scope = .empty;
    defer sc.deinit(gpa);

    const w = try it.internFold(gpa, "w");
    const g = try it.internFold(gpa, "g");

    try sc.push(); // globals
    try sc.define(gpa, w, 1.0);
    try sc.define(gpa, g, 2.0);
    try expectEqual(@as(?f64, 1.0), sc.lookup(w));
    try expectEqual(@as(u8, 1), sc.frameCount());

    try sc.push(); // one instantiation deep
    try sc.define(gpa, w, 3.0);
    try expectEqual(@as(?f64, 3.0), sc.lookup(w)); // shadowed
    try expectEqual(@as(?f64, 2.0), sc.lookup(g)); // outer still visible
    try expectEqual(@as(?f64, 6.0), expr.eval("w*g", sc, it));

    sc.pop();
    try expectEqual(@as(?f64, 1.0), sc.lookup(w)); // shadow gone
    try expectEqual(@as(u8, 1), sc.frameCount());
    try expectEqual(@as(?f64, 2.0), expr.eval("w*g", sc, it));

    // A redefinition within one frame takes effect too.
    try sc.define(gpa, g, 10.0);
    try expectEqual(@as(?f64, 10.0), sc.lookup(g));
    sc.assertValid();
}

test "arithmetic honors precedence, unary minus and parentheses" {
    const gpa = std.testing.allocator;
    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var sc: expr.Scope = .empty;
    defer sc.deinit(gpa);
    try sc.push();
    try sc.define(gpa, try it.internFold(gpa, "w"), 2e-6);
    try sc.define(gpa, try it.internFold(gpa, "n"), 3.0);

    try expectEqual(@as(?f64, 7.0), expr.eval("2*3+1", sc, it));
    try expectEqual(@as(?f64, -6.0), expr.eval("-(1+2)*2", sc, it));
    try expectEqual(@as(?f64, 6e-6), expr.eval("w*n", sc, it));
    try expectEqual(@as(?f64, 500.0), expr.eval("1k/2", sc, it));
    try expectEqual(@as(?f64, 1e-3), expr.eval(" 1e-3 ", sc, it));

    // Rejected: unknown identifier, incomplete expression, trailing input, empty.
    try expect(expr.eval("missing+1", sc, it) == null);
    try expect(expr.eval("3 +", sc, it) == null);
    try expect(expr.eval("4k7", sc, it) == null);
    try expect(expr.eval("", sc, it) == null);
    try expect(expr.eval("2 3", sc, it) == null);
    // Evaluating an unknown name must not have interned it.
    try expect(it.find("missing") == null);
}

test "an unresolvable brace expression is left verbatim, braces included" {
    const gpa = std.testing.allocator;
    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var sc: expr.Scope = .empty;
    defer sc.deinit(gpa);
    try sc.push();
    try sc.define(gpa, try it.internFold(gpa, "rval"), 1000.0);

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "{2*rval}", .want = "2000" },
        .{ .in = "W={rval}m", .want = "W=1000m" },
        .{ .in = "plain", .want = "plain" },
        .{ .in = "{nope}", .want = "{nope}" },
        // Partial resolution: what resolved resolves, what did not survives.
        .{ .in = "W={rval} L={nope}", .want = "W=1000 L={nope}" },
        // Unbalanced brace emits the remainder as-is.
        .{ .in = "a{rval", .want = "a{rval" },
    };

    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try expr.resolveBraces(c.in, sc, it, &out.writer);
        const got = try out.toOwnedSlice();
        defer gpa.free(got);
        try expectEqualStrings(c.want, got);
    }
}

test "a label number prints compactly and never as negative zero" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { v: f64, want: []const u8 }{
        .{ .v = 2000.0, .want = "2000" },
        .{ .v = 0.0, .want = "0" },
        .{ .v = -0.0, .want = "0" },
        .{ .v = 0.001, .want = "0.001" },
    };
    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try expr.writeNumber(c.v, &out.writer);
        const got = try out.toOwnedSlice();
        defer gpa.free(got);
        try expectEqualStrings(c.want, got);
    }
}

// ---------------------------------------------------------------------------
// card.zig — classification
// ---------------------------------------------------------------------------

test "a passive card takes the first bare token as its value" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator, "R1 in out 4k7 tc1=0.1\nC1 out 0 1u\nL1 a b 10n\n");
    defer h.deinit();

    const r = try h.classify(0);
    try expectEqual(card.Kind.elem, r.kind);
    try expectEqualStrings("res", h.className(r));
    try expectEqual(@as(usize, 2), r.nodes.len);
    try expectEqualStrings("in", h.nodeText(r, 0));
    try expectEqualStrings("out", h.nodeText(r, 1));
    // `tc1=0.1` is a parameter, not the value.
    try expectEqualStrings("4k7", r.value);
    try expectEqual(@as(usize, 1), r.args.len);

    const c = try h.classify(1);
    try expectEqualStrings("cap", h.className(c));
    try expectEqualStrings("1u", c.value);

    const l = try h.classify(2);
    try expectEqualStrings("ind", h.className(l));
    try expectEqualStrings("10n", l.value);
}

test "a rail-named bulk node never shadows the transistor model" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator, "M1 d g vss vss nmos w=1u l=0.1u\n");
    defer h.deinit();

    const m = try h.classify(0);
    try expectEqual(card.Kind.elem, m.kind);
    try expectEqualStrings("nmos", h.className(m));
    // Bulk is dropped: three terminals, in card order.
    try expectEqual(@as(usize, 3), m.nodes.len);
    try expectEqualStrings("d", h.nodeText(m, 0));
    try expectEqualStrings("g", h.nodeText(m, 1));
    try expectEqualStrings("vss", h.nodeText(m, 2));
    try expectEqualStrings("W=1u/L=0.1u", m.value);
}

test "a transistor model resolves through its .model card" {
    var h: Harness = undefined;
    try h.init(
        std.testing.allocator,
        ".model nch_25 nmos(level=1 vto=0.5)\nM1 d g s b nch_25 w=1u\nM2 d g s b unknown_model\n",
    );
    defer h.deinit();

    const m1 = try h.classify(1);
    try expectEqual(card.Kind.elem, m1.kind);
    try expectEqualStrings("nmos", h.className(m1));
    try expectEqualStrings("W=1u", m1.value);

    // No `.model`, no builtin: reported rather than guessed.
    const m2 = try h.classify(2);
    try expectEqual(card.Kind.skipped, m2.kind);
    try expectEqual(Reason.unknown_class, m2.reason);
}

test "source subtype comes from the waveform tokens after the nodes" {
    var h: Harness = undefined;
    try h.init(
        std.testing.allocator,
        "V1 a 0 dc 5\nV2 a 0 sin(0 1 1k)\nV3 a 0 ac 1\nI1 a 0 ac 1\nI2 a 0 2m\n",
    );
    defer h.deinit();

    try expectEqualStrings("vsource", h.className(try h.classify(0)));
    try expectEqualStrings("vsourcesin", h.className(try h.classify(1)));
    try expectEqualStrings("vsourceac", h.className(try h.classify(2)));
    try expectEqualStrings("isourceac", h.className(try h.classify(3)));
    try expectEqualStrings("isource", h.className(try h.classify(4)));

    const v1 = try h.classify(0);
    try expectEqualStrings("dc 5", v1.value);
}

test "xspice ports map to symbol slots, not to port order" {
    var h: Harness = undefined;
    try h.init(
        std.testing.allocator,
        ".model myff d_dff\n" ++
            ".model mynand d_nand\n" ++
            ".model myinv d_inverter\n" ++
            "a1 [d clk] [set rst] [q qb] myff\n" ++
            "a2 [x y] z mynand\n" ++
            "a3 in out myinv\n" ++
            "a4 [a b] c adc_bridge\n" ++
            "a5 [d clk] myff\n",
    );
    defer h.deinit();

    // d_dff exposes data clk set reset out nout; dff wants d clk q qb.
    const ff = try h.classify(3);
    try expectEqual(card.Kind.elem, ff.kind);
    try expectEqualStrings("dff", h.className(ff));
    try expectEqual(@as(usize, 4), ff.nodes.len);
    try expectEqualStrings("d", h.nodeText(ff, 0));
    try expectEqualStrings("clk", h.nodeText(ff, 1));
    try expectEqualStrings("q", h.nodeText(ff, 2));
    try expectEqualStrings("qb", h.nodeText(ff, 3));

    // XSPICE puts the gate output last; the GATE2 symbol puts it in the middle.
    const nand = try h.classify(4);
    try expectEqualStrings("nandgate", h.className(nand));
    try expectEqualStrings("x", h.nodeText(nand, 0));
    try expectEqualStrings("z", h.nodeText(nand, 1));
    try expectEqualStrings("y", h.nodeText(nand, 2));

    try expectEqualStrings("notgate", h.className(try h.classify(5)));

    // A model with no symbol, and a card with too few ports, are both reported.
    try expectEqual(card.Kind.skipped, (try h.classify(6)).kind);
    try expectEqual(card.Kind.skipped, (try h.classify(7)).kind);
}

test "controlled, behavioral and fixed-node elements land on their symbols" {
    var h: Harness = undefined;
    try h.init(
        std.testing.allocator,
        "E1 outp outn inp inn 2.0\n" ++
            "G1 outp outn inp inn 1m\n" ++
            "F1 outp outn vsense 10\n" ++
            "H1 outp outn vsense 10\n" ++
            "B1 a 0 v=v(b)*2\n" ++
            "B2 a 0 i=v(b)*2\n" ++
            "S1 a b cp cn smod\n" ++
            "T1 a 0 b 0 z0=50\n" ++
            "Z1 d g s mesmod\n" ++
            "T2 a 0\n",
    );
    defer h.deinit();

    try expectEqualStrings("cvsource", h.className(try h.classify(0)));
    try expectEqualStrings("cisource", h.className(try h.classify(1)));
    try expectEqualStrings("cisource", h.className(try h.classify(2)));
    try expectEqualStrings("cvsource", h.className(try h.classify(3)));
    try expectEqualStrings("vsource", h.className(try h.classify(4)));
    try expectEqualStrings("isource", h.className(try h.classify(5)));
    try expectEqualStrings("switch", h.className(try h.classify(6)));

    // A transmission line takes all four of its nodes.
    const t = try h.classify(7);
    try expectEqualStrings("tline", h.className(t));
    try expectEqual(@as(usize, 4), t.nodes.len);
    try expectEqualStrings("mesfet", h.className(try h.classify(8)));

    // Too few nodes stays a skip rather than becoming a truncated device.
    const bad = try h.classify(9);
    try expectEqual(card.Kind.skipped, bad.kind);
    try expectEqual(Reason.unknown_class, bad.reason);

    // The control nodes ride along in the value rather than becoming pins.
    const e1 = try h.classify(0);
    try expectEqual(@as(usize, 2), e1.nodes.len);
    try expectEqualStrings("inp inn 2.0", e1.value);
}

test "ignored-by-design and skipped-as-a-limitation are distinct classifications" {
    var h: Harness = undefined;
    try h.init(
        std.testing.allocator,
        ".tran 1n 1u\n" ++
            ".model m1 nmos(level=1)\n" ++
            ".param g=2\n" ++
            ".options savecurrents\n" ++
            "K1 L1 L2 0.9\n" ++
            "U1 a b c urcmod l=1\n" ++
            "Q9 a b c nosuchmodel\n" ++
            "X2 a b nosuch\n",
    );
    defer h.deinit();

    const tran = try h.classify(0);
    try expectEqual(card.Kind.ignored, tran.kind);
    try expectEqual(Reason.analysis_card, tran.reason);
    try expect(tran.reason.isByDesign());

    try expectEqual(Reason.model_card, (try h.classify(1)).reason);
    try expectEqual(card.Kind.param_def, (try h.classify(2)).kind);
    try expect(h.cl.isParamDef(LineIdx.at(2)));
    try expectEqual(Reason.option_card, (try h.classify(3)).reason);

    // Inductive coupling is a relationship, not a device: dropped by design.
    try expectEqual(card.Kind.ignored, (try h.classify(4)).kind);

    // These three we wanted to draw and could not.
    const urc = try h.classify(5);
    try expectEqual(card.Kind.skipped, urc.kind);
    try expect(!urc.reason.isByDesign());
    try expectEqual(Reason.unknown_class, (try h.classify(6)).reason);
    try expectEqual(Reason.undefined_subckt, (try h.classify(7)).reason);
}

test "a subckt boundary captures its ports and its default parameters" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator, ".subckt inv in out vdd W=1u L=0.1u\n.ends\ninline subckt\n");
    defer h.deinit();
    const gpa = std.testing.allocator;

    const b = (try h.cl.boundary(gpa, LineIdx.at(0))).?;
    try expect(b == .begin);
    try expectEqualStrings("inv", h.it.get(b.begin.name));
    try expectEqual(@as(usize, 3), b.begin.ports.len);
    try expectEqualStrings("in", h.toks.text(b.begin.ports[0]));
    try expectEqualStrings("vdd", h.toks.text(b.begin.ports[2]));
    try expectEqual(@as(usize, 2), b.begin.params.len);
    // Keys are folded on intern, so `W=` and `w=` are one parameter.
    try expectEqualStrings("w", h.it.get(b.begin.params[0].key));

    const e = (try h.cl.boundary(gpa, LineIdx.at(1))).?;
    try expect(e == .end);
}

test "a spectre element is recognized by its parenthesized node list" {
    var h: Harness = undefined;
    try h.init(
        std.testing.allocator,
        "simulator lang=spectre\nr1 (a b) resistor r=2k\ne1 (op on ip in) vcvs gain=2\n",
    );
    defer h.deinit();

    const r = try h.classify(1);
    try expectEqual(card.Kind.elem, r.kind);
    try expectEqualStrings("res", h.className(r));
    try expectEqualStrings("2k", r.value);
    try expectEqual(@as(usize, 2), r.nodes.len);

    // The Spectre spelling `vcvs` translates onto the builtin output-port symbol.
    const e = try h.classify(2);
    try expectEqualStrings("cvsource", h.className(e));
    try expectEqual(@as(usize, 2), e.nodes.len);
}

test "a foundry master resolves by the longest class token inside it" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();

    const hit = card.scanMaster(&symbols, "sky130_fd_pr__nfet_01v8_lvt").?;
    try expectEqualStrings("nfet", symbols.at(hit[0]).name);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try card.writeFlavour(hit[1], &out.writer);
    const flavour = try out.toOwnedSlice();
    defer gpa.free(flavour);
    // The tail is what distinguishes siblings; the process prefix is worth nothing.
    try expectEqualStrings("01v8 lvt", flavour);

    try expect(card.scanMaster(&symbols, "totally_opaque") == null);
}

// ---------------------------------------------------------------------------
// flatten.zig — definitions, hierarchy, parameters
// ---------------------------------------------------------------------------

test "flattening renames formal ports positionally and prefixes internal nets" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt inv in out\nM1 out in vss vss nmos\n.ends\nX1 a y inv\n",
    );
    defer b.deinit(gpa);
    b.ir.assertValid();

    try expectEqual(@as(usize, 1), b.ir.deviceCount());
    try expectEqualStrings("x1.m1", b.strings.get(b.ir.dev_name[0]));
    // out -> y, in -> a (positional), vss is internal and gets the instance prefix.
    try expectEqualStrings("y", netNameOf(b, 0, 0));
    try expectEqualStrings("a", netNameOf(b, 0, 1));
    try expectEqualStrings("x1.vss", netNameOf(b, 0, 2));
    try expectEqual(@as(usize, 0), b.report.skipped.len);

    // The dissolved boundary is still recorded for group framing.
    try expectEqual(@as(usize, 1), b.ir.groupCount());
    try expectEqualStrings("x1", b.strings.get(b.ir.group_path[0]));
    try expectEqualStrings("inv", b.strings.get(b.ir.group_master[0]));
}

test "hierarchical names compose through nested instantiation" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt leaf p\nR1 p 0 1k\n.ends\n" ++
            ".subckt mid q\nXa q leaf\n.ends\n" ++
            "Xtop net1 mid\n",
    );
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 1), b.ir.deviceCount());
    try expectEqualStrings("xtop.xa.r1", b.strings.get(b.ir.dev_name[0]));
    try expectEqualStrings("net1", netNameOf(b, 0, 0));
    try expectEqual(@as(usize, 0), b.report.skipped.len);
}

test "a definition nested inside another is lifted and stays instantiable" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt top a\n.subckt cell n\nR1 n 0 1k\n.ends\nXc a cell\n.ends\nXt net top\n",
    );
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 1), b.ir.deviceCount());
    try expectEqualStrings("xt.xc.r1", b.strings.get(b.ir.dev_name[0]));
    try expectEqual(@as(usize, 0), b.report.skipped.len);
}

test "net 0 stays global at every depth and is never prefixed" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt leaf p\nR1 p 0 1k\n.ends\nX1 a leaf\nX2 b leaf\nC1 a 0 1u\n",
    );
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 3), b.ir.deviceCount());

    // Both instances and the top-level cap share one ground net.
    var grounds: usize = 0;
    for (b.ir.net_name) |n| {
        if (std.mem.eql(u8, b.strings.get(n), "0")) grounds += 1;
    }
    try expectEqual(@as(usize, 1), grounds);
    // And nothing named `x1.0` was ever created.
    for (b.ir.net_name) |n| {
        try expect(!std.mem.endsWith(u8, b.strings.get(n), ".0"));
    }
}

test "a subckt port count mismatch is reported, never truncated" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt inv in out\nR1 in out 1k\n.ends\nX1 a inv\n",
    );
    defer b.deinit(gpa);

    // Nothing emitted: a positional mapping with the wrong arity would wire the wrong nets.
    try expectEqual(@as(usize, 0), b.ir.deviceCount());
    try expect(hasReason(b.report.skipped, .port_arity_mismatch));
}

test "instantiation past the depth cap is reported, not a stack overflow" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt loop a\nX1 a loop\n.ends\nXt net loop\n",
    );
    defer b.deinit(gpa);

    try expect(hasReason(b.report.skipped, .subckt_too_deep));
    // The self-instantiation emits no devices; the run still completes.
    try expectEqual(@as(usize, 0), b.ir.deviceCount());
}

test "call-site parameters override definition defaults" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".param g=2\n.subckt rload n W=1k\nR1 n 0 {W*g}\n.ends\nX1 a rload W=3k\n",
    );
    defer b.deinit(gpa);

    // globals g=2, default W=1k overridden to 3k at the call site: 3000 * 2.
    try expectEqual(@as(usize, 1), b.ir.deviceCount());
    try expectEqualStrings("6000", b.strings.get(b.ir.dev_value[0]));
}

test "an unbound parameter leaves the value label verbatim" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt rload n\nR1 n 0 {rmissing*2}\n.ends\nX1 a rload\n",
    );
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 1), b.ir.deviceCount());
    try expectEqualStrings("{rmissing*2}", b.strings.get(b.ir.dev_value[0]));
}

test "ignored cards are reported once, at the top level only" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        ".subckt s a\n.tran 1n 1u\nR1 a 0 1k\n.ends\nX1 n s\nX2 m s\n.ac dec 10 1 1k\n",
    );
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 2), b.ir.deviceCount());
    // The `.tran` inside the body is not reported twice, or at all: only the top-level `.ac`.
    try expectEqual(@as(usize, 1), countReason(b.report.ignored, .analysis_card));
}

test "every note lands in the list its reason's intent selects" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        "* a tiny RC + driver\n" ++
            "V1 in 0 dc 5\n" ++
            "R1 in mid 1k\n" ++
            "C1 mid 0 1u\n" ++
            "M1 out mid 0 0 nmos\n" ++
            "M2 out mid 0 0 nch_25\n" ++
            ".tran 1n 1u\n" ++
            ".end\n",
    );
    defer b.deinit(gpa);

    // V1, R1, C1, M1; M2's foundry model has no `.model` card and is skipped.
    try expectEqual(@as(usize, 4), b.ir.deviceCount());
    try expectEqual(@as(usize, 1), b.report.skipped.len);
    try expectEqual(Reason.unknown_class, b.report.skipped[0].reason);

    for (b.report.ignored) |n| try expect(n.reason.isByDesign());
    for (b.report.skipped) |n| try expect(!n.reason.isByDesign());
    try expect(hasReason(b.report.ignored, .analysis_card));

    // Every note's span locates back into the deck it came from.
    for (b.report.skipped) |n| {
        try expect(n.off + n.len <= b.source.text().len);
        const loc = b.source.locate(n.off);
        try expect(loc.line >= 1);
    }
    // The comment line is not reported: stripping it costs nothing to say.
    try expectEqual(@as(usize, 0), countReason(b.report.ignored, .comment));
}

test "an unterminated definition is reported and its body is not emitted at top level" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        "R0 a b 1k\n.subckt orphan p\nR1 p 0 1k\n",
    );
    defer b.deinit(gpa);

    // Only the statement outside the definition survives.
    try expectEqual(@as(usize, 1), b.ir.deviceCount());
    try expectEqualStrings("r0", b.strings.get(b.ir.dev_name[0]));
    try expect(hasReason(b.report.skipped, .port_arity_mismatch));
}

test "an unmatched .ends is reported without disturbing the surrounding deck" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(gpa, &ckt.Config.default, &symbols, "R1 a b 1k\n.ends\nR2 b c 2k\n");
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 2), b.ir.deviceCount());
    try expect(hasReason(b.report.skipped, .port_arity_mismatch));
}

test "nets are numbered in first-mention order" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(gpa, &ckt.Config.default, &symbols, "R1 in mid 1k\nC1 mid 0 1u\n");
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 3), b.ir.netCount());
    try expectEqualStrings("in", b.strings.get(b.ir.net_name[0]));
    try expectEqualStrings("mid", b.strings.get(b.ir.net_name[1]));
    try expectEqualStrings("0", b.strings.get(b.ir.net_name[2]));
    // Net names are folded, so VDD and vdd are one net.
    var b2 = try flatten.fromText(gpa, &ckt.Config.default, &symbols, "R1 VDD n 1k\nR2 vdd n 2k\n");
    defer b2.deinit(gpa);
    try expectEqual(@as(usize, 2), b2.ir.netCount());
}

test "no pin from a netlist card is left floating" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(
        gpa,
        &ckt.Config.default,
        &symbols,
        "M1 d g s b nmos\nR1 d 0 1k\nT1 a 0 b 0 z0=50\n",
    );
    defer b.deinit(gpa);

    try expectEqual(@as(usize, 3), b.ir.deviceCount());
    // The classifier rejects short cards, so `.none` cannot reach the pin column here.
    for (b.ir.pin_net) |n| try expect(n != .none);
    // Pin counts equal the symbols' terminal counts.
    try expectEqual(@as(u32, 3), b.ir.pinCountOf(ckt.ids.DeviceIdx.at(0)));
    try expectEqual(@as(u32, 2), b.ir.pinCountOf(ckt.ids.DeviceIdx.at(1)));
    try expectEqual(@as(u32, 4), b.ir.pinCountOf(ckt.ids.DeviceIdx.at(2)));
}

// ---------------------------------------------------------------------------
// Determinism and allocation failure
// ---------------------------------------------------------------------------

const determinism_deck =
    ".param g=2\n" ++
    ".subckt inv in out vdd\n" ++
    "M1 out in vdd vdd nmos w={g}u\n" ++
    "R1 out 0 1k\n" ++
    ".ends\n" ++
    "V1 vdd 0 dc 1.8\n" ++
    "X1 a y inv vdd\n" ++
    "X2 y z inv vdd\n" ++
    "C1 z 0 1u\n" ++
    ".tran 1n 1u\n";

test "two parses of the same bytes assign identical string ids in identical order" {
    const gpa = std.testing.allocator;
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();

    var first = try flatten.fromText(gpa, &ckt.Config.default, &symbols, determinism_deck);
    defer first.deinit(gpa);
    var second = try flatten.fromText(gpa, &ckt.Config.default, &symbols, determinism_deck);
    defer second.deinit(gpa);

    // The pool is byte-identical, which means every id was assigned in the same order.
    try expectEqualStrings(first.strings.bytes, second.strings.bytes);
    try expectEqual(first.strings.count(), second.strings.count());
    for (first.strings.spans, second.strings.spans) |a, c| {
        try expectEqual(a.off, c.off);
        try expectEqual(a.len, c.len);
    }

    // And every IR column is identical id for id.
    try expectEqual(first.ir.deviceCount(), second.ir.deviceCount());
    try expectEqualSlices(ckt.ids.StrId, first.ir.dev_name, second.ir.dev_name);
    try expectEqualSlices(ckt.ids.StrId, first.ir.dev_value, second.ir.dev_value);
    try expectEqualSlices(ckt.ids.StrId, first.ir.net_name, second.ir.net_name);
    try expectEqualSlices(ckt.ids.NetIdx, first.ir.pin_net, second.ir.pin_net);
    try expectEqualSlices(u32, first.ir.dev_pin0, second.ir.dev_pin0);
    try expectEqual(first.report.ignored.len, second.report.ignored.len);
    try expectEqual(first.report.skipped.len, second.report.skipped.len);
}

fn parseDeck(gpa: std.mem.Allocator, text: []const u8) !void {
    var symbols = try testSymbols(gpa);
    defer symbols.deinit();
    var b = try flatten.fromText(gpa, &ckt.Config.default, &symbols, text);
    defer b.deinit(gpa);
    try expect(b.ir.deviceCount() > 0);
}

test "the front end releases everything when any single allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseDeck,
        .{determinism_deck},
    );
}

fn expandDeck(gpa: std.mem.Allocator) !void {
    const map = FileMap{ .entries = &.{
        .{ .path = "rc.sp", .text = "R1 in out 1k\n.include deep.sp\n" },
        .{ .path = "deep.sp", .text = "C1 out 0 1u\n" },
    } };
    var it = try Interner.init(gpa);
    defer it.deinit(gpa);
    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(gpa);
    var src = try Source.expand(
        gpa,
        &it,
        "deck.sp",
        "V1 in 0 dc 5\n.include rc.sp\n.include missing.sp\n",
        map.loader(),
        &notes,
    );
    defer src.deinit(gpa);
    try expect(src.segmentCount() >= 3);
}

test "include expansion releases everything when any single allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expandDeck, .{});
}
