//! Structured export: the placed schematic as a JSON document, streamed.
//!
//! This is the seam for every tool that post-processes geometry — a Python binding, a
//! netlist-to-KiCad bridge, a cleanup pass, a golden-file diff. It is library surface
//! rather than an `examples/` emitter for the reason ARCHITECTURE.md §2 gives: a C
//! consumer that would otherwise walk forty accessors can take one document instead,
//! and the *shape* of that document is an answer (what a placed schematic contains),
//! not a format.
//!
//! ## Nothing is built, everything is written
//!
//! The Rust original built a `json::Schematic` — a full parallel structure of `String`s
//! and `Vec<Vec<Vec<[i32;2]>>>` — handed it to `serde_json::to_string_pretty`, and got a
//! `String` back. Two complete copies of the schematic in memory before the first byte
//! reaches a file, and one `String` allocation per device name, net name, terminal name
//! and value. A 5,000-device schematic paid ~40,000 allocations to describe data that
//! was already sitting in flat arrays.
//!
//! Here every function takes a `*std.Io.Writer` and walks `Ir` + `Physical` + `Strings`
//! in one pass, emitting bytes as it goes. There is no intermediate document, no
//! `Schematic` type to keep in sync with the IR, and **no allocation at all** — a caller
//! that hands over `Writer.fixed(buf)` or a file writer gets the whole document without
//! the allocator being consulted once. A caller that wants a `[]u8` passes
//! `Writer.Allocating`, which is the only place a byte is heap-allocated and it is the
//! caller's choice.
//!
//! That also means the emitter cannot look ahead. Where the document needs to know
//! something before it prints (does this net carry any drawable segment, so does it
//! deserve a `wires` entry at all?) the answer comes from a cheap re-scan of the CSR
//! offsets, not from a materialized list — see `netHasWire`.
//!
//! ## Determinism
//!
//! Every loop is over a dense index range in ascending order: devices by `DeviceIdx`,
//! nets by `NetIdx`, points by their CSR position. No hash map is iterated anywhere in
//! this file, which is what makes two runs byte-identical (ARCHITECTURE.md §7). The
//! integer grid does the rest: no float formatting, so no locale, no rounding mode and
//! no `-0`.
//!
//! ## Layout of the output
//!
//! Two-space indentation like `serde_json::to_string_pretty`, with **one deliberate
//! deviation**: a coordinate pair prints inline as `[10, 20]` rather than exploded over
//! three lines. serde's pretty printer expands every array uniformly, which turns a
//! 400-point polyline into 1,200 lines of digits and makes a golden diff unreadable.
//! Coordinates are the one thing in this schema that is always exactly two numbers, so
//! inlining them is safe and is what makes the goldens reviewable.
//!
//! ## Schema
//!
//! ```json
//! { "devices": [ { "name": "r1", "class": "res", "value": "5k",
//!                  "rot": 0, "mirror": false, "pos": [40, 0],
//!                  "pins": [ { "term": "a", "net": "out", "xy": [20, 0] } ] } ],
//!   "nets": [ "out", "gnd" ],
//!   "wires": [ { "net": "out", "segments": [ [[20,0],[20,40],[60,40]] ] } ],
//!   "junctions": [ [20, 40] ],
//!   "labels": [ { "net": "clk", "at": [0, 96] } ] }
//! ```
//!
//! `labels` is new against the Rust schema, which had no way to say "this net exists,
//! the router proved it cannot be drawn, here is the tag that stands in for it". A
//! consumer that ignores the key sees exactly the old document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const ids = @import("ids.zig");
const irm = @import("ir.zig");
const catalog = @import("devices/catalog.zig");
const host = @import("devices/host.zig");
const config = @import("config.zig");

const Pt = ids.Pt;
const NetIdx = ids.NetIdx;
const DeviceIdx = ids.DeviceIdx;
const Ir = irm.Ir;
const Physical = irm.Physical;
const Placed = irm.Placed;
const Report = irm.Report;
const Note = irm.Note;
const Config = config.Config;

/// The only failure mode: the writer refused the bytes.
///
/// Nothing in this file allocates, so `OutOfMemory` cannot originate here. A
/// `Writer.Allocating` that runs out of memory reports it as `WriteFailed`, which is
/// its contract, not this module's.
pub const Error = Writer.Error;

/// Spaces per nesting level. Matches `serde_json::to_string_pretty`.
pub const indent_width: usize = 2;

