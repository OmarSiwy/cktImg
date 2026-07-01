//! Single-pass evaluation of a column order.
//!
//! The file reads top-down in pipeline order (stepdown rule — each section's
//! helpers appear right after the code that calls them):
//!
//!   evaluate()            the whole pipeline, phase by phase
//!   § orientation         phase 0: rotate/mirror each device
//!   § oriented geometry   terminal / bounding-box coordinates under orientation
//!   § vertical spacing    phase 1 helpers: stacking gaps, backward-net detection
//!   § routing             phases 5–6: buses, per-net Manhattan routes
//!   § output & metrics    phase 7: pack Physical, junction dots, crossing count

use crate::ctx::{Ctx, NetClass};
use crate::extract::{
    assign_columns, branch_counts, classify, column_of, net_columns, Case, Column, ColumnKind, Spline,
};
use ir::{DeviceIdx, Label, NetIdx, Orientation, PinIdx, Physical, Pt, Rect, Rot};

use config::cfg;

const CELL_W: i32 = devices::CELL_WIDTH;
const HALF: i32 = CELL_W / 2;
/// Clearance of a side-channel detour beyond the widest body it passes.
const SIDE_CLEAR: i32 = 6;

/// Quality metrics of one evaluated order; `key()` is the lexicographic search objective.
#[derive(Clone, Debug)]
pub struct Metrics {
    pub num_labels: u32,
    pub num_forward_margin: u32,
    pub num_body_hits: u32,
    pub num_crossings: u32,
    pub num_staples: u32,
    pub total_span: u32,
    pub margin_tracks: u32,
    pub netid_seq: Vec<u32>,
}

impl Metrics {
    pub fn key(&self) -> (u32, u32, u32, u32, u32, u32, u32, &[u32]) {
        (
            self.num_labels,
            self.num_body_hits,
            self.num_staples,
            self.total_span,
            self.num_crossings,
            self.num_forward_margin,
            self.margin_tracks,
            &self.netid_seq,
        )
    }
}

pub struct Evaluated {
    pub physical: Physical,
    pub n_columns: usize,
    pub metrics: Metrics,
    pub orient: Vec<Orientation>,
    pub fallbacks: Vec<(NetIdx, &'static str)>,
}

/// Per-net routing facts computed once after column assignment.
struct NetInfo {
    net: NetIdx,
    cols: Vec<usize>,
    case: Case,
    /// One representative pin per column (control pins preferred).
    rep: Vec<(usize, PinIdx)>,
    shared_hub: Option<PinIdx>,
    backward: bool,
}

impl NetInfo {
    fn rep_in(&self, col: usize) -> Option<PinIdx> {
        self.rep.iter().find(|&&(c, _)| c == col).map(|&(_, p)| p)
    }
}

/// Read-only state the per-net router needs.
struct RouteCtx<'a> {
    ctx: &'a Ctx<'a>,
    pin_xy: &'a [Pt],
    chosen_h: &'a [Option<NetIdx>],
    track_of: &'a [Option<u32>],
    riser_x: &'a [Option<(i32, i32)>],
    col_boxes: &'a [Vec<Rect>],
    col_of: &'a [usize],
    top_margin: i32,
}

impl RouteCtx<'_> {
    fn pin_at(&self, p: PinIdx) -> Pt {
        self.pin_xy[p.index()]
    }
}

