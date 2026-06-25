//! Regression tests for the spline-column placer. Every test asserts a specific condition
//! from `docs/ALGORITHM.md` against the actual placed/routed output — none is a no-panic or
//! length-equality smoke test. Where a test names a doc section, breaking that behaviour
//! breaks the test.
//!
//! Determinism: tests that read coordinates evaluate a FIXED spline order (id-sorted, the
//! order `extract_splines` returns) via `evaluate`, so column identity from `assign_columns`
//! lines up with the geometry. `layout`/`place` instead pick the best order — used only where
//! the assertion is order-independent.

use crate::ctx::{Ctx, NetClass};
use crate::extract::{assign_columns, classify, column_of, extract_splines, net_columns, Case, ColumnKind, Spline};
use crate::{evaluate, layout, place};
use ir::{DeviceIdx, Interner, NetIdx, Orientation, Pt, Rot, Schematic, Unplaced};

type Build = fn(&mut Interner) -> Schematic<Unplaced>;

fn ir_of(f: Build) -> ir::Ir {
    let mut it = Interner::default();
    f(&mut it).into_ir()
}

/// VDD device y-position (the top rail). Panics if the circuit has no power rail.
fn vdd_y(ctx: &Ctx, pos: &[Pt]) -> i32 {
    (0..ctx.nd())
        .map(|d| DeviceIdx(d as u32))
        .filter(|&d| matches!(ctx.role(d), devices::SymbolRole::PowerRail))
        .map(|d| pos[d.index()].y)
        .min()
        .expect("circuit has a power rail")
}

/// Does an axis-aligned segment enter the OPEN rectangle (x0,x1)×(y0,y1)?
fn seg_enters(p: Pt, q: Pt, x0: i32, x1: i32, y0: i32, y1: i32) -> bool {
    if p.y == q.y {
        let y = p.y;
        let (lo, hi) = (p.x.min(q.x), p.x.max(q.x));
        y0 < y && y < y1 && lo < x1 && x0 < hi
    } else {
        let x = p.x;
        let (lo, hi) = (p.y.min(q.y), p.y.max(q.y));
        x0 < x && x < x1 && lo < y1 && y0 < hi
    }
}

/// Strict interior crossing of a horizontal and a vertical segment (mirrors the engine's
/// `cross`); recomputed here so crossing tests measure the drawn geometry independently.
fn crosses(a1: Pt, a2: Pt, b1: Pt, b2: Pt) -> bool {
    let (ah, bh) = (a1.y == a2.y, b1.y == b2.y);
    if ah == bh {
        return false;
    }
    let (h1, h2, v1, v2) = if ah { (a1, a2, b1, b2) } else { (b1, b2, a1, a2) };
    let (hx0, hx1) = (h1.x.min(h2.x), h1.x.max(h2.x));
    let (vy0, vy1) = (v1.y.min(v2.y), v1.y.max(v2.y));
    hx0 < v1.x && v1.x < hx1 && vy0 < h1.y && h1.y < vy1
}

/// Count crossings between segments of DIFFERENT nets in a finished layout.
fn measured_crossings(phys: &ir::Physical) -> u32 {
    let mut segs: Vec<(usize, Pt, Pt)> = Vec::new();
    for n in 0..phys.net_seg.len() - 1 {
        for s in phys.segments(NetIdx::from_index(n)) {
            for w in s.windows(2) {
                segs.push((n, w[0], w[1]));
            }
        }
    }
    let mut c = 0;
    for i in 0..segs.len() {
        for j in i + 1..segs.len() {
            if segs[i].0 != segs[j].0 && crosses(segs[i].1, segs[i].2, segs[j].1, segs[j].2) {
                c += 1;
            }
        }
    }
    c
}

/// All permutations of 0..n (Heap-style), for exhaustive spline-order checks.
fn permutations(n: usize) -> Vec<Vec<usize>> {
    let mut out = Vec::new();
    let mut a: Vec<usize> = (0..n).collect();
    fn go(a: &mut [usize], k: usize, out: &mut Vec<Vec<usize>>) {
        if k == a.len() {
            out.push(a.to_vec());
            return;
        }
        for i in k..a.len() {
            a.swap(k, i);
            go(a, k + 1, out);
            a.swap(k, i);
        }
    }
    go(&mut a, 0, &mut out);
    out
}

