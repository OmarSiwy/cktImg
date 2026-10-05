//! One test per case in ALGORITHM.md, named by its id, plus the textbook
//! suite. `zig build test`.

const std = @import("std");
const testing = std.testing;
const np = @import("NetlistParser");
const netlist = np.netlist;
const sch = np.schematic;
const lay = np.layout_engine;
const config = np.config;
const textbook = @import("textbook.zig");
const support = @import("support.zig");

const Side = sch.Side;
const none = sch.none;

// ===========================================================================
// Helpers
// ===========================================================================

const Built = struct {
    lib: *np.Library,
    nl: netlist.Netlist,
    roles: []sch.Role,
    s: sch.Schematic,

    /// Stages 1–4 only.
    fn init(src: []const u8) !Built {
        const gpa = testing.allocator;
        const lib = try support.library(gpa);
        errdefer support.freeLibrary(gpa, lib);
        var nl = try netlist.parse(gpa, &.{src}, null);
        errdefer nl.deinit(gpa);
        const roles = try sch.guessRoles(gpa, &nl);
        errdefer gpa.free(roles);
        const s = try sch.build(gpa, &nl, roles, lib);
        return .{ .lib = lib, .nl = nl, .roles = roles, .s = s };
    }
    /// All five stages.
    fn laidOut(src: []const u8) !Built {
        return laidOutWith(src, &.default);
    }
    fn laidOutWith(src: []const u8, cfg: *const config.Config) !Built {
        var b = try init(src);
        errdefer b.deinit();
        try lay.layout(testing.allocator, &b.s, cfg);
        return b;
    }
    fn deinit(b: *Built) void {
        b.s.deinit();
        testing.allocator.free(b.roles);
        b.nl.deinit(testing.allocator);
        support.freeLibrary(testing.allocator, b.lib);
    }

    fn dev(b: *const Built, name: []const u8) u32 {
        return b.nl.device(name).?.index();
    }
    fn net(b: *const Built, name: []const u8) u32 {
        return b.nl.net(name).?.index();
    }
    fn info(b: *const Built, name: []const u8) sch.DeviceInfo {
        return b.s.devices.get(b.dev(name));
    }
    /// The node a device's symbol sits on.
    fn node(b: *const Built, name: []const u8) u32 {
        return b.s.deviceNode(b.dev(name)).?;
    }
    fn pin(b: *const Built, name: []const u8, index: u8) u32 {
        return b.s.pinOf(b.dev(name), index).?;
    }
    fn side(b: *const Built, name: []const u8, index: u8) Side {
        return b.s.pins.items(.side)[b.pin(name, index)];
    }
    fn home(b: *const Built, p: u32) u32 {
        return b.s.pins.items(.home)[p];
    }
    /// The pin of a net's terminal leaf.
    fn leafPin(b: *const Built, net_name: []const u8) u32 {
        const n = b.net(net_name);
        const kinds = b.s.nodes.items(.kind);
        for (b.s.pins.items(.net), b.s.pins.items(.device), b.s.pins.items(.home), 0..) |pn, d, h, p| {
            if (pn == n and d == none and kinds[h] == .terminal) return @intCast(p);
        }
        unreachable;
    }
    fn straight(b: *const Built, p: u32, q: u32) ?u32 {
        for (b.s.edges.items, 0..) |e, id| {
            if (e.kind != .straight) continue;
            if ((e.pa == p and e.pb == q) or (e.pa == q and e.pb == p)) return @intCast(id);
        }
        return null;
    }
    fn edgesAt(b: *const Built, p: u32) u32 {
        var n: u32 = 0;
        for (b.s.edges.items) |e| n += @intFromBool(e.kind == .straight and (e.pa == p or e.pb == p));
        return n;
    }
    /// The end of straight edge `e` that carries pin `p`.
    fn endAt(b: *const Built, e: u32, p: u32) u32 {
        const edge = b.s.edges.items[e];
        return if (edge.pa == p) edge.a else edge.b;
    }
    fn joinOn(b: *const Built, kind: sch.JoinKind, net_name: []const u8) ?sch.Join {
        const n = b.net(net_name);
        for (b.s.joins.items) |j| if (j.active and j.kind == kind and j.net == n) return j;
        return null;
    }
    fn labelsOf(b: *const Built, net_name: []const u8) u32 {
        const n = b.net(net_name);
        var count: u32 = 0;
        for (b.s.nodes.items(.kind), b.s.nodes.items(.ref)) |k, r| count += @intFromBool(k == .label and r == n);
        return count;
    }
    fn pos(b: *const Built, n: u32) [2]i32 {
        return b.s.pos[n];
    }
    /// The middle copy of a net's junction.
    fn junction(b: *const Built, net_name: []const u8) ?u32 {
        const n = b.net(net_name);
        for (b.s.nodes.items(.kind), b.s.nodes.items(.ref), b.s.nodes.items(.group), 0..) |k, r, g, i| {
            if (k == .junction and r == n and g == i) return @intCast(i);
        }
        return null;
    }
    /// Straight edges joining two devices, on any net.
    fn straightsBetween(b: *const Built, d1: []const u8, d2: []const u8) u32 {
        const devs = b.s.pins.items(.device);
        const x = b.dev(d1);
        const y = b.dev(d2);
        var count: u32 = 0;
        for (b.s.edges.items) |e| {
            if (e.kind != .straight) continue;
            count += @intFromBool((devs[e.pa] == x and devs[e.pb] == y) or (devs[e.pa] == y and devs[e.pb] == x));
        }
        return count;
    }
};

