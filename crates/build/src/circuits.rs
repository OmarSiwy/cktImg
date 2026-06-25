//! The eighteen analog primitives of the paper's test suite (§7), built directly as IR via
//! `IrBuilder` — no surface syntax. Each is a `fn(&mut Interner) -> Schematic<Unplaced>`.
//! Netlists are representative of the structure each circuit stresses, not SPICE-exact.

use devices::class_of;
use ir::{Interner, IrBuilder, Orientation, Schematic, SymbolIdx, Unplaced};

fn sym(n: &str) -> SymbolIdx {
    SymbolIdx(class_of(n).expect("known class") as u32)
}
const H: Orientation = Orientation::H;

fn mos(b: &mut IrBuilder, name: &str, kind: &str, d: &str, g: &str, s: &str) {
    b.device(name, sym(kind), name, H, &[Some(d), Some(g), Some(s)]);
}
fn two(b: &mut IrBuilder, name: &str, kind: &str, a: &str, c: &str) {
    b.device(name, sym(kind), name, H, &[Some(a), Some(c)]);
}
fn rail(b: &mut IrBuilder, name: &str, kind: &str, net: &str) {
    b.device(name, sym(kind), name, H, &[Some(net)]);
}

// ---- A. single spline ----

pub fn diode_connected(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RL", "res", "vdd", "out");
    mos(&mut b, "M1", "nmos", "out", "out", "gnd"); // drain→gate feedback stub
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn common_source(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RD", "res", "vdd", "out");
    mos(&mut b, "M1", "nmos", "out", "in", "gnd");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn cs_isource_load(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    mos(&mut b, "M2", "pmos", "out", "vb", "vdd"); // current-source load
    mos(&mut b, "M1", "nmos", "out", "in", "gnd");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn cascode(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    mos(&mut b, "M3", "pmos", "out", "vb1", "vdd");
    mos(&mut b, "M2", "nmos", "out", "vb2", "casc");
    mos(&mut b, "M1", "nmos", "casc", "vin", "gnd");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn source_degenerated(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RD", "res", "vdd", "out");
    mos(&mut b, "M1", "nmos", "out", "in", "s1");
    two(&mut b, "RS", "res", "s1", "gnd"); // series passive in the chain
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

// ---- B. two spline / cross-coupled ----

pub fn current_mirror(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RR", "res", "vdd", "ref");
    mos(&mut b, "M1", "nmos", "ref", "ref", "gnd"); // diode-connected reference
    two(&mut b, "RL", "res", "vdd", "out");
    mos(&mut b, "M2", "nmos", "out", "ref", "gnd"); // mirror
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn cascode_current_mirror(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RR", "res", "vdd", "ref");
    mos(&mut b, "M1c", "nmos", "ref", "cref", "n1"); // cascode-gate bus
    mos(&mut b, "M1", "nmos", "n1", "ref", "gnd"); // lower-gate bus
    two(&mut b, "RL", "res", "vdd", "out");
    mos(&mut b, "M2c", "nmos", "out", "cref", "n2");
    mos(&mut b, "M2", "nmos", "n2", "ref", "gnd");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn wilson_mirror(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RR", "res", "vdd", "ref");
    mos(&mut b, "M1", "nmos", "n1", "n1", "gnd"); // diode
    mos(&mut b, "M2", "nmos", "ref", "n1", "gnd");
    mos(&mut b, "M3", "nmos", "out", "ref", "n1"); // μ>1 feedback
    two(&mut b, "RL", "res", "vdd", "out");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn cross_coupled_pair(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RL1", "res", "vdd", "a");
    two(&mut b, "RL2", "res", "vdd", "bb");
    mos(&mut b, "M1", "nmos", "a", "bb", "gnd"); // gates cross
    mos(&mut b, "M2", "nmos", "bb", "a", "gnd");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

// ---- C. shared / branching ----

pub fn differential_pair(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RL1", "res", "vdd", "n1");
    two(&mut b, "RL2", "res", "vdd", "out1");
    mos(&mut b, "M1", "nmos", "n1", "inp", "tail");
    mos(&mut b, "M2", "nmos", "out1", "inn", "tail");
    mos(&mut b, "M5", "nmos", "tail", "vb", "gnd"); // shared tail node
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn tail_current_source(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RL1", "res", "vdd", "n1");
    two(&mut b, "RL2", "res", "vdd", "n2");
    two(&mut b, "RL3", "res", "vdd", "n3");
    mos(&mut b, "M1", "nmos", "n1", "i1", "tail");
    mos(&mut b, "M2", "nmos", "n2", "i2", "tail");
    mos(&mut b, "M3", "nmos", "n3", "i3", "tail");
    mos(&mut b, "M5", "nmos", "tail", "vb", "gnd"); // one drain feeds N
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn ota_5t(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    mos(&mut b, "M3", "pmos", "n1", "n1", "vdd"); // mirror
    mos(&mut b, "M4", "pmos", "out", "n1", "vdd");
    mos(&mut b, "M1", "nmos", "n1", "inp", "tail"); // diff pair
    mos(&mut b, "M2", "nmos", "out", "inn", "tail");
    mos(&mut b, "M5", "nmos", "tail", "vb", "gnd"); // tail
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn push_pull(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    mos(&mut b, "MP", "pmos", "out", "inp", "vdd");
    mos(&mut b, "MN", "nmos", "out", "inn", "gnd");
    two(&mut b, "RL", "res", "out", "gnd"); // shared out, high fan-out
    two(&mut b, "CL", "cap", "out", "gnd");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

// ---- D. multi-stage / feedback ----

pub fn two_stage_miller(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    mos(&mut b, "M3", "pmos", "n1", "n1", "vdd");
    mos(&mut b, "M1", "nmos", "n1", "inp", "tail");
    mos(&mut b, "M5", "nmos", "tail", "vbias", "gnd");
    mos(&mut b, "M4", "pmos", "out1", "n1", "vdd");
    mos(&mut b, "M2", "nmos", "out1", "inn", "tail");
    mos(&mut b, "M6", "pmos", "out2", "out1", "vdd");
    mos(&mut b, "M7", "nmos", "out2", "vbias", "gnd");
    two(&mut b, "Cc", "cap", "out1", "out2"); // compensation bridge
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn gain_boosted_cascode(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    mos(&mut b, "M3", "pmos", "out", "vb1", "vdd");
    mos(&mut b, "M2", "nmos", "out", "gb", "casc"); // gate driven by aux loop
    mos(&mut b, "M1", "nmos", "casc", "vin", "gnd");
    mos(&mut b, "Ma", "nmos", "gb", "casc", "gnd"); // nested local loop
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn three_stage_nested_miller(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "R1", "res", "vdd", "o1");
    mos(&mut b, "M1", "nmos", "o1", "in", "gnd");
    two(&mut b, "R2", "res", "vdd", "o2");
    mos(&mut b, "M2", "nmos", "o2", "o1", "gnd");
    two(&mut b, "R3", "res", "vdd", "out");
    mos(&mut b, "M3", "nmos", "out", "o2", "gnd");
    two(&mut b, "Cc1", "cap", "o1", "out"); // outer
    two(&mut b, "Cc2", "cap", "o2", "out"); // inner — spans a stage
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

pub fn stacked_bias_string(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    rail(&mut b, "VDD", "vdd", "vdd");
    two(&mut b, "RT", "res", "vdd", "n1");
    mos(&mut b, "M1", "nmos", "n1", "n1", "n2"); // diode string with taps
    mos(&mut b, "M2", "nmos", "n2", "n2", "n3");
    mos(&mut b, "M3", "nmos", "n3", "n3", "gnd");
    rail(&mut b, "GND", "gnd", "gnd");
    b.finish()
}

// ---- E. splineless ----

pub fn transmission_gate(it: &mut Interner) -> Schematic<Unplaced> {
    let mut b = IrBuilder::new(it);
    // no rail: signal-series only (Break C)
    mos(&mut b, "MN", "nmos", "a", "ctl", "bb");
    mos(&mut b, "MP", "pmos", "a", "ctlb", "bb");
    b.finish()
}

/// All eighteen circuits, named, in test-suite order.
pub fn all() -> Vec<(&'static str, fn(&mut Interner) -> Schematic<Unplaced>)> {
    vec![
        ("diode_connected", diode_connected),
        ("common_source", common_source),
        ("cs_isource_load", cs_isource_load),
        ("cascode", cascode),
        ("source_degenerated", source_degenerated),
        ("current_mirror", current_mirror),
        ("cascode_current_mirror", cascode_current_mirror),
        ("wilson_mirror", wilson_mirror),
        ("cross_coupled_pair", cross_coupled_pair),
        ("differential_pair", differential_pair),
        ("tail_current_source", tail_current_source),
        ("ota_5t", ota_5t),
        ("push_pull", push_pull),
        ("two_stage_miller", two_stage_miller),
        ("gain_boosted_cascode", gain_boosted_cascode),
        ("three_stage_nested_miller", three_stage_nested_miller),
        ("stacked_bias_string", stacked_bias_string),
        ("transmission_gate", transmission_gate),
    ]
}
