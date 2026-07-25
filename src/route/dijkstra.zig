//! Direction-aware, multi-source Dijkstra over the lattice — and the six constants
//! that are the router's entire opinion surface.
//!
//! ## What moves through here
//!
//! In: a `Lattice` (read-only), the reusable `Scratch` buffers, and a `Query`
//! naming the net, its class, the nodes already in its tree, and the terminals it
//! still has to reach. Out: one slot index — the `(node, direction)` pair at which
//! the search first popped an unconnected terminal — plus a predecessor chain in
//! `Scratch.prev` that `reconstruct` walks back into a node path. Nothing is
//! allocated, nothing is returned by value that outlives the next call.
//!
//! ## Why the state is `(node, direction)` and not `node`
//!
//! A bend costs about two device cells of wire, which is the single most visible
//! aesthetic preference in the output. Pricing it requires knowing how the search
//! *arrived* at a node, so the state space is doubled and `dist` is indexed
//! `node * 2 + dir`. A node-indexed Dijkstra cannot express "prefer straight" at all
//! — it would have to be bolted on afterwards as a straightening pass, which is
//! exactly the post-hoc repair this design exists to avoid. Two u32 per node buys
//! the whole "prefer straight wire" opinion as an edge weight.
//!
//! ## Generation stamping instead of clearing
//!
//! `dist[i]` is meaningful only when `dist_gen[i] == sc.gen`. Each search bumps
//! `gen`, which costs one integer increment. Clearing instead would cost a
//! `memset` of `nodes * 2 * 4` bytes — for a 200k-node lattice that is 1.6 MB of
//! pointless writes, multiplied by every net and every one of the up-to-16 candidate
//! orders. A hundred nets over sixteen orders is 2.5 GB of memset traded for 1600
//! increments. The one unavoidable clear is generation wraparound, reached once per
//! four billion searches (`Scratch.newGeneration` handles it).
//!
//! ## Allocation: none, ever
//!
//! `run` takes no `Allocator`, and that is the guarantee rather than a discipline —
//! a call site cannot hand it memory, so it cannot acquire any. Everything it needs
//! is pre-sized in `Scratch`, which lives outside the `search` arena precisely so it
//! survives the per-candidate reset. The heap is a plain reused buffer; see
//! `heapCapacityFor` for the sizing contract.

const std = @import("std");

const ids = @import("../ids.zig");
const lat_mod = @import("lattice.zig");
const root = @import("../root.zig");

const NetIdx = ids.NetIdx;
const Lattice = lat_mod.Lattice;
const Kind = lat_mod.Kind;
const Row = lat_mod.Row;
const Dir = lat_mod.Dir;
const Scratch = root.Scratch;

/// The cost weights. **Not configuration.**
///
/// ALGORITHM.md is explicit about this ("The costs are the opinions"): these are not
/// spacing knobs, they encode what a schematic *means*. A caller who retunes them
/// does not get a differently-spaced drawing, they get a differently-*reasoned* one
/// — power that no longer prefers the top of the page, or a router that would rather
/// staircase than cross. That is not a preference a config file should be able to
/// express, so the values are `comptime` rather than fields of `Config`: "these are
/// not tunable" becomes a compile-time fact instead of a comment, and the relaxation
/// loop constant-folds every one of them.
///
/// Every value is quoted as "how much wire is this worth?", so the ratios can be
/// argued about directly. A device cell is 40 layout units wide.
///
/// They were fitted over the whole fixture set by ranking aggregate quality
/// lexicographically — correctness, then crossings, then geometric corners, then
/// wire and area — and the chosen point sits in the middle of a broad plateau: bend
/// 700–1200 and cross 3000–5000 all score identically. They therefore describe the
/// shape of the objective rather than twenty-one particular circuits. Adding a
/// seventh constant to rescue one circuit would be the same special-case treadmill
/// this router replaced, one level up.
pub const W = struct {
    /// Cost per unit length on an ordinary field row or on any vertical run. The
    /// unit everything else is quoted against.
    pub const base: u32 = 10;
    /// Cost per unit length along this net's *own* bus row. Near zero, so a rail
    /// spreads sideways along its bus for free.
    pub const bus: u32 = 1;
    /// Cost per unit length on a row this net has no business standing on — a rail
    /// anywhere but its own bus. Soft infinity: high enough never to be chosen
    /// casually, finite so a net with no other option is still *drawn* rather than
    /// dropped to a label.
    pub const off: u32 = 80;
    /// Cost per unit length on a margin row: eight times a field row, so the top
    /// margin is reached for only by nets that genuinely cannot stay local. This is
    /// how "the margin is for backward feedback" is stated.
    pub const margin: u32 = 80;
    /// Cost of one direction change — about two device cells of wire. A designer
    /// will run a fair way round to keep a wire straight, and so will this.
    pub const bend: u32 = 900;
    /// Cost of crossing an already-drawn foreign wire — about seven cells. A long
    /// detour beats a crossing, but a crossing beats not connecting.
    pub const cross: u32 = 3000;
};