/// Emit the placed schematic, resolving device classes from the builtin catalog only.
///
/// This is the form whose signature matches `root.run`'s `emitFn` parameter, which is
/// why `cfg` is present and unused: the schema carries geometry, not style, and there
/// is no knob in `Config` a JSON consumer can observe. Keeping the parameter is what
/// lets `root.run(gpa, cfg, src, w, json.write)` type-check alongside a caller's own
/// emitter.
///
/// Asserts every `dev_symbol` is below `catalog.builtin_count`. A schematic containing
/// host-registered classes must go through `writeWith`, which can resolve them — the
/// assert is deliberate rather than a fallback class name, because silently printing
/// `"generic"` for someone's DUT symbol is a bug report nobody can diagnose.
///
/// Writes to `w` and returns nothing; the caller owns whatever `w` is backed by and
/// this function allocates nothing. Errors: `WriteFailed`. Complexity O(devices + pins
/// + wire points + junctions + labels), one pass, no lookahead beyond the per-net
/// `netHasWire` scan.
pub fn write(placed: Placed, cfg: *const Config, w: *Writer) Error!void {
    _ = cfg;
    return emit(placed, null, w);
}

/// Emit the placed schematic, resolving classes through `table`.
///
/// The complete form. `table` must be the same `host.Table` the IR's `SymbolIdx` values
/// were assigned from; it is borrowed for the duration of the call and nothing from it
/// is retained. `cfg` is accepted and unused, for symmetry with `write`.
///
/// Class and terminal names are written straight from the class table, device/net/value
/// names straight from the string pool. Nothing is copied and nothing is interned.
///
/// Errors: `WriteFailed`. Allocation-free.
pub fn writeWith(
    placed: Placed,
    table: *const host.Table,
    cfg: *const Config,
    w: *Writer,
) Error!void {
    _ = cfg;
    return emit(placed, table, w);
}

