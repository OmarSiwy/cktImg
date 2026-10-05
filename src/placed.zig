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
    /// The polylines that are a label node's stub (`unshort`).
    stubs: std.ArrayList([*]const Pt) = .empty,
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
        const kinds = s.nodes.items(.kind);
        for (s.routes.items) |r| {
            const pl = try b.poly(r.net, r.pts[0..r.len]) orelse continue;
            if (r.kind != .edge) continue;
            const e = s.edges.items[r.id];
            if (kinds[e.a] == .label or kinds[e.b] == .label) try b.stubs.append(b.a(), pl.ptr);
        }
        for (s.pins.items(.device), s.pins.items(.index), 0..) |d, idx, p| {
            if (d == sch.none) continue;
            const at = round(lay.pinPoint(s, @intCast(p)));
            const pin = b.devicePin(d, idx) orelse continue;
            const end = b.pin_xy.items[pin];
            if (at.eql(end)) continue;
            // Along the pin's side first, then across onto the pin.
            const corner: Pt = if (s.pins.items(.side)[p].isHorizontal()) .{ .x = end.x, .y = at.y } else .{ .x = at.x, .y = end.y };
            _ = try b.poly(s.pins.items(.net)[p], &.{ toF(at), toF(corner), toF(end) });
        }
        for (s.dots.items) |p| try b.junctions.append(b.a(), round(p));
        for (s.no_connects.items) |p| {
            const d = s.pins.items(.device)[p];
            const pin = b.devicePin(d, s.pins.items(.index)[p]) orelse continue;
            try b.no_connects.append(b.a(), b.pin_xy.items[pin]);
        }
        try b.names_();

        // Terminal symbols: one rail or port per terminal the layout drew.
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
                _ = try b.poly(net.index(), &.{ toF(p), toF(end) });
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

    fn poly(b: *Builder, net: u32, pts: []const [2]f32) !?[]const Pt {
        if (net == sch.none or net >= b.polys.len) return null;
        var out: std.ArrayList(Pt) = .empty;
        for (pts) |p| {
            const q = round(p);
            if (out.items.len > 0 and out.items[out.items.len - 1].eql(q)) continue;
            try out.append(b.a(), q);
        }
        if (out.items.len < 2) return null;
        try b.polys[net].append(b.a(), out.items);
        return out.items;
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
        try b.unshort();
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

    /// A wire through or onto a point of another net — a pin, a wire's end
    /// or bend, a label — is a short to a netlister that joins by touch
    /// (xschem). The layout keeps wires that can give way off such points
    /// (L7, L9); what still touches one is a label's stub or a rail, which
    /// never give way. Such a wire is not drawn: a label's stub first (the
    /// name goes onto its pin), then any other. Its net's pieces are then
    /// joined by name (`rename`). Repeated, since a name written on a pin
    /// may sit on a third net's wire; each round removes a wire, so it ends.
    // ponytail: dropping the wire is the fallback; a detour router would
    // keep it.
    fn unshort(b: *Builder) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(b.arena.child_allocator);
        defer scratch.deinit();
        const al = scratch.allocator();
        const dirty = try al.alloc(bool, b.polys.len);
        var any = false;
        while (true) {
            var points: Points = .{};
            // Every pin, a MOS body past the symbol's terminals too: a
            // target whose symbol has one draws it at the device's origin.
            for (b.pin_xy.items, b.pin_net.items) |at, net| if (net != no_net) try points.add(al, at, net);
            for (b.labels.items) |l| try points.add(al, l.at, l.net);
            for (b.polys, 0..) |list, n| for (list.items) |pl| for (pl) |at| try points.add(al, at, @intCast(n));

            @memset(dirty, false);
            var found = false;
            for ([_]bool{ true, false }) |stubs_only| {
                for (b.polys, dirty, 0..) |*list, *d, n| {
                    var k: usize = 0;
                    while (k < list.items.len) {
                        const pl = list.items[k];
                        if (!points.touch(pl, @intCast(n)) or
                            (stubs_only and std.mem.indexOfScalar([*]const Pt, b.stubs.items, pl.ptr) == null))
                        {
                            k += 1;
                            continue;
                        }
                        _ = list.orderedRemove(k);
                        d.* = true;
                        found = true;
                    }
                }
                if (found) break;
            }
            if (!found) break;
            any = true;
            for (dirty, 0..) |d, n| if (d) try b.rename(al, @intCast(n));
        }
        if (!any) return;
        // A dot only where three arms of one net still meet.
        var dots: std.ArrayList(Pt) = .empty;
        const keep = b.a();
        for (b.junctions.items) |j| {
            for (b.polys, 0..) |list, n| {
                var arms: u32 = 0;
                for (list.items) |pl| arms += @as(u32, @intFromBool(pl[0].eql(j))) + @intFromBool(pl[pl.len - 1].eql(j));
                for (b.pin_xy.items, b.pin_net.items) |at, pn| arms += @intFromBool(pn == n and at.eql(j));
                if (arms >= 3) {
                    try dots.append(keep, j);
                    break;
                }
            }
        }
        b.junctions = dots;
    }

    /// Net `n` after some of its wires went, read as a netlister reads it:
    /// a piece left with no pin goes too, wires and names; when more than
    /// one piece is left, each without a name gets one on a pin. `al` holds
    /// what this works with.
    fn rename(b: *Builder, al: Allocator, n: u32) Allocator.Error!void {
        var index: std.AutoHashMapUnmanaged(Pt, u32) = .empty;
        var parent: std.ArrayList(u32) = .empty;
        const node = struct {
            fn f(a_: Allocator, idx: *std.AutoHashMapUnmanaged(Pt, u32), par: *std.ArrayList(u32), at: Pt) !u32 {
                const gop = try idx.getOrPut(a_, at);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(par.items.len);
                    try par.append(a_, gop.value_ptr.*);
                }
                return gop.value_ptr.*;
            }
        }.f;
        const find = struct {
            fn f(par: []u32, x0: u32) u32 {
                var x = x0;
                while (par[x] != x) x = par[x];
                return x;
            }
        }.f;
        const list = &b.polys[n];
        for (list.items) |pl| {
            const first = try node(al, &index, &parent, pl[0]);
            for (pl[1..]) |at| {
                const v = try node(al, &index, &parent, at);
                parent.items[find(parent.items, v)] = find(parent.items, first);
            }
        }
        // A name written on a wire joins it.
        for (b.labels.items) |l| if (l.net == n) {
            const v = try node(al, &index, &parent, l.at);
            for (list.items) |pl| for (pl[0 .. pl.len - 1], pl[1..]) |u, w| {
                if (!Rect.fromCorners(u, w).contains(l.at)) continue;
                parent.items[find(parent.items, v)] = find(parent.items, index.get(u).?);
            };
        };
        // Every drawn pin of the net is a point too (a loose one its own piece).
        const Pin = struct { pin: u32, side: Side, symbol: bool };
        var pins: std.ArrayList(Pin) = .empty;
        for (b.classes.items, b.orients.items, 0..) |c, o, d| {
            const class = b.s.lib.at(c);
            const lo = b.pin0.items[d];
            const hi = b.pin0.items[d + 1];
            for (lo..@min(hi, lo + class.terminals.len)) |pin| {
                if (b.pin_net.items[pin] != n or class.terminals[pin - lo].hidden) continue;
                // A rail's or port's pin is at its origin: no side.
                const side = class.side(pin - lo, o) orelse .right;
                _ = try node(al, &index, &parent, b.pin_xy.items[pin]);
                try pins.append(al, .{ .pin = @intCast(pin), .side = side, .symbol = hi - lo == 1 or class.terminals[pin - lo].ground_ref });
            }
        }
        // Per piece: a pin on it (of a symbol with more than one), and
        // whether it has a name (a label, or a rail or port symbol).
        const count = parent.items.len;
        const has_pin = try al.alloc(bool, count);
        @memset(has_pin, false);
        const named = try al.alloc(bool, count);
        @memset(named, false);
        const pin_of = try al.alloc(?Pin, count);
        @memset(pin_of, null);
        for (pins.items) |p| {
            const r = find(parent.items, index.get(b.pin_xy.items[p.pin]).?);
            has_pin[r] = true;
            if (p.symbol) named[r] = true else if (pin_of[r] == null) pin_of[r] = p;
        }
        for (b.labels.items) |l| if (l.net == n) {
            named[find(parent.items, index.get(l.at).?)] = true;
        };
        // A piece with no pin goes, wires and names.
        var k: usize = 0;
        while (k < list.items.len) {
            if (has_pin[find(parent.items, index.get(list.items[k][0]).?)]) k += 1 else _ = list.orderedRemove(k);
        }
        var kept: std.ArrayList(Label) = .empty;
        for (b.labels.items) |l| {
            if (l.net != n or has_pin[find(parent.items, index.get(l.at).?)]) try kept.append(b.a(), l);
        }
        var pieces: u32 = 0;
        for (has_pin, 0..) |h, r| pieces += @intFromBool(h and find(parent.items, @intCast(r)) == r);
        if (pieces > 1) for (pin_of, named, 0..) |p, nm, r| {
            const pin = p orelse continue;
            if (nm or find(parent.items, @intCast(r)) != r) continue;
            try kept.append(b.a(), .{ .net = n, .at = b.pin_xy.items[pin.pin], .side = pin.side });
        };
        b.labels = kept;
    }
};