/// The unreachable cost. Any live `dist` entry is strictly below it.
pub const inf: u32 = std.math.maxInt(u32);

/// One expansion request.
///
/// Both node lists are borrowed and must stay valid for the call. Both must be
/// **sorted ascending and deduplicated** — membership is answered by binary search,
/// never by a hash map, because the tie-breaking behaviour of the search is part of
/// the determinism guarantee.
pub const Query = struct {
    /// The net being routed. Selects what counts as foreign everywhere.
    net: NetIdx,
    /// Net class. Selects row costs, and nothing else.
    kind: Kind,
    /// Every node already in this net's tree. All are seeded at distance zero, in
    /// **both** directions, so the first move off the tree never pays a bend and a
    /// later terminal joins wherever it is cheapest. This is the mechanism by which
    /// trunks, buses and T-junctions emerge; there is no bus code path.
    ///
    /// For the first expansion this is the single seed terminal.
    sources: []const u32,
    /// The terminals not yet connected. The search stops at the first one it pops,
    /// which is the nearest by cost. Must be **disjoint from `sources`** — the
    /// caller removes terminals as the tree swallows them, so an empty result here
    /// means the net is finished, not that a target was missed.
    targets: []const u32,
};

/// Encode a `(node, direction)` pair as a `dist` / `prev` subscript.
///
/// The one definition of the doubled indexing. Asserts nothing: callers derive
/// `node` from lattice arithmetic that already bounds-checked.
pub fn slotOf(node: u32, dir: Dir) u32 {
    return node * 2 + dir.i();
}

/// The node half of a slot.
pub fn nodeOf(slot: u32) u32 {
    return slot / 2;
}

/// The direction half of a slot.
pub fn dirOf(slot: u32) Dir {
    return @enumFromInt(@as(u1, @intCast(slot % 2)));
}

/// Cost per unit length of a horizontal run on a row of the given purpose, for a net
/// of the given class.
///
/// This table *is* "power along the top, ground along the bottom, drawn once". A
/// rail's own bus row is nearly free and every other row is dear to it, so a rail
/// spreads sideways on its bus and can only ever afford to drop vertically to a pin.
/// No rail-specific branch exists anywhere else in the router — the shape falls out
/// of these six cases.
///
/// Vertical runs do not consult this: a column of the lattice has no purpose the way
/// a row does, so every vertical unit costs `W.base` regardless of class. That
/// asymmetry is deliberate and is what makes a rail's drop off its bus affordable.
pub fn rowCost(row: Row, kind: Kind) u32 {
    return switch (kind) {
        .power => if (row == .power_bus) W.bus else W.off,
        .ground => if (row == .gnd_bus) W.bus else W.off,
        .signal => switch (row) {
            .field => W.base,
            .margin => W.margin,
            // A signal standing on a bus row is a signal in the rails' way.
            .power_bus, .gnd_bus => W.off,
        },
    };
}

