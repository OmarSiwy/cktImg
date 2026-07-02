//! Shared / branching conduction: N=2 own column, N>2 anchor + fan bus, bridge columns, taps.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// §"Shared devices" N=2: the shared tail gets its OWN column placed BETWEEN the two branches.
#[test]
fn shared_n2_column_sits_between_branches() {
    let ir = ir_of(circuits::differential_pair);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let ev = evaluate(&ctx, &order);

    let shared: Vec<usize> = (0..cols.len())
        .filter(|&i| cols[i].kind == ColumnKind::Shared)
        .collect();
    assert_eq!(
        shared.len(),
        1,
        "N=2 shared tail must produce exactly one Shared column"
    );
    let shared_x = ev.physical.pos[cols[shared[0]].devices[0].index()].x;

    let branch_xs: Vec<i32> = cols
        .iter()
        .filter(|c| c.kind == ColumnKind::Spline)
        .map(|c| ev.physical.pos[c.devices[0].index()].x)
        .collect();
    assert!(
        branch_xs.iter().any(|&x| x < shared_x) && branch_xs.iter().any(|&x| x > shared_x),
        "Shared column x={shared_x} must lie between branch columns {branch_xs:?}"
    );
}

/// §"Shared devices" N>2: the tail anchors onto its span-minimising branch — NO Shared
/// column — and the other branches reach it via a fan bus (a horizontal trunk at the hub's y).
#[test]
fn shared_n3_anchors_without_extra_column() {
    let ir = ir_of(circuits::tail_current_source);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let phys = place(&ir);

    assert!(
        cols.iter().all(|c| c.kind != ColumnKind::Shared),
        "N>2 shared tail must NOT get its own column"
    );
    // the tail device (shared by 3 branches) must live on a Spline column
    let tail_dev = {
        let mut count = vec![0u32; ctx.nd()];
        for s in &splines {
            for &d in s {
                count[d.index()] += 1;
            }
        }
        (0..ctx.nd())
            .map(|d| DeviceIdx(d as u32))
            .find(|&d| count[d.index()] >= 3)
    }
    .expect("a device shared by ≥3 branches");
    assert!(
        cols.iter()
            .any(|c| c.kind == ColumnKind::Spline && c.devices.contains(&tail_dev)),
        "anchored tail must sit on a Spline column"
    );
    // its conduction (tail) net is drawn as a fan bus: a horizontal trunk spanning all branches
    let tail_net = ctx
        .pins(tail_dev)
        .find(|&p| ctx.conducts(p) && ctx.net_class(ctx.net_of(p).unwrap()) == NetClass::Signal)
        .and_then(|p| ctx.net_of(p))
        .expect("tail node net");
    let has_bus = phys
        .segments(tail_net)
        .any(|s| s.len() == 2 && s[0].y == s[1].y && s[0].x != s[1].x);
    assert!(has_bus, "fan node must be routed as a horizontal bus");
}

/// §"Shared devices" N>2 / route_fan: the fan node is a horizontal bus at the hub's y with a
/// vertical DROP from each branch pin that isn't already on it. Assert both the bus and the
/// per-branch drops are drawn.
#[test]
fn fan_bus_has_a_drop_per_branch() {
    let ir = ir_of(circuits::tail_current_source);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);

    let splines = extract_splines(&ctx);
    let tail = (0..ctx.nn())
        .map(NetIdx::from_index)
        .find(|&net| {
            ctx.net_class(net) == NetClass::Signal
                && ctx.members(net).iter().any(|&p| {
                    ctx.conducts(p)
                        && splines
                            .iter()
                            .filter(|s| s.contains(&ctx.dev_of(p)))
                            .count()
                            >= 3
                })
        })
        .expect("the fan (tail) net");

    let segs: Vec<Vec<Pt>> = phys.segments(tail).map(|s| s.to_vec()).collect();
    let bus = segs
        .iter()
        .find(|s| s.len() == 2 && s[0].y == s[1].y && s[0].x != s[1].x)
        .expect("a horizontal bus");
    let bus_y = bus[0].y;
    let drops = segs
        .iter()
        .filter(|s| s.len() == 2 && s[0].x == s[1].x && (s[0].y == bus_y || s[1].y == bus_y))
        .count();
    assert!(
        drops >= 2,
        "each off-hub branch needs a vertical drop to the bus, got {drops}"
    );
}

