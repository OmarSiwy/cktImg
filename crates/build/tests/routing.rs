//! Wiring: within-spine feedback, immediate ties, the §C ladder (direct / staple / label),
//! and the "top margin = backward feedback only" classification.
#![allow(unused_imports)] // common is a shared test prelude
mod common;
use common::*;

/// §"Routing primitives" #2 / junction-dot semantics: a connection dot marks where ≥3 same-net
/// arms meet (a tap/fan), but a pure cross-over of two DIFFERENT nets gets NO dot and reads as
/// "not connected". A tail fan node must place a dot; the 5T OTA mirror cross-over must not.
#[test]
fn junction_dots_mark_taps_not_crossovers() {
    // a tail current source fans one node to ≥3 branches → at least one same-net junction dot
    let phys = place(&ir_of(circuits::tail_current_source));
    assert!(!phys.junctions.is_empty(), "a tail fan node (≥3 same-net arms) must place a junction dot");

    // a different-net cross-over earns no dot at the crossing point
    let ir = ir_of(circuits::ota_5t);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);
    let mut segs: Vec<(usize, Pt, Pt)> = Vec::new();
    for n in 0..ctx.nn() {
        for s in phys.segments(NetIdx::from_index(n)) {
            for w in s.windows(2) {
                segs.push((n, w[0], w[1]));
            }
        }
    }
    let mut crossings = 0;
    for i in 0..segs.len() {
        for j in (i + 1)..segs.len() {
            let (a, b) = (segs[i], segs[j]);
            if a.0 == b.0 {
                continue; // same net — a tap, allowed to dot
            }
            // one horizontal, one vertical, interiors crossing → the crossover point
            let (h, v) = if a.1.y == a.2.y && b.1.x == b.2.x {
                (a, b)
            } else if b.1.y == b.2.y && a.1.x == a.2.x {
                (b, a)
            } else {
                continue;
            };
            let (hy, vx) = (h.1.y, v.1.x);
            let (hx0, hx1) = (h.1.x.min(h.2.x), h.1.x.max(h.2.x));
            let (vy0, vy1) = (v.1.y.min(v.2.y), v.1.y.max(v.2.y));
            if hx0 < vx && vx < hx1 && vy0 < hy && hy < vy1 {
                crossings += 1;
                assert!(
                    !phys.junctions.contains(&Pt::new(vx, hy)),
                    "ota_5t: cross-over at ({vx},{hy}) must NOT be a junction dot"
                );
            }
        }
    }
    assert!(crossings >= 1, "expected a mirror cross-over in the 5T OTA");
}

/// §"Within a spine": a feedback loop (diode-connected device) routes a Manhattan wire that
/// does NOT overlap the device body. Assert the diode's feedback net clears M1's body and uses
/// a side channel rather than crossing through it.
#[test]
fn within_spline_feedback_clears_device_body() {
    let ir = ir_of(circuits::diode_connected);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);

    // the diode device: has a control pin whose net also touches one of its conduction pins
    let m = (0..ctx.nd())
        .map(|d| DeviceIdx(d as u32))
        .find(|&d| {
            let gate_net = ctx.pins(d).find(|&p| ctx.role_of(p).is_control()).and_then(|p| ctx.net_of(p));
            gate_net.is_some_and(|g| ctx.pins(d).any(|p| ctx.conducts(p) && ctx.net_of(p) == Some(g)))
        })
        .expect("a diode-connected device");
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

