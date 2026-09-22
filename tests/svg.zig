//! The tests' target: a `Placed` drawn as SVG from its classes' strokes.
//!
//! Built on the public surface only — `Placed`, the `Library` the drawing
//! was placed with, and `geom` for the device names — so anything it draws,
//! an outside renderer can draw the same way.

const std = @import("std");
const np = @import("NetlistParser");

const Pt = np.Pt;
const Writer = std.Io.Writer;

pub const Style = struct {
    /// Pixels per target unit (a symbol is 40 units: 64 px).
    scale: f32 = 1.6,
    /// Pixels around the drawing.
    margin: f32 = 40,
    caption: []const u8 = "",
};

const ink = "#1d2330";
const name_ink = "#56607a";
const net_ink = "#2a62b8";

const Pen = struct {
    w: *Writer,
    st: Style,
    origin: Pt,

    fn x(p: *const Pen, v: i32) f32 {
        return p.st.margin + @as(f32, @floatFromInt(v - p.origin.x)) * p.st.scale;
    }
    fn y(p: *const Pen, v: i32) f32 {
        return p.st.margin + @as(f32, @floatFromInt(v - p.origin.y)) * p.st.scale;
    }
    fn polyline(p: *const Pen, pts: []const Pt) Writer.Error!void {
        try p.w.writeAll("<polyline points=\"");
        for (pts) |q| try p.w.print("{d:.1},{d:.1} ", .{ p.x(q.x), p.y(q.y) });
        try p.w.writeAll("\"/>\n");
    }
    fn circle(p: *const Pen, c: Pt, r: f32, attrs: []const u8) Writer.Error!void {
        try p.w.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\" {s}/>\n", .{ p.x(c.x), p.y(c.y), r * p.st.scale, attrs });
    }
    fn text(p: *const Pen, at: Pt, dx: f32, dy: f32, s: []const u8, anchor: []const u8, size: f32, color: []const u8, italic: bool) Writer.Error!void {
        try p.w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"{s}\" font-size=\"{d:.0}\" fill=\"{s}\" stroke=\"none\"{s}>", .{ p.x(at.x) + dx, p.y(at.y) + dy, anchor, size, color, if (italic) " font-style=\"italic\"" else "" });
        for (s) |ch| switch (ch) {
            '<' => try p.w.writeAll("&lt;"),
            '>' => try p.w.writeAll("&gt;"),
            '&' => try p.w.writeAll("&amp;"),
            else => try p.w.writeByte(ch),
        };
        try p.w.writeAll("</text>\n");
    }
};

pub fn write(gpa: std.mem.Allocator, p: *const np.Placed, lib: *const np.Library, w: *Writer, st: Style) !void {
    const box = p.bounds(lib) orelse np.Rect.point(.zero);
    // Room for names hanging off the edges.
    const lo: Pt = .{ .x = box.min.x - 30, .y = box.min.y - 12 };
    const hi: Pt = .{ .x = box.max.x + 30, .y = box.max.y + 12 };
    const width = @as(f32, @floatFromInt(hi.x - lo.x)) * st.scale + 2 * st.margin;
    const height = @as(f32, @floatFromInt(hi.y - lo.y)) * st.scale + 2 * st.margin + 20;
    try w.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d:.0}" height="{d:.0}" viewBox="0 0 {d:.0} {d:.0}" font-family="Helvetica, Arial, sans-serif">
        \\<rect width="100%" height="100%" fill="#ffffff"/>
        \\
    , .{ width, height, width, height });
    const pen: Pen = .{ .w = w, .st = st, .origin = lo };

    // Wires under symbols, dots over both.
    try w.print("<g fill=\"none\" stroke=\"{s}\" stroke-width=\"1.6\" stroke-linejoin=\"round\" stroke-linecap=\"round\">\n", .{ink});
    for (0..p.netCount()) |n| {
        var it = p.segments(n);
        while (it.next()) |poly| try pen.polyline(poly);
    }
    for (0..p.deviceCount()) |d| try drawDevice(&pen, p, lib, d);
    for (p.no_connects) |c| {
        try pen.polyline(&.{ .{ .x = c.x - 3, .y = c.y - 3 }, .{ .x = c.x + 3, .y = c.y + 3 } });
        try pen.polyline(&.{ .{ .x = c.x - 3, .y = c.y + 3 }, .{ .x = c.x + 3, .y = c.y - 3 } });
    }
    try w.writeAll("</g>\n");
    for (p.junctions) |j| try pen.circle(j, @as(f32, @floatFromInt(np.geom.junction_dot_r)) * 0.8, "fill=\"" ++ ink ++ "\" stroke=\"none\"");

    // Names: devices where geom puts them, nets beside their point.
    const anchors = try np.geom.refdesAnchors(gpa, p, lib);
    defer gpa.free(anchors);
    for (0..p.deviceCount()) |d| {
        if (p.dev_name[d].len > 0) try pen.text(anchors[d], 0, 0, p.dev_name[d], "start", 11, name_ink, false);
    }
    for (p.labels) |l| try netName(&pen, l.at, l.side, p.net_name[l.net], true);
    try pen.text(lo, 0, height - st.margin - 6, st.caption, "start", 12, ink, false);
    try w.writeAll("</svg>\n");
}