/// Points with their nets, by row and by column.
const Points = struct {
    const Point = struct { at: Pt, net: u32 };
    const Index = std.AutoHashMapUnmanaged(i32, std.ArrayList(Point));
    rows: Index = .empty,
    cols: Index = .empty,

    fn add(p: *Points, a: Allocator, at: Pt, net: u32) !void {
        for ([_]*Index{ &p.rows, &p.cols }, [_]i32{ at.y, at.x }) |m, key| {
            const gop = try m.getOrPut(a, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, .{ .at = at, .net = net });
        }
    }

    /// Does polyline `pl` of net `n` run through or onto a point of another net?
    fn touch(p: *const Points, pl: []const Pt, n: u32) bool {
        for (pl[0 .. pl.len - 1], pl[1..]) |u, v| {
            const horizontal = u.y == v.y;
            const on = (if (horizontal) p.rows.get(u.y) else p.cols.get(u.x)) orelse continue;
            const lo = if (horizontal) @min(u.x, v.x) else @min(u.y, v.y);
            const hi = if (horizontal) @max(u.x, v.x) else @max(u.y, v.y);
            for (on.items) |q| {
                const along = if (horizontal) q.at.x else q.at.y;
                if (q.net != n and along >= lo and along <= hi) return true;
            }
        }
        return false;
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
