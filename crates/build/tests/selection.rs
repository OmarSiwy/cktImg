//! Column-order selection (§6): determinism, crossing-minimal choice, the crossing metric,
//! and the beyond-enumeration-limit fallback.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// The pipeline is deterministic by construction: identical input → byte-identical placement.
#[test]
fn placement_is_deterministic() {
    for (name, f) in circuits::all() {
        let a = place(&ir_of(f));
        let b = place(&ir_of(f));
        assert!(a.pos == b.pos, "{name}: device positions not reproducible");
        assert!(a.pin_xy == b.pin_xy, "{name}: pin coordinates not reproducible");
        assert!(a.wire_pts == b.wire_pts, "{name}: wiring not reproducible");
    }
}

/// §6 selection key: net labels and body-crossings (higher priority) come first, then crossings.
/// So the chosen order must achieve the MINIMUM crossing count *among the orders that already
/// minimise (labels, body-hits)* — measured on the actual drawn geometry, over every permutation.
#[test]
fn selection_minimises_crossings() {
    for (name, f) in circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        if !(2..=10).contains(&splines.len()) {
            continue; // single-spline or beyond the enumeration limit
        }
        let metas: Vec<_> = permutations(splines.len())
            .iter()
            .map(|p| {
                let order: Vec<&Spline> = p.iter().map(|&i| &splines[i]).collect();
                evaluate(&ctx, &order).metrics
            })
            .collect();
        // the higher-priority key prefix the search minimises before it ever weighs crossings
        let min_pre = metas.iter().map(|m| (m.num_labels, m.num_body_hits, m.num_staples, m.total_span)).min().unwrap();
        let best = metas
            .iter()
            .filter(|m| (m.num_labels, m.num_body_hits, m.num_staples, m.total_span) == min_pre)
            .map(|m| m.num_crossings)
            .min()
            .unwrap();
        let got = measured_crossings(&place(&ir));
        assert_eq!(got, best, "{name}: placed {got} crossings but {best} were achievable at min (labels,body-hits)");
    }
}

/// §"Routing primitives": the crossing metric must reflect actually-drawn geometry. A single
/// uncrossed spine produces none. Exhaustive crossing validation is in selection_minimises_crossings.
#[test]
fn crossing_metric_tracks_real_crossings() {
    let crossings = |f: Build| {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        evaluate(&ctx, &order).metrics.num_crossings
    };
    assert_eq!(crossings(circuits::cascode), 0, "a single uncrossed cascode spine has no crossings");
    assert_eq!(crossings(circuits::common_source), 0, "a single spine with a resistor load has no crossings");
}

/// §best_order: above enum_limit (10) splines the placer uses a greedy nearest-neighbor
/// heuristic instead of exhaustive search. An 11-branch circuit must still place every device,
/// with all eleven columns, deterministically.
#[test]
fn circuits_beyond_enum_limit_still_place() {
    let mk = || {
        let mut it = Interner::default();
        let mut b = IrBuilder::new(&mut it);
        let h = Orientation::H;
        b.device("VDD", sym("vdd"), "", h, &[Some("vdd")]);
        for i in 0..11 {
            b.device(&format!("R{i}"), sym("res"), "", h, &[Some("vdd"), Some(&format!("n{i}"))]);
            b.device(&format!("M{i}"), sym("nmos"), "", h, &[Some(&format!("n{i}")), Some(&format!("g{i}")), Some("gnd")]);
        }
        b.device("GND", sym("gnd"), "", h, &[Some("gnd")]);
        b.finish().into_ir()
    };
    let ir = mk();
    let ctx = Ctx::build(&ir);
    assert_eq!(extract_splines(&ctx).len(), 11, "eleven branches → eleven splines");
    let a = place(&ir);
    assert_eq!(a.pos.len(), ctx.nd(), "every device placed");
    assert_eq!(a.pin_xy.len(), ir.pins.len(), "every pin placed");
    let b = place(&mk());
    assert!(a.pos == b.pos && a.wire_pts == b.wire_pts, "greedy heuristic is deterministic");
}