pub fn alloc(gpa: std.mem.Allocator, p: *const np.Placed, lib: *const np.Library, st: Style) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try write(gpa, p, lib, &aw.writer, st);
    return aw.toOwnedSlice();
}

fn drawDevice(pen: *const Pen, p: *const np.Placed, lib: *const np.Library, d: usize) !void {
    const class = lib.at(p.dev_class[d]);
    const o = p.dev_orient[d];
    const base = p.dev_pos[d];
    const place = struct {
        fn f(or_: np.Orient, b: Pt, q: Pt) Pt {
            return np.geom.placePoint(or_, b, q);
        }
    }.f;
    for (class.draw) |op| switch (op) {
        .line => |l| try pen.polyline(&.{ place(o, base, l.a), place(o, base, l.b) }),
        .polyline => |ps| {
            var buf: [64]Pt = undefined;
            const n = @min(ps.len, buf.len);
            for (ps[0..n], buf[0..n]) |q, *r| r.* = place(o, base, q);
            try pen.polyline(buf[0..n]);
        },
        .circle => |c| try pen.circle(place(o, base, c.c), @floatFromInt(c.r), "fill=\"#ffffff\""),
        .text => |t| try pen.text(place(o, base, t.at), 0, 3, t.s, "middle", @floatFromInt(t.size + 4), ink, false),
    };
    // A rail or port the layout added carries its net's name.
    if (p.dev_name[d].len == 0 and class.role != .none) {
        const lo, _ = p.pinRange(d);
        const net = p.net_name[p.pin_net[lo]];
        const at = p.pin_xy[lo];
        switch (class.role) {
            .power_rail => try pen.text(at, 0, -6, net, "middle", 12, ink, false),
            .ground_rail => if (np.geom.namesRail(net)) try pen.text(at, 14, 10, net, "start", 11, name_ink, false),
            .input_port => try netName(pen, at, np.geom.nameSide(p, lo), net, false),
            .output_port => try netName(pen, at, np.geom.nameSide(p, lo), net, false),
            .none => {},
        }
    }
}

fn netName(pen: *const Pen, at: Pt, side: np.Side, name: []const u8, italic: bool) !void {
    const color = if (italic) net_ink else ink;
    switch (side) {
        .right => try pen.text(at, 7, 4, name, "start", 12, color, italic),
        .left => try pen.text(at, -7, 4, name, "end", 12, color, italic),
        .up => try pen.text(at, 0, -6, name, "middle", 12, color, italic),
        .down => try pen.text(at, 0, 16, name, "middle", 12, color, italic),
    }
}
