//! Geometry: y inside a column, y between columns, how wide each gap is, and where
//! each column's axis lands.
//!
//! Four phases, run in order, each a pure function of the one before:
//!
//! ```
//! Phase 1  stackColumns  -> dev_y[]      interior y, optimal_len gaps, shared row profile
//! Phase 2  alignColumns  -> col_offset[] rigid vertical shift per column
//! Phase 3  gapLanes      -> lanes[]      wire tracks reserved per inter-column gap
//! Phase 4  placeColumns  -> col_x[], lane_x  column axes and the tracks inside each gap
//! ```
//!
//! All of it is Tier B: order-dependent, route-invariant, integer-only. No wire has
//! been drawn when this runs, and none of these numbers is revised afterwards —
//! channel width is a *conservative forward reservation*, not a measurement, which is
//! what lets ALGORITHM.md promise that a route always has somewhere to go and that
//! there is no unwire-then-rewire anywhere.
//!
//! ## Phase 1: `optimal_len`, and what the `- 1` is for
//!
//! ```
//! optimal_len = N - (pins in the same column) - 1
//! ```
//!
//! `N` is the net's degree. The subtrahend is how many of those pins are already in
//! this column, and the `- 1` removes the direct conduction link between the two
//! stacked neighbours — *that connection is the stacking itself*, not an external tap
//! that needs room. What remains is the number of outside taps that have to reach
//! this node, and each is granted one `tap_unit` of vertical room. **When
//! `optimal_len` is 0 the devices abut**, which is the common case and the reason a
//! two-device spline is tight rather than airy.
//!
//! Two conditions bypass the formula and return `abut_gap` instead: a *flat* device
//! (both conduction pins on one row, so there is no vertical link to absorb taps at
//! all) and a pair whose facing terminals are not on the same net (stacked but not
//! series — matching *any* shared net instead would wrongly abut antiparallel
//! devices, whose far terminals share a net without forming a conduction link).
//!
//! ## Phase 1, the load-bearing part: EQUAL-DEPTH SPLINE COLUMNS SHARE ONE ROW PROFILE
//!
//! This is the single most consequential rule in this file, so it is stated in full.
//!
//! `optimal_len` is a *per-column* quantity. A node in one branch that needs an escape
//! lane produces a larger gap, and that gap shifts every row below it — **in that
//! column only**. A net that taps the same logical row of two parallel branches then
//! has no single row to run along: it staircases, and because the router grows a
//! multi-terminal net as a tree from wherever it already is, the net's remaining
//! terminals join wherever the tree happened to arrive. The visible symptom is a
//! differential pair's tail joining at the left branch instead of at the midpoint
//! between the two.
//!
//! So: **spline columns of equal depth are stacked as one group.** At each depth `k`,
//! the row height and the gap below it are the elementwise maximum over every column
//! in the group, and device `k` of every branch therefore starts at the same `y`. A
//! shared row is then genuinely a row — one horizontal trunk, with the hub's riser
//! dropping at its own column axis, which for an `N = 2` shared column *is* the
//! midpoint between the branches.
//!
//! The cost was measured rather than assumed: +0.5% total area and +4 corners over the
//! fixture set, against -76 units of wire in `two_stage_miller`, and the tail net of
//! every differential structure collapsing to one line and one drop. It also buys the
//! mirror-consistency in **y** that ALGORITHM.md's "Known gaps" section reports as
//! achieved (x remains a gap).
//!
//! Only `.spline` columns group, and only with equal device counts. A `.shared`,
//! `.component`, `.feedback` or `.signal_series` column stacks alone: it holds
//! satellites or a hub whose rows correspond to nothing in any branch, so forcing it
//! into a profile would pad it for no reader benefit.
//!
//! ## Phase 3: what reserves a lane, and what deliberately does not
//!
//! One lane per `.immediate` **signal** net, in each gap it crosses. That is it.
//!
//! - **Rails reserve nothing.** They run on their own bus rows and are never routed as
//!   per-net wires, so counting them would widen every channel for wires that never
//!   appear in one.
//! - **`.within_column` reserves nothing.** It has no gap to cross.
//! - **`.span_ge2` reserves nothing**, and this one was measured, not assumed:
//!   reserving a lane at each endpoint gap widened every wide circuit by roughly 5% of
//!   its area to guarantee room the router did not use, because a spanning net usually
//!   leaves on a row it already occupies rather than needing a fresh vertical track. If
//!   the router genuinely needs another track it takes a body edge or a column axis,
//!   which are lattice coordinates too.
//!
//! Gap width is then `track_w * (lanes + 1)`. The `+ 1` is a floor of one wire gauge,
//! so every gap has somewhere for a riser to run even when nothing was reserved in it.
//! There is no fixed channel base beyond that floor.
//!
//! What is *not* here any more, and must not come back: per-side riser-lane assignment
//! and up-front margin-track packing. Both committed to a lane before knowing what else
//! wanted it. Placement's job is to guarantee that *enough* lanes exist; which wire
//! uses which is the router's, priced on the lattice against everything else competing
//! for the same space.
//!
//! ## Lifetime
//!
//! Every array here is **per-candidate-order** — allocate from the `search` arena.
//! Only the winner's device positions survive, and they are rebuilt into the `out`
//! arena as `Physical.pos`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const Csr = @import("../csr.zig").Csr;
const Config = @import("../config.zig").Config;
const ctxm = @import("ctx.zig");
const colm = @import("column.zig");
const geom = @import("../geom.zig");
const catalog = @import("../devices/catalog.zig");