/// §44/§94 "Between immediate-neighbor spines": an adjacent gate-tie is a LOCAL connection in
/// the single gap between the two columns — one connected polyline, never lifted into the top
/// margin. (The doc also wants it bend-free; the placer currently emits a Z-jog — see faults.rs.
/// This test pins the locality guarantee, which holds.)
#[test]
fn immediate_neighbour_tie_routes_locally() {
    let ir = ir_of(circuits::current_mirror);
    let ctx = Ctx::build(&ir);
    let splines = extract_splines(&ctx);
    let order: Vec<&Spline> = splines.iter().collect();
    let cols = assign_columns(&ctx, &order);
    let col_of = column_of(&ctx, &cols);
    let ev = evaluate(&ctx, &order);
    let vy = vdd_y(&ctx, &ev.physical.pos);

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

/// §"Connection classification": a clean stage (rails + gate-ties + forward signal) draws NO
/// wire in the top margin — nothing is routed strictly above the VDD rail.
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
    for name in clean {
        let ir = ir_of(circuit(name));
        let ctx = Ctx::build(&ir);
        let phys = place(&ir);
        let vy = vdd_y(&ctx, &phys.pos);
        let above = phys.wire_pts.iter().filter(|p| p.y < vy).count();
        assert_eq!(above, 0, "{name}: {above} wire point(s) above the VDD rail — margin should be empty");
    }
}

/// §Connection classification: the engine derives each net's electrical direction, so a clean
/// stage with no margin staples raises NO "non-feedback in margin" misclassification — the
/// direction classifier does not false-positive when the margin is already empty.
#[test]
fn clean_stage_raises_no_margin_misclassification() {
    for name in ["differential_pair", "current_mirror", "cascode", "cross_coupled_pair"] {
        let ir = ir_of(circuit(name));
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        let order: Vec<&Spline> = splines.iter().collect();
        let ev = evaluate(&ctx, &order);
        assert!(
            !ev.fallbacks.iter().any(|(_, why)| why.contains("margin")),
            "{name}: clean stage should raise no margin misclassification, got {:?}",
            ev.fallbacks
        );
    }
}

/// §46: backward feedback is the ONLY connection that earns a long route in the top margin.
/// The two-stage Miller amp's compensation path must put wiring above the VDD rail.
#[test]
fn backward_feedback_uses_top_margin() {
    let ir = ir_of(circuits::two_stage_miller);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);
    let vy = vdd_y(&ctx, &phys.pos);
    assert!(phys.wire_pts.iter().any(|p| p.y < vy), "two-stage Miller feedback must route in the top margin");
}

/// §120 (tier 2) + §"front/back exit": a non-immediate net that can't run direct is a margin
/// STAPLE that exits each endpoint on a side channel (off the spine axis), so a riser never runs
/// through the spine's own bodies. The trunk is a 6-point polyline: pin → side stub → vertical
/// riser → margin run → vertical riser → side stub → pin. Extra segments are taps onto the run.
#[test]
fn margin_staples_are_well_formed_routes() {
    let mut staples = 0;
    for name in ["two_stage_miller", "three_stage_nested_miller", "ota_5t"] {
        let ir = ir_of(circuit(name));
        let ctx = Ctx::build(&ir);
        let phys = place(&ir);
        let vy = vdd_y(&ctx, &phys.pos);
        for n in 0..ctx.nn() {
            if ctx.net_class(NetIdx::from_index(n)) != NetClass::Signal {
                continue;
            }
            let segs: Vec<Vec<Pt>> = phys.segments(NetIdx::from_index(n)).map(|s| s.to_vec()).collect();
            if !segs.iter().flatten().any(|p| p.y < vy) {
                continue;
            }
            // the trunk is the staple: a 6-point side-stub → riser → run → riser → side-stub poly
            let trunk = segs.iter().find(|s| s.len() == 6).unwrap_or_else(|| panic!("{name} net{n}: no 6-pt staple trunk in {segs:?}"));
            assert_eq!(trunk[0].y, trunk[1].y, "{name} net{n}: leg 1 is a horizontal side stub");
            assert_eq!(trunk[1].x, trunk[2].x, "{name} net{n}: leg 2 is a vertical riser");
            assert!(trunk[2].y == trunk[3].y && trunk[2].y < vy, "{name} net{n}: leg 3 is the margin run");
            assert_eq!(trunk[3].x, trunk[4].x, "{name} net{n}: leg 4 is a vertical riser");
            assert_eq!(trunk[4].y, trunk[5].y, "{name} net{n}: leg 5 is a horizontal side stub");
            let run_y = trunk[2].y;
            let (rx0, rx1) = (trunk[2].x.min(trunk[3].x), trunk[2].x.max(trunk[3].x));
            // every other segment is a vertical tap landing on the run
            for s in segs.iter().filter(|s| s.len() != 6) {
                assert_eq!(s.len(), 2, "{name} net{n}: a tap is a 2-point stub, got {s:?}");
                assert_eq!(s[0].x, s[1].x, "{name} net{n}: tap is vertical");
                let top = s.iter().min_by_key(|p| p.y).unwrap();
                assert!(top.y == run_y && rx0 <= top.x && top.x <= rx1, "{name} net{n}: tap {s:?} must land on the run");
            }
            staples += 1;
        }
    }
    assert!(staples >= 4, "expected several margin staples across the multi-stage amps");
}

