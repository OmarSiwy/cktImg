//! The two-phase order search: which spline goes where, left to right.
//!
//! Spline extraction fixes the *set* of columns but not their order. Choosing the
//! order is where all the remaining quality lives, and the two halves of the problem
//! cost wildly different amounts — so they are separated:
//!
//! ```
//! Phase A   every permutation x every free intra-spine swap
//!           -> Proxy (total_signal_span, backward_net_count)
//!           -> the best `refine` survive, in a FIXED STACK ARRAY
//!           ~1000x cheaper than routing an order. ALLOCATES NOTHING.
//!
//! Phase B   place + route + measure each survivor
//!           -> Key (11 integer fields, compared left to right)
//!           -> the winner
//! ```
//!
//! Measured on a generated inverter chain, nine splines went from ~28 s to ~0.2 s and
//! the answer was **identical**, because the proxy is a faithful filter rather than an
//! approximation of the answer. The old arrangement had it backwards: a full route and
//! measure inside an `n!`-sized loop, which capped both how good the router could
//! afford to be and how many splines could be enumerated at all.
//!
//! ## Phase A has no crossing term, and that is not an oversight
//!
//! Phase B ranks `num_crossings` above everything except correctness, so adding a
//! crossing estimate to the proxy is the obvious move. Two were implemented and
//! measured — an interval-**interleave** count (nets whose column spans partially
//! overlap so neither nests inside the other) and a stack-depth **inversion** count
//! (nets crossing one gap whose relative height flips across it). Both made the
//! shortlist *worse* at every tier position tried, worse even than letting equal-span
//! orders fall through to an arbitrary-but-consistent tie-break.
//!
//! The reason is structural, and it is recorded here so nobody re-attempts it as
//! stated. Phase A reasons over **splines**; crossings are decided by **columns**, and
//! the two are not the same set: `column.assign` inserts `.shared`, `.component`,
//! `.feedback` and `.signal_series` columns that no order search ever permutes —
//! `folded_cascode` has 2 splines and 7 columns. On top of that, relative vertical
//! position between columns is set by `stack.alignColumns` *after* ranking, so any
//! depth-based inversion count is guessing at geometry that has not been decided yet. A
//! term that models neither cannot predict crossings; a term that models both is no
//! longer a cheap proxy.
//!
//! The measurement that settles it: on every enumerable fixture the placer already
//! achieves the **exhaustive crossing floor** over all orders. There is nothing for a
//! better ranking key to win. Reducing crossings further needs a change to the *model*
//! — bringing inserted columns into the search space — not to this function.
//!
//! ## Phase A allocates nothing, and that is a structural property
//!
//! The loop may run `n!` times. Everything it touches is a fixed stack array: the
//! permutation buffer (Heap's algorithm, in place), the position map, and the top-K
//! list (insertion into `[]Candidate` the caller provides). Everything that *would*
//! need to be built — the device→splines relation and the greedy adjacency matrix —
//! is hoisted into `Ranker`, built once before the loop starts. `phaseA` therefore
//! takes no `Allocator` at all, which makes the property checkable by looking at the
//! signature rather than by trusting the body.
//!
//! ## The proxy is invariant under intra-spine swaps
//!
//! Worth stating because it is surprising and it is what keeps the swap enumeration
//! free. `Proxy` is a function of which *splines* a net touches and where those
//! splines sit — never of the order of devices inside one. Flipping a swappable pair
//! changes neither, so every swap variant of an order scores identically and the
//! variants are separated only by the tie-break. They still all stream through Phase A,
//! because a survivor's swap mask has to reach Phase B where it genuinely matters
//! (it moves a gate tap, which can save a crossing), and carrying a mask costs one byte
//! per candidate rather than a copy of the spline set.
//!
//! ## Determinism
//!
//! Every tie is broken by an explicit integer comparison: the proxy pair first, then
//! the permutation lexicographically, then the swap mask. Nothing is left to insertion
//! order, nothing is read from a hash map, and `Key.netid_seq` closes the last gap in
//! Phase B. Two runs over the same bytes emit the same drawing byte for byte.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const Csr = @import("../csr.zig").Csr;
const Config = @import("../config.zig").Config;
const ctxm = @import("ctx.zig");
const splinem = @import("spline.zig");

