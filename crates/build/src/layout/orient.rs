//! Phase 0 — per-device orientation — and phase 1 vertical spacing helpers.

use super::geom::{apply_o, oriented_term};
use crate::ctx::{Ctx, NetClass};
use crate::extract::{Case, Column, ColumnKind, classify, net_columns};
use config::cfg;
use ir::{DeviceIdx, NetIdx, Orientation, PinIdx, Rot};

pub(super) fn compute_orientation(
    ctx: &Ctx,
    cols: &[Column],
    col_of: &[usize],
) -> Vec<Orientation> {
    let mut orient = vec![Orientation::H; ctx.nd()];
    for (ci, col) in cols.iter().enumerate() {
        if col.kind == ColumnKind::SignalSeries && col.devices.len() >= 2 {
            // Antiparallel pass group (e.g. transmission gate): no rail feeds it,
            // so devices lie flat, gates facing outward, and the mirror is picked
            // so each conduction net keeps its side — the side wires stack.
            let left_net = |d: DeviceIdx, o: Orientation| -> Option<NetIdx> {
                ctx.conducting_pins(d)
                    .iter()
                    .copied()
                    .find(|&p| apply_o(o, ctx.term_at(p)).x < 0)
                    .and_then(|p| ctx.net_of(p))
            };
            let head_left = left_net(col.devices[0], Orientation::H);
            for (i, &d) in col.devices.iter().enumerate() {
                orient[d.index()] = if i == 0 {
                    Orientation::H
                } else {
                    let flipped = Orientation::new(Rot::R180, true); // gate down, sides kept
                    if left_net(d, flipped) == head_left {
                        flipped
                    } else {
                        Orientation::new(Rot::R180, false)
                    }
                };
            }
            continue;
        }
        for (i, &d) in col.devices.iter().enumerate() {
            let has_gate = ctx.pins(d).any(|p| ctx.role_of(p).is_control());
            if matches!(
                col.kind,
                ColumnKind::Component | ColumnKind::SignalSeries | ColumnKind::Feedback
            ) && !has_gate
            {
                // Passive bridge: stand vertical between a spanning net's channel
                // and a local run, or lie flat facing each net's side — a wire
                // must never cross the body to reach the far plate.
                orient[d.index()] = if col.kind == ColumnKind::Component {
                    bridge_orient(ctx, d, col_of, cols)
                } else {
                    bridge_mirror(ctx, d, col_of)
                };
                continue;
            }
            if col.kind == ColumnKind::Feedback {
                continue; // gated feedback devices stay canonical
            }
            let above = (i > 0).then(|| col.devices[i - 1]);
            let up_left = up_conduction_pin(ctx, d, above)
                .map(|p| ctx.term_at(p).x < 0)
                .unwrap_or(true);
            let gate_left = gate_from_left(ctx, d, col_of, ci);
            orient[d.index()] = match (up_left, gate_left) {
                (true, false) => Orientation::new(Rot::R90, false),
                (true, true) => Orientation::new(Rot::R270, true),
                (false, false) => Orientation::new(Rot::R90, true),
                (false, true) => Orientation::new(Rot::R270, false),
            };
        }
    }
    orient
}

/// Orientation for an in-field 2-pin passive bridge. When exactly one of its
/// nets spans (routes in a channel above the local wiring) the bridge stands
/// VERTICAL with that plate up: each plate then meets its net's horizontal run
/// head-on, no wrap-around. Otherwise it lies flat via [`bridge_mirror`].
fn bridge_orient(ctx: &Ctx, d: DeviceIdx, col_of: &[usize], cols: &[Column]) -> Orientation {
    let cps = ctx.conducting_pins(d);
    if cps.len() == 2 {
        let col_kinds: Vec<ColumnKind> = cols.iter().map(|c| c.kind).collect();
        let spans = |p: PinIdx| -> bool {
            ctx.net_of(p).is_some_and(|net| {
                let cs: Vec<usize> = net_columns(ctx, net, col_of)
                    .into_iter()
                    .filter(|&c| cols[c].in_field())
                    .collect();
                !cs.is_empty() && classify(&cs, &col_kinds) == Case::SpanGe2
            })
        };
        match (spans(cps[0]), spans(cps[1])) {
            (true, false) => return Orientation::V, // pin 0 up
            (false, true) => return Orientation::new(Rot::R270, false), // pin 1 up
            _ => {}
        }
    }
    bridge_mirror(ctx, d, col_of)
}

/// Mirror a 2-pin passive bridge so each pin faces the side its net lives on:
/// the pin whose external connections sit in lower-indexed columns goes left.
fn bridge_mirror(ctx: &Ctx, d: DeviceIdx, col_of: &[usize]) -> Orientation {
    let cps = ctx.conducting_pins(d);
    if cps.len() != 2 {
        return Orientation::H;
    }
    // Mean external column index of a pin's net, as a (sum, count) rational.
    // Rail nets abstain: "connects to ground/power" places the pin at the
    // bus, not at whichever columns other rail-tied devices occupy — letting
    // them vote flipped grounded bipoles to face AWAY from their one signal
    // neighbour (an unroutable plate, so the net fell back to labels).
    let side = |p: PinIdx| -> Option<(usize, usize)> {
        let net = ctx.net_of(p)?;
        if ctx.net_class(net) != NetClass::Signal {
            return None;
        }
        let cs: Vec<usize> = ctx
            .members(net)
            .iter()
            .filter(|&&q| ctx.dev_of(q) != d)
            .map(|&q| col_of[ctx.dev_of(q).index()])
            .filter(|&c| c != usize::MAX)
            .collect();
        (!cs.is_empty()).then(|| (cs.iter().sum(), cs.len()))
    };
    let a_left_canon = ctx.term_at(cps[0]).x < ctx.term_at(cps[1]).x;
    let (a_should_left, tie) = match (side(cps[0]), side(cps[1])) {
        (Some((sa, na)), Some((sb, nb))) => (sa * nb < sb * na, sa * nb == sb * na),
        // One sided vote (the other pin rails or floats): the signal pin
        // faces the side its net lives on relative to this device's column.
        (Some((sa, na)), None) => (sa < col_of[d.index()] * na, false),
        (None, Some((sb, nb))) => (sb >= col_of[d.index()] * nb, false),
        (None, None) => return Orientation::H,
    };
    if a_left_canon == a_should_left || tie {
        Orientation::H
    } else {
        Orientation::new(Rot::R0, true)
    }
}