fn circuit(name: []const u8) []const u8 {
    for (textbook.all ++ textbook.beyond) |c| if (std.mem.eql(u8, c.name, name)) return c.spice;
    unreachable;
}

/// No two nodes on one cell.
fn expectDistinctCells(s: *const sch.Schematic) !void {
    for (s.pos, 0..) |p, i| for (s.pos[i + 1 ..]) |q| {
        try testing.expect(p[0] != q[0] or p[1] != q[1]);
    };
}

/// Every net is drawn in one wired piece, or — if labelled — every piece
/// carries its name (a label node, the terminal leaf or an annotation).
fn expectNetsRealised(s: *const sch.Schematic) !void {
    const gpa = testing.allocator;
    const parent = try gpa.alloc(u32, s.pins.len);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const find = struct {
        fn f(par: []u32, start: u32) u32 {
            var i = start;
            while (par[i] != i) i = par[i];
            return i;
        }
    }.f;
    const unite = struct {
        fn f(par: []u32, a: u32, c: u32) void {
            par[find(par, a)] = find(par, c);
        }
    }.f;
    for (s.edges.items) |e| if (e.kind == .straight) unite(parent, e.pa, e.pb);
    for (0..s.pins.len) |p| for (p + 1..s.pins.len) |q| {
        const jp = s.junctionOf(@intCast(p));
        if (jp != none and jp == s.junctionOf(@intCast(q))) unite(parent, @intCast(p), @intCast(q));
    };
    for (s.joins.items) |j| {
        if (!j.active) continue;
        // A tap or cross joins only through a wire that is still drawn.
        switch (j.kind) {
            .tap => if (s.edges.items[j.q].kind == .straight) unite(parent, j.p, s.edges.items[j.q].pa),
            .corner, .bend => unite(parent, j.p, j.q),
            .cross => if (s.edges.items[j.p].kind == .straight and s.edges.items[j.q].kind == .straight)
                unite(parent, s.edges.items[j.p].pa, s.edges.items[j.q].pa),
        }
    }
    const nets = s.pins.items(.net);
    const devices = s.pins.items(.device);
    const kinds = s.nodes.items(.kind);
    const homes = s.pins.items(.home);
    for (0..s.net_name.len) |n| {
        var roots: [64]u32 = undefined;
        var named: [64]bool = undefined;
        var k: usize = 0;
        for (nets, 0..) |pn, p| {
            if (pn != n) continue;
            const r = find(parent, @intCast(p));
            const idx = std.mem.indexOfScalar(u32, roots[0..k], r) orelse blk: {
                roots[k] = r;
                named[k] = false;
                k += 1;
                break :blk k - 1;
            };
            if (devices[p] == none and kinds[homes[p]] != .junction) named[idx] = true; // terminal or label pin
        }
        if (!s.labeled[n]) {
            try testing.expect(k <= 1);
            continue;
        }
        for (s.annotations.items) |e| {
            if (s.edges.items[e].net != n) continue;
            const r = find(parent, s.edges.items[e].pa);
            if (std.mem.indexOfScalar(u32, roots[0..k], r)) |idx| named[idx] = true;
        }
        for (named[0..k]) |x| try testing.expect(x);
    }
}

// ===========================================================================
// Stage 1 — Roles
// ===========================================================================

test "R1 roles by net name" {
    var b = try Built.init(
        \\roles by name
        \\R1 vdd vin 1k
        \\R2 vin out1 1k
        \\R3 out1 vb1 1k
        \\R4 vb1 x 1k
        \\R5 x gnd 1k
    );
    defer b.deinit();
    try testing.expectEqual(sch.Role.supply, b.roles[b.net("vdd")]);
    try testing.expectEqual(sch.Role.input, b.roles[b.net("vin")]);
    try testing.expectEqual(sch.Role.output, b.roles[b.net("out1")]);
    try testing.expectEqual(sch.Role.bias, b.roles[b.net("vb1")]);
    try testing.expectEqual(sch.Role.internal, b.roles[b.net("x")]);
    try testing.expectEqual(sch.Role.sink, b.roles[b.net("gnd")]);
}

test "R2 a net driven from ground: signal source -> input, otherwise bias" {
    var b = try Built.init(
        \\source-driven roles
        \\Vs a 0 ac 1
        \\Vb b 0 dc 0.5
        \\R1 a b 1k
    );
    defer b.deinit();
    try testing.expectEqual(sch.Role.input, b.roles[b.net("a")]);
    try testing.expectEqual(sch.Role.bias, b.roles[b.net("b")]);
}

test "R3 drivers of terminal nets are not drawn" {
    var b = try Built.init(
        \\drivers
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\Vx p q 1
        \\R1 vdd p 1k
        \\R2 q in 1k
        \\I1 vdd q 1m
    );
    defer b.deinit();
    try testing.expect(!b.info("vdd").kept);
    try testing.expect(!b.info("vin").kept);
    try testing.expect(b.info("vx").kept);
    try testing.expect(b.info("i1").kept);
}

// ===========================================================================
// Stage 2 — Orientation
// ===========================================================================

test "O0 hidden pins: MOS bulk and the op-amp reference on the sink" {
    var cs = try Built.init(circuit("cs_resistive"));
    defer cs.deinit();
    try testing.expect(cs.s.pinOf(cs.dev("m1"), 3) == null);
    var amp = try Built.init(circuit("noninverting_amp"));
    defer amp.deinit();
    try testing.expect(amp.s.pinOf(amp.dev("e1"), 1) == null);
    try testing.expect(amp.s.pinOf(amp.dev("e1"), 0) != null);
}