/// The one document emitter. `table` resolves host classes; `null` means the schematic
/// is builtin-only and a stray host `SymbolIdx` is a producer bug (asserted in `classOf`).
///
/// Written as one function rather than a per-section pass because the indentation depth
/// is a literal constant at every site, which is what keeps the layout auditable against
/// the schema in the module header.
fn emit(placed: Placed, table: ?*const host.Table, w: *Writer) Error!void {
    const ir = placed.ir;
    const phys = placed.physical;
    const pool = placed.strings;

    try w.writeAll("{\n");

    // --- devices ---
    try writeIndent(w, 1);
    try w.writeAll("\"devices\": ");
    if (ir.deviceCount() == 0) {
        try w.writeAll("[],\n");
    } else {
        try w.writeAll("[\n");
        for (0..ir.deviceCount()) |d| {
            const class = classOf(table, ir.dev_symbol[d]);
            const o = ir.dev_orient[d];
            try writeIndent(w, 2);
            try w.writeAll("{\n");

            try writeKey(w, 3, "name");
            try writeString(w, pool.get(ir.dev_name[d]));
            try w.writeAll(",\n");

            try writeKey(w, 3, "class");
            try writeString(w, class.name);
            try w.writeAll(",\n");

            try writeKey(w, 3, "value");
            try writeString(w, pool.get(ir.dev_value[d]));
            try w.writeAll(",\n");

            try writeKey(w, 3, "rot");
            try w.print("{d},\n", .{@as(u8, o.rot)});

            try writeKey(w, 3, "mirror");
            try w.print("{s},\n", .{if (o.mirror) "true" else "false"});

            try writeKey(w, 3, "pos");
            try writePoint(w, phys.pos[d]);
            try w.writeAll(",\n");

            const lo, const hi = ir.pinRange(.at(d));
            try writeKey(w, 3, "pins");
            if (lo == hi) {
                try w.writeAll("[]\n");
            } else {
                try w.writeAll("[\n");
                for (lo..hi) |p| {
                    const slot = p - lo;
                    try writeIndent(w, 4);
                    try w.writeAll("{\n");

                    try writeKey(w, 5, "term");
                    const term: []const u8 = if (slot < class.terminals.len)
                        class.terminals[slot].name
                    else
                        "";
                    try writeString(w, term);
                    try w.writeAll(",\n");

                    try writeKey(w, 5, "net");
                    const net = ir.pin_net[p];
                    if (net == .none) {
                        try w.writeAll("null,\n");
                    } else {
                        try writeString(w, pool.get(ir.net_name[net.i()]));
                        try w.writeAll(",\n");
                    }

                    try writeKey(w, 5, "xy");
                    try writePoint(w, phys.pin_xy[p]);
                    try w.writeAll("\n");

                    try writeIndent(w, 4);
                    try w.writeAll(if (p + 1 < hi) "},\n" else "}\n");
                }
                try writeIndent(w, 3);
                try w.writeAll("]\n");
            }

            try writeIndent(w, 2);
            try w.writeAll(if (d + 1 < ir.deviceCount()) "},\n" else "}\n");
        }
        try writeIndent(w, 1);
        try w.writeAll("],\n");
    }

    // --- nets ---
    try writeIndent(w, 1);
    try w.writeAll("\"nets\": ");
    if (ir.netCount() == 0) {
        try w.writeAll("[],\n");
    } else {
        try w.writeAll("[\n");
        for (0..ir.netCount()) |n| {
            try writeIndent(w, 2);
            try writeString(w, pool.get(ir.net_name[n]));
            try w.writeAll(if (n + 1 < ir.netCount()) ",\n" else "\n");
        }
        try writeIndent(w, 1);
        try w.writeAll("],\n");
    }

    // --- wires: only nets that actually drew something ---
    var drawn: usize = 0;
    for (0..ir.netCount()) |n| {
        if (netHasWire(phys, .at(n))) drawn += 1;
    }
    try writeIndent(w, 1);
    try w.writeAll("\"wires\": ");
    if (drawn == 0) {
        try w.writeAll("[],\n");
    } else {
        try w.writeAll("[\n");
        var emitted: usize = 0;
        for (0..ir.netCount()) |n| {
            const net: NetIdx = .at(n);
            if (!netHasWire(phys, net)) continue;
            emitted += 1;

            try writeIndent(w, 2);
            try w.writeAll("{\n");
            try writeKey(w, 3, "net");
            try writeString(w, pool.get(ir.net_name[n]));
            try w.writeAll(",\n");

            try writeKey(w, 3, "segments");
            try w.writeAll("[\n");
            // The drawable segments of this net, re-scanned from the CSR offsets.
            var left = drawableSegments(phys, net);
            for (phys.net_seg[n]..phys.net_seg[n + 1]) |seg| {
                const pts = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
                if (pts.len < 2) continue;
                left -= 1;

                try writeIndent(w, 4);
                try w.writeAll("[\n");
                for (pts, 0..) |p, k| {
                    try writeIndent(w, 5);
                    try writePoint(w, p);
                    try w.writeAll(if (k + 1 < pts.len) ",\n" else "\n");
                }
                try writeIndent(w, 4);
                try w.writeAll(if (left > 0) "],\n" else "]\n");
            }
            try writeIndent(w, 3);
            try w.writeAll("]\n");

            try writeIndent(w, 2);
            try w.writeAll(if (emitted < drawn) "},\n" else "}\n");
        }
        try writeIndent(w, 1);
        try w.writeAll("],\n");
    }

    // --- junctions ---
    try writeIndent(w, 1);
    try w.writeAll("\"junctions\": ");
    if (phys.junctions.len == 0) {
        try w.writeAll("[],\n");
    } else {
        try w.writeAll("[\n");
        for (phys.junctions, 0..) |p, k| {
            try writeIndent(w, 2);
            try writePoint(w, p);
            try w.writeAll(if (k + 1 < phys.junctions.len) ",\n" else "\n");
        }
        try writeIndent(w, 1);
        try w.writeAll("],\n");
    }

    // --- labels ---
    try writeIndent(w, 1);
    try w.writeAll("\"labels\": ");
    if (phys.labels.len == 0) {
        try w.writeAll("[]\n");
    } else {
        try w.writeAll("[\n");
        for (phys.labels, 0..) |l, k| {
            try writeIndent(w, 2);
            try w.writeAll("{\n");
            try writeKey(w, 3, "net");
            try writeString(w, pool.get(ir.net_name[l.net.i()]));
            try w.writeAll(",\n");
            try writeKey(w, 3, "at");
            try writePoint(w, l.at);
            try w.writeAll("\n");
            try writeIndent(w, 2);
            try w.writeAll(if (k + 1 < phys.labels.len) "},\n" else "}\n");
        }
        try writeIndent(w, 1);
        try w.writeAll("]\n");
    }

    try w.writeAll("}");
}

/// Resolve a device's class. `null` table means builtin-only, which is where `write`'s
/// documented assertion lives.
fn classOf(table: ?*const host.Table, s: ids.SymbolIdx) catalog.DeviceClass {
    if (table) |t| return t.at(s);
    std.debug.assert(s.i() < catalog.builtin_count);
    return catalog.at(s).*;
}

