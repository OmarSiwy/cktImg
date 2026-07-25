//! Behavioral suite for the lattice router and the selection key.
//!
//! Every test here pins a *property* the router's design rests on, not a function's
//! return value. The set is chosen so that a plausible-looking implementation that
//! got any of the load-bearing decisions wrong fails at least one of them:
//!
//! - the Hanan axes carry every pin coordinate, which is the sole reason pin and
//!   short avoidance can be structural rather than a post-route sweep;
//! - body edges snap *away* from the body, so a flush track stays outside it;
//! - collinear sharing is a block and perpendicular passing is a price, and the two
//!   are never confused;
//! - a bend and a crossing cost exactly what ALGORITHM.md says they cost;
//! - owning a pin on a body's boundary grants no licence to cut the body, while a
//!   pin buried in its interior grants exactly that and nothing more;
//! - a rail's shape (spread on the bus, drop vertically) comes out of the cost
//!   table, with no rail-specific code;
//! - a third terminal joins the *tree*, not the seed, which is what makes trunks
//!   emerge;
//! - a label happens only after the search proved exhaustion;
//! - the selection key is a lexicographic total order and never a weighted sum.
//!
//! Fixtures are built straight out of the public `Spec` with an arena, deliberately
//! bypassing placement: a router suite that cannot run until the placer works would
//! be useless for driving this file's implementation order. Coordinates are chosen
//! so every cost in the assertions can be computed by hand from the axes.
//!
//! Expected red until the corresponding function is written.

const std = @import("std");
const ckt = @import("cktimg");

const lattice = ckt.route.lattice;
const dijkstra = ckt.route.dijkstra;
const tree = ckt.route.tree;
const metric = ckt.metric;
const ids = ckt.ids;

const Allocator = std.mem.Allocator;
const Pt = ids.Pt;
const Rect = ids.Rect;
const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const Lattice = lattice.Lattice;
const Spec = lattice.Spec;
const Site = lattice.Site;
const Body = lattice.Body;
const W = dijkstra.W;
const Scratch = ckt.Scratch;
const Physical = ckt.Physical;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

fn pt(x: i32, y: i32) Pt {
    return .{ .x = x, .y = y };
}

fn rect(x0: i32, y0: i32, x1: i32, y1: i32) Rect {
    return .{ .min = .{ .x = x0, .y = y0 }, .max = .{ .x = x1, .y = y1 } };
}

const net1 = NetIdx.at(0);
const net2 = NetIdx.at(1);
const net3 = NetIdx.at(2);
const net4 = NetIdx.at(3);
const foreign = NetIdx.at(7);

// ---------------------------------------------------------------------------
// Fixture F — three devices, hand-computable axes.
//
//   xs = { 0, 10, 20, 40, 60, 70, 80, 95, 100, 120, 140 }      nx = 11
//   ys = { -60, -50, -30, 0, 20, 40, 70, 90, 100 }             ny = 9
//   rows:  margin margin power_bus field field field gnd_bus margin margin
//
//   dev0 body (0,0)-(20,40)     net1 pins at (10,0) top boundary and (0,20) left
//                               boundary — a diode-connected gate-to-drain tie;
//                               net2 pin at (10,40) bottom boundary
//   dev1 body (60,0)-(80,40)    net2 at (70,0), net3 at (70,40)
//   dev2 body (100,0)-(140,40)  net4 at (120,20) — BURIED in the interior — and
//                               net4 at (120,40) on the bottom boundary
// ---------------------------------------------------------------------------

const f_bodies = [_]Body{
    .{ .dev = DeviceIdx.at(0), .rect = rect(0, 0, 20, 40) },
    .{ .dev = DeviceIdx.at(1), .rect = rect(60, 0, 80, 40) },
    .{ .dev = DeviceIdx.at(2), .rect = rect(100, 0, 140, 40) },
};

const f_sites = [_]Site{
    .{ .pin = PinIdx.at(0), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 10, .y = 0 } },
    .{ .pin = PinIdx.at(1), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 0, .y = 20 } },
    .{ .pin = PinIdx.at(2), .dev = DeviceIdx.at(0), .net = net2, .at = .{ .x = 10, .y = 40 } },
    .{ .pin = PinIdx.at(3), .dev = DeviceIdx.at(1), .net = net2, .at = .{ .x = 70, .y = 0 } },
    .{ .pin = PinIdx.at(4), .dev = DeviceIdx.at(1), .net = net3, .at = .{ .x = 70, .y = 40 } },
    .{ .pin = PinIdx.at(5), .dev = DeviceIdx.at(2), .net = net4, .at = .{ .x = 120, .y = 20 } },
    .{ .pin = PinIdx.at(6), .dev = DeviceIdx.at(2), .net = net4, .at = .{ .x = 120, .y = 40 } },
};

const f_col_x = [_]i32{ 10, 70, 120 };
const f_lane_x = [_]i32{ 40, 95 };

fn specF() Spec {
    return .{
        .col_x = &f_col_x,
        .lane_x = &f_lane_x,
        .bodies = &f_bodies,
        .sites = &f_sites,
        .power_bus = -30,
        .gnd_bus = 70,
        .top_margin = -50,
        .bot_margin = 90,
        .grid = 1,
        .track_h = 10,
        .margin_rows = 2,
    };
}

/// A lattice plus the reusable search state, torn down together.
///
/// The lattice comes out of an arena and has no `deinit` — that is the documented
/// lifetime (it dies with `search.reset`), so the arena is what releases it. Scratch
/// survives arena resets in the real pipeline and is therefore owned separately,
/// which the teardown mirrors.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    lat: Lattice,
    sc: Scratch,

    fn init(self: *Fixture, spec: Spec) !void {
        self.arena = .init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.lat = try Lattice.build(self.arena.allocator(), spec);
        self.sc = .empty;
        errdefer self.sc.deinit(std.testing.allocator);
        try self.sc.ensure(std.testing.allocator, self.lat.nodeCount());
    }

    fn deinit(self: *Fixture) void {
        self.sc.deinit(std.testing.allocator);
        self.arena.deinit();
    }

    fn alloc(self: *Fixture) Allocator {
        return self.arena.allocator();
    }

    fn nodeAt(self: *Fixture, x: i32, y: i32) u32 {
        return self.lat.nodeAt(pt(x, y)) orelse unreachable;
    }
};