/// §132–138: margin tracks are packed smallest-window-FIRST so a wide staple nests on an OUTER
/// track and never collides with a narrower one. Assert (a) two staple runs that overlap in x
/// never share a track (y), and (b) of two overlapping runs the WIDER one is the outer (more
/// negative y) — the nesting the doc requires.
#[test]
fn margin_staple_tracks_are_collision_free_and_nested() {
    let mut overlapping_pairs = 0;
    for name in ["two_stage_miller", "three_stage_nested_miller"] {
        let ir = ir_of(circuit(name));
        let ctx = Ctx::build(&ir);
        let runs = margin_runs(&ctx, &place(&ir));
        for i in 0..runs.len() {
            for j in i + 1..runs.len() {
                let (a, b) = (runs[i], runs[j]);
                if !(a.0 < b.1 && b.0 < a.1) {
                    continue; // x-ranges don't overlap
                }
                overlapping_pairs += 1;
                // (a) overlapping runs never share a track (y)
                assert_ne!(a.2, b.2, "{name}: overlapping staples {a:?},{b:?} share a track");
                // (b) when one run NESTS inside another (x-range containment), the container is
                // OUTER (more negative y) — the smallest-window-first packing the doc requires.
                // Partial (crossing) overlaps only need distinct tracks (a); they don't nest.
                let a_in_b = b.0 <= a.0 && a.1 <= b.1;
                let b_in_a = a.0 <= b.0 && b.1 <= a.1;
                if a_in_b || b_in_a {
                    let (outer, inner) = if b_in_a { (a, b) } else { (b, a) };
                    assert!(
                        outer.2 < inner.2,
                        "{name}: container staple {outer:?} must be OUTER (above) nested {inner:?}"
                    );
                }
            }
        }
    }
    assert!(overlapping_pairs >= 2, "expected nested/overlapping staples to actually occur");
}

/// §115 (tier 1): a spanning net whose endpoints align and whose path is clear runs as a single
/// direct horizontal in the device field — not lifted into the margin. The two-stage amp's
/// forward signal does exactly this.
#[test]
fn spanning_signal_uses_direct_horizontal_when_clear() {
    let ir = ir_of(circuits::two_stage_miller);
    let ctx = Ctx::build(&ir);
    let phys = place(&ir);
    let vy = vdd_y(&ctx, &phys.pos);
    let mut found = false;
    for n in 0..ctx.nn() {
        if ctx.net_class(NetIdx::from_index(n)) != NetClass::Signal {
            continue;
        }
        for s in phys.segments(NetIdx::from_index(n)) {
            // a single straight horizontal spanning > one column pitch, kept in the field
            if s.len() == 2 && s[0].y == s[1].y && s[0].y >= vy && (s[1].x - s[0].x).abs() > CELL_W {
                found = true;
            }
        }
    }
    assert!(found, "a clear forward signal must route as a direct in-field horizontal");
}
