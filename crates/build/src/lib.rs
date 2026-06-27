//! `build`: one-pass schematic place-and-route from a transistor netlist, implementing the
//! spline-column model of the project paper. Pipeline: extract splines (VDD→GND conduction
//! paths) → search column orders (exhaustive up to enum_limit, greedy heuristic beyond) →
//! evaluate each in a four-phase single pass → select by a lexicographic integer key. No cost
//! function, no iterative legalization, no runtime conflict discovery.

mod ctx;
mod extract;
mod layout;


pub use ctx::{Ctx, NetClass};
pub use extract::{
    assign_columns, classify, column_of, extract_splines, net_columns, swappable_pairs, Case, Column,
    ColumnKind, Spline,
};
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
    // Loud, per-net routing fallbacks for the CHOSEN order (§subcase C: "loud, printed
    // fallbacks so the user knows what happened"). Printed once, here — not inside `evaluate`,
    // which runs on every candidate order.
    for (net, why) in &best.fallbacks {
        eprintln!("build: net {} — {}", net.index(), why);
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

fn best_order(ctx: &Ctx, splines: &[Spline]) -> Evaluated {
    let swaps = swappable_pairs(ctx, splines);
    if swaps.is_empty() {
        return search_order(ctx, splines);
    }
    // ponytail: 2^N variants where N = swappable pairs (rare, typically 0–2)
    let variants = swap_variants(splines, &swaps);
    let mut best: Option<Evaluated> = None;
    for v in &variants {
        let cand = search_order(ctx, v);
        if best.as_ref().is_none_or(|b| cand.metrics.key() < b.metrics.key()) {
            best = Some(cand);
        }
    }
    best.unwrap_or_else(|| evaluate(ctx, &[]))
}

/// Exhaustive permutation search up to enum_limit; greedy nearest-neighbor beyond.
fn search_order(ctx: &Ctx, splines: &[Spline]) -> Evaluated {
    if splines.len() <= config::cfg().layout.enum_limit {
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
        let mut best: Option<Evaluated> = None;
        for order_idx in greedy_orders(ctx, splines) {
            let order: Vec<&Spline> = order_idx.iter().map(|&i| &splines[i]).collect();
            let cand = evaluate(ctx, &order);
            if best.as_ref().is_none_or(|b| cand.metrics.key() < b.metrics.key()) {
                best = Some(cand);
            }
        }
        best.unwrap_or_else(|| evaluate(ctx, &[]))
    }
}

fn swap_variants(splines: &[Spline], pairs: &[(usize, usize)]) -> Vec<Vec<Spline>> {
    let n = pairs.len().min(8);
    let mut out = Vec::with_capacity(1 << n);
    for mask in 0..(1u32 << n) {
        let mut v: Vec<Spline> = splines.to_vec();
        for (bit, &(si, pi)) in pairs[..n].iter().enumerate() {
            if mask & (1 << bit) != 0 {
                v[si].swap(pi, pi + 1);
            }
        }
        out.push(v);
    }
    out
}

/// Greedy nearest-neighbor: for each possible starting spline, place the most-connected
/// unplaced spline next. Returns N orderings (one per start), same lex key evaluation.
fn greedy_orders(ctx: &Ctx, splines: &[Spline]) -> Vec<Vec<usize>> {
    use std::collections::HashSet;
    let n = splines.len();
    let nets: Vec<HashSet<usize>> = splines
        .iter()
        .map(|s| {
            let mut ns = HashSet::new();
            for &d in s {
                for p in ctx.pins(d) {
                    if let Some(net) = ctx.net_of(p) {
                        ns.insert(net.index());
                    }
                }
            }
            ns
        })
        .collect();
    let mut adj = vec![vec![0usize; n]; n];
    for i in 0..n {
        for j in (i + 1)..n {
            let c = nets[i].intersection(&nets[j]).count();
            adj[i][j] = c;
            adj[j][i] = c;
        }
    }
    let mut orders = Vec::with_capacity(n);
    for start in 0..n {
        let mut order = Vec::with_capacity(n);
        let mut placed = vec![false; n];
        order.push(start);
        placed[start] = true;
        while order.len() < n {
            let next = (0..n)
                .filter(|&i| !placed[i])
                .max_by_key(|&i| {
                    let conn: usize = order.iter().map(|&j| adj[i][j]).sum();
                    (conn, std::cmp::Reverse(i))
                })
                .unwrap();
            order.push(next);
            placed[next] = true;
        }
        orders.push(order);
    }
    orders
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