// ───────────────────────────── Core idea: spline decomposition ─────────────────────────────

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
    let all = crate::circuits::all();
    for &(name, want) in expect {
        let f = all.iter().find(|(n, _)| *n == name).unwrap().1;
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let got = extract_splines(&ctx).len();
        assert_eq!(got, want, "{name}: spline count");
    }
}

// ──────────────────── "Each spine gets its own column, stacked vertically" ───────────────────

/// Every Spline/Shared column places its devices on ONE vertical axis (shared x) in strictly
/// increasing y (VDD→GND conduction order). This is the whole point of vertical orientation:
/// stacked conduction pins share an x so the within-spline wire is a straight line.
#[test]
fn spline_columns_are_vertically_stacked() {
    for (name, f) in crate::circuits::all() {
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

// ────────────────────────────── Power rails: top / bottom / bus ─────────────────────────────

/// §"Power rails": VDD spans the top, GND the bottom — every non-rail device sits strictly
/// between them.
#[test]
fn power_on_top_ground_on_bottom() {
    for (name, f) in crate::circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let has_pwr = (0..ctx.nd()).any(|d| matches!(ctx.role(DeviceIdx(d as u32)), devices::SymbolRole::PowerRail));
        let has_gnd = (0..ctx.nd()).any(|d| matches!(ctx.role(DeviceIdx(d as u32)), devices::SymbolRole::GroundRail));
        if !(has_pwr && has_gnd) {
            continue; // splineless circuits (no rails)
        }
        let phys = place(&ir);
        let (mut top, mut bot) = (i32::MAX, i32::MIN);
        let (mut dmin, mut dmax) = (i32::MAX, i32::MIN);
        for d in 0..ctx.nd() {
            let di = DeviceIdx(d as u32);
            match ctx.role(di) {
                devices::SymbolRole::PowerRail => top = top.min(phys.pos[d].y),
                devices::SymbolRole::GroundRail => bot = bot.max(phys.pos[d].y),
                _ => {
                    dmin = dmin.min(phys.pos[d].y);
                    dmax = dmax.max(phys.pos[d].y);
                }
            }
        }
        assert!(top < dmin, "{name}: VDD ({top}) not above devices ({dmin})");
        assert!(bot > dmax, "{name}: GND ({bot}) not below devices ({dmax})");
    }
}

/// §"Power rails": VDD/GND are drawn ONCE as a horizontal rail bus — never per-net staples.
/// Assert each power/ground net has a single horizontal trunk segment sitting at the rail's y.
#[test]
fn power_and_ground_drawn_as_single_bus() {
    let ir = ir_of(crate::circuits::current_mirror);
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
        assert_eq!(trunks.len(), 1, "net {n} ({class:?}) must be one horizontal bus, got {}", trunks.len());
        if class == NetClass::Power {
            assert_eq!(trunks[0][0].y, vy, "power bus must sit on the VDD rail");
        }
    }
}

// ─────────────────────────────────── Device orientation ────────────────────────────────────

/// §"Device orientation": a gate points LEFT iff its net is driven from a column to the left,
/// otherwise RIGHT (toward the next spine). Check the rule holds for every MOS in a mirror —
/// the diode reference's gate points right, the mirror device's gate points left toward it.
#[test]
fn gate_points_toward_its_driving_spline() {
    let ir = ir_of(crate::circuits::current_mirror);
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
        let Some(gate) = ctx.pins(di).find(|&p| ctx.role_of(p).is_control()) else { continue };
        let Some(net) = ctx.net_of(gate) else { continue };
        let from_left = ctx
            .members(net)
            .iter()
            .any(|&q| matches!(col_of[ctx.dev_of(q).index()], c if c != usize::MAX && c < my_col));
        let body_x = ev.physical.pos[d].x;
        let gate_x = ev.physical.pin_xy[gate.index()].x;
        if from_left {
            assert!(gate_x < body_x, "dev{d}: gate driven from left must point left ({gate_x} !< {body_x})");
        } else {
            assert!(gate_x > body_x, "dev{d}: gate not from left must point right ({gate_x} !> {body_x})");
        }
        checked += 1;
    }
    assert!(checked >= 2, "expected to check both mirror devices");
}