// ---------------------------------------------------------------------------
// The lattice: axes
// ---------------------------------------------------------------------------

test "every pin coordinate is a lattice axis value, so a pin is always a node" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    // This is the property the whole "collision is structural" argument rests on:
    // if a pin were not on both axes, a wire could pass through it without visiting
    // a node and no amount of node blocking would stop it.
    for (f_sites) |s| {
        try expect(std.mem.indexOfScalar(i32, f.lat.xs, s.at.x) != null);
        try expect(std.mem.indexOfScalar(i32, f.lat.ys, s.at.y) != null);
        try expect(f.lat.nodeAt(s.at) != null);
    }
}

test "axes are strictly ascending and deduplicated" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    // col_x duplicates pin x values (10, 70, 120) on purpose; a duplicate axis value
    // would create a zero-length edge, and a zero-length edge is a free bend.
    for (f.lat.xs[1..], 0..) |x, i| try expect(x > f.lat.xs[i]);
    for (f.lat.ys[1..], 0..) |y, i| try expect(y > f.lat.ys[i]);
    try expectEqual(@as(u32, @intCast(f.lat.xs.len)), f.lat.nx);
    try expectEqual(@as(u32, @intCast(f.lat.ys.len)), f.lat.ny);
    try expectEqual(f.lat.nx * f.lat.ny, f.lat.nodeCount());
}

test "the node index is iy times nx plus ix in both directions" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    var iy: u32 = 0;
    while (iy < f.lat.ny) : (iy += 1) {
        var ix: u32 = 0;
        while (ix < f.lat.nx) : (ix += 1) {
            const n = f.lat.node(ix, iy);
            try expectEqual(iy * f.lat.nx + ix, n);
            try expectEqual(ix, f.lat.ixOf(n));
            try expectEqual(iy, f.lat.iyOf(n));
            try expectEqual(pt(f.lat.xs[ix], f.lat.ys[iy]), f.lat.pt(n));
            try expectEqual(n, f.lat.nodeAt(f.lat.pt(n)).?);
        }
    }
}

test "a body edge snaps away from the body, never into it" {
    // Body extents are draw-derived and are not grid multiples. Snapping the low
    // side up or the high side down would round a flush track *into* the device it
    // is supposed to hug, which is exactly the track a gate-to-drain tie needs.
    const bodies = [_]Body{.{ .dev = DeviceIdx.at(0), .rect = rect(3, 5, 17, 27) }};
    const sites = [_]Site{
        .{ .pin = PinIdx.at(0), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 8, .y = 0 } },
    };
    var f: Fixture = undefined;
    try f.init(.{
        .bodies = &bodies,
        .sites = &sites,
        .power_bus = -32,
        .gnd_bus = 64,
        .top_margin = -48,
        .bot_margin = 80,
        .grid = 8,
        .track_h = 16,
        .margin_rows = 1,
    });
    defer f.deinit();

    try expect(std.mem.indexOfScalar(i32, f.lat.xs, 0) != null); // floor(3)
    try expect(std.mem.indexOfScalar(i32, f.lat.xs, 24) != null); // ceil(17)
    try expect(std.mem.indexOfScalar(i32, f.lat.ys, 0) != null); // floor(5)
    try expect(std.mem.indexOfScalar(i32, f.lat.ys, 32) != null); // ceil(27)
    // Nothing derived from the body landed inside it.
    try expect(std.mem.indexOfScalar(i32, f.lat.xs, 8) != null); // the pin, not the body
    try expect(std.mem.indexOfScalar(i32, f.lat.xs, 16) == null);
    try expectEqual(@as(i32, 0), lattice.snapFloor(3, 8));
    try expectEqual(@as(i32, 24), lattice.snapCeil(17, 8));
}

test "every lattice coordinate lands on the host grid" {
    const bodies = [_]Body{.{ .dev = DeviceIdx.at(0), .rect = rect(3, 5, 17, 27) }};
    const sites = [_]Site{
        .{ .pin = PinIdx.at(0), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 8, .y = 0 } },
    };
    var f: Fixture = undefined;
    try f.init(.{
        .bodies = &bodies,
        .sites = &sites,
        .power_bus = -30, // not a multiple of 8; snaps to the nearest row
        .gnd_bus = 65,
        .top_margin = -47,
        .bot_margin = 81,
        .grid = 8,
        .track_h = 16,
        .margin_rows = 2,
    });
    defer f.deinit();

    // Every wire vertex will land on one of these, so all of them must be on grid.
    for (f.lat.xs) |x| try expectEqual(@as(i32, 0), @mod(x, 8));
    for (f.lat.ys) |y| try expectEqual(@as(i32, 0), @mod(y, 8));
}

test "rows outside the two buses are margin and rows between them are field" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    for (f.lat.ys, f.lat.row) |y, r| {
        const want: lattice.Row = if (y == -30)
            .power_bus
        else if (y == 70)
            .gnd_bus
        else if (y < -30 or y > 70)
            .margin
        else
            .field;
        try expectEqual(want, r);
    }
    // The bands actually exist: two rows above the power bus and two below ground.
    var margins: usize = 0;
    for (f.lat.row) |r| margins += @intFromBool(r == .margin);
    try expectEqual(@as(usize, 4), margins);
}

// ---------------------------------------------------------------------------
// The lattice: structural blocking
// ---------------------------------------------------------------------------