/// Which conduction pin faces up the column?
fn up_conduction_pin(ctx: &Ctx, dev: DeviceIdx, above: Option<DeviceIdx>) -> Option<PinIdx> {
    let above_nets: Vec<NetIdx> = above
        .map(|a| {
            ctx.conducting_pins(a)
                .iter()
                .filter_map(|&p| ctx.net_of(p))
                .collect()
        })
        .unwrap_or_default();
    // Preference: shares a net with the device above > power > any non-ground > anything.
    let rank = |p: PinIdx| match ctx.net_of(p) {
        Some(n) if above_nets.contains(&n) => 0,
        Some(n) if ctx.net_class(n) == NetClass::Power => 1,
        Some(n) if ctx.net_class(n) != NetClass::Ground => 2,
        _ => 3,
    };
    ctx.conducting_pins(dev)
        .iter()
        .copied()
        .min_by_key(|&p| rank(p))
}

/// Does the device's gate net connect to anything in an earlier column?
fn gate_from_left(ctx: &Ctx, d: DeviceIdx, col_of: &[usize], my_col: usize) -> bool {
    let gate = ctx.pins(d).find(|&p| ctx.role_of(p).is_control());
    gate.and_then(|p| ctx.net_of(p))
        .map(|net| {
            ctx.members(net).iter().any(|&q| {
                let c = col_of[ctx.dev_of(q).index()];
                c != usize::MAX && c < my_col
            })
        })
        .unwrap_or(false)
}

/// Gap between two stacked devices: `optimallen = degree − in_spline − 1`
/// tap units (the −1 subtracts the conduction link itself), or the abut gap
/// when the facing terminals are not linked.
pub(super) fn optimallen(
    ctx: &Ctx,
    orient: &[Orientation],
    a: DeviceIdx,
    b: DeviceIdx,
    col_of: &[usize],
) -> i32 {
    // A flat (horizontal) device has both conduction pins on one row — there is
    // no vertical conduction link to absorb taps, so stacked neighbours just abut.
    let flat = |d: DeviceIdx| {
        let ys: Vec<i32> = ctx
            .conducting_pins(d)
            .iter()
            .map(|&p| oriented_term(orient, ctx, p).y)
            .collect();
        ys.len() >= 2 && ys.windows(2).all(|w| w[0] == w[1])
    };
    if flat(a) || flat(b) {
        return cfg().layout.abut_gap;
    }
    // The link net is the one between the FACING terminals (a's lowest pin, b's
    // highest). Matching any shared net instead would abut antiparallel devices,
    // whose far terminals share nets without being a conduction link.
    let low_a = ctx
        .conducting_pins(a)
        .iter()
        .copied()
        .max_by_key(|&p| oriented_term(orient, ctx, p).y);
    let high_b = ctx
        .conducting_pins(b)
        .iter()
        .copied()
        .min_by_key(|&p| oriented_term(orient, ctx, p).y);
    let link = match (
        low_a.and_then(|p| ctx.net_of(p)),
        high_b.and_then(|p| ctx.net_of(p)),
    ) {
        (Some(x), Some(y)) if x == y => Some(x),
        _ => None,
    };
    match link {
        Some(net) => {
            let col = col_of[a.index()];
            let in_spline = ctx
                .members(net)
                .iter()
                .filter(|&&p| col_of[ctx.dev_of(p).index()] == col)
                .count();
            let len =
                (ctx.degree(net) as i32 - in_spline as i32 - 1).max(0) * cfg().layout.tap_unit;
            // Geometric hosts connect pins only through wires: an abutted
            // (coincident) pin pair reads as two dangles there, so on a grid
            // host keep at least one grid of drawable wire between them.
            let g = cfg().layout.grid;
            if g > 1 { len.max(g) } else { len }
        }
        None => cfg().layout.abut_gap,
    }
}

/// Does the net drive backwards (a conduction pin in a later column than a gate)?
pub(super) fn net_is_backward(ctx: &Ctx, net: NetIdx, col_of: &[usize], cols: &[Column]) -> bool {
    let (mut gate_min, mut drv_max) = (usize::MAX, 0usize);
    let (mut has_gate, mut has_drv) = (false, false);
    for &p in ctx.members(net) {
        let c = col_of[ctx.dev_of(p).index()];
        if c == usize::MAX || !cols[c].in_field() {
            continue;
        }
        if ctx.role_of(p).is_control() {
            gate_min = gate_min.min(c);
            has_gate = true;
        } else if ctx.conducts(p) {
            drv_max = drv_max.max(c);
            has_drv = true;
        }
    }
    has_gate && has_drv && drv_max > gate_min
}
