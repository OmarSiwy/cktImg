//! The result, as plain data: where every device, pin, wire, dot and name
//! went, in the target's integer coordinates (y down). No accessor is needed
//! to read it — every column is a slice — and it points at nothing but its
//! own arena, so it outlives the netlist and the schematic it came from.
//!
//! ## What becomes a device
//!
//! In order: the netlist's devices that are drawn (a pinless `K` card is
//! not), then one rail or port device per terminal symbol the layout drew
//! (unnamed: `dev_name` is empty, the net is on its one pin), then the
//! terminal symbols of the driver islands.
//!
//! A driver (R3: a source from a supply, input or bias net to ground) is not
//! wired into the circuit — its terminal symbols stand for it there — but it
//! is still a device a simulator needs, so it is drawn apart: left of the
//! circuit, standing between its own terminal symbol and a ground symbol.
//!
//! ## Where a wire meets a pin
//!
//! The layout routes to the point on a device's row or column line where the
//! pins facing that way reach. A class whose pin sits off that line (the
//! second input of an op-amp, split onto its own copy) gets a short lead from
//! there to the pin, so every wire ends exactly on its pin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const library = @import("library.zig");
const netlist_mod = @import("netlist.zig");
const sch = @import("schematic.zig");
const lay = @import("layout.zig");

const Pt = library.Pt;
const Rect = library.Rect;
const Orient = library.Orient;
const Side = library.Side;
const ClassId = library.ClassId;
const Library = library.Library;
const Schematic = sch.Schematic;
const EdgeId = netlist_mod.EdgeId;

/// A pin on no net, or a label about no net.
pub const no_net: u32 = std.math.maxInt(u32);

/// A net's name written at a point (a lab_pin): the text starts at `at` and
/// runs towards `side`.
pub const Label = struct {
    net: u32,
    at: Pt,
    side: Side,
};

pub const Placed = struct {
    arena: std.heap.ArenaAllocator,

    // --- devices ---
    /// Reference designator; empty for the rails and ports the layout added.
    dev_name: []const [:0]const u8,
    dev_class: []const ClassId,
    /// The card's text after the nodes (`nch w=10u`), empty for added ones.
    dev_value: []const [:0]const u8,
    /// Where the class's origin sits.
    dev_pos: []const Pt,
    dev_orient: []const Orient,
    /// Pins of device d: `dev_pin0[d] .. dev_pin0[d + 1]`, in SPICE node order.
    dev_pin0: []const u32,

    // --- pins ---
    /// `no_net` for a pin the card had but the class has no terminal for.
    pin_net: []const u32,
    /// The class terminal, placed; the device origin when there is none.
    pin_xy: []const Pt,

    // --- nets ---
    net_name: []const [:0]const u8,
    /// Wires: net n owns segments `net_seg[n] .. net_seg[n + 1]`; segment k
    /// is the polyline `wire_pts[seg_pt[k] .. seg_pt[k + 1]]`, Manhattan,
    /// at least two points.
    net_seg: []const u32,
    seg_pt: []const u32,
    wire_pts: []const Pt,
    /// Where three or more wire arms of one net meet: a dot. Every wire that
    /// reaches one ends there (a wire through it is split in two), so a
    /// consumer that joins wires only at their ends — xschem — connects them.
    junctions: []const Pt,
    /// Net names written where a wire gives way to a name (W8, W9, L4, L7),
    /// and on the tops of driver islands whose net has no port symbol.
    labels: []const Label,
    /// Pins alone on their net (W10): a cross.
    no_connects: []const Pt,

    pub fn deinit(self: *Placed) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn deviceCount(self: *const Placed) usize {
        return self.dev_class.len;
    }
    pub fn netCount(self: *const Placed) usize {
        return self.net_name.len;
    }
    pub fn pinRange(self: *const Placed, d: usize) struct { u32, u32 } {
        return .{ self.dev_pin0[d], self.dev_pin0[d + 1] };
    }

    /// The polylines of net `n`.
    pub fn segments(self: *const Placed, n: usize) Segments {
        return .{ .p = self, .k = self.net_seg[n], .end = self.net_seg[n + 1] };
    }

    pub const Segments = struct {
        p: *const Placed,
        k: u32,
        end: u32,
        pub fn next(it: *Segments) ?[]const Pt {
            if (it.k >= it.end) return null;
            defer it.k += 1;
            return it.p.wire_pts[it.p.seg_pt[it.k]..it.p.seg_pt[it.k + 1]];
        }
    };

    /// Device `d`'s symbol box, placed.
    pub fn deviceRect(self: *const Placed, lib: *const Library, d: usize) Rect {
        return self.dev_orient[d].applyRect(lib.at(self.dev_class[d]).bbox()).translate(self.dev_pos[d]);
    }

    /// Everything drawn: symbols, wires, dots, label points, crosses. Null
    /// for an empty drawing.
    pub fn bounds(self: *const Placed, lib: *const Library) ?Rect {
        var acc: ?Rect = null;
        const grow = struct {
            fn f(a: *?Rect, r: Rect) void {
                a.* = if (a.*) |c| c.merge(r) else r;
            }
        }.f;
        for (0..self.deviceCount()) |d| grow(&acc, self.deviceRect(lib, d));
        for (self.wire_pts) |p| grow(&acc, .point(p));
        for (self.junctions) |p| grow(&acc, .point(p));
        for (self.labels) |l| grow(&acc, .point(l.at));
        for (self.no_connects) |p| grow(&acc, .point(p));
        return acc;
    }

    /// Exports a laid-out schematic. `nl` is the netlist it was built from.
    pub fn init(gpa: Allocator, s: *const Schematic, nl: *const netlist_mod.Netlist) Allocator.Error!Placed {
        var b: Builder = .{ .arena = .init(gpa), .s = s, .nl = nl };
        errdefer b.arena.deinit();
        try b.run();
        return b.finish();
    }
};