test "O1 power path only -> vertical" {
    var b = try Built.init(
        \\power only
        \\V1 vdd 0 1
        \\R1 vdd 0 1k
    );
    defer b.deinit();
    const i = b.info("r1");
    try testing.expect(i.on_power_path and !i.on_signal_path);
    try testing.expectEqual(sch.Orientation.vertical, i.orientation);
}

test "O2 signal path only -> horizontal" {
    var b = try Built.init(circuit("rc_lowpass"));
    defer b.deinit();
    const i = b.info("r1");
    try testing.expect(i.on_signal_path and !i.on_power_path);
    try testing.expectEqual(sch.Orientation.horizontal, i.orientation);
}

test "O3 both paths, side pin -> vertical" {
    var b = try Built.init(circuit("cs_resistive"));
    defer b.deinit();
    const i = b.info("m1");
    try testing.expect(i.on_signal_path and i.on_power_path);
    try testing.expectEqual(sch.Orientation.vertical, i.orientation);
}

test "O4 both paths, no side pin -> horizontal" {
    var b = try Built.init(
        \\feedback resistor on both paths
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\M1 x in 0 0 nch
        \\R1 vdd x 1k
        \\Rf x out 1k
        \\Rl out 0 1k
    );
    defer b.deinit();
    const i = b.info("rf");
    try testing.expect(i.on_signal_path and i.on_power_path);
    try testing.expectEqual(sch.Orientation.horizontal, i.orientation);
}

test "O5 on neither path -> vertical" {
    var b = try Built.init(circuit("rc_lowpass"));
    defer b.deinit();
    const i = b.info("c1");
    try testing.expect(!i.on_signal_path and !i.on_power_path);
    try testing.expectEqual(sch.Orientation.vertical, i.orientation);
}

test "O6 flip Y: the pin nearer the supply faces up" {
    var b = try Built.init(circuit("cs_active_load"));
    defer b.deinit();
    try testing.expect(b.info("m2").flip_y);
    try testing.expectEqual(Side.up, b.side("m2", 2)); // PMOS source
    try testing.expectEqual(Side.down, b.side("m2", 0));
}

test "O7 flip X: the pin nearer the input faces left" {
    var b = try Built.init(
        \\resistor written backwards
        \\Vin in 0 ac 1
        \\R1 out in 1k
        \\C1 out 0 1n
    );
    defer b.deinit();
    try testing.expect(b.info("r1").flip_x);
    try testing.expectEqual(Side.left, b.side("r1", 1));
    try testing.expectEqual(Side.right, b.side("r1", 0));
}

test "O8 mirror pair: two side pins of two vertical devices face each other" {
    var b = try Built.init(circuit("current_mirror"));
    defer b.deinit();
    try testing.expectEqual(Side.right, b.side("m1", 1));
    try testing.expectEqual(Side.left, b.side("m2", 1));
}

test "O8 not for stacked devices: an inverter's two gates keep facing left" {
    var b = try Built.init(circuit("ring_oscillator"));
    defer b.deinit();
    try testing.expectEqual(Side.left, b.side("mp2", 1));
    try testing.expectEqual(Side.left, b.side("mn2", 1));
}

test "O9 differential pair: inputs face outwards, leaves follow" {
    var b = try Built.init(circuit("diff_pair_resistive"));
    defer b.deinit();
    try testing.expectEqual(Side.left, b.side("m1", 1));
    try testing.expectEqual(Side.right, b.side("m2", 1));
    try testing.expectEqual(Side.left, b.s.pins.items(.side)[b.leafPin("inn")]); // leaf on the right
    try testing.expectEqual(Side.right, b.s.pins.items(.side)[b.leafPin("outn")]); // leaf on the left
    try testing.expectEqual(Side.left, b.s.pins.items(.side)[b.leafPin("outp")]);
}

// ===========================================================================
// Stage 3 — Wiring
// ===========================================================================

test "W1 pair: one pin facing down meets one facing up" {
    var b = try Built.init(circuit("cs_resistive"));
    defer b.deinit();
    const e = b.straight(b.pin("rd", 1), b.pin("m1", 0)).?;
    try testing.expectEqual(Side.down, b.s.edges.items[e].side);
    try testing.expect(b.straight(b.leafPin("in"), b.pin("m1", 1)) != null);
}

test "W2 fan: one pin against k facing pins, no perpendicular wire" {
    var b = try Built.init(circuit("diff_pair_resistive"));
    defer b.deinit();
    // The tail current source under both sources, the supply over both loads.
    try testing.expectEqual(2, b.edgesAt(b.pin("iss", 0)));
    try testing.expectEqual(2, b.edgesAt(b.leafPin("vdd")));
    try testing.expect(b.joinOn(.tap, "tail") == null);
}

test "W2 several against several: matched one-to-one, never a device to itself" {
    var b = try Built.laidOut(circuit("sallen_key"));
    defer b.deinit();
    // out: c1 and the op-amp output face right; the op-amp's - input and the
    // output leaf face left. c1 takes the transistor-like partner (e1-),
    // the op-amp output the leaf; e1's own two pins get a bend.
    try testing.expect(b.straight(b.pin("e1", 0), b.leafPin("out")) != null);
    try testing.expect(b.straight(b.pin("e1", 0), b.pin("e1", 3)) == null);
    try testing.expect(b.joinOn(.bend, "out") != null);
    for (b.s.edges.items) |e| {
        if (e.kind != .straight) continue;
        const d = b.s.pins.items(.device);
        try testing.expect(d[e.pa] == none or d[e.pa] != d[e.pb]);
    }
    try testing.expectEqual(0, b.s.stats.crossings);
}

