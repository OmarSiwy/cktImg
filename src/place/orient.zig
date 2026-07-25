//! Device orientation: which way each symbol faces, decided from topology alone.
//!
//! What moves through here:
//!
//! ```
//! Columns (kind, membership, column_of)  +  Ctx (terminal roles, nets)
//!   -> per device: is its up-facing conduction pin the canonical left one?
//!   -> per device: does its gate net come from an earlier column?
//!   -> Orient[]  (one packed byte per device)
//! ```
//!
//! One output array, indexed by `DeviceIdx`, written once per candidate order. It is
//! Tier B: order-dependent, route-invariant, and computed before a single wire
//! exists.
//!
//! ## The rule, and why it is only two bits of information
//!
//! ALGORITHM.md states it in three lines: a gate points right by default, toward the
//! next column, and points **left** exactly when its gate net has a pin in an earlier
//! column. That is one boolean. The second is which of the device's two conducting
//! terminals faces up the column, which follows from what it shares with the device
//! stacked above it. Those two booleans select one of four quarter-turn-plus-mirror
//! transforms, and there is no fifth case — orientation is a lookup, not a search.
//!
//! Stating it as "the gate's net *source*" would need a notion of which pin drives,
//! which the netlist does not carry. "Has a pin in an earlier column" is the same
//! preference expressed in data the placer already has, and it degrades gracefully:
//! a gate net with no earlier pin simply keeps the default.
//!
//! ## Bridges are the exception, and they are exceptions about *bodies*
//!
//! A two-terminal passive in a bridge or satellite column has no gate, so the rule
//! above says nothing. What it does have is two plates that each must meet their
//! net's run head-on — a wire that has to wrap around the body to reach the far plate
//! is a wire the lattice router will happily draw and a reader will misread. So a
//! passive bridge is laid **horizontally**, mirrored so each plate faces the side its
//! net lives on, and stood **vertically** only when exactly one of its nets spans
//! (that plate then points at the channel the spanning run occupies). An *active*
//! bridge — a MOSFET whose drain and source resolve to columns — keeps the ordinary
//! gate rule and is oriented vertically like any spline device, which is what
//! ALGORITHM.md specifies for the gain-boosted cascode's `Ma`.
//!
//! Rail nets **abstain** from the mirroring vote. "This plate connects to ground"
//! says nothing about which side of the device ground is on; letting it vote flipped
//! grounded bipoles away from their one signal neighbour and made the plate
//! unreachable, so the net fell back to a label. A rail pin drops to the bus row
//! instead, from wherever it ends up.
//!
//! ## Antiparallel pass groups
//!
//! A `.signal_series` column holding two or more devices is a transmission gate or
//! another antiparallel pass structure. No rail feeds it, so there is no up and no
//! down: the devices lie flat with their gates facing outward, and each one's mirror
//! is chosen so that a given conduction net stays on the same side for every device
//! in the stack. That is what makes the two side wires straight runs instead of a
//! pair of crossovers.
//!
//! ## Lifetime
//!
//! The returned array is **per-candidate-order**: allocate it from the `search`
//! arena. Only the winning candidate's array is copied into `Ir.dev_orient`, by the
//! caller, after Phase B picks a winner.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const ctxm = @import("ctx.zig");
const colm = @import("column.zig");

const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const Orient = ids.Orient;
const Ctx = ctxm.Ctx;
const Columns = colm.Columns;
const ColumnIdx = colm.ColumnIdx;

