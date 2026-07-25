//! Column assignment: turning an ordered spline set into the left-to-right column
//! list the rest of placement stacks, aligns and routes between.
//!
//! What moves through here:
//!
//! ```
//! SplineSet + a permutation of it  (the candidate order)
//!   + branch_count per device      (Tier A, from ctx.zig)
//!   -> one Spline column per spline, minus its shared devices
//!   -> Shared columns   (branch_count == 2, inserted between the two branches)
//!   -> anchoring        (branch_count >= 3, kept on the span-minimising branch)
//!   -> Component / Feedback columns  (cross-column bridges)
//!   -> Component columns             (same-spline satellites, after the parent)
//!   -> SignalSeries columns          (rail-less conduction groups)
//!   -> Columns { kind[], column -> devices CSR, column_of[] }
//!   -> per-net: which columns it touches, and its NetCase
//! ```
//!
//! This is the first pass of ALGORITHM.md's **Tier B** — order-dependent but
//! route-invariant. It runs once per candidate order and never sees a wire.
//!
//! ## Why one CSR plus a reverse map, and not a list of device lists
//!
//! Every consumer wants one of exactly two queries: "the devices of column c" and
//! "the column of device d". A `[][]DeviceIdx` answers the first with a pointer
//! chase per column and the second not at all, so the Rust original scans every
//! column's vector to answer it — inside the bridge test, which runs per device.
//! One CSR plus one dense `column_of` answers both in a load, and the whole
//! assignment frees in three calls.
//!
//! ## Column *positions* are decided by a sort, not by insertion
//!
//! Inserting a column shifts every index after it, which then invalidates the
//! `column_of` entries and the anchor decisions computed against the old indices.
//! So the passes below emit `(anchor, rank)` keys instead — base column `i` gets
//! `(i, 0)`, a satellite of column `p` gets `(p, 1)`, a bridge spanning up to column
//! `m` gets `(m - 1, 2)` — and one stable sort produces the final order. That places
//! a satellite immediately after its parent and a bridge immediately before the
//! higher column it spans, which is exactly what ALGORITHM.md specifies, in one pass
//! with no index rewriting.
//!
//! ## Determinism: no hash map is iterated
//!
//! The Rust original keys shared-device anchors by `HashMap<u32, usize>` and groups
//! antiparallel pass devices by `HashMap<Vec<usize>, Vec<DeviceIdx>>`, then iterates
//! both. Iteration order of a hash map is not reproducible, and the second one hashes
//! a heap-allocated key per device. Both are replaced here: anchors live in a dense
//! `[]ColumnIdx` indexed by device, and the antiparallel grouping sorts devices by
//! their (sorted, deduplicated) conducting-net signature and takes equal runs. Sorting
//! is O(n log n) against a hash map's O(n), on tens of devices, and it is the only
//! version whose output is byte-reproducible — ARCHITECTURE.md §7, not a preference.
//!
//! ## Lifetime
//!
//! `Columns` and `NetInfos` are **per-candidate-order**: allocate them from the
//! `search` arena, which is reset between candidates. Nothing here may be handed to
//! the `out` arena — the winning order is re-derived, not retained.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const Csr = @import("../csr.zig").Csr;
const ctxm = @import("ctx.zig");

const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const NetCase = ids.NetCase;
const Ctx = ctxm.Ctx;
const SplineIdx = ctxm.SplineIdx;
const SplineSet = ctxm.SplineSet;

