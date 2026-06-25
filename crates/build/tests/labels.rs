//! §14 rail fallback: a rail that can't be drawn cleanly as a bus falls back to a lab pin,
//! recorded in `Physical::labels` rather than silently dropped.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// A rail net with nothing to span (a single connection point) cannot form a horizontal bus.
/// §14: it falls back to a lab pin — emitted into `Physical::labels` at that pin, with NO bus
/// segment drawn for the net.
#[test]
fn degenerate_rail_falls_back_to_a_lab_pin() {
    // VDD's net has only the rail symbol on it (nothing else references "vdd").
    let mut it = Interner::default();
    let mut b = IrBuilder::new(&mut it);
    let h = Orientation::H;
    b.device("VDD", sym("vdd"), "", h, &[Some("vdd")]);
    b.device("M1", sym("nmos"), "", h, &[Some("out"), Some("in"), Some("gnd")]);
    b.device("GND", sym("gnd"), "", h, &[Some("gnd")]);
    let ir = b.finish().into_ir();
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);

    let vdd_net = (0..ctx.nn())
        .map(NetIdx::from_index)
        .find(|&n| ctx.net_class(n) == NetClass::Power)
        .expect("a power net");

    assert!(
        phys.labels.iter().any(|l| l.net == vdd_net),
        "an unspannable rail must drop a lab pin, got labels {:?}",
        phys.labels
    );
    assert_eq!(phys.segments(vdd_net).count(), 0, "no bus should be drawn for the lab-pinned rail");
}

/// The healthy circuits never need the fallback: a rail with real connections is drawn as a bus,
/// so no labels are emitted.
#[test]
fn well_connected_rails_emit_no_labels() {
    for (name, f) in circuits::all() {
        let phys = place(&ir_of(f));
        assert!(phys.labels.is_empty(), "{name}: unexpected lab-pin fallback {:?}", phys.labels);
    }
}
