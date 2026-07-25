//! TikZ/PGF emitter: a placed schematic as a `tikzpicture` `pdflatex` draws itself.
//!
//! Compiled **only** when the `latex_renderer` build option is set; `root.latex` is
//! `void` otherwise, so a consumer who only wants geometry does not carry the escaping
//! tables and a reference to `latex.write` without the option is a compile error naming
//! the option rather than a link failure.
//!
//! This is the one format emitter that lives in the library rather than in `examples/`,
//! and the reason is who asks for it: paper figures are a *user-facing feature*, so they
//! should come from the library a user already links against, not from a sample they
//! have to vendor and keep in step with our geometry. SVG has no such claim — the
//! gallery is a development tool — so it stays outside on the same public API a
//! third-party adapter gets (ARCHITECTURE.md §2).
//!
//! ## Streamed, not accumulated
//!
//! The Rust renderer built one `String` with ~10 `write!`s per device and returned it,
//! so a 5,000-device figure existed twice: once in the `String` and once in whatever the
//! caller wrote it to. Here every function takes a `*std.Io.Writer`. Writing a figure
//! straight to a file never materializes it; a caller who wants bytes passes
//! `Writer.Allocating` and that is the only allocation.
//!
//! The two things that *are* allocated — refdes anchors and group frames — are allocated
//! because their results are order-dependent, not because of formatting: a label dodges
//! the labels already placed, so there is no per-device pure function to stream from.
//! Both come from `geom.zig`, both are freed before this function returns, and both are
//! the same answers the SVG gallery draws. That sharing is the point: two renderers that
//! each place their own labels are two renderers that disagree, and the first symptom is
//! a bug report from someone whose figure does not match the gallery.
//!
//! ## Coordinates: y-down layout into y-up TikZ
//!
//! The placer's y increases downwards (screen convention); TikZ's increases upwards. The
//! entire reconciliation is **negating y at the point of emission** — `writePoint` is the
//! only place it happens, and every coordinate in the output goes through it.
//!
//! Absolute `pt` units, no `x=`/`y=` scaling trickery. Unit scaling would make node
//! labels shear with the canvas and would make a circle's `radius=` ambiguous about
//! which axis it followed; one grid unit is one point, and the numbers in the output are
//! the numbers in `Physical`.
//!
//! ## The transform is not reimplemented here
//!
//! `ids.Orient.apply` is the single definition of mirror-then-rotate in the program.
//! `geom.zig` delegates to it and so does `placePoint` below — this file contains no
//! rotation arithmetic of its own, which is exactly the duplication that makes two
//! renderings of one schematic diverge. Bounding boxes come from `geom.bounds`, label
//! anchors from `geom.refdesAnchors`, frames from `geom.groupFrames`, and the forced
//! label width from `geom.refdesWidth`.
//!
//! ## Text widths are forced, not estimated
//!
//! Every label is wrapped in a `\makebox` of exactly the width the layout collided
//! against (`geom.refdesWidth`, `catalog.textWidth`). TeX therefore sets the glyphs into
//! the same box the placer reserved, so a label the layout says is clear is clear in the
//! PDF. Without the `\makebox` the two would agree only by luck, and only for the fonts
//! we happened to test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const ids = @import("ids.zig");
const irm = @import("ir.zig");
const catalog = @import("devices/catalog.zig");
const host = @import("devices/host.zig");
const geom = @import("geom.zig");
const config = @import("config.zig");

const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;
const Placed = irm.Placed;
const Config = config.Config;
const DrawOp = catalog.DrawOp;

/// Writer failure, or the allocator failing during the two order-dependent passes.
///
/// `OutOfMemory` can only come from `geom.refdesAnchors` and `geom.groupFrames`; the
/// emission itself allocates nothing.
pub const Error = Writer.Error || Allocator.Error;

/// Radius of a pin dot, in points.
pub const pin_dot_r: i32 = 2;
/// Radius of a junction dot. Larger than a pin dot so a T-junction reads as a
/// connection rather than as a terminal.
pub const junction_dot_r: i32 = 3;

