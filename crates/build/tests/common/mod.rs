//! Shared fixtures and geometry helpers for the `build` integration tests. Each test file does
//! `mod common;` then `use common::*;`. Tests assert ALGORITHM.md conditions against the actual
//! placed/routed output through the public `build` API — never no-panic or length smoke checks.
//!
//! Determinism note: coordinate-reading tests evaluate a FIXED spline order (id-sorted, the
//! order `extract_splines` returns) via `evaluate`, so column identity from `assign_columns`
//! lines up with the geometry. `layout`/`place` instead pick the best order — used only where
//! the assertion is order-independent.
#![allow(dead_code, unused_imports)]

// The §7 test circuits live in tests/fixtures.rs (dev-only — not shipped by `build`). Path-include
// them here so `use common::*` re-exports `circuits` to every test file.
#[path = "../fixtures/circuits.rs"]
pub mod circuits;

pub use build::{
    Case, Column, ColumnKind, Ctx, NetClass, Spline, assign_columns, classify, column_of, evaluate,
    extract_splines, layout, net_columns, place,
};
pub use ir::{
    DeviceIdx, Interner, IrBuilder, Label, NetIdx, Orientation, Pt, Rect, Rot, Schematic,
    SymbolIdx, Unplaced,
};

/// A circuit constructor from the `circuits` fixture module.
pub type Build = fn(&mut Interner) -> Schematic<Unplaced>;

/// Layout constants mirrored from layout.rs (private there). If those change, the spacing/fault
/// characterization tests should be updated in lockstep.
pub const CELL_W: i32 = 40;
pub const TRACK_W: i32 = 8; // one wire gauge; also the one-gauge channel floor (no base)

/// A device-class symbol by class name (e.g. "nmos", "res", "vdd").
pub fn sym(n: &str) -> SymbolIdx {
    SymbolIdx(devices::class_of(n).expect("known class") as u32)
}

/// Build the IR for a named test circuit.
pub fn ir_of(f: Build) -> ir::Ir {
    let mut it = Interner::default();
    f(&mut it).into_ir()
}

/// Look up a circuit constructor by name from `circuits::all()`.
pub fn circuit(name: &str) -> Build {
    circuits::all()
        .into_iter()
        .find(|(n, _)| *n == name)
        .unwrap_or_else(|| panic!("no circuit {name}"))
        .1
}

/// A device's absolute oriented collision box — same construction the engine uses for its
/// `Rect::intersects` clearance check, so tests can re-derive it from public data.
pub fn dev_box(orient: &[Orientation], ctx: &Ctx, d: DeviceIdx, pos: Pt) -> Rect {
    let bb = ctx.class(d).bbox();
    let o = orient[d.index()];
    let (mut mnx, mut mny, mut mxx, mut mxy) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
    for (x, y) in [
        (bb.min.x, bb.min.y),
        (bb.max.x, bb.min.y),
        (bb.min.x, bb.max.y),
        (bb.max.x, bb.max.y),
    ] {
        let q = o.apply(Pt::new(x, y));
        mnx = mnx.min(q.x);
        mxx = mxx.max(q.x);
        mny = mny.min(q.y);
        mxy = mxy.max(q.y);
    }
    Rect::new(
        Pt::new(pos.x + mnx, pos.y + mny),
        Pt::new(pos.x + mxx, pos.y + mxy),
    )
}

/// VDD device y-position (the top rail). Panics if the circuit has no power rail.
pub fn vdd_y(ctx: &Ctx, pos: &[Pt]) -> i32 {
    (0..ctx.nd())
        .map(|d| DeviceIdx(d as u32))
        .filter(|&d| matches!(ctx.role(d), devices::SymbolRole::PowerRail))
        .map(|d| pos[d.index()].y)
        .min()
        .expect("circuit has a power rail")
}

/// Does an axis-aligned segment enter the OPEN rectangle (x0,x1)×(y0,y1)?
pub fn seg_enters(p: Pt, q: Pt, x0: i32, x1: i32, y0: i32, y1: i32) -> bool {
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
pub fn crosses(a1: Pt, a2: Pt, b1: Pt, b2: Pt) -> bool {
    let (ah, bh) = (a1.y == a2.y, b1.y == b2.y);
    if ah == bh {
        return false;
    }
    let (h1, h2, v1, v2) = if ah {
        (a1, a2, b1, b2)
    } else {
        (b1, b2, a1, a2)
    };
    let (hx0, hx1) = (h1.x.min(h2.x), h1.x.max(h2.x));
    let (vy0, vy1) = (v1.y.min(v2.y), v1.y.max(v2.y));
    hx0 < v1.x && v1.x < hx1 && vy0 < h1.y && h1.y < vy1
}

/// Count crossings between segments of DIFFERENT nets in a finished layout.
pub fn measured_crossings(phys: &ir::Physical) -> u32 {
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
pub fn permutations(n: usize) -> Vec<Vec<usize>> {
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

/// Every margin staple's horizontal run as (x_lo, x_hi, y): a horizontal segment drawn strictly
/// above the VDD rail, across all nets.
pub fn margin_runs(ctx: &Ctx, phys: &ir::Physical) -> Vec<(i32, i32, i32)> {
    let vy = vdd_y(ctx, &phys.pos);
    let mut runs = Vec::new();
    for n in 0..ctx.nn() {
        for s in phys.segments(NetIdx::from_index(n)) {
            // a margin staple is a 6-point trunk (side stub → riser → RUN → riser → side stub);
            // the run is the middle horizontal leg, above the VDD rail. Side stubs and taps are
            // not runs.
            if s.len() == 6 && s[2].y == s[3].y && s[2].y < vy {
                runs.push((s[2].x.min(s[3].x), s[2].x.max(s[3].x), s[2].y));
            }
        }
    }
    runs
}
