//! The Hanan grid every net is routed on, and the structural blocking that makes
//! "never short, never cut a body, never touch a foreign pin" unreachable in the
//! search rather than checked after it.
//!
//! ## What moves through here
//!
//! In: a finished placement — pin points, column axes, lane axes, device body
//! rectangles, the two bus rows and the margin bands. Out: two sorted coordinate
//! axes plus seven flat columns describing, per node and per edge, what is in the
//! way. `dijkstra.zig` reads those columns and nothing else; `tree.zig` writes back
//! through `occupy` as each net is drawn, so net *k + 1* sees every wire net *k*
//! left behind.
//!
//! Axes are the Hanan grid over every interesting coordinate: every pin x and y,
//! every column axis, every reserved lane, every device-body edge (a wire may run
//! flush along a body, so its edges are legal tracks), the two bus rows, and a band
//! of margin rows above the power bus and below the ground bus. Node index is
//! `iy * nx + ix`; a lattice edge only ever joins adjacent coordinates on one axis.
//!
//! ## Why every pin coordinate has to be on the axes
//!
//! This is the load-bearing property, not a convenience (ALGORITHM.md, "The
//! lattice"). Because a pin's x and y are both axis values, a foreign pin is always
//! a *node*, and because edges join only adjacent coordinates, no wire can pass
//! through a pin without visiting its node. "Never touch a foreign pin" therefore
//! reduces to marking one node. The same argument makes "never T into a foreign
//! net" a node mark, since two wires can only meet at a node.
//!
//! The consequence is worth stating plainly: **collision is structural**. There is
//! no post-hoc conflict sweep, no unwire-then-rewire, and no repair pass, because a
//! route that would short, cut a body or touch a foreign pin is not reachable by the
//! search that produced it. The `pin_hits` / `geom_shorts` / `body_hits` terms of
//! the selection key are *assertions* that this held, not a filter that makes it
//! hold.
//!
//! ## One u32 per edge, not a list
//!
//! The Rust original stores `Vec<Vec<u16>>` — a per-edge list of every body
//! overlapping it. One `u32` replaces it, because an edge blocked by two bodies is
//! still blocked, and the only question ever asked of a blocker is "is it the device
//! whose buried pin licenses this cut?". A list costs a 16-byte header and a
//! separate allocation per blocked edge; the column costs 4 bytes per edge, total,
//! contiguous, and is built and thrown away with one arena reset.
//!
//! **Verify item (ARCHITECTURE.md §6).** The approximation loses exactly one case:
//! an edge blocked by bodies A *and* B where the route owns a buried pin in A. With
//! one slot the answer depends on which body was stored last, so such an edge may be
//! wrongly traversable (if A was stored) or wrongly closed (if B was). Two bodies
//! can only share an edge where two symbols overlap, which placement does not
//! produce — but that is a claim about the fixture set, so it is checked there. If a
//! fixture ever needs "blocked by A or B, exempt for A", widen the column to a `u64`
//! pair *before* considering a list again.
//!
//! `node_net` needs no such caveat and is exact. A node owned by net A is closed to
//! every other net, so no second net can ever place a vertex or a pin obstacle
//! there; one slot can never lose information. That is also why pin obstacles and
//! wire vertices share the column — both mean "this node belongs to that net", and
//! blocking is one integer compare either way.
//!
//! ## Lifetime: the search arena, freed by reset
//!
//! A `Lattice` is built from `Pipeline.search` and has **no `deinit`**. It dies when
//! the candidate-order loop calls `search.reset(.retain_capacity)`, along with the
//! column assignment, the offsets and the route polylines that were built beside it.
//! Sixteen candidate orders therefore cost one arena's worth of pages instead of
//! sixteen rounds of malloc/free over eleven arrays. Nothing in a `Lattice` may
//! outlive that reset: anything that must survive is copied into `out` by
//! `tree.Wires.pack`.
//!
//! ## The closed/open rectangle trap
//!
//! `ids.Rect.intersects` is **closed** — it reports two rectangles touching along an
//! edge as intersecting, which is what label-collision wants. Body blocking needs
//! the **open** predicate, and `overlapsOpen` below is it. Using the closed one here
//! would block every track flush with a body edge, which is precisely the track the
//! router needs when it hugs a device instead of stepping out to a channel; a
//! diode-connected gate-to-drain tie would then have nowhere to go. The two
//! predicates are not interchangeable and the difference is one `<` per axis.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");

