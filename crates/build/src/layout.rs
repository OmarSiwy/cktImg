//! The four-phase one-pass evaluation of a single column order (§5), plus per-net routing
//! (§4) and the candidate metrics for the selection key (§6). x ⟂ y by construction: y comes
//! from phases 1–2, x from phases 3–4, and no margin/channel ever moves a device (Lemma 1).
//!
//! Spline devices are placed VERTICAL (ARCH §Case 1): the device is rotated so its two
//! conduction terminals stack on the column-centre axis (one top, one bottom) and the gate
//! exits horizontally to the left or right. Because conduction pins of stacked devices then
//! share an x, the within-spline wire is a straight vertical line — no Manhattan jog.

use crate::ctx::{Ctx, NetClass};
use crate::extract::{
    assign_columns, branch_counts, classify, column_of, net_columns, Case, Column, ColumnKind, Spline,
};
use ir::{DeviceIdx, Label, NetIdx, Orientation, PinIdx, Physical, Pt, Rect, Rot};

use config::cfg;

const CELL_W: i32 = devices::CELL_WIDTH; // geometry invariant, not opinion
const HALF: i32 = CELL_W / 2;
// Spacing knobs (abut_gap, tap_unit, track_w, track_h, margin_gap, bus_gap) are
// opinion-based and live in lint.toml; read them via `cfg().layout.*`.

/// Integer counts that order candidate layouts (§6). Compared lexicographically; never
/// summed with weights.
#[derive(Clone, Debug)]
pub struct Metrics {
    pub num_labels: u32,
    /// Wire segments whose interior crosses a device body (real `Rect::intersects`, §"Collision
    /// is checked strictly"). Second in the key: the order search prefers a layout that routes a
    /// staple/riser around bodies over one that draws through them.
    pub num_body_hits: u32,
    pub num_crossings: u32,
    pub num_staples: u32,
    pub total_span: u32,
    pub margin_tracks: u32,
    pub netid_seq: Vec<u32>,
}

