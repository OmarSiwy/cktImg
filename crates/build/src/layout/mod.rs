//! Single-pass evaluation of a column order.
//!
//!   evaluate()   the whole pipeline, phase by phase
//!   geom         orthogonal-segment predicates, snapping, oriented geometry
//!   orient       phase 0: rotate/mirror each device; stacking-gap helpers
//!   route        phases 5–6: buses, per-net Manhattan routes
//!   output       phase 7: strict closure passes, metrics, packing Physical

mod geom;
mod orient;
mod output;
mod route;

use geom::{oriented_box_rel, oriented_term, snap_ceil, snap_near};
use orient::{compute_orientation, net_is_backward, optimallen};
use output::{
    build_physical, count_body_hits, count_crossings_and_overlaps, count_geom_shorts,
    count_pin_hits, enforce_crossing_budget, enforce_pin_coverage,
};
use route::{
    NetInfo, Obstacles, RouteCtx, hook_margin_pins, label_net_pins, route_bus_at, route_hub_trunk,
    route_net,
};

use crate::ctx::{Ctx, NetClass};
use crate::extract::{
    Case, Column, ColumnKind, Spline, assign_columns, branch_counts, classify, column_of,
    net_columns,
};
use config::cfg;
use ir::{DeviceIdx, Label, NetIdx, Orientation, Physical, PinIdx, Pt, Rect};

pub(crate) const CELL_W: i32 = devices::CELL_WIDTH;
const HALF: i32 = CELL_W / 2;

/// Quality metrics of one evaluated order; `key()` is the lexicographic search objective.
#[derive(Clone, Debug)]
pub struct Metrics {
    pub num_labels: u32,
    pub num_forward_margin: u32,
    /// Wire touching a foreign net's pin point. Geometric-connectivity hosts
    /// merge a pin with any wire through it, so every hit is a short there.
    pub num_pin_hits: u32,
    /// Wire endpoint landing on a foreign net's wire (T-junction short in
    /// geometric-connectivity hosts).
    pub num_geom_shorts: u32,
    pub num_body_hits: u32,
    pub num_overlaps: u32,
    pub num_crossings: u32,
    pub num_staples: u32,
    pub total_span: u32,
    pub margin_tracks: u32,
    pub netid_seq: Vec<u32>,
}

