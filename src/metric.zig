//! Measuring a drawn layout: the lexicographic selection key, junction dots, and
//! the wire-versus-wire counts that feed both.
//!
//! ## What moves through here
//!
//! In: a `Physical` (device positions, pin points, the nested wire CSR) plus the
//! `pin_net` column it was drawn from. Out: integers — one `Key` per candidate
//! order, and one flat `[]Pt` of junction dots for the winner. Nothing here mutates
//! geometry; measurement is strictly downstream of routing, which is what lets the
//! candidate loop throw a whole placement away without unwinding anything.
//!
//! ## The key is a struct, not a number
//!
//! `Key` is compared **field by field, in declaration order**, and never collapsed
//! into a weighted sum. Two consequences worth stating because they are the point:
//!
//! - Reordering the fields is a *behaviour change*. The declaration order is the
//!   documented priority order from ALGORITHM.md, so the struct is the
//!   specification. This is intentional — a reviewer who moves `crossings` below
//!   `staples` has changed what the program considers a good drawing, and the diff
//!   shows it.
//! - No weight can trade one fault for another. A weighted sum would let three
//!   fewer staples pay for one more crossing, and there is no exchange rate between
//!   "reads as a false connection" and "is slightly more complicated". A crossing is
//!   a measured aesthetic fault; staples and span are proxies for complexity.
//!   Lexicographic ordering says so structurally.
//!
//! Every field is an integer. No float appears anywhere in place-and-route, so every
//! comparison is exact, every tie breaks the same way twice, and byte-reproducible
//! output falls out of the type rather than out of epsilon discipline.
//!
//! ## The counts are assertions, not filters
//!
//! `pin_hits`, `geom_shorts` and `body_hits` sit near the top of the key, yet on the
//! current fixture set they are zero for every weight setting ever tried. That is
//! the evidence for the claim in `route/lattice.zig`: collision is structural, so a
//! colliding route is unreachable in the search rather than drawn and then measured.
//! These fields exist to *catch a regression in that guarantee*. If one ever goes
//! non-zero the fix is in the lattice, never in the key.
//!
//! ## Junction dots are an arm count, not a topology query
//!
//! A dot means "these wires are connected"; its absence means they are not. Getting
//! it wrong changes what the schematic says. The rule is purely local: count the
//! same-net arms meeting at a point and emit a dot at three or more. A segment
//! endpoint contributes one arm, a segment passing through the point's interior
//! contributes two, and a device pin contributes one. Different-net wires never
//! contribute to each other's arm count, so a pure crossover is 2 + 2 across two
//! *different* nets, gets no dot, and correctly reads as not connected.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("ids.zig");
const irm = @import("ir.zig");

const NetIdx = ids.NetIdx;
const Pt = ids.Pt;
const Physical = irm.Physical;

