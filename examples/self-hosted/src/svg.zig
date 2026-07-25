//! SVG emitter for the dev gallery. **Not** part of the library.
//!
//! ## Why this lives in examples/ and not in src/
//!
//! The library's product is geometry: placed symbols, routed polylines, junctions,
//! labels, and the transform/bounds/anchor answers in `ckt.geom` that a renderer
//! cannot correctly recompute on its own. Formats are not geometry. Promoting an
//! emitter into the library would give it privileged access to internals, the two
//! paths would drift, and the first symptom would be a bug report from someone whose
//! own adapter cannot reproduce our gallery output.
//!
//! So this file imports **only `@import("cktimg")`** and touches nothing that a
//! third-party consumer could not reach. That constraint is the point of the example,
//! not an inconvenience it works around:
//!
//! > If this emitter needs something the public API does not expose, that is an **API
//! > bug**, and the fix belongs in `src/`. It is never a local workaround here.
//!
//! Concretely, that means: no reaching past `Placed` into private fields, no
//! recomputing the mirror-then-rotate order (call `ids.Orient.apply`), no
//! re-deriving body extents or refdes anchor positions (call `ckt.geom`), and no
//! second opinion about where a junction dot goes (`Physical.junctions` already
//! decided). Every one of those is a place where a renderer that "just did the math
//! itself" would start disagreeing with the C ABI's view of the same schematic.
//!
//! ## Streaming, not building
//!
//! Everything writes into a `*std.Io.Writer` supplied by the caller, so rendering a
//! 3 MB schematic to a file never materializes 3 MB of string. `write` matches the
//! `emitFn` signature `ckt.run` takes, which is what lets the gallery drive
//! parse → place → emit in one call.
//!
//! Coordinates are integers throughout, because placement is integer-only; there is
//! no float formatting anywhere in the geometry path and therefore no locale or
//! rounding drift between two runs. Stroke widths from `Config.render` are the only
//! floats, and they are style, not geometry.

const std = @import("std");
const ckt = @import("cktimg");

const Writer = std.Io.Writer;
const Placed = ckt.Placed;
const Config = ckt.Config;
const Rect = ckt.ids.Rect;
const Pt = ckt.ids.Pt;
const geom = ckt.geom;
const catalog = ckt.devices.catalog;
const Table = ckt.devices.host.Table;

/// Scratch for the two `ckt.geom` passes that are inherently order-dependent
/// (`refdesAnchors`, `groupFrames`) and therefore take an allocator.
///
/// A stack buffer rather than a parameter, because the emitter's contract is that it
/// allocates nothing the caller can observe. It is sized for the largest fixture with
/// room to spare; if it ever runs short the emitter degrades to the un-dodged label
/// spot and no group frames, which is a slightly uglier drawing rather than a failure.
/// ponytail: fixed scratch; hand `write` an allocator if a real deck ever overruns it.
const scratch_bytes = 1 << 20;

/// Everything `ckt.geom` answers for one drawing, computed once per emitter entry.
///
/// `table` resolves `SymbolIdx` values. The gallery registers no host classes — the
/// front end maps an unrecognized master onto the builtin `generic` box rather than
/// registering anything — so an empty table answers every fixture out of the comptime
/// catalog.
const Derived = struct {
    table: Table,
    anchors: []const Pt,
    frames: []const geom.GroupBox,

    /// `fba` must outlive the returned value; it backs `anchors` and `frames`.
    fn init(placed: Placed, fba: *std.heap.FixedBufferAllocator) Derived {
        const a = fba.allocator();
        var d: Derived = .{ .table = .init(a), .anchors = &.{}, .frames = &.{} };
        d.anchors = geom.refdesAnchors(a, placed.ir, placed.physical, placed.strings, &d.table) catch
            &.{};
        d.frames = geom.groupFrames(a, placed.ir, placed.physical, placed.strings, &d.table) catch
            &.{};
        return d;
    }

    /// Where device `d`'s refdes goes: the collision-avoided anchor when the scratch
    /// held, otherwise the preferred spot `geom` would have tried first.
    fn anchor(self: Derived, placed: Placed, d: usize) Pt {
        if (d < self.anchors.len) return self.anchors[d];
        const base = placed.physical.pos[d];
        return .{ .x = base.x + catalog.cell_half + geom.label_gap, .y = base.y };
    }
};

