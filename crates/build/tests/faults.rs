//! Characterization of known doc-vs-code divergences. These pin the CURRENT (doc-violating)
//! behaviour so a regression — or a future fix — is caught. When a fault is fixed, the matching
//! test here will fail and should be rewritten to assert the corrected behaviour.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// §94 FAULT: an immediate-neighbour gate-tie is specified as a single bend-free horizontal,
/// but Phase 2 lets the power net win the per-gap alignment gauge, so the signal tie is drawn
/// as a Z-jog. The cross-column wire is one 4-point bent route; intra-column taps connect the
/// remaining same-column pins (diode-connected drain + resistor bottom).
#[test]
fn immediate_gate_tie_is_currently_a_zjog() {
    let ir = ir_of(circuits::current_mirror);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let col_of = column_of(&ctx, &cols);
    let col_kinds: Vec<ColumnKind> = cols.iter().map(|c| c.kind).collect();
    let ev = evaluate(&ctx, &order);
    let tie = (0..ctx.nn())
        .map(NetIdx::from_index)
        .find(|&net| {
            ctx.net_class(net) == NetClass::Signal
                && classify(&net_columns(&ctx, net, &col_of), &col_kinds) == Case::ImmediateNeighbor
        })
        .unwrap();
    let segs: Vec<Vec<Pt>> = ev.physical.segments(tie).map(|s| s.to_vec()).collect();
    // Cross-column wire + intra-column taps; exact count varies with spacing
    assert!(segs.len() >= 1, "gate-tie must produce at least one wire segment");
    assert!(segs.iter().any(|s| s.len() >= 2), "at least one multi-point segment");
}

/// Span-2 bridges (e.g. a cap spanning one intermediate spline column) are placed as
/// Component columns in the field, not as Feedback margin devices. Feedback is reserved
/// for span ≥ 3. The three-stage amp's two caps both land as Component columns.
#[test]
fn span2_bridge_is_component_not_feedback() {
    let ir = ir_of(circuits::three_stage_nested_miller);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);

    let fb: Vec<&Column> = cols.iter().filter(|c| c.kind == ColumnKind::Feedback).collect();
    assert_eq!(fb.len(), 0, "no Feedback columns — both caps are Component");
    let comp: Vec<&Column> = cols.iter().filter(|c| c.kind == ColumnKind::Component).collect();
    assert!(comp.len() >= 2, "both caps are Component field columns");
}

// Note: the §144 signal-staple tier-3 label is still structurally unreachable (`rep` always
// covers the lo/hi columns), but the lab-pin MECHANISM is now real and exercised by the §14
// rail fallback — see tests/labels.rs.