test "W3 unpaired pins of a group tap a perpendicular wire of the net" {
    var b = try Built.init(circuit("two_stage_opamp"));
    defer b.deinit();
    // m6 pairs with m7 (a transistor first); cl taps the cc->out line.
    try testing.expect(b.straight(b.pin("m6", 0), b.pin("m7", 0)) != null);
    try testing.expect(b.straight(b.pin("m6", 0), b.pin("cl", 0)) == null);
    const j = b.joinOn(.tap, "out").?;
    try testing.expectEqual(b.pin("cl", 0), j.p);
    try testing.expectEqual(b.straight(b.pin("cc", 1), b.leafPin("out")).?, j.q);
}

test "W4 a lone pin taps a perpendicular wire" {
    var b = try Built.init(circuit("cs_resistive"));
    defer b.deinit();
    const j = b.joinOn(.tap, "out").?;
    try testing.expectEqual(b.leafPin("out"), j.p);
    try testing.expectEqual(b.straight(b.pin("rd", 1), b.pin("m1", 0)).?, j.q);
}

test "W5 corner: two lone pins facing perpendicular ways" {
    var b = try Built.init(circuit("common_gate"));
    defer b.deinit();
    const j = b.joinOn(.corner, "in").?;
    const pins = [_]u32{ j.p, j.q };
    try testing.expect(std.mem.indexOfScalar(u32, &pins, b.leafPin("in")) != null);
    try testing.expect(std.mem.indexOfScalar(u32, &pins, b.pin("m1", 2)) != null);
}

test "W6 cross: a vertical and a horizontal wire of one net" {
    var b = try Built.init(circuit("two_stage_opamp"));
    defer b.deinit();
    const j = b.joinOn(.cross, "out").?;
    try testing.expectEqual(b.straight(b.pin("m6", 0), b.pin("m7", 0)).?, j.p);
    try testing.expectEqual(b.straight(b.pin("cc", 1), b.leafPin("out")).?, j.q);
}

test "W7 bend: two pins of one device in different pieces" {
    var ota = try Built.init(circuit("ota_5t"));
    defer ota.deinit();
    const j = ota.joinOn(.bend, "x").?;
    try testing.expectEqual(ota.dev("m3"), ota.s.pins.items(.device)[j.p]);
    try testing.expectEqual(ota.dev("m3"), ota.s.pins.items(.device)[j.q]);

    var bg = try Built.init(circuit("bandgap"));
    defer bg.deinit();
    var bends: u32 = 0;
    for (bg.s.joins.items) |jj| bends += @intFromBool(jj.kind == .bend and jj.net == bg.net("0"));
    try testing.expectEqual(3, bends); // each diode-connected BJT
}

test "W8 bias nets are drawn with one label per pin" {
    var b = try Built.init(circuit("two_stage_opamp"));
    defer b.deinit();
    try testing.expect(b.s.labeled[b.net("vb")]);
    try testing.expectEqual(2, b.labelsOf("vb"));
    try testing.expect(b.s.terminalNode(b.net("vb")) == null);
}

test "W9 pieces no join can connect -> labels" {
    var b = try Built.init(
        \\three gates on one net
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\R1 vdd d1 1k
        \\R2 vdd d2 1k
        \\R3 vdd d3 1k
        \\M1 d1 g 0 0 nch
        \\M2 d2 g 0 0 nch
        \\M3 d3 g 0 0 nch
    );
    defer b.deinit();
    try testing.expect(b.s.labeled[b.net("g")]);
    try testing.expectEqual(3, b.labelsOf("g"));
}

test "W10 a dangling pin gets no wire" {
    var b = try Built.init(
        \\dangling
        \\V1 vdd 0 1
        \\R1 vdd 0 1k
        \\C1 vdd nc 1p
    );
    defer b.deinit();
    const n = b.net("nc");
    for (b.s.edges.items) |e| try testing.expect(e.net != n);
    for (b.s.joins.items) |j| try testing.expect(j.net != n);
    try testing.expect(!b.s.labeled[n]);
    // ...and its end gets a no-connect mark.
    var laid = try Built.laidOut(
        \\dangling
        \\V1 vdd 0 1
        \\R1 vdd 0 1k
        \\C1 vdd nc 1p
    );
    defer laid.deinit();
    try testing.expectEqualSlices(u32, &.{laid.pin("c1", 1)}, laid.s.no_connects.items);
}

// ===========================================================================
// Stage 4 — Supernodes
// ===========================================================================

test "S1 several pins on one side: copies chained across that side" {
    var b = try Built.init(circuit("noninverting_amp"));
    defer b.deinit();
    const root = b.node("e1");
    try testing.expectEqual(3, b.s.groupSize(root));
    // ctrl+ and ctrl- on the end copies, the output on the middle one.
    const plus = b.home(b.pin("e1", 2));
    const minus = b.home(b.pin("e1", 3));
    try testing.expect(plus != root and minus != root and plus != minus);
    try testing.expectEqual(root, b.home(b.pin("e1", 0)));
}

test "S2 a fan pin: its node becomes copies, one edge per copy" {
    var b = try Built.laidOut(circuit("diff_pair_resistive"));
    defer b.deinit();
    const root = b.node("iss");
    try testing.expectEqual(3, b.s.groupSize(root));
    const p = b.pin("iss", 0);
    try testing.expectEqual(root, b.home(p)); // the symbol stays on the middle copy
    var xs: [2]i32 = undefined;
    var k: usize = 0;
    for (b.s.edges.items, 0..) |e, id| {
        if (e.kind != .straight or (e.pa != p and e.pb != p)) continue;
        const end = b.endAt(@intCast(id), p);
        try testing.expect(end != root);
        xs[k] = b.pos(end)[0];
        k += 1;
    }
    try testing.expect(@min(xs[0], xs[1]) < b.pos(root)[0] and b.pos(root)[0] < @max(xs[0], xs[1]));
}

