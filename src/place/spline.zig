//! Spline extraction: decomposing a schematic into conduction paths from VDD to
//! ground.
//!
//! A **spline** is one path a current can take from a power net down to a ground
//! net, naming every device it passes through in conduction order. ALGORITHM.md's
//! core idea is that a circuit *is* a set of splines, that each becomes a column,
//! and that layout is then only two problems — stacking inside a column and wiring
//! between them. This file produces that set. Everything downstream is a
//! consequence of it.
//!
//! What moves through here:
//!
//! ```
//! Ctx.gnd_dist  (BFS hop count per net)
//!   + power nets (or, rail-less, the hot nets of independent sources)
//!   -> seeds: the non-rail devices touching each power net, ascending
//!   -> walkDown: steepest descent on gnd_dist, conducting pins only
//!   -> dedup + sort by lowest device index
//!   -> SplineSet (CSR)
//! ```
//!
//! ## The BFS is not here
//!
//! Ground distance is computed once in `ctx.zig` and merely *read* here, because
//! ALGORITHM.md's Tier-A table lists it as topology-invariant. It has no dependence
//! on column order, so recomputing it per candidate would be the exact drift the
//! tier split exists to prevent. This file's contribution is the walk, not the
//! field the walk descends.
//!
//! ## Why steepest descent rather than a path search
//!
//! A conduction path is not just any route through the graph — it is the one a
//! designer would draw top to bottom. Descending `gnd_dist` gets that for free:
//! from any node, step to the neighbour whose *far* terminal is strictly closer to
//! ground. No backtracking, no path enumeration, and the result is a chain, which is
//! what a column has to be. Ties break on the lower device index so two runs over
//! the same netlist produce byte-identical splines.
//!
//! ## The one exception: plateau crossing
//!
//! Strict descent stalls when ground is reachable from *both* ends of a passive
//! ladder — a source shorting the seed end makes the watershed nets in the middle
//! tie on distance, and no neighbour is strictly closer. Breaking there would split
//! one ladder into several one-device splines. So when strict descent finds nothing
//! and there is exactly **one** unvisited neighbour at the same distance, the walk
//! crosses it. One, not any: a plain series chain has a unique continuation, while a
//! genuine fork at a plateau is a branch point and must not be guessed.
//!
//! ## Determinism
//!
//! Seeds are collected, sorted by device index and deduplicated before walking, and
//! the final set is sorted by each spline's minimum device index. No hash map is
//! iterated anywhere in this file. Two runs over the same bytes therefore emit the
//! same splines in the same order, which is what makes the whole selection key
//! reproducible (ARCHITECTURE.md §7).
//!
//! ## Lifetime
//!
//! The `SplineSet` is **per-document**, like `Ctx`: the *set* is fixed and only its
//! order is searched, so it is built once from the `doc` arena and read by every
//! candidate order. Allocating it from `search` would destroy it on the first reset.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const ctxm = @import("ctx.zig");

const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const Ctx = ctxm.Ctx;
const SplineIdx = ctxm.SplineIdx;

/// spline → its devices, power end first, ground end last.
///
/// Re-exported from `ctx.zig`, where the index space is declared so that
/// `Ctx.branchCounts` can name it without importing this file. Same type, one
/// definition.
pub const SplineSet = ctxm.SplineSet;

/// An adjacent pair inside one spline whose order is free to flip.
///
/// `at` is the position of the *upper* device of the pair, so the swap exchanges
/// positions `at` and `at + 1` of spline `spline`. Two entries, not a range: the
/// order search treats each pair as an independent on/off bit.
pub const Swap = struct {
    spline: SplineIdx,
    at: u32,
};