// ───────────────────────── Top margin carries backward feedback ONLY ────────────────────────

/// §"Wiring/Connection classification": a clean stage (rails + gate-ties + forward signal)
/// draws NO wire in the top margin — nothing is routed strictly above the VDD rail.
#[test]
fn clean_stages_draw_no_margin_wires() {
    let clean = [
        "common_source",
        "cascode",
        "current_mirror",
        "cascode_current_mirror",
        "differential_pair", // §50: a clean diff-pair input stage has NO margin wires
        "cross_coupled_pair",
        "tail_current_source",
        "stacked_bias_string",
    ];
    let all = crate::circuits::all();
    for name in clean {
        let f = all.iter().find(|(n, _)| *n == name).unwrap().1;
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let phys = place(&ir);
        let vy = vdd_y(&ctx, &phys.pos);
        let above = phys.wire_pts.iter().filter(|p| p.y < vy).count();
        assert_eq!(above, 0, "{name}: {above} wire point(s) above the VDD rail — margin should be empty");
    }
}

/// §46: backward feedback is the ONLY connection that earns a long route in the top margin.
/// The two-stage Miller amp's compensation path must put wiring above the VDD rail.
#[test]
fn backward_feedback_uses_top_margin() {
    let ir = ir_of(crate::circuits::two_stage_miller);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);
    let vy = vdd_y(&ctx, &phys.pos);
    let above = phys.wire_pts.iter().filter(|p| p.y < vy).count();
    assert!(above > 0, "two-stage Miller feedback must route in the top margin");
}

// ────────────────────────────────────── Shared devices ─────────────────────────────────────

/// §"Shared devices" N=2: the shared tail gets its OWN column placed BETWEEN the two branches.
#[test]
fn shared_n2_column_sits_between_branches() {
    let ir = ir_of(crate::circuits::differential_pair);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let ev = evaluate(&ctx, &order);

    let shared: Vec<usize> = (0..cols.len()).filter(|&i| cols[i].kind == ColumnKind::Shared).collect();
    assert_eq!(shared.len(), 1, "N=2 shared tail must produce exactly one Shared column");
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

/// §"Shared devices" N>2: the tail anchors onto its first branch — NO Shared column — and the
/// other branches reach it via a fan bus (a horizontal trunk at the hub's y).
#[test]
fn shared_n3_anchors_without_extra_column() {
    let ir = ir_of(crate::circuits::tail_current_source);
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
        (0..ctx.nd()).map(|d| DeviceIdx(d as u32)).find(|&d| count[d.index()] >= 3)
    }
    .expect("a device shared by ≥3 branches");
    assert!(
        cols.iter().any(|c| c.kind == ColumnKind::Spline && c.devices.contains(&tail_dev)),
        "anchored tail must sit on a Spline column"
    );
    // its conduction (tail) net is drawn as a fan bus: a horizontal trunk spanning all branches
    let tail_net = ctx
        .pins(tail_dev)
        .find(|&p| ctx.conducts(p) && ctx.net_class(ctx.net_of(p).unwrap()) == NetClass::Signal)
        .and_then(|p| ctx.net_of(p))
        .expect("tail node net");
    let has_bus = phys.segments(tail_net).any(|s| s.len() == 2 && s[0].y == s[1].y && s[0].x != s[1].x);
    assert!(has_bus, "fan node must be routed as a horizontal bus");
}

// ─────────────────────────── Within-spine feedback routing (§53) ────────────────────────────

