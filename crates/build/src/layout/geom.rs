//! Orthogonal-segment predicates, grid snapping, and oriented device geometry.

use crate::ctx::Ctx;
use ir::{DeviceIdx, Orientation, PinIdx, Pt, Rect};

/// Is `p` on the closed orthogonal segment a–b (endpoints included)?
pub(super) fn on_segment(p: Pt, a: Pt, b: Pt) -> bool {
    p == a || p == b || on_segment_interior(p, a, b)
}

/// Is `p` strictly inside the orthogonal segment a–b (endpoints excluded)?
pub(super) fn on_segment_interior(p: Pt, a: Pt, b: Pt) -> bool {
    if a.y == b.y && p.y == a.y {
        (a.x.min(b.x) < p.x) && (p.x < a.x.max(b.x))
    } else if a.x == b.x && p.x == a.x {
        (a.y.min(b.y) < p.y) && (p.y < a.y.max(b.y))
    } else {
        false
    }
}

/// Does the closed orthogonal segment a–b touch any of `pts`?
pub(super) fn seg_hits_pin(pts: &[Pt], a: Pt, b: Pt) -> bool {
    pts.iter().any(|&p| on_segment(p, a, b))
}

/// Does the segment a–b cross a device body it may not? Each body carries the
/// routed net's own pin points on that device; same rule as the contract
/// guard: crossing an own-net device's box is legal only where the segment
/// contains that device's pin on the net.
pub(super) fn seg_hits_body(bodies: &[(Rect, Vec<Pt>)], a: Pt, b: Pt) -> bool {
    let r = Rect::from_corners(a, b);
    bodies
        .iter()
        .any(|(bx, own)| r.intersects(bx) && !own.iter().any(|&pp| on_segment(pp, a, b)))
}

/// Would drawing a–b short against an already-routed foreign segment? Any
/// endpoint of one lying on the other merges them in a geometric-connectivity
/// host (this also covers every collinear overlap — 1-D interval overlap puts
/// an endpoint inside the other interval). A pure interior crossing is legal.
pub(super) fn seg_conflicts(a: Pt, b: Pt, others: &[(Pt, Pt)]) -> bool {
    others.iter().any(|&(c, d)| {
        on_segment(c, a, b) || on_segment(d, a, b) || on_segment(a, c, d) || on_segment(b, c, d)
    })
}

/// Any segment of the polyline conflicting per [`seg_conflicts`].
pub(super) fn poly_conflicts(pts: &[Pt], others: &[(Pt, Pt)]) -> bool {
    pts.windows(2).any(|w| seg_conflicts(w[0], w[1], others))
}

/// Are a net's wire segments + pins one connected island under touch
/// semantics? (Pins connect only through wires — coincident pins don't merge.)
pub(super) fn one_island(segs: &[(Pt, Pt)], pins: &[Pt]) -> bool {
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

/// Smallest grid multiple ≥ v (identity at grid ≤ 1).
pub(super) fn snap_ceil(v: i32, g: i32) -> i32 {
    if g <= 1 {
        v
    } else {
        (v + g - 1).div_euclid(g) * g
    }
}

/// Nearest grid multiple (identity at grid ≤ 1).
pub(super) fn snap_near(v: i32, g: i32) -> i32 {
    if g <= 1 {
        v
    } else {
        (v + g / 2).div_euclid(g) * g
    }
}

pub(super) fn apply_o(o: Orientation, p: devices::Pt) -> Pt {
    o.apply(Pt::new(p.x, p.y))
}

/// A pin's terminal point in oriented device-local coordinates.
pub(super) fn oriented_term(orient: &[Orientation], ctx: &Ctx, p: PinIdx) -> Pt {
    apply_o(orient[ctx.dev_of(p).index()], ctx.term_at(p))
}

/// A device's bounding box in oriented device-local coordinates.
pub(super) fn oriented_box_rel(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx) -> Rect {
    let bb = ctx.class(d).bbox();
    let o = orient[d.index()];
    // An orthogonal transform maps opposite corners to opposite corners.
    Rect::from_corners(apply_o(o, bb.min), apply_o(o, bb.max))
}

/// A device's bounding box in canvas coordinates.
pub(super) fn dev_box(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx, pos: Pt) -> Rect {
    let r = oriented_box_rel(orient, ctx, d);
    Rect::new(pos + r.min, pos + r.max)
}