/// Emit the whole figure: one `\definecolor` followed by one `tikzpicture`.
///
/// Drop the result into a document with `\usepackage{tikz,xcolor}`, or `\input` it.
/// Self-contained apart from those two packages — no custom macros, no external
/// converter, no raster step.
///
/// Draw order is deliberate and is what makes the figure readable: group frames first
/// (annotation belongs under the circuit), then wires, then symbols with their refdes
/// labels, then pin and junction dots on top, then the unrouted-net labels. A renderer
/// that reorders these gets dots hidden under symbol strokes.
///
/// - `gpa` backs `geom.refdesAnchors` and `geom.groupFrames` only. Both are released
///   before returning, so this function transfers no ownership and leaks nothing on the
///   error path.
/// - `placed` supplies the IR, the geometry and the string pool. Borrowed.
/// - `table` resolves every device's symbol class and must be the table the IR's
///   `SymbolIdx` values came from. Borrowed.
/// - `cfg` supplies `render.wire` (bare hex, no `#`; upper-cased here because TikZ's
///   `HTML` color model demands it), `render.sym_w` and `render.wire_w`. Borrowed.
/// - `w` receives the document.
///
/// Errors: `WriteFailed` from `w`, `OutOfMemory` from the two layout passes. Complexity
/// O(devices × draw ops + wire points), plus the quadratic-ish label pass `geom` owns.
pub fn write(
    gpa: Allocator,
    placed: Placed,
    table: *const host.Table,
    cfg: *const Config,
    w: *Writer,
) Error!void {
    // Both passes are order-dependent, so both must complete before a byte is emitted;
    // both are released here, so the figure transfers no ownership.
    const anchors = try geom.refdesAnchors(
        gpa,
        placed.ir,
        placed.physical,
        placed.strings,
        table,
    );
    defer gpa.free(anchors);
    const frames = try geom.groupFrames(gpa, placed.ir, placed.physical, placed.strings, table);
    defer gpa.free(frames);

    try writePreamble(cfg, w);
    // Annotation under the circuit, dots over it: see the doc comment on draw order.
    for (frames) |f| try writeGroup(placed, f, w);
    try writeWires(placed, w);
    for (0..placed.ir.deviceCount()) |d| {
        try writeDevice(placed, table, d, w);
        try writeTag(w, "cktlbl", anchors[d], placed.strings.get(placed.ir.dev_name[d]));
    }
    try writeDots(placed, w);
    try writeLabels(placed, w);
    try writeEpilogue(w);
}

/// One left-anchored, forced-width text node: a refdes or an unrouted-net tag.
///
/// The `\makebox` is the whole point — its width is the box `geom` collided against, so
/// TeX sets the glyphs into the space the layout reserved instead of into whatever the
/// font happens to need.
fn writeTag(w: *Writer, style: []const u8, at: Pt, s: []const u8) Writer.Error!void {
    try w.print("  \\node[{s}] at ", .{style});
    try writePoint(w, at);
    try w.print(" {{\\makebox[{d}pt][l]{{", .{geom.refdesWidth(s)});
    try escape(w, s);
    try w.writeAll("}};\n");
}