const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;
const Ctx = ctxm.Ctx;
const Columns = colm.Columns;
const ColumnIdx = colm.ColumnIdx;
const NetInfos = colm.NetInfos;

/// A band of vertical routing tracks.
///
/// The index space is `columns + 1` wide and offset by one relative to `lanes`,
/// because a route may need to wrap around the outside of the field:
///
/// - `0` — the band immediately left of the first column
/// - `g + 1` — the gap between column `g` and column `g + 1`
/// - `columns` — the band immediately right of the last column
///
/// The offset is stated here because it is the one place in `place/` where two
/// closely related arrays are indexed differently, and getting it wrong shifts every
/// track by one gap without producing an obviously broken drawing.
pub const TrackIdx = enum(u32) {
    _,

    pub fn i(t: TrackIdx) usize {
        return @intFromEnum(t);
    }

    pub fn at(n: usize) TrackIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }

    /// The track band inside the gap between column `g` and column `g + 1`.
    pub fn inGap(g: usize) TrackIdx {
        return TrackIdx.at(g + 1);
    }
};

/// The finished geometric skeleton for one candidate order.
///
/// Owns every array. Allocate from the `search` arena; `deinit` is correct under any
/// allocator so tests can audit it.
pub const Stacked = struct {
    /// Interior y of every device within its own column, before the column offset is
    /// applied. Indexed by `DeviceIdx`; 0 for rails and unplaced devices.
    dev_y: []i32,
    /// Rigid vertical shift per column, from Phase 2. Indexed by `ColumnIdx`.
    col_offset: []i32,
    /// Reserved wire tracks per inter-column gap. Length `columns - 1` (empty for a
    /// single-column layout); `lanes[g]` is the gap between column `g` and `g + 1`.
    lanes: []u32,
    /// Half-width of each column: the widest oriented half-extent of any device in it,
    /// floored at the standard half cell so builtin columns pitch uniformly.
    col_half: []i32,
    /// x of each column's axis. Indexed by `ColumnIdx`. A `.feedback` column takes its
    /// predecessor's x, since it occupies no field width.
    col_x: []i32,
    /// Available track x's per band. See `TrackIdx` for the off-by-one index space.
    lane_x: Csr(TrackIdx, i32),

    pub const empty: Stacked = .{
        .dev_y = &.{},
        .col_offset = &.{},
        .lanes = &.{},
        .col_half = &.{},
        .col_x = &.{},
        .lane_x = .empty,
    };

    pub fn deinit(self: *Stacked, gpa: Allocator) void {
        gpa.free(self.dev_y);
        gpa.free(self.col_offset);
        gpa.free(self.lanes);
        gpa.free(self.col_half);
        gpa.free(self.col_x);
        self.lane_x.deinit(gpa);
        self.dev_y = &.{};
        self.col_offset = &.{};
        self.lanes = &.{};
        self.col_half = &.{};
        self.col_x = &.{};
    }

    /// Absolute y of `d`: its column's offset plus its interior y.
    ///
    /// This is the composition Phase 1 and Phase 2 exist to produce, and the only
    /// correct way to combine them — reading `dev_y` alone gives a device's position
    /// relative to a column that has since been shifted.
    pub fn absY(self: Stacked, cols: Columns, d: DeviceIdx) i32 {
        const col = cols.column_of[d.i()];
        if (col == .none) return self.dev_y[d.i()];
        return self.col_offset[col.i()] + self.dev_y[d.i()];
    }
};