/// A column in the final left-to-right order.
///
/// Its own index space, distinct from `ids.ColIdx` (which is a *lattice* x
/// coordinate — a different thing that happens to be called a column). Declared here
/// because a column only exists once assignment has run.
pub const ColumnIdx = enum(u32) {
    /// Not in any column: a rail symbol, or a device the assignment could not place.
    /// The sentinel every walk in `place/` filters on.
    none = std.math.maxInt(u32),
    _,

    pub fn i(c: ColumnIdx) usize {
        std.debug.assert(c != .none);
        return @intFromEnum(c);
    }

    pub fn at(n: usize) ColumnIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// Why a column exists, which decides how it is stacked, oriented and priced.
///
/// The tag is never a control-flow switch in the router — ALGORITHM.md is explicit
/// that every net routes through one identical tree search. It selects *costs*,
/// *spacing* and *orientation*, and nothing else.
pub const ColumnKind = enum(u8) {
    /// One extracted conduction path, stacked vertically. The default column.
    spline,
    /// A device shared by exactly two branches, given its own column between them
    /// (ALGORITHM.md "Shared devices", N = 2).
    shared,
    /// A bridge between adjacent columns, or a stack of same-spline satellites sitting
    /// immediately after their parent.
    component,
    /// A non-immediate bridge: it spans two or more gaps and lives in the backward
    /// feedback margin band, so it occupies no width in the device field.
    feedback,
    /// A conductor touching no rail — a pass transistor or transmission gate. Yields
    /// no spline, so it becomes its own column and the circuit places with no rails.
    signal_series,
};

/// The assignment: what every column is, what is in it, and where every device went.
///
/// Owns all three arrays. Allocate from the `search` arena; `deinit` is still correct
/// under a general allocator so tests can audit it.
pub const Columns = struct {
    /// Kind per column. Indexed by `ColumnIdx`; `len` is the column count.
    kind: []ColumnKind,
    /// column → its devices, top to bottom in conduction order.
    dev: Csr(ColumnIdx, DeviceIdx),
    /// Reverse map: device → its column, `.none` for rails and unplaced devices.
    /// Dense, indexed by `DeviceIdx`.
    column_of: []ColumnIdx,

    pub const empty: Columns = .{ .kind = &.{}, .dev = .empty, .column_of = &.{} };

    pub fn deinit(self: *Columns, gpa: Allocator) void {
        gpa.free(self.kind);
        self.dev.deinit(gpa);
        gpa.free(self.column_of);
        self.kind = &.{};
        self.column_of = &.{};
    }

    pub fn count(self: Columns) usize {
        return self.kind.len;
    }

    /// The devices of `c`, top to bottom. Borrowed from `dev.values`; never freed by
    /// the caller.
    pub fn devices(self: Columns, c: ColumnIdx) []const DeviceIdx {
        return self.dev.slice(c);
    }

    /// True when `c` occupies horizontal room in the device field.
    ///
    /// False only for `.feedback`, which is margin-resident: it is skipped by the x
    /// placement, by canvas extent, and by net classification, because a wire routed
    /// through the margin band must not make its net look like it reaches across the
    /// field.
    pub fn inField(self: Columns, c: ColumnIdx) bool {
        return self.kind[c.i()] != .feedback;
    }

    /// Check: `kind.len + 1 == dev.offsets.len`, `column_of.len == deviceCount()`, and
    /// `column_of` agrees with `dev` in both directions. Panics on violation.
    pub fn assertValid(self: Columns, c: Ctx) void {
        std.debug.assert(self.kind.len + 1 == self.dev.offsets.len);
        std.debug.assert(self.column_of.len == c.deviceCount());
        self.dev.assertValid();
        for (0..self.count()) |ci| {
            for (self.devices(ColumnIdx.at(ci))) |d| {
                std.debug.assert(self.column_of[d.i()] == ColumnIdx.at(ci));
            }
        }
        for (self.column_of, 0..) |col, di| {
            if (col == .none) continue;
            var found = false;
            for (self.devices(col)) |d| {
                if (d.i() == di) found = true;
            }
            std.debug.assert(found);
        }
    }
};

/// Assign every device to a column for one candidate order.
///
/// `order` is a permutation of `0 .. splines.keyCount()`: `order[k]` is the spline
/// that goes in the k-th spline position. It must be a genuine permutation — a
/// repeated or missing entry is a programming error and is asserted.
///
/// The five rules, in the sequence they are applied:
///
/// 1. **Spline columns.** One per entry of `order`, holding that spline's devices in
///    conduction order, minus any device this pass gives away by rules 2 and 3.
/// 2. **`branch_count == 2` — own column.** The shared device is removed from both
///    branches and emitted as a `.shared` column immediately after the first branch
///    that mentions it, which puts it *between* the two branches. ALGORITHM.md's
///    motivating case is a first-stage op-amp tail.
/// 3. **`branch_count >= 3` — anchor, no new column.** The device stays on exactly one
///    branch: the one whose position minimises `sum(|anchor_pos - branch_pos|)` over
///    every branch it appears on, ties going to the lower position. That is the median
///    branch. Symmetric placement around the shared device is deliberately *not*
///    attempted — ALGORITHM.md lists mirror-x as a known gap and this rule as the
///    deterministic stand-in.
/// 4. **Bridges.** A non-spline, non-rail device with exactly two conducting terminals
///    whose nets both resolve to columns is a bridge. Purely topological: it catches a
///    Miller cap and a gain-boost MOSFET alike, because a MOSFET's gate is not a
///    conducting terminal and so takes no part in the test.
///    - `a != b` and `|a - b| == 1` → a `.component` column inserted just before
///      `max(a, b)`.
///    - `a != b` and `|a - b| >= 2` → a `.feedback` column at the same position, but
///      margin-resident.
///    - `a == b` → a same-spline **satellite**: it joins the one `.component` column
///      that sits immediately after its parent, at position `a + 1`. Several
///      satellites of one spline share that column. Their nets then span exactly two
///      adjacent columns, so they classify `.immediate` and route as short horizontals.
///
///    A **rail net never resolves to a column.** "Touches ground" says nothing about
///    horizontal position, and letting it resolve would park grounded bipoles and
///    divider legs in the margin band as cross-field feedback bridges. A bridge with
///    one signal side and one rail side is treated as a satellite of the signal side
///    instead, and its rail pin drops to the bus.
/// 5. **Everything left over → `.signal_series`.** Rail-less conductors. Devices
///    sharing the same set of two or more conducting nets — an antiparallel pass
///    structure, a transmission gate — are grouped into *one* column so they stack;
///    everything else gets a column to itself. Groups are emitted in ascending
///    lowest-device-index order.
///
/// Divergence from the Rust original, recorded deliberately: it splits Component from
/// Feedback at `|a - b| >= 3`, while ALGORITHM.md ("Bridge devices") says `>= 2`. This
/// port follows the document, because the document is the specification and the
/// threshold is the difference between a bridge sitting in the field and one sitting
/// in the margin — a visible behavioural choice, not a tuning constant. Fixtures whose
/// golden output changes as a result are regenerated with this note as the reason, per
/// ARCHITECTURE.md's rule that a divergence without a written reason is a bug.
///
/// Caller owns the result and must `deinit` it. Errors: `OutOfMemory` only.
///
/// Edge cases: an empty `order` (a rail-less circuit) is legal and produces only
/// `.signal_series` columns. A device whose two conducting nets both fail to resolve
/// falls through to rule 5 rather than being dropped.
///
/// Complexity: O(devices x columns) for the bridge pass's column resolution, plus one
/// O(columns log columns) stable sort. The quadratic term is over a column count in
/// the tens; if it ever matters the fix is a net → column index, not a hash map.
pub fn assign(
    gpa: Allocator,
    c: Ctx,
    splines: SplineSet,
    order: []const u32,
    branch_count: []const u16,
) Allocator.Error!Columns {
    const nd = c.deviceCount();
    std.debug.assert(branch_count.len == nd);
    assertPermutation(order, splines.keyCount());

    // One record per column, one flat device pool. The pool is append-only and a
    // record names a run inside it, so sorting the records reorders whole columns
    // without touching a device — which is what makes the `(anchor, rank)` scheme
    // cheaper than index-shifted insertion.
    var pool: std.ArrayList(DeviceIdx) = .empty;
    defer pool.deinit(gpa);
    var recs: std.ArrayList(Rec) = .empty;
    defer recs.deinit(gpa);

    // Rule 3: a device on three or more branches stays on the median branch.
    const anchor_pos = try gpa.alloc(u32, nd);
    defer gpa.free(anchor_pos);
    @memset(anchor_pos, no_pos);
    for (0..nd) |di| {
        const d = DeviceIdx.at(di);
        if (branch_count[di] < 3) continue;
        var best: u32 = no_pos;
        var best_cost: usize = std.math.maxInt(usize);
        for (order, 0..) |si, pos| {
            if (!memberOf(splines, si, d)) continue;
            var cost: usize = 0;
            for (order, 0..) |sj, other| {
                if (!memberOf(splines, sj, d)) continue;
                cost += if (other > pos) other - pos else pos - other;
            }
            if (cost < best_cost) {
                best_cost = cost;
                best = @intCast(pos);
            }
        }
        anchor_pos[di] = best;
    }

    // Rules 1 and 2: one spline column per order entry, with a `.shared` column
    // emitted immediately after the first branch that mentions each two-branch device.
    var shared_done = try gpa.alloc(bool, nd);
    defer gpa.free(shared_done);
    @memset(shared_done, false);
    for (order, 0..) |si, pos| {
        const devs = splines.slice(SplineIdx.at(si));
        const start: u32 = @intCast(pool.items.len);
        for (devs) |d| {
            const bc = branch_count[d.i()];
            if (bc == 2) continue;
            if (bc >= 3 and anchor_pos[d.i()] != pos) continue;
            try pool.append(gpa, d);
        }
        try recs.append(gpa, .{
            .kind = .spline,
            .anchor = @intCast(recs.items.len),
            .rank = 0,
            .start = start,
            .len = @intCast(pool.items.len - start),
        });
        for (devs) |d| {
            if (branch_count[d.i()] != 2 or shared_done[d.i()]) continue;
            shared_done[d.i()] = true;
            const s: u32 = @intCast(pool.items.len);
            try pool.append(gpa, d);
            try recs.append(gpa, .{
                .kind = .shared,
                .anchor = @intCast(recs.items.len),
                .rank = 0,
                .start = s,
                .len = 1,
            });
        }
    }

    // Reverse map over the base columns only. Bridge resolution asks "which base
    // column does this net live in", and the answer must not shift as columns are
    // inserted — that is the whole reason positions are keys and not indices.
    const base_col = try gpa.alloc(u32, nd);
    defer gpa.free(base_col);
    @memset(base_col, no_pos);
    for (recs.items, 0..) |r, ci| {
        for (pool.items[r.start..][0..r.len]) |d| base_col[d.i()] = @intCast(ci);
    }

    // Rule 4 and 5: every device on no spline is a bridge, a satellite or leftover.
    var sats: std.ArrayList(Sat) = .empty;
    defer sats.deinit(gpa);
    var bridges: std.ArrayList(Rec) = .empty;
    defer bridges.deinit(gpa);
    var series: std.ArrayList(DeviceIdx) = .empty;
    defer series.deinit(gpa);

    for (0..nd) |di| {
        const d = DeviceIdx.at(di);
        if (c.isRail(d) or branch_count[di] > 0) continue;
        const cps = c.conductingPins(d);
        if (cps.len == 2) {
            const a = resolveColumn(c, base_col, cps[0]);
            const b = resolveColumn(c, base_col, cps[1]);
            if (a != no_pos and b != no_pos) {
                if (a == b) {
                    try sats.append(gpa, .{ .parent = a, .dev = d });
                    continue;
                }
                const diff = if (a > b) a - b else b - a;
                // ALGORITHM.md's "Bridge devices" splits at |a - b| >= 2; the Rust
                // original split at >= 3. The document is the specification.
                const kind: ColumnKind = if (diff >= 2) .feedback else .component;
                try bridges.append(gpa, .{
                    .kind = kind,
                    .anchor = @max(a, b) - 1,
                    .rank = 2,
                    .start = 0,
                    .len = 1,
                    .dev = d,
                });
                continue;
            }
            // A rail net never resolves, so a bridge with one rail side hangs beside
            // its signal column instead of being parked in the margin band.
            if (a != no_pos and railSide(c, cps[1])) {
                try sats.append(gpa, .{ .parent = a, .dev = d });
                continue;
            }
            if (b != no_pos and railSide(c, cps[0])) {
                try sats.append(gpa, .{ .parent = b, .dev = d });
                continue;
            }
        }
        try series.append(gpa, d);
    }

    // Satellites: grouped by parent, deterministic because the key is sorted rather
    // than hashed. Several satellites of one spline share the one column after it.
    std.mem.sort(Sat, sats.items, {}, Sat.lessThan);
    var i: usize = 0;
    while (i < sats.items.len) {
        const parent = sats.items[i].parent;
        const start: u32 = @intCast(pool.items.len);
        while (i < sats.items.len and sats.items[i].parent == parent) : (i += 1) {
            try pool.append(gpa, sats.items[i].dev);
        }
        try recs.append(gpa, .{
            .kind = .component,
            .anchor = parent,
            .rank = 1,
            .start = start,
            .len = @intCast(pool.items.len - start),
        });
    }
    for (bridges.items) |b| {
        var r = b;
        r.start = @intCast(pool.items.len);
        r.len = 1;
        try pool.append(gpa, b.dev);
        try recs.append(gpa, r);
    }

    // One stable sort puts a satellite after its parent and a bridge before the
    // higher column it spans, with no index rewriting anywhere.
    std.mem.sort(Rec, recs.items, {}, Rec.lessThan);

    // Rule 5: leftovers. Devices sharing a conducting-net signature stack together.
    try appendSeries(gpa, c, series.items, &pool, &recs);

    // Materialize.
    const kind = try gpa.alloc(ColumnKind, recs.items.len);
    errdefer gpa.free(kind);
    const offsets = try gpa.alloc(u32, recs.items.len + 1);
    errdefer gpa.free(offsets);
    const values = try gpa.alloc(DeviceIdx, pool.items.len);
    errdefer gpa.free(values);
    const column_of = try gpa.alloc(ColumnIdx, nd);
    errdefer gpa.free(column_of);
    @memset(column_of, .none);

    var w: u32 = 0;
    for (recs.items, 0..) |r, ci| {
        kind[ci] = r.kind;
        offsets[ci] = w;
        for (pool.items[r.start..][0..r.len]) |d| {
            values[w] = d;
            column_of[d.i()] = ColumnIdx.at(ci);
            w += 1;
        }
    }
    offsets[recs.items.len] = w;

    return .{
        .kind = kind,
        .dev = .{ .offsets = offsets, .values = values },
        .column_of = column_of,
    };
}

/// The "no column" marker inside `assign`, distinct from `ColumnIdx.none` only in
/// that it names a *base* column position rather than a final one.
const no_pos: u32 = std.math.maxInt(u32);

/// One column under construction: what it is, where it sorts, and which run of the
/// device pool it owns.
const Rec = struct {
    kind: ColumnKind,
    /// Base column this one attaches to. The primary sort key.
    anchor: u32,
    /// 0 = a base column, 1 = satellites of it, 2 = a bridge landing before the next.
    rank: u8,
    start: u32,
    len: u32,
    /// Only set while a bridge waits for its pool slot.
    dev: DeviceIdx = .none,

    fn lessThan(_: void, a: Rec, b: Rec) bool {
        if (a.anchor != b.anchor) return a.anchor < b.anchor;
        return a.rank < b.rank;
    }
};

/// A same-spline satellite waiting to be grouped with its siblings.
const Sat = struct {
    parent: u32,
    dev: DeviceIdx,

    fn lessThan(_: void, a: Sat, b: Sat) bool {
        if (a.parent != b.parent) return a.parent < b.parent;
        return @intFromEnum(a.dev) < @intFromEnum(b.dev);
    }
};

fn assertPermutation(order: []const u32, n: usize) void {
    if (!std.debug.runtime_safety) return;
    std.debug.assert(order.len == n);
    for (order, 0..) |s, i| {
        std.debug.assert(s < n);
        for (order[i + 1 ..]) |t| std.debug.assert(s != t);
    }
}

fn memberOf(splines: SplineSet, si: u32, d: DeviceIdx) bool {
    for (splines.slice(SplineIdx.at(si))) |x| {
        if (x == d) return true;
    }
    return false;
}

/// True when `p` sits on a power or ground net.
fn railSide(c: Ctx, p: PinIdx) bool {
    const n = c.netOf(p);
    return n != .none and c.isRailNet(n);
}

/// The base column `p`'s net lives in, or `no_pos`.
///
/// A **rail net never resolves**: "touches ground" says nothing about horizontal
/// position, and resolving it would park every grounded bipole in the margin band as
/// a cross-field feedback bridge.
fn resolveColumn(c: Ctx, base_col: []const u32, p: PinIdx) u32 {
    const n = c.netOf(p);
    if (n == .none or c.isRailNet(n)) return no_pos;
    for (c.members(n)) |q| {
        const col = base_col[c.devOf(q).i()];
        if (col != no_pos) return col;
    }
    return no_pos;
}

/// Emit the leftover devices as `.signal_series` columns.
///
/// Devices sharing the same set of two or more conducting nets — an antiparallel pass
/// structure, a transmission gate — stack in one column; everything else gets its own.
/// Grouping is by sorting the net signatures, never by hashing them: the Rust original
/// keyed a `HashMap<Vec<usize>, _>` and iterated it, which is not reproducible.
fn appendSeries(
    gpa: Allocator,
    c: Ctx,
    series: []const DeviceIdx,
    pool: *std.ArrayList(DeviceIdx),
    recs: *std.ArrayList(Rec),
) Allocator.Error!void {
    if (series.len == 0) return;

    var sig: std.ArrayList(u32) = .empty;
    defer sig.deinit(gpa);
    var ent: std.ArrayList(Entry) = .empty;
    defer ent.deinit(gpa);

    for (series) |d| {
        const start: u32 = @intCast(sig.items.len);
        for (c.conductingPins(d)) |p| {
            const n = c.netOf(p);
            if (n == .none) continue;
            try sig.append(gpa, @intCast(n.i()));
        }
        const tail = sig.items[start..];
        std.mem.sort(u32, tail, {}, std.sort.asc(u32));
        var k: usize = 0;
        for (tail, 0..) |v, j| {
            if (j > 0 and v == tail[k - 1]) continue;
            tail[k] = v;
            k += 1;
        }
        sig.shrinkRetainingCapacity(start + k);
        try ent.append(gpa, .{ .dev = d, .start = start, .len = @intCast(k) });
    }

    const Sorter = struct {
        sig: []const u32,
        fn lessThan(self: @This(), a: Entry, b: Entry) bool {
            const sa = self.sig[a.start..][0..a.len];
            const sb = self.sig[b.start..][0..b.len];
            switch (std.mem.order(u32, sa, sb)) {
                .lt => return true,
                .gt => return false,
                .eq => return @intFromEnum(a.dev) < @intFromEnum(b.dev),
            }
        }
    };
    std.mem.sort(Entry, ent.items, Sorter{ .sig = sig.items }, Sorter.lessThan);

    // Equal runs are the groups. Emit them in ascending lowest-device-index order,
    // which after the sort above is the first entry of each run.
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    var i: usize = 0;
    while (i < ent.items.len) {
        const a = ent.items[i];
        var j = i + 1;
        while (j < ent.items.len) : (j += 1) {
            const b = ent.items[j];
            if (!std.mem.eql(u32, sig.items[a.start..][0..a.len], sig.items[b.start..][0..b.len])) break;
        }
        try runs.append(gpa, .{ .from = @intCast(i), .to = @intCast(j), .sig_len = a.len });
        i = j;
    }
    std.mem.sort(Run, runs.items, ent.items, Run.lessThan);

    for (runs.items) |run| {
        const group = ent.items[run.from..run.to];
        if (run.sig_len >= 2 and group.len >= 2) {
            const start: u32 = @intCast(pool.items.len);
            for (group) |e| try pool.append(gpa, e.dev);
            try recs.append(gpa, .{
                .kind = .signal_series,
                .anchor = no_pos,
                .rank = 0,
                .start = start,
                .len = @intCast(group.len),
            });
        } else {
            for (group) |e| {
                const start: u32 = @intCast(pool.items.len);
                try pool.append(gpa, e.dev);
                try recs.append(gpa, .{
                    .kind = .signal_series,
                    .anchor = no_pos,
                    .rank = 0,
                    .start = start,
                    .len = 1,
                });
            }
        }
    }
}

const Entry = struct { dev: DeviceIdx, start: u32, len: u32 };

const Run = struct {
    from: u32,
    to: u32,
    sig_len: u32,

    fn lessThan(ent: []const Entry, a: Run, b: Run) bool {
        return @intFromEnum(ent[a.from].dev) < @intFromEnum(ent[b.from].dev);
    }
};

/// The columns a net's pins touch: sorted ascending, deduplicated, `.none` dropped.
///
/// `out` is caller-supplied scratch of at least `cols.count()` entries; the result is
/// a **borrowed prefix of `out`**, valid until the caller reuses it. This is called
/// once per net per candidate order and allocating a fresh slice each time is the
/// single easiest allocation to delete in this file.
///
/// Returns an empty slice for a net whose pins all sit on rails or unplaced devices.
/// Allocation-free.
pub fn netColumns(c: Ctx, cols: Columns, net: NetIdx, out: []ColumnIdx) []const ColumnIdx {
    std.debug.assert(out.len >= cols.count());
    // Sorted insertion rather than collect-then-sort: a net may have far more pins
    // than there are columns, and `out` is only guaranteed to hold one entry per
    // column. Insertion is over a list of at most `cols.count()` entries.
    var n: usize = 0;
    for (c.members(net)) |p| {
        const col = cols.column_of[c.devOf(p).i()];
        if (col == .none) continue;
        var k: usize = 0;
        while (k < n and @intFromEnum(out[k]) < @intFromEnum(col)) k += 1;
        if (k < n and out[k] == col) continue;
        std.mem.copyBackwards(ColumnIdx, out[k + 1 .. n + 1], out[k..n]);
        out[k] = col;
        n += 1;
    }
    return out[0..n];
}

/// How far a net reaches, in the terms `stack.zig` prices.
///
/// `net_cols` must be the sorted, deduplicated in-field column list from
/// `netColumns`. One column or none → `.within_column`. Otherwise count the
/// `.spline` and `.signal_series` columns strictly between the lowest and highest:
/// none → `.immediate`, any → `.span_ge2`.
///
/// The asymmetry is the point. `.shared`, `.component` and `.feedback` columns are
/// **transparent** to this measure: they were inserted between spline columns and do
/// not represent a stage the signal has to cross, so a net whose pins straddle one is
/// still an immediate-neighbour net and still gets a short horizontal run. Counting
/// them would classify a satellite hookup as a spanning net and push it into the
/// margin band, which is precisely the wire ALGORITHM.md reserves the margin *against*.
///
/// Pure function, allocation-free.
pub fn classify(net_cols: []const ColumnIdx, kinds: []const ColumnKind) NetCase {
    if (net_cols.len <= 1) return .within_column;
    const lo = net_cols[0].i();
    const hi = net_cols[net_cols.len - 1].i();
    for (kinds[lo + 1 .. hi]) |k| {
        // `.shared`, `.component` and `.feedback` are transparent: they were inserted
        // between spline columns and are not a stage the signal has to cross.
        if (k == .spline or k == .signal_series) return .span_ge2;
    }
    return .immediate;
}

/// Does this net drive backwards — a conduction pin in a column to the *right* of a
/// gate it feeds?
///
/// Exactly the nets that belong in the top feedback margin. Only in-field columns
/// count, so a pin already parked in the margin band cannot make its own net look
/// backward. Requires both a control pin and a conducting pin: a net with only gates
/// on it drives nothing and is never backward.
///
/// Used two ways, which is why it lives here rather than in `orient.zig` where the
/// Rust original keeps it: `classifyNets` stores it per net, and `order.zig` counts it
/// as the second term of the Phase-A proxy. One definition, one-way import.
///
/// Allocation-free.
pub fn isBackward(c: Ctx, cols: Columns, net: NetIdx) bool {
    var gate_min: usize = std.math.maxInt(usize);
    var drv_max: usize = 0;
    var has_gate = false;
    var has_drv = false;
    for (c.members(net)) |p| {
        const col = cols.column_of[c.devOf(p).i()];
        if (col == .none or !cols.inField(col)) continue;
        if (c.isControl(p)) {
            gate_min = @min(gate_min, col.i());
            has_gate = true;
        } else if (c.conducts(p)) {
            drv_max = @max(drv_max, col.i());
            has_drv = true;
        }
    }
    return has_gate and has_drv and drv_max > gate_min;
}

/// Index into the `NetInfos` arrays. Dense from 0, and *not* a net index — only nets
/// with at least one in-field pin get an entry.
pub const InfoIdx = enum(u32) {
    _,

    pub fn i(x: InfoIdx) usize {
        return @intFromEnum(x);
    }

    pub fn at(n: usize) InfoIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// Per-net facts, computed once column membership is known.
///
/// SoA and CSR throughout: `align_columns` reads only `case` and `rep`, `gap_lanes`
/// reads only `case` and `cols`, and the router reads only `net` and `backward`. A
/// record per net would drag all six fields into cache for each of those passes.
///
/// Entries are in ascending net order, so a linear merge against any other net-indexed
/// array is possible and the whole structure is reproducible.
pub const NetInfos = struct {
    /// The net each entry describes, ascending. Nets with no in-field pin are absent.
    net: []NetIdx,
    /// entry → its sorted, deduplicated in-field columns. Never empty.
    cols: Csr(InfoIdx, ColumnIdx),
    /// Span class, from `classify`.
    case: []NetCase,
    /// entry → one representative pin per column it touches, parallel to `cols`.
    /// A control pin is preferred over a conducting one, because alignment wants the
    /// gate that must line up, not whichever pin came first.
    rep: Csr(InfoIdx, PinIdx),
    /// The net's pin on a shared (`branch_count >= 2`) device, or `.none`. This is the
    /// hub a fan bus converges on; `stack.zig` shifts a `.shared` column down until
    /// this pin clears every branch pin feeding it.
    shared_hub: []PinIdx,
    /// True when the net drives leftwards — see `isBackward`.
    backward: []bool,

    pub const empty: NetInfos = .{
        .net = &.{},
        .cols = .empty,
        .case = &.{},
        .rep = .empty,
        .shared_hub = &.{},
        .backward = &.{},
    };

    pub fn deinit(self: *NetInfos, gpa: Allocator) void {
        gpa.free(self.net);
        self.cols.deinit(gpa);
        gpa.free(self.case);
        self.rep.deinit(gpa);
        gpa.free(self.shared_hub);
        gpa.free(self.backward);
        self.net = &.{};
        self.case = &.{};
        self.shared_hub = &.{};
        self.backward = &.{};
    }

    pub fn count(self: NetInfos) usize {
        return self.net.len;
    }

    /// The entry for `net`, or null when the net has no in-field pin.
    ///
    /// Binary search over `net`, which is ascending by construction. O(log n) and
    /// allocation-free — and specifically *not* a hash map, so that any pass built on
    /// it stays reproducible.
    pub fn find(self: NetInfos, net: NetIdx) ?InfoIdx {
        var lo: usize = 0;
        var hi: usize = self.net.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = @intFromEnum(self.net[mid]);
            if (v == @intFromEnum(net)) return InfoIdx.at(mid);
            if (v < @intFromEnum(net)) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// The representative pin of entry `x` in column `col`, or `.none` when the net
    /// does not reach that column.
    pub fn repIn(self: NetInfos, x: InfoIdx, col: ColumnIdx) PinIdx {
        const cs = self.cols.slice(x);
        for (cs, self.rep.slice(x)) |c, p| {
            if (c == col) return p;
        }
        return .none;
    }

    /// Lowest and highest in-field column of entry `x`. Asserts the entry exists.
    pub fn span(self: NetInfos, x: InfoIdx) struct { ColumnIdx, ColumnIdx } {
        const cs = self.cols.slice(x);
        std.debug.assert(cs.len > 0);
        return .{ cs[0], cs[cs.len - 1] };
    }
};

/// Classify every net against a finished column assignment.
///
/// `branch_count` is the Tier-A array from `Ctx.branchCounts`; it is what makes a pin
/// a `shared_hub` candidate. One pass over the nets, one pass over each net's pins.
///
/// Nets with no in-field pin are omitted entirely rather than carried with an empty
/// column list — every consumer would otherwise have to check, and the check would be
/// forgotten in exactly one of them.
///
/// Caller owns the result and must `deinit` it. Errors: `OutOfMemory` only.
/// Complexity: O(pins + nets x columns), the second term from `netColumns`' scratch
/// walk.
pub fn classifyNets(
    gpa: Allocator,
    c: Ctx,
    cols: Columns,
    branch_count: []const u16,
) Allocator.Error!NetInfos {
    var net: std.ArrayList(NetIdx) = .empty;
    defer net.deinit(gpa);
    var case: std.ArrayList(NetCase) = .empty;
    defer case.deinit(gpa);
    var hub: std.ArrayList(PinIdx) = .empty;
    defer hub.deinit(gpa);
    var backward: std.ArrayList(bool) = .empty;
    defer backward.deinit(gpa);
    var col_vals: std.ArrayList(ColumnIdx) = .empty;
    defer col_vals.deinit(gpa);
    var rep_vals: std.ArrayList(PinIdx) = .empty;
    defer rep_vals.deinit(gpa);
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(gpa);

    const scratch = try gpa.alloc(ColumnIdx, cols.count());
    defer gpa.free(scratch);

    for (0..c.netCount()) |n| {
        const id = NetIdx.at(n);
        const all = netColumns(c, cols, id, scratch);
        // Feedback-column pins are margin-resident: they take no part in span
        // classification, representative choice or backward detection.
        var in_field: usize = 0;
        for (all) |col| {
            if (!cols.inField(col)) continue;
            scratch[in_field] = col;
            in_field += 1;
        }
        if (in_field == 0) continue;
        const cs = scratch[0..in_field];

        try offsets.append(gpa, @intCast(col_vals.items.len));
        try col_vals.appendSlice(gpa, cs);
        // One representative pin per in-field column, control preferred: alignment
        // wants the gate that must line up, not whichever pin came first.
        const rep_base = rep_vals.items.len;
        try rep_vals.appendNTimes(gpa, .none, in_field);
        for (c.members(id)) |p| {
            const col = cols.column_of[c.devOf(p).i()];
            if (col == .none or !cols.inField(col)) continue;
            const k = indexOfCol(cs, col) orelse continue;
            const cur = rep_vals.items[rep_base + k];
            if (cur == .none or (c.isControl(p) and !c.isControl(cur))) {
                rep_vals.items[rep_base + k] = p;
            }
        }

        try net.append(gpa, id);
        try case.append(gpa, classify(cs, cols.kind));
        try backward.append(gpa, isBackward(c, cols, id));

        var h: PinIdx = .none;
        for (c.members(id)) |p| {
            if (branch_count[c.devOf(p).i()] >= 2 and c.conducts(p)) {
                h = p;
                break;
            }
        }
        try hub.append(gpa, h);
    }
    try offsets.append(gpa, @intCast(col_vals.items.len));

    // Both CSRs share one offsets array by construction — `rep` is parallel to
    // `cols` — but each owns its copy so `deinit` stays two independent calls.
    const rep_off = try gpa.dupe(u32, offsets.items);
    errdefer gpa.free(rep_off);
    const net_s = try net.toOwnedSlice(gpa);
    errdefer gpa.free(net_s);
    const case_s = try case.toOwnedSlice(gpa);
    errdefer gpa.free(case_s);
    const hub_s = try hub.toOwnedSlice(gpa);
    errdefer gpa.free(hub_s);
    const back_s = try backward.toOwnedSlice(gpa);
    errdefer gpa.free(back_s);
    const col_s = try col_vals.toOwnedSlice(gpa);
    errdefer gpa.free(col_s);
    const rep_s = try rep_vals.toOwnedSlice(gpa);
    errdefer gpa.free(rep_s);
    const off_s = try offsets.toOwnedSlice(gpa);

    return .{
        .net = net_s,
        .cols = .{ .offsets = off_s, .values = col_s },
        .case = case_s,
        .rep = .{ .offsets = rep_off, .values = rep_s },
        .shared_hub = hub_s,
        .backward = back_s,
    };
}

fn indexOfCol(cs: []const ColumnIdx, col: ColumnIdx) ?usize {
    for (cs, 0..) |x, k| {
        if (x == col) return k;
    }
    return null;
}