const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const Pt = ids.Pt;
const Rect = ids.Rect;

/// What a lattice row is for. Rail nets get their own bus row nearly free; every
/// other net pays to stand on it, and rails pay to stand anywhere else.
///
/// One byte, one entry per y coordinate — the `row` column is indexed by `iy`, not
/// by node, because row purpose is a property of the whole row.
pub const Row = enum(u8) {
    /// Inside the device field: the ordinary case, priced at `W.base`.
    field,
    /// The VDD bus, above the field.
    power_bus,
    /// The GND bus, below the field.
    gnd_bus,
    /// Backward-feedback band above the power bus, or its mirror below ground.
    margin,
};

/// Which class of net is being routed. Selects the row costs and nothing else —
/// there is no per-kind control flow anywhere in the router.
pub const Kind = enum(u8) {
    power,
    ground,
    signal,
};

/// The axis a lattice move runs along.
///
/// Carried in the search state alongside the node (`dist` is indexed
/// `node * 2 + dir`) because a bend is a cost, and a cost that depends on how you
/// arrived means the arrival direction is part of the search state. A plain
/// node-indexed Dijkstra cannot price bends at all.
pub const Dir = enum(u1) {
    h = 0,
    v = 1,

    pub fn i(d: Dir) u32 {
        return @intFromEnum(d);
    }

    /// The other axis. A step whose direction differs from the arrival direction
    /// pays `W.bend`.
    pub fn other(d: Dir) Dir {
        return if (d == .h) .v else .h;
    }
};

/// A device body a wire may not cut, in absolute layout coordinates.
///
/// `rect` is the placed, oriented bounding box — `geom.placedRect`. Rails are not
/// bodies: they render as bus symbols rather than placed geometry, so they neither
/// block edges nor obstruct nodes.
pub const Body = struct {
    dev: DeviceIdx,
    rect: Rect,
};

/// One placed pin, as the lattice sees it.
///
/// Three separate roles, which is why the flags are explicit rather than derived:
/// the point seeds the axes (always), the node becomes a foreign-net obstacle (only
/// when `obstacle`), and the pin may license cutting its own device's body (only
/// when it is strictly inside `dev`'s rectangle, which `build` determines).
pub const Site = struct {
    pin: PinIdx,
    /// The device owning this terminal. Used only for the own-body exemption.
    dev: DeviceIdx,
    /// The pin's net. `.none` (floating) sites still seed the axes but never
    /// obstruct, since no net can claim a node it has no reason to reach.
    net: NetIdx,
    /// Absolute placed location, on the host grid.
    at: Pt,
    /// False for rail-device pins. A rail draws as a bus symbol, not a placed pin,
    /// so a foreign wire crossing its point is not a short and must not be blocked.
    obstacle: bool = true,
};

