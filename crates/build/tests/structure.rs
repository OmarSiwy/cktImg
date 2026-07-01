//! Structural decomposition: spines, columns, net classification, and the splineless case.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// §"Core idea": a circuit decomposes into N spines (VDD→GND conduction paths). The count is a
/// property of the topology, so pin it per circuit — a regression that merges or splits
/// conduction paths changes these numbers.
#[test]
fn splines_decompose_per_topology() {
    let expect: &[(&str, usize)] = &[
        ("diode_connected", 1),
        ("common_source", 1),
        ("cs_isource_load", 1),
        ("cascode", 1),
        ("source_degenerated", 1),
        ("current_mirror", 2),
        ("cascode_current_mirror", 2),
        ("wilson_mirror", 2),
        ("cross_coupled_pair", 2),
        ("differential_pair", 2),
        ("tail_current_source", 3),
        ("push_pull", 1),
        ("stacked_bias_string", 1),
        ("transmission_gate", 0), // no rail → splineless (Break C)
    ];
    for &(name, want) in expect {
        let ir = ir_of(circuit(name));
        let ctx = Ctx::build(&ir);
        assert_eq!(extract_splines(&ctx).len(), want, "{name}: spline count");
    }
}

/// Every Spline/Shared column places its devices on ONE vertical axis (shared x) in strictly
/// increasing y (VDD→GND conduction order). This is the whole point of vertical orientation:
/// stacked conduction pins share an x so the within-spline wire is a straight line.
#[test]
fn spline_columns_are_vertically_stacked() {
    for (name, f) in circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        let cols = assign_columns(&ctx, &order);
        let ev = evaluate(&ctx, &order);
        for col in &cols {
            if !matches!(col.kind, ColumnKind::Spline | ColumnKind::Shared) || col.devices.len() < 2 {
                continue;
            }
            let xs: Vec<i32> = col.devices.iter().map(|&d| ev.physical.pos[d.index()].x).collect();
            assert!(xs.iter().all(|&x| x == xs[0]), "{name}: column not on one axis: {xs:?}");
            let ys: Vec<i32> = col.devices.iter().map(|&d| ev.physical.pos[d.index()].y).collect();
            assert!(
                ys.windows(2).all(|w| w[0] < w[1]),
                "{name}: column not stacked top→bottom in conduction order: {ys:?}"
            );
        }
    }
}

/// §"Classify": a net is WithinSpline (≤1 column), ImmediateNeighbor (adjacent spines,
/// Shared/Component transparent), or SpanGe2 (≥1 Spline column between endpoints).
#[test]
fn classify_partitions_by_column_span() {
    use ColumnKind::*;
    let all_sp = [Spline, Spline, Spline, Spline, Spline, Spline, Spline, Spline];
    assert_eq!(classify(&[], &all_sp), Case::WithinSpline);
    assert_eq!(classify(&[3], &all_sp), Case::WithinSpline);
    assert_eq!(classify(&[1, 2], &all_sp), Case::ImmediateNeighbor);
    // Spline between → SpanGe2
    assert_eq!(classify(&[0, 2], &all_sp), Case::SpanGe2);
    assert_eq!(classify(&[1, 2, 3], &all_sp), Case::SpanGe2, "consecutive but span 2 → staple");
    assert_eq!(classify(&[0, 5], &all_sp), Case::SpanGe2);
    // Only a Shared column between → still ImmediateNeighbor
    let with_shared = [Spline, Shared, Spline];
    assert_eq!(classify(&[0, 2], &with_shared), Case::ImmediateNeighbor, "Shared column is transparent");
}

/// Break C: a rail-less circuit (transmission gate) yields NO splines — devices sharing both
/// conducting nets are grouped into one signal-series column (antiparallel), oriented vertically
/// with opposing gates.
#[test]
fn splineless_circuit_is_signal_series() {
    let ir = ir_of(circuits::transmission_gate);
    let ctx = Ctx::build(&ir);
    assert_eq!(extract_splines(&ctx).len(), 0, "no rails → no splines");

    let cols = assign_columns(&ctx, &[]);
    assert!(!cols.is_empty(), "devices must still be placed");
    assert!(cols.iter().all(|c| c.kind == ColumnKind::SignalSeries), "all columns are signal-series");

    // Antiparallel devices (shared conducting nets) are grouped into one column
    let grouped = cols.iter().filter(|c| c.devices.len() >= 2).count();
    assert!(grouped >= 1, "antiparallel devices should be grouped into one column");

    let ev = evaluate(&ctx, &[]);
    // Grouped antiparallel MOSFETs are oriented vertically with opposing gate sides
    let non_rail: Vec<usize> = (0..ctx.nd())
        .filter(|&d| !ctx.is_rail(DeviceIdx(d as u32)))
        .collect();
    assert!(non_rail.iter().all(|&d| matches!(ev.orient[d].rot(), Rot::R90 | Rot::R270)),
        "antiparallel series devices should be oriented vertically");
    // Gates point in opposite directions
    let rots: Vec<Rot> = non_rail.iter().map(|&d| ev.orient[d].rot()).collect();
    assert!(rots.len() >= 2 && rots[0] != rots[1], "antiparallel gates must point opposite directions");
}

/// §A test table: a CS + current-source load is ONE spline of two stacked devices (load over
/// driver, sharing the output node); both gates are off-spline taps (the load's a bias, the
/// driver's the input). A gain-boosted cascode places deterministically. Named coverage for two
/// fixtures otherwise only swept by `circuits::all()`.
#[test]
fn cs_isource_load_and_gain_boosted_place_as_specified() {
    let ir = ir_of(circuits::cs_isource_load);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    assert_eq!(splines.len(), 1, "CS + current-source load is a single spline");
    assert_eq!(splines[0].len(), 2, "two stacked devices share the output node");

    let a = place(&ir_of(circuits::gain_boosted_cascode));
    let b = place(&ir_of(circuits::gain_boosted_cascode));
    assert!(a.pos == b.pos && a.wire_pts == b.wire_pts, "gain-boosted cascode places deterministically");
}
