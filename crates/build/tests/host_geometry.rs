//! Host-geometry contract: a schematic-editor host installs its own pin
//! anchors (devices::install_anchor_overrides) and grid (config::install),
//! then consumes placed+routed output 1:1. Such hosts resolve connectivity
//! GEOMETRICALLY — a pin or wire endpoint touching a wire is a connection —
//! so the drawn geometry itself must satisfy, for every fixture:
//!
//!   1. every device origin and pin on the host grid
//!   2. no wire touching a foreign net's pin point
//!   3. no wire vertex of one net on another net's wire (T-short)
//!   4. every multi-pin net's geometry connected: each pin on the net's own
//!      wiring (or holding a label), wiring forming one island
//!
//! Anchors below are Schemify's symbol pin offsets rotated by M(x,y)=(-y,x)
//! into cktimg's canonical convention (channel horizontal, gate up) so the
//! orientation heuristics keep working; M is orthogonal, so the host can
//! always recover its own (rotation, mirror) per device exactly.
#![allow(unused_imports)]
mod common;
use common::*;
use std::collections::HashMap;

const GRID: i32 = 10;

/// M(x,y) = (-y, x) applied to Schemify's native pin offsets.
const MOS3: [ir::Pt; 3] = [pt(30, 20), pt(0, -20), pt(-30, 20)]; // d, g, s
const BJT3: [ir::Pt; 3] = [pt(30, 20), pt(0, -20), pt(-30, 20)]; // c, b, e
const TWO2: [ir::Pt; 2] = [pt(30, 0), pt(-30, 0)]; // a, b

const fn pt(x: i32, y: i32) -> ir::Pt {
    ir::Pt { x, y }
}

fn install_host_geometry() {
    let d = |p: &'static [ir::Pt]| -> &'static [devices::Pt] {
        // ir::Pt and devices::Pt are distinct types with identical layout;
        // rebuild rather than transmute.
        Box::leak(
            p.iter()
                .map(|q| devices::Pt { x: q.x, y: q.y })
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        )
    };
    let mos = d(&MOS3);
    let bjt = d(&BJT3);
    let two = d(&TWO2);
    // A runtime-categorized host component (testbench DUT): box symbol,
    // Input pin left, other pins right — the host's project-symbol layout.
    let dut = devices::HostClass {
        name: "my_opamp".into(),
        terminals: vec![
            ("in".into(), devices::TerminalRole::Gate, devices::Pt { x: -40, y: 0 }),
            ("out".into(), devices::TerminalRole::Passive, devices::Pt { x: 40, y: -20 }),
            ("vdd".into(), devices::TerminalRole::Passive, devices::Pt { x: 40, y: 0 }),
            ("gnd".into(), devices::TerminalRole::Passive, devices::Pt { x: 40, y: 20 }),
        ],
    };
    devices::install_host_classes(
        &[
            ("nmos", mos),
            ("pmos", mos),
            ("nfet", mos),
            ("pfet", mos),
            ("nfetd", mos),
            ("pfetd", mos),
            ("njfet", bjt),
            ("pjfet", bjt),
            ("npn", bjt),
            ("pnp", bjt),
            ("res", two),
            ("cap", two),
            ("ind", two),
            ("diode", two),
            ("vsource", two),
            ("isource", two),
            ("vsourceac", two),
            ("isourceac", two),
            ("cvsource", two),
            ("cisource", two),
            ("battery", two),
        ],
        &[dut],
    );
    config::install(config::Config {
        layout: config::Layout {
            abut_gap: 10,
            tap_unit: 20,
            track_w: 10,
            track_h: 20,
            margin_gap: 20,
            bus_gap: 30,
            enum_limit: 10,
            grid: GRID,
            strict_geometry: true,
        },
        render: config::Render::default(),
    });
}

fn on_segment(p: Pt, a: Pt, b: Pt) -> bool {
    if a.y == b.y && p.y == a.y {
        a.x.min(b.x) <= p.x && p.x <= a.x.max(b.x)
    } else if a.x == b.x && p.x == a.x {
        a.y.min(b.y) <= p.y && p.y <= a.y.max(b.y)
    } else {
        false
    }
}

struct NetGeom {
    segs: Vec<(Pt, Pt)>,
    pins: Vec<Pt>,
    labels: Vec<Pt>,
}

fn geometry(ctx: &Ctx, phys: &ir::Physical) -> Vec<NetGeom> {
    (0..ctx.nn())
        .map(|n| {
            let net = NetIdx::from_index(n);
            let mut segs = Vec::new();
            for poly in phys.segments(net) {
                for w in poly.windows(2) {
                    if w[0] != w[1] {
                        segs.push((w[0], w[1]));
                    }
                }
            }
            let pins = ctx
                .members(net)
                .iter()
                .map(|&p| phys.pin_xy[p.index()])
                .collect();
            let labels = phys
                .labels
                .iter()
                .filter(|l| l.net == net)
                .map(|l| l.at)
                .collect();
            NetGeom { segs, pins, labels }
        })
        .collect()
}