test "a foreign pin is an unreachable node while its own net may enter" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    const from = f.nodeAt(0, 0);
    const to = f.nodeAt(10, 0); // net1's pin

    try expect(f.lat.nodeBlocked(to, net2));
    try expect(!f.lat.nodeBlocked(to, net1));
    try expectEqual(@as(?u32, null), dijkstra.stepCost(&f.lat, net2, .signal, from, .h, to, .h));
    try expectEqual(
        @as(?u32, 10 * W.base),
        dijkstra.stepCost(&f.lat, net1, .signal, from, .h, to, .h),
    );
}

test "a collinear foreign-net edge is blocked as a short" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    // A foreign net already runs down the lane at x = 40.
    f.lat.occupy(foreign, &.{ pt(40, 0), pt(40, 40) });

    const a = f.nodeAt(40, 0);
    const b = f.nodeAt(40, 20);
    // Sharing the edge would draw as one wire: hard block, never a price.
    try expect(f.lat.edgeShorted(.v, f.lat.vEdge(f.lat.ixOf(a), f.lat.iyOf(a)), net1));
    try expectEqual(@as(?u32, null), dijkstra.stepCost(&f.lat, net1, .signal, a, .v, b, .v));
    // The net that drew it may retrace its own edge.
    try expect(!f.lat.edgeShorted(.v, f.lat.vEdge(f.lat.ixOf(a), f.lat.iyOf(a)), foreign));
    try expect(dijkstra.stepCost(&f.lat, foreign, .signal, a, .v, b, .v) != null);
}

test "a perpendicular crossing is reachable and priced at the crossing weight" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    f.lat.occupy(foreign, &.{ pt(40, 0), pt(40, 40) });

    const from = f.nodeAt(20, 20);
    const to = f.nodeAt(40, 20); // mid-run of the foreign wire, but not a vertex
    // Passing through, perpendicular, is a genuine crossing: expensive and finite.
    // The node itself is NOT owned — only the foreign net's vertices are.
    try expect(!f.lat.nodeBlocked(to, net1));
    try expect(f.lat.crosses(to, .h, net1));
    try expectEqual(
        @as(?u32, 20 * W.base + W.cross),
        dijkstra.stepCost(&f.lat, net1, .signal, from, .h, to, .h),
    );
}

test "a direction change costs exactly the bend weight" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    const from = f.nodeAt(0, 0);
    const to = f.nodeAt(10, 0);
    const straight = dijkstra.stepCost(&f.lat, net1, .signal, from, .h, to, .h).?;
    const bent = dijkstra.stepCost(&f.lat, net1, .signal, from, .v, to, .h).?;
    try expectEqual(@as(u32, 10 * W.base), straight);
    try expectEqual(straight + W.bend, bent);
}

test "owning a boundary pin is no licence to cut the body" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    // net1 owns the pin at (0,20) on dev0's left edge. The step inland from it runs
    // through the open interior, and the pin does not license it — otherwise one
    // lattice edge would span gate pin to far body edge and a gate-to-drain tie
    // would drive straight across the symbol.
    const gate = f.nodeAt(0, 20);
    const inland = f.nodeAt(10, 20);
    try expectEqual(DeviceIdx.none, f.lat.node_bury[gate]);
    try expectEqual(
        @as(?u32, null),
        dijkstra.stepCost(&f.lat, net1, .signal, gate, .h, inland, .h),
    );
}

test "a pin buried in its own body licenses that body's edges and no other net's" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    const buried = f.nodeAt(120, 20);
    const boundary = f.nodeAt(120, 40);
    try expectEqual(DeviceIdx.at(2), f.lat.node_bury[buried]);
    // The exemption exists for exactly one reason: without it the buried pin is
    // unreachable, since every edge landing on it cuts the body.
    try expect(dijkstra.stepCost(&f.lat, net4, .signal, boundary, .v, buried, .v) != null);
    try expectEqual(
        @as(?u32, null),
        dijkstra.stepCost(&f.lat, net1, .signal, boundary, .v, buried, .v),
    );
}

test "a flush track along a body edge stays legal" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    // Row y = 0 is dev0's top edge. An edge merely touching the body is clear; only
    // an edge through the open interior is blocked. Closed-rectangle overlap here
    // would forbid hugging a device and force every route out to a channel.
    const a = f.nodeAt(0, 0);
    const b = f.nodeAt(10, 0);
    try expect(!f.lat.edgeCutsBody(.h, f.lat.hEdge(f.lat.ixOf(a), f.lat.iyOf(a)), net2, a, b));
    try expect(!lattice.overlapsOpen(rect(0, 0, 10, 0), f_bodies[0].rect));
    // ...while the row through the middle is not.
    const c = f.nodeAt(0, 20);
    const d = f.nodeAt(10, 20);
    try expect(f.lat.edgeCutsBody(.h, f.lat.hEdge(f.lat.ixOf(c), f.lat.iyOf(c)), net2, c, d));
}

test "occupancy from one net is visible to the next net routed" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    const mid = f.nodeAt(40, 0);
    try expect(!f.lat.nodeBlocked(mid, net1));
    f.lat.occupy(foreign, &.{ pt(40, 0), pt(40, 40) });
    // A vertex is a hard block — a T into a foreign net is a short.
    try expect(f.lat.nodeBlocked(mid, net1));
    try expect(!f.lat.nodeBlocked(mid, foreign));
    try expectEqual(foreign, f.lat.node_net[mid]);
}

fn buildF(gpa: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const lat = try Lattice.build(arena.allocator(), specF());
    try expect(lat.nodeCount() > 0);
    try expect(lat.h_occ.len == lat.hEdgeCount());
    try expect(lat.v_occ.len == lat.vEdgeCount());
}

test "lattice construction releases everything when any single allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildF, .{});
}

// ---------------------------------------------------------------------------
// Costs
// ---------------------------------------------------------------------------