/// §"Components between spines": a bridge passive gets its own column placed BETWEEN the two
/// node columns it spans. The Miller compensation cap sits between the two output columns.
#[test]
fn bridge_passive_column_sits_between_its_nodes() {
    let ir = ir_of(circuits::two_stage_miller);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let col_of = column_of(&ctx, &cols);
    let ev = evaluate(&ctx, &order);

    let comp = cols
        .iter()
        .find(|c| c.kind == ColumnKind::Component)
        .expect("Miller cap column");
    let cap = comp.devices[0];
    let cap_x = ev.physical.pos[cap.index()].x;

    // x of the two spline columns holding the cap's two bridged nets
    let mut node_xs: Vec<i32> = ctx
        .pins(cap)
        .filter(|&p| ctx.conducts(p))
        .filter_map(|p| ctx.net_of(p))
        .filter_map(|net| {
            ctx.members(net)
                .iter()
                .map(|&q| col_of[ctx.dev_of(q).index()])
                .find(|&c| c != usize::MAX && !cols[c].devices.contains(&cap))
                .map(|c| ev.physical.pos[cols[c].devices[0].index()].x)
        })
        .collect();
    node_xs.sort_unstable();
    node_xs.dedup();
    assert_eq!(
        node_xs.len(),
        2,
        "bridge cap should span two distinct node columns"
    );
    assert!(
        node_xs[0] < cap_x && cap_x < node_xs[1],
        "Miller cap x={cap_x} must sit between its bridged columns {node_xs:?}"
    );
}

/// §147/§163: BOTH plates of a bridge passive must be wired to their node — even when the cap's
/// Component column is an INTERMEDIATE column of one plate's net (the regression that left the
/// Miller cap dangling: the case-router used to wire only a net's extreme columns). Checked on
/// the placed (rendered) layout for both Miller amps.
#[test]
fn bridge_passive_plates_are_both_wired() {
    for name in ["two_stage_miller", "three_stage_nested_miller"] {
        let ir = ir_of(circuit(name));
        let ctx = Ctx::build(&ir);
        let phys = place(&ir);
        let mut caps = 0;
        for d in 0..ctx.nd() {
            let di = DeviceIdx(d as u32);
            let cps: Vec<_> = ctx.pins(di).filter(|&p| ctx.conducts(p)).collect();
            let is_bridge = cps.len() == 2
                && cps
                    .iter()
                    .all(|&p| ctx.role_of(p) == devices::TerminalRole::Passive);
            if !is_bridge {
                continue;
            }
            caps += 1;
            for &p in &cps {
                let net = ctx.net_of(p).expect("plate net");
                let at = phys.pin_xy[p.index()];
                let wired = phys.segments(net).flatten().any(|&q| q == at);
                assert!(
                    wired,
                    "{name}: bridge plate pin{} at {at:?} (net {}) is dangling",
                    p.index(),
                    net.index()
                );
            }
        }
        assert!(caps >= 1, "{name}: expected at least one bridge cap");
    }
}

/// §"Routing primitives" #1: a cross-gate (cascode) net taps a NON-endpoint y — the middle
/// device of each column, not its top or bottom. The cascode mirror's upper-gate bus must
/// connect strictly inside each column's vertical extent.
#[test]
fn cross_gate_taps_at_midstack() {
    let ir = ir_of(circuits::cascode_current_mirror);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let col_of = column_of(&ctx, &cols);
    let ev = evaluate(&ctx, &order);

    // a multi-column net whose pins are all control taps (the cascode-gate bus)
    let tap = (0..ctx.nn())
        .map(NetIdx::from_index)
        .find(|&net| {
            let m = ctx.members(net);
            m.len() >= 2
                && m.iter().all(|&p| ctx.role_of(p).is_control())
                && net_columns(&ctx, net, &col_of).len() >= 2
        })
        .expect("cascode mirror has a cross-gate tap net");

    let mut hits = 0;
    for &p in ctx.members(tap) {
        let col = col_of[ctx.dev_of(p).index()];
        let ys: Vec<i32> = cols[col]
            .devices
            .iter()
            .map(|&d| ev.physical.pos[d.index()].y)
            .collect();
        let (top, bot) = (*ys.iter().min().unwrap(), *ys.iter().max().unwrap());
        let py = ev.physical.pin_xy[p.index()].y;
        assert!(
            top < py && py < bot,
            "tap at y={py} is an endpoint of column [{top},{bot}], not mid-stack"
        );
        hits += 1;
    }
    assert!(hits >= 2, "expected a mid-stack tap on each branch");
}