test "S3 odd width: an even fan gets one more copy, the middle one bare" {
    var b = try Built.init(circuit("diff_pair_resistive"));
    defer b.deinit();
    const leaf = b.s.terminalNode(b.net("vdd")).?;
    try testing.expectEqual(3, b.s.groupSize(leaf));
    const p = b.leafPin("vdd");
    for (b.s.edges.items, 0..) |e, id| {
        if (e.kind == .straight and (e.pa == p or e.pb == p)) try testing.expect(b.endAt(@intCast(id), p) != leaf);
    }
}

test "S4 other pins: along the chain at its ends, across it centred" {
    var b = try Built.laidOut(circuit("ota_5t"));
    defer b.deinit();
    const root = b.node("m5");
    try testing.expectEqual(3, b.s.groupSize(root));
    const gate = b.home(b.pin("m5", 1));
    try testing.expect(gate != root);
    try testing.expect(b.pos(gate)[0] < b.pos(root)[0]);
    try testing.expectEqual(root, b.home(b.pin("m5", 2)));
}

// ===========================================================================
// Stage 5 — Layout
// ===========================================================================

test "L1 straight edges share a column (vertical) or a row (horizontal)" {
    var b = try Built.laidOut(circuit("cs_resistive"));
    defer b.deinit();
    try testing.expectEqual(b.pos(b.node("rd"))[0], b.pos(b.node("m1"))[0]);
    try testing.expect(b.pos(b.node("rd"))[1] < b.pos(b.node("m1"))[1]);
    const in_leaf = b.s.terminalNode(b.net("in")).?;
    try testing.expectEqual(b.pos(b.node("m1"))[1], b.pos(in_leaf)[1]);
    try testing.expect(b.pos(in_leaf)[0] < b.pos(b.node("m1"))[0]);
}

test "L2 an edge whose row or column would put two nodes on one cell is bent" {
    // The only case in 40 000 random netlists of up to eight devices since
    // W1 keeps two devices to one straight wire.
    var b = try Built.laidOut(
        \\collision
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\M0 out out a vdd pch
        \\M1 out b c vdd pch
        \\C2 c 0 1p
        \\M3 c out in vdd pch
    );
    defer b.deinit();
    try testing.expectEqual(1, b.s.stats.bent);
    try testing.expectEqual(0, b.s.stats.conflicts);
    try expectDistinctCells(&b.s);
}

test "L3 joins are drawable: a tap lands between its wire's ends" {
    var cs = try Built.laidOut(circuit("cs_resistive"));
    defer cs.deinit();
    const out = cs.pos(cs.s.terminalNode(cs.net("out")).?);
    try testing.expect(out[0] > cs.pos(cs.node("m1"))[0]);
    try testing.expect(cs.pos(cs.node("rd"))[1] < out[1] and out[1] < cs.pos(cs.node("m1"))[1]);

    var cg = try Built.laidOut(circuit("common_gate"));
    defer cg.deinit();
    const in = cg.pos(cg.s.terminalNode(cg.net("in")).?);
    const m1 = cg.pos(cg.node("m1"));
    try testing.expect(in[0] < m1[0] and in[1] > m1[1]); // corner: left of and below the source
}

test "L4 a join on a cycle of order constraints turns its net into labels" {
    var b = try Built.laidOut(
        \\drain-gate resistor
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\Rin in n 1k
        \\R1 vdd n 1k
        \\M1 n out 0 0 nch
        \\Rx n out 1k
    );
    defer b.deinit();
    // Net n wants Rin | M1 | Rx left to right (cross); net out wants Rx left of M1.
    try testing.expect(b.s.labeled[b.net("n")]);
    try testing.expect(b.joinOn(.cross, "n") == null);
    try testing.expectEqual(0, b.s.stats.crossings);
    try expectNetsRealised(&b.s);
}

test "L5 a cycle of straight edges alone: one constraint dropped, edge bent" {
    // Two shorted devices (dummies): each one's down pin meets the other's
    // up pin on the same net, so each sits above the other.
    var b = try Built.laidOut(
        \\dummies
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\C0 a a 1p
        \\C1 a a 1p
    );
    defer b.deinit();
    try testing.expectEqual(1, b.s.stats.conflicts);
    try testing.expectEqual(1, b.s.stats.bent);
    try expectDistinctCells(&b.s);
}

test "L6 separation: nodes, wires through nodes, and names never share a cell" {
    var b = try Built.laidOut(
        \\two unrelated resistors
        \\R1 a b 1k
        \\R2 c d 1k
    );
    defer b.deinit();
    try expectDistinctCells(&b.s);

    // The mirrored input's wire would run through the second stage: the
    // second stage moves right instead.
    var two = try Built.laidOut(circuit("two_stage_opamp"));
    defer two.deinit();
    try testing.expectEqual(0, two.s.stats.overlaps);
    const inp = two.pos(two.s.terminalNode(two.net("inp")).?);
    try testing.expect(inp[0] < two.pos(two.node("m6"))[0]);

    // A name of three or more characters keeps the next cell free by
    // pushing a node there a column further out: both stacks stay level.
    var tel = try Built.laidOut(circuit("telescopic_cascode"));
    defer tel.deinit();
    try testing.expectEqual(tel.pos(tel.node("m7"))[1], tel.pos(tel.node("m8"))[1]);
    try testing.expectEqual(tel.pos(tel.node("m1"))[1], tel.pos(tel.node("m2"))[1]);
    try expectDistinctCells(&tel.s);
}