/// Cost of one lattice step, or null when the step is structurally forbidden.
///
/// The single place every routing rule is applied, so it is also the place to read
/// to learn them. `from` and `to` must be 4-adjacent along `dir` (asserted); `from`
/// was arrived at along `from_dir`.
///
/// Forbidden — returns null, meaning the step does not exist in the search graph at
/// all:
///
/// - `to` is owned by another net: a foreign pin sits there, or a foreign wire has a
///   vertex there. Touching either would short.
/// - the edge already carries a foreign net: collinear overlap, which draws as one
///   wire and reads as a connection.
/// - the edge cuts a device body without the buried-pin licence.
///
/// Priced — returns a finite cost:
///
/// - `len * rowCost(row, kind)` for a horizontal step, `len * W.base` for a vertical
///   one, where `len` is the distance between adjacent axis values;
/// - plus `W.bend` when `dir != from_dir`;
/// - plus `W.cross` when the step passes perpendicular through a node a foreign wire
///   runs through. That is a genuine crossing and reads correctly as *not
///   connected*, so it is expensive and finite rather than blocked.
///
/// Pure and allocation-free. Saturating: the sum cannot overflow a `u32` for any
/// lattice a schematic produces, and `run` saturates the accumulation anyway.
pub fn stepCost(
    lat: *const Lattice,
    net: NetIdx,
    kind: Kind,
    from: u32,
    from_dir: Dir,
    to: u32,
    dir: Dir,
) ?u32 {
    const ix = lat.ixOf(from);
    const iy = lat.iyOf(from);
    const jx = lat.ixOf(to);
    const jy = lat.iyOf(to);
    std.debug.assert(if (dir == .h)
        iy == jy and (ix + 1 == jx or jx + 1 == ix)
    else
        ix == jx and (iy + 1 == jy or jy + 1 == iy));

    // Never touch a foreign pin, never T into a foreign net.
    if (lat.nodeBlocked(to, net)) return null;

    const e = if (dir == .h)
        lat.hEdge(@min(ix, jx), iy)
    else
        lat.vEdge(ix, @min(iy, jy));

    // Collinear sharing is a short, not a crossing.
    if (lat.edgeShorted(dir, e, net)) return null;
    if (lat.edgeCutsBody(dir, e, net, @min(from, to), @max(from, to))) return null;

    const len: u32 = if (dir == .h)
        @intCast(@abs(lat.xs[jx] - lat.xs[ix]))
    else
        @intCast(@abs(lat.ys[jy] - lat.ys[iy]));

    // A lattice column has no purpose the way a row does, so every vertical unit
    // costs `W.base` regardless of class — that is what makes a rail's drop off its
    // bus affordable.
    const unit = if (dir == .h) rowCost(lat.row[iy], kind) else W.base;

    var w = std.math.mul(u32, len, unit) catch inf;
    if (dir != from_dir) w +|= W.bend;
    // Perpendicular pass-through is a genuine crossing: priced, never blocked.
    if (lat.crosses(to, dir, net)) w +|= W.cross;
    return w;
}

/// Entries the heap must hold for a lattice of `nodes` nodes.
///
/// The queue uses lazy deletion — an improved slot is pushed again rather than
/// decreased in place — so the bound is one entry per successful relaxation, and
/// each of the `2 * nodes` slots can be relaxed from at most four neighbours. Hence
/// `nodes * 8`. `Scratch.ensure` is the only sizing point in the program, and this
/// is the contract it must satisfy; `run` asserts it on entry rather than growing,
/// because growing would mean allocating.
pub fn heapCapacityFor(nodes: u32) usize {
    return @as(usize, nodes) * 8;
}