/// Run all four phases and return the finished skeleton.
///
/// The convenience form. `infos` must have been built against the same `cols`, and
/// `orient` against the same `cols` too — mismatched inputs produce a plausible-looking
/// drawing with wires that miss their pins, so both are asserted by length.
///
/// Caller owns the result and must `deinit` it. Errors: `OutOfMemory` only.
pub fn run(
    gpa: Allocator,
    c: Ctx,
    cols: Columns,
    infos: NetInfos,
    orient: []const Orient,
    cfg: *const Config,
) Allocator.Error!Stacked {
    std.debug.assert(orient.len == c.deviceCount());
    std.debug.assert(infos.count() == infos.case.len);

    const dev_y = try stackColumns(gpa, c, cols, orient, cfg);
    errdefer gpa.free(dev_y);
    const col_offset = try alignColumns(gpa, c, cols, infos, dev_y, orient);
    errdefer gpa.free(col_offset);
    const lanes = try gapLanes(gpa, c, cols, infos);
    errdefer gpa.free(lanes);
    const placed = try placeColumns(gpa, c, cols, orient, lanes, cfg);
    return .{
        .dev_y = dev_y,
        .col_offset = col_offset,
        .lanes = lanes,
        .col_half = placed[0],
        .col_x = placed[1],
        .lane_x = placed[2],
    };
}

/// Phase 1 — interior y of every device within its column.
///
/// Top-down stacking with `optimalLen` gaps, and the shared row profile described at
/// length in the module header: `.spline` columns of equal device count are stacked as
/// one group, so at each depth the gap above and the row height are the elementwise
/// maxima over the group and device `k` of every column in the group gets the identical
/// `y`. Every other column stacks by itself.
///
/// Device origins are quantized up to `cfg.layout.grid`, so that a pin — origin plus
/// the class's anchor offset — stays on the host grid. Body extents are draw-derived
/// and are *not* grid multiples, which is why the quantization is applied to the origin
/// and not to the box.
///
/// Post-conditions: within a column, `dev_y` is non-decreasing in stack position; for
/// any two equal-depth `.spline` columns `a` and `b`, `dev_y[a.devices[k]] ==
/// dev_y[b.devices[k]]` for every `k`. That second one is the property to test —
/// a per-column implementation satisfies everything else and fails only this.
///
/// Caller owns the returned slice (length `c.deviceCount()`) and frees it with `gpa`.
/// Errors: `OutOfMemory` only.
pub fn stackColumns(
    gpa: Allocator,
    c: Ctx,
    cols: Columns,
    orient: []const Orient,
    cfg: *const Config,
) Allocator.Error![]i32 {
    const dev_y = try gpa.alloc(i32, c.deviceCount());
    errdefer gpa.free(dev_y);
    @memset(dev_y, 0);

    const ncol = cols.count();
    const done = try gpa.alloc(bool, ncol);
    defer gpa.free(done);
    @memset(done, false);

    const group = try gpa.alloc(ColumnIdx, ncol);
    defer gpa.free(group);

    for (0..ncol) |i| {
        if (done[i]) continue;
        // EQUAL-DEPTH SPLINE COLUMNS SHARE ONE ROW PROFILE. Every other column stacks
        // alone: its rows correspond to nothing in any branch, so padding it to a
        // profile buys no reader anything.
        const depth = cols.dev.count(ColumnIdx.at(i));
        var n: usize = 0;
        if (cols.kind[i] == .spline) {
            for (i..ncol) |j| {
                if (cols.kind[j] != .spline) continue;
                if (cols.dev.count(ColumnIdx.at(j)) != depth) continue;
                done[j] = true;
                group[n] = ColumnIdx.at(j);
                n += 1;
            }
        } else {
            done[i] = true;
            group[0] = ColumnIdx.at(i);
            n = 1;
        }
        const g = group[0..n];

        var top: i32 = 0;
        for (0..depth) |k| {
            if (k > 0) {
                var gap: i32 = 0;
                for (g) |col| {
                    const devs = cols.devices(col);
                    gap = @max(gap, optimalLen(c, cols, orient, devs[k - 1], devs[k], cfg));
                }
                top += gap;
            }
            var next = top;
            for (g) |col| {
                const d = cols.devices(col)[k];
                const r = orientedBox(c, orient, d);
                // Quantize the *origin*: body extents are draw-derived and are not
                // grid multiples, but a pin is origin plus anchor and must land on it.
                dev_y[d.i()] = snapCeil(top - r.min.y, cfg.layout.grid);
                next = @max(next, dev_y[d.i()] + r.max.y);
            }
            top = next;
        }
    }
    return dev_y;
}