/// Emit the preamble: the wire color definition, `\begin{tikzpicture}` and the five
/// styles the body uses.
///
/// Split out because it is the part a host embedding our figure inside its own picture
/// wants to replace, and because it is the only part that reads `cfg`.
///
/// The styles, and why each is what it is:
///
/// - `cktsym` — symbol strokes. `line cap/join=round` so a zigzag resistor's corners do
///   not spike.
/// - `cktwire` — wire strokes, in the configured color.
/// - `cktdot` — filled connection dots, same color as the wires.
/// - `cktlbl` — refdes labels. `anchor=base west` is the left-edge-on-baseline semantics
///   `geom.refdesAnchors` computes for, matching SVG `<text>`, so the shared anchors
///   mean the same point in both backends. `inner sep=0pt` because the `\makebox` in the
///   node body already *is* the collision box and the node must add nothing to it.
/// - `cktsymlbl` — symbol-internal text (pin names, block titles), centred and upright.
/// - `cktgroup` / `cktgrouplbl` — subckt frames: grey, dashed, rounded, so they read as
///   annotation rather than as wiring.
///
/// Errors: `WriteFailed`.
pub fn writePreamble(cfg: *const Config, w: *Writer) Writer.Error!void {
    try w.writeAll("\\definecolor{cktwire}{HTML}{");
    // TikZ's HTML colour model wants upper case; folding here rather than in `Config`
    // keeps the config value the same string the SVG backend writes verbatim.
    for (cfg.render.wire) |c| try w.writeByte(std.ascii.toUpper(c));
    try w.writeAll("}%\n");

    try w.writeAll("\\begin{tikzpicture}[\n");
    try w.print(
        "  cktsym/.style={{draw=black,line width={d}pt,line cap=round,line join=round}},\n",
        .{cfg.render.sym_w},
    );
    try w.print(
        "  cktwire/.style={{draw=cktwire,line width={d}pt,line cap=round,line join=round}},\n",
        .{cfg.render.wire_w},
    );
    try w.writeAll(
        \\  cktdot/.style={fill=cktwire},
        \\  cktlbl/.style={font=\tiny,text=black!55,anchor=base west,inner sep=0pt},
        \\  cktsymlbl/.style={text=black,anchor=center,inner sep=0pt},
        \\  cktgroup/.style={draw=black!40,dashed,rounded corners=3pt,line width=0.6pt},
        \\  cktgrouplbl/.style={font=\tiny,text=black!40,anchor=base west,inner sep=0pt}]
        \\
    );
}

/// Emit `\end{tikzpicture}` and its newline.
pub fn writeEpilogue(w: *Writer) Writer.Error!void {
    try w.writeAll("\\end{tikzpicture}\n");
}

/// Emit one placed point as a TikZ coordinate literal: `(<x>pt,<-y>pt)`.
///
/// **The y-negation lives here and nowhere else.** Every coordinate in the output passes
/// through this function, which is what makes "the figure is not vertically mirrored" a
/// property of one line rather than of every call site.
///
/// Integers only, so this is two `i32` formats and no float, no locale and no rounding.
/// Grid coordinates are far inside `i32`, so the negation cannot overflow for any
/// schematic the placer can produce.
pub fn writePoint(w: *Writer, p: Pt) Writer.Error!void {
    try w.print("({d}pt,{d}pt)", .{ p.x, -p.y });
}

/// Emit a polyline as `(x0pt,y0pt) -- (x1pt,y1pt) -- …`, with no leading `\draw` and no
/// trailing semicolon.
///
/// Writes nothing for fewer than two points: a one-point "polyline" is not drawable and
/// TikZ would silently accept the degenerate path. Asserts nothing — a short run is a
/// data condition the router can legitimately produce.
pub fn writePath(w: *Writer, pts: []const Pt) Writer.Error!void {
    if (pts.len < 2) return;
    for (pts, 0..) |p, i| {
        if (i > 0) try w.writeAll(" -- ");
        try writePoint(w, p);
    }
}

