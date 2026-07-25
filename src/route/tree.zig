//! Multi-terminal tree growth: the only routing primitive in the program, and the
//! ordering that decides which net gets to be selfish.
//!
//! ## What moves through here
//!
//! In: a `Lattice`, the `Scratch` buffers, and one `Job` per net (its class, its
//! terminal points, its column span, its label anchors). Out: polylines accumulated
//! into a `Wires` builder living in the `search` arena, and — on the winning
//! candidate order only — packed into the nested CSR of `ir.Physical` in the `out`
//! arena. Along the way each drawn polyline is written back into the lattice through
//! `Lattice.occupy`, so every later net sees it.
//!
//! ## Trunks and buses are not code
//!
//! A net with *k* terminals is grown as a tree: seed at one terminal, then
//! repeatedly run `dijkstra.run` with **every node already in the tree** as a
//! zero-cost source, stop at the nearest unconnected terminal, and fold the whole
//! found path into the tree. Because the entire tree is free to start from, a later
//! terminal joins wherever it is cheapest rather than where the seed happens to be.
//!
//! That single property is what makes trunks, buses and T-junctions **emerge**. A
//! rail's long horizontal run along its bus row with short vertical drops off it is
//! not a "bus" routine; it is what this search returns when the bus row costs
//! `W.bus` and every other row costs `W.off`. There is deliberately no bus code
//! path, no trunk code path and no T-junction code path to keep in agreement with
//! the cost table (ALGORITHM.md, "Multi-terminal nets, trunks and buses").
//!
//! ## Routing order: least freedom first
//!
//! Nets are drawn sequentially and each sees everything already drawn, so order is a
//! design decision. Rails go first: they own their bus rows, nothing competes for
//! them, and they establish the frame. Signals then go in order of **increasing**
//! column span.
//!
//! That inverts the usual global-routing instinct of "longest net first". Freedom
//! runs the other way here — a spanning net can choose among a whole band of margin
//! rows, while a two-pin net inside one column has essentially one acceptable path,
//! the straight run between its pins. Route the free nets first and the constrained
//! ones get boxed in; a local net that loses its straight run has to loop around the
//! outside of its own column, which is precisely the wire that makes a schematic
//! read as machine-generated.
//!
//! The trade was measured rather than assumed. Narrowest-first costs one extra
//! crossing in `folded_cascode` (already the worst-placed fixture) and buys two
//! fewer corners, ~2% less area, less margin traffic, and one fewer circuit with
//! design-rule issues — including turning an inverter's input net back into the
//! plain vertical it obviously should be. Both orders reach the exhaustive crossing
//! floor *for their own ordering*, so neither is a search failure; this is a design
//! preference, and this is which way it was chosen.
//!
//! ## Why a builder instead of per-net slices
//!
//! Nets are routed in span order but `Physical.net_seg` is CSR by `NetIdx`, so
//! something has to reorder. `Wires` appends in routing order into three flat arrays
//! and `pack` performs one counting sort into the CSR — linear, stable, and
//! deterministic. Returning a `[][]Pt` per net instead would allocate a header per
//! net, scatter the points, and still need the same reordering.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const irm = @import("../ir.zig");
const lat_mod = @import("lattice.zig");
const dijkstra = @import("dijkstra.zig");
const root = @import("../root.zig");

const NetIdx = ids.NetIdx;
const Pt = ids.Pt;
const Lattice = lat_mod.Lattice;
const Kind = lat_mod.Kind;
const Scratch = root.Scratch;

/// One net to route.
///
/// All slices are borrowed for the lifetime of the routing pass and are not owned by
/// the job. `terminals` and `label_at` normally come out of the `search` arena
/// alongside the placement they were derived from.
pub const Job = struct {
    net: NetIdx,
    /// Net class. Rails are `.power` / `.ground`; everything else is `.signal`.
    kind: Kind,
    /// Every pin point on the net, in ascending pin order. Duplicates are allowed
    /// and are collapsed by node, since two coincident pins are one terminal to the
    /// search.
    terminals: []const Pt,
    /// Number of inter-column gaps the net spans: `last_column - first_column`. Zero
    /// for a net inside a single column. This is the sort key, and it is an input to
    /// *ordering* only — never to control flow.
    span: u32,
    /// Where to put name labels if the fallback fires: one point per distinct
    /// non-rail pin. The fallback must cover the **whole** net, because a
    /// geometric-connectivity host connects by name only where a label actually
    /// touches, so an unlabelled pin would dangle.
    label_at: []const Pt,
};