/// Vertical room between two devices stacked directly on top of each other, in grid
/// units.
///
/// `a` is above `b`, both in the same column. The link net is the one joining `a`'s
/// **lowest** oriented conducting terminal to `b`'s **highest** — the facing pair, not
/// merely any net the two share.
///
/// ```
/// optimal_len = max(0, degree(link) - pins_of_link_in_this_column - 1) * tap_unit
/// ```
///
/// Returns exactly 0 when the formula clamps to zero, which is the abutment case
/// ALGORITHM.md names: the two symbols touch. It returns `cfg.layout.abut_gap` instead
/// — a *positive* gap — in the two cases where the formula does not apply: either
/// device is flat (both conduction pins on one row, no vertical link to absorb taps),
/// or the facing terminals are not on a common net.
///
/// One host accommodation, and it is a real one rather than a rounding: on a grid host
/// (`cfg.layout.grid > 1`) pins connect only through drawn wire, so a coincident pin
/// pair reads as two dangling terminals. The result is therefore floored at one grid
/// step there, leaving something drawable between them. On an ungridded host (`grid <=
/// 1`) a true zero is returned and the symbols genuinely abut.
///
/// Pure function of `Ctx`, `Columns`, `orient` and `cfg`; allocation-free.
pub fn optimalLen(
    c: Ctx,
    cols: Columns,
    orient: []const Orient,
    a: DeviceIdx,
    b: DeviceIdx,
    cfg: *const Config,
) i32 {
    // A flat device has both conduction pins on one row: there is no vertical link to
    // absorb taps, so stacked neighbours simply abut.
    if (isFlat(c, orient, a) or isFlat(c, orient, b)) return cfg.layout.abut_gap;

    const low_a = extremeTerm(c, orient, a, .lowest);
    const high_b = extremeTerm(c, orient, b, .highest);
    if (low_a == .none or high_b == .none) return cfg.layout.abut_gap;
    const na = c.netOf(low_a);
    const nb = c.netOf(high_b);
    // The link is the net between the *facing* terminals. Matching any shared net
    // would wrongly abut antiparallel devices, whose far terminals share a net
    // without forming a conduction link.
    if (na == .none or na != nb) return cfg.layout.abut_gap;

    const col = cols.column_of[a.i()];
    var in_col: i32 = 0;
    for (c.members(na)) |p| {
        if (cols.column_of[c.devOf(p).i()] == col) in_col += 1;
    }
    const taps = @max(0, @as(i32, @intCast(c.degree(na))) - in_col - 1);
    const len = taps * cfg.layout.tap_unit;
    // On a grid host pins connect only through drawn wire, so a coincident pair reads
    // as two dangling terminals: leave one step of something to draw.
    const g = cfg.layout.grid;
    return if (g > 1) @max(len, g) else len;
}