test "the cost weights hold their documented values" {
    // These are not config knobs. They encode what a schematic means, so they are
    // comptime and a change here is a change to the drawing's reasoning.
    try expectEqual(@as(u32, 10), W.base);
    try expectEqual(@as(u32, 1), W.bus);
    try expectEqual(@as(u32, 80), W.off);
    try expectEqual(@as(u32, 80), W.margin);
    try expectEqual(@as(u32, 900), W.bend);
    try expectEqual(@as(u32, 3000), W.cross);
    // The ratios are the opinion, and a device cell is 40 units wide: a bend is
    // worth about two cells of wire, a crossing about seven, and a rail pays eighty
    // times its bus rate to stand anywhere else.
    try expect(W.bend >= 2 * 40 * W.base);
    try expect(W.cross >= 7 * 40 * W.base);
    try expect(W.cross > W.bend);
    try expectEqual(W.off, W.bus * 80);
}

test "a rail's own bus row is nearly free and every other row is dear to it" {
    try expectEqual(W.bus, dijkstra.rowCost(.power_bus, .power));
    try expectEqual(W.bus, dijkstra.rowCost(.gnd_bus, .ground));
    try expectEqual(W.off, dijkstra.rowCost(.field, .power));
    try expectEqual(W.off, dijkstra.rowCost(.margin, .power));
    try expectEqual(W.off, dijkstra.rowCost(.gnd_bus, .power));
    try expectEqual(W.off, dijkstra.rowCost(.power_bus, .ground));
    try expectEqual(W.off, dijkstra.rowCost(.field, .ground));
    // A signal pays the ordinary rate in the field and eight times that in the
    // margin, which is the whole of "the margin is for backward feedback".
    try expectEqual(W.base, dijkstra.rowCost(.field, .signal));
    try expectEqual(W.margin, dijkstra.rowCost(.margin, .signal));
    try expectEqual(@as(u32, 8), W.margin / W.base);
}

// ---------------------------------------------------------------------------
// Dijkstra
// ---------------------------------------------------------------------------

test "dijkstra allocates nothing per call" {
    // The signature is the guarantee: with no allocator parameter a call cannot
    // acquire memory, so this is checked at compile time and then confirmed.
    comptime {
        for (@typeInfo(@TypeOf(dijkstra.run)).@"fn".params) |p| {
            if (p.type) |T| {
                if (T == std.mem.Allocator) @compileError("dijkstra.run must not take an allocator");
            }
        }
    }

    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    // Scratch is already sized, and `ensure` is monotonic: no allocation, so a
    // failing allocator sails through it.
    try f.sc.ensure(failing.allocator(), f.lat.nodeCount());

    const sources = [_]u32{f.nodeAt(10, 0)};
    const targets = [_]u32{f.nodeAt(70, 0)};
    _ = dijkstra.run(&f.lat, &f.sc, .{
        .net = net1,
        .kind = .signal,
        .sources = &sources,
        .targets = &targets,
    });
    try expectEqual(@as(usize, 0), failing.allocations);
}

test "scratch is sized for the heap's worst case before any search runs" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    const nodes = f.lat.nodeCount();
    try expect(f.sc.capacity >= nodes);
    try expectEqual(@as(usize, nodes) * 2, f.sc.dist.len);
    try expectEqual(f.sc.dist.len, f.sc.dist_gen.len);
    try expectEqual(f.sc.dist.len, f.sc.prev.len);
    try expect(f.sc.heap.len >= dijkstra.heapCapacityFor(nodes));
}

test "generation stamping invalidates the previous search instead of clearing" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    const near = f.nodeAt(20, 0);

    // net1's own two pins — the diode tie. (70,0) is net2's pin, so aiming a net1
    // search there is structurally unroutable and `run` rightly returns null.
    const a_src = [_]u32{f.nodeAt(10, 0)};
    const a_dst = [_]u32{f.nodeAt(0, 20)};
    try expect(dijkstra.run(&f.lat, &f.sc, .{
        .net = net1,
        .kind = .signal,
        .sources = &a_src,
        .targets = &a_dst,
    }) != null);
    const gen_a = f.sc.gen;
    // The first search certainly relaxed the seed's right-hand neighbour.
    try expect(dijkstra.distOf(&f.sc, dijkstra.slotOf(near, .h)) < dijkstra.inf);

    // A second, tiny search on the far side of the lattice pops its target
    // immediately and never touches that node again.
    const b_src = [_]u32{f.nodeAt(120, 20)};
    const b_dst = [_]u32{f.nodeAt(120, 40)};
    try expect(dijkstra.run(&f.lat, &f.sc, .{
        .net = net4,
        .kind = .signal,
        .sources = &b_src,
        .targets = &b_dst,
    }) != null);
    try expect(f.sc.gen != gen_a);
    // No stale distance bleeds through: the stamp, not the value, decides liveness.
    try expectEqual(dijkstra.inf, dijkstra.distOf(&f.sc, dijkstra.slotOf(near, .h)));
    try expect(!f.sc.isLive(dijkstra.slotOf(near, .h)));
}

test "a multi-source expansion starts free from every node already in the tree" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    // Two sources, one much closer to the target. Seeding both directions at zero
    // means the first move off the tree never pays a bend, so the answer is a plain
    // 10-unit run rather than 10 units plus a bend.
    const sources = [_]u32{ f.nodeAt(0, 0), f.nodeAt(60, 0) };
    const targets = [_]u32{f.nodeAt(70, 0)};
    const slot = dijkstra.run(&f.lat, &f.sc, .{
        .net = net2,
        .kind = .signal,
        .sources = &sources,
        .targets = &targets,
    }).?;
    try expectEqual(f.nodeAt(70, 0), dijkstra.nodeOf(slot));
    try expectEqual(@as(u32, 10 * W.base), dijkstra.distOf(&f.sc, slot));

    var buf: [64]u32 = undefined;
    const path = dijkstra.reconstruct(&f.sc, slot, &buf);
    try expectEqual(@as(usize, 2), path.len);
    try expectEqual(f.nodeAt(60, 0), path[0]);
    try expectEqual(f.nodeAt(70, 0), path[1]);
}

// ---------------------------------------------------------------------------
// Tree growth
// ---------------------------------------------------------------------------

