//! The four-phase one-pass evaluation of a single column order (§5), plus per-net routing
//! (§4) and the candidate metrics for the selection key (§6). x ⟂ y by construction: y comes
//! from phases 1–2, x from phases 3–4, and no margin/channel ever moves a device (Lemma 1).
//!
//! Spline devices are placed VERTICAL (ARCH §Case 1): the device is rotated so its two
//! conduction terminals stack on the column-centre axis (one top, one bottom) and the gate
//! exits horizontally to the left or right. Because conduction pins of stacked devices then
//! share an x, the within-spline wire is a straight vertical line — no Manhattan jog.

use crate::ctx::{Ctx, NetClass};
use crate::extract::{assign_columns, classify, column_of, net_columns, Case, Column, ColumnKind, Spline};
use ir::{DeviceIdx, NetIdx, Orientation, PinIdx, Physical, Pt, Rot};

const CELL_W: i32 = devices::CELL_WIDTH;
const HALF: i32 = CELL_W / 2;
const ABUT_GAP: i32 = 8; // minimum vertical gap when optimallen = 0 (abut)
const TAP_UNIT: i32 = 12; // extra vertical room per fan-out tap (optimallen)
const CH_BASE: i32 = 24; // base inter-column channel — clears a vertical device's gate stub
const TRACK_W: i32 = 8; // extra channel width per wire crossing a gap
const TRACK_H: i32 = 10; // margin track pitch
const MARGIN_GAP: i32 = 16; // clearance from device field to first margin track
const BUS_GAP: i32 = 24; // clearance from device field to the VDD/GND rail bus

/// Integer counts that order candidate layouts (§6). Compared lexicographically; never
/// summed with weights.
#[derive(Clone, Debug)]
pub struct Metrics {
    pub num_labels: u32,
    pub num_crossings: u32,
    pub num_staples: u32,
    pub total_span: u32,
    pub margin_tracks: u32,
    pub netid_seq: Vec<u32>,
}

impl Metrics {
    /// The lexicographic key (§6 `Key`). Lower is better.
    pub fn key(&self) -> (u32, u32, u32, u32, u32, &[u32]) {
        (
            self.num_labels,
            self.num_crossings,
            self.num_staples,
            self.total_span,
            self.margin_tracks,
            &self.netid_seq,
        )
    }
}

pub struct Evaluated {
    pub physical: Physical,
    pub n_columns: usize,
    pub metrics: Metrics,
    /// Per-device orientation the placer chose (vertical for spline devices). Written back
    /// into the IR so the renderer draws the bodies the way they were placed.
    pub orient: Vec<Orientation>,
}

fn apply_o(o: Orientation, p: devices::Pt) -> Pt {
    o.apply(Pt::new(p.x, p.y))
}
fn oriented_term(orient: &[Orientation], ctx: &Ctx, p: PinIdx) -> Pt {
    apply_o(orient[ctx.dev_of(p).index()], ctx.term_at(p))
}
fn oriented_y_extent(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx) -> (i32, i32) {
    let bb = ctx.class(d).bbox();
    let o = orient[d.index()];
    let mut mny = i32::MAX;
    let mut mxy = i32::MIN;
    for (x, y) in [(bb.min.x, bb.min.y), (bb.max.x, bb.min.y), (bb.min.x, bb.max.y), (bb.max.x, bb.max.y)] {
        let q = o.apply(Pt::new(x, y));
        mny = mny.min(q.y);
        mxy = mxy.max(q.y);
    }
    (mny, mxy)
}

struct NetInfo {
    net: NetIdx,
    cols: Vec<usize>,
    case: Case,
    /// representative pin in each touched column: (column, pin)
    rep: Vec<(usize, PinIdx)>,
    /// if this net touches a shared-column device's conduction terminal, the hub pin the
    /// branches fan to (ARCH §Case 2 / fan node).
    shared_hub: Option<PinIdx>,
}

