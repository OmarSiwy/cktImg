//! Phases 6–7 — strict-mode closure passes, violation metrics, and packing
//! the routed geometry into a [`Physical`].

use super::geom::{dev_box, on_segment, on_segment_interior, one_island};
use super::route::label_net_pins;
use crate::ctx::Ctx;
use crate::extract::Column;
use config::cfg;
use ir::{DeviceIdx, Label, NetIdx, Orientation, Physical, Pt, Rect};

/// Flatten every net's polylines to non-degenerate `(net, a, b)` segments.
fn flat_segs(net_segs: &[Vec<Vec<Pt>>]) -> Vec<(usize, Pt, Pt)> {
    let mut segs = Vec::new();
    for (n, polys) in net_segs.iter().enumerate() {
        for poly in polys {
            for w in poly.windows(2) {
                if w[0] != w[1] {
                    segs.push((n, w[0], w[1]));
                }
            }
        }
    }
    segs
}

/// Pin-coverage closure (strict hosts only): after all routing, every pin
/// of every net must sit on its net's own wiring or carry a label — a
/// geometric host resolves connectivity by touch, so anything less is a
/// dangle. A net that misses ANY pin is stripped and fully labelled.
/// (Also covers geometry-less nets: single-pin nets left by a skipped
/// master, pins living entirely in the margins.)
pub(super) fn enforce_pin_coverage(
    ctx: &Ctx,
    pin_xy: &[Pt],
    net_segs: &mut [Vec<Vec<Pt>>],
    labels: &mut Vec<Label>,
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
) {
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
            label_net_pins(ctx, net, pin_xy, labels);
            if labels.len() > before {
                fallbacks.push((net, "wiring misses a pin — lab pins instead"));
            }
        }
    }
}

/// Crossing budget: dense fields read badly and hosts lint them
/// (Schemify Q4: crossings ≤ max(10, wires/4)). Strip the net with
/// the most different-net crossings to labels until under budget —
/// labels remove crossings without touching correctness.
pub(super) fn enforce_crossing_budget(
    ctx: &Ctx,
    pin_xy: &[Pt],
    net_segs: &mut [Vec<Vec<Pt>>],
    labels: &mut Vec<Label>,
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
) {
    loop {
        let segs_flat = flat_segs(net_segs);
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
        label_net_pins(ctx, net, pin_xy, labels);
        fallbacks.push((net, "crossing budget exceeded — busiest net labelled"));
    }
}

/// Count wire segments crossing field device bodies — rails and margin-resident
/// feedback devices are excluded; wires near them are expected. Boxes of devices
/// that have a pin on the same net are also excluded (a wire arriving at its own
/// device terminal is not a crossing).
pub(super) fn count_body_hits(
    ctx: &Ctx,
    orient: &[Orientation],
    cols: &[Column],
    col_of: &[usize],
    pos: &[Pt],
    net_segs: &[Vec<Vec<Pt>>],
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
) -> u32 {
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
            (di, dev_box(orient, ctx, di, pos[d]))
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
    num_body_hits
}

/// Foreign-pin hits (strict only): any wire touching another net's pin point
/// (a short in geometric-connectivity hosts).
pub(super) fn count_pin_hits(
    net_segs: &[Vec<Vec<Pt>>],
    pin_pts: &[(NetIdx, Pt)],
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
) -> u32 {
    if !cfg().layout.strict_geometry {
        return 0;
    }
    let mut num_pin_hits = 0u32;
    for (n, segs) in net_segs.iter().enumerate() {
        let net = NetIdx::from_index(n);
        let mut hit = false;
        for poly in segs {
            for w in poly.windows(2) {
                for &(pn, pp) in pin_pts {
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
    num_pin_hits
}

/// Geometric T-shorts (strict only): a wire vertex of one net landing on
/// another net's wire. Downstream each straight run is one wire, so EVERY
/// vertex is a wire endpoint and merges with whatever it touches.
pub(super) fn count_geom_shorts(
    net_segs: &[Vec<Vec<Pt>>],
    fallbacks: &mut Vec<(NetIdx, &'static str)>,
) -> u32 {
    if !cfg().layout.strict_geometry {
        return 0;
    }
    let mut num_geom_shorts = 0u32;
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
    num_geom_shorts
}

/// Pack routed polylines into the CSR arrays of a [`Physical`].
pub(super) fn build_physical(
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
            wire_pts.extend_from_slice(s);
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

/// Count segment pairs from different nets that conflict: perpendicular interiors
/// crossing, and — worse — parallel segments sharing more than a point (they draw
/// as ONE wire and read as a false connection).
pub(super) fn count_crossings_and_overlaps(net_segs: &[Vec<Vec<Pt>>]) -> (u32, u32) {
    let segs = flat_segs(net_segs);
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