const DeviceIdx = ids.DeviceIdx;
const NetIdx = ids.NetIdx;
const Ctx = ctxm.Ctx;
const SplineIdx = ctxm.SplineIdx;
const SplineSet = ctxm.SplineSet;
const Swap = splinem.Swap;

/// Largest spline count Phase A can hold in its fixed buffers.
///
/// Above `Config.layout.enum_limit` (default 10) the search abandons exhaustive
/// enumeration for greedy seeds anyway, so this only has to exceed that bound with
/// headroom. Chosen at 16 so a caller can raise `enum_limit` a few notches without
/// recompiling — 16! is far beyond any sane budget, but the *buffer* costing 16 bytes
/// is not worth being clever about.
pub const max_splines: usize = 16;

/// Largest shortlist Phase A will fill.
///
/// `Config.layout.refine` (default 16) is clamped to this. Quality on the fixture set
/// saturates at `refine = 2`, so the default is already pure headroom and this ceiling
/// is not a constraint anyone will meet.
pub const max_refine: usize = 64;

/// Largest number of free intra-spine swaps that get enumerated.
///
/// `2^8` variants. More never helped in practice, and the enumeration is a product with
/// the permutation count, so the cap is what keeps `n! * 2^k` from becoming the thing
/// that runs out of budget instead of `n!`.
/// `// ponytail: 8-swap cap; lift it only with a measurement that says it bought something.`
pub const max_swaps: usize = 8;

/// Cheap, routing-free score for one column order. Lower is better on both fields.
///
/// **Two fields, and there is no third.** See the module header for the crossing term
/// that was measured and rejected; a test asserts this struct's shape so that adding
/// one is a deliberate act rather than a drive-by.
///
/// `span` is the total left-to-right distance every signal net has to reach, summed
/// over nets. Minimising it *is* ALGORITHM.md's "signals flow left to right"
/// preference, restated as a linear-arrangement objective — which is a real objective
/// with a real optimum, rather than a heuristic.
///
/// `backward` counts nets driving leftwards: a conducting pin in a later column than a
/// gate it feeds. Exactly the nets that end up in the feedback margin, so fewer of them
/// means less margin traffic.
pub const Proxy = struct {
    span: u32 = 0,
    backward: u32 = 0,

    /// Lexicographic order: span first, backward as the tie-break. Total.
    pub fn lessThan(a: Proxy, b: Proxy) bool {
        return a.order(b) == .lt;
    }

    pub fn order(a: Proxy, b: Proxy) std.math.Order {
        if (a.span != b.span) return std.math.order(a.span, b.span);
        return std.math.order(a.backward, b.backward);
    }
};