/// Sort jobs into routing order, in place.
///
/// Key: rails before signals, then span ascending, then `NetIdx` ascending. The
/// final term is what makes the order total, and therefore what makes two runs over
/// the same netlist draw the same picture.
///
/// Uses `std.mem.sort` (stable) rather than `std.sort.pdq`, though the total key
/// makes stability moot; the cost is irrelevant at schematic scale and the guarantee
/// is worth having in writing.
///
/// Mutates `jobs`. Allocation-free.
pub fn sortJobs(jobs: []Job) void {
    std.mem.sort(Job, jobs, {}, jobLess);
}

/// Rails before signals, then span ascending, then `NetIdx` ascending. The last term
/// is what makes the order total, and therefore what makes two runs draw the same
/// picture.
fn jobLess(_: void, a: Job, b: Job) bool {
    const ar = @intFromBool(a.kind == .signal);
    const br = @intFromBool(b.kind == .signal);
    if (ar != br) return ar < br;
    if (a.span != b.span) return a.span < b.span;
    return @intFromEnum(a.net) < @intFromEnum(b.net);
}

/// Route every net in `jobs`, in the order they are given.
///
/// Callers pass `jobs` already through `sortJobs`; this function does not reorder,
/// because the order is a documented property of the output and hiding a sort inside
/// the loop would make it invisible. Asserts the order is non-decreasing under the
/// sort key in safe builds.
///
/// For each job: grow the tree, or — when `growTree` reports exhaustion — emit the
/// job's labels instead. Both outcomes land in `wires`.
///
/// `arena` is the `search` arena and backs both `wires` and the per-net working
/// sets. Mutates `lat` (occupancy), `sc` (search state) and `wires`.
///
/// Errors: `OutOfMemory` only. An unroutable net is *not* an error — it is a label,
/// which the selection key then minimises ahead of everything else.
///
/// Complexity: O(nets × terminals × E log V). The lattice is not rebuilt between
/// nets; only its occupancy columns change.
pub fn routeAll(
    arena: Allocator,
    lat: *Lattice,
    sc: *Scratch,
    jobs: []const Job,
    wires: *Wires,
) Allocator.Error!void {
    if (std.debug.runtime_safety) {
        var i: usize = 1;
        while (i < jobs.len) : (i += 1) std.debug.assert(!jobLess({}, jobs[i], jobs[i - 1]));
    }
    for (jobs) |job| {
        if (!try growTree(arena, lat, sc, job, wires)) try labelNet(arena, job, wires);
    }
}