/// The selection key. Lower is better, compared left to right.
///
/// Field order is priority order, from ALGORITHM.md, "Selection and determinism":
/// avoid a dropped-to-label net first, then a short, then a wire through a device
/// body, then wire-versus-wire faults, and only then staple count and span.
/// **Crossings outrank staples and span**, deliberately.
///
/// 48 bytes and trivially copyable, so the candidate loop keeps the best key by
/// value and never allocates to compare.
pub const Key = struct {
    /// Nets that proved unroutable and became name tags. Minimised first, which is
    /// what keeps the label fallback the exception it is documented to be.
    labels: u32,
    /// Wire segments touching a foreign net's pin point. A geometric-connectivity
    /// host merges a pin with any wire through it, so every hit is a short there.
    pin_hits: u32,
    /// Wire *vertices* of one net landing on another net's wire — a T-junction
    /// short. Downstream each straight run is one wire, so every vertex is an
    /// endpoint and merges with whatever it touches.
    geom_shorts: u32,
    /// Wire segments crossing a device body they do not belong to.
    body_hits: u32,
    /// Different-net segment pairs that are collinear and share more than a point.
    /// They draw as one wire and read as a false connection — worse than a crossing,
    /// hence ranked above it.
    overlaps: u32,
    /// Different-net perpendicular segment pairs whose interiors intersect. A real
    /// aesthetic fault, measured on the drawn geometry.
    crossings: u32,
    /// Signal nets spanning two or more column gaps — the wires that have to leave
    /// their neighbourhood.
    staples: u32,
    /// Total column span summed over those nets.
    total_span: u32,
    /// Non-backward signal nets that ended up in the top margin. The margin is for
    /// backward feedback; a forward net up there means the column order failed to
    /// keep it local. Observed rather than merely asserted (ALGORITHM.md, "Between
    /// spines").
    forward_margin: u32,
    /// Distinct margin rows any wire actually used.
    margin_tracks: u32,
    /// Final deterministic tie-break: a fold over the routed net ids in ascending
    /// order. Two candidate orders that are equal on every measured term still
    /// compare unequal here unless they routed exactly the same nets, so the winner
    /// never depends on iteration order or on which candidate happened to be
    /// evaluated first. See `netIdSeq`.
    netid_seq: u64,

    /// The key every candidate beats: every count saturated.
    ///
    /// Used to initialise the running best, so the first candidate always wins the
    /// first comparison without a separate "is this the first" branch.
    pub const worst: Key = .{
        .labels = std.math.maxInt(u32),
        .pin_hits = std.math.maxInt(u32),
        .geom_shorts = std.math.maxInt(u32),
        .body_hits = std.math.maxInt(u32),
        .overlaps = std.math.maxInt(u32),
        .crossings = std.math.maxInt(u32),
        .staples = std.math.maxInt(u32),
        .total_span = std.math.maxInt(u32),
        .forward_margin = std.math.maxInt(u32),
        .margin_tracks = std.math.maxInt(u32),
        .netid_seq = std.math.maxInt(u64),
    };

    /// Strict order on keys: field by field in declaration order, first difference
    /// decides.
    ///
    /// A **total order** — irreflexive, transitive, and total up to equality of
    /// every field — which is what `std.mem.sort` requires and what a
    /// tournament-style "keep the best" loop silently assumes. The `void` context
    /// parameter is there so this can be passed straight to `std.mem.sort`.
    ///
    /// Pure, allocation-free, branch-per-field.
    pub fn lessThan(_: void, a: Key, b: Key) bool {
        return order(a, b) == .lt;
    }

    /// Three-way comparison, for callers that need to distinguish "equal" from
    /// "not better" — the candidate loop does, so that an exact tie keeps the
    /// earlier candidate and the choice is not left to floating comparison order.
    pub fn order(a: Key, b: Key) std.math.Order {
        // Declaration order IS the priority order; the loop makes that literal, so
        // reordering the struct reorders the priorities and nothing else moves.
        inline for (@typeInfo(Key).@"struct".fields) |f| {
            const o = std.math.order(@field(a, f.name), @field(b, f.name));
            if (o != .eq) return o;
        }
        return .eq;
    }
};

/// Fold a net-id sequence into the key's final tie-break.
///
/// `nets` must be **ascending and deduplicated** — the caller sorts, because the
/// value has to be a function of the *set* of routed nets and not of the order they
/// were routed in. Asserted in safe builds.
///
/// FNV-1a over the little-endian net ids: order-sensitive by construction, which is
/// why the ascending precondition matters, and cheap enough to recompute per
/// candidate. Collisions are harmless — this term only ever breaks a tie between
/// candidates that were equal on every measured quantity, and two such candidates
/// that also collide here simply keep the earlier one.
///
/// Pure, allocation-free.
pub fn netIdSeq(nets: []const NetIdx) u64 {
    if (std.debug.runtime_safety) {
        var i: usize = 1;
        while (i < nets.len) : (i += 1) {
            std.debug.assert(@intFromEnum(nets[i]) > @intFromEnum(nets[i - 1]));
        }
    }
    var h: u64 = 0xcbf29ce484222325;
    for (nets) |n| {
        var v = @intFromEnum(n);
        for (0..4) |_| {
            h ^= v & 0xff;
            h *%= 0x100000001b3;
            v >>= 8;
        }
    }
    return h;
}

// ---------------------------------------------------------------------------
// Orthogonal segment predicates
//
// Here rather than in geom.zig because they are measurement, not placement: geom.zig
// answers "where does this symbol go", these answer "did two drawn things touch".
// Every one assumes axis-aligned segments, which the router guarantees.
// ---------------------------------------------------------------------------

/// Is `p` on the closed orthogonal segment `a`–`b`, endpoints included?
///
/// False for a non-orthogonal segment, which is a bug upstream rather than a case to
/// handle. A degenerate segment (`a == b`) contains only that point.
pub fn onSegment(p: Pt, a: Pt, b: Pt) bool {
    if (a.x == b.x) {
        if (a.y == b.y) return p.eql(a);
        return p.x == a.x and p.y >= @min(a.y, b.y) and p.y <= @max(a.y, b.y);
    }
    if (a.y != b.y) return false; // not orthogonal: a bug upstream, not a case
    return p.y == a.y and p.x >= @min(a.x, b.x) and p.x <= @max(a.x, b.x);
}