// Fixture T — no bodies, three terminals of one net.
//   xs = { 0, 40, 80 }      ys = { -50, -30, 0, 40, 70, 90 }
const t_sites = [_]Site{
    .{ .pin = PinIdx.at(0), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 0, .y = 0 } },
    .{ .pin = PinIdx.at(1), .dev = DeviceIdx.at(1), .net = net1, .at = .{ .x = 80, .y = 0 } },
    .{ .pin = PinIdx.at(2), .dev = DeviceIdx.at(2), .net = net1, .at = .{ .x = 40, .y = 40 } },
};
const t_col_x = [_]i32{ 0, 40, 80 };

fn specT() Spec {
    return .{
        .col_x = &t_col_x,
        .sites = &t_sites,
        .power_bus = -30,
        .gnd_bus = 70,
        .top_margin = -50,
        .bot_margin = 90,
        .grid = 1,
        .track_h = 10,
        .margin_rows = 1,
    };
}

const t_terminals = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 80, .y = 0 }, .{ .x = 40, .y = 40 } };

test "a third terminal joins the existing tree, not the seed" {
    var f: Fixture = undefined;
    try f.init(specT());
    defer f.deinit();

    var wires: tree.Wires = .empty; // arena-backed; released with the fixture
    const ok = try tree.growTree(f.alloc(), &f.lat, &f.sc, .{
        .net = net1,
        .kind = .signal,
        .terminals = &t_terminals,
        .span = 2,
        .label_at = &t_terminals,
    }, &wires);
    try expect(ok);

    // Expansion 1 takes the cheap straight run to (80,0). Expansion 2 then starts
    // from the WHOLE tree, so (40,40) drops off the middle of that run rather than
    // detouring back to the seed. No bus or trunk code path produced this.
    try expectEqual(@as(usize, 2), wires.segmentCount());
    try expectEqualSlices(Pt, &.{ pt(0, 0), pt(80, 0) }, wires.segment(0));
    try expectEqualSlices(Pt, &.{ pt(40, 0), pt(40, 40) }, wires.segment(1));

    // The junction point is interior to the trunk, and is neither terminal.
    const joint = wires.segment(1)[0];
    try expect(metric.onSegmentInterior(joint, pt(0, 0), pt(80, 0)));
    try expect(!joint.eql(t_terminals[0]));
    try expect(!joint.eql(t_terminals[1]));
}

test "a rail spreads along its own bus row and only drops vertically" {
    // Two field pins and a rail pin on the power bus. Nothing in the router knows
    // what a bus is: the shape comes out of rowCost alone.
    const bodies = [_]Body{
        .{ .dev = DeviceIdx.at(0), .rect = rect(0, 0, 20, 40) },
        .{ .dev = DeviceIdx.at(1), .rect = rect(60, 0, 80, 40) },
    };
    const sites = [_]Site{
        .{ .pin = PinIdx.at(0), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 10, .y = 0 } },
        .{ .pin = PinIdx.at(1), .dev = DeviceIdx.at(1), .net = net1, .at = .{ .x = 70, .y = 0 } },
        .{
            .pin = PinIdx.at(2),
            .dev = DeviceIdx.at(2),
            .net = net1,
            .at = .{ .x = 40, .y = -30 },
            .obstacle = false, // a rail draws as a bus symbol, not a placed pin
        },
    };
    const col_x = [_]i32{ 10, 70 };
    const lane_x = [_]i32{40};
    var f: Fixture = undefined;
    try f.init(.{
        .col_x = &col_x,
        .lane_x = &lane_x,
        .bodies = &bodies,
        .sites = &sites,
        .power_bus = -30,
        .gnd_bus = 70,
        .top_margin = -50,
        .bot_margin = 90,
        .grid = 1,
        .track_h = 10,
        .margin_rows = 1,
    });
    defer f.deinit();

    const terminals = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 70, .y = 0 }, .{ .x = 40, .y = -30 } };
    var wires: tree.Wires = .empty;
    try expect(try tree.growTree(f.alloc(), &f.lat, &f.sc, .{
        .net = net1,
        .kind = .power,
        .terminals = &terminals,
        .span = 1,
        .label_at = &terminals,
    }, &wires));

    // A direct 60-unit run across the field would cost 60 * W.off = 4800; going up
    // to the bus, across at W.bus and back down costs 2460. Assert the *shape*: no
    // horizontal run anywhere but the bus row.
    var horizontals: usize = 0;
    var s: usize = 0;
    while (s < wires.segmentCount()) : (s += 1) {
        const poly = wires.segment(s);
        for (poly[1..], 0..) |b, i| {
            const a = poly[i];
            if (a.y == b.y) {
                horizontals += 1;
                try expectEqual(@as(i32, -30), a.y);
            } else {
                try expectEqual(a.x, b.x); // Manhattan: no diagonals, ever
            }
        }
    }
    try expect(horizontals >= 1);
}

test "a diode-connected tie routes around its own body, never through it" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    // net1 is dev0's gate (0,20) tied to its drain (10,0). The straight L through
    // the body is blocked, so the search hugs the left edge instead of stepping out
    // to a channel — tighter, and found by the same search that finds the obvious
    // route.
    const terminals = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 20 } };
    var wires: tree.Wires = .empty;
    try expect(try tree.growTree(f.alloc(), &f.lat, &f.sc, .{
        .net = net1,
        .kind = .signal,
        .terminals = &terminals,
        .span = 0,
        .label_at = &terminals,
    }, &wires));

    try expectEqual(@as(usize, 1), wires.segmentCount());
    try expectEqualSlices(Pt, &.{ pt(10, 0), pt(0, 0), pt(0, 20) }, wires.segment(0));
    // Nothing entered the open interior of dev0.
    for (wires.segment(0)) |p| {
        try expect(!(p.x > 0 and p.x < 20 and p.y > 0 and p.y < 40));
    }
}