/// Emit a complete, standalone SVG document for `placed`.
///
/// Signature-compatible with `ckt.run`'s `emitFn` parameter, so a caller can go from
/// SPICE bytes to an SVG file without ever holding the document in memory.
///
/// `cfg` supplies styling only — stroke colors, stroke widths, and the padding added
/// around the content bounding box. It must be the same `Config` the schematic was
/// placed with, since `render.pad` is applied here rather than baked into the
/// geometry.
///
/// `w` receives the document: an XML declaration, an `<svg>` element whose `viewBox`
/// is the content bounds grown by `cfg.render.pad`, then symbols, wires, junctions and
/// labels in that order — painter's order, so wires never occlude a device body.
///
/// Writes nothing but the document; allocates nothing. All bounded work uses stack
/// buffers, which is why there is no allocator parameter.
///
/// Errors: `std.Io.Writer.Error` only, propagated from `w`. A schematic with no
/// devices emits a valid empty document rather than failing — an empty netlist is a
/// data condition, not a programming error.
pub fn write(placed: Placed, cfg: *const Config, w: *Writer) Writer.Error!void {
    var buf: [scratch_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const d = Derived.init(placed, &fba);

    const min_x, const min_y, const width, const height = viewBox(contentOf(placed, d), cfg.render.pad);

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d} {d} {d} {d}\" " ++
            "width=\"{d}\" height=\"{d}\" font-family=\"sans-serif\">\n",
        .{ min_x, min_y, width, height, width, height },
    );
    try w.print(
        "<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"white\"/>\n",
        .{ min_x, min_y, width, height },
    );

    // Frames are annotation, not circuit, so they go under everything.
    try writeFrames(placed, d, w);
    try writeSymbols(placed, cfg, w);
    try writeWires(placed, cfg, w);
    try writeJunctions(placed, cfg, w);
    try writeLabels(placed, cfg, w);

    try w.writeAll("</svg>\n");
}

/// Emit each group frame as a dashed rect plus its label, at the box and anchor
/// `ckt.geom.groupFrames` already decided. Private: `write`'s document structure is
/// the only caller, and the public surface stays the four painter's-order passes.
fn writeFrames(placed: Placed, d: Derived, w: *Writer) Writer.Error!void {
    for (d.frames) |g| {
        try w.print(
            "<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"none\" " ++
                "stroke=\"#999\" stroke-width=\"1\" stroke-dasharray=\"6 4\" rx=\"4\"/>\n",
            .{ g.rect.min.x, g.rect.min.y, g.rect.max.x - g.rect.min.x, g.rect.max.y - g.rect.min.y },
        );
        try w.print("<text x=\"{d}\" y=\"{d}\" font-size=\"8\" fill=\"#999\">", .{
            g.label_at.x, g.label_at.y,
        });
        try writeEscaped(placed.strings.get(g.path), w);
        try w.writeAll(" : ");
        try writeEscaped(placed.strings.get(g.master), w);
        try w.writeAll("</text>\n");
    }
}

/// The content bounding box `write` sizes the document to.
///
/// `ckt.geom.bounds` covers bodies, wires, junctions and label points; the refdes text
/// and the group frames sit outside all of that, so they are merged in here rather than
/// being clipped off the edge of the document.
///
/// Public because the HTML index sizes its thumbnails from the same numbers — the doc
/// on `viewBox` says why two derivations of "how big is this drawing" is the thing to
/// avoid, and this is the other half of that answer. Allocates nothing the caller sees.
pub fn contentRect(placed: Placed) Rect {
    var buf: [scratch_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    return contentOf(placed, Derived.init(placed, &fba));
}

/// `contentRect` for a caller that already built the `geom` answers, so the two entry
/// points never do the anchor pass twice in one nested call.
fn contentOf(placed: Placed, d: Derived) Rect {
    var content: Rect = geom.bounds(placed.ir, placed.physical, &d.table) orelse
        .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 0, .y = 0 } };
    for (0..placed.ir.deviceCount()) |i| {
        const name = placed.strings.get(placed.ir.dev_name[i]);
        content = content.merge(geom.refdesRect(d.anchor(placed, i), name));
    }
    for (d.frames) |g| content = content.merge(g.rect);
    return content;
}

