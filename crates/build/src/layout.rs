//! Single-pass evaluation of a column order.
//!
//!   evaluate()            the whole pipeline, phase by phase
//!   § orientation         phase 0: rotate/mirror each device
//!   § oriented geometry   terminal / bounding-box coordinates under orientation
//!   § vertical spacing    phase 1 helpers: stacking gaps, backward-net detection
//!   § routing             phases 5–6: buses, per-net Manhattan routes
//!   § output & metrics    phase 7: pack Physical, junction dots, crossing count

use crate::ctx::{Ctx, NetClass};
use crate::extract::{
    Case, Column, ColumnKind, Spline, assign_columns, branch_counts, classify, column_of,
    net_columns,
};
use ir::{DeviceIdx, Label, NetIdx, Orientation, Physical, PinIdx, Pt, Rect, Rot};

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
    /// Every placed non-rail pin with its net — foreign-pin obstacles.
    pin_pts: &'a [(NetIdx, Pt)],
}

impl RouteCtx<'_> {
    fn pin_at(&self, p: PinIdx) -> Pt {
        self.pin_xy[p.index()]
    }

    /// Pin points of every net but `net`. A wire may not touch these at all:
    /// geometric-connectivity hosts merge a pin with any wire through its
    /// point, so even grazing one is a short.
    fn foreign_pins(&self, net: NetIdx) -> Vec<Pt> {
        self.pin_pts
            .iter()
            .filter(|&&(n, _)| n != net)
            .map(|&(_, p)| p)
            .collect()
    }
}

/// Is `p` on the closed orthogonal segment a–b (endpoints included)?
fn on_segment(p: Pt, a: Pt, b: Pt) -> bool {
    p == a || p == b || on_segment_interior(p, a, b)
}

/// Does the closed orthogonal segment a–b touch any of `pts`?
fn seg_hits_pin(pts: &[Pt], a: Pt, b: Pt) -> bool {
    pts.iter().any(|&p| on_segment(p, a, b))
}

/// Does the segment a–b cross a device body it may not? Each body carries the
/// routed net's own pin points on that device; same rule as the contract
/// guard: crossing an own-net device's box is legal only where the segment
/// contains that device's pin on the net.
fn seg_hits_body(bodies: &[(Rect, Vec<Pt>)], a: Pt, b: Pt) -> bool {
    let r = Rect::from_corners(a, b);
    bodies
        .iter()
        .any(|(bx, own)| r.intersects(bx) && !own.iter().any(|&pp| on_segment(pp, a, b)))
}


/// Are a net's wire segments + pins one connected island under touch
/// semantics? (Pins connect only through wires — coincident pins don't merge.)
fn one_island(segs: &[(Pt, Pt)], pins: &[Pt]) -> bool {
    let n = segs.len() + pins.len();
    if n <= 1 {
        return true;
    }
    let mut parent: Vec<usize> = (0..n).collect();
    fn find(p: &mut [usize], mut i: usize) -> usize {
        while p[i] != i {
            p[i] = p[p[i]];
            i = p[i];
        }
        i
    }
    let touches = |(a1, a2): (Pt, Pt), (b1, b2): (Pt, Pt)| {
        on_segment(a1, b1, b2)
            || on_segment(a2, b1, b2)
            || on_segment(b1, a1, a2)
            || on_segment(b2, a1, a2)
    };
    for i in 0..segs.len() {
        for j in (i + 1)..segs.len() {
            if touches(segs[i], segs[j]) {
                let (ri, rj) = (find(&mut parent, i), find(&mut parent, j));
                parent[ri] = rj;
            }
        }
        for (pi, &p) in pins.iter().enumerate() {
            if on_segment(p, segs[i].0, segs[i].1) {
                let (ri, rj) = (find(&mut parent, i), find(&mut parent, segs.len() + pi));
                parent[ri] = rj;
            }
        }
    }
    let root = find(&mut parent, 0);
    (0..n).all(|i| find(&mut parent, i) == root)
}

/// Label every (non-rail) pin of a net — the label fallback must cover the
/// WHOLE net: a geometric host connects by name only where a label touches,
/// so any unlabelled pin would dangle.
fn label_net_pins(ctx: &Ctx, net: NetIdx, pin_xy: &[Pt], labels: &mut Vec<Label>) {
    let mut pts: Vec<Pt> = ctx
        .members(net)
        .iter()
        .filter(|&&p| !ctx.is_rail(ctx.dev_of(p)))
        .map(|&p| pin_xy[p.index()])
        .collect();
    pts.sort_by_key(|p| (p.x, p.y));
    pts.dedup();
    for at in pts {
        labels.push(Label { net, at });
    }
}

/// Would drawing a–b short against an already-routed foreign segment? Any
/// endpoint of one lying on the other merges them in a geometric-connectivity
/// host (this also covers every collinear overlap — 1-D interval overlap puts
/// an endpoint inside the other interval). A pure interior crossing is legal.
fn seg_conflicts(a: Pt, b: Pt, others: &[(Pt, Pt)]) -> bool {
    others.iter().any(|&(c, d)| {
        on_segment(c, a, b) || on_segment(d, a, b) || on_segment(a, c, d) || on_segment(b, c, d)
    })
}

/// Any segment of the polyline conflicting per [`seg_conflicts`].
fn poly_conflicts(pts: &[Pt], others: &[(Pt, Pt)]) -> bool {
    pts.windows(2).any(|w| seg_conflicts(w[0], w[1], others))
}

/// Smallest grid multiple ≥ v (identity at grid ≤ 1).
fn snap_ceil(v: i32, g: i32) -> i32 {
    if g <= 1 { v } else { (v + g - 1).div_euclid(g) * g }
}