test "a buried pin is reached straight through its own body" {
    var f: Fixture = undefined;
    try f.init(specF());
    defer f.deinit();

    const terminals = [_]Pt{ .{ .x = 120, .y = 20 }, .{ .x = 120, .y = 40 } };
    var wires: tree.Wires = .empty;
    try expect(try tree.growTree(f.alloc(), &f.lat, &f.sc, .{
        .net = net4,
        .kind = .signal,
        .terminals = &terminals,
        .span = 0,
        .label_at = &terminals,
    }, &wires));
    try expectEqual(@as(usize, 1), wires.segmentCount());
    try expectEqualSlices(Pt, &.{ pt(120, 20), pt(120, 40) }, wires.segment(0));
}

test "compression leaves one vertex per corner and none in between" {
    var pts = [_]Pt{
        pt(0, 0), pt(0, 0), pt(10, 0), pt(20, 0), pt(40, 0), pt(40, 20), pt(40, 40),
    };
    const out = tree.compress(&pts);
    // Intermediate collinear points would each read as a wire ENDPOINT to the
    // junction-dot arm count, so compression is part of that contract.
    try expectEqualSlices(Pt, &.{ pt(0, 0), pt(40, 0), pt(40, 40) }, out);
}

// Fixture L — a terminal walled in by foreign pins, so no tree can exist.
const l_walled_sites = [_]Site{
    .{ .pin = PinIdx.at(0), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 0, .y = 0 } },
    .{ .pin = PinIdx.at(1), .dev = DeviceIdx.at(0), .net = net1, .at = .{ .x = 40, .y = 0 } },
    .{ .pin = PinIdx.at(2), .dev = DeviceIdx.at(1), .net = net2, .at = .{ .x = 20, .y = 0 } },
    .{ .pin = PinIdx.at(3), .dev = DeviceIdx.at(1), .net = net2, .at = .{ .x = 40, .y = 20 } },
    .{ .pin = PinIdx.at(4), .dev = DeviceIdx.at(1), .net = net2, .at = .{ .x = 40, .y = -30 } },
};
const l_open_sites = l_walled_sites[0..2];
const l_col_x = [_]i32{ 0, 20, 40 };
const l_terminals = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 0 } };

fn specL(sites: []const Site) Spec {
    return .{
        .col_x = &l_col_x,
        .sites = sites,
        .power_bus = -30,
        .gnd_bus = 20,
        .top_margin = -50,
        .bot_margin = 40,
        .grid = 1,
        .track_h = 10,
        .margin_rows = 1,
    };
}

test "a net is labelled only when the search proves no tree exists" {
    // Control: the identical lattice without the wall routes, so the fallback is
    // about exhaustion and not about the shape being unfamiliar.
    {
        var f: Fixture = undefined;
        try f.init(specL(l_open_sites));
        defer f.deinit();
        var wires: tree.Wires = .empty;
        const jobs = [_]tree.Job{.{
            .net = net1,
            .kind = .signal,
            .terminals = &l_terminals,
            .span = 2,
            .label_at = &l_terminals,
        }};
        try tree.routeAll(f.alloc(), &f.lat, &f.sc, &jobs, &wires);
        try expectEqual(@as(usize, 0), wires.labels.items.len);
        try expect(wires.segmentCount() >= 1);
    }

    // Walled in: every neighbour of (40,0) belongs to another net, so Dijkstra
    // drains the queue and returns nothing. Only then is a label emitted — and it
    // must cover EVERY pin, because a geometric host connects by name only where a
    // label touches.
    {
        var f: Fixture = undefined;
        try f.init(specL(&l_walled_sites));
        defer f.deinit();
        var wires: tree.Wires = .empty;
        const jobs = [_]tree.Job{.{
            .net = net1,
            .kind = .signal,
            .terminals = &l_terminals,
            .span = 2,
            .label_at = &l_terminals,
        }};
        try tree.routeAll(f.alloc(), &f.lat, &f.sc, &jobs, &wires);
        try expectEqual(@as(usize, 0), wires.segmentCount());
        try expectEqual(@as(usize, 2), wires.labels.items.len);
        try expectEqual(net1, wires.labels.items[0].net);
        try expectEqual(pt(0, 0), wires.labels.items[0].at);
        try expectEqual(pt(40, 0), wires.labels.items[1].at);
    }
}

test "signals route in order of increasing span, rails first" {
    var jobs = [_]tree.Job{
        .{ .net = net3, .kind = .signal, .terminals = &.{}, .span = 3, .label_at = &.{} },
        .{ .net = net4, .kind = .signal, .terminals = &.{}, .span = 1, .label_at = &.{} },
        .{ .net = net2, .kind = .ground, .terminals = &.{}, .span = 5, .label_at = &.{} },
        .{ .net = net1, .kind = .signal, .terminals = &.{}, .span = 1, .label_at = &.{} },
    };
    tree.sortJobs(&jobs);

    // Rails first — they own their bus rows and establish the frame regardless of
    // how far they reach. Then least freedom first: a narrow net has essentially one
    // acceptable path, so it picks before a spanning net crowds it out. Ties break
    // on net index, which is what makes the order total.
    try expectEqual(net2, jobs[0].net);
    try expectEqual(net1, jobs[1].net);
    try expectEqual(net4, jobs[2].net);
    try expectEqual(net3, jobs[3].net);
    // Stated as the invariant rather than as four indices: after the rails, span is
    // non-decreasing, and equal spans are in net order.
    for (jobs[2..], 1..) |j, i| {
        const prev = jobs[i];
        try expect(prev.kind != .signal or j.span > prev.span or
            (j.span == prev.span and @intFromEnum(j.net) > @intFromEnum(prev.net)));
    }
}

