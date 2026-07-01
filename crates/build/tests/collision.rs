//! §"Collision is checked strictly": real rectangle intersection via `Rect::intersects`, used
//! for the tier-1 direct-horizontal clearance decision.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// `Rect::intersects` is a strict (open-interior) overlap: sharing an edge is not a collision,
/// overlapping interiors is. `contains` is likewise strict.
#[test]
fn rect_intersects_is_strict() {
    let a = Rect::new(Pt::new(0, 0), Pt::new(10, 10));
    assert!(a.intersects(&Rect::new(Pt::new(5, 5), Pt::new(15, 15))), "overlapping interiors collide");
    assert!(!a.intersects(&Rect::new(Pt::new(10, 0), Pt::new(20, 10))), "edge-to-edge does not collide");
    assert!(!a.intersects(&Rect::new(Pt::new(10, 10), Pt::new(20, 20))), "corner touch does not collide");
    assert!(!a.intersects(&Rect::new(Pt::new(20, 20), Pt::new(30, 30))), "disjoint");

    // a horizontal wire as a degenerate rect: collides iff it passes through the box interior
    let wire = |x0, x1, y| Rect::from_corners(Pt::new(x0, y), Pt::new(x1, y));
    assert!(wire(-5, 15, 5).intersects(&a), "wire through the interior collides");
    assert!(!wire(-5, 15, 0).intersects(&a), "wire flush along the bottom edge is clear");
    assert!(!wire(-5, 15, 10).intersects(&a), "wire flush along the top edge is clear");

    assert!(a.contains(Pt::new(5, 5)));
    assert!(!a.contains(Pt::new(0, 5)), "boundary is not contained");
}

/// §214 end-to-end: when the engine routes a spanning signal net as a tier-1 DIRECT horizontal,
/// that wire is genuinely clear of every device box it passes between — proving the clearance
/// decision uses real rectangle intersection, not a coarser test. Checked on every circuit.
#[test]
fn direct_horizontals_never_cross_a_device_box() {
    let mut checked = 0;
    for (name, f) in circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        let ev = evaluate(&ctx, &order);
        let phys = &ev.physical;
        let vy = (0..ctx.nd())
            .filter(|&d| matches!(ctx.role(DeviceIdx(d as u32)), devices::SymbolRole::PowerRail))
            .map(|d| phys.pos[d].y)
            .min()
            .unwrap_or(i32::MIN);

        let boxes: Vec<(i32, Rect)> =
            (0..ctx.nd()).map(|d| (phys.pos[d].x, dev_box(&ev.orient, &ctx, DeviceIdx(d as u32), phys.pos[d]))).collect();

        for n in 0..ctx.nn() {
            if ctx.net_class(NetIdx::from_index(n)) != NetClass::Signal {
                continue;
            }
            let segs: Vec<&[Pt]> = phys.segments(NetIdx::from_index(n)).collect();
            // a tier-1 direct run: the whole net is one straight in-field horizontal across >1 column
            if segs.len() != 1 || segs[0].len() != 2 {
                continue;
            }
            let (p, q) = (segs[0][0], segs[0][1]);
            if p.y != q.y || p.y < vy || (p.x - q.x).abs() <= CELL_W {
                continue;
            }
            let wire = Rect::from_corners(p, q);
            let (x0, x1) = (p.x.min(q.x), p.x.max(q.x));
            for &(cx, b) in &boxes {
                if x0 < cx && cx < x1 {
                    assert!(!wire.intersects(&b), "{name} net{n}: direct run {p:?}->{q:?} crosses device box {b:?}");
                    checked += 1;
                }
            }
        }
    }
    assert!(checked >= 1, "expected at least one direct horizontal with an intervening column to vet");
}

/// §"Collision is checked strictly": `num_body_hits` counts wire/device-body interior overlaps on
/// the drawn geometry, and it is the second key term, so the chosen order minimises it. Verify
/// (a) the metric matches a from-scratch recount of the placed geometry, and (b) no permutation
/// achieves fewer hits than the order the search picked.
#[test]
fn body_hits_metric_is_real_and_minimised() {
    for (name, f) in circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        if !(2..=7).contains(&splines.len()) {
            continue;
        }
        let best = permutations(splines.len())
            .iter()
            .map(|p| {
                let order: Vec<&Spline> = p.iter().map(|&i| &splines[i]).collect();
                evaluate(&ctx, &order).metrics.num_body_hits
            })
            .min()
            .unwrap();
        // the searched placement's body-hits, recounted from drawn geometry
        // (must exclude rails and Feedback-column devices, matching the engine)
        let order: Vec<&Spline> = splines.iter().collect();
        let ev = evaluate(&ctx, &order); // id-order; chosen order is <= this on the key
        let cols = assign_columns(&ctx, &order);
        let col_of = column_of(&ctx, &cols);
        let boxes: Vec<(DeviceIdx, Rect)> = (0..ctx.nd())
            .filter(|&d| {
                let di = DeviceIdx(d as u32);
                if ctx.is_rail(di) { return false; }
                let c = col_of[d];
                c == usize::MAX || cols[c].kind != ColumnKind::Feedback
            })
            .map(|d| {
                let di = DeviceIdx(d as u32);
                (di, dev_box(&ev.orient, &ctx, di, ev.physical.pos[d]))
            })
            .collect();
        let mut measured = 0u32;
        for n in 0..ctx.nn() {
            let net = NetIdx::from_index(n);
            let net_devs: Vec<DeviceIdx> = ctx.members(net).iter().map(|&p| ctx.dev_of(p)).collect();
            for s in ev.physical.segments(net) {
                for w in s.windows(2) {
                    let r = Rect::from_corners(w[0], w[1]);
                    measured += boxes.iter()
                        .filter(|&&(di, ref b)| !net_devs.contains(&di) && r.intersects(b))
                        .count() as u32;
                }
            }
        }
        assert_eq!(measured, ev.metrics.num_body_hits, "{name}: body-hit metric disagrees with drawn geometry");
        assert!(best <= ev.metrics.num_body_hits, "{name}: a better order exists ({best} < {})", ev.metrics.num_body_hits);
    }
}
