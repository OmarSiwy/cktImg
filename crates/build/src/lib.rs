//! `build`: one-pass schematic place-and-route from a transistor netlist, implementing the
//! spline-column model of the project paper. Pipeline: extract splines (VDD→GND conduction
//! paths) → enumerate column orders → evaluate each in a four-phase single pass → select by a
//! lexicographic integer key. No cost function, no iterative legalization, no runtime
//! conflict discovery.

pub mod circuits;
mod ctx;
mod extract;
mod layout;
#[cfg(test)]
mod tests;

pub use ctx::{Ctx, NetClass};
pub use extract::{extract_splines, Case, Column, ColumnKind, Spline};
pub use layout::{evaluate, Evaluated, Metrics};

use ir::{Ir, Physical, Placed, Schematic, Unplaced};

/// Place and route a schematic, promoting it to `Placed` (§5/§6). The placer also chooses
/// each device's orientation (vertical for spline devices), written back into the IR so the
/// renderer draws bodies as placed.
pub fn layout(sch: Schematic<Unplaced>) -> Schematic<Placed> {
    let mut ir = sch.into_ir();
    let best = {
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        best_order(&ctx, &splines)
    };
    if best.metrics.num_labels > 0 {
        eprintln!(
            "build: {} net(s) fell back to a net label (could not route as a staple)",
            best.metrics.num_labels
        );
    }
    ir.devices.orient = best.orient;
    Schematic::from_resolved(ir, best.physical)
}

/// Compute physical coordinates for an IR: extract splines, pick the best column order.
pub fn place(ir: &Ir) -> Physical {
    let ctx = Ctx::build(ir);
    let splines = extract_splines(&ctx);
    best_order(&ctx, &splines).physical
}

/// Enumerate column orders up to this spline count; beyond it use the deterministic
/// id-sorted order (the paper's DFS fallback). 7! = 5040 evaluations.
const ENUM_LIMIT: usize = 7;

fn best_order(ctx: &Ctx, splines: &[Spline]) -> Evaluated {
    if splines.len() <= ENUM_LIMIT {
        let mut idx: Vec<usize> = (0..splines.len()).collect();
        let mut best: Option<Evaluated> = None;
        permute(&mut idx, 0, &mut |perm| {
            let order: Vec<&Spline> = perm.iter().map(|&i| &splines[i]).collect();
            let cand = evaluate(ctx, &order);
            if best.as_ref().is_none_or(|b| cand.metrics.key() < b.metrics.key()) {
                best = Some(cand);
            }
        });
        best.unwrap_or_else(|| evaluate(ctx, &[]))
    } else {
        let order: Vec<&Spline> = splines.iter().collect();
        evaluate(ctx, &order)
    }
}

/// Heap-style recursion over all permutations of `a`, invoking `f` on each.
fn permute(a: &mut [usize], k: usize, f: &mut impl FnMut(&[usize])) {
    if k == a.len() {
        f(a);
        return;
    }
    for i in k..a.len() {
        a.swap(k, i);
        permute(a, k + 1, f);
        a.swap(k, i);
    }
}