/// Run one multi-source expansion. Returns the slot at which the nearest unconnected
/// terminal was reached, or null when the lattice is exhausted and no such path
/// exists.
///
/// Null is the *proof* behind the label fallback: it means Dijkstra drained the
/// queue without reaching any target, so no Manhattan tree exists on this lattice
/// for this net. That is why a label is a real guarantee rather than "this shape was
/// not in the vocabulary" (ALGORITHM.md, "The label fallback"). Callers must not
/// treat null as "try something else"; there is nothing else.
///
/// Side effects: bumps `sc.gen` and overwrites `sc.dist`, `sc.dist_gen`, `sc.prev`
/// and `sc.heap`. Every previous search's results are invalidated — including the
/// predecessor chain — so `reconstruct` must be called before the next `run`.
///
/// Pre-conditions, asserted: `sc.capacity >= lat.nodeCount()`,
/// `sc.heap.len >= heapCapacityFor(lat.nodeCount())`, `q.sources` and `q.targets`
/// sorted ascending and disjoint. A source that is `nodeBlocked` for `q.net` is
/// skipped rather than asserted — coincident pins can close a node the net itself
/// owns a pin on, and the honest outcome is that the net fails to route and gets
/// labelled.
///
/// Edge cases: empty `sources` or empty `targets` returns null immediately, having
/// bumped the generation. A target that is also a source violates the precondition
/// and is a caller bug, not a fast path.
///
/// Determinism: neighbours are relaxed in the fixed order left, right, up, down, and
/// ties in the heap break on the lower slot index. Two runs over equal input pop
/// the same sequence, which is what makes the whole pipeline byte-reproducible.
///
/// Complexity: O(E log V) with `V = 2 * nodes` and `E = 4V`. The heap is 4-ary
/// because sift-down dominates and a wider fan-out shortens the tree.
/// `// ponytail: 4-ary heap; the weights are small integers (1/10/80/900/3000) so a
/// bucket queue (Dial's) would be O(1) per operation — swap to one if profiling ever
/// puts the heap in the top three. It needs a sizing analysis first, because the
/// bucket count scales with the largest single-edge increment,
/// W.bend + W.cross + W.off * longest_span.`
pub fn run(lat: *const Lattice, sc: *Scratch, q: Query) ?u32 {
    const nodes = lat.nodeCount();
    std.debug.assert(sc.capacity >= nodes);
    std.debug.assert(sc.heap.len >= heapCapacityFor(nodes));
    if (std.debug.runtime_safety) {
        var i: usize = 1;
        while (i < q.sources.len) : (i += 1) std.debug.assert(q.sources[i] > q.sources[i - 1]);
        i = 1;
        while (i < q.targets.len) : (i += 1) std.debug.assert(q.targets[i] > q.targets[i - 1]);
        for (q.sources) |s| std.debug.assert(!isMember(q.targets, s));
    }

    // Every previous search's results die here, in one integer increment.
    sc.newGeneration();
    if (q.sources.len == 0 or q.targets.len == 0) return null;

    var len: usize = 0;
    for (q.sources) |s| {
        // A source the net cannot even stand on is skipped, not asserted: coincident
        // pins can close a node the net itself owns a pin on.
        if (lat.nodeBlocked(s, q.net)) continue;
        for ([2]Dir{ .h, .v }) |d| {
            const slot = slotOf(s, d);
            sc.dist[slot] = 0;
            sc.dist_gen[slot] = sc.gen;
            sc.prev[slot] = no_prev;
            len = heapPush(sc.heap, len, .{ .cost = 0, .node_dir = slot });
        }
    }

    while (len > 0) {
        const top, const shrunk = heapPop(sc.heap, len);
        len = shrunk;
        const slot = top.node_dir;
        // Lazy deletion: an improved slot was pushed again, so stale copies remain.
        if (!sc.isLive(slot) or top.cost > sc.dist[slot]) continue;

        const node = nodeOf(slot);
        if (isMember(q.targets, node)) return slot;

        const dir = dirOf(slot);
        const ix = lat.ixOf(node);
        const iy = lat.iyOf(node);
        // Fixed relaxation order — left, right, up, down — is part of determinism.
        var nb: [4]struct { to: u32, dir: Dir } = undefined;
        var n_nb: usize = 0;
        if (ix > 0) {
            nb[n_nb] = .{ .to = node - 1, .dir = .h };
            n_nb += 1;
        }
        if (ix + 1 < lat.nx) {
            nb[n_nb] = .{ .to = node + 1, .dir = .h };
            n_nb += 1;
        }
        if (iy > 0) {
            nb[n_nb] = .{ .to = node - lat.nx, .dir = .v };
            n_nb += 1;
        }
        if (iy + 1 < lat.ny) {
            nb[n_nb] = .{ .to = node + lat.nx, .dir = .v };
            n_nb += 1;
        }

        for (nb[0..n_nb]) |step| {
            const w = stepCost(lat, q.net, q.kind, node, dir, step.to, step.dir) orelse continue;
            const nc = top.cost +| w;
            const ns = slotOf(step.to, step.dir);
            if (sc.isLive(ns) and nc >= sc.dist[ns]) continue;
            sc.dist[ns] = nc;
            sc.dist_gen[ns] = sc.gen;
            sc.prev[ns] = slot;
            len = heapPush(sc.heap, len, .{ .cost = nc, .node_dir = ns });
        }
    }
    return null;
}

/// No predecessor: this slot is a search source.
const no_prev: u32 = std.math.maxInt(u32);

/// Membership in a sorted, deduplicated node list. Binary search, never a map.
fn isMember(sorted: []const u32, n: u32) bool {
    return std.sort.binarySearch(u32, sorted, n, struct {
        fn f(key: u32, item: u32) std.math.Order {
            return std.math.order(key, item);
        }
    }.f) != null;
}