/// Everything `build` needs, as plain data.
///
/// Deliberately not a reference to placement state: the lattice is a pure function
/// of these coordinates, so a test can construct one directly and the router can be
/// developed before the placer exists. All slices are **borrowed for the duration of
/// the call** — `build` copies what it keeps into the arena.
pub const Spec = struct {
    /// Column axes, one x per column. Unsorted and possibly duplicated; `build`
    /// sorts and dedups everything together.
    col_x: []const i32 = &.{},
    /// Reserved lane axes inside the inter-column gaps, flattened. Placement
    /// guarantees enough lanes exist; which wire uses which is the router's choice,
    /// so they arrive here as an undifferentiated list.
    lane_x: []const i32 = &.{},
    /// Device bodies. Order is irrelevant; blocking is a union.
    bodies: []const Body = &.{},
    /// Every pin of every device, rails included (they seed axes but do not
    /// obstruct — see `Site.obstacle`).
    sites: []const Site = &.{},
    /// y of the VDD bus row, above the field.
    power_bus: i32,
    /// y of the GND bus row, below the field.
    gnd_bus: i32,
    /// y of the first backward-feedback margin row, above `power_bus`.
    top_margin: i32,
    /// y of the first margin row below `gnd_bus`. The bottom band exists so a route
    /// that genuinely has nowhere else to go still has somewhere to go.
    bot_margin: i32,
    /// Host grid quantum. Every lattice coordinate lands on a multiple of it,
    /// because every wire vertex will. 1 means no quantization.
    grid: i32 = 1,
    /// Vertical pitch between margin rows.
    track_h: i32 = 10,
    /// How many rows each margin band gets.
    margin_rows: u32 = 5,
};

