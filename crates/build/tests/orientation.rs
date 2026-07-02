//! Device orientation: gate side, vertical placement written back, passives left horizontal.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// §"Device orientation": a gate points LEFT iff its net is driven from a column to the left,
/// otherwise RIGHT (toward the next spine). Check the rule holds for every MOS in a mirror —
/// the diode reference's gate points right, the mirror device's gate points left toward it.
#[test]
fn gate_points_toward_its_driving_spline() {
    let ir = ir_of(circuits::current_mirror);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let col_of = column_of(&ctx, &cols);
    let ev = evaluate(&ctx, &order);

    let mut checked = 0;
    for d in 0..ctx.nd() {
        let di = DeviceIdx(d as u32);
        let my_col = col_of[d];
        if my_col == usize::MAX {
            continue;
        }
        let Some(gate) = ctx.pins(di).find(|&p| ctx.role_of(p).is_control()) else {
            continue;
        };
        let Some(net) = ctx.net_of(gate) else {
            continue;
        };
        let from_left = ctx
            .members(net)
            .iter()
            .any(|&q| matches!(col_of[ctx.dev_of(q).index()], c if c != usize::MAX && c < my_col));
        let body_x = ev.physical.pos[d].x;
        let gate_x = ev.physical.pin_xy[gate.index()].x;
        if from_left {
            assert!(
                gate_x < body_x,
                "dev{d}: gate driven from left must point left ({gate_x} !< {body_x})"
            );
        } else {
            assert!(
                gate_x > body_x,
                "dev{d}: gate not from left must point right ({gate_x} !> {body_x})"
            );
        }
        checked += 1;
    }
    assert!(checked >= 2, "expected to check both mirror devices");
}

/// The placer SETS each spline device's orientation (vertical) and writes it back into the IR
/// so the renderer draws bodies as placed; rails stay horizontal.
#[test]
fn layout_writes_vertical_orientation_back() {
    let mut it = Interner::default();
    let sch = circuits::differential_pair(&mut it);
    let placed = layout(sch);
    let ir = placed.ir();
    let ctx = Ctx::build(ir);

    let mut spline_devs = 0;
    for d in 0..ir.devices.len() {
        let di = DeviceIdx(d as u32);
        let rot = ir.devices.orient[d].rot();
        let is_mos = ctx.pins(di).any(|p| ctx.role_of(p).is_control());
        if ctx.is_rail(di) {
            assert_eq!(rot, Rot::R0, "rails stay horizontal");
        } else if is_mos {
            assert!(
                matches!(rot, Rot::R90 | Rot::R270),
                "spline MOS dev{d} must be vertical, got {rot:?}"
            );
            spline_devs += 1;
        }
    }
    assert!(
        spline_devs >= 3,
        "diff pair has ≥3 transistors placed vertically"
    );
}

/// Passive bridge/series devices stay HORIZONTAL; active satellites (MOSFETs in Component
/// columns) are oriented vertically like spline devices.
#[test]
fn bridge_and_series_devices_stay_horizontal() {
    let mut passive_checked = 0;
    let mut active_checked = 0;
    for (name, f) in circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        let cols = assign_columns(&ctx, &order);
        let ev = evaluate(&ctx, &order);
        for c in &cols {
            if !matches!(c.kind, ColumnKind::Component | ColumnKind::SignalSeries) {
                continue;
            }
            // An antiparallel pass group (transmission gate) has no rail feeding it:
            // its devices lie flat regardless of gates.
            let pass_group = c.kind == ColumnKind::SignalSeries && c.devices.len() >= 2;
            for &d in &c.devices {
                // Gated (active) devices carry spine current → vertical; passives
                // and pass groups stay flat.
                let has_gate = ctx.pins(d).any(|p| ctx.role_of(p).is_control());
                if has_gate && !pass_group {
                    assert!(
                        matches!(ev.orient[d.index()].rot(), Rot::R90 | Rot::R270),
                        "{name}: active {:?} dev should be vertical, got {:?}",
                        c.kind,
                        ev.orient[d.index()].rot()
                    );
                    active_checked += 1;
                } else {
                    // A passive bridge stands VERTICAL iff exactly one of its nets
                    // spans (routes in a channel above); otherwise it lies flat.
                    let col_of = column_of(&ctx, &cols);
                    let col_kinds: Vec<ColumnKind> = cols.iter().map(|c| c.kind).collect();
                    let spans = |p: ir::PinIdx| -> bool {
                        ctx.net_of(p).is_some_and(|net| {
                            let cs: Vec<usize> = net_columns(&ctx, net, &col_of)
                                .into_iter()
                                .filter(|&c| cols[c].in_field())
                                .collect();
                            !cs.is_empty() && classify(&cs, &col_kinds) == Case::SpanGe2
                        })
                    };
                    let cps = ctx.conducting_pins(d);
                    let vertical = c.kind == ColumnKind::Component
                        && cps.len() == 2
                        && (spans(cps[0]) != spans(cps[1]));
                    let rot = ev.orient[d.index()].rot();
                    if vertical {
                        assert!(
                            matches!(rot, Rot::R90 | Rot::R270),
                            "{name}: bridge with one spanning net should be vertical, got {rot:?}"
                        );
                    } else {
                        assert!(
                            matches!(rot, Rot::R0 | Rot::R180),
                            "{name}: {:?} dev not horizontal",
                            c.kind
                        );
                    }
                    passive_checked += 1;
                }
            }
        }
    }
    assert!(
        passive_checked >= 4,
        "expected passive Component/SignalSeries devices across the suite"
    );
    assert!(
        active_checked >= 1,
        "expected at least one active satellite (gain_boosted_cascode)"
    );
}