/// Grow one net's tree. Returns false when the search proved no tree exists.
///
/// The algorithm, in full:
///
/// 1. Resolve every terminal point to a lattice node, dropping duplicates. A point
///    that is not on both axes cannot be reached and makes the net unroutable —
///    that is a placement bug, and returning false surfaces it as a label rather
///    than as a wire to the wrong place.
/// 2. Fewer than two distinct terminal nodes: nothing to draw. Returns true having
///    emitted nothing, which is the correct answer for a one-pin net.
/// 3. Seed the tree with terminal 0. The choice is arbitrary and does not bias the
///    result, because every subsequent expansion starts from the whole tree.
/// 4. While unconnected terminals remain: run `dijkstra.run` from all tree nodes to
///    all remaining targets. On null, return false. Otherwise reconstruct the path,
///    add **every node on it** to the tree (this is what lets later terminals T into
///    the middle of an existing run), drop any target the path swallowed, compress
///    the path to a polyline, emit it, and `occupy` it.
///
/// Post-condition on success: every terminal node is in the tree, and the emitted
/// polylines are connected as a tree — each one starts on a node the previous
/// polylines already covered.
///
/// `arena` backs the tree membership set and the path buffer, both sized to the
/// lattice and reused across the expansions of this net. Mutates `lat`, `sc` and
/// `wires`. Errors: `OutOfMemory`.
pub fn growTree(
    arena: Allocator,
    lat: *Lattice,
    sc: *Scratch,
    job: Job,
    wires: *Wires,
) Allocator.Error!bool {
    const nodes = lat.nodeCount();
    if (nodes == 0) return false;

    // 1. terminals -> nodes, duplicates collapsed. A point off the axes cannot be
    //    reached, and guessing a nearby node would connect the wrong things.
    var terms: std.ArrayList(u32) = .empty;
    defer terms.deinit(arena);
    for (job.terminals) |t| {
        const n = lat.nodeAt(t) orelse return false;
        if (std.mem.indexOfScalar(u32, terms.items, n) == null) try terms.append(arena, n);
    }
    // 2. one terminal (or none) is nothing to draw, and that is the right answer.
    if (terms.items.len < 2) return true;

    const in_tree = try arena.alloc(bool, nodes);
    defer arena.free(in_tree);
    @memset(in_tree, false);

    // 3. seed at terminal 0; every expansion starts from the whole tree, so the
    //    choice does not bias the result.
    var tree_nodes: std.ArrayList(u32) = .empty;
    defer tree_nodes.deinit(arena);
    try tree_nodes.append(arena, terms.items[0]);
    in_tree[terms.items[0]] = true;

    var left: std.ArrayList(u32) = .empty;
    defer left.deinit(arena);
    try left.appendSlice(arena, terms.items[1..]);
    std.mem.sort(u32, left.items, {}, std.sort.asc(u32));

    const path_buf = try arena.alloc(u32, nodes);
    defer arena.free(path_buf);
    const poly_buf = try arena.alloc(Pt, nodes);
    defer arena.free(poly_buf);

    while (left.items.len > 0) {
        std.mem.sort(u32, tree_nodes.items, {}, std.sort.asc(u32));
        // 4. multi-source from every tree node: this is the whole of trunks, buses
        //    and T-junctions, with no bus code path.
        const slot = dijkstra.run(lat, sc, .{
            .net = job.net,
            .kind = job.kind,
            .sources = tree_nodes.items,
            .targets = left.items,
        }) orelse return false;

        const path = dijkstra.reconstruct(sc, slot, path_buf);
        for (path) |n| {
            if (in_tree[n]) continue;
            in_tree[n] = true;
            try tree_nodes.append(arena, n);
        }
        // Any target the path swallowed is connected now.
        var w: usize = 0;
        for (left.items) |n| {
            if (in_tree[n]) continue;
            left.items[w] = n;
            w += 1;
        }
        left.shrinkRetainingCapacity(w);

        for (path, 0..) |n, i| poly_buf[i] = lat.pt(n);
        const poly = compress(poly_buf[0..path.len]);
        if (poly.len >= 2) {
            try wires.emit(arena, job.net, poly);
            lat.occupy(job.net, poly);
        }
    }
    return true;
}

/// Drop collinear interior points, in place, so a run of lattice steps becomes one
/// straight segment.
///
/// Returns the prefix of `pts` that survives. Also removes consecutive duplicates,
/// which a path through both direction-slots of one node produces. The output is the
/// polyline that gets drawn and measured: leaving the intermediate vertices in would
/// inflate the point count, and — worse — make every intermediate lattice node look
/// like a wire *endpoint* to `metric.junctions`, which counts endpoints as one arm
/// and interior pass-throughs as two. Compression is therefore part of the
/// junction-dot contract, not a size optimisation.
///
/// Pure apart from the in-place rewrite; allocation-free. Linear.
pub fn compress(pts: []Pt) []Pt {
    var w: usize = 0;
    for (pts) |p| {
        if (w > 0 and pts[w - 1].eql(p)) continue;
        if (w >= 2) {
            const a = pts[w - 2];
            const b = pts[w - 1];
            if ((a.x == b.x and b.x == p.x) or (a.y == b.y and b.y == p.y)) w -= 1;
        }
        pts[w] = p;
        w += 1;
    }
    return pts[0..w];
}