/// Phase 2 — one rigid vertical offset per column.
///
/// Column 0 sits at zero. For each adjacent pair, one pin alignment is chosen and the
/// right column is shifted so those two pins share a y, which hands the router a
/// zero-bend straight run to find. Candidates, in priority order:
///
/// 1. If the right column is a `.component`, any **signal** net with a representative
///    pin in both columns, preferring a local net over a spanning one — a spanning
///    net's channel is free to move, a local run is not.
/// 2. Otherwise, an `.immediate` net whose highest column is exactly the right one.
///
/// Among candidates the topmost pin pair wins, with the net index as the final
/// tie-break so the choice is reproducible. A pair with no candidate inherits the left
/// column's offset unchanged, which keeps unrelated columns from drifting apart.
///
/// Caller owns the returned slice (length `cols.count()`) and frees it with `gpa`.
/// Errors: `OutOfMemory` only.
pub fn alignColumns(
    gpa: Allocator,
    c: Ctx,
    cols: Columns,
    infos: NetInfos,
    dev_y: []const i32,
    orient: []const Orient,
) Allocator.Error![]i32 {
    const ncol = cols.count();
    const offset = try gpa.alloc(i32, ncol);
    errdefer gpa.free(offset);
    @memset(offset, 0);

    var g: usize = 0;
    while (ncol > 0 and g < ncol - 1) : (g += 1) {
        var have = false;
        var best_span = false;
        var best_top: i32 = 0;
        var best_net: u32 = 0;
        var best_pi: PinIdx = .none;
        var best_pj: PinIdx = .none;
        var best_base: usize = 0;

        for (0..infos.count()) |xi| {
            const x = colm.InfoIdx.at(xi);
            const lo, const hi = infos.span(x);
            var span_cand = false;
            var pi: PinIdx = .none;
            var pj: PinIdx = .none;
            var base: usize = 0;

            // A component column aligns to any signal net with a pin on both sides,
            // preferring a local net: a spanning net's channel is free to move.
            if (cols.kind[g + 1] == .component and !c.isRailNet(infos.net[xi])) {
                const a = infos.repIn(x, ColumnIdx.at(g));
                const b = infos.repIn(x, ColumnIdx.at(g + 1));
                if (a != .none and b != .none) {
                    span_cand = infos.case[xi] == .span_ge2;
                    pi = a;
                    pj = b;
                    base = g;
                }
            }
            if (pi == .none and infos.case[xi] == .immediate and lo.i() <= g and hi.i() == g + 1) {
                const a = infos.repIn(x, lo);
                const b = infos.repIn(x, hi);
                if (a != .none and b != .none) {
                    span_cand = false;
                    pi = a;
                    pj = b;
                    base = lo.i();
                }
            }
            if (pi == .none) continue;

            const top = @min(pinY(c, orient, dev_y, pi), pinY(c, orient, dev_y, pj));
            const net_id: u32 = @intCast(infos.net[xi].i());
            const better = !have or
                (@intFromBool(span_cand) < @intFromBool(best_span)) or
                (span_cand == best_span and top < best_top) or
                (span_cand == best_span and top == best_top and net_id < best_net);
            if (!better) continue;
            have = true;
            best_span = span_cand;
            best_top = top;
            best_net = net_id;
            best_pi = pi;
            best_pj = pj;
            best_base = base;
        }

        offset[g + 1] = if (have)
            offset[best_base] + pinY(c, orient, dev_y, best_pi) - pinY(c, orient, dev_y, best_pj)
        else
            offset[g];
    }
    return offset;
}

/// Phase 3 — how many wire tracks each inter-column gap must carry.
///
/// One lane per `.immediate` signal net in each gap between its lowest and highest
/// column. Rails contribute nothing; `.within_column` contributes nothing;
/// **`.span_ge2` contributes nothing**, which is the measured decision explained in the
/// module header and the single easiest thing in this file to "fix" back into a 5% area
/// regression.
///
/// Returns a slice of length `cols.count() - 1`, or empty for zero or one column.
/// Caller owns it and frees it with `gpa`. Errors: `OutOfMemory` only.
pub fn gapLanes(gpa: Allocator, c: Ctx, cols: Columns, infos: NetInfos) Allocator.Error![]u32 {
    const n = if (cols.count() == 0) 0 else cols.count() - 1;
    const lanes = try gpa.alloc(u32, n);
    errdefer gpa.free(lanes);
    @memset(lanes, 0);
    for (0..infos.count()) |xi| {
        // Rails run on their own bus row and are never routed as per-net wires;
        // `.within_column` has no gap to cross; `.span_ge2` reserves NOTHING, which is
        // the measured decision in the module header and not an omission.
        if (c.isRailNet(infos.net[xi])) continue;
        if (infos.case[xi] != .immediate) continue;
        const lo, const hi = infos.span(colm.InfoIdx.at(xi));
        var g = lo.i();
        while (g < @min(hi.i(), n)) : (g += 1) lanes[g] += 1;
    }
    return lanes;
}