/// The `viewBox` for `content`, grown by `pad` on every side.
///
/// Returned as `.{ min_x, min_y, width, height }` in the SVG's coordinate convention.
/// Split out from `write` because the HTML index needs the same numbers to size its
/// thumbnails, and two independent derivations of "how big is this drawing" is exactly
/// the divergence this file is structured to avoid.
///
/// `pad` is in host grid units and is applied symmetrically. A degenerate `content`
/// (zero width or height) still yields a positive width and height, so the document is
/// never invalid.
pub fn viewBox(content: Rect, pad: i32) struct { i32, i32, i32, i32 } {
    // A zero-area content box still has to produce a document a viewer will render, so
    // both extents floor at 1.
    return .{
        content.min.x - pad,
        content.min.y - pad,
        @max(1, content.max.x - content.min.x + 2 * pad),
        @max(1, content.max.y - content.min.y + 2 * pad),
    };
}

/// Emit every device symbol as a `<g>` of strokes, plus its refdes text.
///
/// Each device's draw primitives come from its symbol class; each primitive point is
/// transformed by `ids.Orient.apply` and then translated by the device's position from
/// `placed.physical.pos`. **The transform is not reimplemented here** — mirror-then-rotate
/// is the library's single definition and a renderer that inlines its own copy is how
/// two views of the same schematic start disagreeing.
///
/// Refdes anchors likewise come from `ckt.geom`, which has already resolved label
/// collisions against neighboring bodies; this function only positions the text where
/// it was told.
///
/// Borrowed: reads `placed` and writes `w`, retaining neither.
pub fn writeSymbols(placed: Placed, cfg: *const Config, w: *Writer) Writer.Error!void {
    var buf: [scratch_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const d = Derived.init(placed, &fba);

    const ir = placed.ir;
    const stroke = cfg.render.stroke;
    for (0..ir.deviceCount()) |i| {
        const o = ir.dev_orient[i];
        const base = placed.physical.pos[i];
        const class = d.table.at(ir.dev_symbol[i]);

        try w.print(
            "<g fill=\"none\" stroke=\"{s}\" stroke-width=\"{d}\">\n",
            .{ stroke, cfg.render.sym_w },
        );
        for (class.draw) |op| switch (op) {
            .line => |l| {
                const a = base.add(o.apply(l.a));
                const b = base.add(o.apply(l.b));
                try w.print("<line x1=\"{d}\" y1=\"{d}\" x2=\"{d}\" y2=\"{d}\"/>\n", .{
                    a.x, a.y, b.x, b.y,
                });
            },
            .polyline => |pts| {
                try w.writeAll("<polyline points=\"");
                for (pts, 0..) |p, k| {
                    if (k > 0) try w.writeByte(' ');
                    try writePoint(base.add(o.apply(p)), w);
                }
                try w.writeAll("\"/>\n");
            },
            .circle => |c| {
                const q = base.add(o.apply(c.c));
                try w.print("<circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\"/>\n", .{ q.x, q.y, c.r });
            },
            // Anchored at the glyph centre and drawn upright: orientation moves where a
            // pin label sits, never how it reads. `textLength` pins the rendered width to
            // the one `catalog.textWidth` promised, so the class bbox holds in any viewer.
            .text => |t| {
                const q = base.add(o.apply(t.at));
                try w.print(
                    "<text x=\"{d}\" y=\"{d}\" font-size=\"{d}\" fill=\"{s}\" stroke=\"none\" " ++
                        "text-anchor=\"middle\" dominant-baseline=\"central\" " ++
                        "textLength=\"{d}\" lengthAdjust=\"spacingAndGlyphs\">",
                    .{ q.x, q.y, t.size, stroke, catalog.textWidth(t.s, t.size) },
                );
                try writeEscaped(t.s, w);
                try w.writeAll("</text>\n");
            },
        };
        try w.writeAll("</g>\n");

        const name = placed.strings.get(ir.dev_name[i]);
        const at = d.anchor(placed, i);
        try w.print(
            "<text x=\"{d}\" y=\"{d}\" font-size=\"7\" fill=\"#444\" " ++
                "textLength=\"{d}\" lengthAdjust=\"spacingAndGlyphs\">",
            // The collision box carries two units of padding the glyphs must not claim.
            .{ at.x, at.y, geom.refdesWidth(name) - 2 },
        );
        try writeEscaped(name, w);
        try w.writeAll("</text>\n");
    }
}

/// Emit routed wires as one `<polyline>` per segment.
///
/// Walks the nested CSR in `placed.physical`: net → segments → points. Consecutive
/// points are guaranteed axis-aligned by the router, so no smoothing, corner-fitting
/// or diagonal handling is needed or wanted — a diagonal here would be a bug upstream
/// and should show up in the drawing rather than be silently rounded away.
///
/// Nets that routing could not connect have no segments; they appear through
/// `writeLabels` instead.
pub fn writeWires(placed: Placed, cfg: *const Config, w: *Writer) Writer.Error!void {
    const phys = placed.physical;
    for (0..placed.ir.netCount()) |net| {
        for (phys.net_seg[net]..phys.net_seg[net + 1]) |seg| {
            const pts = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
            if (pts.len < 2) continue;
            try w.writeAll("<polyline points=\"");
            for (pts, 0..) |p, k| {
                if (k > 0) try w.writeByte(' ');
                try writePoint(p, w);
            }
            try w.print(
                "\" fill=\"none\" stroke=\"#{s}\" stroke-width=\"{d}\" " ++
                    "stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n",
                .{ cfg.render.wire, cfg.render.wire_w },
            );
        }
    }
}

/// Emit a filled dot at every point in `placed.physical.junctions`.
///
/// The library has already decided which meetings are junctions: three or more
/// same-net arms get a dot, two arms is a corner and gets none. This function does not
/// re-derive that from the polylines, because a renderer that counts arms itself will
/// eventually disagree with the C ABI over an ambiguous crossing.
pub fn writeJunctions(placed: Placed, cfg: *const Config, w: *Writer) Writer.Error!void {
    for (placed.physical.junctions) |p| {
        try w.print("<circle cx=\"{d}\" cy=\"{d}\" r=\"3\" fill=\"#{s}\"/>\n", .{
            p.x, p.y, cfg.render.wire,
        });
    }
}

/// Emit a name tag for every net in `placed.physical.labels`.
///
/// A label means the lattice search proved no tree exists for that net, so it is real
/// information about the drawing rather than a rendering shortcut. Styled distinctly
/// from device text so a reader can tell a dropped connection from an annotation at a
/// glance.
pub fn writeLabels(placed: Placed, cfg: *const Config, w: *Writer) Writer.Error!void {
    for (placed.physical.labels) |l| {
        const name = placed.strings.get(placed.ir.net_name[l.net.i()]);
        // A tick at the label point plus the net name beside it: a dropped connection
        // has to be legible as a dropped connection, not mistaken for an annotation.
        try w.print("<circle cx=\"{d}\" cy=\"{d}\" r=\"2\" fill=\"#c62828\"/>\n", .{ l.at.x, l.at.y });
        try w.print(
            "<text x=\"{d}\" y=\"{d}\" font-size=\"7\" fill=\"#c62828\" font-style=\"italic\" " ++
                "textLength=\"{d}\" lengthAdjust=\"spacingAndGlyphs\">",
            .{ l.at.x + 4, l.at.y - 3, ckt.geom.refdesWidth(name) - 2 },
        );
        try writeEscaped(name, w);
        try w.writeAll("</text>\n");
    }
    _ = cfg; // Labels are styled distinctly from every configurable stroke, by design.
}

/// Write `s` with the five XML metacharacters replaced by entities.
///
/// Net and device names come from a SPICE file and are attacker-controlled as far as
/// this program is concerned, so escaping is unconditional rather than
/// "when it looks like it needs it". Escapes `&`, `<`, `>`, `"` and `'`; passes every
/// other byte through unchanged, including non-ASCII, since SVG is UTF-8 and the
/// string pool holds valid UTF-8.
///
/// Streams directly to `w` — no intermediate buffer, no allocation, no length cap.
pub fn writeEscaped(s: []const u8, w: *Writer) Writer.Error!void {
    var flushed: usize = 0;
    for (s, 0..) |c, i| {
        const entity = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => continue,
        };
        // Runs between metacharacters go out in one call; the common case is one call
        // for the whole string.
        try w.writeAll(s[flushed..i]);
        try w.writeAll(entity);
        flushed = i + 1;
    }
    try w.writeAll(s[flushed..]);
}

/// Write a single point as `"x,y"`, the form every SVG points list uses.
///
/// Integers only. Exists so that the coordinate format is stated once rather than
/// spelled out at each of the four call sites, which is where a stray space or a
/// swapped axis creeps in.
pub fn writePoint(p: Pt, w: *Writer) Writer.Error!void {
    try w.print("{d},{d}", .{ p.x, p.y });
}