/// Orientation for every device in the schematic.
///
/// Length `c.deviceCount()`, indexed by `DeviceIdx`. Rails and unplaced devices keep
/// the identity orientation — they are drawn as bus glyphs and never rotated.
///
/// The four transforms a gated device can receive, as a function of
/// `(up_pin_is_canonical_left, gate_from_left)`:
///
/// | up-left | gate-left | transform          | reads as                          |
/// |---------|-----------|--------------------|-----------------------------------|
/// | true    | false     | rot 90             | canonical-left pin up, gate right  |
/// | true    | true      | rot 270 + mirror   | canonical-left pin up, gate left   |
/// | false   | false     | rot 90 + mirror    | canonical-right pin up, gate right |
/// | false   | true      | rot 270            | canonical-right pin up, gate left  |
///
/// The invariant a caller should test against is not the table but its consequence:
/// after `compute`, `orient[d].apply(gateAnchor(d)).x` is negative exactly when
/// `gateFromLeft(c, cols, d)` is true. The encoding is an implementation detail; the
/// direction the gate points is the specification.
///
/// Caller owns the returned slice and frees it with `gpa`.
///
/// Errors: `OutOfMemory` only. Complexity: O(pins + nets touched by gates), with the
/// bridge cases adding one `netColumns` walk per two-terminal bridge.
pub fn compute(gpa: Allocator, c: Ctx, cols: Columns) Allocator.Error![]Orient {
    const out = try gpa.alloc(Orient, c.deviceCount());
    errdefer gpa.free(out);
    @memset(out, Orient.r0);

    const scratch = try gpa.alloc(ColumnIdx, cols.count());
    defer gpa.free(scratch);

    for (0..cols.count()) |ci| {
        const col = ColumnIdx.at(ci);
        const devs = cols.devices(col);
        const kind = cols.kind[ci];

        if (kind == .signal_series and devs.len >= 2) {
            // Antiparallel pass group: no rail feeds it, so the devices lie flat with
            // their gates outward and each mirror is picked so a conduction net keeps
            // the same side down the stack — that is what makes the two side wires
            // straight runs instead of a pair of crossovers.
            const head = leftNet(c, devs[0], Orient.r0);
            for (devs, 0..) |d, i| {
                if (i == 0) {
                    out[d.i()] = Orient.r0;
                    continue;
                }
                const flipped: Orient = .{ .rot = 2, .mirror = true };
                out[d.i()] = if (leftNet(c, d, flipped) == head)
                    flipped
                else
                    Orient{ .rot = 2, .mirror = false };
            }
            continue;
        }

        for (devs, 0..) |d, i| {
            const gated = hasControl(c, d);
            if (!gated and (kind == .component or kind == .signal_series or kind == .feedback)) {
                out[d.i()] = if (kind == .component)
                    bridgeOrient(c, cols, d, scratch)
                else
                    bridgeMirror(c, cols, d);
                continue;
            }
            if (kind == .feedback) continue; // gated feedback devices stay canonical
            const above: DeviceIdx = if (i > 0) devs[i - 1] else .none;
            const up = upConductionPin(c, d, above);
            const up_left = if (up == .none) true else c.termAt(up).x < 0;
            const gate_left = gateFromLeft(c, cols, d);
            out[d.i()] = if (up_left)
                (if (gate_left) Orient{ .rot = 3, .mirror = true } else Orient{ .rot = 1 })
            else
                (if (gate_left) Orient{ .rot = 3 } else Orient{ .rot = 1, .mirror = true });
        }
    }
    return out;
}

/// The net on the pin that sits left of centre under `o`, or `.none`.
fn leftNet(c: Ctx, d: DeviceIdx, o: Orient) ids.NetIdx {
    for (c.conductingPins(d)) |p| {
        if (o.apply(c.termAt(p)).x < 0) return c.netOf(p);
    }
    return .none;
}

fn hasControl(c: Ctx, d: DeviceIdx) bool {
    const lo, const hi = c.ir.pinRange(d);
    for (lo..hi) |p| {
        if (c.isControl(PinIdx.at(p))) return true;
    }
    return false;
}

/// Does `d`'s gate net connect to anything in a column strictly left of `d`'s own?
///
/// The whole of ALGORITHM.md's orientation rule. Returns false when `d` has no
/// control terminal, when its gate is floating, or when every other pin on the gate
/// net sits in `d`'s column or later — all three keep the default, gate-right.
///
/// Pins on unplaced devices and on rails contribute nothing: they have no column, so
/// they cannot be "earlier".
///
/// Asserts `d` is placed. Allocation-free; O(degree of the gate net).
pub fn gateFromLeft(c: Ctx, cols: Columns, d: DeviceIdx) bool {
    const my = cols.column_of[d.i()];
    std.debug.assert(my != .none);
    const lo, const hi = c.ir.pinRange(d);
    for (lo..hi) |pi| {
        const p = PinIdx.at(pi);
        if (!c.isControl(p)) continue;
        const net = c.netOf(p);
        if (net == .none) return false;
        for (c.members(net)) |q| {
            const col = cols.column_of[c.devOf(q).i()];
            if (col != .none and col.i() < my.i()) return true;
        }
        return false;
    }
    return false;
}

/// Which conducting pin of `dev` should face up the column?
///
/// Preference order, most specific first: a pin sharing a net with `above` (the
/// device stacked directly on top, `.none` for the topmost), then a power pin, then
/// any non-ground pin, then anything. Ties break on the lower pin index.
///
/// The first rule is the one that matters — it is what makes a stack's internal
/// conduction links vertical and adjacent instead of routed around. The rest only
/// decide the orientation of a column's endpoints, where power belongs at the top and
/// ground at the bottom.
///
/// Returns `.none` when `dev` has no conducting pin at all. Allocation-free.
pub fn upConductionPin(c: Ctx, dev: DeviceIdx, above: DeviceIdx) PinIdx {
    var best: PinIdx = .none;
    var best_rank: u8 = 255;
    for (c.conductingPins(dev)) |p| {
        const n = c.netOf(p);
        const rank: u8 = if (n == .none)
            3
        else if (above != .none and sharesNet(c, above, n))
            0
        else if (c.classOfNet(n) == .power)
            1
        else if (c.classOfNet(n) != .ground)
            2
        else
            3;
        if (rank < best_rank) {
            best_rank = rank;
            best = p;
        }
    }
    return best;
}