/// Walk the predecessor chain from `slot` back to a source, writing node indices into
/// `out` in path order (source first, terminal last).
///
/// Returns the prefix of `out` that was written. `out` must be long enough for the
/// path; `lat.nodeCount()` always is, since a shortest path visits no node twice.
/// Asserts the chain terminates — a truncated chain means the caller ran another
/// search between `run` and this call, and silently returning a partial path would
/// draw a wire to nowhere.
///
/// Consecutive nodes may repeat when a path turns at a node (the two slots of one
/// node are distinct states); duplicates are collapsed here, so the result is a
/// simple node path ready for `tree.compress`.
///
/// Reads `sc.prev`, mutates nothing. Borrowed: the result aliases `out`.
pub fn reconstruct(sc: *const Scratch, slot: u32, out: []u32) []u32 {
    var n: usize = 0;
    var cur = slot;
    while (true) {
        // A dead stamp means another search ran between `run` and this call, and a
        // partial path would draw a wire to nowhere.
        std.debug.assert(sc.isLive(cur));
        out[n] = nodeOf(cur);
        n += 1;
        const p = sc.prev[cur];
        if (p == no_prev) break;
        cur = p;
    }
    std.mem.reverse(u32, out[0..n]);

    // A path that turns at a node visits both of that node's slots.
    var w: usize = 1;
    for (out[1..n]) |v| {
        if (v == out[w - 1]) continue;
        out[w] = v;
        w += 1;
    }
    return out[0..w];
}

/// Best known cost of `slot` in the current generation, or `inf` when unvisited.
///
/// The read side of generation stamping, exposed so tests can assert that a new
/// search does not inherit the previous net's distances.
pub fn distOf(sc: *const Scratch, slot: u32) u32 {
    return if (sc.isLive(slot)) sc.dist[slot] else inf;
}

// ---------------------------------------------------------------------------
// 4-ary heap over Scratch.heap
//
// Split out so the sift loops are testable in isolation and so `run` reads as the
// algorithm rather than as index arithmetic. Both operate on a caller-held length,
// because the buffer is shared and its length is not the heap's size.
// ---------------------------------------------------------------------------

/// Push `entry` onto the heap of current size `len`, returning the new size.
///
/// Sifts up by comparing `(cost, node_dir)` — cost first, slot index as the
/// tie-break, so equal-cost entries pop in a defined order. Asserts the buffer has
/// room; see `heapCapacityFor`.
pub fn heapPush(heap: []Scratch.HeapEntry, len: usize, entry: Scratch.HeapEntry) usize {
    std.debug.assert(len < heap.len);
    var i = len;
    heap[i] = entry;
    while (i > 0) {
        const p = (i - 1) / 4;
        if (!entryLess(heap[i], heap[p])) break;
        std.mem.swap(Scratch.HeapEntry, &heap[i], &heap[p]);
        i = p;
    }
    return len + 1;
}

/// Pop the minimum entry from the heap of current size `len`.
///
/// Returns the entry and the new size. Asserts `len > 0`. Sifts down over four
/// children per level, which is the whole reason for the 4-ary shape: pops dominate,
/// and a shallower tree means fewer cache misses per sift.
pub fn heapPop(heap: []Scratch.HeapEntry, len: usize) struct { Scratch.HeapEntry, usize } {
    std.debug.assert(len > 0);
    const top = heap[0];
    const n = len - 1;
    if (n > 0) {
        heap[0] = heap[n];
        var i: usize = 0;
        while (true) {
            var best = i;
            var c = i * 4 + 1;
            const end = @min(c + 4, n);
            while (c < end) : (c += 1) {
                if (entryLess(heap[c], heap[best])) best = c;
            }
            if (best == i) break;
            std.mem.swap(Scratch.HeapEntry, &heap[i], &heap[best]);
            i = best;
        }
    }
    return .{ top, n };
}

/// Total order on heap entries: cost ascending, then slot index ascending.
///
/// The slot tie-break is not cosmetic. Equal-cost frontier entries are the common
/// case on a Hanan grid full of equal-length edges, and leaving their order to the
/// heap's internal array layout would make the output depend on push history.
pub fn entryLess(a: Scratch.HeapEntry, b: Scratch.HeapEntry) bool {
    if (a.cost != b.cost) return a.cost < b.cost;
    return a.node_dir < b.node_dir;
}