/// `<indent>"<k>": `, the prefix every object member shares.
fn writeKey(w: *Writer, n: usize, k: []const u8) Error!void {
    try writeIndent(w, n);
    try w.writeByte('"');
    try w.writeAll(k);
    try w.writeAll("\": ");
}

/// How many of net `n`'s segments have two or more points.
fn drawableSegments(phys: Physical, n: NetIdx) usize {
    const i = n.i();
    var k: usize = 0;
    for (phys.net_seg[i]..phys.net_seg[i + 1]) |seg| {
        if (phys.seg_pt[seg + 1] - phys.seg_pt[seg] >= 2) k += 1;
    }
    return k;
}

/// Emit the front end's report as JSON: `{ "ignored": [...], "skipped": [...] }`.
///
/// Each note prints as `{ "line": 3, "off": 42, "len": 11, "reason": "analysis_card",
/// "text": ".tran 1n 1u" }`. `reason` is the enum tag name, so a consumer switches on a
/// stable identifier rather than on prose.
///
/// `src` is the concatenated source arena the notes' spans index. Pass it and each note
/// gains a 1-based `line` (counted by scanning newlines up to `off`) and the offending
/// `text`; pass an empty slice and both are omitted, leaving `off`/`len` as the only
/// location — which is all a caller who no longer holds the source can honestly be
/// given. `src` is borrowed and unmodified.
///
/// The two categories stay separate because they mean different things: `ignored` is
/// by-design (an analysis card has no schematic meaning), `skipped` is a limitation.
/// Merging them makes a clean parse look lossy.
///
/// Errors: `WriteFailed`. Allocation-free. O(notes × span-prefix) for the line numbers,
/// which is a linear scan over a buffer nobody reads in the common case of zero notes.
pub fn writeReport(report: Report, src: []const u8, w: *Writer) Error!void {
    try w.writeAll("{\n");
    try writeNotes(w, "ignored", report.ignored, src, true);
    try writeNotes(w, "skipped", report.skipped, src, false);
    try w.writeAll("}");
}

/// One `"<key>": [ … ]` member of the report object.
fn writeNotes(
    w: *Writer,
    key: []const u8,
    notes: []const Note,
    src: []const u8,
    comma: bool,
) Error!void {
    try writeKey(w, 1, key);
    if (notes.len == 0) {
        try w.writeAll(if (comma) "[],\n" else "[]\n");
        return;
    }
    try w.writeAll("[\n");
    for (notes, 0..) |n, k| {
        try writeIndent(w, 2);
        try w.writeAll("{\n");
        if (src.len != 0) {
            try writeKey(w, 3, "line");
            try w.print("{d},\n", .{lineOf(src, n.off)});
        }
        try writeKey(w, 3, "off");
        try w.print("{d},\n", .{n.off});
        try writeKey(w, 3, "len");
        try w.print("{d},\n", .{n.len});
        try writeKey(w, 3, "reason");
        try writeString(w, @tagName(n.reason));
        if (src.len == 0) {
            try w.writeAll("\n");
        } else {
            try w.writeAll(",\n");
            try writeKey(w, 3, "text");
            try writeString(w, spanOf(src, n));
            try w.writeAll("\n");
        }
        try writeIndent(w, 2);
        try w.writeAll(if (k + 1 < notes.len) "},\n" else "}\n");
    }
    try writeIndent(w, 1);
    try w.writeAll(if (comma) "],\n" else "]\n");
}

/// The offending bytes a note points at, clamped to `src`.
///
/// A span past the end of the buffer is a data condition — the source a caller kept may
/// be a different one — so it degrades to the empty string rather than trapping.
fn spanOf(src: []const u8, n: Note) []const u8 {
    if (n.off >= src.len) return src[0..0];
    const end = @min(src.len, @as(usize, n.off) + n.len);
    return src[n.off..end];
}

/// Emit the report in the C ABI's line-oriented text format.
///
/// One line per note, `ignored` first then `skipped`, each formatted exactly as the
/// Rust ABI produced it:
///
/// ```text
/// ignored line 1: .tran 1n 1u (analysis card)
/// skipped line 7: xbad a b nosuchcell (undefined subckt)
/// ```
///
/// A clean netlist writes nothing at all, which is the empty string the C header
/// promises. This format is a *contract* — foreign consumers grep it — so it is
/// preserved verbatim rather than modernized, and it is why this exists beside
/// `writeReport` instead of callers being told to parse the JSON.
///
/// `src` supplies the line number and the offending text, as in `writeReport`. With an
/// empty `src` the text degrades to `@<off>+<len>` and the line number to 0, rather
/// than the function refusing to run.
///
/// Errors: `WriteFailed`. Allocation-free.
pub fn writeReportText(report: Report, src: []const u8, w: *Writer) Error!void {
    for ([2][]const Note{ report.ignored, report.skipped }, [2][]const u8{ "ignored", "skipped" }) |notes, kind| {
        for (notes) |n| {
            try w.print("{s} line {d}: ", .{ kind, lineOf(src, n.off) });
            if (src.len == 0) {
                try w.print("@{d}+{d}", .{ n.off, n.len });
            } else {
                try w.writeAll(spanOf(src, n));
            }
            try w.print(" ({s})\n", .{n.reason.text()});
        }
    }
}

