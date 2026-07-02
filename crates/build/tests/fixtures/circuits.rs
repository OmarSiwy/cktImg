//! The analog primitives of the paper's test suite (§7), parsed from the canonical
//! SPICE fixtures in `tests/fixtures/`. Rail devices (VDD/GND) are auto-inserted for nets
//! named `vdd`/`gnd` since the placer requires them but SPICE netlists don't carry them.

use ir::{Interner, Schematic, Unplaced};

fn from_spice(src: &str, it: &mut Interner) -> Schematic<Unplaced> {
    let mut text = src.to_string();
    // Auto-add rail devices for standard power/ground net names.
    // The SPICE fixtures use these as plain net names; the placer needs
    // explicit rail symbols to anchor spines.
    if src
        .split_whitespace()
        .any(|t| t.eq_ignore_ascii_case("vdd"))
    {
        text.push_str("XVDD vdd vdd\n");
    }
    if src
        .split_whitespace()
        .any(|t| t.eq_ignore_ascii_case("gnd"))
    {
        text.push_str("XGND gnd gnd\n");
    }
    let (sch, _) = netlist::parse(&text, it);
    sch
}

// ---- A. single spline ----

pub fn diode_connected(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/diode_connected.spice"),
        it,
    )
}

pub fn common_source(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/common_source.spice"),
        it,
    )
}

pub fn cs_isource_load(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/cs_isource_load.spice"),
        it,
    )
}

pub fn cascode(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(include_str!("../../../../tests/fixtures/cascode.spice"), it)
}

pub fn source_degenerated(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/source_degenerated.spice"),
        it,
    )
}

// ---- B. two spline / cross-coupled ----

pub fn current_mirror(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/current_mirror.spice"),
        it,
    )
}

pub fn cascode_current_mirror(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/cascode_current_mirror.spice"),
        it,
    )
}

pub fn wilson_mirror(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/wilson_mirror.spice"),
        it,
    )
}

pub fn cross_coupled_pair(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/cross_coupled_pair.spice"),
        it,
    )
}

// ---- C. shared / branching ----

pub fn differential_pair(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/differential_pair.spice"),
        it,
    )
}

pub fn tail_current_source(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/tail_current_source.spice"),
        it,
    )
}

pub fn ota_5t(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(include_str!("../../../../tests/fixtures/ota_5t.spice"), it)
}

pub fn push_pull(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/push_pull.spice"),
        it,
    )
}

// ---- D. multi-stage / feedback ----

pub fn two_stage_miller(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/two_stage_miller.spice"),
        it,
    )
}

pub fn gain_boosted_cascode(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/gain_boosted_cascode.spice"),
        it,
    )
}

pub fn three_stage_nested_miller(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/three_stage_nested_miller.spice"),
        it,
    )
}

pub fn stacked_bias_string(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/stacked_bias_string.spice"),
        it,
    )
}

pub fn folded_cascode(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/folded_cascode.spice"),
        it,
    )
}

pub fn inverter_chain(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/inverter_chain.spice"),
        it,
    )
}

// ---- E. splineless ----

pub fn transmission_gate(it: &mut Interner) -> Schematic<Unplaced> {
    from_spice(
        include_str!("../../../../tests/fixtures/transmission_gate.spice"),
        it,
    )
}

/// A named fixture: the circuit's name and its builder.
pub type Fixture = (&'static str, fn(&mut Interner) -> Schematic<Unplaced>);

/// All circuits, named, in test-suite order.
pub fn all() -> Vec<Fixture> {
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
        ("folded_cascode", folded_cascode),
        ("inverter_chain", inverter_chain),
        ("transmission_gate", transmission_gate),
    ]
}