/// Extract every VDD→GND conduction path in the schematic.
///
/// Seeds from each power net in ascending net order: the non-rail devices touching
/// it, sorted by device index and deduplicated, each walked down to ground. A shared
/// device (a differential pair's tail, a mirror's reference leg) is reached by
/// several walks and therefore appears on several splines — that recurrence is what
/// `Ctx.branchCounts` later counts, so it is deliberate and must not be filtered out.
///
/// **Rail-less fallback.** A circuit with no supply symbol at all (an RC filter, a
/// bridge, anything source-driven) produces no splines from the power pass. Rather
/// than dropping every device into the leftover horizontal pass, the walk re-seeds
/// from the non-ground conducting nets of each independent source (SPICE prefix `V`
/// or `I`): there, the source *is* the rail. If that also yields nothing — a genuine
/// pass-transistor network with neither rails nor sources — the result is legitimately
/// empty and `column.zig` places every device as a `signal_series` column.
///
/// Post-conditions: splines are sorted ascending by their minimum device index and
/// no spline is empty. A device may appear on several splines but never twice within
/// one. The walk is bounded — a cycle in the conduction graph terminates after at
/// most `deviceCount() + 2` steps rather than looping.
///
/// Caller owns the result and must `deinit` it with `gpa`; see the module header for
/// which arena that should be.
///
/// Errors: `OutOfMemory` only. Complexity: O(seeds x path length) walks over data
/// already in cache, plus one sort of the spline list.
pub fn extract(gpa: Allocator, c: Ctx) Allocator.Error!SplineSet {
    const nd = c.deviceCount();

    // One walk buffer, reused by every seed: `walkDown` never allocates.
    const chain = try gpa.alloc(DeviceIdx, nd + 2);
    defer gpa.free(chain);
    const seeds = try gpa.alloc(DeviceIdx, nd + 1);
    defer gpa.free(seeds);

    // Flat spline values plus one start offset per spline; the pair becomes the CSR
    // once the splines are sorted.
    var vals: std.ArrayList(DeviceIdx) = .empty;
    defer vals.deinit(gpa);
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(gpa);

    const power = try c.powerNets(gpa);
    defer gpa.free(power);
    for (power) |pnet| try seedFrom(gpa, c, pnet, seeds, chain, &vals, &starts);

    if (starts.items.len == 0) {
        const hot = try sourceHotNets(gpa, c);
        defer gpa.free(hot);
        for (hot) |n| try seedFrom(gpa, c, n, seeds, chain, &vals, &starts);
    }

    // Sort by each spline's minimum device index. A stable sort over an explicit key
    // keeps two runs identical; nothing here has been near a hash map.
    const n_spl = starts.items.len;
    const perm = try gpa.alloc(u32, n_spl);
    defer gpa.free(perm);
    const min_dev = try gpa.alloc(u32, n_spl);
    defer gpa.free(min_dev);
    for (0..n_spl) |s| {
        perm[s] = @intCast(s);
        const lo = starts.items[s];
        const hi = if (s + 1 < n_spl) starts.items[s + 1] else @as(u32, @intCast(vals.items.len));
        var m: u32 = std.math.maxInt(u32);
        for (vals.items[lo..hi]) |d| m = @min(m, @intFromEnum(d));
        min_dev[s] = m;
    }
    const By = struct {
        keys: []const u32,
        fn lessThan(self: @This(), a: u32, b: u32) bool {
            return self.keys[a] < self.keys[b];
        }
    };
    std.mem.sort(u32, perm, By{ .keys = min_dev }, By.lessThan);

    const offsets = try gpa.alloc(u32, n_spl + 1);
    errdefer gpa.free(offsets);
    const values = try gpa.alloc(DeviceIdx, vals.items.len);
    errdefer gpa.free(values);
    var w: u32 = 0;
    for (perm, 0..) |s, k| {
        offsets[k] = w;
        const lo = starts.items[s];
        const hi = if (s + 1 < n_spl) starts.items[s + 1] else @as(u32, @intCast(vals.items.len));
        for (vals.items[lo..hi]) |d| {
            values[w] = d;
            w += 1;
        }
    }
    offsets[n_spl] = w;
    return .{ .offsets = offsets, .values = values };
}