/// The routing lattice: sorted axes, per-row purpose, per-edge blocking and
/// occupancy, per-node ownership.
///
/// All arrays are allocated from the `search` arena and are **not individually
/// owned**: there is no `deinit`, and freeing one would be a bug. See the module
/// header on lifetime.
///
/// Field arrays are public because measurement, tests and the tree grower all index
/// them directly; the accessors below exist to keep the index arithmetic in one
/// place, not to hide the data.
pub const Lattice = struct {
    /// Sorted, deduplicated x axis. Length `nx`.
    xs: []i32,
    /// Sorted, deduplicated y axis. Length `ny`.
    ys: []i32,
    /// Purpose of each row, parallel to `ys`. Length `ny`.
    row: []Row,
    nx: u32,
    ny: u32,

    /// Body blocking horizontal edge `(ix, iy) -> (ix + 1, iy)`, or `.none`.
    /// Length `(nx - 1) * ny`, indexed `iy * (nx - 1) + ix`.
    h_blk: []DeviceIdx,
    /// Body blocking vertical edge `(ix, iy) -> (ix, iy + 1)`, or `.none`.
    /// Length `nx * (ny - 1)`, indexed `iy * nx + ix`.
    v_blk: []DeviceIdx,
    /// Net already drawn along each horizontal edge, or `.none`. A second net on the
    /// same edge would be a collinear overlap — a short — so this is a hard block
    /// rather than a price.
    h_occ: []NetIdx,
    /// Net already drawn along each vertical edge, or `.none`.
    v_occ: []NetIdx,

    /// The pin sitting on each node, or `.none`. Length `nx * ny`.
    ///
    /// When several pins are coincident the **lowest `PinIdx`** is kept. That is a
    /// second instance of the one-slot approximation described in the module header:
    /// coincident pins of *different* nets exist in the fixture set
    /// (`cross_coupled_pair`), and where they do, this column names only one of
    /// them. Blocking is unaffected, because `node_net` is claimed by whichever pin
    /// obstructs first and the node is closed to everyone else either way; only a
    /// diagnostic that asks "which pin is here" sees the difference.
    node_pin: []PinIdx,
    /// The net owning each node, or `.none`.
    ///
    /// Set at build time by an obstructing pin, and at draw time by `occupy` when a
    /// wire vertex lands here. Both mean the same thing to the search — the node is
    /// closed to every other net — so they share one column and one compare.
    node_net: []NetIdx,
    /// The device whose **open interior** swallows the pin on this node, or `.none`.
    ///
    /// The only licence to cut a body, and deliberately narrow. A pin buried inside
    /// its own symbol would otherwise be unreachable, since every edge landing on it
    /// crosses the interior. A pin on the body *boundary* — every builtin MOSFET
    /// terminal — needs no licence at all: an edge reaching it from outside never
    /// enters the interior. Granting the exemption to boundary pins is exactly the
    /// bug that let a gate-to-drain tie drive a wire straight across its own
    /// transistor, because one lattice edge spanned the gate pin to the far body
    /// edge and the endpoint licensed the whole cut. See ALGORITHM.md, "The
    /// lattice": owning a pin is not a licence.
    node_bury: []DeviceIdx,

    /// Build the lattice for a finished placement.
    ///
    /// `arena` must be the `search` arena (or, in a test, any arena the caller
    /// resets): the result borrows nothing from `spec` but owns nothing either, and
    /// is released by the arena, never by a `deinit`.
    ///
    /// Axis construction, in order:
    ///
    /// 1. every `Site.at.x` and `.y` — the property the whole design rests on;
    /// 2. `col_x` and `lane_x`;
    /// 3. every body edge, **snapped away from the body**: `min` floored to the
    ///    grid, `max` ceiled. Body extents are draw-derived and are not grid
    ///    multiples, so snapping the other way would round a flush track *into* the
    ///    device it is supposed to hug;
    /// 4. the two bus rows, snapped to the nearest grid multiple;
    /// 5. `margin_rows` rows stepping up from `top_margin` by `track_h`, and
    ///    `margin_rows` stepping down from `bot_margin`.
    ///
    /// Then sort and dedup each axis. Row purpose is decided from the *snapped* bus
    /// coordinates: equal to the power bus is `.power_bus`, equal to the ground bus
    /// is `.gnd_bus`, outside the two is `.margin`, between them is `.field`.
    ///
    /// Blocking uses the **open** overlap test (`overlapsOpen`), so an edge merely
    /// flush with a body is clear and an edge through its interior is not.
    ///
    /// Post-conditions: `xs` and `ys` are strictly ascending; every `Site.at` that
    /// lay on both axes resolves through `nodeAt`; `h_occ` and `v_occ` are entirely
    /// `.none` (nothing is drawn yet).
    ///
    /// Errors: `OutOfMemory`, and nothing else — a degenerate placement (no pins, no
    /// bodies) yields a lattice with empty axes rather than an error, and every
    /// query on it fails cleanly.
    ///
    /// Complexity: O(n log n) for the axes, plus O(bodies × (nx + ny)) for blocking
    /// — each body only visits the rows and columns strictly inside it.
    pub fn build(arena: Allocator, spec: Spec) Allocator.Error!Lattice {
        const g = spec.grid;

        var xv: std.ArrayList(i32) = .empty;
        defer xv.deinit(arena);
        var yv: std.ArrayList(i32) = .empty;
        defer yv.deinit(arena);

        // 1. every pin coordinate — the property the whole design rests on.
        for (spec.sites) |s| {
            try xv.append(arena, s.at.x);
            try yv.append(arena, s.at.y);
        }
        // 2. column and lane axes.
        for (spec.col_x) |x| try xv.append(arena, x);
        for (spec.lane_x) |x| try xv.append(arena, x);
        // 3. body edges, snapped AWAY from the body.
        for (spec.bodies) |b| {
            try xv.append(arena, snapFloor(b.rect.min.x, g));
            try xv.append(arena, snapCeil(b.rect.max.x, g));
            try yv.append(arena, snapFloor(b.rect.min.y, g));
            try yv.append(arena, snapCeil(b.rect.max.y, g));
        }
        // 4. the two bus rows, to the nearest multiple.
        const pbus = snapNear(spec.power_bus, g);
        const gbus = snapNear(spec.gnd_bus, g);
        try yv.append(arena, pbus);
        try yv.append(arena, gbus);
        // 5. the two margin bands.
        var k: u32 = 0;
        while (k < spec.margin_rows) : (k += 1) {
            const step = @as(i32, @intCast(k)) * spec.track_h;
            try yv.append(arena, snapNear(spec.top_margin - step, g));
            try yv.append(arena, snapNear(spec.bot_margin + step, g));
        }

        const xs = try sortedDedup(arena, xv.items);
        const ys = try sortedDedup(arena, yv.items);
        const nx: u32 = @intCast(xs.len);
        const ny: u32 = @intCast(ys.len);

        const row = try arena.alloc(Row, ys.len);
        for (ys, row) |y, *r| {
            r.* = if (y == pbus)
                .power_bus
            else if (y == gbus)
                .gnd_bus
            else if (y < pbus or y > gbus)
                .margin
            else
                .field;
        }

        const n_h = if (nx == 0) 0 else (nx - 1) * ny;
        const n_v = if (ny == 0) 0 else nx * (ny - 1);
        const n_node = nx * ny;

        const h_blk = try arena.alloc(DeviceIdx, n_h);
        @memset(h_blk, .none);
        const v_blk = try arena.alloc(DeviceIdx, n_v);
        @memset(v_blk, .none);
        const h_occ = try arena.alloc(NetIdx, n_h);
        @memset(h_occ, .none);
        const v_occ = try arena.alloc(NetIdx, n_v);
        @memset(v_occ, .none);
        const node_pin = try arena.alloc(PinIdx, n_node);
        @memset(node_pin, .none);
        const node_net = try arena.alloc(NetIdx, n_node);
        @memset(node_net, .none);
        const node_bury = try arena.alloc(DeviceIdx, n_node);
        @memset(node_bury, .none);

        var lat: Lattice = .{
            .xs = xs,
            .ys = ys,
            .row = row,
            .nx = nx,
            .ny = ny,
            .h_blk = h_blk,
            .v_blk = v_blk,
            .h_occ = h_occ,
            .v_occ = v_occ,
            .node_pin = node_pin,
            .node_net = node_net,
            .node_bury = node_bury,
        };

        // Blocking is the OPEN overlap: an edge merely flush with a body is clear.
        // Restricting the row (or column) strictly inside the body first is what
        // makes the degenerate edge rectangle a non-issue — see `overlapsOpen`.
        for (spec.bodies) |b| {
            var iy: u32 = 0;
            while (iy < ny) : (iy += 1) {
                const y = ys[iy];
                if (y <= b.rect.min.y or y >= b.rect.max.y) continue;
                var ix: u32 = 0;
                while (ix + 1 < nx) : (ix += 1) {
                    if (xs[ix] < b.rect.max.x and b.rect.min.x < xs[ix + 1]) {
                        h_blk[iy * (nx - 1) + ix] = b.dev;
                    }
                }
            }
            var ix: u32 = 0;
            while (ix < nx) : (ix += 1) {
                const x = xs[ix];
                if (x <= b.rect.min.x or x >= b.rect.max.x) continue;
                var iy2: u32 = 0;
                while (iy2 + 1 < ny) : (iy2 += 1) {
                    if (ys[iy2] < b.rect.max.y and b.rect.min.y < ys[iy2 + 1]) {
                        v_blk[iy2 * nx + ix] = b.dev;
                    }
                }
            }
        }

        for (spec.sites) |s| {
            const n = lat.nodeAt(s.at) orelse continue;
            // Lowest PinIdx wins when pins are coincident.
            if (node_pin[n] == .none or @intFromEnum(s.pin) < @intFromEnum(node_pin[n])) {
                node_pin[n] = s.pin;
            }
            // First obstructing pin claims the node; a second one changes nothing,
            // because the node is closed to everyone but the claimant either way.
            if (s.obstacle and s.net != .none and node_net[n] == .none) node_net[n] = s.net;
            // The licence to cut a body: strictly inside its OWN device's rectangle.
            for (spec.bodies) |b| {
                if (b.dev != s.dev) continue;
                if (s.at.x > b.rect.min.x and s.at.x < b.rect.max.x and
                    s.at.y > b.rect.min.y and s.at.y < b.rect.max.y)
                {
                    node_bury[n] = s.dev;
                }
            }
        }

        return lat;
    }

    /// Total nodes, `nx * ny`. This is the number `Scratch.ensure` must be sized to.
    pub fn nodeCount(self: Lattice) u32 {
        return self.nx * self.ny;
    }

    /// Horizontal edges, `(nx - 1) * ny`. Zero when `nx` is 0 or 1.
    pub fn hEdgeCount(self: Lattice) u32 {
        return if (self.nx == 0) 0 else (self.nx - 1) * self.ny;
    }

    /// Vertical edges, `nx * (ny - 1)`. Zero when `ny` is 0 or 1.
    pub fn vEdgeCount(self: Lattice) u32 {
        return if (self.ny == 0) 0 else self.nx * (self.ny - 1);
    }

    /// Node index from axis subscripts. The one definition of `iy * nx + ix`.
    ///
    /// Asserts both subscripts are in range — an out-of-range subscript is a
    /// programming error in the caller's neighbour arithmetic, not a data condition.
    pub fn node(self: Lattice, ix: u32, iy: u32) u32 {
        std.debug.assert(ix < self.nx and iy < self.ny);
        return iy * self.nx + ix;
    }

    /// x subscript of a node.
    pub fn ixOf(self: Lattice, n: u32) u32 {
        return n % self.nx;
    }

    /// y subscript of a node.
    pub fn iyOf(self: Lattice, n: u32) u32 {
        return n / self.nx;
    }

    /// The layout coordinate of a node. Asserts `n < nodeCount()`.
    pub fn pt(self: Lattice, n: u32) Pt {
        std.debug.assert(n < self.nodeCount());
        return .{ .x = self.xs[n % self.nx], .y = self.ys[n / self.nx] };
    }

    /// The node at an exact layout coordinate, or null when the point is not on both
    /// axes.
    ///
    /// Two binary searches, allocation-free. Null is a real answer, not a failure:
    /// a terminal that does not resolve is a net the router cannot start, and
    /// `tree.zig` drops it to labels rather than guessing a nearby node. Snapping to
    /// the nearest node here would silently move a pin, which is how a drawing ends
    /// up connecting the wrong things.
    pub fn nodeAt(self: Lattice, p: Pt) ?u32 {
        const ix = std.sort.binarySearch(i32, self.xs, p.x, orderI32) orelse return null;
        const iy = std.sort.binarySearch(i32, self.ys, p.y, orderI32) orelse return null;
        return @as(u32, @intCast(iy)) * self.nx + @as(u32, @intCast(ix));
    }

    /// Index of the horizontal edge leaving `(ix, iy)` rightwards.
    ///
    /// Asserts `ix + 1 < nx`. Callers hold the invariant by bounds-checking the
    /// neighbour first.
    pub fn hEdge(self: Lattice, ix: u32, iy: u32) u32 {
        std.debug.assert(ix + 1 < self.nx and iy < self.ny);
        return iy * (self.nx - 1) + ix;
    }

    /// Index of the vertical edge leaving `(ix, iy)` downwards. Asserts
    /// `iy + 1 < ny`.
    pub fn vEdge(self: Lattice, ix: u32, iy: u32) u32 {
        std.debug.assert(ix < self.nx and iy + 1 < self.ny);
        return iy * self.nx + ix;
    }

    /// Length in layout units of the horizontal edge leaving column `ix`.
    ///
    /// Always positive: axes are strictly ascending after dedup. This is the `len`
    /// that multiplies the per-unit row cost, which is why the Hanan grid stays
    /// cheap — a long clear run is one edge, not one edge per grid unit.
    pub fn hLen(self: Lattice, ix: u32) i32 {
        return self.xs[ix + 1] - self.xs[ix];
    }

    /// Length in layout units of the vertical edge leaving row `iy`.
    pub fn vLen(self: Lattice, iy: u32) i32 {
        return self.ys[iy + 1] - self.ys[iy];
    }

    /// Is `n` closed to `net`?
    ///
    /// True when the node is owned by a different net — either a foreign pin sits
    /// here (never touch a foreign pin) or a foreign wire has a vertex here (never T
    /// into a foreign net). Both are hard blocks; neither is priced. A node owned by
    /// `net` itself is open, which is what lets a later terminal T into the tree
    /// already drawn.
    pub fn nodeBlocked(self: Lattice, n: u32, net: NetIdx) bool {
        const owner = self.node_net[n];
        return owner != .none and owner != net;
    }

    /// Would running `net` along this edge share it with a foreign net?
    ///
    /// A collinear overlap is a **short**, not a crossing: the two wires draw as one
    /// line and read as connected. Hard block. `dir` selects which occupancy column
    /// to consult and `e` is the index within it (`hEdge` / `vEdge`).
    pub fn edgeShorted(self: Lattice, dir: Dir, e: u32, net: NetIdx) bool {
        const owner = if (dir == .h) self.h_occ[e] else self.v_occ[e];
        return owner != .none and owner != net;
    }

    /// Would running `net` along this edge cut a device body it has no licence to
    /// cut?
    ///
    /// The licence is narrow and is the whole of the own-body exemption: the edge's
    /// own endpoints `a` and `b` are checked against `node_bury`, and the cut is
    /// permitted only when the blocking device is the one whose *interior* holds a
    /// pin of `net` at that endpoint. A boundary pin grants nothing — see
    /// `node_bury`.
    ///
    /// `a` and `b` must be the two endpoints of edge `e` in direction `dir`;
    /// asserted in safe builds.
    pub fn edgeCutsBody(self: Lattice, dir: Dir, e: u32, net: NetIdx, a: u32, b: u32) bool {
        const lo = @min(a, b);
        std.debug.assert(if (dir == .h) @max(a, b) == lo + 1 else @max(a, b) == lo + self.nx);
        std.debug.assert(e == if (dir == .h)
            self.iyOf(lo) * (self.nx - 1) + self.ixOf(lo)
        else
            self.iyOf(lo) * self.nx + self.ixOf(lo));

        const blocker = if (dir == .h) self.h_blk[e] else self.v_blk[e];
        if (blocker == .none) return false;
        // The only licence: an endpoint holds a pin of `net` buried in *that* body's
        // open interior. A boundary pin grants nothing — see `node_bury`.
        if (self.node_bury[a] == blocker and self.node_net[a] == net) return false;
        if (self.node_bury[b] == blocker and self.node_net[b] == net) return false;
        return true;
    }

    /// Does moving through `n` along `dir` cross a foreign wire?
    ///
    /// True when a foreign net occupies either perpendicular edge incident to the
    /// node. This is a *genuine* crossing — the two wires meet at a point and the
    /// drawing must read as "not connected" — so it is priced at `W.cross`, not
    /// forbidden. A long detour beats a crossing; a crossing beats not connecting
    /// (ALGORITHM.md, "The costs are the opinions").
    ///
    /// Note the asymmetry with `edgeShorted`: parallel sharing is a block, and
    /// perpendicular passing is a price. That single distinction is what makes
    /// crossings finite and shorts impossible.
    pub fn crosses(self: Lattice, n: u32, dir: Dir, net: NetIdx) bool {
        const ix = self.ixOf(n);
        const iy = self.iyOf(n);
        if (dir == .v) {
            // A vertical move crosses whatever runs horizontally through the node.
            if (ix > 0 and foreign(self.h_occ[iy * (self.nx - 1) + ix - 1], net)) return true;
            if (ix + 1 < self.nx and foreign(self.h_occ[iy * (self.nx - 1) + ix], net)) return true;
        } else {
            if (iy > 0 and foreign(self.v_occ[(iy - 1) * self.nx + ix], net)) return true;
            if (iy + 1 < self.ny and foreign(self.v_occ[iy * self.nx + ix], net)) return true;
        }
        return false;
    }

    /// Record a drawn polyline so every later net sees it.
    ///
    /// Marks each vertex's node in `node_net` and every edge the polyline runs along
    /// in `h_occ` / `v_occ`. Mutates the lattice; this is the only writer after
    /// `build`, and the reason nets must be routed in a defined order — net *k + 1*
    /// searches a different lattice than net *k* did.
    ///
    /// `poly` must be a Manhattan polyline whose vertices are all lattice nodes;
    /// points that do not resolve are skipped rather than asserted, because a
    /// polyline may have been re-emitted after compression. Idempotent: occupying
    /// the same polyline twice for the same net changes nothing.
    ///
    /// Complexity: O(points + total edge subscripts spanned).
    pub fn occupy(self: *Lattice, net: NetIdx, poly: []const Pt) void {
        for (poly) |p| {
            const n = self.nodeAt(p) orelse continue;
            if (self.node_net[n] == .none) self.node_net[n] = net;
        }
        if (poly.len < 2) return;
        for (poly[1..], poly[0 .. poly.len - 1]) |b, a| {
            const na = self.nodeAt(a) orelse continue;
            const nb = self.nodeAt(b) orelse continue;
            const ax = self.ixOf(na);
            const ay = self.iyOf(na);
            const bx = self.ixOf(nb);
            const by = self.iyOf(nb);
            if (ay == by) {
                var ix = @min(ax, bx);
                while (ix < @max(ax, bx)) : (ix += 1) self.h_occ[ay * (self.nx - 1) + ix] = net;
            } else if (ax == bx) {
                var iy = @min(ay, by);
                while (iy < @max(ay, by)) : (iy += 1) self.v_occ[iy * self.nx + ax] = net;
            }
        }
    }
};