/// Escape the TeX specials that can appear in a name, writing the result to `w`.
///
/// | input | output |
/// |---|---|
/// | `\` | `\textbackslash{}` |
/// | `^` | `\textasciicircum{}` |
/// | `~` | `\textasciitilde{}` |
/// | `& % $ # _ { }` | the same character, backslash-prefixed |
///
/// The first three need command forms because a backslash-prefixed `\^` is an accent
/// rather than a character, and `\~` likewise; the `{}` suffix stops TeX from swallowing
/// a following space. Everything else passes through byte for byte, including UTF-8
/// continuation bytes — the front end rejects non-ASCII names, and re-encoding valid
/// UTF-8 here would only misalign the forced label widths, which count bytes.
///
/// Public because a host adding its own annotations to our picture needs exactly this
/// table, and a second copy of it is how one renderer starts emitting a `_` that TeX
/// reads as a subscript.
///
/// Errors: `WriteFailed`. Allocation-free, one pass, no buffering.
pub fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    // Run-batched: a name with no specials — which is nearly all of them — costs one
    // `writeAll` rather than one call per byte.
    var run: usize = 0;
    for (s, 0..) |c, i| {
        const sub: []const u8 = switch (c) {
            // A backslash-prefixed `\^` or `\~` is an accent, not a character, so these
            // three need command forms; the `{}` stops TeX eating a following space.
            '\\' => "\\textbackslash{}",
            '^' => "\\textasciicircum{}",
            '~' => "\\textasciitilde{}",
            '&' => "\\&",
            '%' => "\\%",
            '$' => "\\$",
            '#' => "\\#",
            '_' => "\\_",
            '{' => "\\{",
            '}' => "\\}",
            else => continue,
        };
        try w.writeAll(s[run..i]);
        run = i + 1;
        try w.writeAll(sub);
    }
    try w.writeAll(s[run..]);
}

/// A canonical symbol-local point, placed: mirrored, rotated, then translated.
///
/// Delegates to `ids.Orient.apply`, the program's single definition of mirror-then-
/// rotate, and adds `base`. Nothing here re-derives the rotation matrix — that is the
/// whole reason this one-liner is a named, public function instead of being inlined at
/// the four op sites below.
///
/// Pure, allocation-free, exact in integers: a quarter turn is a coordinate swap and a
/// sign flip.
pub fn placePoint(o: Orient, base: Pt, p: Pt) Pt {
    return base.add(o.apply(p));
}

/// Emit one device's symbol body: every draw op, placed.
///
/// Lines and polylines become `\draw[cktsym]` paths. A circle becomes
/// `circle[radius=<r>pt]` around its placed centre, with the radius **unchanged** —
/// rotation and mirroring preserve it and there is no scaling in this coordinate system.
/// Text becomes a `cktsymlbl` node wrapped in `\makebox[<catalog.textWidth>pt][c]{…}`,
/// drawn upright at its placed anchor: orientation moves where symbol text sits, never
/// how it reads, or a mirrored flip-flop renders `KLC`.
///
/// `d` is a device subscript, asserted in range. Errors: `WriteFailed`. Allocation-free.
pub fn writeDevice(
    placed: Placed,
    table: *const host.Table,
    d: usize,
    w: *Writer,
) Writer.Error!void {
    std.debug.assert(d < placed.ir.deviceCount());
    const o = placed.ir.dev_orient[d];
    const base = placed.physical.pos[d];

    for (table.at(placed.ir.dev_symbol[d]).draw) |op| switch (op) {
        .line => |l| {
            const pair = [2]Pt{ placePoint(o, base, l.a), placePoint(o, base, l.b) };
            try w.writeAll("  \\draw[cktsym] ");
            try writePath(w, &pair);
            try w.writeAll(";\n");
        },
        .polyline => |ps| {
            if (ps.len < 2) continue;
            try w.writeAll("  \\draw[cktsym] ");
            for (ps, 0..) |p, i| {
                if (i > 0) try w.writeAll(" -- ");
                try writePoint(w, placePoint(o, base, p));
            }
            try w.writeAll(";\n");
        },
        .circle => |c| {
            try w.writeAll("  \\draw[cktsym] ");
            try writePoint(w, placePoint(o, base, c.c));
            // The radius is untouched: a quarter turn and a mirror both preserve it.
            try w.print(" circle[radius={d}pt];\n", .{c.r});
        },
        .text => |t| {
            // Upright regardless of orientation: only the anchor moves, or a mirrored
            // flip-flop reads `KLC`.
            try w.print(
                "  \\node[cktsymlbl,font=\\fontsize{{{d}}}{{{d}}}\\selectfont] at ",
                .{ t.size, t.size },
            );
            try writePoint(w, placePoint(o, base, t.at));
            try w.print(" {{\\makebox[{d}pt][c]{{", .{catalog.textWidth(t.s, t.size)});
            try escape(w, t.s);
            try w.writeAll("}};\n");
        },
    };
}