/// Width of one inter-column gap: `track_w * (lanes + 1)`.
///
/// The `+ 1` is the one-gauge floor — every gap keeps room for a riser even when no
/// net reserved anything in it, so the router always has an escape. There is no
/// additive channel base beyond it.
///
/// Pure, allocation-free, and total: `gapWidth(cfg, 0) == cfg.layout.track_w`.
pub fn gapWidth(cfg: *const Config, lanes: u32) i32 {
    return cfg.layout.track_w * @as(i32, @intCast(lanes + 1));
}

/// Phase 4 — column axes and the track x's inside every band.
///
/// Column 0's axis sits one track width in from the left edge of its own half-width.
/// Each subsequent in-field column is placed at `prev_x + prev_half + this_half +
/// gapWidth(lanes[prev])`. A `.feedback` column consumes no width and takes its
/// predecessor's x, since it lives in the margin band rather than the field.
///
/// Half-widths come from each column's widest oriented device extent, floored at the
/// standard half cell (20 units) so a column of builtins pitches uniformly and a wide
/// host symbol costs space rather than correctness, and quantized up to the grid so
/// column axes stay on it.
///
/// Track x's are spaced evenly inside each band and snapped to the nearest grid
/// multiple, then filtered to those strictly inside the band — snapping can collapse a
/// track onto a column edge on a coarse grid, and a track on a body edge is not a track.
/// One extra band is emitted outside each extreme so a route can always wrap the field.
///
/// Returns `.{ col_half, col_x, lane_x }`, all three caller-owned and freed with `gpa`.
/// Errors: `OutOfMemory` only.
pub fn placeColumns(
    gpa: Allocator,
    c: Ctx,
    cols: Columns,
    orient: []const Orient,
    lanes: []const u32,
    cfg: *const Config,
) Allocator.Error!struct { []i32, []i32, Csr(TrackIdx, i32) } {
    const ncol = cols.count();
    const grid = cfg.layout.grid;
    const tw = cfg.layout.track_w;

    const col_half = try gpa.alloc(i32, ncol);
    errdefer gpa.free(col_half);
    for (0..ncol) |i| {
        var h: i32 = half_cell;
        for (cols.devices(ColumnIdx.at(i))) |d| {
            const r = orientedBox(c, orient, d);
            h = @max(h, @max(r.max.x, -r.min.x));
        }
        col_half[i] = snapCeil(h, grid);
    }

    const col_x = try gpa.alloc(i32, ncol);
    errdefer gpa.free(col_x);
    if (ncol > 0) {
        col_x[0] = col_half[0] + tw;
        for (1..ncol) |i| {
            if (!cols.inField(ColumnIdx.at(i))) {
                // A feedback column lives in the margin band and consumes no width.
                col_x[i] = col_x[i - 1];
                continue;
            }
            const l: u32 = if (i - 1 < lanes.len) lanes[i - 1] else 0;
            col_x[i] = col_x[i - 1] + col_half[i - 1] + col_half[i] + gapWidth(cfg, l);
        }
    }

    var vals: std.ArrayList(i32) = .empty;
    defer vals.deinit(gpa);
    var offs: std.ArrayList(u32) = .empty;
    defer offs.deinit(gpa);
    if (ncol > 0) {
        const left = col_x[0] - col_half[0];
        try pushBand(gpa, &vals, &offs, left - tw, left, 1, grid);
        for (0..ncol - 1) |g| {
            const a = col_x[g] + col_half[g];
            const b = col_x[g + 1] - col_half[g + 1];
            const l: u32 = if (g < lanes.len) lanes[g] else 0;
            if (b > a) {
                try pushBand(gpa, &vals, &offs, a, b, l + 1, grid);
            } else {
                try offs.append(gpa, @intCast(vals.items.len));
            }
        }
        const right = col_x[ncol - 1] + col_half[ncol - 1];
        try pushBand(gpa, &vals, &offs, right, right + tw, 1, grid);
    }
    try offs.append(gpa, @intCast(vals.items.len));

    const lane_off = try offs.toOwnedSlice(gpa);
    errdefer gpa.free(lane_off);
    const lane_vals = try vals.toOwnedSlice(gpa);
    return .{ col_half, col_x, .{ .offsets = lane_off, .values = lane_vals } };
}