test "S5 a rail's copies are re-dealt before a join gives way (L4)" {
    var b = try Built.laidOut(circuit("bandgap"));
    defer b.deinit();
    // The vdd chain, dealt by key, puts m1 left of m2, so the x and y taps
    // cycle with it; S5 re-deals it and the op-amp lands between the first
    // two branches with both taps wired. Only g still cycles (its corners
    // want the op-amp left of every gate) and gives way.
    try testing.expect(b.s.labeled[b.net("g")]);
    try testing.expect(!b.s.labeled[b.net("x")]);
    try testing.expect(!b.s.labeled[b.net("y")]);
    try testing.expect(!b.s.labeled[b.net("vref")]);
    try testing.expect(b.s.stats.redealt);
    const e1 = b.pos(b.node("e1"))[0];
    try testing.expect(b.pos(b.node("m2"))[0] < e1 and e1 < b.pos(b.node("m1"))[0]);
    try testing.expectEqual(4, b.labelsOf("g")); // three gates and the op-amp output
    try testing.expectEqual(0, b.s.stats.crossings);
    try expectNetsRealised(&b.s);
}

test "L7 a net gives way as a whole, but keeps its terminal attached" {
    var b = try Built.laidOut(circuit("telescopic_cascode"));
    defer b.deinit();
    // The gate taps of m7/m8 onto the outn node give way; the output leaf's
    // own tap stays, so the terminal is not left floating.
    try testing.expect(b.s.labeled[b.net("outn")]);
    const j = b.joinOn(.tap, "outn").?;
    try testing.expectEqual(b.leafPin("outn"), j.p);
    try testing.expectEqual(2, b.labelsOf("outn"));
    try testing.expectEqual(0, b.s.stats.crossings);
    try expectNetsRealised(&b.s);
}

test "L7 a straight edge gives way only when no join is to blame" {
    // Smallest case the fuzzer found: two NMOS and a capacitor all between
    // nets a and b, so some straight wire must cross.
    var b = try Built.laidOut(
        \\shared source and drain
        \\.model nch nmos level=1
        \\.model pch pmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\M0 b a a 0 nch
        \\C1 b a 1p
        \\M2 b a b 0 nch
    );
    defer b.deinit();
    var dropped: u32 = 0;
    for (b.s.edges.items) |e| dropped += @intFromBool(e.kind == .dropped);
    try testing.expect(dropped > 0);
    try testing.expectEqual(0, b.s.stats.crossings);
    try testing.expectEqual(0, b.s.stats.overlaps);
    try expectNetsRealised(&b.s);
}

test "L8 leaves and labels sit beside what they are wired to" {
    var b = try Built.laidOut(circuit("cs_active_load"));
    defer b.deinit();
    const m2 = b.pos(b.node("m2"));
    for (b.s.nodes.items(.kind), b.s.nodes.items(.ref), 0..) |k, r, n| {
        if (k != .label or r != b.net("vb")) continue;
        try testing.expectEqual(m2[0] - 1, b.pos(@intCast(n))[0]);
        try testing.expectEqual(m2[1], b.pos(@intCast(n))[1]);
    }
    const out = b.pos(b.s.terminalNode(b.net("out")).?);
    try testing.expectEqual(b.pos(b.node("m1"))[0] + 1, out[0]);
}

// ===========================================================================
// Junctions, copies, geometry
// ===========================================================================

test "W1 two devices share at most one straight wire" {
    // Net out asks for m0.d–m1.g (horizontal) and m1.s–m0.g (vertical): no
    // placement keeps both straight. The second is a bend around m1 instead.
    var b = try Built.laidOut(
        \\diode chain
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\M0 out out in 0 nch
        \\M1 a out out 0 nch
        \\M2 in in 0 0 nch
    );
    defer b.deinit();
    try testing.expectEqual(1, b.straightsBetween("m0", "m1"));
    try testing.expectEqual(0, b.s.stats.bent);
    try testing.expectEqual(0, b.s.stats.crossings);
    try testing.expectEqual(0, b.s.stats.overlaps);
    // The out terminal is wired, not left beside the drawing.
    try testing.expect(b.straight(b.leafPin("out"), b.pin("m0", 0)) != null);
    try expectNetsRealised(&b.s);
}

test "J1 an input or output that would fan out gets a junction bar and a stub" {
    var inv = try Built.laidOut(circuit("cmos_inverter"));
    defer inv.deinit();
    const leaf = inv.s.terminalNode(inv.net("in")).?;
    const j = inv.junction("in").?;
    try testing.expectEqual(1, inv.s.groupSize(leaf)); // the terminal is not split
    try testing.expectEqual(3, inv.s.groupSize(j)); // the bar: two gates, bare middle
    try testing.expect(inv.straight(inv.leafPin("in"), inv.s.pinOf(inv.dev("mp"), 1).?) == null);
    const lp = inv.pos(leaf);
    const jp = inv.pos(j);
    try testing.expect(lp[0] < jp[0]); // sticks out to the left
    try testing.expectEqual(lp[1], jp[1]); // level with the bar's middle
    try testing.expect(inv.pos(inv.node("mp"))[1] < jp[1] and jp[1] < inv.pos(inv.node("mn"))[1]);
    try testing.expect(!inv.s.labeled[inv.net("in")]);

    var amp = try Built.laidOut(circuit("noninverting_amp"));
    defer amp.deinit();
    const out = amp.s.terminalNode(amp.net("out")).?;
    try testing.expectEqual(1, amp.s.groupSize(out));
    try testing.expect(amp.pos(amp.junction("out").?)[0] < amp.pos(out)[0]); // sticks out to the right
}