/// Does `d` have a conducting pin on `n`?
fn sharesNet(c: Ctx, d: DeviceIdx, n: ids.NetIdx) bool {
    for (c.conductingPins(d)) |p| {
        if (c.netOf(p) == n) return true;
    }
    return false;
}

/// Orientation for a two-terminal passive bridge in an in-field `.component` column.
///
/// When exactly one of its two nets is a spanning net, the bridge stands **vertical**
/// with that plate up, so the plate meets the spanning run's horizontal channel
/// head-on with no wrap-around. Otherwise it lies flat and delegates to
/// `bridgeMirror`.
///
/// Allocation-free apart from the scratch buffer `netColumns` needs, which the caller
/// supplies via `scratch` (at least `cols.count()` entries).
pub fn bridgeOrient(c: Ctx, cols: Columns, d: DeviceIdx, scratch: []ColumnIdx) Orient {
    const cps = c.conductingPins(d);
    if (cps.len == 2) {
        const a = netSpans(c, cols, cps[0], scratch);
        const b = netSpans(c, cols, cps[1], scratch);
        // Vertical, with the spanning plate up: it then meets the spanning run's
        // horizontal channel head-on instead of wrapping around the body.
        if (a and !b) return .{ .rot = 1 };
        if (b and !a) return .{ .rot = 3 };
    }
    return bridgeMirror(c, cols, d);
}

/// Is `p`'s net a spanning net over the in-field columns?
fn netSpans(c: Ctx, cols: Columns, p: PinIdx, scratch: []ColumnIdx) bool {
    const net = c.netOf(p);
    if (net == .none) return false;
    const all = colm.netColumns(c, cols, net, scratch);
    var n: usize = 0;
    for (all) |col| {
        if (!cols.inField(col)) continue;
        scratch[n] = col;
        n += 1;
    }
    if (n == 0) return false;
    return colm.classify(scratch[0..n], cols.kind) == .span_ge2;
}

/// Mirror a flat two-terminal bridge so each plate faces the side its net lives on.
///
/// Each pin votes with the *mean* column index of its net's other pins, compared as a
/// pair of integer rationals so no division and no float enters the comparison
/// (ARCHITECTURE.md: integers only in geometry). The pin whose net lives further left
/// goes left; a tie keeps the canonical orientation.
///
/// **Rail nets abstain** — see the module header. When only one pin gets a vote, that
/// pin faces the side its net sits on relative to this device's own column. When
/// neither does, the canonical orientation stands.
///
/// Returns the identity or a pure vertical-axis mirror; never a rotation. That is
/// deliberate: a flat bridge stays flat, and the only question this answers is which
/// plate is on the left.
///
/// Allocation-free.
pub fn bridgeMirror(c: Ctx, cols: Columns, d: DeviceIdx) Orient {
    const cps = c.conductingPins(d);
    if (cps.len != 2) return Orient.r0;
    const mirror: Orient = .{ .mirror = true };

    // Each pin votes with the mean column of its net's *other* pins, compared as a
    // pair of rationals so no division and no float enters the comparison.
    const va = netVote(c, cols, d, cps[0]);
    const vb = netVote(c, cols, d, cps[1]);
    const a_left_canon = c.termAt(cps[0]).x < c.termAt(cps[1]).x;
    const my: i64 = @intCast(cols.column_of[d.i()].i());

    var a_should_left: bool = undefined;
    var tie = false;
    if (va != null and vb != null) {
        const l = va.?.sum * vb.?.count;
        const r = vb.?.sum * va.?.count;
        a_should_left = l < r;
        tie = l == r;
    } else if (va) |v| {
        a_should_left = v.sum < my * v.count;
    } else if (vb) |v| {
        a_should_left = v.sum >= my * v.count;
    } else {
        // Rail nets abstain, so neither plate has an opinion: keep canonical.
        return Orient.r0;
    }
    if (a_left_canon == a_should_left or tie) return Orient.r0;
    return mirror;
}

/// Sum and count of the columns `p`'s net occupies away from `d`, or null when the
/// net abstains (a rail, a float, or nothing placed).
fn netVote(c: Ctx, cols: Columns, d: DeviceIdx, p: PinIdx) ?struct { sum: i64, count: i64 } {
    const net = c.netOf(p);
    if (net == .none or c.isRailNet(net)) return null;
    var sum: i64 = 0;
    var count: i64 = 0;
    for (c.members(net)) |q| {
        const dq = c.devOf(q);
        if (dq == d) continue;
        const col = cols.column_of[dq.i()];
        if (col == .none) continue;
        sum += @intCast(col.i());
        count += 1;
    }
    if (count == 0) return null;
    return .{ .sum = sum, .count = count };
}
