//! Phase 5 — per-net Manhattan routing: buses, staples, column wiring.

use super::CELL_W;
use super::geom::{
    on_segment, on_segment_interior, poly_conflicts, seg_conflicts, seg_hits_body, seg_hits_pin,
    snap_ceil, snap_near,
};
use crate::ctx::Ctx;
use crate::extract::Case;
use config::cfg;
use ir::{Label, NetIdx, PinIdx, Pt, Rect};

/// Clearance of a side-channel detour beyond the widest body it passes.
const SIDE_CLEAR: i32 = 6;

/// Per-net routing facts computed once after column assignment.
pub(super) struct NetInfo {
    pub(super) net: NetIdx,
    pub(super) cols: Vec<usize>,
    pub(super) case: Case,
    /// One representative pin per column (control pins preferred).
    pub(super) rep: Vec<(usize, PinIdx)>,
    pub(super) shared_hub: Option<PinIdx>,
    pub(super) backward: bool,
}

impl NetInfo {
    pub(super) fn rep_in(&self, col: usize) -> Option<PinIdx> {
        self.rep.iter().find(|&&(c, _)| c == col).map(|&(_, p)| p)
    }
}

/// Read-only state the per-net router needs.
pub(super) struct RouteCtx<'a> {
    pub(super) ctx: &'a Ctx<'a>,
    pub(super) pin_xy: &'a [Pt],
    pub(super) chosen_h: &'a [Option<NetIdx>],
    pub(super) track_of: &'a [Option<u32>],
    pub(super) riser_x: &'a [Option<(i32, i32)>],
    pub(super) col_boxes: &'a [Vec<Rect>],
    pub(super) col_of: &'a [usize],
    pub(super) top_margin: i32,
    /// Every placed non-rail pin with its net — foreign-pin obstacles.
    pub(super) pin_pts: &'a [(NetIdx, Pt)],
}

impl RouteCtx<'_> {
    pub(super) fn pin_at(&self, p: PinIdx) -> Pt {
        self.pin_xy[p.index()]
    }

    /// Pin points of every net but `net`. A wire may not touch these at all:
    /// geometric-connectivity hosts merge a pin with any wire through its
    /// point, so even grazing one is a short.
    pub(super) fn foreign_pins(&self, net: NetIdx) -> Vec<Pt> {
        self.pin_pts
            .iter()
            .filter(|&&(n, _)| n != net)
            .map(|&(_, p)| p)
            .collect()
    }
}

/// Everything an in-flight route must not touch. Empty lists (non-strict mode)
/// make every predicate degenerate to the pre-host routing exactly.
pub(super) struct Obstacles<'a> {
    /// Foreign nets' pin points.
    pub(super) foreign: &'a [Pt],
    /// Already-routed foreign wire segments.
    pub(super) others: &'a [(Pt, Pt)],
    /// Device bodies, each with the routed net's own pin points on that device.
    pub(super) bodies: &'a [(Rect, Vec<Pt>)],
}

impl Obstacles<'_> {
    /// The contract predicate: a segment is dirty if it touches a foreign pin,
    /// an already-routed foreign wire, or a device body away from that
    /// device's own pin on this net.
    pub(super) fn seg_dirty(&self, a: Pt, b: Pt) -> bool {
        a != b
            && (seg_hits_pin(self.foreign, a, b)
                || seg_conflicts(a, b, self.others)
                || seg_hits_body(self.bodies, a, b))
    }
}