test "J1 not for rails: a supply over several loads stays one rail" {
    var b = try Built.init(circuit("diff_pair_resistive"));
    defer b.deinit();
    try testing.expect(b.junction("vdd") == null);
    try testing.expectEqual(3, b.s.groupSize(b.s.terminalNode(b.net("vdd")).?));
}

test "J2 same-facing pins of one stack share a bar, and the bar taps the net" {
    var b = try Built.laidOut(circuit("ring_oscillator"));
    defer b.deinit();
    // Each inverter's gates hang on a bar; a and b are wired from each
    // drain to the next bar.
    for ([_][]const u8{ "a", "b" }) |n| {
        try testing.expect(!b.s.labeled[b.net(n)]);
        const j = b.joinOn(.tap, n).?;
        try testing.expect(b.s.junctionOf(j.p) != none);
    }
    // All three inverters stand level, left to right.
    const row = struct {
        fn f(x: *const Built, d: []const u8) i32 {
            return x.pos(x.node(d))[1];
        }
    }.f;
    try testing.expectEqual(row(&b, "mp1"), row(&b, "mp2"));
    try testing.expectEqual(row(&b, "mp2"), row(&b, "mp3"));
    try testing.expectEqual(row(&b, "mn1"), row(&b, "mn2"));
    try testing.expectEqual(row(&b, "mn2"), row(&b, "mn3"));
    try testing.expect(b.pos(b.node("mp1"))[0] < b.pos(b.node("mp2"))[0]);
    try testing.expect(b.pos(b.node("mp2"))[0] < b.pos(b.node("mp3"))[0]);
    try expectNetsRealised(&b.s);
}

test "J2 not for devices side by side" {
    var b = try Built.init(
        \\three gates on one net
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\R1 vdd d1 1k
        \\R2 vdd d2 1k
        \\R3 vdd d3 1k
        \\M1 d1 g 0 0 nch
        \\M2 d2 g 0 0 nch
        \\M3 d3 g 0 0 nch
    );
    defer b.deinit();
    try testing.expect(b.junction("g") == null);
}

test "L4 a cycle breaks at its feedback wire" {
    // The ring's three taps close a cycle of order constraints (each stage
    // right of the one before, and the first right of the last). The
    // loop-back c runs against the flow, so c gives way, not a or b.
    var b = try Built.laidOut(circuit("ring_oscillator"));
    defer b.deinit();
    try testing.expect(b.s.labeled[b.net("c")]);
    try testing.expectEqual(1, b.s.stats.labeled_nets);
}

test "S5 a rail's copies follow where their partners land" {
    // Smallest case the fuzzer found: the ground rail's attachments, dealt
    // by key, land out of order; they are re-dealt and the rail runs straight.
    var b = try Built.laidOut(
        \\redeal
        \\.model nch nmos level=1
        \\Vdd vdd 0 1.8
        \\Vin in 0 ac 1
        \\M0 in c a 0 nch
        \\C1 0 a 1p
        \\C2 0 in 1p
        \\C3 in in 1p
    );
    defer b.deinit();
    try testing.expect(b.s.stats.redealt);
    for (b.s.routes.items) |r| {
        if (r.kind == .edge and b.s.edges.items[r.id].kind == .chain) try testing.expect(r.straight);
    }
    try testing.expectEqual(0, b.s.stats.crossings);
}

/// Visible length of the straight wire between two pins.
fn wireLength(b: *const Built, p: u32, q: u32) f32 {
    const u = lay.pinPoint(&b.s, p);
    const v = lay.pinPoint(&b.s, q);
    return @abs(u[0] - v[0]) + @abs(u[1] - v[1]);
}

test "geometry: wire lengths come from the settings, by situation" {
    var b = try Built.laidOut(circuit("cascode"));
    defer b.deinit();
    // In the target's coordinates: one unit is the symbol set's 40.
    const d: config.Layout = .{};
    const u: f32 = @floatFromInt(b.lib.unit);
    try testing.expectEqual(d.stack * u, wireLength(&b, b.pin("m2", 2), b.pin("m1", 0))); // m2 over m1
    try testing.expectEqual(d.terminal * u, wireLength(&b, b.leafPin("in"), b.pin("m1", 1)));
    try testing.expectEqual(d.rail * u, wireLength(&b, b.leafPin("vdd"), b.pin("rd", 0)));

    var cfg: config.Config = .default;
    cfg.layout.stack = 0.75;
    cfg.layout.terminal = 1.5;
    var c = try Built.laidOutWith(circuit("cascode"), &cfg);
    defer c.deinit();
    try testing.expectEqual(0.75 * u, wireLength(&c, c.pin("m2", 2), c.pin("m1", 0)));
    try testing.expectEqual(1.5 * u, wireLength(&c, c.leafPin("in"), c.pin("m1", 1)));
    // Only the spacing changes, never the order.
    try testing.expectEqualSlices([2]i32, b.s.pos, c.s.pos);
}