// ===========================================================================
// Export
// ===========================================================================

const Builder = struct {
    arena: std.heap.ArenaAllocator,
    s: *const Schematic,
    nl: *const netlist_mod.Netlist,

    names: std.ArrayList([:0]const u8) = .empty,
    classes: std.ArrayList(ClassId) = .empty,
    values: std.ArrayList([:0]const u8) = .empty,
    pos: std.ArrayList(Pt) = .empty,
    orients: std.ArrayList(Orient) = .empty,
    pin0: std.ArrayList(u32) = .empty,
    pin_net: std.ArrayList(u32) = .empty,
    pin_xy: std.ArrayList(Pt) = .empty,
    /// Per net: its polylines, before packing.
    polys: []std.ArrayList([]const Pt) = &.{},
    labels: std.ArrayList(Label) = .empty,
    no_connects: std.ArrayList(Pt) = .empty,
    junctions: std.ArrayList(Pt) = .empty,

    fn a(b: *Builder) Allocator {
        return b.arena.allocator();
    }

    fn run(b: *Builder) !void {
        const s = b.s;
        const n_nets = s.net_name.len;
        b.polys = try b.a().alloc(std.ArrayList([]const Pt), n_nets);
        @memset(b.polys, .empty);
        try b.pin0.append(b.a(), 0);

        // Netlist devices in the drawing.
        const info = s.devices.slice();
        for (0..s.devices.len) |d| {
            if (!info.items(.kept)[d]) continue;
            const node = s.deviceNode(@intCast(d)) orelse continue;
            const origin = round(s.xy[node]).sub(info.items(.grid)[d]);
            try b.device(@intCast(d), origin, info.items(.orient)[d]);
        }
        // Wires, then the leads that bring them onto off-line pins.
        for (s.routes.items) |r| try b.poly(r.net, r.pts[0..r.len]);
        for (s.pins.items(.device), s.pins.items(.index), 0..) |d, idx, p| {
            if (d == sch.none) continue;
            const at = round(lay.pinPoint(s, @intCast(p)));
            const pin = b.devicePin(d, idx) orelse continue;
            const end = b.pin_xy.items[pin];
            if (at.eql(end)) continue;
            // Along the pin's side first, then across onto the pin.
            const corner: Pt = if (s.pins.items(.side)[p].isHorizontal()) .{ .x = end.x, .y = at.y } else .{ .x = at.x, .y = end.y };
            try b.poly(s.pins.items(.net)[p], &.{ toF(at), toF(corner), toF(end) });
        }
        for (s.dots.items) |p| try b.junctions.append(b.a(), round(p));
        for (s.no_connects.items) |p| {
            const d = s.pins.items(.device)[p];
            const pin = b.devicePin(d, s.pins.items(.index)[p]) orelse continue;
            try b.no_connects.append(b.a(), b.pin_xy.items[pin]);
        }
        try b.names_();

        // Terminal symbols: one rail or port per terminal the layout drew.
        const kinds = s.nodes.items(.kind);
        for (kinds, s.nodes.items(.ref), s.nodes.items(.group), 0..) |k, net, g, node| {
            if (k != .terminal or g != node) continue;
            const at = round(s.xy[node]);
            if (roleClass(s, net)) |c| {
                try b.added(c, net, at);
            } else {
                try b.labels.append(b.a(), .{ .net = net, .at = at, .side = leafSide(s, @intCast(node)) });
            }
        }
        try b.islands();
    }

    /// A netlist device: every card pin, placed on its class terminal.
    fn device(b: *Builder, d: u32, origin: Pt, o: Orient) !void {
        const s = b.s;
        const class = s.lib.at(s.devices.items(.class)[d]);
        try b.names.append(b.a(), try b.a().dupeZ(u8, s.device_name[d]));
        try b.classes.append(b.a(), s.devices.items(.class)[d]);
        try b.values.append(b.a(), try b.valueText(d));
        try b.pos.append(b.a(), origin);
        try b.orients.append(b.a(), o);
        const members = b.nl.graph.members(EdgeId.from(d));
        for (members, 0..) |net, i| {
            try b.pin_net.append(b.a(), net.index());
            try b.pin_xy.append(b.a(), if (i < class.terminals.len) origin.add(o.apply(class.terminals[i].at)) else origin);
        }
        try b.pin0.append(b.a(), @intCast(b.pin_net.items.len));
    }

    /// A rail or port symbol the layout added, on `net`, its pin at `at`.
    fn added(b: *Builder, c: ClassId, net: u32, at: Pt) !void {
        const t = b.s.lib.at(c).terminals[0].at;
        try b.names.append(b.a(), "");
        try b.classes.append(b.a(), c);
        try b.values.append(b.a(), "");
        try b.pos.append(b.a(), at.sub(t));
        try b.orients.append(b.a(), .r0);
        try b.pin_net.append(b.a(), net);
        try b.pin_xy.append(b.a(), at);
        try b.pin0.append(b.a(), @intCast(b.pin_net.items.len));
    }

    /// The exported pin index of netlist device `d`'s pin `idx`, if it was
    /// exported.
    fn devicePin(b: *const Builder, d: u32, idx: u8) ?u32 {
        var k: u32 = 0;
        for (0..d) |e| k += @intFromBool(b.s.devices.items(.kept)[e] and b.s.deviceNode(@intCast(e)) != null);
        if (!b.s.devices.items(.kept)[d]) return null;
        const pin = b.pin0.items[k] + idx;
        return if (pin < b.pin0.items[k + 1]) pin else null;
    }

    /// Label nodes and annotations: a net's name at a point.
    fn names_(b: *Builder) !void {
        const s = b.s;
        for (s.nodes.items(.kind), s.nodes.items(.ref), 0..) |k, net, node| {
            if (k != .label) continue;
            try b.labels.append(b.a(), .{ .net = net, .at = round(s.xy[node]), .side = leafSide(s, @intCast(node)) });
        }
        for (s.annotations.items) |e| {
            for (s.routes.items) |r| {
                if (r.kind != .edge or r.id != e) continue;
                // Midway along the longest segment, beside the wire.
                var best: usize = 0;
                var best_len: f32 = -1;
                for (0..r.len - 1) |k| {
                    const len = @abs(r.pts[k][0] - r.pts[k + 1][0]) + @abs(r.pts[k][1] - r.pts[k + 1][1]);
                    if (len > best_len) {
                        best_len = len;
                        best = k;
                    }
                }
                const u = r.pts[best];
                const w = r.pts[best + 1];
                const horizontal = @abs(u[1] - w[1]) < 1e-3;
                try b.labels.append(b.a(), .{
                    .net = s.edges.items[e].net,
                    .at = round(.{ (u[0] + w[0]) / 2, (u[1] + w[1]) / 2 }),
                    .side = if (horizontal) .up else .left,
                });
                break;
            }
        }
    }

    /// R3: each driver stands apart, left of the circuit: its terminal symbol
    /// on top, the source, a ground symbol below, in netlist order.
    fn islands(b: *Builder) !void {
        const s = b.s;
        const unit = s.lib.unit;
        var drivers: std.ArrayList(u32) = .empty;
        for (s.devices.items(.driver), 0..) |dr, d| if (dr) try drivers.append(b.a(), @intCast(d));
        if (drivers.items.len == 0) return;

        var lo: Pt = .{ .x = 0, .y = 0 };
        var have = false;
        for (b.pos.items, 0..) |p, d| {
            const r = b.s.lib.at(b.classes.items[d]).bbox();
            const x = p.x - @as(i32, @intCast(@max(@abs(r.min.x), @abs(r.max.x))));
            if (!have or x < lo.x) lo.x = x;
            if (!have or p.y < lo.y) lo.y = p.y;
            have = true;
        }
        for (b.polys) |list| for (list.items) |pl| for (pl) |p| {
            lo = .{ .x = @min(lo.x, p.x), .y = @min(lo.y, p.y) };
        };
        // A name runs about a unit from its point.
        for (b.labels.items) |l| lo = .{ .x = @min(lo.x, l.at.x - unit), .y = @min(lo.y, l.at.y) };

        const n: i32 = @intCast(drivers.items.len);
        for (drivers.items, 0..) |d, k| {
            // Two units apart, the nearest one a unit and a half clear.
            const x = lo.x - unit - 2 * unit * (n - 1 - @as(i32, @intCast(k))) - @divTrunc(unit, 2);
            const top = lo.y;
            const members = b.nl.graph.members(EdgeId.from(d));
            // The pin on the terminal net goes up.
            const up_pin: usize = if (s.roles[members[0].index()] == .sink) 1 else 0;
            const class_id = s.devices.items(.class)[d];
            const class = s.lib.at(class_id);
            var o: Orient = .left;
            const want_up = if (up_pin < class.terminals.len) class.terminals[up_pin].at else Pt.zero;
            if (o.apply(want_up).y > 0) o = Orient.flipped(.left, false, true);
            const origin: Pt = .{ .x = x, .y = top + unit };
            try b.deviceAt(d, origin, o);
            // Wires from each end pin to its symbol.
            const first = b.pin0.items[b.pin0.items.len - 2];
            for (members, 0..) |net, i| {
                if (i >= class.terminals.len) continue;
                const p = b.pin_xy.items[first + i];
                const up = p.y < origin.y;
                const end: Pt = .{ .x = p.x, .y = if (up) top else top + 2 * unit };
                try b.poly(net.index(), &.{ toF(p), toF(end) });
                if (roleClass(s, net.index())) |c| {
                    try b.added(c, net.index(), end);
                } else {
                    try b.labels.append(b.a(), .{ .net = net.index(), .at = end, .side = if (up) .up else .down });
                }
            }
        }
    }

    fn deviceAt(b: *Builder, d: u32, origin: Pt, o: Orient) !void {
        return b.device(d, origin, o);
    }

    fn poly(b: *Builder, net: u32, pts: []const [2]f32) !void {
        if (net == sch.none or net >= b.polys.len) return;
        var out: std.ArrayList(Pt) = .empty;
        for (pts) |p| {
            const q = round(p);
            if (out.items.len > 0 and out.items[out.items.len - 1].eql(q)) continue;
            try out.append(b.a(), q);
        }
        if (out.items.len < 2) return;
        try b.polys[net].append(b.a(), out.items);
    }

    fn valueText(b: *Builder, d: u32) ![:0]const u8 {
        var w: std.Io.Writer.Allocating = .init(b.a());
        const toks = b.nl.params(EdgeId.from(d));
        for (toks, 0..) |t, i| {
            const glue = i == 0 or std.mem.eql(u8, t, "=") or std.mem.eql(u8, toks[i - 1], "=");
            if (!glue) w.writer.writeByte(' ') catch return error.OutOfMemory;
            w.writer.writeAll(t) catch return error.OutOfMemory;
        }
        return w.toOwnedSliceSentinel(0);
    }

    /// Splits every polyline that runs through a junction there.
    fn splitAtJunctions(b: *Builder) Allocator.Error!void {
        for (b.polys) |*list| {
            var k: usize = 0;
            while (k < list.items.len) {
                const pl = list.items[k];
                const cut = findCut(pl, b.junctions.items) orelse {
                    k += 1;
                    continue;
                };
                const i, const j = cut;
                const first = try b.a().alloc(Pt, i + 2);
                @memcpy(first[0 .. i + 1], pl[0 .. i + 1]);
                first[i + 1] = j;
                const second = try b.a().alloc(Pt, pl.len - i);
                second[0] = j;
                @memcpy(second[1..], pl[i + 1 ..]);
                // Both halves are looked at again: either may run through
                // another junction.
                list.items[k] = first;
                try list.append(b.a(), second);
            }
        }
    }

    fn finish(b: *Builder) Allocator.Error!Placed {
        try b.splitAtJunctions();
        const al = b.a();
        var net_seg: std.ArrayList(u32) = .empty;
        var seg_pt: std.ArrayList(u32) = .empty;
        var pts: std.ArrayList(Pt) = .empty;
        try seg_pt.append(al, 0);
        for (b.polys) |list| {
            try net_seg.append(al, @intCast(seg_pt.items.len - 1));
            for (list.items) |poly_| {
                try pts.appendSlice(al, poly_);
                try seg_pt.append(al, @intCast(pts.items.len));
            }
        }
        try net_seg.append(al, @intCast(seg_pt.items.len - 1));
        const nets = try al.alloc([:0]const u8, b.s.net_name.len);
        for (nets, b.s.net_name) |*d, n| d.* = try al.dupeZ(u8, n);
        return .{
            .arena = b.arena,
            .dev_name = b.names.items,
            .dev_class = b.classes.items,
            .dev_value = b.values.items,
            .dev_pos = b.pos.items,
            .dev_orient = b.orients.items,
            .dev_pin0 = b.pin0.items,
            .pin_net = b.pin_net.items,
            .pin_xy = b.pin_xy.items,
            .net_name = nets,
            .net_seg = net_seg.items,
            .seg_pt = seg_pt.items,
            .wire_pts = pts.items,
            .junctions = b.junctions.items,
            .labels = b.labels.items,
            .no_connects = b.no_connects.items,
        };
    }
};

