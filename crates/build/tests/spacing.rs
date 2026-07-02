//! §"Wire length (spacing between devices)": vertical tap room and horizontal channel width.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// §"Wire length": optimallen = degree − in_spline − 1. The −1 subtracts the conduction
/// link between the two stacked neighbors (that's the stacking itself). One external tap
/// cancels the −1, so optimallen stays 0 (abut). Two external taps add one TAP_UNIT.
#[test]
fn optimallen_adds_tap_room_per_external_connection() {
    let mk = |taps: usize| {
        let mut it = Interner::default();
        let mut b = IrBuilder::new(&mut it);
        let h = Orientation::H;
        b.device("VDD", sym("vdd"), "", h, &[Some("vdd")]);
        b.device(
            "Ma",
            sym("nmos"),
            "",
            h,
            &[Some("vdd"), Some("ga"), Some("mid")],
        );
        b.device(
            "Mb",
            sym("nmos"),
            "",
            h,
            &[Some("mid"), Some("gb"), Some("gnd")],
        );
        for i in 0..taps {
            b.device(
                &format!("M{i}"),
                sym("nmos"),
                "",
                h,
                &[Some("vdd"), Some("mid"), Some("gnd")],
            );
        }
        b.device("GND", sym("gnd"), "", h, &[Some("gnd")]);
        let phys = place(&b.finish().into_ir());
        phys.pos[2].y - phys.pos[1].y // gap between Ma and Mb
    };
    let abut = mk(0); // degree=2, in=2, optimal = 2-2-1 = 0 → abut
    let one_tap = mk(1); // degree=3, in=2, optimal = 3-2-1 = 0 → still abut
    let two_taps = mk(2); // degree=4, in=2, optimal = 4-2-1 = 1 → +TAP_UNIT
    assert!(abut > 0, "stacked devices still need their own extents");
    assert_eq!(
        one_tap, abut,
        "one external tap → the −1 cancels it, still abut"
    );
    assert_eq!(
        two_taps - abut,
        12,
        "two external taps add exactly one TAP_UNIT of room"
    );
}

/// §210: channel width is the room actually reserved in a gap — `TRACK_W` (one wire gauge) per
/// wire/riser crossing it — with NO fixed base constant. The only floor is one gauge, the
/// physical minimum for a stub to run a vertical line. So every column-to-column gap is a
/// positive multiple of `TRACK_W` on top of the cell width, and never less than one gauge.
#[test]
fn channel_width_is_reserved_gauges_with_no_base() {
    let mut saw_gap = false;
    for (name, f) in circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        let cols = assign_columns(&ctx, &order);
        let ev = evaluate(&ctx, &order);
        let mut xs: Vec<i32> = cols
            .iter()
            .filter(|c| !c.devices.is_empty() && c.kind != ColumnKind::Feedback) // Feedback lives in the margin, no channel
            .map(|c| ev.physical.pos[c.devices[0].index()].x)
            .collect();
        xs.sort_unstable();
        xs.dedup();
        for w in xs.windows(2) {
            let gap = w[1] - w[0] - CELL_W; // channel beyond the cell bodies
            saw_gap = true;
            assert!(
                gap >= TRACK_W,
                "{name}: gap channel {gap} below the one-gauge floor"
            );
            assert_eq!(
                gap % TRACK_W,
                0,
                "{name}: gap channel {gap} not a whole number of gauges"
            );
        }
    }
    assert!(saw_gap, "expected multi-column circuits");
}