test "geometry: every coordinate is a whole number of the target's units" {
    var cfg: config.Config = .default;
    cfg.layout.stack = 0.3; // 12.0 units: fine; 0.31 would round up
    cfg.layout.bend = 0.31;
    for (textbook.all ++ textbook.beyond) |c| {
        var b = try Built.laidOutWith(c.spice, &cfg);
        defer b.deinit();
        for (b.s.xy) |p| for (p) |v| try testing.expectEqual(@round(v), v);
        for (b.s.routes.items) |r| for (r.pts[0..r.len]) |p| for (p) |v| try testing.expectEqual(@round(v), v);
    }
}

test "geometry: a bend keeps clearance from its neighbour's symbol" {
    // Sallen-Key: the buffer's feedback comes around under the op-amp into
    // its - input, beside C2's ground symbol.
    var b = try Built.laidOut(circuit("sallen_key"));
    defer b.deinit();
    const g: config.Layout = .{};
    const u: f32 = @floatFromInt(b.lib.unit);
    const ground = b.s.xy[b.s.terminalNode(b.net("0")).?];
    const minus = lay.pinPoint(&b.s, b.pin("e1", 3));
    try testing.expectEqual(ground[1], minus[1]); // the same row
    const stub_x = minus[0] - g.bend * u;
    const half: f32 = @floatFromInt(b.lib.at(b.lib.findRole(.ground_rail).?).bbox().max.x);
    try testing.expect(stub_x - ground[0] >= half + g.clearance * u);
}

// ===========================================================================
// Textbook suite
// ===========================================================================

test "textbook: every circuit draws with no crossings, overlaps or bends" {
    for (textbook.all) |c| {
        errdefer std.debug.print("circuit: {s}\n", .{c.name});
        var b = try Built.laidOut(c.spice);
        defer b.deinit();
        const t = b.s.stats;
        try testing.expectEqual(0, t.crossings);
        try testing.expectEqual(0, t.overlaps);
        try testing.expectEqual(0, t.bent);
        try testing.expectEqual(0, t.conflicts);
        try expectDistinctCells(&b.s);
        try expectNetsRealised(&b.s);
        // Labels only where the rules put them: bias nets (W8), and the
        // bandgap's gate line (L4).
        for (b.s.labeled, 0..) |l, n| {
            const name = b.s.net_name[n];
            const bandgap = std.mem.eql(u8, c.name, "bandgap") and
                std.mem.eql(u8, name, "g");
            try testing.expectEqual(b.roles[n] == .bias or bandgap, l);
        }
    }
}

test "textbook: layout is deterministic" {
    for (textbook.all) |c| {
        var b1 = try Built.laidOut(c.spice);
        defer b1.deinit();
        var b2 = try Built.laidOut(c.spice);
        defer b2.deinit();
        try testing.expectEqualSlices([2]i32, b1.s.pos, b2.s.pos);
    }
}

test "random netlists: terminate, one node per cell, every net drawn or named" {
    const nets = [_][]const u8{ "vdd", "0", "in", "out", "a", "b", "c" };
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for (0..150) |_| {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("random\n.model nch nmos level=1\n.model pch pmos level=1\nVdd vdd 0 1.8\nVin in 0 ac 1\n");
        for (0..r.intRangeAtMost(u32, 2, 6)) |i| {
            const p = nets[r.intRangeLessThan(usize, 0, nets.len)];
            const q = nets[r.intRangeLessThan(usize, 0, nets.len)];
            const g = nets[r.intRangeLessThan(usize, 0, nets.len)];
            switch (r.intRangeAtMost(u32, 0, 3)) {
                0 => try w.print("R{d} {s} {s} 1k\n", .{ i, p, q }),
                1 => try w.print("C{d} {s} {s} 1p\n", .{ i, p, q }),
                2 => try w.print("M{d} {s} {s} {s} 0 nch\n", .{ i, p, g, q }),
                else => try w.print("M{d} {s} {s} {s} vdd pch\n", .{ i, p, g, q }),
            }
        }
        errdefer std.debug.print("{s}\n", .{w.buffered()});
        var b = try Built.laidOut(w.buffered());
        defer b.deinit();
        try expectDistinctCells(&b.s);
        try expectNetsRealised(&b.s);
    }
}

/// `n` instances of one block on a shared output and shared rails, each with
/// its own input and controls: many pieces that only the rails tie together.
fn sharedBlocks(buf: []u8, n: usize) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("shared blocks\n.subckt sw in_ out ctrl ctrl_b vdd vss\nR1 in_ out 1k\n.ends sw\n");
    for (0..n) |i| try w.print("X{d} a{d} out s{d} sn{d} vdd vss sw\n", .{ i, i, i, i });
    return w.buffered();
}

test "L6 many blocks on shared nets: layout work grows with the drawing, not its square" {
    // A request no order could satisfy used to repeat until 4n² rounds (ten
    // blocks took 25 s), and clashes were ordered one per round, each piece
    // stepping past the others one at a time. Now a repeated request ends
    // L6, and past `batch_after` all clashes of a round are ordered at once.
    var buf: [4096]u8 = undefined;
    for ([_]usize{ 2, 10, 40 }) |n| {
        var b = try Built.laidOut(try sharedBlocks(&buf, n));
        defer b.deinit();
        errdefer std.debug.print("{d} blocks: {d} rounds for {d} nodes\n", .{ n, b.s.stats.rounds, b.s.nodes.len });
        try expectDistinctCells(&b.s);
        try expectNetsRealised(&b.s);
        // 7, 343 and 3222 rounds (17, 73 and 283 nodes); the 4n² rounds of
        // a single pass were 21 317 for ten blocks.
        try testing.expect(b.s.stats.rounds <= 20 * b.s.nodes.len);
    }
}