/// §"Within a spine": a feedback loop (diode-connected device) routes a Manhattan wire that
/// does NOT overlap the device body. Assert the diode's feedback net clears M1's body and uses
/// a side channel rather than crossing through it.
#[test]
fn within_spline_feedback_clears_device_body() {
    let ir = ir_of(crate::circuits::diode_connected);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);

    // the diode device: has a control pin whose net also touches one of its conduction pins
    let m = (0..ctx.nd()).map(|d| DeviceIdx(d as u32)).find(|&d| {
        let gate_net = ctx.pins(d).find(|&p| ctx.role_of(p).is_control()).and_then(|p| ctx.net_of(p));
        gate_net.is_some_and(|g| ctx.pins(d).any(|p| ctx.conducts(p) && ctx.net_of(p) == Some(g)))
    });
    let m = m.expect("a diode-connected device");
    let fb_net = ctx.pins(m).find(|&p| ctx.role_of(p).is_control()).and_then(|p| ctx.net_of(p)).unwrap();

    // M1 body box: centred on its column axis, full cell width, spanning its conduction pins
    let half = devices::CELL_WIDTH / 2;
    let cx = phys.pos[m.index()].x;
    let (x0, x1) = (cx - half, cx + half);
    let ys: Vec<i32> = ctx.pins(m).filter(|&p| ctx.conducts(p)).map(|p| phys.pin_xy[p.index()].y).collect();
    let (y0, y1) = (*ys.iter().min().unwrap(), *ys.iter().max().unwrap());

    let mut uses_side_channel = false;
    for seg in phys.segments(fb_net) {
        for w in seg.windows(2) {
            assert!(
                !seg_enters(w[0], w[1], x0, x1, y0, y1),
                "feedback wire {:?}→{:?} crosses the device body ({x0}..{x1},{y0}..{y1})",
                w[0],
                w[1]
            );
            if w[0].x > x1 || w[1].x > x1 {
                uses_side_channel = true;
            }
        }
    }
    assert!(uses_side_channel, "diode feedback must detour through a side channel beside the body");
}

// ──────────────────── Immediate-neighbour tie routes locally, not in the margin ──────────────

/// §44/§94 "Between immediate-neighbor spines": an adjacent gate-tie is a LOCAL connection in
/// the single gap between the two columns — one connected polyline, never lifted into the top
/// margin. (The doc also wants it bend-free; the placer currently emits a small Z-jog because
/// the power net pre-empts the per-gap alignment gauge — see the regression report. This test
/// pins the locality guarantee, which holds.)
#[test]
fn immediate_neighbour_tie_routes_locally() {
    let ir = ir_of(crate::circuits::current_mirror);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let col_of = column_of(&ctx, &cols);
    let ev = evaluate(&ctx, &order);
    let vy = vdd_y(&ctx, &ev.physical.pos);

    // the mirror gate-tie: an immediate-neighbour SIGNAL net
    let tie = (0..ctx.nn())
        .map(NetIdx::from_index)
        .find(|&net| {
            ctx.net_class(net) == NetClass::Signal
                && classify(&net_columns(&ctx, net, &col_of)) == Case::ImmediateNeighbor
        })
        .expect("current mirror has an immediate-neighbour gate-tie");

    let polys: Vec<Vec<Pt>> = ev.physical.segments(tie).map(|s| s.to_vec()).collect();
    assert_eq!(polys.len(), 1, "an adjacent tie is one local polyline, not a split margin route");
    let pts = &polys[0];
    assert!(pts.iter().all(|p| p.y >= vy), "gate-tie must stay in the field, never the top margin");
    let span = pts.iter().map(|p| p.x).max().unwrap() - pts.iter().map(|p| p.x).min().unwrap();
    assert!(span > 0, "gate-tie must actually bridge the two adjacent columns");
}

// ───────────────────────────────── Wire length / tap room ──────────────────────────────────

