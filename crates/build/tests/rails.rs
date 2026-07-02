//! Power rails: VDD on top, GND on bottom, each drawn once as a horizontal bus.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// §"Power rails": VDD spans the top, GND the bottom — every FIELD device sits strictly between
/// them. Feedback bridge devices are margin residents (in the backward-route band above VDD), so
/// they are excluded — see §"Device inside a feedback loop".
#[test]
fn power_on_top_ground_on_bottom() {
    for (name, f) in circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let has_pwr = (0..ctx.nd()).any(|d| {
            matches!(
                ctx.role(DeviceIdx(d as u32)),
                devices::SymbolRole::PowerRail
            )
        });
        let has_gnd = (0..ctx.nd()).any(|d| {
            matches!(
                ctx.role(DeviceIdx(d as u32)),
                devices::SymbolRole::GroundRail
            )
        });
        if !(has_pwr && has_gnd) {
            continue; // splineless circuits (no rails)
        }
        // place via the same order we inspect, so we can exclude margin-resident Feedback devices
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        let cols = assign_columns(&ctx, &order);
        let phys = &evaluate(&ctx, &order).physical;
        let margin: std::collections::HashSet<u32> = cols
            .iter()
            .filter(|c| c.kind == ColumnKind::Feedback)
            .flat_map(|c| c.devices.iter().map(|d| d.0))
            .collect();
        let (mut top, mut bot) = (i32::MAX, i32::MIN);
        let (mut dmin, mut dmax) = (i32::MAX, i32::MIN);
        for d in 0..ctx.nd() {
            let di = DeviceIdx(d as u32);
            match ctx.role(di) {
                devices::SymbolRole::PowerRail => top = top.min(phys.pos[d].y),
                devices::SymbolRole::GroundRail => bot = bot.max(phys.pos[d].y),
                _ if margin.contains(&(d as u32)) => {} // backward-route-band resident, not a field device
                _ => {
                    dmin = dmin.min(phys.pos[d].y);
                    dmax = dmax.max(phys.pos[d].y);
                }
            }
        }
        assert!(
            top < dmin,
            "{name}: VDD ({top}) not above field devices ({dmin})"
        );
        assert!(
            bot > dmax,
            "{name}: GND ({bot}) not below field devices ({dmax})"
        );
    }
}

/// §"Power rails": VDD/GND are drawn ONCE as a horizontal rail bus — never per-net staples.
/// Assert each power/ground net has a single horizontal trunk segment sitting at the rail's y.
#[test]
fn power_and_ground_drawn_as_single_bus() {
    let ir = ir_of(circuits::current_mirror);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);
    let vy = vdd_y(&ctx, &phys.pos);
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        let class = ctx.net_class(net);
        if !matches!(class, NetClass::Power | NetClass::Ground) {
            continue;
        }
        let trunks: Vec<&[Pt]> = phys
            .segments(net)
            .filter(|s| s.len() == 2 && s[0].y == s[1].y && s[0].x != s[1].x)
            .collect();
        assert_eq!(
            trunks.len(),
            1,
            "net {n} ({class:?}) must be one horizontal bus, got {}",
            trunks.len()
        );
        if class == NetClass::Power {
            assert_eq!(trunks[0][0].y, vy, "power bus must sit on the VDD rail");
        }
    }
}