test "two identical runs produce byte-identical geometry" {
    var out: [2]struct { segs: usize, pts: []const Pt, nets: []const NetIdx, offs: []const u32 } = undefined;
    var fixtures: [2]Fixture = undefined;
    var wires: [2]tree.Wires = .{ .empty, .empty };

    for (&fixtures) |*fx| try fx.init(specT());
    defer for (&fixtures) |*fx| fx.deinit();

    for (0..2) |k| {
        const jobs = [_]tree.Job{.{
            .net = net1,
            .kind = .signal,
            .terminals = &t_terminals,
            .span = 2,
            .label_at = &t_terminals,
        }};
        try tree.routeAll(
            fixtures[k].alloc(),
            &fixtures[k].lat,
            &fixtures[k].sc,
            &jobs,
            &wires[k],
        );
        out[k] = .{
            .segs = wires[k].segmentCount(),
            .pts = wires[k].pts.items,
            .nets = wires[k].seg_net.items,
            .offs = wires[k].seg_off.items,
        };
    }

    try expectEqual(out[0].segs, out[1].segs);
    try expectEqualSlices(Pt, out[0].pts, out[1].pts);
    try expectEqualSlices(NetIdx, out[0].nets, out[1].nets);
    try expectEqualSlices(u32, out[0].offs, out[1].offs);
}

test "packing reorders segments into net order without consulting a map" {
    var f: Fixture = undefined;
    try f.init(specT());
    defer f.deinit();

    var wires: tree.Wires = .empty;
    // Emitted out of net order, exactly as span-first routing does.
    try wires.emit(f.alloc(), net3, &.{ pt(0, 0), pt(40, 0) });
    try wires.emit(f.alloc(), net1, &.{ pt(0, 40), pt(40, 40) });
    try wires.emit(f.alloc(), net3, &.{ pt(40, 0), pt(40, 40) });

    var phys: Physical = .empty;
    try wires.pack(f.alloc(), 3, &phys);

    try expectEqualSlices(u32, &.{ 0, 1, 1, 3 }, phys.net_seg);
    try expectEqualSlices(u32, &.{ 0, 2, 4, 6 }, phys.seg_pt);
    // net1's single segment sorts first; net3 keeps its two in emission order,
    // which is tree-growth order — the order a reader would trace the net in.
    try expectEqualSlices(Pt, &.{ pt(0, 40), pt(40, 40) }, phys.segment(net1, 0));
    try expectEqualSlices(Pt, &.{ pt(0, 0), pt(40, 0) }, phys.segment(net3, 0));
    try expectEqualSlices(Pt, &.{ pt(40, 0), pt(40, 40) }, phys.segment(net3, 1));
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

// A hand-built Physical: net1 is a trunk with a T, net2 is an unrelated vertical
// crossing it. Two nets, five pins, three segments.
//
//   net1: (0,0)-(80,0) and (40,0)-(40,40); pins (0,0) (80,0) (40,40)
//   net2: (20,-20)-(20,20);                pins (20,-20) (20,20)
fn crossoverPhysical() struct { phys: Physical, pin_net: []const NetIdx } {
    const S = struct {
        var wire_pts = [_]Pt{
            .{ .x = 0, .y = 0 },    .{ .x = 80, .y = 0 },
            .{ .x = 40, .y = 0 },   .{ .x = 40, .y = 40 },
            .{ .x = 20, .y = -20 }, .{ .x = 20, .y = 20 },
        };
        var net_seg = [_]u32{ 0, 2, 3 };
        var seg_pt = [_]u32{ 0, 2, 4, 6 };
        var pin_xy = [_]Pt{
            .{ .x = 0, .y = 0 },    .{ .x = 80, .y = 0 },  .{ .x = 40, .y = 40 },
            .{ .x = 20, .y = -20 }, .{ .x = 20, .y = 20 },
        };
        const pin_net = [_]NetIdx{ net1, net1, net1, net2, net2 };
    };
    return .{
        .phys = .{
            .pos = &.{},
            .pin_xy = &S.pin_xy,
            .net_seg = &S.net_seg,
            .seg_pt = &S.seg_pt,
            .wire_pts = &S.wire_pts,
            .junctions = &.{},
            .labels = &.{},
        },
        .pin_net = &S.pin_net,
    };
}

test "a junction dot appears where three same-net arms meet and nowhere else" {
    const fx = crossoverPhysical();
    const dots = try metric.junctions(std.testing.allocator, fx.pin_net, fx.phys);
    defer std.testing.allocator.free(dots);

    // (40,0): the trunk passes through its interior (2 arms) and the drop ends
    // there (1 arm) = 3. Every other point on net1 is 2 arms — a corner, or a wire
    // reaching a pin — and gets nothing.
    try expectEqualSlices(Pt, &.{pt(40, 0)}, dots);
}

test "a different-net crossover gets no dot" {
    const fx = crossoverPhysical();
    const dots = try metric.junctions(std.testing.allocator, fx.pin_net, fx.phys);
    defer std.testing.allocator.free(dots);

    // net2 crosses net1's trunk at (20,0). Two arms each, on two different nets,
    // and arms never pool across nets — so the drawing correctly reads as *not
    // connected*.
    for (dots) |d| try expect(!d.eql(pt(20, 0)));
}

test "a corner and a wire reaching a pin are two arms and get no dot" {
    var wire_pts = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 0 }, .{ .x = 40, .y = 40 } };
    var net_seg = [_]u32{ 0, 1 };
    var seg_pt = [_]u32{ 0, 3 };
    var pin_xy = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 40 } };
    const pin_net = [_]NetIdx{ net1, net1 };
    const phys: Physical = .{
        .pos = &.{},
        .pin_xy = &pin_xy,
        .net_seg = &net_seg,
        .seg_pt = &seg_pt,
        .wire_pts = &wire_pts,
        .junctions = &.{},
        .labels = &.{},
    };
    const dots = try metric.junctions(std.testing.allocator, &pin_net, phys);
    defer std.testing.allocator.free(dots);
    try expectEqual(@as(usize, 0), dots.len);
}