/// Emit one net's labels, one per distinct point in `job.label_at`.
///
/// Points are sorted by (x, y) and deduplicated first, so the label list is
/// reproducible regardless of pin order. Appends to `wires.labels`.
///
/// Called only after `growTree` returned false. Errors: `OutOfMemory`.
pub fn labelNet(arena: Allocator, job: Job, wires: *Wires) Allocator.Error!void {
    if (job.label_at.len == 0) return;
    const at = try arena.dupe(Pt, job.label_at);
    defer arena.free(at);
    std.mem.sort(Pt, at, {}, ptLessXY);
    var prev: ?Pt = null;
    for (at) |p| {
        if (prev) |q| if (q.eql(p)) continue;
        try wires.label(arena, job.net, p);
        prev = p;
    }
}

/// Point order by (x, y), the canonical form for label and junction lists.
fn ptLessXY(_: void, a: Pt, b: Pt) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

/// Accumulator for routed geometry, in routing order.
///
/// Lives in the `search` arena during a candidate evaluation and is thrown away with
/// it; only the winner's is `pack`ed into the `out` arena. Because of that split it
/// has a `deinit` for the tests and standalone callers who back it with a
/// general-purpose allocator, and the pipeline simply never calls it.
pub const Wires = struct {
    /// Owning net of each emitted segment, in emission order.
    seg_net: std.ArrayList(NetIdx),
    /// CSR offsets into `pts`, one per segment plus a terminating entry. Length is
    /// `seg_net.items.len + 1` after every complete `emit`.
    seg_off: std.ArrayList(u32),
    /// Every polyline vertex, packed back to back in emission order.
    pts: std.ArrayList(Pt),
    /// Nets that proved unroutable, as name tags.
    labels: std.ArrayList(irm.Label),

    /// A builder with no segments. `seg_off` is empty here and gains its leading
    /// zero on first use, so `.empty` needs no allocation.
    pub const empty: Wires = .{
        .seg_net = .empty,
        .seg_off = .empty,
        .pts = .empty,
        .labels = .empty,
    };

    /// Release all four lists. Safe on `.empty`, and a no-op the pipeline never
    /// performs — see the type's note on lifetime.
    pub fn deinit(self: *Wires, gpa: Allocator) void {
        self.seg_net.deinit(gpa);
        self.seg_off.deinit(gpa);
        self.pts.deinit(gpa);
        self.labels.deinit(gpa);
        self.* = .empty;
    }

    /// Append one polyline for `net`.
    ///
    /// `poly` must have at least two points and must be Manhattan: consecutive
    /// points differ on exactly one axis. Both are asserted — a diagonal here means
    /// the path reconstruction or the compression is wrong, and drawing it would
    /// produce a schematic no netlist extractor can read back.
    ///
    /// Copies the points; `poly` is borrowed and may be reused by the caller
    /// immediately. Errors: `OutOfMemory`.
    pub fn emit(self: *Wires, gpa: Allocator, net: NetIdx, poly: []const Pt) Allocator.Error!void {
        std.debug.assert(poly.len >= 2);
        for (poly[1..], poly[0 .. poly.len - 1]) |b, a| {
            std.debug.assert((a.x == b.x) != (a.y == b.y));
        }
        // Reserve everything first: a half-appended segment is a corrupt CSR.
        try self.seg_net.ensureUnusedCapacity(gpa, 1);
        try self.seg_off.ensureUnusedCapacity(gpa, 2);
        try self.pts.ensureUnusedCapacity(gpa, poly.len);

        if (self.seg_off.items.len == 0) self.seg_off.appendAssumeCapacity(0);
        self.pts.appendSliceAssumeCapacity(poly);
        self.seg_net.appendAssumeCapacity(net);
        self.seg_off.appendAssumeCapacity(@intCast(self.pts.items.len));
    }

    /// Append one label.
    pub fn label(self: *Wires, gpa: Allocator, net: NetIdx, at: Pt) Allocator.Error!void {
        try self.labels.append(gpa, .{ .net = net, .at = at });
    }

    /// Number of segments emitted so far.
    pub fn segmentCount(self: Wires) usize {
        return self.seg_net.items.len;
    }

    /// The points of segment `s`, borrowed from `pts` and invalidated by the next
    /// `emit`.
    pub fn segment(self: Wires, s: usize) []const Pt {
        std.debug.assert(s < self.segmentCount());
        return self.pts.items[self.seg_off.items[s]..self.seg_off.items[s + 1]];
    }

    /// Pack into the nested CSR of `phys`, in `NetIdx` order.
    ///
    /// Fills `phys.net_seg` (length `net_count + 1`), `phys.seg_pt` (length
    /// `segment_count + 1`), `phys.wire_pts` and `phys.labels`, allocating all four
    /// from `out`. Leaves `pos`, `pin_xy` and `junctions` untouched — those come
    /// from placement and from `metric.junctions`, and a partially-filled `Physical`
    /// is the deliberate handoff shape rather than an oversight.
    ///
    /// Reordering is a **counting sort** over `seg_net`: count segments per net,
    /// prefix-sum into `net_seg`, then place. Within a net, segments keep their
    /// emission order, which is tree-growth order — the order a reader would trace
    /// the net in. No hash map is consulted, here or anywhere on this path.
    ///
    /// Labels are sorted by `(net, x, y)` for the same reason.
    ///
    /// Caller owns the arrays through `out`. Errors: `OutOfMemory`. Linear in
    /// segments plus points plus `net_count`.
    pub fn pack(
        self: Wires,
        out: Allocator,
        net_count: usize,
        phys: *irm.Physical,
    ) Allocator.Error!void {
        const n_seg = self.seg_net.items.len;

        const net_seg = try out.alloc(u32, net_count + 1);
        errdefer out.free(net_seg);
        @memset(net_seg, 0);
        const seg_pt = try out.alloc(u32, n_seg + 1);
        errdefer out.free(seg_pt);
        const wire_pts = try out.alloc(Pt, self.pts.items.len);
        errdefer out.free(wire_pts);

        // Counting sort: count, prefix-sum, place. No map is consulted.
        for (self.seg_net.items) |n| net_seg[n.i() + 1] += 1;
        for (1..net_count + 1) |i| net_seg[i] += net_seg[i - 1];

        const cursor = try out.alloc(u32, net_count);
        defer out.free(cursor);
        @memcpy(cursor, net_seg[0..net_count]);
        // Destination slot -> emission slot. Within a net, emission (tree-growth)
        // order is preserved, which is the order a reader traces the net in.
        const src = try out.alloc(u32, n_seg);
        defer out.free(src);
        for (self.seg_net.items, 0..) |n, s| {
            const d = cursor[n.i()];
            cursor[n.i()] += 1;
            src[d] = @intCast(s);
        }

        seg_pt[0] = 0;
        var w: u32 = 0;
        for (src, 0..) |s, d| {
            const poly = self.segment(s);
            @memcpy(wire_pts[w..][0..poly.len], poly);
            w += @intCast(poly.len);
            seg_pt[d + 1] = w;
        }

        const labels = try out.alloc(irm.Label, self.labels.items.len);
        errdefer out.free(labels);
        @memcpy(labels, self.labels.items);
        std.mem.sort(irm.Label, labels, {}, labelLess);

        phys.net_seg = net_seg;
        phys.seg_pt = seg_pt;
        phys.wire_pts = wire_pts;
        phys.labels = labels;
    }
};

/// Label order: net, then (x, y). Deterministic regardless of routing order.
fn labelLess(_: void, a: irm.Label, b: irm.Label) bool {
    if (a.net != b.net) return @intFromEnum(a.net) < @intFromEnum(b.net);
    return ptLessXY({}, a.at, b.at);
}