/// Nearest grid multiple (identity at grid ≤ 1).
fn snap_near(v: i32, g: i32) -> i32 {
    if g <= 1 { v } else { (v + g / 2).div_euclid(g) * g }
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
    // Device origins are grid-quantized so pins (origin + host anchor) stay on
    // the host's grid; the draw-derived bbox extents are not grid multiples.
    let mut dev_y = vec![0i32; ctx.nd()];
    for c in &cols {
        let mut top = 0i32;
        let mut prev: Option<DeviceIdx> = None;
        for &d in &c.devices {
            let r = oriented_box_rel(&orient, ctx, d);
            if let Some(p) = prev {
                top += optimallen(ctx, &orient, p, d, &col_of);
            }
            dev_y[d.index()] = snap_ceil(top - r.min.y, grid);
            top = dev_y[d.index()] + r.max.y;
            prev = Some(d);
        }
    }
    let pin_iy =
        |p: PinIdx| -> i32 { dev_y[ctx.dev_of(p).index()] + oriented_term(&orient, ctx, p).y };

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
        infos.push(NetInfo {
            net,
            cols: cs,
            case,
            rep,
            shared_hub,
            backward,
        });
    }

    // Phase 2: rigid vertical offsets (one horizontal alignment per adjacent pair)
    let mut offset = vec![0i32; ncol];
    let mut chosen_h: Vec<Option<NetIdx>> = vec![None; ncol.saturating_sub(1)];
    for g in 0..ncol.saturating_sub(1) {
        let mut best: Option<(bool, i32, u32, PinIdx, PinIdx, usize)> = None;
        for inf in &infos {
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
    // A pin at the very top of its column (top plate of a vertical bridge, top
    // drain of a stack) takes no side lane: the staple leg drops straight onto it.
    let exits_up = |p: PinIdx| -> Option<i32> {
        let d = ctx.dev_of(p);
        let c = col_of[d.index()];
        if c == usize::MAX || cols[c].devices.first() != Some(&d) {
            return None;
        }
        let t = oriented_term(&orient, ctx, p);
        let bb = oriented_box_rel(&orient, ctx, d);
        (t.x > bb.min.x && t.x < bb.max.x && t.y == bb.min.y).then_some(t.x)
    };
    let mut riser_info: Vec<Option<(usize, Exit, usize, Exit)>> = vec![None; ctx.nn()];
    for s in &staples {
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
    // Per-column half-width: CELL half for builtins, wider for host classes
    // (runtime box components), grid-quantized so column x stays on grid.
    let col_half: Vec<i32> = cols
        .iter()
        .map(|c| {
            c.devices
                .iter()
                .map(|&d| {
                    let r = oriented_box_rel(&orient, ctx, d);
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

    // Feedback devices: centred between bridged columns in the backward-route
    // band, then de-overlapped left-to-right — the band is one row, and two
    // devices given the same centre would put DIFFERENT-net pins on the same
    // point (a hard short in geometric-connectivity hosts).
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
            let r = oriented_box_rel(&orient, ctx, d);
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

    // Rail positions: centred over spanned columns, on their bus
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

    // Pin coordinates
    let mut pin_xy = vec![Pt::new(0, 0); ctx.ir.pins.len()];
    for (d, &pd) in pos.iter().enumerate() {
        let di = DeviceIdx(d as u32);
        for p in ctx.pins(di) {
            pin_xy[p.index()] = pd + oriented_term(&orient, ctx, p);
        }
    }

    // Collision boxes
    let mut col_boxes: Vec<Vec<Rect>> = vec![Vec::new(); ncol];
    for c in &cols {
        for &d in &c.devices {
            col_boxes[col_of[d.index()]].push(dev_box(&orient, ctx, d, pos[d.index()]));
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
        .map(|di| (di, dev_box(&orient, ctx, di, pos[di.index()])))
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
    // and must not touch it — see `seg_conflicts`.
    let mut routed: Vec<(NetIdx, Pt, Pt)> = Vec::new();
    let strict = cfg().layout.strict_geometry;
    for inf in &infos {
        let segs = &mut net_segs[inf.net.index()];
        // Host obstacles exist only in strict mode; empty lists make every
        // new predicate degenerate to the pre-host routing exactly.
        let foreign = if strict { rc.foreign_pins(inf.net) } else { Vec::new() };
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
        // same rule the contract guard judges them by — see `seg_hits_body`.
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
        // The contract predicate, shared by the guard below and the hub-row
        // search: a segment is dirty if it touches a foreign pin, an
        // already-routed foreign wire, or a device body away from that
        // device's own pin on this net. Empty obstacle lists (non-strict
        // mode) make every segment clean.
        let seg_dirty = |a: Pt, b: Pt| {
            a != b
                && (seg_hits_pin(&foreign, a, b)
                    || seg_conflicts(a, b, &others)
                    || seg_hits_body(&bodies, a, b))
        };
        match ctx.net_class(inf.net) {
            NetClass::Power => {
                let pts: Vec<Pt> = ctx
                    .members(inf.net)
                    .iter()
                    .map(|&p| pin_xy[p.index()])
                    .collect();
                route_bus_at(&pts, power_bus, &foreign, &others, &bodies, segs);
            }
            NetClass::Ground => {
                let pts: Vec<Pt> = ctx
                    .members(inf.net)
                    .iter()
                    .map(|&p| pin_xy[p.index()])
                    .collect();
                route_bus_at(&pts, gnd_bus, &foreign, &others, &bodies, segs);
            }
            NetClass::Signal => match inf.shared_hub {
                Some(hub) => {
                    let pts: Vec<Pt> = ctx
                        .members(inf.net)
                        .iter()
                        .map(|&p| pin_xy[p.index()])
                        .collect();
                    // Trunk row: the hub row when its whole geometry passes
                    // the contract predicate, else the nearest clean row
                    // within ±6 tracks — ALL below-rows before any above-row
                    // (a diff pair's tail trunk belongs BELOW the
                    // transistors, meeting the current source's pin; only
                    // when nothing below is clean may the trunk go over the
                    // top). Nothing clean at all keeps the hub row — the
                    // guard labels it.
                    let hub_y = pin_xy[hub.index()].y;
                    let th = cfg().layout.track_h;
                    let rows = std::iter::once(hub_y)
                        .chain((1..=6).map(|k| hub_y + k * th))
                        .chain((1..=6).map(|k| hub_y - k * th));
                    let mut best: Option<Vec<Vec<Pt>>> = None;
                    for y in rows {
                        let mut cand: Vec<Vec<Pt>> = Vec::new();
                        route_bus_at(&pts, y, &foreign, &others, &bodies, &mut cand);
                        if cand
                            .iter()
                            .all(|poly| poly.windows(2).all(|w| !seg_dirty(w[0], w[1])))
                        {
                            best = Some(cand);
                            break;
                        }
                    }
                    match best {
                        Some(mut c) => segs.append(&mut c),
                        None => {
                            route_bus_at(&pts, hub_y, &foreign, &others, &bodies, segs)
                        }
                    }
                }
                None => route_net(
                    &rc,
                    inf,
                    &foreign,
                    &others,
                    &bodies,
                    segs,
                    &mut labels,
                    &mut fallbacks,
                    &mut num_forward_margin,
                ),
            },
        }

        // Margin pins (feedback devices, hanging sources) hook into the
        // net's wiring. Strict mode additionally falls back to the nearest
        // same-net pin (geometric hosts have no by-name nets: an unwired pin
        // is a dangle) and skips pins already touching the wiring.
        for &p in &fb_pins[inf.net.index()] {
            let at = pin_xy[p.index()];
            if strict {
                let on_wiring = segs
                    .iter()
                    .any(|poly| poly.windows(2).any(|w| on_segment(at, w[0], w[1])));
                if on_wiring {
                    continue;
                }
            }
            // Strict mode: nearest anchor whose L-hook passes the contract
            // predicate, else plain nearest (the guard labels it). Non-strict
            // keeps the plain nearest — the pre-host choice exactly.
            let dist = |q: Pt| (q.x - at.x).abs() + (q.y - at.y).abs();
            let clean_l = |q: Pt| {
                let mid = Pt::new(at.x, q.y);
                !seg_dirty(at, mid) && !seg_dirty(mid, q)
            };
            let pick = |cands: Vec<Pt>| -> Option<Pt> {
                let nearest = cands.iter().copied().min_by_key(|&q| dist(q))?;
                if !strict || clean_l(nearest) {
                    return Some(nearest);
                }
                let mut sorted = cands;
                sorted.sort_by_key(|&q| (dist(q), q.x, q.y));
                Some(sorted.into_iter().find(|&q| clean_l(q)).unwrap_or(nearest))
            };
            let nearest = pick(segs.iter().flatten().copied().collect()).or_else(|| {
                if !strict {
                    return None;
                }
                pick(
                    ctx.members(inf.net)
                        .iter()
                        .filter(|&&q| q != p)
                        .map(|&q| pin_xy[q.index()])
                        .collect(),
                )
            });
            match nearest {
                Some(anchor) if !strict || anchor != at => {
                    segs.push(vec![at, Pt::new(at.x, anchor.y), anchor]);
                }
                Some(_) => {}
                None => {
                    if !strict {
                        segs.push(vec![at]); // pre-host: lone point marker
                    }
                }
            }
        }

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
        let net = inf.net;
        let dirty = cfg().layout.strict_geometry
            && segs
                .iter()
                .any(|poly| poly.windows(2).any(|w| seg_dirty(w[0], w[1])));
        if dirty {
            segs.clear();
            label_net_pins(ctx, net, &pin_xy, &mut labels);
            fallbacks.push((
                net,
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

    // Pin-coverage closure (strict hosts only): after all routing, every pin
    // of every net must sit on its net's own wiring or carry a label — a
    // geometric host resolves connectivity by touch, so anything less is a
    // dangle. A net that misses ANY pin is stripped and fully labelled.
    // (Also covers geometry-less nets: single-pin nets left by a skipped
    // master, pins living entirely in the margins.)
    if cfg().layout.strict_geometry {
        for n in 0..ctx.nn() {
            let net = NetIdx::from_index(n);
            if labels.iter().any(|l| l.net == net) {
                continue; // already labelled — labels cover all pins
            }
            // Every pin on the wiring AND the whole net one island: covered
            // pins on two disconnected wire groups still split the net.
            let segs_n: Vec<(Pt, Pt)> = net_segs[n]
                .iter()
                .flat_map(|poly| poly.windows(2).map(|w| (w[0], w[1])))
                .filter(|&(a, b)| a != b)
                .collect();
            let pins_n: Vec<Pt> = ctx
                .members(net)
                .iter()
                .filter(|&&p| !ctx.is_rail(ctx.dev_of(p)))
                .map(|&p| pin_xy[p.index()])
                .collect();
            let all_covered = pins_n
                .iter()
                .all(|&at| segs_n.iter().any(|&(a, b)| on_segment(at, a, b)))
                && one_island(&segs_n, &pins_n);
            if !all_covered {
                net_segs[n].clear();
                let before = labels.len();
                label_net_pins(ctx, net, &pin_xy, &mut labels);
                if labels.len() > before {
                    fallbacks.push((net, "wiring misses a pin — lab pins instead"));
                }
            }
        }

        // Crossing budget: dense fields read badly and hosts lint them
        // (Schemify Q4: crossings ≤ max(10, wires/4)). Strip the net with
        // the most different-net crossings to labels until under budget —
        // labels remove crossings without touching correctness.
        loop {
            let mut segs_flat: Vec<(usize, Pt, Pt)> = Vec::new();
            for (n, polys) in net_segs.iter().enumerate() {
                for poly in polys {
                    for w in poly.windows(2) {
                        if w[0] != w[1] {
                            segs_flat.push((n, w[0], w[1]));
                        }
                    }
                }
            }
            let mut per_net = vec![0u32; ctx.nn()];
            let mut total = 0u32;
            for i in 0..segs_flat.len() {
                for j in (i + 1)..segs_flat.len() {
                    let (a, b) = (&segs_flat[i], &segs_flat[j]);
                    if a.0 == b.0 {
                        continue;
                    }
                    let (a_h, b_h) = (a.1.y == a.2.y, b.1.y == b.2.y);
                    if a_h == b_h {
                        continue;
                    }
                    let ((h1, h2), (v1, v2)) = if a_h {
                        ((a.1, a.2), (b.1, b.2))
                    } else {
                        ((b.1, b.2), (a.1, a.2))
                    };
                    let (hx0, hx1) = (h1.x.min(h2.x), h1.x.max(h2.x));
                    let (vy0, vy1) = (v1.y.min(v2.y), v1.y.max(v2.y));
                    if hx0 < v1.x && v1.x < hx1 && vy0 < h1.y && h1.y < vy1 {
                        per_net[a.0] += 1;
                        per_net[b.0] += 1;
                        total += 1;
                    }
                }
            }
            // Downstream lint budget; keep in lockstep with Schemify Q4.
            let budget = 10u32.max(segs_flat.len() as u32 / 4);
            if total <= budget {
                break;
            }
            let worst = (0..ctx.nn()).max_by_key(|&n| per_net[n]).unwrap();
            if per_net[worst] == 0 {
                break;
            }
            net_segs[worst].clear();
            let net = NetIdx::from_index(worst);
            label_net_pins(ctx, net, &pin_xy, &mut labels);
            fallbacks.push((net, "crossing budget exceeded — busiest net labelled"));
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
            if ctx.is_rail(di) {
                return false;
            }
            let c = col_of[d];
            c == usize::MAX || cols[c].in_field()
        })
        .map(|d| {
            let di = DeviceIdx(d as u32);
            (di, dev_box(&orient, ctx, di, pos[d]))
        })
        .collect();
    let mut num_body_hits = 0u32;
    for (n, segs) in net_segs.iter().enumerate() {
        let net = NetIdx::from_index(n);
        let net_devs: Vec<DeviceIdx> = ctx.members(net).iter().map(|&p| ctx.dev_of(p)).collect();
        let mut hit = false;
        for poly in segs {
            for w in poly.windows(2) {
                let r = Rect::from_corners(w[0], w[1]);
                for &(di, ref b) in &all_boxes {
                    if net_devs.contains(&di) {
                        continue;
                    }
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

    // Foreign-pin hits: any wire touching another net's pin point (a short in
    // geometric-connectivity hosts).
    let mut num_pin_hits = 0u32;
    for (n, segs) in net_segs.iter().enumerate().filter(|_| cfg().layout.strict_geometry) {
        let net = NetIdx::from_index(n);
        let mut hit = false;
        for poly in segs {
            for w in poly.windows(2) {
                for &(pn, pp) in &pin_pts {
                    if pn != net && on_segment(pp, w[0], w[1]) {
                        num_pin_hits += 1;
                        hit = true;
                    }
                }
            }
        }
        if hit {
            fallbacks.push((net, "a wire touches a foreign pin"));
        }
    }

    // Geometric T-shorts: a wire vertex of one net landing on another net's
    // wire. Downstream each straight run is one wire, so EVERY vertex is a
    // wire endpoint and merges with whatever it touches.
    let mut num_geom_shorts = 0u32;
    if cfg().layout.strict_geometry {
        let verts: Vec<Vec<Pt>> = net_segs
            .iter()
            .map(|segs| {
                let mut v: Vec<Pt> = segs.iter().flatten().copied().collect();
                v.sort_by_key(|p| (p.x, p.y));
                v.dedup();
                v
            })
            .collect();
        // ponytail: O(nets² · verts) scan — fine at schematic scale
        for i in 0..net_segs.len() {
            let mut hit = false;
            for (j, segs) in net_segs.iter().enumerate() {
                if i == j {
                    continue;
                }
                for &v in &verts[i] {
                    if segs
                        .iter()
                        .any(|poly| poly.windows(2).any(|w| on_segment(v, w[0], w[1])))
                    {
                        num_geom_shorts += 1;
                        hit = true;
                    }
                }
            }
            if hit {
                fallbacks.push((
                    NetIdx::from_index(i),
                    "a wire endpoint lands on another net's wire",
                ));
            }
        }
    }

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

// ── § orientation (phase 0) ─────────────────────────────────────────────────

fn compute_orientation(ctx: &Ctx, cols: &[Column], col_of: &[usize]) -> Vec<Orientation> {
    let mut orient = vec![Orientation::H; ctx.nd()];
    for (ci, col) in cols.iter().enumerate() {
        if !matches!(
            col.kind,
            ColumnKind::Spline
                | ColumnKind::Shared
                | ColumnKind::Component
                | ColumnKind::SignalSeries
                | ColumnKind::Feedback
        ) {
            continue;
        }
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
            let above = if i > 0 {
                Some(col.devices[i - 1])
            } else {
                None
            };
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
/// when the facing terminals are not linked.
fn optimallen(
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
            let len = (ctx.degree(net) as i32 - in_spline as i32 - 1).max(0)
                * cfg().layout.tap_unit;
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

/// Horizontal bus at `bus_y` with vertical drops from each pin. A drop that
/// would pass through a foreign pin, wire, or device body jogs sideways by
/// whole tracks (both sides tried; a hit everywhere stays straight and
/// surfaces as a pin-hit / geom-short / body metric).
fn route_bus_at(
    pts: &[Pt],
    bus_y: i32,
    foreign: &[Pt],
    others: &[(Pt, Pt)],
    bodies: &[(Rect, Vec<Pt>)],
    out: &mut Vec<Vec<Pt>>,
) {
    if pts.len() < 2 {
        return;
    }
    let mut drops: Vec<Vec<Pt>> = Vec::new();
    let mut bus_xs: Vec<i32> = pts.iter().map(|p| p.x).collect();
    for p in pts {
        if p.y == bus_y {
            continue;
        }
        let poly = jogged_drop(*p, bus_y, foreign, others, bodies);
        bus_xs.push(poly.last().unwrap().x);
        drops.push(poly);
    }
    // Trunk spans every landing point (a jogged drop may fall past a pin x).
    let minx = bus_xs.iter().copied().min().unwrap();
    let maxx = bus_xs.iter().copied().max().unwrap();
    out.push(vec![Pt::new(minx, bus_y), Pt::new(maxx, bus_y)]);
    out.extend(drops);
}

/// Vertical drop from `p` to `to_y`, jogging sideways by whole tracks when
/// the straight drop touches a foreign pin, an already-routed foreign wire,
/// or a device body (own-net bodies allowed only through their pin — see
/// [`seg_hits_body`]). No clear lane within a few tracks stays straight and
/// surfaces as a metric.
fn jogged_drop(
    p: Pt,
    to_y: i32,
    foreign: &[Pt],
    others: &[(Pt, Pt)],
    bodies: &[(Rect, Vec<Pt>)],
) -> Vec<Pt> {
    // The pin itself sits on the drop; exclude it from the pin test.
    let hits = |a: Pt, b: Pt| foreign.iter().any(|&q| q != p && on_segment(q, a, b));
    let dirty = |poly: &[Pt]| {
        poly.windows(2).any(|w| {
            hits(w[0], w[1])
                || seg_conflicts(w[0], w[1], others)
                || seg_hits_body(bodies, w[0], w[1])
        })
    };
    let drop = vec![p, Pt::new(p.x, to_y)];
    if !dirty(&drop) {
        return drop;
    }
    let tw = cfg().layout.track_w;
    (1..=4)
        .flat_map(|k| [k * tw, -k * tw])
        .find_map(|dx| {
            let side = Pt::new(p.x + dx, p.y);
            let down = Pt::new(p.x + dx, to_y);
            let cand = vec![p, side, down];
            (!dirty(&cand)).then_some(cand)
        })
        .unwrap_or(drop)
}

/// Route one signal net by its case: within a column, between immediate
/// neighbours, or spanning (staple through a field channel or the top margin).
#[allow(clippy::too_many_arguments)]
fn route_net(
    rc: &RouteCtx,
    inf: &NetInfo,
    foreign: &[Pt],
    others: &[(Pt, Pt)],
    bodies: &[(Rect, Vec<Pt>)],
    out: &mut Vec<Vec<Pt>>,
    labels: &mut Vec<Label>,
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
    num_forward_margin: &mut u32,
) {
    match inf.case {
        Case::WithinSpline => {
            let col = inf.cols[0];
            let ps: Vec<(Pt, bool)> = rc
                .ctx
                .members(inf.net)
                .iter()
                .filter(|&&q| rc.col_of[rc.ctx.dev_of(q).index()] == col)
                .map(|&q| (rc.pin_at(q), rc.ctx.conducts(q)))
                .collect();
            wire_column_pins(&ps, &rc.col_boxes[col], foreign, others, out);
        }
        Case::ImmediateNeighbor => {
            let (lo, hi) = (inf.cols[0], *inf.cols.last().unwrap());
            let pi = inf.rep_in(lo).map(|p| rc.pin_at(p));
            let pj = inf.rep_in(hi).map(|p| rc.pin_at(p));
            if let (Some(a), Some(b)) = (pi, pj) {
                let is_chosen =
                    (lo..hi).any(|g| rc.chosen_h.get(g).copied().flatten() == Some(inf.net));
                // Interior columns (Shared/Component) are transparent to spline
                // distance but their bodies still block wires.
                let run_clear = |y: i32| -> bool {
                    let (p, q) = (Pt::new(a.x.min(b.x), y), Pt::new(a.x.max(b.x), y));
                    let seg = Rect::from_corners(p, q);
                    ((lo + 1)..hi).all(|c| rc.col_boxes[c].iter().all(|bx| !seg.intersects(bx)))
                        && !seg_hits_pin(foreign, p, q)
                        && !seg_conflicts(p, q, others)
                };
                let mut run = None;
                if is_chosen && a.y == b.y && run_clear(a.y) {
                    out.push(vec![a, b]);
                    run = Some((a.y, snap_near((a.x + b.x) / 2, cfg().layout.grid)));
                } else if let Some(mx) =
                    channel_mx(rc.col_boxes, lo, hi, a, b, foreign, others, bodies)
                {
                    out.push(vec![a, Pt::new(mx, a.y), Pt::new(mx, b.y), b]);
                    run = Some((a.y, mx));
                } else {
                    // No clean jog exists (e.g. the X of a cross-coupled
                    // pair) — connect by name instead of drawing a short.
                    // EVERY pin gets a tap: unlabelled pins would dangle.
                    label_net_pins(rc.ctx, inf.net, rc.pin_xy, labels);
                    fallbacks.push((
                        inf.net,
                        "no overlap-free jog between neighbour columns — labelled instead",
                    ));
                }
                if let Some((run_y, run_x)) = run {
                    for &(c, p) in &inf.rep {
                        if c > lo && c < hi {
                            let q = rc.pin_at(p);
                            out.push(vec![q, Pt::new(q.x, run_y), Pt::new(run_x, run_y)]);
                        }
                    }
                }
            }
        }
        Case::SpanGe2 => {
            let (lo, hi) = (inf.cols[0], *inf.cols.last().unwrap());
            let a = inf.rep_in(lo).map(|p| rc.pin_at(p));
            let b = inf.rep_in(hi).map(|p| rc.pin_at(p));
            if let (Some(a), Some(b)) = (a, b) {
                let channel = find_channel_y(rc.col_boxes, lo, hi, a, b, foreign, others);
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
                    // Riser legs only where the wire actually changes level — an
                    // endpoint already at the run y connects straight along it.
                    let (rxlo, rxhi) = rc.riser_x[inf.net.index()].unwrap_or((a.x, b.x));
                    let mut pts = vec![a];
                    if a.y != y {
                        pts.extend([Pt::new(rxlo, a.y), Pt::new(rxlo, y)]);
                    }
                    if b.y != y {
                        pts.extend([Pt::new(rxhi, y), Pt::new(rxhi, b.y)]);
                    }
                    pts.push(b);
                    out.push(pts);
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
                            out.push(jogged_drop(q, run_y, foreign, others, bodies));
                        }
                    }
                }
            } else {
                let at = a
                    .or(b)
                    .or_else(|| rc.ctx.members(inf.net).first().map(|&p| rc.pin_at(p)));
                if let Some(at) = at {
                    if cfg().layout.strict_geometry {
                        label_net_pins(rc.ctx, inf.net, rc.pin_xy, labels);
                    } else {
                        labels.push(Label { net: inf.net, at });
                    }
                    fallbacks.push((inf.net, "no representative pin at a span endpoint column"));
                }
            }
        }
    }
    // Intra-column taps: multi-column nets may have several pins in one column
    if inf.case != Case::WithinSpline {
        for &(c, _) in &inf.rep {
            let ps: Vec<(Pt, bool)> = rc
                .ctx
                .members(inf.net)
                .iter()
                .filter(|&&p| rc.col_of[rc.ctx.dev_of(p).index()] == c)
                .map(|&p| (rc.pin_at(p), rc.ctx.conducts(p)))
                .collect();
            wire_column_pins(&ps, &rc.col_boxes[c], foreign, others, out);
        }
    }
}

/// Wire multiple pins in the same column: gather off-axis pins onto the dominant
/// axis, then run the axis spine — every segment is collision-checked and detours
/// through a side channel wherever a device body blocks the direct path.
fn wire_column_pins(
    pins: &[(Pt, bool)],
    boxes: &[Rect],
    foreign: &[Pt],
    others: &[(Pt, Pt)],
    out: &mut Vec<Vec<Pt>>,
) {
    if pins.len() < 2 {
        return;
    }
    let mut ps: Vec<Pt> = pins.iter().map(|&(p, _)| p).collect();
    ps.sort_by_key(|p| (p.y, p.x));
    ps.dedup();
    if ps.len() < 2 {
        return;
    }
    // Pins already on this net's existing wiring (a staple run passing through,
    // an interior tap) need nothing more — re-wiring them draws redundant loops.
    let on_wiring = |p: Pt| -> bool {
        out.iter()
            .flat_map(|poly| poly.windows(2))
            .any(|w| w[0] == p || w[1] == p || on_segment_interior(p, w[0], w[1]))
    };
    if ps.iter().all(|&p| on_wiring(p)) {
        return;
    }
    // Dominant axis: the x shared by the most pins — coincident pins each count,
    // so a chained drain/source junction outweighs a lone gate. Ties prefer an x
    // with a conduction pin (the spline axis), then leftmost.
    let axis_x = {
        let score = |x: i32| {
            (
                pins.iter().filter(|q| q.0.x == x).count(),
                pins.iter().any(|q| q.0.x == x && q.1),
                std::cmp::Reverse(x),
            )
        };
        ps.iter().map(|p| p.x).max_by_key(|&x| score(x)).unwrap()
    };
    // A vertical run is blocked by a box it strictly crosses, and also by a box
    // whose FULL height it spans while flush with its edge — that redraws the
    // device's own conduction path and reads as a short across its terminals.
    let blocks = |b: &Rect, x: i32, lo: i32, hi: i32| -> bool {
        let seg = Rect::new(Pt::new(x, lo), Pt::new(x + 1, hi));
        seg.intersects(b)
            || (b.min.x - 1 <= x && x <= b.max.x + 1 && lo <= b.min.y && hi >= b.max.y)
    };
    let blocked = |x: i32, y0: i32, y1: i32| -> bool {
        let (lo, hi) = (y0.min(y1), y0.max(y1));
        boxes.iter().any(|b| blocks(b, x, lo, hi))
            || seg_hits_pin(foreign, Pt::new(x, lo), Pt::new(x, hi))
            || seg_conflicts(Pt::new(x, lo), Pt::new(x, hi), others)
    };
    // Side-channel x on the requested side, clear of every box and both
    // endpoints, on the host grid (wires must land on grid like pins do).
    let grid = cfg().layout.grid;
    let side_x = |back: bool, x0: i32, x1: i32| -> i32 {
        if back {
            snap_ceil(
                boxes
                    .iter()
                    .map(|b| b.max.x)
                    .max()
                    .unwrap_or(axis_x)
                    .max(x0.max(x1))
                    + SIDE_CLEAR,
                grid,
            )
        } else {
            -snap_ceil(
                -(boxes
                    .iter()
                    .map(|b| b.min.x)
                    .min()
                    .unwrap_or(axis_x)
                    .min(x0.min(x1))
                    - SIDE_CLEAR),
                grid,
            )
        }
    };
    // A candidate polyline touching a foreign pin or an already-routed
    // foreign wire is dirty.
    let dirty = |pts: &[Pt]| {
        pts.windows(2).any(|w| seg_hits_pin(foreign, w[0], w[1])) || poly_conflicts(pts, others)
    };
    let tw = cfg().layout.track_w;
    // Detour lane search: preferred side at its channel x, then whole-track
    // steps outward, then the same ladder on the far side. First clean lane
    // wins; nothing clean keeps the preferred lane (surfaces as a metric).
    let pick_detour = |mk: &dyn Fn(bool, i32) -> Vec<Pt>, prefer: bool| -> Vec<Pt> {
        for back in [prefer, !prefer] {
            for k in 0..4 {
                let shift = if back { k * tw } else { -k * tw };
                let cand = mk(back, shift);
                if !dirty(&cand) {
                    return cand;
                }
            }
        }
        mk(prefer, 0)
    };
    let on_axis: Vec<Pt> = ps.iter().filter(|p| p.x == axis_x).copied().collect();
    let mut v_ys: Vec<i32> = on_axis.iter().map(|p| p.y).collect();
    for &op in ps.iter().filter(|p| p.x != axis_x) {
        let nearest = on_axis
            .iter()
            .min_by_key(|p| (p.y - op.y).abs())
            .copied()
            .unwrap_or(ps[0]);
        let gather = vec![op, Pt::new(axis_x, op.y)];
        if blocked(axis_x, nearest.y, op.y) || dirty(&gather) {
            // Detour on the pin's own side of the axis first.
            let mk = |back: bool, shift: i32| -> Vec<Pt> {
                let sx = side_x(back, nearest.x, op.x) + shift;
                vec![nearest, Pt::new(sx, nearest.y), Pt::new(sx, op.y), op]
            };
            out.push(pick_detour(&mk, op.x >= axis_x));
        } else {
            v_ys.push(op.y);
            out.push(gather);
        }
    }
    v_ys.sort();
    v_ys.dedup();
    // Axis spine: straight where clear, around a blocking body otherwise
    // (e.g. antiparallel pass devices whose far terminals share a net).
    // The detour goes to the side OPPOSITE the blockers' bulk.
    for w in v_ys.windows(2) {
        let (y0, y1) = (w[0], w[1]);
        if blocked(axis_x, y0, y1) {
            let bulk: i32 = boxes
                .iter()
                .filter(|b| blocks(b, axis_x, y0, y1))
                .map(|b| (b.min.x + b.max.x) / 2 - axis_x)
                .sum();
            let mk = |back: bool, shift: i32| -> Vec<Pt> {
                let sx = side_x(back, axis_x, axis_x) + shift;
                vec![
                    Pt::new(axis_x, y0),
                    Pt::new(sx, y0),
                    Pt::new(sx, y1),
                    Pt::new(axis_x, y1),
                ]
            };
            out.push(pick_detour(&mk, bulk <= 0));
        } else {
            out.push(vec![Pt::new(axis_x, y0), Pt::new(axis_x, y1)]);
        }
    }
}

/// The x for the vertical jog of an immediate-neighbour route: inside the window
/// between the endpoint columns' bodies, and clear of every intermediate column's
/// boxes (a bridge capacitor between the columns must not be stabbed). Nearest
/// clear gap-midpoint to the window centre wins; falls back to the centre.
#[allow(clippy::too_many_arguments)]
fn channel_mx(
    col_boxes: &[Vec<Rect>],
    lo: usize,
    hi: usize,
    a: Pt,
    b: Pt,
    foreign: &[Pt],
    others: &[(Pt, Pt)],
    bodies: &[(Rect, Vec<Pt>)],
) -> Option<i32> {
    let mid: Vec<&Rect> = ((lo + 1)..hi).flat_map(|c| col_boxes[c].iter()).collect();
    // The jog is three segments — vertical at x plus the two horizontal legs —
    // and all three must clear the intermediate bodies, every device body
    // (own-net ones allowed only through their pin), every foreign pin, and
    // everything already routed.
    let clear = |x: i32| -> bool {
        let legs = [
            (Pt::new(x, a.y.min(b.y)), Pt::new(x, a.y.max(b.y))),
            (Pt::new(a.x.min(x), a.y), Pt::new(a.x.max(x), a.y)),
            (Pt::new(b.x.min(x), b.y), Pt::new(b.x.max(x), b.y)),
        ];
        legs.iter().all(|&(p, q)| {
            let r = Rect::from_corners(p, q);
            !mid.iter().any(|bx| r.intersects(bx))
                && !seg_hits_pin(foreign, p, q)
                && !seg_conflicts(p, q, others)
                && !seg_hits_body(bodies, p, q)
        })
    };
    // Whole-track scan around `x0`: nearest clean jog x on the grid. None =
    // no clean jog exists in the shape vocabulary — the caller falls back to
    // a label (an X-topology like a cross-coupled pair cannot be drawn with
    // Z-jogs: the two shared pin rows force an overlap at every jog x).
    let grid = cfg().layout.grid;
    let scan = |x0: i32| -> Option<i32> {
        let x0 = snap_near(x0, grid);
        if !cfg().layout.strict_geometry {
            return Some(x0); // pre-host behavior: take the midpoint as-is
        }
        let tw = cfg().layout.track_w;
        (0..=4)
            .flat_map(|k| [x0 + k * tw, x0 - k * tw])
            .find(|&x| clear(x))
    };
    let left = col_boxes[lo].iter().map(|r| r.max.x).max();
    let right = col_boxes[hi].iter().map(|r| r.min.x).min();
    let (l, r) = match (left, right) {
        (Some(l), Some(r)) if l < r => (l, r),
        // No box window (abutting columns): still hunt for a clean jog.
        _ => return scan((a.x + b.x) / 2),
    };
    let centre = snap_near((l + r) / 2, grid);
    let mut edges: Vec<i32> = mid.iter().flat_map(|bx| [bx.min.x, bx.max.x]).collect();
    edges.push(l);
    edges.push(r);
    edges.sort_unstable();
    edges.dedup();
    let mut cands: Vec<i32> = std::iter::once(centre)
        .chain(edges.windows(2).map(|w| snap_near((w[0] + w[1]) / 2, grid)))
        .filter(|&x| l < x && x < r && clear(x))
        .collect();
    cands.sort_unstable();
    cands.dedup();
    cands
        .into_iter()
        .min_by_key(|&x| ((x - centre).abs(), x))
        .or_else(|| scan(centre))
}

/// Find a y-level where a horizontal wire from `a` to `b` clears all intermediate
/// device boxes. Tries both pin y-levels first (so an aligned, unobstructed pair
/// returns its own y), then gaps between boxes, then just outside the extremes.
#[allow(clippy::too_many_arguments)]
fn find_channel_y(
    col_boxes: &[Vec<Rect>],
    lo: usize,
    hi: usize,
    a: Pt,
    b: Pt,
    foreign: &[Pt],
    others: &[(Pt, Pt)],
) -> Option<i32> {
    let xmin = a.x.min(b.x);
    let xmax = a.x.max(b.x);
    let check = |y: i32| -> bool {
        let wire = Rect::from_corners(Pt::new(xmin, y), Pt::new(xmax, y));
        ((lo + 1)..hi).all(|c| !col_boxes[c].iter().any(|bx| wire.intersects(bx)))
            && !seg_hits_pin(foreign, Pt::new(xmin, y), Pt::new(xmax, y))
            && !seg_conflicts(Pt::new(xmin, y), Pt::new(xmax, y), others)
    };
    if check(a.y) {
        return Some(a.y);
    }
    if check(b.y) {
        return Some(b.y);
    }
    // Box edges in intermediate columns bound the candidate y-levels: gap
    // midpoints plus just-outside the extremes, all on the host grid (wires
    // must land on grid like pins do). Among the clear ones, take the one
    // needing the least total riser length (ties → higher on the page).
    let grid = cfg().layout.grid;
    let mut edges: Vec<i32> = Vec::new();
    for boxes in &col_boxes[lo + 1..hi] {
        for bx in boxes {
            edges.push(bx.min.y);
            edges.push(bx.max.y);
        }
    }
    edges.sort_unstable();
    edges.dedup();
    let mut cands: Vec<i32> = edges
        .windows(2)
        .map(|w| snap_near((w[0] + w[1]) / 2, grid))
        .collect();
    if let (Some(&top), Some(&bot)) = (edges.first(), edges.last()) {
        cands.push(-snap_ceil(-(top - 1), grid));
        cands.push(snap_ceil(bot + 1, grid));
    }
    cands.sort_unstable();
    cands.dedup();
    cands
        .into_iter()
        .filter(|&y| y > a.y.min(b.y) - CELL_W && y < a.y.max(b.y) + CELL_W && check(y))
        .min_by_key(|&y| ((a.y - y).abs() + (b.y - y).abs(), y))
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
    debug_assert_eq!(net_segs.len(), ctx.nn());
    for segs in net_segs {
        for s in segs {
            for &p in s {
                wire_pts.push(p);
            }
            seg_pt.push(wire_pts.len() as u32);
            seg_count += 1;
        }
        net_seg.push(seg_count);
    }
    let junctions = compute_junctions(ctx, &pin_xy, net_segs);
    Physical {
        pos,
        pin_xy,
        net_seg,
        seg_pt,
        wire_pts,
        junctions,
        labels,
    }
}

/// A junction dot goes wherever ≥3 wire arms of one net meet.
fn compute_junctions(ctx: &Ctx, pin_xy: &[Pt], net_segs: &[Vec<Vec<Pt>>]) -> Vec<Pt> {
    let mut junctions = Vec::new();
    for (n, segs) in net_segs.iter().enumerate() {
        let mut edges: Vec<(Pt, Pt)> = Vec::new();
        for poly in segs {
            for w in poly.windows(2) {
                if w[0] != w[1] {
                    edges.push((w[0], w[1]));
                }
            }
        }
        if edges.is_empty() {
            continue;
        }
        let pins: Vec<Pt> = ctx
            .members(NetIdx::from_index(n))
            .iter()
            .map(|&p| pin_xy[p.index()])
            .collect();
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
/// Count segment pairs from different nets that conflict: perpendicular interiors
/// crossing, and — worse — parallel segments sharing more than a point (they draw
/// as ONE wire and read as a false connection).
fn count_crossings_and_overlaps(net_segs: &[Vec<Vec<Pt>>]) -> (u32, u32) {
    let mut segs: Vec<(usize, Pt, Pt)> = Vec::new();
    for (ni, polys) in net_segs.iter().enumerate() {
        for poly in polys {
            for w in poly.windows(2) {
                if w[0] != w[1] {
                    segs.push((ni, w[0], w[1]));
                }
            }
        }
    }
    // ponytail: O(n²) pair scan — fine at schematic scale, sweep line if it ever isn't
    let crosses = |a1: Pt, a2: Pt, b1: Pt, b2: Pt| -> bool {
        let (h1, h2, v1, v2) = if a1.y == a2.y {
            (a1, a2, b1, b2)
        } else {
            (b1, b2, a1, a2)
        };
        let (hx0, hx1) = (h1.x.min(h2.x), h1.x.max(h2.x));
        let (vy0, vy1) = (v1.y.min(v2.y), v1.y.max(v2.y));
        hx0 < v1.x && v1.x < hx1 && vy0 < h1.y && h1.y < vy1
    };
    // Collinear with positive-length shared span (touching at one point is fine).
    let overlaps = |a1: Pt, a2: Pt, b1: Pt, b2: Pt| -> bool {
        if a1.y == a2.y && b1.y == b2.y && a1.y == b1.y {
            a1.x.min(a2.x).max(b1.x.min(b2.x)) < a1.x.max(a2.x).min(b1.x.max(b2.x))
        } else if a1.x == a2.x && b1.x == b2.x && a1.x == b1.x {
            a1.y.min(a2.y).max(b1.y.min(b2.y)) < a1.y.max(a2.y).min(b1.y.max(b2.y))
        } else {
            false
        }
    };
    let (mut nc, mut no) = (0u32, 0u32);
    for i in 0..segs.len() {
        for j in (i + 1)..segs.len() {
            let (a, b) = (&segs[i], &segs[j]);
            if a.0 == b.0 {
                continue;
            }
            let (a_h, b_h) = (a.1.y == a.2.y, b.1.y == b.2.y);
            if a_h != b_h {
                nc += crosses(a.1, a.2, b.1, b.2) as u32;
            } else {
                no += overlaps(a.1, a.2, b.1, b.2) as u32;
            }
        }
    }
    (nc, no)
}