/// Is this occupancy slot owned by someone other than `net`?
fn foreign(owner: NetIdx, net: NetIdx) bool {
    return owner != .none and owner != net;
}

fn orderI32(key: i32, item: i32) std.math.Order {
    return std.math.order(key, item);
}

/// Sort a scratch coordinate list ascending and copy the distinct values into the
/// arena. Sorting in place first is what keeps this one pass and no set.
fn sortedDedup(arena: Allocator, vals: []i32) Allocator.Error![]i32 {
    std.mem.sort(i32, vals, {}, std.sort.asc(i32));
    var n: usize = 0;
    for (vals) |v| {
        if (n > 0 and vals[n - 1] == v) continue;
        vals[n] = v;
        n += 1;
    }
    return arena.dupe(i32, vals[0..n]);
}

/// Open (strict) rectangle overlap: true only when the two share interior area.
///
/// Not the same predicate as `ids.Rect.intersects`, which is closed and reports
/// edge-touching as an intersection. Body blocking needs this one so that a track
/// flush along a body edge stays legal — see the module header. Kept here rather
/// than in `geom.zig` because this is the only consumer, and giving the two
/// predicates neighbouring homes is how they get confused.
///
/// Pure, allocation-free, exact in integers. Degenerate (zero-area) rectangles never
/// overlap anything under this test, which is why the edge-blocking loops restrict
/// the row or column first and then test the perpendicular span.
pub fn overlapsOpen(a: Rect, b: Rect) bool {
    return a.min.x < b.max.x and b.min.x < a.max.x and
        a.min.y < b.max.y and b.min.y < a.max.y;
}

/// Smallest grid multiple greater than or equal to `v`. Identity when `g <= 1`.
///
/// Used for the high side of a body edge, so the track lands outside the body.
pub fn snapCeil(v: i32, g: i32) i32 {
    if (g <= 1) return v;
    return @divFloor(v + g - 1, g) * g;
}

/// Largest grid multiple less than or equal to `v`. Identity when `g <= 1`.
///
/// Used for the low side of a body edge — the mirror of `snapCeil`, and together
/// they are what "snapped away from the body" means.
pub fn snapFloor(v: i32, g: i32) i32 {
    if (g <= 1) return v;
    return @divFloor(v, g) * g;
}

/// Nearest grid multiple, ties going up. Identity when `g <= 1`.
///
/// Used for bus and margin rows, which are chosen coordinates rather than derived
/// extents: there is no body to stay clear of, so the nearest multiple is right.
pub fn snapNear(v: i32, g: i32) i32 {
    if (g <= 1) return v;
    return @divFloor(v + @divTrunc(g, 2), g) * g;
}