/// Walk every non-rail device touching `net`, in ascending device order, and append
/// each resulting chain to the flat spline list.
///
/// `seeds` and `chain` are scratch buffers owned by `extract`; `vals` and `starts`
/// accumulate the result. Deduplicating the seeds is what keeps a two-pin device on a
/// power net from producing the same spline twice.
fn seedFrom(
    gpa: Allocator,
    c: Ctx,
    net: NetIdx,
    seeds: []DeviceIdx,
    chain: []DeviceIdx,
    vals: *std.ArrayList(DeviceIdx),
    starts: *std.ArrayList(u32),
) Allocator.Error!void {
    var n: usize = 0;
    for (c.members(net)) |p| {
        const d = c.devOf(p);
        if (c.isRail(d)) continue;
        seeds[n] = d;
        n += 1;
    }
    const list = seeds[0..n];
    std.mem.sort(DeviceIdx, list, {}, struct {
        fn lt(_: void, a: DeviceIdx, b: DeviceIdx) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.lt);
    var prev: ?DeviceIdx = null;
    for (list) |d| {
        if (prev != null and prev.? == d) continue;
        prev = d;
        const walked = walkDown(c, d, net, chain);
        if (walked.len == 0) continue;
        try starts.append(gpa, @intCast(vals.items.len));
        try vals.appendSlice(gpa, walked);
    }
}

/// Follow conduction pins from `start` toward ground by steepest descent.
///
/// `from` is the net the walk arrives on — the power net for a seed — and is what
/// stops the first step from immediately going back the way it came. `out` is a
/// caller-supplied scratch buffer that must hold at least `c.deviceCount() + 2`
/// entries; the returned chain is a **prefix of `out`**, borrowed, valid until the
/// caller reuses the buffer. Taking a buffer rather than allocating is what lets
/// `extract` run every seed through one allocation.
///
/// Each step: find this device's conducting pin whose net differs from `from`; if
/// that net is ground, stop. Otherwise consider every other non-rail device with a
/// *conducting* pin on it, look at that device's own far conducting net, and step to
/// the one whose ground distance is strictly smaller — ties on distance broken by the
/// lower device index. If nothing is strictly closer and exactly one unvisited
/// neighbour sits at the same distance, cross that plateau (see the module header);
/// otherwise stop.
///
/// Edge cases: a device with fewer than two conducting pins ends the chain
/// immediately after itself, so a dangling one-terminal element still yields a
/// one-device spline. A floating exit net ends the chain. The `guard` bound means a
/// conduction cycle produces a truncated chain rather than hanging.
///
/// Returns at least one device — `start` itself — so the result is never empty.
/// Allocation-free.
pub fn walkDown(c: Ctx, start: DeviceIdx, from: NetIdx, out: []DeviceIdx) []const DeviceIdx {
    std.debug.assert(out.len >= c.deviceCount() + 2);
    var n: usize = 0;
    var dev = start;
    var arrived = from;
    while (true) {
        out[n] = dev;
        n += 1;
        // The bound, not a cycle check: a conduction cycle truncates rather than hangs.
        if (n == out.len) break;

        const exit = exitPin(c, dev, arrived) orelse break;
        const next = c.netOf(exit);
        if (next == .none) break;
        if (c.isGround(next)) break;

        const here = c.groundDistance(next);
        var best_dist: u32 = undefined;
        var best: DeviceIdx = .none;
        var level: DeviceIdx = .none;
        var level_count: usize = 0;
        for (c.members(next)) |pin| {
            const d2 = c.devOf(pin);
            if (d2 == dev or c.isRail(d2) or !c.conducts(pin)) continue;
            const far_dist = if (exitPin(c, d2, next)) |q| blk: {
                const f = c.netOf(q);
                break :blk if (f == .none) Ctx.unreachable_dist else c.groundDistance(f);
            } else Ctx.unreachable_dist;

            if (far_dist == here and !contains(out[0..n], d2)) {
                level = d2;
                level_count += 1;
            }
            if (far_dist >= here) continue;
            if (best == .none or far_dist < best_dist or
                (far_dist == best_dist and @intFromEnum(d2) < @intFromEnum(best)))
            {
                best_dist = far_dist;
                best = d2;
            }
        }
        // Plateau crossing: ground reachable from both ends of a passive ladder ties
        // the watershed nets, so strict descent stalls. One continuation is a series
        // chain and is crossed; a fork is a branch point and is not guessed.
        if (best == .none and level_count == 1) best = level;
        if (best == .none) break;
        dev = best;
        arrived = next;
    }
    return out[0..n];
}

/// `d`'s first conducting pin whose net differs from the one the walk arrived on.
fn exitPin(c: Ctx, d: DeviceIdx, arrived: NetIdx) ?PinIdx {
    for (c.conductingPins(d)) |p| {
        if (c.netOf(p) != arrived) return p;
    }
    return null;
}

fn contains(list: []const DeviceIdx, d: DeviceIdx) bool {
    for (list) |x| {
        if (x == d) return true;
    }
    return false;
}

/// The non-ground conducting nets of every independent source, ascending and
/// deduplicated.
///
/// A source's hot node is the rail of a rail-less circuit, so these are the seeds the
/// fallback in `extract` uses. Selection is by the class's SPICE prefix (`V` or `I`)
/// and never by name. Ground nets are excluded because seeding a walk *at* ground
/// would terminate it on its first step.
///
/// Caller owns the returned slice and frees it with `gpa`. Empty when the schematic
/// has no independent source.
pub fn sourceHotNets(gpa: Allocator, c: Ctx) Allocator.Error![]NetIdx {
    var out: std.ArrayList(NetIdx) = .empty;
    errdefer out.deinit(gpa);
    for (0..c.deviceCount()) |di| {
        const d = DeviceIdx.at(di);
        if (c.isRail(d)) continue;
        const prefix = c.classOf(d).prefix;
        if (prefix != 'V' and prefix != 'I') continue;
        for (c.conductingPins(d)) |p| {
            const n = c.netOf(p);
            if (n == .none or c.isGround(n)) continue;
            try out.append(gpa, n);
        }
    }
    const list = out.items;
    std.mem.sort(NetIdx, list, {}, struct {
        fn lt(_: void, a: NetIdx, b: NetIdx) bool {
            return @intFromEnum(a) < @intFromEnum(b);
        }
    }.lt);
    // Dedup in place; the tail is trimmed by `toOwnedSlice` shrinking below.
    var w: usize = 0;
    for (list, 0..) |n, k| {
        if (k > 0 and n == list[w - 1]) continue;
        list[w] = n;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);
    return out.toOwnedSlice(gpa);
}

/// Adjacent same-class, same-value device pairs inside a spline, whose order the
/// circuit does not care about.
///
/// Two series devices of identical symbol and identical value text connected
/// drain→source are electrically interchangeable, so the placer is free to try both
/// orders. ALGORITHM.md calls the win "rare but near-zero cost": flipping a pair may
/// align a gate tap with a neighbour column's pin and save a crossing, and detecting
/// it is a comparison of two `StrId`s.
///
/// Detection is Tier A — it depends only on the spline set, so the result is computed
/// once and reused by every candidate order. The *swap* itself is applied in
/// `order.zig`, as a bit in a mask; nothing here mutates the spline set.
///
/// Caller owns the returned slice, sorted by `(spline, at)`, and frees it with `gpa`.
/// Empty when no spline holds two matching neighbours, which is the common case.
pub fn swappablePairs(gpa: Allocator, c: Ctx, splines: SplineSet) Allocator.Error![]Swap {
    var out: std.ArrayList(Swap) = .empty;
    errdefer out.deinit(gpa);
    const ir = c.ir;
    for (0..splines.keyCount()) |si| {
        const devs = splines.slice(SplineIdx.at(si));
        if (devs.len < 2) continue;
        for (devs[0 .. devs.len - 1], 0..) |a, i| {
            const b = devs[i + 1];
            if (ir.dev_symbol[a.i()] != ir.dev_symbol[b.i()]) continue;
            if (ir.dev_value[a.i()] != ir.dev_value[b.i()]) continue;
            try out.append(gpa, .{ .spline = SplineIdx.at(si), .at = @intCast(i) });
        }
    }
    return out.toOwnedSlice(gpa);
}