impl Metrics {
    /// The lexicographic key (§6 `Key`). Lower is better.
    pub fn key(&self) -> (u32, u32, u32, u32, u32, u32, &[u32]) {
        (
            self.num_labels,
            self.num_body_hits,
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
    /// Routing degradations on THIS candidate: a signal net that fell all the way to a net
    /// label (§subcase C tier 3), each with the reason it could not be routed. Collected per
    /// candidate so the caller prints only the WINNING order's fallbacks — loud, once.
    pub fallbacks: Vec<(NetIdx, &'static str)>,
}

fn apply_o(o: Orientation, p: devices::Pt) -> Pt {
    o.apply(Pt::new(p.x, p.y))
}
fn oriented_term(orient: &[Orientation], ctx: &Ctx, p: PinIdx) -> Pt {
    apply_o(orient[ctx.dev_of(p).index()], ctx.term_at(p))
}
fn oriented_y_extent(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx) -> (i32, i32) {
    let r = oriented_box_rel(orient, ctx, d);
    (r.min.y, r.max.y)
}

/// The device's bounding box after orientation, RELATIVE to its origin (add `pos` for absolute).
fn oriented_box_rel(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx) -> Rect {
    let bb = ctx.class(d).bbox();
    let o = orient[d.index()];
    let (mut mnx, mut mny, mut mxx, mut mxy) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for (x, y) in [(bb.min.x, bb.min.y), (bb.max.x, bb.min.y), (bb.min.x, bb.max.y), (bb.max.x, bb.max.y)] {
        let q = o.apply(Pt::new(x, y));
        mnx = mnx.min(q.x);
        mxx = mxx.max(q.x);
        mny = mny.min(q.y);
        mxy = mxy.max(q.y);
    }
    Rect::new(Pt::new(mnx, mny), Pt::new(mxx, mxy))
}

/// The device's absolute collision box: oriented bbox translated to its placed position.
fn dev_box(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx, pos: Pt) -> Rect {
    let r = oriented_box_rel(orient, ctx, d);
    Rect::new(Pt::new(pos.x + r.min.x, pos.y + r.min.y), Pt::new(pos.x + r.max.x, pos.y + r.max.y))
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
    /// Electrical direction across the columns (§Connection classification): `true` when an
    /// output (conduction pin) sits to the RIGHT of a gate it drives — backward feedback, the
    /// only thing the top margin should carry. `false` = forward inter-stage signal. Used to
    /// flag margin misclassification, not to choose the route.
    backward: bool,
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
    let shared_dev: Vec<bool> = branch_counts(ctx, order).iter().map(|&c| c >= 2).collect();

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
        let backward = net_is_backward(ctx, net, &col_of);
        infos.push(NetInfo { net, cols: cs, case, rep, shared_hub, backward });
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

    // --- Phase 3.5: staple exit sides + per-side riser lanes (§"Routes may exit a spine from the
    //     front or the back, decided pre-route"). Each staple endpoint leaves its column on a
    //     chosen side and descends in the ADJACENT channel — never on the spine axis — so a riser
    //     never runs through the spine's own stacked bodies. Spine 0 exits front (into the left
    //     outer margin); the last spine exits back (right outer margin); an interior endpoint
    //     exits toward the run. Lanes are reserved per (column, side), one wire gauge each. ---
    let tw = cfg().layout.track_w;
    let mut front_lanes = vec![0u32; ncol]; // risers descending on a column's LEFT side
    let mut back_lanes = vec![0u32; ncol]; //  ... and on its RIGHT side
    // The endpoint exits on whichever side its pin sits — a pin on the body's right edge exits
    // back, left edge exits front — so the horizontal stub runs AWAY from the body, never through
    // it. A pin on the column axis (no horizontal edge) has no preference: spine 0 exits front
    // (left outer margin), the last spine back (right outer margin), interior toward the run.
    let pin_side = |p: PinIdx, fallback: bool| -> bool {
        let tx = oriented_term(&orient, ctx, p).x;
        let bb = oriented_box_rel(&orient, ctx, ctx.dev_of(p));
        if tx >= bb.max.x {
            true // right edge → back
        } else if tx <= bb.min.x {
            false // left edge → front
        } else {
            fallback
        }
    };
    // net → (lo_col, lo_back, lo_lane, hi_col, hi_back, hi_lane)
    let mut riser: std::collections::HashMap<u32, (usize, bool, u32, usize, bool, u32)> = Default::default();
    for s in &staples {
        let (lo, hi) = (s.cols[0], *s.cols.last().unwrap());
        let lo_pin = s.rep.iter().find(|&&(c, _)| c == lo).map(|&(_, p)| p);
        let hi_pin = s.rep.iter().find(|&&(c, _)| c == hi).map(|&(_, p)| p);
        let lo_back = lo_pin.map(|p| pin_side(p, lo != 0)).unwrap_or(lo != 0);
        let hi_back = hi_pin.map(|p| pin_side(p, hi == ncol - 1)).unwrap_or(hi == ncol - 1);
        let take = |lanes: &mut Vec<u32>, c: usize| -> u32 {
            let v = lanes[c];
            lanes[c] += 1;
            v
        };
        let lo_lane = if lo_back { take(&mut back_lanes, lo) } else { take(&mut front_lanes, lo) };
        let hi_lane = if hi_back { take(&mut back_lanes, hi) } else { take(&mut front_lanes, hi) };
        riser.insert(s.net.index() as u32, (lo, lo_back, lo_lane, hi, hi_back, hi_lane));
    }

    // --- Phase 4: channel widths → column x (§5.4). §"Collision is checked strictly — no
    //     approximation": a gap's width is the riser room ACTUALLY reserved in it — the back-side
    //     risers of the left column plus the front-side risers of the right column — plus the
    //     immediate-neighbour wires, plus a one-gauge floor (the physical minimum for a stub to
    //     run). One wire gauge each, no `CH_BASE` base constant. ---
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
        col_x[0] = HALF + front_lanes[0] as i32 * tw; // left outer margin for spine 0's front risers
        for i in 1..ncol {
            if cols[i].kind == ColumnKind::Feedback {
                col_x[i] = col_x[i - 1]; // no field footprint — positioned in the margin band below
                continue;
            }
            col_x[i] = col_x[i - 1] + CELL_W + gap_width(i - 1);
        }
    }
    // riser x for each staple endpoint, now that col_x is fixed (front = left of axis, back = right)
    let exit_x = |col: usize, back: bool, lane: u32| -> i32 {
        let off = HALF + tw * (lane as i32 + 1);
        if back {
            col_x[col] + off
        } else {
            col_x[col] - off
        }
    };
    let mut riser_x: std::collections::HashMap<u32, (i32, i32)> = Default::default();
    for (&net, &(lo, lb, ll, hi, hb, hl)) in &riser {
        riser_x.insert(net, (exit_x(lo, lb, ll), exit_x(hi, hb, hl)));
    }

    // --- Device positions (non-rail devices in their columns) ---
    let abs_y = |dev_y: &[i32], d: DeviceIdx| offset[col_of[d.index()]] + dev_y[d.index()];

    // A Shared (N=2) device must sit BELOW the branch pins it fans to, so route_fan's bus drops
    // INTO its top terminal instead of slicing up through the branch bodies (ALGORITHM.md §Shared
    // N=2: "Spine bottom → shared top"). Shift it down so its hub pin clears the lowest branch pin.
    let mut extra_y = vec![0i32; ctx.nd()];
    for c in cols.iter().filter(|c| c.kind == ColumnKind::Shared) {
        let d = c.devices[0];
        let Some(inf) = infos.iter().find(|i| i.shared_hub.map(|p| ctx.dev_of(p)) == Some(d)) else { continue };
        let hub_abs = abs_y(&dev_y, d) + pin_iy(&dev_y, inf.shared_hub.unwrap()) - dev_y[d.index()];
        let branch_max = ctx
            .members(inf.net)
            .iter()
            .filter(|&&p| ctx.dev_of(p) != d && col_of[ctx.dev_of(p).index()] != usize::MAX)
            .map(|&p| offset[col_of[ctx.dev_of(p).index()]] + pin_iy(&dev_y, p))
            .max();
        if let Some(bmax) = branch_max {
            extra_y[d.index()] = (bmax + cfg().layout.abut_gap - hub_abs).max(0);
        }
    }

    let mut pos = vec![Pt::new(0, 0); ctx.nd()];
    for c in &cols {
        for &d in &c.devices {
            pos[d.index()] = Pt::new(col_x[col_of[d.index()]], abs_y(&dev_y, d) + extra_y[d.index()]);
        }
    }

    // canvas extent over placed device pins; the VDD/GND buses sit just outside it. Feedback
    // devices are margin residents (positioned below), not field devices — exclude them so they
    // don't stretch the field extent.
    let mut ctop = i32::MAX;
    let mut cbot = i32::MIN;
    for c in cols.iter().filter(|c| c.kind != ColumnKind::Feedback) {
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

    // §"Device inside a feedback loop" (Non-immediate): place each feedback bridge device in the
    // backward-route band (top margin), centred between the two node columns it bridges. Its two
    // bridged nets then route to its plates, splitting the feedback wire around it.
    let fb_band = power_bus - cfg().layout.margin_gap;
    for c in cols.iter().filter(|c| c.kind == ColumnKind::Feedback) {
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

    // absolute device collision boxes per column, for the direct-horizontal clearance test
    // (§C tier 1) — real rectangles, checked with `Rect::intersects`, not a y-span-only test.
    let mut col_boxes: Vec<Vec<Rect>> = vec![Vec::new(); ncol];
    for c in &cols {
        for &d in &c.devices {
            col_boxes[col_of[d.index()]].push(dev_box(&orient, ctx, d, pos[d.index()]));
        }
    }

    // --- Route every net (§4 RouteNet). Power/ground nets are horizontal rail buses; signal
    //     nets dispatch by case. Signal staples sit above the power bus. A net that cannot be
    //     drawn cleanly (degenerate rail, §14; unroutable staple, §144) drops a lab pin. ---
    let top_margin = power_bus - cfg().layout.margin_gap;
    let mut net_segs: Vec<Vec<Vec<Pt>>> = vec![Vec::new(); ctx.nn()];
    let mut labels: Vec<Label> = Vec::new();
    let mut fallbacks: Vec<(NetIdx, &'static str)> = Vec::new();
    for inf in &infos {
        let segs = &mut net_segs[inf.net.index()];
        match ctx.net_class(inf.net) {
            NetClass::Power => route_rail_bus(ctx, inf.net, &pin_xy, power_bus, segs),
            NetClass::Ground => route_rail_bus(ctx, inf.net, &pin_xy, gnd_bus, segs),
            NetClass::Signal => match inf.shared_hub {
                Some(hub) => route_fan(ctx, inf.net, hub, &pin_xy, segs),
                None => route_net(
                    ctx, inf, &pin_xy, &chosen_h, &track_of, &riser_x, &col_boxes, top_margin, segs,
                    &mut labels, &mut fallbacks,
                ),
            },
        }
    }

    // §14: a power/ground rail with nothing in the device field to span cannot be drawn as a
    // clean bus (those nets never enter `infos`) — fall back to a lab pin at the rail symbol.
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        if !matches!(ctx.net_class(net), NetClass::Power | NetClass::Ground) {
            continue;
        }
        let spans_field = ctx.members(net).iter().any(|&p| col_of[ctx.dev_of(p).index()] != usize::MAX);
        if !spans_field {
            if let Some(&p) = ctx.members(net).first() {
                labels.push(Label { net, at: pin_xy[p.index()] });
                fallbacks.push((net, "power/ground rail spans no device field — lab pin instead of a bus"));
            }
        }
    }
    let num_labels = labels.len() as u32;

    // §"Collision is checked strictly": every routed wire vs every device body, real rectangle
    // intersection. A crossing is a real fault — count it (drives the order search away from it)
    // and report it loudly for the chosen order. Strict intersection excludes boundary-touching
    // pins, so a wire meeting its own device's terminal is not a hit.
    let all_boxes: Vec<Rect> =
        (0..ctx.nd()).map(|d| dev_box(&orient, ctx, DeviceIdx(d as u32), pos[d])).collect();
    let mut num_body_hits = 0u32;
    for n in 0..ctx.nn() {
        let mut hit = false;
        for poly in &net_segs[n] {
            for w in poly.windows(2) {
                let r = Rect::from_corners(w[0], w[1]);
                for b in &all_boxes {
                    if r.intersects(b) {
                        num_body_hits += 1;
                        hit = true;
                    }
                }
            }
        }
        if hit {
            fallbacks.push((NetIdx::from_index(n), "a wire segment crosses a device body"));
        }
    }

    let physical = build_physical(ctx, pos, pin_xy, &net_segs, labels);

    let num_staples = staples.len() as u32;
    let total_span: u32 = staples.iter().map(|s| (s.cols.last().unwrap() - s.cols[0]) as u32).sum();
    let num_crossings = count_crossings(&net_segs);
    let mut netid_seq: Vec<u32> = infos.iter().map(|i| i.net.index() as u32).collect();
    netid_seq.sort_unstable();
    let metrics =
        Metrics { num_labels, num_body_hits, num_crossings, num_staples, total_span, margin_tracks, netid_seq };

    Evaluated { physical, n_columns: ncol, metrics, orient, fallbacks }
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
        for &p in cps {
            if ctx.net_of(p).is_some() && anets.contains(&ctx.net_of(p)) {
                return Some(p);
            }
        }
    }
    for &p in cps {
        if let Some(n) = ctx.net_of(p) {
            if ctx.net_class(n) == NetClass::Power {
                return Some(p);
            }
        }
    }
    // no rail above or on this device: the upper terminal is the non-ground one (toward
    // supply), so a top device with an internal-node source still orients sensibly.
    for &p in cps {
        if ctx.net_of(p).is_some_and(|n| ctx.net_class(n) != NetClass::Ground) {
            return Some(p);
        }
    }
    cps.first().copied()
}

/// Electrical direction of a net across the columns (§Connection classification). A net is
/// **backward feedback** when a conduction pin (an output) sits in a column to the RIGHT of a
/// gate (control input) the net drives — the signal runs leftward, the one thing the top margin
/// is meant to carry. Everything else is a forward inter-stage signal. Best-effort from terminal
/// roles and columns; used only to flag margin misclassification, never to pick the route.
fn net_is_backward(ctx: &Ctx, net: NetIdx, col_of: &[usize]) -> bool {
    let mut gate_min = usize::MAX;
    let mut drv_max = 0usize;
    let mut has_gate = false;
    let mut has_drv = false;
    for &p in ctx.members(net) {
        let c = col_of[ctx.dev_of(p).index()];
        if c == usize::MAX {
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
            let optimallen = (ctx.degree(net) as i32 - in_spline as i32).max(0);
            optimallen * cfg().layout.tap_unit // 0 ⇒ abut
        }
        None => cfg().layout.abut_gap,
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
        return; // unspannable rails are lab-pinned by the dedicated §14 pass in `evaluate`
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
    riser_x: &std::collections::HashMap<u32, (i32, i32)>,
    col_boxes: &[Vec<Rect>],
    top_margin: i32,
    out: &mut Vec<Vec<Pt>>,
    labels: &mut Vec<Label>,
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
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
                    // Drop the jog's vertical in the clear CHANNEL between the two columns'
                    // bodies — never at the pin midpoint, which lands INSIDE a body when a pin
                    // sits on a device's far edge (e.g. a horizontal series device's far
                    // terminal), drawing the wire through it (§"Collision is checked strictly").
                    let left = col_boxes[g].iter().map(|r| r.max.x).max();
                    let right = col_boxes[g + 1].iter().map(|r| r.min.x).min();
                    let mx = match (left, right) {
                        (Some(l), Some(r)) if l < r => (l + r) / 2,
                        _ => (a.x + b.x) / 2,
                    };
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
                // The trunk runs at `run_y`, between the two extreme columns.
                let run_y = if a.y == b.y && horizontal_clear(col_boxes, lo, hi, Rect::from_corners(a, b)) {
                    out.push(vec![a, b]); // tier 1: uncongested straight run
                    a.y
                } else {
                    let t = track_of.get(&(inf.net.index() as u32)).copied().unwrap_or(0) as i32;
                    let my = top_margin - t * cfg().layout.track_h; // tier 2: margin staple, above the power bus
                    // §"front/back exit": risers descend in the adjacent channel (off the spine
                    // axis) so they clear the spine's own bodies. Stub out to the riser x, up to
                    // the margin run, across, down the far riser, stub in to the pin.
                    let (rxlo, rxhi) = riser_x.get(&(inf.net.index() as u32)).copied().unwrap_or((a.x, b.x));
                    out.push(vec![
                        a,
                        Pt::new(rxlo, a.y),
                        Pt::new(rxlo, my),
                        Pt::new(rxhi, my),
                        Pt::new(rxhi, b.y),
                        b,
                    ]);
                    // §Connection classification: the top margin is for backward feedback only. A
                    // forward signal here is a misclassification — surface it, don't hide it.
                    if !inf.backward {
                        fallbacks.push((inf.net, "non-feedback net routed in the top margin (margin is for backward feedback only)"));
                    }
                    my
                };
                // §147/§163: every INTERMEDIATE column the net touches (e.g. a bridge cap's plate
                // in its own Component column) is tapped down to the trunk — otherwise its pin
                // dangles. The extremes are already the trunk endpoints.
                for &(c, p) in &inf.rep {
                    if c > lo && c < hi {
                        let q = pin_at(p);
                        if q.y != run_y {
                            out.push(vec![q, Pt::new(q.x, run_y)]);
                        }
                    }
                }
            } else {
                // tier 3: last-resort net label (LOUD) at whichever endpoint we have
                let at = a.or(b).or_else(|| ctx.members(inf.net).first().map(|&p| pin_at(p)));
                if let Some(at) = at {
                    labels.push(Label { net: inf.net, at });
                    fallbacks.push((inf.net, "no representative pin at a span endpoint column"));
                }
            }
        }
    }
}

fn build_physical(ctx: &Ctx, pos: Vec<Pt>, pin_xy: Vec<Pt>, net_segs: &[Vec<Vec<Pt>>], labels: Vec<Label>) -> Physical {
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

/// Does the candidate horizontal `wire` (a degenerate rect spanning columns `lo`..`hi`) clear
/// every device box in the columns strictly between them? (ARCH §subcase C tier 1: direct
/// horizontal if uncongested.) Real rectangle intersection — `Rect::intersects` — not a
/// y-span-only stacking check (ALGORITHM.md §"Collision is checked strictly").
fn horizontal_clear(col_boxes: &[Vec<Rect>], lo: usize, hi: usize, wire: Rect) -> bool {
    for c in (lo + 1)..hi {
        if col_boxes[c].iter().any(|b| wire.intersects(b)) {
            return false;
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