/// Evaluate one fixed spline order in a single pass (§5 `Evaluate`).
pub fn evaluate(ctx: &Ctx, order: &[&Spline]) -> Evaluated {
    let cols = assign_columns(ctx, order);
    let ncol = cols.len();
    let col_of = column_of(ctx, &cols);

    // --- Phase 0: per-device orientation (ARCH §Case 1). Spline/shared devices go vertical
    //     with gate to the side its net comes from; component/rail devices stay horizontal. ---
    let orient = compute_orientation(ctx, &cols, &col_of);

    // Fan-node devices: shared by ≥2 branches. N=2 sits in its own Shared column; N>2 is anchored
    // onto its first branch (no column). Either way its conduction net is a hub the branches fan
    // to, so key the hub off branch count, not column kind (ARCH §Case 2 / fan node).
    let mut branch_count = vec![0u32; ctx.nd()];
    for s in order {
        for &d in s.iter() {
            branch_count[d.index()] += 1;
        }
    }
    let shared_dev: Vec<bool> = branch_count.iter().map(|&c| c >= 2).collect();

    // --- Phase 1: interior y per column. Spacing between stacked devices is `optimallen`
    //     (ARCH §Sizing): the shared net's fan-out tap room, abut when zero. ---
    let mut dev_y = vec![0i32; ctx.nd()];
    for c in &cols {
        let mut top = 0i32;
        let mut prev: Option<DeviceIdx> = None;
        for &d in &c.devices {
            let (mny, mxy) = oriented_y_extent(&orient, ctx, d);
            if let Some(p) = prev {
                top += optimallen(ctx, p, d, &col_of); // tap room for the net joining them
            }
            let oy = top - mny; // place so the device's top edge sits at `top`
            dev_y[d.index()] = oy;
            top = oy + mxy;
            prev = Some(d);
        }
    }
    let pin_iy = |dev_y: &[i32], p: PinIdx| dev_y[ctx.dev_of(p).index()] + oriented_term(&orient, ctx, p).y;

    // --- Classify every net once column membership is known (§Classify) ---
    let mut infos: Vec<NetInfo> = Vec::new();
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        let cs = net_columns(ctx, net, &col_of);
        if cs.is_empty() {
            continue; // rail-only net
        }
        let mut rep: Vec<(usize, PinIdx)> = Vec::new();
        for &p in ctx.members(net) {
            let c = col_of[ctx.dev_of(p).index()];
            if c != usize::MAX && !rep.iter().any(|&(rc, _)| rc == c) {
                rep.push((c, p));
            }
        }
        let case = classify(&cs);
        let shared_hub = ctx
            .members(net)
            .iter()
            .copied()
            .find(|&p| shared_dev[ctx.dev_of(p).index()] && ctx.conducts(p));
        infos.push(NetInfo { net, cols: cs, case, rep, shared_hub });
    }

    // --- Phase 2: rigid vertical offsets, one horizontal per adjacent pair (§5.2, Break B) ---
    let mut offset = vec![0i32; ncol];
    let mut chosen_h: Vec<Option<NetIdx>> = vec![None; ncol.saturating_sub(1)];
    for g in 0..ncol.saturating_sub(1) {
        let mut best: Option<(i32, u32, PinIdx, PinIdx)> = None; // (topy, id, pi, pj)
        for inf in &infos {
            if inf.case != Case::ImmediateNeighbor || inf.cols != vec![g, g + 1] {
                continue;
            }
            let pi = inf.rep.iter().find(|&&(c, _)| c == g).map(|&(_, p)| p);
            let pj = inf.rep.iter().find(|&&(c, _)| c == g + 1).map(|&(_, p)| p);
            let (Some(pi), Some(pj)) = (pi, pj) else { continue };
            let topy = pin_iy(&dev_y, pi).min(pin_iy(&dev_y, pj));
            let cand = (topy, inf.net.index() as u32, pi, pj);
            if best.is_none_or(|b| (cand.0, cand.1) < (b.0, b.1)) {
                best = Some(cand);
            }
        }
        if let Some((_, id, pi, pj)) = best {
            offset[g + 1] = offset[g] + pin_iy(&dev_y, pi) - pin_iy(&dev_y, pj);
            chosen_h[g] = Some(NetIdx::from_index(id as usize));
        } else {
            offset[g + 1] = offset[g]; // inherit gauge
        }
    }

    // --- Phase 3: margin tracks. ARCH §132: smallest-window-FIRST so a wide staple nests on
    //     an OUTER track and never blocks a narrower one inside it (the paper's left-edge order
    //     is wrong here). Track 0 is innermost. Tie-break by net id. ---
    let mut staples: Vec<&NetInfo> = infos.iter().filter(|i| i.case == Case::SpanGe2).collect();
    staples.sort_by_key(|i| (i.cols.last().unwrap() - i.cols[0], i.net.index() as u32));
    let mut track_of: std::collections::HashMap<u32, u32> = std::collections::HashMap::new();
    let mut track_end: Vec<usize> = Vec::new();
    for s in &staples {
        let (lo, hi) = (s.cols[0], *s.cols.last().unwrap());
        let t = (0..track_end.len())
            .find(|&t| track_end[t] < lo)
            .unwrap_or_else(|| {
                track_end.push(0);
                track_end.len() - 1
            });
        track_end[t] = hi;
        track_of.insert(s.net.index() as u32, t as u32);
    }
    let margin_tracks = track_end.len() as u32;

    // --- Phase 4: channel widths → column x (§5.4) ---
    let mut crossings = vec![0u32; ncol.saturating_sub(1)];
    for s in &staples {
        for g in s.cols[0]..*s.cols.last().unwrap() {
            crossings[g] += 1;
        }
    }
    for inf in &infos {
        if inf.case == Case::ImmediateNeighbor {
            let g = inf.cols[0];
            if g < crossings.len() {
                crossings[g] += 1;
            }
        }
    }
    let mut col_x = vec![0i32; ncol];
    if ncol > 0 {
        col_x[0] = HALF;
        for i in 1..ncol {
            let gap = CH_BASE + TRACK_W * crossings[i - 1] as i32;
            col_x[i] = col_x[i - 1] + CELL_W + gap;
        }
    }

    // --- Device positions (non-rail devices in their columns) ---
    let abs_y = |dev_y: &[i32], d: DeviceIdx| offset[col_of[d.index()]] + dev_y[d.index()];
    let mut pos = vec![Pt::new(0, 0); ctx.nd()];
    for c in &cols {
        for &d in &c.devices {
            pos[d.index()] = Pt::new(col_x[col_of[d.index()]], abs_y(&dev_y, d));
        }
    }

    // canvas extent over placed device pins; the VDD/GND buses sit just outside it
    let mut ctop = i32::MAX;
    let mut cbot = i32::MIN;
    for c in &cols {
        for &d in &c.devices {
            for p in ctx.pins(d) {
                let y = pos[d.index()].y + oriented_term(&orient, ctx, p).y;
                ctop = ctop.min(y);
                cbot = cbot.max(y);
            }
        }
    }
    if ctop > cbot {
        ctop = 0;
        cbot = 0;
    }
    let power_bus = ctop - BUS_GAP;
    let gnd_bus = cbot + BUS_GAP;

    // Rails sit ON their bus, centred over the columns their net spans (ARCH: VDD a rail
    // across the top, GND across the bottom); the bus router ties every spline end to it.
    for d in 0..ctx.nd() {
        let di = DeviceIdx(d as u32);
        if !ctx.is_rail(di) {
            continue;
        }
        let power = matches!(ctx.role(di), devices::SymbolRole::PowerRail);
        let mut xs: Vec<i32> = Vec::new();
        for p in ctx.pins(di) {
            if let Some(net) = ctx.net_of(p) {
                for &q in ctx.members(net) {
                    let c = col_of[ctx.dev_of(q).index()];
                    if c != usize::MAX {
                        xs.push(col_x[c]);
                    }
                }
            }
        }
        let cx = if xs.is_empty() { 0 } else { xs.iter().sum::<i32>() / xs.len() as i32 };
        pos[d] = Pt::new(cx, if power { power_bus } else { gnd_bus });
    }

    // pin coordinates parallel the Pins array
    let mut pin_xy = vec![Pt::new(0, 0); ctx.ir.pins.len()];
    for d in 0..ctx.nd() {
        let di = DeviceIdx(d as u32);
        for p in ctx.pins(di) {
            let t = oriented_term(&orient, ctx, p);
            pin_xy[p.index()] = Pt::new(pos[d].x + t.x, pos[d].y + t.y);
        }
    }

    // absolute device y-spans per column, for the direct-horizontal clearance test (§C tier 1)
    let mut col_yspans: Vec<Vec<(i32, i32)>> = vec![Vec::new(); ncol];
    for c in &cols {
        for &d in &c.devices {
            let (mny, mxy) = oriented_y_extent(&orient, ctx, d);
            let yc = pos[d.index()].y;
            col_yspans[col_of[d.index()]].push((yc + mny, yc + mxy));
        }
    }

    // --- Route every net (§4 RouteNet). Power/ground nets are horizontal rail buses; signal
    //     nets dispatch by case. Signal staples sit above the power bus. ---
    let top_margin = power_bus - MARGIN_GAP;
    let mut net_segs: Vec<Vec<Vec<Pt>>> = vec![Vec::new(); ctx.nn()];
    let mut num_labels = 0u32;
    for inf in &infos {
        let segs = &mut net_segs[inf.net.index()];
        match ctx.net_class(inf.net) {
            NetClass::Power => route_rail_bus(ctx, inf.net, &pin_xy, power_bus, segs),
            NetClass::Ground => route_rail_bus(ctx, inf.net, &pin_xy, gnd_bus, segs),
            NetClass::Signal => match inf.shared_hub {
                Some(hub) => route_fan(ctx, inf.net, hub, &pin_xy, segs),
                None => route_net(ctx, inf, &pin_xy, &chosen_h, &track_of, &col_yspans, top_margin, segs, &mut num_labels),
            },
        }
    }

    let physical = build_physical(ctx, pos, pin_xy, &net_segs);

    let num_staples = staples.len() as u32;
    let total_span: u32 = staples.iter().map(|s| (s.cols.last().unwrap() - s.cols[0]) as u32).sum();
    let num_crossings = count_crossings(&net_segs);
    let mut netid_seq: Vec<u32> = infos.iter().map(|i| i.net.index() as u32).collect();
    netid_seq.sort_unstable();
    let metrics = Metrics { num_labels, num_crossings, num_staples, total_span, margin_tracks, netid_seq };

    Evaluated { physical, n_columns: ncol, metrics, orient }
}