pub fn evaluate(ctx: &Ctx, order: &[&Spline]) -> Evaluated {
    // Phase 0: columns + per-device orientation
    let cols = assign_columns(ctx, order);
    let ncol = cols.len();
    let col_of = column_of(ctx, &cols);
    let col_kinds: Vec<ColumnKind> = cols.iter().map(|c| c.kind).collect();
    let orient = compute_orientation(ctx, &cols, &col_of);
    let shared_dev: Vec<bool> = branch_counts(ctx, order).iter().map(|&c| c >= 2).collect();

    // Phase 1: interior y per column (optimallen spacing between stacked devices)
    let mut dev_y = vec![0i32; ctx.nd()];
    for c in &cols {
        let mut top = 0i32;
        let mut prev: Option<DeviceIdx> = None;
        for &d in &c.devices {
            let r = oriented_box_rel(&orient, ctx, d);
            if let Some(p) = prev {
                top += optimallen(ctx, p, d, &col_of);
            }
            dev_y[d.index()] = top - r.min.y;
            top = dev_y[d.index()] + r.max.y;
            prev = Some(d);
        }
    }
    let pin_iy = |p: PinIdx| -> i32 {
        dev_y[ctx.dev_of(p).index()] + oriented_term(&orient, ctx, p).y
    };

    // Classify every net once column membership is known
    let mut infos: Vec<NetInfo> = Vec::new();
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        // Feedback-column pins are margin-resident — exclude them from
        // classification, representative selection, and backward detection.
        let cs: Vec<usize> = net_columns(ctx, net, &col_of)
            .into_iter()
            .filter(|&c| cols[c].in_field())
            .collect();
        if cs.is_empty() {
            continue;
        }
        let mut rep: Vec<(usize, PinIdx)> = Vec::new();
        for &p in ctx.members(net) {
            let c = col_of[ctx.dev_of(p).index()];
            if c == usize::MAX {
                continue;
            }
            if let Some(entry) = rep.iter_mut().find(|e| e.0 == c) {
                if ctx.role_of(p).is_control() && !ctx.role_of(entry.1).is_control() {
                    entry.1 = p;
                }
            } else {
                rep.push((c, p));
            }
        }
        let case = classify(&cs, &col_kinds);
        let shared_hub = ctx
            .members(net)
            .iter()
            .copied()
            .find(|&p| shared_dev[ctx.dev_of(p).index()] && ctx.conducts(p));
        let backward = net_is_backward(ctx, net, &col_of, &cols);
        infos.push(NetInfo { net, cols: cs, case, rep, shared_hub, backward });
    }

    // Phase 2: rigid vertical offsets (one horizontal alignment per adjacent pair)
    let mut offset = vec![0i32; ncol];
    let mut chosen_h: Vec<Option<NetIdx>> = vec![None; ncol.saturating_sub(1)];
    for g in 0..ncol.saturating_sub(1) {
        let mut best: Option<(i32, u32, PinIdx, PinIdx, usize)> = None;
        for inf in &infos {
            if inf.case != Case::ImmediateNeighbor {
                continue;
            }
            let (lo, hi) = (inf.cols[0], *inf.cols.last().unwrap());
            if lo > g || hi != g + 1 {
                continue;
            }
            let (Some(pi), Some(pj)) = (inf.rep_in(lo), inf.rep_in(hi)) else { continue };
            let topy = pin_iy(pi).min(pin_iy(pj));
            let cand = (topy, inf.net.index() as u32, pi, pj, lo);
            if best.is_none_or(|b| (cand.0, cand.1) < (b.0, b.1)) {
                best = Some(cand);
            }
        }
        if let Some((_, id, pi, pj, lo)) = best {
            offset[g + 1] = offset[lo] + pin_iy(pi) - pin_iy(pj);
            chosen_h[g] = Some(NetIdx::from_index(id as usize));
        } else {
            offset[g + 1] = offset[g];
        }
    }

    // Phase 3: margin tracks (smallest-window-first packing)
    let mut staples: Vec<&NetInfo> = infos.iter().filter(|i| i.case == Case::SpanGe2).collect();
    staples.sort_by_key(|i| (i.cols.last().unwrap() - i.cols[0], i.net.index() as u32));
    let mut track_of: Vec<Option<u32>> = vec![None; ctx.nn()];
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
        track_of[s.net.index()] = Some(t as u32);
    }
    let margin_tracks = track_end.len() as u32;

    // Phase 3.5: staple exit sides + per-side riser lanes
    let tw = cfg().layout.track_w;
    let mut front_lanes = vec![0u32; ncol];
    let mut back_lanes = vec![0u32; ncol];
    let pin_side = |p: PinIdx, fallback: bool| -> bool {
        let tx = oriented_term(&orient, ctx, p).x;
        let bb = oriented_box_rel(&orient, ctx, ctx.dev_of(p));
        if tx >= bb.max.x {
            true
        } else if tx <= bb.min.x {
            false
        } else {
            fallback
        }
    };
    let mut riser_info: Vec<Option<(usize, bool, u32, usize, bool, u32)>> = vec![None; ctx.nn()];
    for s in &staples {
        let (lo, hi) = (s.cols[0], *s.cols.last().unwrap());
        let lo_back = s.rep_in(lo).map(|p| pin_side(p, lo != 0)).unwrap_or(lo != 0);
        let hi_back = s.rep_in(hi).map(|p| pin_side(p, hi == ncol - 1)).unwrap_or(hi == ncol - 1);
        let take = |lanes: &mut Vec<u32>, c: usize| -> u32 {
            let v = lanes[c];
            lanes[c] += 1;
            v
        };
        let lo_lane = if lo_back { take(&mut back_lanes, lo) } else { take(&mut front_lanes, lo) };
        let hi_lane = if hi_back { take(&mut back_lanes, hi) } else { take(&mut front_lanes, hi) };
        riser_info[s.net.index()] = Some((lo, lo_back, lo_lane, hi, hi_back, hi_lane));
    }

    // Phase 4: channel widths → column x
    let mut immediate = vec![0u32; ncol.saturating_sub(1)];
    for inf in &infos {
        if inf.case == Case::ImmediateNeighbor {
            let g = inf.cols[0];
            if g < immediate.len() {
                immediate[g] += 1;
            }
        }
    }
    let gap_width = |g: usize| tw * (1 + back_lanes[g] + front_lanes[g + 1] + immediate[g]) as i32;
    let mut col_x = vec![0i32; ncol];
    if ncol > 0 {
        col_x[0] = HALF + front_lanes[0] as i32 * tw;
        for i in 1..ncol {
            if !cols[i].in_field() {
                col_x[i] = col_x[i - 1];
                continue;
            }
            col_x[i] = col_x[i - 1] + CELL_W + gap_width(i - 1);
        }
    }
    let exit_x = |col: usize, back: bool, lane: u32| -> i32 {
        let off = HALF + tw * (lane as i32 + 1);
        if back { col_x[col] + off } else { col_x[col] - off }
    };
    let mut riser_x: Vec<Option<(i32, i32)>> = vec![None; ctx.nn()];
    for (n, info) in riser_info.iter().enumerate() {
        if let Some(&(lo, lb, ll, hi, hb, hl)) = info.as_ref() {
            riser_x[n] = Some((exit_x(lo, lb, ll), exit_x(hi, hb, hl)));
        }
    }

    // Device positions
    let abs_y = |d: DeviceIdx| -> i32 { offset[col_of[d.index()]] + dev_y[d.index()] };

    // Shared (N=2): shift down so hub pin clears the lowest branch pin
    let mut extra_y = vec![0i32; ctx.nd()];
    for c in cols.iter().filter(|c| c.kind == ColumnKind::Shared) {
        let d = c.devices[0];
        let Some(inf) = infos.iter().find(|i| i.shared_hub.map(|p| ctx.dev_of(p)) == Some(d)) else {
            continue;
        };
        let hub_abs = abs_y(d) + pin_iy(inf.shared_hub.unwrap()) - dev_y[d.index()];
        let branch_max = ctx
            .members(inf.net)
            .iter()
            .filter(|&&p| ctx.dev_of(p) != d && col_of[ctx.dev_of(p).index()] != usize::MAX)
            .map(|&p| offset[col_of[ctx.dev_of(p).index()]] + pin_iy(p))
            .max();
        if let Some(bmax) = branch_max {
            extra_y[d.index()] = (bmax + cfg().layout.abut_gap - hub_abs).max(0);
        }
    }

    let mut pos = vec![Pt::new(0, 0); ctx.nd()];
    for c in &cols {
        for &d in &c.devices {
            pos[d.index()] = Pt::new(col_x[col_of[d.index()]], abs_y(d) + extra_y[d.index()]);
        }
    }

    // Canvas extent (feedback devices are margin-resident, excluded)
    let (mut ctop, mut cbot) = (i32::MAX, i32::MIN);
    for c in cols.iter().filter(|c| c.in_field()) {
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
    let power_bus = ctop - cfg().layout.bus_gap;
    let gnd_bus = cbot + cfg().layout.bus_gap;

    // Feedback devices: centred between bridged columns in the backward-route band
    let fb_band = power_bus - cfg().layout.margin_gap;
    for c in cols.iter().filter(|c| !c.in_field()) {
        let d = c.devices[0];
        let xs: Vec<i32> = ctx
            .pins(d)
            .filter(|&p| ctx.conducts(p))
            .filter_map(|p| ctx.net_of(p))
            .filter_map(|net| {
                ctx.members(net)
                    .iter()
                    .map(|&q| col_of[ctx.dev_of(q).index()])
                    .find(|&cc| cc != usize::MAX && !cols[cc].devices.contains(&d))
                    .map(|cc| col_x[cc])
            })
            .collect();
        let cx = if xs.is_empty() { 0 } else { xs.iter().sum::<i32>() / xs.len() as i32 };
        pos[d.index()] = Pt::new(cx, fb_band);
    }

    // Rail positions: centred over spanned columns, on their bus
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

    // Pin coordinates
    let mut pin_xy = vec![Pt::new(0, 0); ctx.ir.pins.len()];
    for d in 0..ctx.nd() {
        let di = DeviceIdx(d as u32);
        for p in ctx.pins(di) {
            pin_xy[p.index()] = pos[d] + oriented_term(&orient, ctx, p);
        }
    }

    // Collision boxes
    let mut col_boxes: Vec<Vec<Rect>> = vec![Vec::new(); ncol];
    for c in &cols {
        for &d in &c.devices {
            col_boxes[col_of[d.index()]].push(dev_box(&orient, ctx, d, pos[d.index()]));
        }
    }

    // Phase 5: route every net
    let top_margin = power_bus - cfg().layout.margin_gap;
    let rc = RouteCtx {
        ctx,
        pin_xy: &pin_xy,
        chosen_h: &chosen_h,
        track_of: &track_of,
        riser_x: &riser_x,
        col_boxes: &col_boxes,
        col_of: &col_of,
        top_margin,
    };
    let mut net_segs: Vec<Vec<Vec<Pt>>> = vec![Vec::new(); ctx.nn()];
    let mut labels: Vec<Label> = Vec::new();
    let mut fallbacks: Vec<(NetIdx, &'static str)> = Vec::new();
    let mut num_forward_margin = 0u32;
    for inf in &infos {
        let segs = &mut net_segs[inf.net.index()];
        match ctx.net_class(inf.net) {
            NetClass::Power => {
                let pts: Vec<Pt> = ctx.members(inf.net).iter().map(|&p| pin_xy[p.index()]).collect();
                route_bus_at(&pts, power_bus, segs);
            }
            NetClass::Ground => {
                let pts: Vec<Pt> = ctx.members(inf.net).iter().map(|&p| pin_xy[p.index()]).collect();
                route_bus_at(&pts, gnd_bus, segs);
            }
            NetClass::Signal => match inf.shared_hub {
                Some(hub) => {
                    let pts: Vec<Pt> =
                        ctx.members(inf.net).iter().map(|&p| pin_xy[p.index()]).collect();
                    route_bus_at(&pts, pin_xy[hub.index()].y, segs);
                }
                None => route_net(&rc, inf, segs, &mut labels, &mut fallbacks, &mut num_forward_margin),
            },
        }
    }

    // Feedback devices: connect each plate pin to its net's field wiring
    for c in cols.iter().filter(|c| !c.in_field()) {
        for &d in &c.devices {
            for p in ctx.pins(d) {
                if !ctx.conducts(p) { continue; }
                let Some(net) = ctx.net_of(p) else { continue };
                let at = pin_xy[p.index()];
                let segs = &mut net_segs[net.index()];
                // Find the nearest existing wire point on this net to connect to
                let nearest = segs.iter().flatten().copied()
                    .min_by_key(|&q| (q.x - at.x).abs() + (q.y - at.y).abs());
                if let Some(anchor) = nearest {
                    segs.push(vec![at, Pt::new(at.x, anchor.y), anchor]);
                } else {
                    segs.push(vec![at]);
                }
            }
        }
    }

    // Unspannable rails → lab pin fallback
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        if !matches!(ctx.net_class(net), NetClass::Power | NetClass::Ground) {
            continue;
        }
        let spans_field = ctx
            .members(net)
            .iter()
            .any(|&p| col_of[ctx.dev_of(p).index()] != usize::MAX);
        if !spans_field {
            if let Some(&p) = ctx.members(net).first() {
                labels.push(Label { net, at: pin_xy[p.index()] });
                fallbacks.push((
                    net,
                    "power/ground rail spans no device field — lab pin instead of a bus",
                ));
            }
        }
    }
    let num_labels = labels.len() as u32;

    // Phase 6: body hit counting (wire segments crossing field device bodies — rails and
    // margin-resident feedback devices are excluded; wires near them are expected).
    // Boxes of devices that have a pin on the same net are also excluded (a wire
    // arriving at its own device terminal is not a crossing).
    let all_boxes: Vec<(DeviceIdx, Rect)> = (0..ctx.nd())
        .filter(|&d| {
            let di = DeviceIdx(d as u32);
            if ctx.is_rail(di) { return false; }
            let c = col_of[d];
            c == usize::MAX || cols[c].in_field()
        })
        .map(|d| {
            let di = DeviceIdx(d as u32);
            (di, dev_box(&orient, ctx, di, pos[d]))
        })
        .collect();
    let mut num_body_hits = 0u32;
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        let net_devs: Vec<DeviceIdx> = ctx.members(net).iter().map(|&p| ctx.dev_of(p)).collect();
        let mut hit = false;
        for poly in &net_segs[n] {
            for w in poly.windows(2) {
                let r = Rect::from_corners(w[0], w[1]);
                for &(di, ref b) in &all_boxes {
                    if net_devs.contains(&di) { continue; }
                    if r.intersects(b) {
                        num_body_hits += 1;
                        hit = true;
                    }
                }
            }
        }
        if hit {
            fallbacks.push((net, "a wire segment crosses a device body"));
        }
    }

    // Phase 7: pack the result + metrics
    let physical = build_physical(ctx, pos, pin_xy, &net_segs, labels);
    let num_staples = staples.len() as u32;
    let total_span: u32 =
        staples.iter().map(|s| (s.cols.last().unwrap() - s.cols[0]) as u32).sum();
    let num_crossings = count_crossings(&net_segs);
    let mut netid_seq: Vec<u32> = infos.iter().map(|i| i.net.index() as u32).collect();
    netid_seq.sort_unstable();
    let metrics = Metrics {
        num_labels,
        num_forward_margin,
        num_body_hits,
        num_crossings,
        num_staples,
        total_span,
        margin_tracks,
        netid_seq,
    };
    Evaluated { physical, n_columns: ncol, metrics, orient, fallbacks }
}