/// One survivor of Phase A: an order, a swap mask, and the score it earned.
///
/// Fixed size and trivially copyable so the shortlist can be a stack array. `order` is
/// a `[max_splines]u8` rather than a slice for exactly that reason — a slice would
/// point into a permutation buffer that the very next iteration overwrites.
pub const Candidate = struct {
    /// The score. Candidates in a shortlist are sorted ascending on this first.
    proxy: Proxy = .{},
    /// Which free intra-spine swaps are applied, one bit per entry of
    /// `Ranker.swaps`. Bit `k` set means that pair is flipped.
    swap_mask: u8 = 0,
    /// How many entries of `order` are meaningful.
    len: u8 = 0,
    /// `order[k]` is the spline index that goes in the k-th column position. A
    /// permutation of `0 .. len`.
    order: [max_splines]u8 = @splat(0),

    /// Total order used by the shortlist: proxy, then the permutation
    /// lexicographically, then the swap mask.
    ///
    /// Every tier is an integer comparison, so two runs produce the same shortlist in
    /// the same sequence. The permutation tier is what makes the "arbitrary" tie-break
    /// ALGORITHM.md mentions actually *consistent*.
    pub fn lessThan(a: Candidate, b: Candidate) bool {
        switch (a.proxy.order(b.proxy)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        switch (std.mem.order(u8, a.slice(), b.slice())) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        return a.swap_mask < b.swap_mask;
    }

    /// The meaningful prefix of `order`. Borrowed from `a`; do not retain past its
    /// lifetime.
    pub fn slice(a: *const Candidate) []const u8 {
        return a.order[0..a.len];
    }
};

/// Everything Phase A needs, hoisted out of the loop so the loop can allocate nothing.
///
/// Built once per document (the spline set is fixed; only its order is searched), so
/// allocate it from the `doc` arena alongside `Ctx`. Borrowed by every `rank` call and
/// by `phaseA`.
pub const Ranker = struct {
    /// Borrowed. Must outlive the ranker.
    c: Ctx,
    /// Borrowed. Must outlive the ranker.
    splines: SplineSet,
    /// device → the splines it lies on, ascending and deduplicated.
    ///
    /// A CSR because the proxy walks it once per pin of every signal net, which is the
    /// innermost loop of an `n!` search. The Rust original rebuilds a
    /// `Vec<Vec<usize>>` per swap variant; here it is built once and never again,
    /// which is most of the reason `phaseA` needs no allocator.
    dev_spline: Csr(DeviceIdx, SplineIdx),
    /// Free intra-spine swaps, truncated to `max_swaps`. Borrowed or owned depending
    /// on `init`; released by `deinit` either way.
    swaps: []Swap,
    /// Row-major `n x n` count of nets two splines share. Only populated when the
    /// spline count exceeds `enum_limit`, since it exists solely to seed the greedy
    /// fallback; empty otherwise, and that emptiness is the flag.
    adj: []u32,
    /// Spline count, `<= max_splines`.
    n: u8,

    pub const empty: Ranker = .{
        .c = Ctx.empty,
        .splines = .empty,
        .dev_spline = .empty,
        .swaps = &.{},
        .adj = &.{},
        .n = 0,
    };

    /// Build the ranker for one document.
    ///
    /// Asserts `splines.keyCount() <= max_splines`; a schematic beyond that is a
    /// resource bound the caller must have clamped first, not a runtime condition to
    /// paper over. Truncates `swaps` to `max_swaps` entries, keeping the lowest
    /// `(spline, at)` pairs so the truncation is deterministic rather than
    /// whichever-came-first.
    ///
    /// Caller owns the result and must `deinit` it with `gpa`.
    ///
    /// Errors: `OutOfMemory` only. Complexity: O(total spline length) for the reverse
    /// relation, plus O(n^2 x nets) for the adjacency matrix — which is skipped
    /// entirely when exhaustive enumeration will be used.
    pub fn init(
        gpa: Allocator,
        c: Ctx,
        splines: SplineSet,
        cfg: *const Config,
    ) Allocator.Error!Ranker {
        const n = splines.keyCount();
        std.debug.assert(n <= max_splines);
        const nd = c.deviceCount();

        // device -> splines, ascending. Built once; the `n!` loop then reads it and
        // allocates nothing, which is most of why `phaseA` takes no allocator.
        const counts = try gpa.alloc(u32, nd);
        defer gpa.free(counts);
        @memset(counts, 0);
        for (splines.values) |d| counts[d.i()] += 1;
        var dev_spline = try Csr(DeviceIdx, SplineIdx).fromCounts(gpa, counts);
        errdefer dev_spline.deinit(gpa);
        const cursor = try gpa.alloc(u32, nd);
        defer gpa.free(cursor);
        @memcpy(cursor, dev_spline.offsets[0..nd]);
        for (0..n) |si| {
            for (splines.slice(SplineIdx.at(si))) |d| {
                dev_spline.values[cursor[d.i()]] = SplineIdx.at(si);
                cursor[d.i()] += 1;
            }
        }

        const all = try splinem.swappablePairs(gpa, c, splines);
        defer gpa.free(all);
        // Truncation keeps the lowest `(spline, at)` pairs, which `swappablePairs`
        // already emits in order, so which swaps survive is not whichever-came-first.
        const swaps = try gpa.dupe(Swap, all[0..@min(all.len, max_swaps)]);
        errdefer gpa.free(swaps);

        // The adjacency matrix exists only to seed the greedy fallback, so it is not
        // computed at all when exhaustive enumeration will be used. That emptiness is
        // the flag `greedyOrders` asserts on.
        var adj: []u32 = &.{};
        if (n > cfg.layout.enum_limit) {
            adj = try gpa.alloc(u32, n * n);
            errdefer gpa.free(adj);
            @memset(adj, 0);
            const mark = try gpa.alloc(u8, c.netCount());
            defer gpa.free(mark);
            @memset(mark, 0);
            for (0..n) |i| {
                for (splines.slice(SplineIdx.at(i))) |d| {
                    const lo, const hi = c.ir.pinRange(d);
                    for (lo..hi) |pi| {
                        const net = c.ir.pin_net[pi];
                        if (net != .none) mark[net.i()] = 1;
                    }
                }
                for (i + 1..n) |j| {
                    var shared: u32 = 0;
                    for (splines.slice(SplineIdx.at(j))) |d| {
                        const lo, const hi = c.ir.pinRange(d);
                        for (lo..hi) |pi| {
                            const net = c.ir.pin_net[pi];
                            if (net == .none or mark[net.i()] != 1) continue;
                            mark[net.i()] = 2; // counted once per pair
                            shared += 1;
                        }
                    }
                    for (splines.slice(SplineIdx.at(j))) |d| {
                        const lo, const hi = c.ir.pinRange(d);
                        for (lo..hi) |pi| {
                            const net = c.ir.pin_net[pi];
                            if (net != .none and mark[net.i()] == 2) mark[net.i()] = 1;
                        }
                    }
                    adj[i * n + j] = shared;
                    adj[j * n + i] = shared;
                }
                @memset(mark, 0);
            }
        }

        return .{
            .c = c,
            .splines = splines,
            .dev_spline = dev_spline,
            .swaps = swaps,
            .adj = adj,
            .n = @intCast(n),
        };
    }

    pub fn deinit(self: *Ranker, gpa: Allocator) void {
        self.dev_spline.deinit(gpa);
        gpa.free(self.swaps);
        gpa.free(self.adj);
        self.swaps = &.{};
        self.adj = &.{};
    }

    /// Score one order. **Allocates nothing** — this is the function that runs `n!`
    /// times.
    ///
    /// `posn` maps spline index to column position: `posn[s]` is where spline `s` sits.
    /// That is the *inverse* of a `Candidate.order`, and it is the direction the proxy
    /// wants, because the loop is over nets and asks "where is the spline this pin's
    /// device lies on". `phaseA` maintains both. Length must equal `n`; asserted.
    ///
    /// Only **signal** nets contribute. A rail spans the whole layout by definition and
    /// would add a constant to every order's span, which changes no comparison and
    /// costs a pass over the widest nets in the circuit.
    ///
    /// A net whose pins all sit on devices belonging to no spline (a bridge between two
    /// satellites, say) contributes nothing: it has no position to reason about at this
    /// stage. That is a real limitation and is the "most columns are not in the search
    /// space" known gap, not a bug in this function.
    ///
    /// Complexity: O(pins of signal nets x splines per device), with everything read
    /// from two CSRs and one stack array.
    pub fn rank(self: *const Ranker, posn: []const u8) Proxy {
        std.debug.assert(posn.len == self.n);
        var out: Proxy = .{};
        const c = self.c;
        for (0..c.netCount()) |ni| {
            const net = NetIdx.at(ni);
            // A rail spans the layout by definition: it would add the same constant to
            // every order and change no comparison.
            if (c.isRailNet(net)) continue;
            var lo: u8 = std.math.maxInt(u8);
            var hi: u8 = 0;
            var gate_lo: u8 = std.math.maxInt(u8);
            var drv_hi: u8 = 0;
            var seen = false;
            var has_gate = false;
            for (c.members(net)) |p| {
                for (self.dev_spline.slice(c.devOf(p))) |s| {
                    const pos = posn[s.i()];
                    lo = @min(lo, pos);
                    hi = @max(hi, pos);
                    seen = true;
                    if (c.isControl(p)) {
                        gate_lo = @min(gate_lo, pos);
                        has_gate = true;
                    } else if (c.conducts(p)) {
                        drv_hi = @max(drv_hi, pos);
                    }
                }
            }
            // A net on no spline has no position to reason about at this stage.
            if (!seen) continue;
            out.span += hi - lo;
            if (has_gate and drv_hi > gate_lo) out.backward += 1;
        }
        return out;
    }

    /// One greedy most-connected-next order per possible starting spline, written into
    /// `out`.
    ///
    /// The fallback above `Config.layout.enum_limit`, where `n!` is out of budget. Each
    /// seed grows an order by repeatedly appending the unplaced spline sharing the most
    /// nets with everything placed so far, ties going to the lower index. Returns how
    /// many orders were written; at most `n`, so `out` must hold `n` entries of
    /// `[max_splines]u8`.
    ///
    /// Allocation-free: it reads `adj`, which `init` built. Asserts `adj` is populated
    /// — calling this on a ranker built under the enumeration limit is a programming
    /// error, because the matrix was deliberately not computed.
    pub fn greedyOrders(self: *const Ranker, out: [][max_splines]u8) usize {
        std.debug.assert(self.adj.len > 0);
        const n: usize = self.n;
        std.debug.assert(out.len >= n);
        for (0..n) |start| {
            var placed = std.StaticBitSet(max_splines).initEmpty();
            out[start][0] = @intCast(start);
            placed.set(start);
            for (1..n) |k| {
                var best: usize = 0;
                var best_conn: u32 = 0;
                var have = false;
                for (0..n) |i| {
                    if (placed.isSet(i)) continue;
                    var conn: u32 = 0;
                    for (out[start][0..k]) |j| conn += self.adj[i * n + j];
                    // Ties go to the lower index, so the seed is reproducible.
                    if (have and conn <= best_conn) continue;
                    have = true;
                    best = i;
                    best_conn = conn;
                }
                out[start][k] = @intCast(best);
                placed.set(best);
            }
        }
        return n;
    }
};

/// Phase A — stream every candidate order and keep the best `out.len`.
///
/// Enumerates, for each swap mask in `0 .. 2^|swaps|`, every permutation of the spline
/// indices, scores it with `Ranker.rank`, and inserts it into `out` if it beats the
/// current worst survivor. Permutations come from **Heap's algorithm run iteratively
/// over a fixed stack array**: each step is one transposition, so the position map is
/// updated in O(1) rather than rebuilt, and there is no recursion depth to bound.
///
/// Above `cfg.layout.enum_limit` splines the permutation enumeration is replaced by
/// `Ranker.greedyOrders`, one seed per spline. That guard is a resource bound, not an
/// opinion: `n!` growth is the known gap ALGORITHM.md documents, and this is the guard
/// rather than the fix. Do not "improve" it during the port.
///
/// `out` is caller-supplied and should be a **stack array** of `min(cfg.layout.refine,
/// max_refine)` entries — the whole point is that this function is reachable from a
/// loop that allocates nothing. It is left sorted ascending by `Candidate.lessThan`.
///
/// Returns how many entries were filled: `min(out.len, number of candidates)`. Zero
/// when `out` is empty or the ranker holds no splines; a caller seeing zero should
/// evaluate the empty order, which places every device as an inserted column and is a
/// legitimate drawing for a rail-less circuit.
///
/// **Takes no allocator, by construction.** A test asserts that, because it is the
/// kind of property that survives review and dies to a refactor.
///
/// Post-conditions: `out[0 .. n]` is sorted, contains no duplicate `(order, swap_mask)`
/// pair, and is identical across runs on identical input.
pub fn phaseA(r: *const Ranker, cfg: *const Config, out: []Candidate) usize {
    const n: usize = r.n;
    if (out.len == 0 or n == 0) return 0;

    var perm: [max_splines]u8 = undefined;
    var posn: [max_splines]u8 = undefined;
    var counter: [max_splines]u8 = undefined;
    var seeds: [max_splines][max_splines]u8 = undefined;
    var filled: usize = 0;

    const nswaps: u5 = @intCast(@min(r.swaps.len, max_swaps));
    const masks: u32 = @as(u32, 1) << nswaps;
    var mask: u32 = 0;
    while (mask < masks) : (mask += 1) {
        if (n <= cfg.layout.enum_limit) {
            for (0..n) |k| {
                perm[k] = @intCast(k);
                posn[k] = @intCast(k);
                counter[k] = 0;
            }
            consider(r, perm[0..n], posn[0..n], @intCast(mask), out, &filled);
            // Heap's algorithm, iteratively over a fixed array: one transposition per
            // step, so the position map updates in O(1) and there is no recursion.
            var i: usize = 1;
            while (i < n) {
                if (counter[i] < i) {
                    const j: usize = if (i % 2 == 0) 0 else counter[i];
                    std.mem.swap(u8, &perm[j], &perm[i]);
                    posn[perm[j]] = @intCast(j);
                    posn[perm[i]] = @intCast(i);
                    consider(r, perm[0..n], posn[0..n], @intCast(mask), out, &filled);
                    counter[i] += 1;
                    i = 1;
                } else {
                    counter[i] = 0;
                    i += 1;
                }
            }
        } else {
            // Above the limit `n!` is out of budget. The guard is a resource bound,
            // not an opinion — ALGORITHM.md documents the factorial as a known gap.
            const got = r.greedyOrders(seeds[0..n]);
            for (seeds[0..got]) |seed| {
                @memcpy(perm[0..n], seed[0..n]);
                for (perm[0..n], 0..) |s, pos| posn[s] = @intCast(pos);
                consider(r, perm[0..n], posn[0..n], @intCast(mask), out, &filled);
            }
        }
    }
    return filled;
}

/// Score one order and insert it into the shortlist if it beats the current worst.
///
/// Insertion into a caller-supplied array: no allocation, and the array stays sorted
/// so the "worst survivor" test is one comparison against the last entry.
fn consider(
    r: *const Ranker,
    perm: []const u8,
    posn: []const u8,
    mask: u8,
    out: []Candidate,
    filled: *usize,
) void {
    var cand: Candidate = .{
        .proxy = r.rank(posn),
        .swap_mask = mask,
        .len = @intCast(perm.len),
        .order = @splat(0),
    };
    @memcpy(cand.order[0..perm.len], perm);

    if (filled.* < out.len) {
        var k = filled.*;
        while (k > 0 and cand.lessThan(out[k - 1])) : (k -= 1) out[k] = out[k - 1];
        out[k] = cand;
        filled.* += 1;
        return;
    }
    if (!cand.lessThan(out[out.len - 1])) return;
    var k = out.len - 1;
    while (k > 0 and cand.lessThan(out[k - 1])) : (k -= 1) out[k] = out[k - 1];
    out[k] = cand;
}

/// The Phase-B selection key: eleven integers, compared left to right.
///
/// **Never a weighted sum.** A weighted sum lets a large improvement in a cheap field
/// buy a regression in an expensive one, and the whole point of this ordering is that
/// it cannot. Field declaration order *is* the priority order documented in
/// ALGORITHM.md, so reordering this struct is a behaviour change — which is the intent,
/// and is why the fields are not alphabetized or grouped by type.
///
/// Read top to bottom: avoid a net dropped to a label first, then a short, then a wire
/// driven through a device body, then wire-vs-wire crossings, and only then staple
/// count and span. **Crossings outrank staples and span** because a crossing is a
/// measured aesthetic fault while those two are merely proxies for complexity.
///
/// The first five fields are *assertions* rather than objectives. Because bodies block
/// lattice edges and foreign pins block lattice nodes, a colliding route is unreachable
/// in the search rather than something drawn and then measured — on the current fixture
/// set they are zero for every weight setting tried, which is the evidence that the
/// guarantee comes from the structure and not from the tuning. They stay in the key so
/// that a regression in the lattice shows up as a lost candidate rather than as a
/// silently worse drawing.
///
/// This type lives here rather than in `metric.zig` because it is the search's
/// *decision procedure*; `metric.zig` measures the fields and should alias it
/// (`pub const Key = order.Key;`) rather than declare a second copy — two definitions
/// of a priority order is exactly how a priority order drifts.
pub const Key = struct {
    /// Nets the router proved unroutable and dropped to name tags. Minimised first,
    /// which is what keeps the label fallback the exception ALGORITHM.md promises.
    labels: u32 = 0,
    /// Wires touching a foreign net's pin point. A short on any host that merges a pin
    /// with a wire passing through it.
    pin_hits: u32 = 0,
    /// Wire endpoints landing on a foreign net's wire — a T-junction short.
    geom_shorts: u32 = 0,
    /// Wires driven through a device body.
    body_hits: u32 = 0,
    /// Collinear same-direction overlaps between two nets.
    overlaps: u32 = 0,
    /// Perpendicular wire-vs-wire crossings. The highest-ranked genuine objective.
    crossings: u32 = 0,
    /// Backward feedback staples.
    staples: u32 = 0,
    /// Total column span of the spanning nets.
    total_span: u32 = 0,
    /// Forward nets that ended up in the top margin band. The margin is for backward
    /// feedback; this counts the invariant being *observed* rather than merely asserted.
    forward_margin: u32 = 0,
    /// Distinct margin rows the routes actually used.
    margin_tracks: u32 = 0,
    /// Final deterministic tie-break: a fixed fold of the sorted in-field net-id
    /// sequence.
    ///
    /// Its job is not to express a preference — by the time two candidates agree on ten
    /// integer quality measures, neither is better. Its job is to make the choice
    /// between them a *function of the input* instead of a function of evaluation
    /// order, so that two runs over the same bytes pick the same drawing. Folding the
    /// sequence into one `u64` keeps `Key` a fixed-size, trivially copyable value that
    /// needs no allocator and no lifetime; the fold must be fixed and documented, since
    /// changing it changes which of two equally good drawings ships.
    netid_seq: u64 = 0,

    /// Strict lexicographic comparison, field by field in declaration order.
    ///
    /// A total order: irreflexive, antisymmetric and transitive, because it is a
    /// lexicographic product of total orders on unsigned integers. Tests pin all three,
    /// plus the specific consequence that a candidate with fewer crossings wins even
    /// when it has more staples and a longer span.
    pub fn lessThan(a: Key, b: Key) bool {
        return a.order(b) == .lt;
    }

    pub fn order(a: Key, b: Key) std.math.Order {
        inline for (@typeInfo(Key).@"struct".fields) |f| {
            const x = @field(a, f.name);
            const y = @field(b, f.name);
            if (x != y) return std.math.order(x, y);
        }
        return .eq;
    }

    /// Fold a sorted, deduplicated net-id sequence into the `netid_seq` tie-break.
    ///
    /// `nets` must be ascending; the fold is order-sensitive, so an unsorted input
    /// silently produces a different tie-break and is asserted against. Fixed mixing
    /// with no randomness and no address dependence — a seeded or ASLR-influenced hash
    /// here would make output differ between runs, which is the one thing this field
    /// exists to prevent.
    ///
    /// Pure, allocation-free.
    pub fn foldNetIds(nets: []const NetIdx) u64 {
        // FNV-1a over the little-endian ids. Fixed mixing, no seed, no address
        // dependence: two runs over the same bytes must fold identically.
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (nets, 0..) |n, i| {
            if (i > 0) std.debug.assert(@intFromEnum(n) > @intFromEnum(nets[i - 1]));
            var v = @intFromEnum(n);
            for (0..4) |_| {
                h ^= v & 0xff;
                h *%= 0x1000_0000_01b3;
                v >>= 8;
            }
        }
        return h;
    }
};

/// Phase B's decision: the index of the best measured candidate.
///
/// `keys[i]` is the measured key of survivor `i`, in the order `phaseA` produced them.
/// Returns the index of the `Key.lessThan`-minimum, and on an exact tie the **lowest
/// index** — which is the best Phase-A proxy, so the cheap filter breaks what the
/// expensive one could not.
///
/// Kept separate from the evaluation loop deliberately: the loop needs a lattice, a
/// router and a measurer, none of which this file should know about, while the
/// *decision* is a comparison over eleven integers that can be tested on its own. The
/// caller's Phase B is then the obvious three lines — reset the `search` arena, place
/// and route the candidate, measure it — with no policy in it.
///
/// Asserts `keys` is non-empty. Allocation-free; O(n).
pub fn pickBest(keys: []const Key) usize {
    std.debug.assert(keys.len > 0);
    var best: usize = 0;
    for (keys[1..], 1..) |k, i| {
        // Strictly better only: an exact tie keeps the earlier candidate, which is the
        // better Phase-A proxy.
        if (k.lessThan(keys[best])) best = i;
    }
    return best;
}