/// The first segment of `poly` that runs through a junction, and the
/// junction.
fn findCut(poly: []const Pt, junctions: []const Pt) ?struct { usize, Pt } {
    for (poly[0 .. poly.len - 1], poly[1..], 0..) |u, v, i| {
        for (junctions) |j| if (strictlyInside(j, u, v)) return .{ i, j };
    }
    return null;
}

/// `p` on the axis-aligned segment u–v, not at either end.
fn strictlyInside(p: Pt, u: Pt, v: Pt) bool {
    if (u.x == v.x) return p.x == u.x and p.y > @min(u.y, v.y) and p.y < @max(u.y, v.y);
    if (u.y == v.y) return p.y == u.y and p.x > @min(u.x, v.x) and p.x < @max(u.x, v.x);
    return false;
}

fn round(p: [2]f32) Pt {
    return .{ .x = @intFromFloat(@round(p[0])), .y = @intFromFloat(@round(p[1])) };
}

fn toF(p: Pt) [2]f32 {
    return .{ @floatFromInt(p.x), @floatFromInt(p.y) };
}

/// The rail or port class a terminal net's symbol is drawn as, if the
/// library has one.
fn roleClass(s: *const Schematic, net: u32) ?ClassId {
    const role: library.Role = switch (s.roles[net]) {
        .supply => .power_rail,
        .sink => .ground_rail,
        .input => .input_port,
        .output => .output_port,
        .bias, .internal => return null,
    };
    return s.lib.findRole(role);
}

/// Which way a terminal's or label's name runs: away from its wire.
fn leafSide(s: *const Schematic, node: u32) Side {
    for (s.pins.items(.home), s.pins.items(.side), s.pins.items(.device)) |h, side, d| {
        if (h == node and d == sch.none) return side.opposite();
    }
    return .left;
}
