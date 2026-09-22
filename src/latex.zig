//! CircuiTikZ emitter: a `Placed` as a `circuitikz` picture that `pdflatex`
//! draws. Compiled only with `-Dlatex_renderer=true` (`root.latex` is `void`
//! otherwise, so a stale reference names the missing option).
//!
//! A device whose class is in the layout's vocabulary is drawn as the
//! CircuiTikZ component for it: two-pin parts as `to[R]`, `to[C]`, … between
//! their pin points, transistors and the op-amp as nodes turned to the
//! device's placement, with a lead from each anchor to its pin point (the
//! components are not the size of the library's symbols; the wires end on
//! the pins either way). Rails, ports and junction dots are `vdd`, `ground`,
//! `ocirc` and `circ` nodes. Any other class — a generated box, a subcircuit
//! block — is drawn from its strokes. Needs `\usepackage[american]{circuitikz}`.
//!
//! The one emitter inside the library, as in cktImg: a paper figure is a
//! user-facing feature, so it comes from the library a user links, not a
//! sample they vendor. Everything it needs to agree with other renderers —
//! placed strokes, name anchors — comes from `geom`.
//!
//! Coordinates: one target unit is one point, and y is negated at the one
//! place points are written (`writePoint`), since TikZ's y grows upwards.
//! Streamed: nothing but the name anchors is allocated.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const library = @import("library.zig");
const placed_mod = @import("placed.zig");
const geom = @import("geom.zig");
const config = @import("config.zig");

const Pt = library.Pt;
const Orient = library.Orient;
const Library = library.Library;
const Placed = placed_mod.Placed;
const Config = config.Config;

pub const Error = Writer.Error || Allocator.Error;

/// One `\definecolor` and one `circuitikz` picture: wires, components with
/// their names, dots, net labels, no-connect crosses.
pub fn write(gpa: Allocator, p: *const Placed, lib: *const Library, cfg: *const Config, w: *Writer) Error!void {
    const anchors = try geom.refdesAnchors(gpa, p, lib);
    defer gpa.free(anchors);

    try w.writeAll("\\definecolor{cktwire}{HTML}{");
    for (cfg.render.wire) |c| try w.writeByte(std.ascii.toUpper(c));
    try w.writeAll("}%\n\\begin{circuitikz}[x=1pt,y=1pt,\n");
    try w.print("  cktsym/.style={{draw=black,line width={d}pt,line cap=round,line join=round}},\n", .{cfg.render.sym_w});
    try w.print("  cktwire/.style={{draw=cktwire,line width={d}pt,line cap=round,line join=round}},\n", .{cfg.render.wire_w});
    try w.writeAll(
        \\  cktdot/.style={fill=cktwire},
        \\  cktlbl/.style={font=\tiny,text=black!55,anchor=base west,inner sep=0pt},
        \\  cktnet/.style={font=\tiny\itshape,text=cktwire,inner sep=1pt},
        \\  cktsymlbl/.style={text=black,anchor=center,inner sep=0pt}]
        \\  \ctikzset{bipoles/length=40pt, amplifiers/scale=0.6}
        \\
    );
    for (0..p.netCount()) |n| {
        var it = p.segments(n);
        while (it.next()) |poly| try writePath(w, "cktwire", .r0, .zero, poly);
    }
    for (0..p.deviceCount()) |d| {
        if (!try writeComponent(p, lib, d, w)) try writeDevice(p, lib, d, w);
        if (p.dev_name[d].len > 0) {
            try w.writeAll("  \\node[cktlbl] at ");
            try writePoint(w, anchors[d]);
            try w.print(" {{\\makebox[{d}pt][l]{{", .{geom.refdesWidth(p.dev_name[d])});
            try escape(w, p.dev_name[d]);
            try w.writeAll("}};\n");
        } else if (lib.at(p.dev_class[d]).role != .none) {
            // A rail or port the layout added: its net's name beside the pin,
            // away from its wire.
            const lo, _ = p.pinRange(d);
            const role = lib.at(p.dev_class[d]).role;
            const name = p.net_name[p.pin_net[lo]];
            if (role == .ground_rail and !geom.namesRail(name)) continue;
            const side: library.Side = switch (role) {
                .power_rail => .up,
                .ground_rail => .down,
                else => geom.nameSide(p, lo),
            };
            const anchor = switch (side) {
                .right => "west",
                .left => "east",
                .up => "south",
                .down => "north",
            };
            const nudge: Pt = switch (side) {
                .right => .{ .x = 5, .y = 0 },
                .left => .{ .x = -5, .y = 0 },
                .up => .{ .x = 0, .y = -3 },
                .down => .{ .x = 0, .y = 8 },
            };
            try w.print("  \\node[cktnet,anchor={s}] at ", .{anchor});
            try writePoint(w, p.pin_xy[lo].add(nudge));
            try w.writeAll(" {");
            try escape(w, name);
            try w.writeAll("};\n");
        }
    }
    for (p.junctions) |j| {
        try w.writeAll("  \\draw ");
        try writePoint(w, j);
        try w.writeAll(" node[circ]{};\n");
    }
    for (p.no_connects) |c| {
        try writePath(w, "cktsym", .r0, .zero, &.{ .{ .x = c.x - 3, .y = c.y - 3 }, .{ .x = c.x + 3, .y = c.y + 3 } });
        try writePath(w, "cktsym", .r0, .zero, &.{ .{ .x = c.x - 3, .y = c.y + 3 }, .{ .x = c.x + 3, .y = c.y - 3 } });
    }
    for (p.labels) |l| {
        const anchor = switch (l.side) {
            .right => "west",
            .left => "east",
            .up => "south",
            .down => "north",
        };
        try w.print("  \\node[cktnet,anchor={s}] at ", .{anchor});
        try writePoint(w, l.at);
        try w.writeAll(" {");
        try escape(w, p.net_name[l.net]);
        try w.writeAll("};\n");
    }
    try w.writeAll("\\end{circuitikz}\n");
}