impl Metrics {
    #[allow(clippy::type_complexity)]
    pub fn key(&self) -> (u32, u32, u32, u32, u32, u32, u32, u32, u32, u32, &[u32]) {
        (
            self.num_labels,
            self.num_pin_hits,
            self.num_geom_shorts,
            self.num_body_hits,
            self.num_overlaps,
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

/// How a staple leaves its endpoint column: through a side riser lane, or a
/// straight drop onto a top-facing pin.
#[derive(Copy, Clone)]
enum Exit {
    Side(bool, u32),
    Up(i32),
}

pub fn evaluate(ctx: &Ctx, order: &[&Spline]) -> Evaluated {
    let grid = cfg().layout.grid;
    // Phase 0: columns + per-device orientation
    let cols = assign_columns(ctx, order);
    let ncol = cols.len();
    let col_of = column_of(ctx, &cols);
    let col_kinds: Vec<ColumnKind> = cols.iter().map(|c| c.kind).collect();
    let orient = compute_orientation(ctx, &cols, &col_of);
    let shared_dev: Vec<bool> = branch_counts(ctx, order).iter().map(|&c| c >= 2).collect();

    // Phase 1: interior y per column (optimallen spacing between stacked devices).
    let dev_y = stack_columns(ctx, &orient, &cols, &col_of);
    let pin_iy =
        |p: PinIdx| -> i32 { dev_y[ctx.dev_of(p).index()] + oriented_term(&orient, ctx, p).y };

    // Classify every net once column membership is known
    let infos = classify_nets(ctx, &cols, &col_of, &col_kinds, &shared_dev);

    // Phase 2: rigid vertical offsets (one horizontal alignment per adjacent pair)
    let (offset, chosen_h) = align_columns(ctx, &cols, &infos, &dev_y, &orient);

    // Phase 3: margin tracks (smallest-window-first packing)
    let mut staples: Vec<&NetInfo> = infos.iter().filter(|i| i.case == Case::SpanGe2).collect();
    staples.sort_by_key(|i| (i.cols.last().unwrap() - i.cols[0], i.net.index() as u32));
    let (track_of, margin_tracks) = pack_tracks(&staples, ctx.nn());

    // Phase 3.5: staple exit sides + per-side riser lanes
    let (front_lanes, back_lanes, riser_info) =
        staple_exits(ctx, &orient, &cols, &col_of, &staples, ncol);

    // Phase 4: channel widths → column x
    let (col_x, riser_x) = place_columns(
        ctx,
        &cols,
        &orient,
        &infos,
        &front_lanes,
        &back_lanes,
        &riser_info,
    );

    // Device positions
    let abs_y = |d: DeviceIdx| -> i32 { offset[col_of[d.index()]] + dev_y[d.index()] };

    // Shared (N=2): shift down so hub pin clears the lowest branch pin
    let mut extra_y = vec![0i32; ctx.nd()];
    for c in cols.iter().filter(|c| c.kind == ColumnKind::Shared) {
        let d = c.devices[0];
        let Some(inf) = infos
            .iter()
            .find(|i| i.shared_hub.map(|p| ctx.dev_of(p)) == Some(d))
        else {
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
            extra_y[d.index()] = snap_ceil((bmax + cfg().layout.abut_gap - hub_abs).max(0), grid);
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

    place_feedback(ctx, &cols, &col_of, &col_x, &orient, power_bus, &mut pos);
    place_rails(ctx, &col_of, &col_x, power_bus, gnd_bus, &mut pos);

    // Pin coordinates
    let mut pin_xy = vec![Pt::new(0, 0); ctx.ir.pins.len()];
    for (d, &pd) in pos.iter().enumerate() {
        for p in ctx.pins(DeviceIdx(d as u32)) {
            pin_xy[p.index()] = pd + oriented_term(&orient, ctx, p);
        }
    }

    // Collision boxes
    let mut col_boxes: Vec<Vec<Rect>> = vec![Vec::new(); ncol];
    for c in &cols {
        for &d in &c.devices {
            col_boxes[col_of[d.index()]].push(geom::dev_box(&orient, ctx, d, pos[d.index()]));
        }
    }

    // Foreign-pin obstacles: rails excluded — they render as bus labels, not
    // placed pins, in geometric-connectivity hosts.
    let mut pin_pts: Vec<(NetIdx, Pt)> = Vec::new();
    for d in 0..ctx.nd() {
        let di = DeviceIdx(d as u32);
        if ctx.is_rail(di) {
            continue;
        }
        for p in ctx.pins(di) {
            if let Some(n) = ctx.net_of(p) {
                pin_pts.push((n, pin_xy[p.index()]));
            }
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
        pin_pts: &pin_pts,
    };
    // Foreign bodies for the contract guard: every non-rail device box.
    // (Downstream R6 bodies are pin hulls; the class bbox is a superset.)
    let guard_boxes: Vec<(DeviceIdx, Rect)> = (0..ctx.nd())
        .map(|d| DeviceIdx(d as u32))
        .filter(|&di| !ctx.is_rail(di))
        .map(|di| (di, geom::dev_box(&orient, ctx, di, pos[di.index()])))
        .collect();
    // Margin-resident (feedback/source) conduction pins, grouped by net, so
    // they hook into their net's wiring inside the same guarded pass.
    let mut fb_pins: Vec<Vec<PinIdx>> = vec![Vec::new(); ctx.nn()];
    // In strict mode ALL pins hook up, not just conduction: a gated feedback
    // device (e.g. a transmission gate) has margin-resident gate pins too,
    // and an unhooked pin is a dangle in geometric-connectivity hosts.
    for c in cols.iter().filter(|c| !c.in_field()) {
        for &d in &c.devices {
            for p in ctx.pins(d) {
                if !cfg().layout.strict_geometry && !ctx.conducts(p) {
                    continue;
                }
                if let Some(net) = ctx.net_of(p) {
                    fb_pins[net.index()].push(p);
                }
            }
        }
    }

    let mut net_segs: Vec<Vec<Vec<Pt>>> = vec![Vec::new(); ctx.nn()];
    let mut labels: Vec<Label> = Vec::new();
    let mut fallbacks: Vec<(NetIdx, &'static str)> = Vec::new();
    let mut num_forward_margin = 0u32;
    // Nets route sequentially; each sees everything already drawn (`routed`)
    // and must not touch it — see `Obstacles::seg_dirty`.
    let mut routed: Vec<(NetIdx, Pt, Pt)> = Vec::new();
    let strict = cfg().layout.strict_geometry;
    for inf in &infos {
        let segs = &mut net_segs[inf.net.index()];
        // Host obstacles exist only in strict mode; empty lists make every
        // predicate degenerate to the pre-host routing exactly.
        let foreign = if strict {
            rc.foreign_pins(inf.net)
        } else {
            Vec::new()
        };
        let others: Vec<(Pt, Pt)> = if strict {
            routed
                .iter()
                .filter(|&&(n, _, _)| n != inf.net)
                .map(|&(_, a, b)| (a, b))
                .collect()
        } else {
            Vec::new()
        };
        // Device bodies with this net's own pin points on each: the escape
        // routines (jogged drops, channel jogs) must dodge bodies under the
        // same rule the contract guard judges them by.
        let bodies: Vec<(Rect, Vec<Pt>)> = if strict {
            guard_boxes
                .iter()
                .map(|&(di, b)| {
                    let own = ctx
                        .pins(di)
                        .filter(|&p| ctx.net_of(p) == Some(inf.net))
                        .map(|p| pin_xy[p.index()])
                        .collect();
                    (b, own)
                })
                .collect()
        } else {
            Vec::new()
        };
        let obs = Obstacles {
            foreign: &foreign,
            others: &others,
            bodies: &bodies,
        };
        match ctx.net_class(inf.net) {
            NetClass::Power => {
                let pts: Vec<Pt> = ctx
                    .members(inf.net)
                    .iter()
                    .map(|&p| pin_xy[p.index()])
                    .collect();
                route_bus_at(&pts, power_bus, &obs, segs);
            }
            NetClass::Ground => {
                let pts: Vec<Pt> = ctx
                    .members(inf.net)
                    .iter()
                    .map(|&p| pin_xy[p.index()])
                    .collect();
                route_bus_at(&pts, gnd_bus, &obs, segs);
            }
            NetClass::Signal => match inf.shared_hub {
                Some(hub) => {
                    let pts: Vec<Pt> = ctx
                        .members(inf.net)
                        .iter()
                        .map(|&p| pin_xy[p.index()])
                        .collect();
                    route_hub_trunk(&pts, pin_xy[hub.index()].y, &obs, segs);
                }
                None => route_net(
                    &rc,
                    inf,
                    &obs,
                    segs,
                    &mut labels,
                    &mut fallbacks,
                    &mut num_forward_margin,
                ),
            },
        }

        hook_margin_pins(ctx, inf.net, &fb_pins[inf.net.index()], &pin_xy, &obs, segs);

        // ── Contract guard ──
        // Wires are an OPTIMIZATION; labels are the GUARANTEE. Any segment
        // that touches a foreign pin, an already-routed foreign wire, or the
        // interior of a device body would be a short or an R6 violation in a
        // geometric-connectivity host — strip the net's wiring and label
        // every pin instead. A segment may cross an own-net device's box
        // only where it actually reaches that device's pin on this net (a
        // wire arriving at its own terminal); merely sharing a net does not
        // license slicing through the body art. The search key minimizes
        // labels, so this stays the exception, never the plan.
        let dirty = strict
            && segs
                .iter()
                .any(|poly| poly.windows(2).any(|w| obs.seg_dirty(w[0], w[1])));
        if dirty {
            segs.clear();
            label_net_pins(ctx, inf.net, &pin_xy, &mut labels);
            fallbacks.push((
                inf.net,
                "wiring violates host geometry (foreign pin/wire/body) — labelled instead",
            ));
        }

        for poly in segs.iter() {
            for w in poly.windows(2) {
                if w[0] != w[1] {
                    routed.push((inf.net, w[0], w[1]));
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
                labels.push(Label {
                    net,
                    at: pin_xy[p.index()],
                });
                fallbacks.push((
                    net,
                    "power/ground rail spans no device field — lab pin instead of a bus",
                ));
            }
        }
    }

    if strict {
        enforce_pin_coverage(ctx, &pin_xy, &mut net_segs, &mut labels, &mut fallbacks);
        enforce_crossing_budget(ctx, &pin_xy, &mut net_segs, &mut labels, &mut fallbacks);
    }
    let num_labels = labels.len() as u32;

    // Phase 6: violation metrics
    let num_body_hits = count_body_hits(
        ctx,
        &orient,
        &cols,
        &col_of,
        &pos,
        &net_segs,
        &mut fallbacks,
    );
    let num_pin_hits = count_pin_hits(&net_segs, &pin_pts, &mut fallbacks);
    let num_geom_shorts = count_geom_shorts(&net_segs, &mut fallbacks);

    // Phase 7: pack the result + metrics
    let physical = build_physical(ctx, pos, pin_xy, &net_segs, labels);
    let num_staples = staples.len() as u32;
    let total_span: u32 = staples
        .iter()
        .map(|s| (s.cols.last().unwrap() - s.cols[0]) as u32)
        .sum();
    let (num_crossings, num_overlaps) = count_crossings_and_overlaps(&net_segs);
    let mut netid_seq: Vec<u32> = infos.iter().map(|i| i.net.index() as u32).collect();
    netid_seq.sort_unstable();
    let metrics = Metrics {
        num_labels,
        num_forward_margin,
        num_pin_hits,
        num_geom_shorts,
        num_body_hits,
        num_overlaps,
        num_crossings,
        num_staples,
        total_span,
        margin_tracks,
        netid_seq,
    };
    Evaluated {
        physical,
        n_columns: ncol,
        metrics,
        orient,
        fallbacks,
    }
}

/// Phase 1: interior y of every device within its column (top-down stacking
/// with [`optimallen`] gaps). Device origins are grid-quantized so pins
/// (origin + host anchor) stay on the host's grid; the draw-derived bbox
/// extents are not grid multiples.
fn stack_columns(ctx: &Ctx, orient: &[Orientation], cols: &[Column], col_of: &[usize]) -> Vec<i32> {
    let grid = cfg().layout.grid;
    let mut dev_y = vec![0i32; ctx.nd()];
    for c in cols {
        let mut top = 0i32;
        let mut prev: Option<DeviceIdx> = None;
        for &d in &c.devices {
            let r = oriented_box_rel(orient, ctx, d);
            if let Some(p) = prev {
                top += optimallen(ctx, orient, p, d, col_of);
            }
            dev_y[d.index()] = snap_ceil(top - r.min.y, grid);
            top = dev_y[d.index()] + r.max.y;
            prev = Some(d);
        }
    }
    dev_y
}

/// One [`NetInfo`] per net with at least one in-field pin.
fn classify_nets(
    ctx: &Ctx,
    cols: &[Column],
    col_of: &[usize],
    col_kinds: &[ColumnKind],
    shared_dev: &[bool],
) -> Vec<NetInfo> {
    let mut infos = Vec::new();
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        // Feedback-column pins are margin-resident — exclude them from
        // classification, representative selection, and backward detection.
        let cs: Vec<usize> = net_columns(ctx, net, col_of)
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
        let case = classify(&cs, col_kinds);
        let shared_hub = ctx
            .members(net)
            .iter()
            .copied()
            .find(|&p| shared_dev[ctx.dev_of(p).index()] && ctx.conducts(p));
        let backward = net_is_backward(ctx, net, col_of, cols);
        infos.push(NetInfo {
            net,
            cols: cs,
            case,
            rep,
            shared_hub,
            backward,
        });
    }
    infos
}

/// Phase 2: rigid vertical offset per column — one horizontal pin alignment
/// chosen per adjacent column pair (`chosen_h`).
fn align_columns(
    ctx: &Ctx,
    cols: &[Column],
    infos: &[NetInfo],
    dev_y: &[i32],
    orient: &[Orientation],
) -> (Vec<i32>, Vec<Option<NetIdx>>) {
    let ncol = cols.len();
    let pin_iy =
        |p: PinIdx| -> i32 { dev_y[ctx.dev_of(p).index()] + oriented_term(orient, ctx, p).y };
    let mut offset = vec![0i32; ncol];
    let mut chosen_h: Vec<Option<NetIdx>> = vec![None; ncol.saturating_sub(1)];
    for g in 0..ncol.saturating_sub(1) {
        let mut best: Option<(bool, i32, u32, PinIdx, PinIdx, usize)> = None;
        for inf in infos {
            let (lo, hi) = (inf.cols[0], *inf.cols.last().unwrap());
            // A Component column aligns to a signal net passing through it and
            // its left neighbour (zero-stub plates). Local nets outrank spanning
            // ones — a spanning net's channel is free to move, a local run isn't.
            let mut cand = None;
            if cols[g + 1].kind == ColumnKind::Component
                && ctx.net_class(inf.net) == NetClass::Signal
            {
                if let (Some(pi), Some(pj)) = (inf.rep_in(g), inf.rep_in(g + 1)) {
                    cand = Some((inf.case == Case::SpanGe2, pi, pj, g));
                }
            }
            if cand.is_none() && inf.case == Case::ImmediateNeighbor && lo <= g && hi == g + 1 {
                if let (Some(pi), Some(pj)) = (inf.rep_in(lo), inf.rep_in(hi)) {
                    cand = Some((false, pi, pj, lo));
                }
            }
            let Some((span, pi, pj, base)) = cand else {
                continue;
            };
            let topy = pin_iy(pi).min(pin_iy(pj));
            let key = (span, topy, inf.net.index() as u32);
            if best.is_none_or(|b| key < (b.0, b.1, b.2)) {
                best = Some((span, topy, inf.net.index() as u32, pi, pj, base));
            }
        }
        if let Some((_, _, id, pi, pj, base)) = best {
            offset[g + 1] = offset[base] + pin_iy(pi) - pin_iy(pj);
            chosen_h[g] = Some(NetIdx::from_index(id as usize));
        } else {
            offset[g + 1] = offset[g];
        }
    }
    (offset, chosen_h)
}

/// Phase 3: assign each spanning net a margin track, smallest window first.
/// Returns (net → track, number of tracks used).
fn pack_tracks(staples: &[&NetInfo], nn: usize) -> (Vec<Option<u32>>, u32) {
    let mut track_of: Vec<Option<u32>> = vec![None; nn];
    let mut track_end: Vec<usize> = Vec::new();
    for s in staples {
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
    (track_of, margin_tracks)
}

/// Phase 3.5: choose each staple's exit (side riser lane or straight-up drop)
/// at both endpoint columns, allocating per-side lanes as it goes.
#[allow(clippy::type_complexity)]
fn staple_exits(
    ctx: &Ctx,
    orient: &[Orientation],
    cols: &[Column],
    col_of: &[usize],
    staples: &[&NetInfo],
    ncol: usize,
) -> (Vec<u32>, Vec<u32>, Vec<Option<(usize, Exit, usize, Exit)>>) {
    let mut front_lanes = vec![0u32; ncol];
    let mut back_lanes = vec![0u32; ncol];
    let pin_side = |p: PinIdx, fallback: bool| -> bool {
        let tx = oriented_term(orient, ctx, p).x;
        let bb = oriented_box_rel(orient, ctx, ctx.dev_of(p));
        if tx >= bb.max.x {
            true
        } else if tx <= bb.min.x {
            false
        } else {
            fallback
        }
    };
    // A pin at the very top of its column (top plate of a vertical bridge, top
    // drain of a stack) takes no side lane: the staple leg drops straight onto it.
    let exits_up = |p: PinIdx| -> Option<i32> {
        let d = ctx.dev_of(p);
        let c = col_of[d.index()];
        if c == usize::MAX || cols[c].devices.first() != Some(&d) {
            return None;
        }
        let t = oriented_term(orient, ctx, p);
        let bb = oriented_box_rel(orient, ctx, d);
        (t.x > bb.min.x && t.x < bb.max.x && t.y == bb.min.y).then_some(t.x)
    };
    let mut riser_info: Vec<Option<(usize, Exit, usize, Exit)>> = vec![None; ctx.nn()];
    for s in staples {
        let (lo, hi) = (s.cols[0], *s.cols.last().unwrap());
        // On-axis pins exit toward the span interior (lo → right, hi → left):
        // the run continues that way, so an exterior exit would wrap the column.
        let mut mk = |c: usize, pin: Option<PinIdx>, default_back: bool| -> Exit {
            if let Some(tx) = pin.and_then(exits_up) {
                return Exit::Up(tx);
            }
            let back = pin
                .map(|p| pin_side(p, default_back))
                .unwrap_or(default_back);
            let lanes = if back {
                &mut back_lanes
            } else {
                &mut front_lanes
            };
            let v = lanes[c];
            lanes[c] += 1;
            Exit::Side(back, v)
        };
        let lo_exit = mk(lo, s.rep_in(lo), true);
        let hi_exit = mk(hi, s.rep_in(hi), false);
        riser_info[s.net.index()] = Some((lo, lo_exit, hi, hi_exit));
    }
    (front_lanes, back_lanes, riser_info)
}

/// Phase 4: channel widths → column x, and each staple's riser x positions.
fn place_columns(
    ctx: &Ctx,
    cols: &[Column],
    orient: &[Orientation],
    infos: &[NetInfo],
    front_lanes: &[u32],
    back_lanes: &[u32],
    riser_info: &[Option<(usize, Exit, usize, Exit)>],
) -> (Vec<i32>, Vec<Option<(i32, i32)>>) {
    let ncol = cols.len();
    let grid = cfg().layout.grid;
    let tw = cfg().layout.track_w;
    let mut immediate = vec![0u32; ncol.saturating_sub(1)];
    for inf in infos {
        if inf.case == Case::ImmediateNeighbor {
            let g = inf.cols[0];
            if g < immediate.len() {
                immediate[g] += 1;
            }
        }
    }
    let gap_width = |g: usize| tw * (1 + back_lanes[g] + front_lanes[g + 1] + immediate[g]) as i32;
    // Per-column half-width: CELL half for builtins, wider for host classes
    // (runtime box components), grid-quantized so column x stays on grid.
    let col_half: Vec<i32> = cols
        .iter()
        .map(|c| {
            c.devices
                .iter()
                .map(|&d| {
                    let r = oriented_box_rel(orient, ctx, d);
                    r.max.x.max(-r.min.x)
                })
                .max()
                .unwrap_or(HALF)
                .max(HALF)
        })
        .map(|h| snap_ceil(h, grid))
        .collect();
    let mut col_x = vec![0i32; ncol];
    if ncol > 0 {
        col_x[0] = col_half[0] + front_lanes[0] as i32 * tw;
        for i in 1..ncol {
            if !cols[i].in_field() {
                col_x[i] = col_x[i - 1];
                continue;
            }
            col_x[i] = col_x[i - 1] + col_half[i - 1] + col_half[i] + gap_width(i - 1);
        }
    }
    let exit_x = |col: usize, back: bool, lane: u32| -> i32 {
        let off = col_half[col] + tw * (lane as i32 + 1);
        if back {
            col_x[col] + off
        } else {
            col_x[col] - off
        }
    };
    let mut riser_x: Vec<Option<(i32, i32)>> = vec![None; ctx.nn()];
    for (n, info) in riser_info.iter().enumerate() {
        if let Some(&(lo, le, hi, he)) = info.as_ref() {
            let ex = |c: usize, e: Exit| match e {
                Exit::Up(tx) => col_x[c] + tx,
                Exit::Side(back, lane) => exit_x(c, back, lane),
            };
            riser_x[n] = Some((ex(lo, le), ex(hi, he)));
        }
    }
    (col_x, riser_x)
}

/// Feedback devices: centred between bridged columns in the backward-route
/// band, then (strict mode) de-overlapped left-to-right — the band is one row,
/// and two devices given the same centre would put DIFFERENT-net pins on the
/// same point (a hard short in geometric-connectivity hosts).
fn place_feedback(
    ctx: &Ctx,
    cols: &[Column],
    col_of: &[usize],
    col_x: &[i32],
    orient: &[Orientation],
    power_bus: i32,
    pos: &mut [Pt],
) {
    let grid = cfg().layout.grid;
    let fb_band = power_bus - cfg().layout.margin_gap;
    let mut fb_at: Vec<(i32, DeviceIdx)> = cols
        .iter()
        .filter(|c| !c.in_field())
        .map(|c| {
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
            let cx = if xs.is_empty() {
                0
            } else {
                snap_near(xs.iter().sum::<i32>() / xs.len() as i32, grid)
            };
            (cx, d)
        })
        .collect();
    fb_at.sort_by_key(|&(cx, d)| (cx, d.index()));
    if cfg().layout.strict_geometry {
        let tw = cfg().layout.track_w;
        let mut next_free = i32::MIN;
        for (cx, d) in fb_at {
            let r = oriented_box_rel(orient, ctx, d);
            let x = if next_free == i32::MIN {
                cx
            } else {
                cx.max(snap_ceil(next_free - r.min.x, grid))
            };
            pos[d.index()] = Pt::new(x, fb_band);
            next_free = x + r.max.x + tw;
        }
    } else {
        for (cx, d) in fb_at {
            pos[d.index()] = Pt::new(cx, fb_band);
        }
    }
}

/// Rail positions: centred over spanned columns, on their bus.
fn place_rails(
    ctx: &Ctx,
    col_of: &[usize],
    col_x: &[i32],
    power_bus: i32,
    gnd_bus: i32,
    pos: &mut [Pt],
) {
    let grid = cfg().layout.grid;
    for (d, pd) in pos.iter_mut().enumerate() {
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
        let cx = if xs.is_empty() {
            0
        } else {
            snap_near(xs.iter().sum::<i32>() / xs.len() as i32, grid)
        };
        *pd = Pt::new(cx, if power { power_bus } else { gnd_bus });
    }
}