test "a perpendicular interior intersection counts as one crossing" {
    const fx = crossoverPhysical();
    const counts = metric.countCrossingsAndOverlaps(fx.phys);
    try expectEqual(@as(u32, 1), counts.crossings);
    try expectEqual(@as(u32, 0), counts.overlaps);
}

test "collinear different-net segments sharing a span count as an overlap" {
    // Two horizontals of different nets sharing x in [20,40]: they draw as ONE wire
    // and read as a false connection, which is why overlaps rank above crossings.
    var wire_pts = [_]Pt{
        .{ .x = 0, .y = 0 },  .{ .x = 40, .y = 0 },
        .{ .x = 20, .y = 0 }, .{ .x = 80, .y = 0 },
        .{ .x = 80, .y = 0 }, .{ .x = 120, .y = 0 },
    };
    var net_seg = [_]u32{ 0, 1, 3 };
    var seg_pt = [_]u32{ 0, 2, 4, 6 };
    var pin_xy = [_]Pt{};
    const phys: Physical = .{
        .pos = &.{},
        .pin_xy = &pin_xy,
        .net_seg = &net_seg,
        .seg_pt = &seg_pt,
        .wire_pts = &wire_pts,
        .junctions = &.{},
        .labels = &.{},
    };
    const counts = metric.countCrossingsAndOverlaps(phys);
    try expectEqual(@as(u32, 1), counts.overlaps);
    // Touching at exactly one point (80,0) is not an overlap.
    try expectEqual(@as(u32, 0), counts.crossings);
}

test "orthogonal segment predicates separate endpoints from interiors" {
    try expect(metric.onSegment(pt(0, 0), pt(0, 0), pt(40, 0)));
    try expect(!metric.onSegmentInterior(pt(0, 0), pt(0, 0), pt(40, 0)));
    try expect(metric.onSegmentInterior(pt(20, 0), pt(0, 0), pt(40, 0)));
    try expect(!metric.onSegment(pt(20, 1), pt(0, 0), pt(40, 0)));
    try expect(metric.onSegmentInterior(pt(0, 20), pt(0, 0), pt(0, 40)));
}

// ---------------------------------------------------------------------------
// The selection key
// ---------------------------------------------------------------------------

const zero: metric.Key = .{
    .labels = 0,
    .pin_hits = 0,
    .geom_shorts = 0,
    .body_hits = 0,
    .overlaps = 0,
    .crossings = 0,
    .staples = 0,
    .total_span = 0,
    .forward_margin = 0,
    .margin_tracks = 0,
    .netid_seq = 0,
};

test "field order is priority order: crossings outrank staples and span" {
    var fewer_crossings = zero;
    fewer_crossings.staples = 99;
    fewer_crossings.total_span = 9999;
    fewer_crossings.margin_tracks = 7;

    var fewer_staples = zero;
    fewer_staples.crossings = 1;

    // A crossing is a measured aesthetic fault; staples and span are proxies for
    // complexity. No weight may trade one for the other, so the key is compared
    // field by field and never summed.
    try expect(metric.Key.lessThan({}, fewer_crossings, fewer_staples));
    try expect(!metric.Key.lessThan({}, fewer_staples, fewer_crossings));
}

test "a label outranks every other fault in the key" {
    var one_label = zero;
    one_label.labels = 1;

    var everything_else = zero;
    everything_else.pin_hits = 5;
    everything_else.geom_shorts = 5;
    everything_else.body_hits = 5;
    everything_else.overlaps = 5;
    everything_else.crossings = 5;
    everything_else.staples = 5;

    try expect(metric.Key.lessThan({}, everything_else, one_label));
}

test "the key ranks its faults in the documented order" {
    // Walk the fields in declaration order: bumping field k must lose to bumping
    // field k+1, for every adjacent pair. That is the whole priority list, asserted
    // rather than described.
    const fields = @typeInfo(metric.Key).@"struct".fields;
    inline for (fields[0 .. fields.len - 1], 0..) |fa, i| {
        const fb = fields[i + 1];
        var a = zero;
        var b = zero;
        @field(a, fa.name) = 1;
        @field(b, fb.name) = 1;
        try expect(metric.Key.lessThan({}, b, a));
        try expect(!metric.Key.lessThan({}, a, b));
    }
}

test "Key.lessThan is a strict total order" {
    var keys: [6]metric.Key = .{ zero, zero, zero, zero, zero, zero };
    keys[1].labels = 1;
    keys[2].crossings = 3;
    keys[3].crossings = 3;
    keys[3].staples = 1;
    keys[4].netid_seq = 99;
    keys[5] = keys[2];

    for (keys) |a| {
        // Irreflexive.
        try expect(!metric.Key.lessThan({}, a, a));
        try expectEqual(std.math.Order.eq, metric.Key.order(a, a));
        for (keys) |b| {
            // Antisymmetric and total: exactly one of <, >, == holds.
            const lt = metric.Key.lessThan({}, a, b);
            const gt = metric.Key.lessThan({}, b, a);
            try expect(!(lt and gt));
            const eql = std.meta.eql(a, b);
            try expect(lt or gt or eql);
            for (keys) |c| {
                // Transitive.
                if (lt and metric.Key.lessThan({}, b, c)) {
                    try expect(metric.Key.lessThan({}, a, c));
                }
            }
        }
    }
    // Every real key beats the sentinel the candidate loop starts from.
    try expect(metric.Key.lessThan({}, zero, metric.Key.worst));
}

test "the netid tie-break depends on the set of nets and not on routing order" {
    const ascending = [_]NetIdx{ net1, net2, net3 };
    const same = [_]NetIdx{ net1, net2, net3 };
    const different = [_]NetIdx{ net1, net2, net4 };
    try expectEqual(metric.netIdSeq(&ascending), metric.netIdSeq(&same));
    try expect(metric.netIdSeq(&ascending) != metric.netIdSeq(&different));
    // An empty candidate (nothing routed at all) is still a well-defined value, and
    // is not confusable with a real one.
    try expect(metric.netIdSeq(&.{}) != metric.netIdSeq(&ascending));
}