/// `(<x>pt,<-y>pt)`: the one place y is negated.
pub fn writePoint(w: *Writer, p: Pt) Writer.Error!void {
    try w.print("({d}pt,{d}pt)", .{ p.x, -p.y });
}

/// TeX specials in a name, escaped.
pub fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    var run: usize = 0;
    for (s, 0..) |c, i| {
        const sub: []const u8 = switch (c) {
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

fn writePath(w: *Writer, style: []const u8, o: Orient, base: Pt, pts: []const Pt) Writer.Error!void {
    if (pts.len < 2) return;
    try w.print("  \\draw[{s}] ", .{style});
    for (pts, 0..) |q, i| {
        if (i > 0) try w.writeAll(" -- ");
        try writePoint(w, geom.placePoint(o, base, q));
    }
    try w.writeAll(";\n");
}

fn writeCircle(w: *Writer, op: []const u8, c: Pt, r: i32) Writer.Error!void {
    try w.print("  \\{s} ", .{op});
    try writePoint(w, c);
    try w.print(" circle[radius={d}pt];\n", .{r});
}

// ---------------------------------------------------------------------------
// CircuiTikZ components
// ---------------------------------------------------------------------------

/// Two-pin classes: the `to[...]` bipole, drawn from pin 0 to pin 1.
const bipoles = std.StaticStringMap([]const u8).initComptime(.{
    .{ "res", "R" },      .{ "cap", "C" },     .{ "ind", "L" },
    .{ "vsource", "V" },  .{ "isource", "I" }, .{ "diode", "D" },
    .{ "bsource", "cV" }, .{ "ccvs", "cV" },   .{ "cccs", "cI" },
});

/// Node components: the CircuiTikZ shape, and for each class terminal (in
/// SPICE order) its anchor and where CircuiTikZ puts it unturned (y up).
const Node = struct { shape: []const u8, anchors: []const []const u8, at: []const [2]f32 };
const mos_at = [_][2]f32{ .{ 0, 21.9 }, .{ -27.9, 0 }, .{ 0, -21.9 } };
const pmos_at = [_][2]f32{ .{ 0, -21.9 }, .{ -27.9, 0 }, .{ 0, 21.9 } };
const bjt_at = [_][2]f32{ .{ 0, 21.9 }, .{ -23.9, 0 }, .{ 0, -21.9 } };
const pnp_at = [_][2]f32{ .{ 0, -21.9 }, .{ -23.9, 0 }, .{ 0, 21.9 } };
const jfet_at = [_][2]f32{ .{ 0, 21.9 }, .{ -27.9, -7.7 }, .{ 0, -21.9 } };
const nodes = std.StaticStringMap(Node).initComptime(.{
    .{ "nmos", Node{ .shape = "nmos", .anchors = &.{ "D", "G", "S" }, .at = &mos_at } },
    .{ "pmos", Node{ .shape = "pmos", .anchors = &.{ "D", "G", "S" }, .at = &pmos_at } },
    .{ "npn", Node{ .shape = "npn", .anchors = &.{ "C", "B", "E" }, .at = &bjt_at } },
    .{ "pnp", Node{ .shape = "pnp", .anchors = &.{ "C", "B", "E" }, .at = &pnp_at } },
    .{ "njfet", Node{ .shape = "njfet", .anchors = &.{ "D", "G", "S" }, .at = &jfet_at } },
    .{ "pjfet", Node{ .shape = "pjfet", .anchors = &.{ "D", "G", "S" }, .at = &jfet_at } },
    // out+ out- in+ in-: the reference has no anchor (drawn only on ground).
    .{ "cvsource", Node{ .shape = "op amp, noinv input up", .anchors = &.{ "out", "", "+", "-" }, .at = &.{ .{ 20.3, 0 }, .{ 0, 0 }, .{ -20.3, 8.4 }, .{ -20.3, -8.4 } } } },
});

/// Draws device `d` as a CircuiTikZ component; false when its class has
/// none (the caller draws its strokes).
fn writeComponent(p: *const Placed, lib: *const Library, d: usize, w: *Writer) Writer.Error!bool {
    const class = lib.at(p.dev_class[d]);
    const lo, const hi = p.pinRange(d);
    const pins = p.pin_xy[lo..hi];
    if (p.dev_name[d].len == 0 and class.role != .none) {
        const shape = switch (class.role) {
            .power_rail => "vdd",
            .ground_rail => "ground",
            else => "ocirc",
        };
        try w.writeAll("  \\draw ");
        try writePoint(w, pins[0]);
        try w.print(" node[{s}]{{}};\n", .{shape});
        return true;
    }
    if (bipoles.get(class.name)) |kind| {
        if (pins.len < 2) return false;
        try w.writeAll("  \\draw ");
        try writePoint(w, pins[0]);
        try w.print(" to[{s}] ", .{kind});
        try writePoint(w, pins[1]);
        try w.writeAll(";\n");
        return true;
    }
    const n = nodes.get(class.name) orelse return false;
    if (pins.len < n.anchors.len) return false;
    // An op-amp symbol has no reference pin: only when nothing is wired to it.
    for (n.anchors, 0..) |a, k| if (a.len == 0 and wired(p, lo + @as(u32, @intCast(k)))) return false;
    // The turn and mirror that best point each anchor where its pin is.
    const origin = p.dev_pos[d];
    var best: struct { rot: u32 = 0, mirror: bool = false, score: f32 = -1e9 } = .{};
    for (0..8) |k| {
        const rot: u32 = @intCast(k & 3);
        const mirror = k >= 4;
        var score: f32 = 0;
        for (n.anchors, n.at, 0..) |a, at, i| {
            if (a.len == 0) continue;
            const v = turn(at, rot, mirror);
            const t = [2]f32{ @floatFromInt(pins[i].x - origin.x), @floatFromInt(origin.y - pins[i].y) };
            score += (v[0] * t[0] + v[1] * t[1]) / (@sqrt(v[0] * v[0] + v[1] * v[1]) * @max(1, @sqrt(t[0] * t[0] + t[1] * t[1])));
        }
        if (score > best.score) best = .{ .rot = rot, .mirror = mirror, .score = score };
    }
    try w.writeAll("  \\draw ");
    try writePoint(w, origin);
    try w.print(" node[{s}, rotate={d}, xscale={s}] (d{d}) {{}};\n", .{ n.shape, best.rot * 90, if (best.mirror) "-1" else "1", d });
    // Leads: from each anchor straight out, then across onto the pin.
    for (n.anchors, 0..) |a, i| {
        if (a.len == 0) continue;
        const v = turn(n.at[i], best.rot, best.mirror);
        const pin = pins[i];
        // A horizontal anchor runs to the pin's x first (`-|`), a vertical
        // one to the pin's y first (`|-`).
        const bend = if (@abs(v[0]) >= @abs(v[1])) "-|" else "|-";
        try w.print("  \\draw[cktsym] (d{d}.{s}) {s} ", .{ d, a, bend });
        try writePoint(w, pin);
        try w.writeAll(";\n");
    }
    return true;
}

/// A CircuiTikZ point turned: mirror (x), then `rot` quarter turns counter-
/// clockwise — what `rotate=90·rot, xscale=±1` does to a node (measured).
fn turn(v: [2]f32, rot: u32, mirror: bool) [2]f32 {
    var q = if (mirror) [2]f32{ -v[0], v[1] } else v;
    for (0..rot) |_| q = .{ -q[1], q[0] };
    return q;
}

/// Some wire of the pin's net ends on the pin's point.
fn wired(p: *const Placed, pin: u32) bool {
    const net = p.pin_net[pin];
    if (net == placed_mod.no_net) return false;
    var it = p.segments(net);
    while (it.next()) |poly| {
        if (poly[0].eql(p.pin_xy[pin]) or poly[poly.len - 1].eql(p.pin_xy[pin])) return true;
    }
    return false;
}

fn writeDevice(p: *const Placed, lib: *const Library, d: usize, w: *Writer) Writer.Error!void {
    const o = p.dev_orient[d];
    const base = p.dev_pos[d];
    for (lib.at(p.dev_class[d]).draw) |op| switch (op) {
        .line => |l| try writePath(w, "cktsym", o, base, &.{ l.a, l.b }),
        .polyline => |ps| try writePath(w, "cktsym", o, base, ps),
        .circle => |c| try writeCircle(w, "draw[cktsym,fill=white]", geom.placePoint(o, base, c.c), c.r),
        .text => |t| {
            try w.print("  \\node[cktsymlbl,font=\\fontsize{{{d}}}{{{d}}}\\selectfont] at ", .{ t.size, t.size });
            try writePoint(w, geom.placePoint(o, base, t.at));
            try w.writeAll(" {");
            try escape(w, t.s);
            try w.writeAll("};\n");
        },
    };
}

test "latex: escape and point" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try escape(&w, "a_b%c");
    try writePoint(&w, .{ .x = 3, .y = 4 });
    try std.testing.expectEqualStrings("a\\_b\\%c(3pt,-4pt)", w.buffered());
}