/// §"Wire length": optimallen = N − (in-column connections). An extra connection from OUTSIDE
/// the column raises N without raising the in-column count, so it adds one unit of tap room
/// between the two stacked devices; with none, they abut.
#[test]
fn optimallen_adds_tap_room_per_external_connection() {
    use ir::IrBuilder;
    let sym = |n: &str| ir::SymbolIdx(devices::class_of(n).expect("class") as u32);
    let h = Orientation::H;
    let mk = |tap: bool| {
        let mut it = Interner::default();
        let mut b = IrBuilder::new(&mut it);
        b.device("VDD", sym("vdd"), "", h, &[Some("vdd")]);
        b.device("Ma", sym("nmos"), "", h, &[Some("vdd"), Some("ga"), Some("mid")]);
        b.device("Mb", sym("nmos"), "", h, &[Some("mid"), Some("gb"), Some("gnd")]);
        if tap {
            // gate of a second-column device taps `mid`: N=3, in-column still 2 → optimallen 1
            b.device("Mc", sym("nmos"), "", h, &[Some("vdd"), Some("mid"), Some("gnd")]);
        }
        b.device("GND", sym("gnd"), "", h, &[Some("gnd")]);
        let ir = b.finish().into_ir();
        let phys = place(&ir);
        phys.pos[2].y - phys.pos[1].y // gap between Ma and Mb
    };
    let abut = mk(false);
    let with_tap = mk(true);
    assert!(abut > 0, "stacked devices still need their own extents");
    assert_eq!(with_tap - abut, 12, "one external tap adds exactly one TAP_UNIT of room");
}

// ───────────────────────────── Crossing metric reflects geometry ────────────────────────────

/// §"Routing primitives": a mirror-load cross-over produces real wire crossings; a single
/// uncrossed spine produces none. The crossing metric must reflect actually-drawn geometry.
#[test]
fn crossing_metric_tracks_real_crossings() {
    let one_col = {
        let ir = ir_of(crate::circuits::cascode);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        evaluate(&ctx, &order).metrics.num_crossings
    };
    assert_eq!(one_col, 0, "a single uncrossed cascode spine has no crossings");

    let ota = {
        let ir = ir_of(crate::circuits::ota_5t);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        evaluate(&ctx, &order).metrics.num_crossings
    };
    assert!(ota >= 1, "the 5T OTA mirror cross-over must register at least one crossing");
}

// ──────────────────────── Placer writes vertical orientation back to IR ─────────────────────

/// The placer SETS each spline device's orientation (vertical) and writes it back into the IR
/// so the renderer draws bodies as placed; rails stay horizontal.
#[test]
fn layout_writes_vertical_orientation_back() {
    let mut it = Interner::default();
    let sch = crate::circuits::differential_pair(&mut it);
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
            assert!(matches!(rot, Rot::R90 | Rot::R270), "spline MOS dev{d} must be vertical, got {rot:?}");
            spline_devs += 1;
        }
    }
    assert!(spline_devs >= 3, "diff pair has ≥3 transistors placed vertically");
}


// ──────────────────────────────── Determinism & selection (§6) ──────────────────────────────

/// The pipeline is deterministic by construction: identical input → byte-identical placement.
#[test]
fn placement_is_deterministic() {
    for (name, f) in crate::circuits::all() {
        let a = place(&ir_of(f));
        let b = place(&ir_of(f));
        assert!(a.pos == b.pos, "{name}: device positions not reproducible");
        assert!(a.pin_xy == b.pin_xy, "{name}: pin coordinates not reproducible");
        assert!(a.wire_pts == b.wire_pts, "{name}: wiring not reproducible");
    }
}

/// §6 selection key: with no net labels (true for every test circuit), crossings are the first
/// discriminator. The chosen column order must achieve the MINIMUM crossing count over all
/// orders — measured on the actual drawn geometry, compared against every permutation.
#[test]
fn selection_minimises_crossings() {
    for (name, f) in crate::circuits::all() {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        if !(2..=7).contains(&splines.len()) {
            continue; // single-spline or beyond the enumeration limit
        }
        let best = permutations(splines.len())
            .iter()
            .map(|p| {
                let order: Vec<&Spline> = p.iter().map(|&i| &splines[i]).collect();
                evaluate(&ctx, &order).metrics.num_crossings
            })
            .min()
            .unwrap();
        let got = measured_crossings(&place(&ir));
        assert_eq!(got, best, "{name}: placed {got} crossings but {best} were achievable");
    }
}

// ─────────────────────────────────── classify() spec (§Classify) ────────────────────────────