/// A device's bounding box in oriented, device-local coordinates.
///
/// The class's canonical box, transformed by `orient[d]` and re-normalized — a
/// quarter-turn or a mirror swaps which corner is minimal, so applying the transform
/// to `min` and `max` naively yields an inverted rectangle that `Rect.intersects`
/// then reports as never colliding. Delegates to `geom.transformRect`, which is the
/// single definition of that fix.
///
/// Allocation-free.
pub fn orientedBox(c: Ctx, orient: []const Orient, d: DeviceIdx) Rect {
    return geom.transformRect(orient[d.i()], c.classOf(d).bbox());
}

/// A pin's terminal point in oriented, device-local coordinates.
///
/// Add the device's absolute position to get the canvas point. Allocation-free.
pub fn orientedTerm(c: Ctx, orient: []const Orient, p: PinIdx) Pt {
    return orient[c.devOf(p).i()].apply(c.termAt(p));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Standard half cell. A column of builtins pitches uniformly at this width; a wider
/// host symbol costs space rather than correctness.
const half_cell: i32 = catalog.cell_half;

/// Smallest grid multiple at or above `v`. Identity when the host is ungridded.
fn snapCeil(v: i32, g: i32) i32 {
    if (g <= 1) return v;
    return @divFloor(v + g - 1, g) * g;
}

/// Nearest grid multiple. Identity when the host is ungridded.
fn snapNear(v: i32, g: i32) i32 {
    if (g <= 1) return v;
    return @divFloor(v + @divTrunc(g, 2), g) * g;
}

/// Absolute-within-column y of a pin: its device's interior y plus the oriented anchor.
fn pinY(c: Ctx, orient: []const Orient, dev_y: []const i32, p: PinIdx) i32 {
    return dev_y[c.devOf(p).i()] + orientedTerm(c, orient, p).y;
}

/// Both conduction pins on one row? Then the device carries no vertical link.
fn isFlat(c: Ctx, orient: []const Orient, d: DeviceIdx) bool {
    const cps = c.conductingPins(d);
    if (cps.len < 2) return false;
    const y0 = orientedTerm(c, orient, cps[0]).y;
    for (cps[1..]) |p| {
        if (orientedTerm(c, orient, p).y != y0) return false;
    }
    return true;
}

const Extreme = enum { lowest, highest };

/// The device's bottom-most (`.lowest`) or top-most (`.highest`) conducting terminal.
///
/// y grows downward, so "lowest" is the maximum y. Ties keep the later pin for the
/// bottom and the earlier for the top, which is the tie-break the Rust original's
/// `max_by_key` / `min_by_key` pair produces and the one the fixtures were fitted on.
fn extremeTerm(c: Ctx, orient: []const Orient, d: DeviceIdx, which: Extreme) PinIdx {
    var best: PinIdx = .none;
    var best_y: i32 = 0;
    for (c.conductingPins(d)) |p| {
        const y = orientedTerm(c, orient, p).y;
        const take = best == .none or switch (which) {
            .lowest => y >= best_y,
            .highest => y < best_y,
        };
        if (!take) continue;
        best = p;
        best_y = y;
    }
    return best;
}

/// Emit one band of track x's between `a` and `b`, evenly spaced and grid-snapped.
///
/// Tracks that snap onto a band edge are dropped: a track flush with a body edge is
/// not a track. A band with no room emits nothing but still occupies its CSR key, so
/// the `TrackIdx` index space stays aligned with the columns.
fn pushBand(
    gpa: Allocator,
    vals: *std.ArrayList(i32),
    offs: *std.ArrayList(u32),
    a: i32,
    b: i32,
    n: u32,
    grid: i32,
) Allocator.Error!void {
    try offs.append(gpa, @intCast(vals.items.len));
    const cnt: i32 = @intCast(@max(n, 1));
    const step = @max(@divTrunc(b - a, cnt + 1), 1);
    var k: i32 = 1;
    while (k <= cnt) : (k += 1) {
        const x = snapNear(a + k * step, grid);
        if (x > a and x < b) try vals.append(gpa, x);
    }
}