/// Union-find over a net's wiring: are all segments + pins one island?
fn net_is_connected(g: &NetGeom) -> bool {
    // Labels make connectivity by name; a labelled net passes structurally.
    if !g.labels.is_empty() {
        return true;
    }
    if g.pins.len() < 2 {
        return true;
    }
    let n = g.segs.len() + g.pins.len();
    let mut parent: Vec<usize> = (0..n).collect();
    fn find(p: &mut Vec<usize>, i: usize) -> usize {
        while p[i] != i {
            let gp = p[p[i]];
            p[i] = gp;
            return find(p, gp);
        }
        i
    }
    let union = |p: &mut Vec<usize>, a: usize, b: usize| {
        let (ra, rb) = (find(p, a), find(p, b));
        p[ra] = rb;
    };
    let touches = |(a1, a2): (Pt, Pt), (b1, b2): (Pt, Pt)| -> bool {
        on_segment(a1, b1, b2)
            || on_segment(a2, b1, b2)
            || on_segment(b1, a1, a2)
            || on_segment(b2, a1, a2)
    };
    for i in 0..g.segs.len() {
        for j in (i + 1)..g.segs.len() {
            if touches(g.segs[i], g.segs[j]) {
                union(&mut parent, i, j);
            }
        }
    }
    // NOTE: coincident pins do NOT connect — geometric-connectivity hosts
    // (Schemify connectivity.rs) merge pins only through touching wires.
    for (pi, &p) in g.pins.iter().enumerate() {
        for (si, &(a, b)) in g.segs.iter().enumerate() {
            if on_segment(p, a, b) {
                union(&mut parent, g.segs.len() + pi, si);
            }
        }
    }
    let root = find(&mut parent, 0);
    (0..n).all(|i| find(&mut parent, i) == root)
}

/// Testbench: a runtime-categorized DUT box driven by a source and loaded —
/// the `X` master resolves to the host class instead of flattening/skipping.
fn testbench(it: &mut Interner) -> Schematic<Unplaced> {
    let src = "V1 in gnd 1\n\
               XDUT in out vdd gnd my_opamp\n\
               RL out gnd 10k\n\
               XVDD vdd vdd\n\
               XGND gnd gnd\n";
    let (sch, rep) = netlist::parse(src, it);
    assert!(
        rep.skipped.is_empty(),
        "testbench lines skipped: {:?}",
        rep.skipped
    );
    sch
}

/// Source-driven amplifier (PySpice-style): every input biased by an explicit
/// V source. Sources hang off gate nets into feedback/margin columns — their
/// nets must still wire up (a net with no in-field wiring gets a real wire to
/// its nearest pin, never an invisible point stub), and stacked conduction
/// links must never fuse pins by abutment (grid hosts need a drawable wire).
fn driven_common_source(it: &mut Interner) -> Schematic<Unplaced> {
    let src = "Vdd vdd 0 1.8\n\
               Vin vin 0 700m\n\
               Rd vdd vout 5k\n\
               M1 vout vin 0 0 nmos\n\
               XVDD vdd vdd\n\
               XGND 0 gnd\n";
    let (sch, rep) = netlist::parse(src, it);
    assert!(rep.skipped.is_empty(), "skipped: {:?}", rep.skipped);
    sch
}

#[test]
fn host_geometry_contract() {
    install_host_geometry();
    let mut failures: Vec<String> = Vec::new();
    let mut fixtures = circuits::all();
    fixtures.push(("testbench_dut", testbench));
    fixtures.push(("driven_common_source", driven_common_source));
    for (name, f) in fixtures {
        let ir = ir_of(f);
        let ctx = Ctx::build(&ir);
        let phys = place(&ir);
        let nets = geometry(&ctx, &phys);

        // 1. grid
        for (d, p) in phys.pos.iter().enumerate() {
            if p.x % GRID != 0 || p.y % GRID != 0 {
                failures.push(format!("{name}: device {d} off-grid at ({}, {})", p.x, p.y));
            }
        }
        for (i, p) in phys.pin_xy.iter().enumerate() {
            if p.x % GRID != 0 || p.y % GRID != 0 {
                failures.push(format!("{name}: pin {i} off-grid at ({}, {})", p.x, p.y));
            }
        }
        for p in &phys.wire_pts {
            if p.x % GRID != 0 || p.y % GRID != 0 {
                failures.push(format!("{name}: wire vertex off-grid at ({}, {})", p.x, p.y));
            }
        }

        for (n, g) in nets.iter().enumerate() {
            // 2. no wire through a foreign pin
            for (m, h) in nets.iter().enumerate() {
                if m == n {
                    continue;
                }
                for &p in &h.pins {
                    // A shared point that is also one of net n's own pins is a
                    // legitimate multi-net terminal only if nets differ — flag it.
                    if g.segs.iter().any(|&(a, b)| on_segment(p, a, b)) {
                        failures.push(format!(
                            "{name}: net {n} wire touches net {m} pin at ({}, {})",
                            p.x, p.y
                        ));
                    }
                }
                // 3. no vertex on a foreign wire
                for &(a, b) in &g.segs {
                    for &v in [a, b].iter() {
                        if h.segs.iter().any(|&(c, d)| on_segment(v, c, d)) {
                            failures.push(format!(
                                "{name}: net {n} vertex ({}, {}) lands on net {m} wire",
                                v.x, v.y
                            ));
                        }
                    }
                }
            }
            // 4a. every pin on own wiring (or the net carries a label / is
            // trivial). Coincident pins do NOT count — hosts merge pins only
            // through wires.
            if g.pins.len() >= 2 && g.labels.is_empty() {
                for &p in &g.pins {
                    let covered = g.segs.iter().any(|&(a, b)| on_segment(p, a, b));
                    if !covered {
                        failures.push(format!(
                            "{name}: net {n} pin at ({}, {}) dangling",
                            p.x, p.y
                        ));
                    }
                }
            }
            // 4b. one island
            if !net_is_connected(g) {
                failures.push(format!("{name}: net {n} wiring is split into islands"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} violations:\n{}",
        failures.len(),
        failures.join("\n")
    );
}