/// Is `p` strictly inside the orthogonal segment `a`–`b`, endpoints excluded?
///
/// The distinction from `onSegment` is load-bearing for junction dots: a wire whose
/// *end* is at a point contributes one arm, while a wire passing *through* it
/// contributes two. Confusing the two turns a corner into a dot or loses a real
/// T-junction.
pub fn onSegmentInterior(p: Pt, a: Pt, b: Pt) bool {
    if (a.x == b.x) {
        if (a.y == b.y) return false;
        return p.x == a.x and p.y > @min(a.y, b.y) and p.y < @max(a.y, b.y);
    }
    if (a.y != b.y) return false;
    return p.y == a.y and p.x > @min(a.x, b.x) and p.x < @max(a.x, b.x);
}

/// Junction dots: every point where three or more same-net wire arms meet.
///
/// Arms are counted at each candidate point of each net:
///
/// - a device pin of that net at the point: **one** arm each. Two coincident pins
///   therefore contribute two, which is correct — they are two conductors arriving.
/// - a segment with an endpoint at the point: **one** arm.
/// - a segment whose interior passes through the point: **two** arms.
///
/// Three or more means a dot. Two means a corner, or a wire reaching a pin, and gets
/// none. Nets are considered one at a time, so a different-net crossover never
/// accumulates arms and never gets a dot — which is exactly what makes it read as
/// *not connected*.
///
/// Candidates are the union of every segment endpoint and every pin point of the
/// net; an interior-only intersection cannot reach three arms without one of those
/// being present.
///
/// `pin_net` is the IR's pin→net column, parallel to `phys.pin_xy`; both are
/// borrowed. Net count is taken from `phys.net_seg.len - 1`.
///
/// Caller owns the returned slice and frees it with `gpa`. The result is sorted by
/// (x, y) and deduplicated, so it is byte-reproducible and a renderer can walk it
/// directly. Returns an empty slice when nothing is drawn.
///
/// Errors: `OutOfMemory`. Complexity: O(nets × (pins + segments × candidates));
/// `// ponytail: quadratic per net, fine at schematic scale — bucket the candidates
/// by coordinate if a thousand-net netlist ever shows up.`
pub fn junctions(
    gpa: Allocator,
    pin_net: []const NetIdx,
    phys: Physical,
) Allocator.Error![]Pt {
    var out: std.ArrayList(Pt) = .empty;
    errdefer out.deinit(gpa);
    if (phys.net_seg.len == 0) return out.toOwnedSlice(gpa);

    var cand: std.ArrayList(Pt) = .empty;
    defer cand.deinit(gpa);

    // One net at a time: arms never pool across nets, which is exactly what makes a
    // different-net crossover read as *not connected*.
    for (0..phys.net_seg.len - 1) |ni| {
        const net = NetIdx.at(ni);
        cand.clearRetainingCapacity();
        for (phys.net_seg[ni]..phys.net_seg[ni + 1]) |s| {
            for (phys.wire_pts[phys.seg_pt[s]..phys.seg_pt[s + 1]]) |p| try cand.append(gpa, p);
        }
        for (pin_net, phys.pin_xy) |pn, p| {
            if (pn == net) try cand.append(gpa, p);
        }
        std.mem.sort(Pt, cand.items, {}, ptLessXY);

        for (cand.items, 0..) |p, i| {
            if (i > 0 and cand.items[i - 1].eql(p)) continue;
            var arms: u32 = 0;
            for (pin_net, phys.pin_xy) |pn, q| {
                // Two coincident pins are two conductors arriving, and count twice.
                if (pn == net and q.eql(p)) arms += 1;
            }
            for (phys.net_seg[ni]..phys.net_seg[ni + 1]) |s| {
                const poly = phys.wire_pts[phys.seg_pt[s]..phys.seg_pt[s + 1]];
                for (poly[1..], poly[0 .. poly.len - 1]) |b, a| {
                    if (p.eql(a) or p.eql(b)) {
                        arms += 1; // an end arriving
                    } else if (onSegmentInterior(p, a, b)) {
                        arms += 2; // a wire passing through
                    }
                }
            }
            if (arms >= 3) try out.append(gpa, p);
        }
    }

    std.mem.sort(Pt, out.items, {}, ptLessXY);
    var w: usize = 0;
    for (out.items, 0..) |p, i| {
        if (i > 0 and out.items[w - 1].eql(p)) continue;
        out.items[w] = p;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);
    return out.toOwnedSlice(gpa);
}