/// Label every (non-rail) pin of a net — the label fallback must cover the
/// WHOLE net: a geometric host connects by name only where a label touches,
/// so any unlabelled pin would dangle.
pub(super) fn label_net_pins(ctx: &Ctx, net: NetIdx, pin_xy: &[Pt], labels: &mut Vec<Label>) {
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

/// Horizontal bus at `bus_y` with vertical drops from each pin. A drop that
/// would pass through a foreign pin, wire, or device body jogs sideways by
/// whole tracks (both sides tried; a hit everywhere stays straight and
/// surfaces as a pin-hit / geom-short / body metric).
pub(super) fn route_bus_at(pts: &[Pt], bus_y: i32, obs: &Obstacles, out: &mut Vec<Vec<Pt>>) {
    if pts.len() < 2 {
        return;
    }
    let mut drops: Vec<Vec<Pt>> = Vec::new();
    let mut bus_xs: Vec<i32> = pts.iter().map(|p| p.x).collect();
    for p in pts {
        if p.y == bus_y {
            continue;
        }
        let poly = jogged_drop(*p, bus_y, obs);
        bus_xs.push(poly.last().unwrap().x);
        drops.push(poly);
    }
    // Trunk spans every landing point (a jogged drop may fall past a pin x).
    let minx = bus_xs.iter().copied().min().unwrap();
    let maxx = bus_xs.iter().copied().max().unwrap();
    out.push(vec![Pt::new(minx, bus_y), Pt::new(maxx, bus_y)]);
    out.extend(drops);
}

/// Trunk for a shared-hub net: the hub row when its whole geometry passes the
/// contract predicate, else the nearest clean row within ±6 tracks — ALL
/// below-rows before any above-row (a diff pair's tail trunk belongs BELOW the
/// transistors, meeting the current source's pin; only when nothing below is
/// clean may the trunk go over the top). Nothing clean at all keeps the hub
/// row — the guard labels it.
pub(super) fn route_hub_trunk(pts: &[Pt], hub_y: i32, obs: &Obstacles, out: &mut Vec<Vec<Pt>>) {
    let th = cfg().layout.track_h;
    let rows = std::iter::once(hub_y)
        .chain((1..=6).map(|k| hub_y + k * th))
        .chain((1..=6).map(|k| hub_y - k * th));
    for y in rows {
        let mut cand: Vec<Vec<Pt>> = Vec::new();
        route_bus_at(pts, y, obs, &mut cand);
        if cand
            .iter()
            .all(|poly| poly.windows(2).all(|w| !obs.seg_dirty(w[0], w[1])))
        {
            out.append(&mut cand);
            return;
        }
    }
    route_bus_at(pts, hub_y, obs, out);
}

/// Hook margin-resident pins (feedback devices, hanging sources) into the
/// net's wiring. Strict mode additionally falls back to the nearest same-net
/// pin (geometric hosts have no by-name nets: an unwired pin is a dangle) and
/// skips pins already touching the wiring.
pub(super) fn hook_margin_pins(
    ctx: &Ctx,
    net: NetIdx,
    pins: &[PinIdx],
    pin_xy: &[Pt],
    obs: &Obstacles,
    segs: &mut Vec<Vec<Pt>>,
) {
    let strict = cfg().layout.strict_geometry;
    for &p in pins {
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
            !obs.seg_dirty(at, mid) && !obs.seg_dirty(mid, q)
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
                ctx.members(net)
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
}

/// Vertical drop from `p` to `to_y`, jogging sideways by whole tracks when
/// the straight drop touches a foreign pin, an already-routed foreign wire,
/// or a device body (own-net bodies allowed only through their pin — see
/// [`seg_hits_body`]). No clear lane within a few tracks stays straight and
/// surfaces as a metric.
fn jogged_drop(p: Pt, to_y: i32, obs: &Obstacles) -> Vec<Pt> {
    // The pin itself sits on the drop; exclude it from the pin test.
    let hits = |a: Pt, b: Pt| obs.foreign.iter().any(|&q| q != p && on_segment(q, a, b));
    let dirty = |poly: &[Pt]| {
        poly.windows(2).any(|w| {
            hits(w[0], w[1])
                || seg_conflicts(w[0], w[1], obs.others)
                || seg_hits_body(obs.bodies, w[0], w[1])
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
pub(super) fn route_net(
    rc: &RouteCtx,
    inf: &NetInfo,
    obs: &Obstacles,
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
            wire_column_pins(&ps, &rc.col_boxes[col], obs, out);
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
                        && !seg_hits_pin(obs.foreign, p, q)
                        && !seg_conflicts(p, q, obs.others)
                };
                let mut run = None;
                if is_chosen && a.y == b.y && run_clear(a.y) {
                    out.push(vec![a, b]);
                    run = Some((a.y, snap_near((a.x + b.x) / 2, cfg().layout.grid)));
                } else if let Some(mx) = channel_mx(rc.col_boxes, lo, hi, a, b, obs) {
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
                let channel = find_channel_y(rc.col_boxes, lo, hi, a, b, obs);
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
                            out.push(jogged_drop(q, run_y, obs));
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
            wire_column_pins(&ps, &rc.col_boxes[c], obs, out);
        }
    }
}

/// Wire multiple pins in the same column: gather off-axis pins onto the dominant
/// axis, then run the axis spine — every segment is collision-checked and detours
/// through a side channel wherever a device body blocks the direct path.
fn wire_column_pins(pins: &[(Pt, bool)], boxes: &[Rect], obs: &Obstacles, out: &mut Vec<Vec<Pt>>) {
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
            || seg_hits_pin(obs.foreign, Pt::new(x, lo), Pt::new(x, hi))
            || seg_conflicts(Pt::new(x, lo), Pt::new(x, hi), obs.others)
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
        pts.windows(2)
            .any(|w| seg_hits_pin(obs.foreign, w[0], w[1]))
            || poly_conflicts(pts, obs.others)
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
    v_ys.sort_unstable();
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
fn channel_mx(
    col_boxes: &[Vec<Rect>],
    lo: usize,
    hi: usize,
    a: Pt,
    b: Pt,
    obs: &Obstacles,
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
                && !seg_hits_pin(obs.foreign, p, q)
                && !seg_conflicts(p, q, obs.others)
                && !seg_hits_body(obs.bodies, p, q)
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
fn find_channel_y(
    col_boxes: &[Vec<Rect>],
    lo: usize,
    hi: usize,
    a: Pt,
    b: Pt,
    obs: &Obstacles,
) -> Option<i32> {
    let xmin = a.x.min(b.x);
    let xmax = a.x.max(b.x);
    let check = |y: i32| -> bool {
        let wire = Rect::from_corners(Pt::new(xmin, y), Pt::new(xmax, y));
        ((lo + 1)..hi).all(|c| !col_boxes[c].iter().any(|bx| wire.intersects(bx)))
            && !seg_hits_pin(obs.foreign, Pt::new(xmin, y), Pt::new(xmax, y))
            && !seg_conflicts(Pt::new(xmin, y), Pt::new(xmax, y), obs.others)
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