/// ARCH §Case 1: orient spline/shared devices vertically. The terminal joining the device
/// above sits at top, the gate exits to the side its net arrives from. Component, signal-
/// series and rail devices keep their horizontal authoring.
fn compute_orientation(ctx: &Ctx, cols: &[Column], col_of: &[usize]) -> Vec<Orientation> {
    let mut orient = vec![Orientation::H; ctx.nd()];
    for (ci, col) in cols.iter().enumerate() {
        if !matches!(col.kind, ColumnKind::Spline | ColumnKind::Shared) {
            continue;
        }
        for (i, &d) in col.devices.iter().enumerate() {
            let above = if i > 0 { Some(col.devices[i - 1]) } else { None };
            // the device's terminal that connects upward (canonical-left vs canonical-right)
            let up_left = up_conduction_pin(ctx, d, above)
                .map(|p| ctx.term_at(p).x < 0)
                .unwrap_or(true);
            let gate_left = gate_from_left(ctx, d, col_of, ci);
            // R90 keeps the canonical-left terminal on top & gate right; mirror/R270 flip those.
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

/// The conducting pin of `dev` that connects upward: shared with the device above, else a
/// pin on a power net (top of column), else the first conducting pin.
fn up_conduction_pin(ctx: &Ctx, dev: DeviceIdx, above: Option<DeviceIdx>) -> Option<PinIdx> {
    let cps = ctx.conducting_pins(dev);
    if let Some(a) = above {
        let anets: Vec<Option<NetIdx>> = ctx.conducting_pins(a).iter().map(|&p| ctx.net_of(p)).collect();
        for &p in &cps {
            if ctx.net_of(p).is_some() && anets.contains(&ctx.net_of(p)) {
                return Some(p);
            }
        }
    }
    for &p in &cps {
        if let Some(n) = ctx.net_of(p) {
            if ctx.net_class(n) == NetClass::Power {
                return Some(p);
            }
        }
    }
    // no rail above or on this device: the upper terminal is the non-ground one (toward
    // supply), so a top device with an internal-node source still orients sensibly.
    for &p in &cps {
        if ctx.net_of(p).is_some_and(|n| ctx.net_class(n) != NetClass::Ground) {
            return Some(p);
        }
    }
    cps.first().copied()
}

/// Does this device's gate net arrive from a column to the left? (ARCH §Case 1.)
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

/// Tap room for the net joining two stacked devices (ARCH §Sizing): `optimallen = N − (#
/// in-spline connections)`, where N is the net's degree and in-spline connections are its
/// pins on devices in the same column (the two stacked conductors, plus any same-column gate
/// or feedback tap). `optimallen == 0` ⇒ abut (zero extra gap).
fn optimallen(ctx: &Ctx, a: DeviceIdx, b: DeviceIdx, col_of: &[usize]) -> i32 {
    let bnets: Vec<Option<NetIdx>> = ctx.conducting_pins(b).iter().map(|&p| ctx.net_of(p)).collect();
    let shared = ctx
        .conducting_pins(a)
        .into_iter()
        .filter_map(|p| ctx.net_of(p))
        .find(|n| bnets.contains(&Some(*n)));
    match shared {
        Some(net) => {
            let col = col_of[a.index()];
            let in_spline = ctx
                .members(net)
                .iter()
                .filter(|&&p| col_of[ctx.dev_of(p).index()] == col)
                .count();
            let optimallen = (ctx.degree(net) as i32 - in_spline as i32).max(0);
            optimallen * TAP_UNIT // 0 ⇒ abut
        }
        None => ABUT_GAP,
    }
}

/// A fan-node net (ARCH §Case 2): the branches connect to a shared/tail device's conduction
/// terminal. Route as a short bus at the hub pin's y, with each branch pin dropping to it —
/// the Manhattan, no-fallback connection the shared device demands.
fn route_fan(ctx: &Ctx, net: NetIdx, hub_pin: PinIdx, pin_xy: &[Pt], out: &mut Vec<Vec<Pt>>) {
    let hub = pin_xy[hub_pin.index()];
    let pts: Vec<Pt> = ctx.members(net).iter().map(|&p| pin_xy[p.index()]).collect();
    if pts.len() < 2 {
        return;
    }
    let minx = pts.iter().map(|p| p.x).min().unwrap().min(hub.x);
    let maxx = pts.iter().map(|p| p.x).max().unwrap().max(hub.x);
    out.push(vec![Pt::new(minx, hub.y), Pt::new(maxx, hub.y)]); // bus at the hub level
    for p in &pts {
        if p.y != hub.y {
            out.push(vec![*p, Pt::new(p.x, hub.y)]); // drop the branch pin to the hub
        }
    }
}

/// A power/ground net as a horizontal rail bus at `bus_y`, with a vertical drop from every
/// member pin (including the rail symbol's) up/down to it. ARCH: VDD across the top, GND
/// across the bottom — never an in-field staple that skips the rail symbol.
fn route_rail_bus(ctx: &Ctx, net: NetIdx, pin_xy: &[Pt], bus_y: i32, out: &mut Vec<Vec<Pt>>) {
    let pts: Vec<Pt> = ctx.members(net).iter().map(|&p| pin_xy[p.index()]).collect();
    if pts.len() < 2 {
        return;
    }
    let minx = pts.iter().map(|p| p.x).min().unwrap();
    let maxx = pts.iter().map(|p| p.x).max().unwrap();
    out.push(vec![Pt::new(minx, bus_y), Pt::new(maxx, bus_y)]); // the bus
    for p in &pts {
        if p.y != bus_y {
            out.push(vec![*p, Pt::new(p.x, bus_y)]); // drop to the bus
        }
    }
}

/// §4 RouteNet: dispatch by case. Vertical devices put conduction pins on the column axis, so
/// the within-spline wire is a straight line; only off-axis taps (feedback gate↔drain) jog.
#[allow(clippy::too_many_arguments)]
fn route_net(
    ctx: &Ctx,
    inf: &NetInfo,
    pin_xy: &[Pt],
    chosen_h: &[Option<NetIdx>],
    track_of: &std::collections::HashMap<u32, u32>,
    col_yspans: &[Vec<(i32, i32)>],
    top_margin: i32,
    out: &mut Vec<Vec<Pt>>,
    num_labels: &mut u32,
) {
    let pin_at = |p: PinIdx| pin_xy[p.index()];
    match inf.case {
        Case::WithinSpline => {
            // all of the net's pins in this column, sorted top→bottom
            let mut ps: Vec<Pt> = ctx.members(inf.net).iter().map(|&q| pin_at(q)).collect();
            if ps.len() < 2 {
                return;
            }
            ps.sort_by_key(|p| (p.y, p.x));
            if ps.iter().all(|p| p.x == ps[0].x) {
                out.push(ps); // straight vertical spline wire (pins share the column axis)
            } else {
                // feedback / off-axis tap: Manhattan through a side channel clear of the body
                let sx = ps.iter().map(|p| p.x).max().unwrap() + HALF + 6;
                for w in ps.windows(2) {
                    out.push(vec![w[0], Pt::new(sx, w[0].y), Pt::new(sx, w[1].y), w[1]]);
                }
            }
        }
        Case::ImmediateNeighbor => {
            let g = inf.cols[0];
            let pi = inf.rep.iter().find(|&&(c, _)| c == g).map(|&(_, p)| pin_at(p));
            let pj = inf.rep.iter().find(|&&(c, _)| c == g + 1).map(|&(_, p)| pin_at(p));
            if let (Some(a), Some(b)) = (pi, pj) {
                if chosen_h.get(g).copied().flatten() == Some(inf.net) && a.y == b.y {
                    out.push(vec![a, b]); // clean horizontal
                } else {
                    let mx = (a.x + b.x) / 2; // Z-jog in the shared gap
                    out.push(vec![a, Pt::new(mx, a.y), Pt::new(mx, b.y), b]);
                }
            }
        }
        Case::SpanGe2 => {
            // §subcase C ladder, in order: (1) direct horizontal if clear, (2) margin staple,
            // (3) net label (loud). Only non-neighbour nets enter here.
            let lo = inf.cols[0];
            let hi = *inf.cols.last().unwrap();
            let a = inf.rep.iter().find(|&&(c, _)| c == lo).map(|&(_, p)| pin_at(p));
            let b = inf.rep.iter().find(|&&(c, _)| c == hi).map(|&(_, p)| pin_at(p));
            if let (Some(a), Some(b)) = (a, b) {
                if a.y == b.y && horizontal_clear(col_yspans, lo, hi, a.y) {
                    out.push(vec![a, b]); // tier 1: uncongested straight run
                } else {
                    let t = track_of.get(&(inf.net.index() as u32)).copied().unwrap_or(0) as i32;
                    let my = top_margin - t * TRACK_H; // tier 2: margin staple, above the power bus
                    out.push(vec![a, Pt::new(a.x, my), Pt::new(b.x, my), b]);
                }
            } else {
                *num_labels += 1; // tier 3: last-resort net label (LOUD)
            }
        }
    }
}

fn build_physical(ctx: &Ctx, pos: Vec<Pt>, pin_xy: Vec<Pt>, net_segs: &[Vec<Vec<Pt>>]) -> Physical {
    let mut net_seg = Vec::with_capacity(ctx.nn() + 1);
    let mut seg_pt = vec![0u32];
    let mut wire_pts: Vec<Pt> = Vec::new();
    net_seg.push(0u32);
    let mut seg_count = 0u32;
    for n in 0..ctx.nn() {
        for s in &net_segs[n] {
            for &p in s {
                wire_pts.push(p);
            }
            seg_pt.push(wire_pts.len() as u32);
            seg_count += 1;
        }
        net_seg.push(seg_count);
    }
    let junctions = compute_junctions(ctx, &pin_xy, net_segs);
    Physical { pos, pin_xy, net_seg, seg_pt, wire_pts, junctions }
}

/// Connection dots. A point needs a dot when ≥3 same-net wire "arms" meet there: a segment with
/// the point as an endpoint = 1 arm, a segment passing through its interior = 2 arms, a device
/// pin at the point = 1 arm. Two arms is a corner or a wire reaching a pin (no dot); three is a
/// T-tap or fan. Different-net wires never share a net's arm count, so a crossover gets no dot
/// and correctly reads as "not connected".
fn compute_junctions(ctx: &Ctx, pin_xy: &[Pt], net_segs: &[Vec<Vec<Pt>>]) -> Vec<Pt> {
    let mut junctions = Vec::new();
    for n in 0..ctx.nn() {
        let mut edges: Vec<(Pt, Pt)> = Vec::new();
        for poly in &net_segs[n] {
            for w in poly.windows(2) {
                if w[0] != w[1] {
                    edges.push((w[0], w[1]));
                }
            }
        }
        if edges.is_empty() {
            continue;
        }
        let pins: Vec<Pt> =
            ctx.members(NetIdx::from_index(n)).iter().map(|&p| pin_xy[p.index()]).collect();
        let mut cand: Vec<Pt> = edges.iter().flat_map(|&(a, b)| [a, b]).collect();
        cand.extend(pins.iter().copied());
        cand.sort_by_key(|p| (p.x, p.y));
        cand.dedup();
        for &p in &cand {
            let mut arms = pins.iter().filter(|&&q| q == p).count();
            for &(a, b) in &edges {
                if a == p || b == p {
                    arms += 1;
                } else if on_segment_interior(p, a, b) {
                    arms += 2;
                }
            }
            if arms >= 3 {
                junctions.push(p);
            }
        }
    }
    junctions.sort_by_key(|p| (p.x, p.y));
    junctions.dedup();
    junctions
}

/// Is `p` strictly inside the axis-aligned segment a–b (not an endpoint)?
fn on_segment_interior(p: Pt, a: Pt, b: Pt) -> bool {
    if a.y == b.y && p.y == a.y {
        (a.x.min(b.x) < p.x) && (p.x < a.x.max(b.x))
    } else if a.x == b.x && p.x == a.x {
        (a.y.min(b.y) < p.y) && (p.y < a.y.max(b.y))
    } else {
        false
    }
}

/// Is a horizontal line at height `y` from column `lo` to `hi` clear of every device in the
/// columns strictly between them? (ARCH §subcase C tier 1: direct horizontal if uncongested.)
fn horizontal_clear(col_yspans: &[Vec<(i32, i32)>], lo: usize, hi: usize, y: i32) -> bool {
    for c in (lo + 1)..hi {
        for &(y0, y1) in &col_yspans[c] {
            if y0 <= y && y <= y1 {
                return false;
            }
        }
    }
    true
}

/// Count actual drawn-wire crossings: pairs of orthogonal segments from DIFFERENT nets whose
/// interiors intersect (same-net touches are junctions, not crossings).
fn count_crossings(net_segs: &[Vec<Vec<Pt>>]) -> u32 {
    let mut segs: Vec<(usize, Pt, Pt)> = Vec::new();
    for (ni, polys) in net_segs.iter().enumerate() {
        for poly in polys {
            for w in poly.windows(2) {
                segs.push((ni, w[0], w[1]));
            }
        }
    }
    let mut n = 0u32;
    for i in 0..segs.len() {
        for j in (i + 1)..segs.len() {
            if segs[i].0 != segs[j].0 && cross(segs[i].1, segs[i].2, segs[j].1, segs[j].2) {
                n += 1;
            }
        }
    }
    n
}

/// Strict interior intersection of two axis-aligned segments (one horizontal, one vertical).
fn cross(a1: Pt, a2: Pt, b1: Pt, b2: Pt) -> bool {
    let a_h = a1.y == a2.y;
    let b_h = b1.y == b2.y;
    if a_h == b_h {
        return false; // parallel: collinear overlaps aren't counted as crossings
    }
    let (h1, h2, v1, v2) = if a_h { (a1, a2, b1, b2) } else { (b1, b2, a1, a2) };
    let hy = h1.y;
    let (hx0, hx1) = (h1.x.min(h2.x), h1.x.max(h2.x));
    let vx = v1.x;
    let (vy0, vy1) = (v1.y.min(v2.y), v1.y.max(v2.y));
    hx0 < vx && vx < hx1 && vy0 < hy && hy < vy1
}