/// Emit every routed wire, net by net, segment by segment.
///
/// Walks the nested CSR directly — `net_seg` then `seg_pt` into `wire_pts` — with no
/// intermediate list. Segments of fewer than two points are skipped rather than emitted
/// as degenerate paths.
///
/// Errors: `WriteFailed`. Allocation-free.
pub fn writeWires(placed: Placed, w: *Writer) Writer.Error!void {
    const phys = placed.physical;
    for (0..placed.ir.netCount()) |n| {
        for (phys.net_seg[n]..phys.net_seg[n + 1]) |seg| {
            const pts = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
            if (pts.len < 2) continue;
            try w.writeAll("  \\draw[cktwire] ");
            try writePath(w, pts);
            try w.writeAll(";\n");
        }
    }
}

/// Emit the pin dots and the junction dots, in that order.
///
/// Pin dots mark every terminal; junction dots mark only where three or more same-net
/// arms meet, and are larger so the two read differently. Both are `cktdot`, so they
/// take the wire color and a reader sees them as part of the wiring.
///
/// Errors: `WriteFailed`. Allocation-free.
pub fn writeDots(placed: Placed, w: *Writer) Writer.Error!void {
    for (placed.physical.pin_xy) |p| try writeDot(w, p, pin_dot_r);
    for (placed.physical.junctions) |p| try writeDot(w, p, junction_dot_r);
}

fn writeDot(w: *Writer, p: Pt, r: i32) Writer.Error!void {
    try w.writeAll("  \\fill[cktdot] ");
    try writePoint(w, p);
    try w.print(" circle[radius={d}pt];\n", .{r});
}

/// Emit the tags standing in for nets the router could not connect.
///
/// The Rust renderer had no equivalent, so a figure of a hard schematic silently dropped
/// connectivity it actually had. Each label is a `cktlbl` node at its anchor carrying the
/// escaped net name, wrapped in the same forced-width `\makebox` as a refdes so it
/// occupies the box the layout reserved for it.
///
/// Writes nothing when there are no labels, which is the normal case.
///
/// Errors: `WriteFailed`. Allocation-free.
pub fn writeLabels(placed: Placed, w: *Writer) Writer.Error!void {
    for (placed.physical.labels) |l| {
        const name = placed.strings.get(placed.ir.net_name[l.net.i()]);
        try writeTag(w, "cktlbl", l.at, name);
    }
}

/// Emit the dashed frame and title for one flattened subckt instance.
///
/// The title is `"<path> : <master>"`, formatted here rather than carried on the
/// `GroupBox`: `geom` keeps the two `StrId`s so each emitter spells the separator in its
/// own syntax and nothing allocates a string the renderer immediately re-escapes.
///
/// Errors: `WriteFailed`. Allocation-free.
pub fn writeGroup(
    placed: Placed,
    box: geom.GroupBox,
    w: *Writer,
) Writer.Error!void {
    try w.writeAll("  \\draw[cktgroup] ");
    try writePoint(w, box.rect.min);
    try w.writeAll(" rectangle ");
    try writePoint(w, box.rect.max);
    try w.writeAll(";\n");

    // `"<path> : <master>"` is spelled here rather than carried on the `GroupBox`, so
    // nothing allocates a string this function would immediately re-escape.
    try w.writeAll("  \\node[cktgrouplbl] at ");
    try writePoint(w, box.label_at);
    try w.writeAll(" {");
    try escape(w, placed.strings.get(box.path));
    try w.writeAll(" : ");
    try escape(w, placed.strings.get(box.master));
    try w.writeAll("};\n");
}