// ── § orientation (phase 0) ─────────────────────────────────────────────────

fn compute_orientation(ctx: &Ctx, cols: &[Column], col_of: &[usize]) -> Vec<Orientation> {
    let mut orient = vec![Orientation::H; ctx.nd()];
    for (ci, col) in cols.iter().enumerate() {
        if !matches!(col.kind, ColumnKind::Spline | ColumnKind::Shared | ColumnKind::Component | ColumnKind::SignalSeries) {
            continue;
        }
        for (i, &d) in col.devices.iter().enumerate() {
            let has_gate = ctx.pins(d).any(|p| ctx.role_of(p).is_control());
            if matches!(col.kind, ColumnKind::Component | ColumnKind::SignalSeries) && !has_gate {
                continue;
            }
            let above = if i > 0 { Some(col.devices[i - 1]) } else { None };
            let up_left = up_conduction_pin(ctx, d, above)
                .map(|p| ctx.term_at(p).x < 0)
                .unwrap_or(true);
            let gate_left = if col.kind == ColumnKind::SignalSeries && col.devices.len() >= 2 && i > 0 {
                // Antiparallel: force opposite gate side from the first device
                matches!(orient[col.devices[0].index()].rot(), Rot::R90)
            } else {
                gate_from_left(ctx, d, col_of, ci)
            };
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

/// Which conduction pin faces up the column?
fn up_conduction_pin(ctx: &Ctx, dev: DeviceIdx, above: Option<DeviceIdx>) -> Option<PinIdx> {
    let above_nets: Vec<NetIdx> = above
        .map(|a| ctx.conducting_pins(a).iter().filter_map(|&p| ctx.net_of(p)).collect())
        .unwrap_or_default();
    // Preference: shares a net with the device above > power > any non-ground > anything.
    let rank = |p: PinIdx| match ctx.net_of(p) {
        Some(n) if above_nets.contains(&n) => 0,
        Some(n) if ctx.net_class(n) == NetClass::Power => 1,
        Some(n) if ctx.net_class(n) != NetClass::Ground => 2,
        _ => 3,
    };
    ctx.conducting_pins(dev).iter().copied().min_by_key(|&p| rank(p))
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

// ── § oriented geometry ─────────────────────────────────────────────────────

fn apply_o(o: Orientation, p: devices::Pt) -> Pt {
    o.apply(Pt::new(p.x, p.y))
}

/// A pin's terminal point in oriented device-local coordinates.
fn oriented_term(orient: &[Orientation], ctx: &Ctx, p: PinIdx) -> Pt {
    apply_o(orient[ctx.dev_of(p).index()], ctx.term_at(p))
}

/// A device's bounding box in oriented device-local coordinates.
fn oriented_box_rel(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx) -> Rect {
    let bb = ctx.class(d).bbox();
    let o = orient[d.index()];
    // An orthogonal transform maps opposite corners to opposite corners.
    Rect::from_corners(apply_o(o, bb.min), apply_o(o, bb.max))
}

/// A device's bounding box in canvas coordinates.
fn dev_box(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx, pos: Pt) -> Rect {
    let r = oriented_box_rel(orient, ctx, d);
    Rect::new(pos + r.min, pos + r.max)
}

// ── § vertical spacing (phase 1) ────────────────────────────────────────────

/// Gap between two stacked devices: `optimallen = degree − in_spline − 1`
/// tap units (the −1 subtracts the conduction link itself), or the abut gap
/// when they share no net.
fn optimallen(ctx: &Ctx, a: DeviceIdx, b: DeviceIdx, col_of: &[usize]) -> i32 {
    let bnets: Vec<Option<NetIdx>> =
        ctx.conducting_pins(b).iter().map(|&p| ctx.net_of(p)).collect();
    let shared = ctx
        .conducting_pins(a)
        .iter()
        .copied()
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
            (ctx.degree(net) as i32 - in_spline as i32 - 1).max(0) * cfg().layout.tap_unit
        }
        None => cfg().layout.abut_gap,
    }
}

/// Does the net drive backwards (a conduction pin in a later column than a gate)?
fn net_is_backward(ctx: &Ctx, net: NetIdx, col_of: &[usize], cols: &[Column]) -> bool {
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

// ── § routing (phase 5) ─────────────────────────────────────────────────────

/// Horizontal bus at `bus_y` with vertical drops from each pin.
fn route_bus_at(pts: &[Pt], bus_y: i32, out: &mut Vec<Vec<Pt>>) {
    if pts.len() < 2 {
        return;
    }
    let minx = pts.iter().map(|p| p.x).min().unwrap();
    let maxx = pts.iter().map(|p| p.x).max().unwrap();
    out.push(vec![Pt::new(minx, bus_y), Pt::new(maxx, bus_y)]);
    for p in pts {
        if p.y != bus_y {
            out.push(vec![*p, Pt::new(p.x, bus_y)]);
        }
    }
}

/// Route one signal net by its case: within a column, between immediate
/// neighbours, or spanning (staple through a field channel or the top margin).
fn route_net(
    rc: &RouteCtx,
    inf: &NetInfo,
    out: &mut Vec<Vec<Pt>>,
    labels: &mut Vec<Label>,
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
    num_forward_margin: &mut u32,
) {
    match inf.case {
        Case::WithinSpline => {
            let col = inf.cols[0];
            let mut ps: Vec<Pt> = rc
                .ctx
                .members(inf.net)
                .iter()
                .filter(|&&q| rc.col_of[rc.ctx.dev_of(q).index()] == col)
                .map(|&q| rc.pin_at(q))
                .collect();
            wire_column_pins(&mut ps, &rc.col_boxes[col], out);
        }
        Case::ImmediateNeighbor => {
            let (lo, hi) = (inf.cols[0], *inf.cols.last().unwrap());
            let pi = inf.rep_in(lo).map(|p| rc.pin_at(p));
            let pj = inf.rep_in(hi).map(|p| rc.pin_at(p));
            if let (Some(a), Some(b)) = (pi, pj) {
                let is_chosen =
                    (lo..hi).any(|g| rc.chosen_h.get(g).copied().flatten() == Some(inf.net));
                let run_y;
                let run_x;
                if is_chosen && a.y == b.y {
                    out.push(vec![a, b]);
                    run_y = a.y;
                    run_x = (a.x + b.x) / 2;
                } else {
                    let left = rc.col_boxes[lo].iter().map(|r| r.max.x).max();
                    let right = rc.col_boxes[hi].iter().map(|r| r.min.x).min();
                    let mx = match (left, right) {
                        (Some(l), Some(r)) if l < r => (l + r) / 2,
                        _ => (a.x + b.x) / 2,
                    };
                    out.push(vec![a, Pt::new(mx, a.y), Pt::new(mx, b.y), b]);
                    run_y = a.y;
                    run_x = mx;
                }
                for &(c, p) in &inf.rep {
                    if c > lo && c < hi {
                        let q = rc.pin_at(p);
                        out.push(vec![q, Pt::new(q.x, run_y), Pt::new(run_x, run_y)]);
                    }
                }
            }
        }
        Case::SpanGe2 => {
            let (lo, hi) = (inf.cols[0], *inf.cols.last().unwrap());
            let a = inf.rep_in(lo).map(|p| rc.pin_at(p));
            let b = inf.rep_in(hi).map(|p| rc.pin_at(p));
            if let (Some(a), Some(b)) = (a, b) {
                let channel = find_channel_y(rc.col_boxes, lo, hi, a, b);
                let run_y = if a.y == b.y && channel == Some(a.y) {
                    // Aligned and the direct horizontal is clear.
                    out.push(vec![a, b]);
                    a.y
                } else {
                    // Staple via a clear in-field channel if one exists, else a margin track.
                    let y = channel.unwrap_or_else(|| {
                        let t = rc.track_of[inf.net.index()].unwrap_or(0) as i32;
                        rc.top_margin - t * cfg().layout.track_h
                    });
                    let (rxlo, rxhi) = rc.riser_x[inf.net.index()].unwrap_or((a.x, b.x));
                    out.push(vec![
                        a,
                        Pt::new(rxlo, a.y),
                        Pt::new(rxlo, y),
                        Pt::new(rxhi, y),
                        Pt::new(rxhi, b.y),
                        b,
                    ]);
                    if channel.is_none() && !inf.backward {
                        *num_forward_margin += 1;
                        fallbacks.push((
                            inf.net,
                            "non-feedback net routed in the top margin (margin is for backward feedback only)",
                        ));
                    }
                    y
                };
                for &(c, p) in &inf.rep {
                    if c > lo && c < hi {
                        let q = rc.pin_at(p);
                        if q.y != run_y {
                            out.push(vec![q, Pt::new(q.x, run_y)]);
                        }
                    }
                }
            } else {
                let at = a
                    .or(b)
                    .or_else(|| rc.ctx.members(inf.net).first().map(|&p| rc.pin_at(p)));
                if let Some(at) = at {
                    labels.push(Label { net: inf.net, at });
                    fallbacks.push((inf.net, "no representative pin at a span endpoint column"));
                }
            }
        }
    }
    // Intra-column taps: multi-column nets may have several pins in one column
    if inf.case != Case::WithinSpline {
        for &(c, _) in &inf.rep {
            let mut ps: Vec<Pt> = rc
                .ctx
                .members(inf.net)
                .iter()
                .filter(|&&p| rc.col_of[rc.ctx.dev_of(p).index()] == c)
                .map(|&p| rc.pin_at(p))
                .collect();
            wire_column_pins(&mut ps, &rc.col_boxes[c], out);
        }
    }
}

/// Wire multiple pins in the same column: straight vertical if aligned, otherwise
/// gather off-axis pins onto the dominant axis, detouring through a side channel
/// when a device body blocks the direct connection.
fn wire_column_pins(ps: &mut Vec<Pt>, boxes: &[Rect], out: &mut Vec<Vec<Pt>>) {
    if ps.len() < 2 {
        return;
    }
    ps.sort_by_key(|p| (p.y, p.x));
    ps.dedup();
    if ps.len() < 2 {
        return;
    }
    if ps.iter().all(|p| p.x == ps[0].x) {
        out.push(ps.clone());
        return;
    }
    // Dominant axis: the x shared by the most pins (leftmost on ties).
    let axis_x = {
        let mut best = (ps[0].x, 0usize);
        for p in ps.iter() {
            let n = ps.iter().filter(|q| q.x == p.x).count();
            if n > best.1 || (n == best.1 && p.x < best.0) {
                best = (p.x, n);
            }
        }
        best.0
    };
    let on_axis: Vec<Pt> = ps.iter().filter(|p| p.x == axis_x).copied().collect();
    let mut v_ys: Vec<i32> = on_axis.iter().map(|p| p.y).collect();
    for &op in ps.iter().filter(|p| p.x != axis_x) {
        let nearest = on_axis.iter().min_by_key(|p| (p.y - op.y).abs()).copied().unwrap_or(ps[0]);
        let wire = Rect::new(
            Pt::new(axis_x, nearest.y.min(op.y)),
            Pt::new(axis_x + 1, nearest.y.max(op.y)),
        );
        if boxes.iter().any(|b| wire.intersects(b)) {
            // Axis blocked by a body: detour through a side channel clear of every box.
            let sx = boxes.iter().map(|b| b.max.x).max().unwrap_or(axis_x).max(op.x) + SIDE_CLEAR;
            out.push(vec![nearest, Pt::new(sx, nearest.y), Pt::new(sx, op.y), op]);
        } else {
            v_ys.push(op.y);
            out.push(vec![op, Pt::new(axis_x, op.y)]);
        }
    }
    v_ys.sort();
    v_ys.dedup();
    if v_ys.len() >= 2 {
        out.push(v_ys.iter().map(|&y| Pt::new(axis_x, y)).collect());
    }
}

/// Find a y-level where a horizontal wire from `a` to `b` clears all intermediate
/// device boxes. Tries both pin y-levels first (so an aligned, unobstructed pair
/// returns its own y), then gaps between boxes, then just outside the extremes.
fn find_channel_y(col_boxes: &[Vec<Rect>], lo: usize, hi: usize, a: Pt, b: Pt) -> Option<i32> {
    let xmin = a.x.min(b.x);
    let xmax = a.x.max(b.x);
    let check = |y: i32| -> bool {
        let wire = Rect::from_corners(Pt::new(xmin, y), Pt::new(xmax, y));
        ((lo + 1)..hi).all(|c| !col_boxes[c].iter().any(|bx| wire.intersects(bx)))
    };
    if check(a.y) { return Some(a.y); }
    if check(b.y) { return Some(b.y); }
    // Box edges in intermediate columns are the candidate y-levels; try the
    // midpoint of each gap between consecutive edges.
    let mut edges: Vec<i32> = Vec::new();
    for c in (lo + 1)..hi {
        for bx in &col_boxes[c] {
            edges.push(bx.min.y);
            edges.push(bx.max.y);
        }
    }
    edges.sort_unstable();
    edges.dedup();
    for w in edges.windows(2) {
        let mid = (w[0] + w[1]) / 2;
        if mid > a.y.min(b.y) - CELL_W && mid < a.y.max(b.y) + CELL_W && check(mid) {
            return Some(mid);
        }
    }
    // Just above the topmost and just below the bottommost box.
    if let (Some(&top), Some(&bot)) = (edges.first(), edges.last()) {
        if check(top - 1) && top - 1 >= a.y.min(b.y) - CELL_W { return Some(top - 1); }
        if check(bot + 1) && bot + 1 <= a.y.max(b.y) + CELL_W { return Some(bot + 1); }
    }
    None
}

// ── § output & metrics (phase 7) ────────────────────────────────────────────

/// Pack routed polylines into the CSR arrays of a [`Physical`].
fn build_physical(
    ctx: &Ctx,
    pos: Vec<Pt>,
    pin_xy: Vec<Pt>,
    net_segs: &[Vec<Vec<Pt>>],
    labels: Vec<Label>,
) -> Physical {
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
    Physical { pos, pin_xy, net_seg, seg_pt, wire_pts, junctions, labels }
}

/// A junction dot goes wherever ≥3 wire arms of one net meet.
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

fn on_segment_interior(p: Pt, a: Pt, b: Pt) -> bool {
    if a.y == b.y && p.y == a.y {
        (a.x.min(b.x) < p.x) && (p.x < a.x.max(b.x))
    } else if a.x == b.x && p.x == a.x {
        (a.y.min(b.y) < p.y) && (p.y < a.y.max(b.y))
    } else {
        false
    }
}

/// Count pairs of perpendicular segments from different nets whose interiors cross.
fn count_crossings(net_segs: &[Vec<Vec<Pt>>]) -> u32 {
    let mut segs: Vec<(usize, Pt, Pt)> = Vec::new();
    for (ni, polys) in net_segs.iter().enumerate() {
        for poly in polys {
            for w in poly.windows(2) {
                segs.push((ni, w[0], w[1]));
            }
        }
    }
    // ponytail: O(n²) pair scan — fine at schematic scale, sweep line if it ever isn't
    let crosses = |a1: Pt, a2: Pt, b1: Pt, b2: Pt| -> bool {
        let (a_h, b_h) = (a1.y == a2.y, b1.y == b2.y);
        if a_h == b_h {
            return false; // parallel
        }
        let (h1, h2, v1, v2) = if a_h { (a1, a2, b1, b2) } else { (b1, b2, a1, a2) };
        let (hx0, hx1) = (h1.x.min(h2.x), h1.x.max(h2.x));
        let (vy0, vy1) = (v1.y.min(v2.y), v1.y.max(v2.y));
        hx0 < v1.x && v1.x < hx1 && vy0 < h1.y && h1.y < vy1
    };
    let mut n = 0u32;
    for i in 0..segs.len() {
        for j in (i + 1)..segs.len() {
            if segs[i].0 != segs[j].0 && crosses(segs[i].1, segs[i].2, segs[j].1, segs[j].2) {
                n += 1;
            }
        }
    }
    n
}