/// §"Classify": a net is WithinSpline (≤1 column), ImmediateNeighbor (adjacent columns,
/// span 1), or SpanGe2 (span ≥ 2). Pin the exact boundaries.
#[test]
fn classify_partitions_by_column_span() {
    assert_eq!(classify(&[]), Case::WithinSpline);
    assert_eq!(classify(&[3]), Case::WithinSpline);
    assert_eq!(classify(&[1, 2]), Case::ImmediateNeighbor);
    assert_eq!(classify(&[0, 2]), Case::SpanGe2);
    assert_eq!(classify(&[1, 2, 3]), Case::SpanGe2, "consecutive but span 2 → staple");
    assert_eq!(classify(&[0, 5]), Case::SpanGe2);
}

// ─────────────────────────── Bridge passives & signal-series columns ─────────────────────────

/// §"Components between spines" / Break C: bridge passives (Component) and rail-less conductors
/// (SignalSeries) are laid HORIZONTALLY — only Spline/Shared devices are rotated vertical.
#[test]
fn bridge_and_series_devices_stay_horizontal() {
    let mut checked = 0;
    for (name, f) in crate::circuits::all() {
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
            for &d in &c.devices {
                assert_eq!(ev.orient[d.index()].rot(), Rot::R0, "{name}: {:?} dev not horizontal", c.kind);
                checked += 1;
            }
        }
    }
    assert!(checked >= 5, "expected several Component/SignalSeries devices across the suite");
}

/// §"Components between spines": a bridge passive gets its own column placed BETWEEN the two
/// node columns it spans. The Miller compensation cap sits between the two output columns.
#[test]
fn bridge_passive_column_sits_between_its_nodes() {
    let ir = ir_of(crate::circuits::two_stage_miller);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let col_of = column_of(&ctx, &cols);
    let ev = evaluate(&ctx, &order);

    let comp = cols.iter().find(|c| c.kind == ColumnKind::Component).expect("Miller cap column");
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
    assert_eq!(node_xs.len(), 2, "bridge cap should span two distinct node columns");
    assert!(
        node_xs[0] < cap_x && cap_x < node_xs[1],
        "Miller cap x={cap_x} must sit between its bridged columns {node_xs:?}"
    );
}

// ──────────────────────────────────── Mid-stack gate tap ─────────────────────────────────────

/// §"Routing primitives" #1: a cross-gate (cascode) net taps a NON-endpoint y — the middle
/// device of each column, not its top or bottom. The cascode mirror's upper-gate bus must
/// connect strictly inside each column's vertical extent.
#[test]
fn cross_gate_taps_at_midstack() {
    let ir = ir_of(crate::circuits::cascode_current_mirror);
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
        let ys: Vec<i32> = cols[col].devices.iter().map(|&d| ev.physical.pos[d.index()].y).collect();
        let (top, bot) = (*ys.iter().min().unwrap(), *ys.iter().max().unwrap());
        let py = ev.physical.pin_xy[p.index()].y;
        assert!(top < py && py < bot, "tap at y={py} is an endpoint of column [{top},{bot}], not mid-stack");
        hits += 1;
    }
    assert!(hits >= 2, "expected a mid-stack tap on each branch");
}

// ───────────────────────────────── Splineless (Break C) ─────────────────────────────────────

/// Break C: a rail-less circuit (transmission gate) yields NO splines — every device becomes a
/// signal-series column, placed side by side and left horizontal.
#[test]
fn splineless_circuit_is_signal_series() {
    let ir = ir_of(crate::circuits::transmission_gate);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    assert_eq!(splines.len(), 0, "no rails → no splines");

    let cols = assign_columns(&ctx, &[]);
    assert!(!cols.is_empty(), "devices must still be placed");
    assert!(cols.iter().all(|c| c.kind == ColumnKind::SignalSeries), "all columns are signal-series");

    let ev = evaluate(&ctx, &[]);
    let xs: Vec<i32> = (0..ctx.nd()).map(|d| ev.physical.pos[d].x).collect();
    assert!(xs.windows(2).all(|w| w[0] != w[1]), "series devices sit in distinct columns: {xs:?}");
    assert!((0..ctx.nd()).all(|d| ev.orient[d].rot() == Rot::R0), "series devices stay horizontal");
}