/// Point order by (x, y) — the canonical form the junction and label lists use.
fn ptLessXY(_: void, a: Pt, b: Pt) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

/// Crossing and overlap counts over all different-net segment pairs.
///
/// A **crossing** is a perpendicular pair whose interiors intersect: `hx0 < vx <
/// hx1` and `vy0 < hy < vy1`, strictly, so two wires that merely meet end-to-end at
/// a point are not counted. An **overlap** is a collinear pair sharing a span of
/// positive length — touching at a single point is fine, but any shared run draws as
/// one wire and reads as a false connection, which is why overlaps outrank crossings
/// in the key.
///
/// Same-net pairs are skipped entirely: a net crossing itself is a routing artefact
/// the tree growth does not produce, and a net overlapping itself is just a
/// re-traced trunk.
///
/// Reads `phys.net_seg`, `phys.seg_pt` and `phys.wire_pts`. Zero-length segments are
/// ignored. Pure and allocation-free.
///
/// `// ponytail: O(n²) pair scan over segments — fine at schematic scale; a sweep
/// line if a netlist ever makes it not.`
pub fn countCrossingsAndOverlaps(phys: Physical) Counts {
    var c: Counts = .{ .crossings = 0, .overlaps = 0 };
    if (phys.net_seg.len == 0) return c;
    const nets = phys.net_seg.len - 1;

    for (0..nets) |ai| {
        for (phys.net_seg[ai]..phys.net_seg[ai + 1]) |as| {
            const pa = phys.wire_pts[phys.seg_pt[as]..phys.seg_pt[as + 1]];
            for (pa[1..], pa[0 .. pa.len - 1]) |a1, a0| {
                if (a0.eql(a1)) continue;
                for (ai + 1..nets) |bi| {
                    for (phys.net_seg[bi]..phys.net_seg[bi + 1]) |bs| {
                        const pb = phys.wire_pts[phys.seg_pt[bs]..phys.seg_pt[bs + 1]];
                        for (pb[1..], pb[0 .. pb.len - 1]) |b1, b0| {
                            if (b0.eql(b1)) continue;
                            switch (classify(a0, a1, b0, b1)) {
                                .none => {},
                                .crossing => c.crossings += 1,
                                .overlap => c.overlaps += 1,
                            }
                        }
                    }
                }
            }
        }
    }
    return c;
}

const Fault = enum { none, crossing, overlap };

/// Classify one different-net pair of non-degenerate orthogonal segments.
fn classify(a0: Pt, a1: Pt, b0: Pt, b1: Pt) Fault {
    const a_h = a0.y == a1.y;
    const b_h = b0.y == b1.y;
    if (a_h == b_h) {
        // Parallel. Only a shared run of positive length draws as one wire; meeting
        // at a single point is fine.
        if (a_h) {
            if (a0.y != b0.y) return .none;
            const lo = @max(@min(a0.x, a1.x), @min(b0.x, b1.x));
            const hi = @min(@max(a0.x, a1.x), @max(b0.x, b1.x));
            return if (hi > lo) .overlap else .none;
        }
        if (a0.x != b0.x) return .none;
        const lo = @max(@min(a0.y, a1.y), @min(b0.y, b1.y));
        const hi = @min(@max(a0.y, a1.y), @max(b0.y, b1.y));
        return if (hi > lo) .overlap else .none;
    }
    // Perpendicular: strict interior intersection only, so end-to-end meetings are
    // not counted.
    const h0 = if (a_h) a0 else b0;
    const h1 = if (a_h) a1 else b1;
    const v0 = if (a_h) b0 else a0;
    const v1 = if (a_h) b1 else a1;
    const hit = v0.x > @min(h0.x, h1.x) and v0.x < @max(h0.x, h1.x) and
        h0.y > @min(v0.y, v1.y) and h0.y < @max(v0.y, v1.y);
    return if (hit) .crossing else .none;
}

/// The pair of counts `countCrossingsAndOverlaps` produces.
pub const Counts = struct {
    crossings: u32,
    overlaps: u32,
};