// ---------------------------------------------------------------------------
// Pieces, public because a host emitting its own annotations beside ours needs the
// same escaping and the same coordinate spelling. Everything else stays private.
// ---------------------------------------------------------------------------

/// Write `s` as a JSON string literal, quotes included.
///
/// Escapes `"` and `\`, and every control byte below 0x20 as `\uXXXX` (using the short
/// forms `\n`, `\r`, `\t`, `\b`, `\f` where they exist). Bytes at or above 0x80 pass
/// through unchanged: the string pool holds UTF-8, and re-encoding valid UTF-8 as
/// `\u` escapes would only make the output larger and the diff noisier. `DEL` (0x7f) is
/// legal unescaped JSON and is left alone.
///
/// Errors: `WriteFailed`. Allocation-free, one pass, no buffering.
pub fn writeString(w: *Writer, s: []const u8) Error!void {
    try w.writeByte('"');
    // Run-batched: everything that needs no escape goes out in one `writeAll`, so a
    // name with no specials costs exactly one call.
    var run: usize = 0;
    for (s, 0..) |c, i| {
        const esc: []const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x09 => "\\t",
            0x0a => "\\n",
            0x0c => "\\f",
            0x0d => "\\r",
            0x00...0x07, 0x0b, 0x0e...0x1f => "",
            else => continue,
        };
        try w.writeAll(s[run..i]);
        run = i + 1;
        if (esc.len != 0) {
            try w.writeAll(esc);
        } else {
            try w.print("\\u{x:0>4}", .{c});
        }
    }
    try w.writeAll(s[run..]);
    try w.writeByte('"');
}

/// Write a coordinate pair as `[x, y]`, on one line.
///
/// The deliberate deviation from serde's pretty printer described in the module header.
/// Integers only, so this is `std.fmt` on two `i32`s and nothing else.
pub fn writePoint(w: *Writer, p: Pt) Error!void {
    try w.print("[{d}, {d}]", .{ p.x, p.y });
}

/// Write `n * indent_width` spaces.
pub fn writeIndent(w: *Writer, n: usize) Error!void {
    const spaces = " " ** 32;
    var left = n * indent_width;
    while (left > spaces.len) : (left -= spaces.len) try w.writeAll(spaces);
    try w.writeAll(spaces[0..left]);
}

/// Does net `n` own at least one segment with two or more points?
///
/// The `wires` array carries only nets that actually drew something, which is the Rust
/// schema and worth keeping: a consumer iterating `wires` wants polylines, not a run of
/// empty objects. Answering it costs a walk of `net_seg[n]..net_seg[n+1]` comparing
/// `seg_pt` offsets — offsets already in cache from the emit loop — instead of the
/// `Vec<Wire>` the Rust materialized to find out.
///
/// A degenerate segment (fewer than two points) is not drawable and does not count, so
/// a net whose every segment is a single point is omitted entirely rather than
/// producing `"segments": []`.
///
/// Pure, allocation-free. O(segments of `n`).
pub fn netHasWire(phys: Physical, n: NetIdx) bool {
    const i = n.i();
    if (i + 1 >= phys.net_seg.len) return false;
    for (phys.net_seg[i]..phys.net_seg[i + 1]) |seg| {
        if (phys.seg_pt[seg + 1] - phys.seg_pt[seg] >= 2) return true;
    }
    return false;
}

/// 1-based line number of byte `off` in `src`, or 0 when `src` is empty or `off` is
/// past its end.
///
/// Counting rather than storing: the front end records spans, not lines
/// (ARCHITECTURE.md §5), because in the common case of a clean parse nobody ever asks.
/// This is where the cost is paid, once, for the handful of notes that exist.
pub fn lineOf(src: []const u8, off: u32) u32 {
    if (src.len == 0 or off >= src.len) return 0;
    return 1 + @as(u32, @intCast(std.mem.count(u8, src[0..off], "\n")));
}
