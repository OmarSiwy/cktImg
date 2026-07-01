mod ctx;
mod extract;
mod layout;

pub use ctx::{Ctx, NetClass};
pub use extract::{
    assign_columns, classify, column_of, extract_splines, net_columns, swappable_pairs, Case, Column,
    ColumnKind, Spline,
};
pub use layout::{evaluate, Evaluated, Metrics};

use ir::{Ir, Physical, Placed, Schematic, Strings, Unplaced};

fn verbose() -> bool {
    static V: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *V.get_or_init(|| std::env::var("CKTIMG_VERBOSE").is_ok())
}

pub fn layout(sch: Schematic<Unplaced>) -> Schematic<Placed> {
    layout_impl(sch, None)
}

pub fn layout_verbose(sch: Schematic<Unplaced>, pool: &Strings) -> Schematic<Placed> {
    layout_impl(sch, Some(pool))
}

fn layout_impl(sch: Schematic<Unplaced>, pool: Option<&Strings>) -> Schematic<Placed> {
    let mut ir = sch.into_ir();
    let best = {
        let ctx = Ctx::build(&ir);
        let splines = extract_splines(&ctx);
        if verbose() || pool.is_some() {
            dump_pipeline(&ir, &ctx, &splines, pool);
        }
        best_order(&ctx, &splines)
    };
    if verbose() || pool.is_some() {
        dump_result(&ir, &best, pool);
    }
    ir.devices.orient = best.orient;
    Schematic::from_resolved(ir, best.physical)
}

pub fn place(ir: &Ir) -> Physical {
    let ctx = Ctx::build(ir);
    let splines = extract_splines(&ctx);
    best_order(&ctx, &splines).physical
}

fn name(_ir: &Ir, pool: Option<&Strings>, names: &[ir::StrId], idx: usize) -> String {
    pool.map(|p| p.get(names[idx]).to_string()).unwrap_or_else(|| format!("#{idx}"))
}

fn dev_name(ir: &Ir, pool: Option<&Strings>, d: ir::DeviceIdx) -> String {
    name(ir, pool, &ir.devices.name, d.index())
}

fn net_name(ir: &Ir, pool: Option<&Strings>, n: ir::NetIdx) -> String {
    name(ir, pool, &ir.nets.name, n.index())
}

fn dump_pipeline(ir: &Ir, ctx: &Ctx, splines: &[Spline], pool: Option<&Strings>) {
    eprintln!("╔══ BUILD PIPELINE ══════════════════════════════════════╗");

    // Legend
    eprintln!("│ devices ({}):", ctx.nd());
    for d in 0..ctx.nd() {
        let di = ir::DeviceIdx(d as u32);
        let role = ctx.role(di);
        eprintln!("│   d{d} = {} [{role:?}]", dev_name(ir, pool, di));
    }
    eprintln!("│ nets ({}):", ctx.nn());
    for n in 0..ctx.nn() {
        let ni = ir::NetIdx::from_index(n);
        let class = ctx.net_class(ni);
        let members: Vec<String> = ctx.members(ni).iter().map(|&p| {
            let d = ctx.dev_of(p);
            let role = ctx.role_of(p);
            format!("{}:{:?}", dev_name(ir, pool, d), role)
        }).collect();
        eprintln!("│   n{n} = {} [{class:?}] pins=[{}]", net_name(ir, pool, ni), members.join(", "));
    }

    // Splines
    eprintln!("├── splines ({}):", splines.len());
    for (i, s) in splines.iter().enumerate() {
        let chain: Vec<String> = s.iter().map(|&d| dev_name(ir, pool, d)).collect();
        eprintln!("│   spline[{i}]: {}", chain.join(" → "));
    }

    // Swappable pairs
    let swaps = swappable_pairs(ctx, splines);
    if !swaps.is_empty() {
        eprintln!("├── swappable pairs ({}):", swaps.len());
        for &(si, pi) in &swaps {
            eprintln!("│   spline[{si}] positions {pi}↔{}", pi + 1);
        }
    }

    // Column assignment (using default order)
    let cols = assign_columns(ctx, &splines.iter().collect::<Vec<_>>());
    let col_of = column_of(ctx, &cols);
    eprintln!("├── columns ({}):", cols.len());
    for (ci, c) in cols.iter().enumerate() {
        let devs: Vec<String> = c.devices.iter().map(|&d| dev_name(ir, pool, d)).collect();
        eprintln!("│   col[{ci}] {:?}: [{}]", c.kind, devs.join(", "));
    }

    // Net classification
    eprintln!("├── net classification:");
    for n in 0..ctx.nn() {
        let ni = ir::NetIdx::from_index(n);
        let cs = net_columns(ctx, ni, &col_of);
        if cs.is_empty() { continue; }
        let col_kinds: Vec<ColumnKind> = cols.iter().map(|c| c.kind).collect();
        let case = classify(&cs, &col_kinds);
        let class = ctx.net_class(ni);
        eprintln!("│   {} [{class:?}] → {case:?} (cols={cs:?})", net_name(ir, pool, ni));
    }
    eprintln!("╚════════════════════════════════════════════════════════╝");
}

fn dump_result(ir: &Ir, eval: &Evaluated, pool: Option<&Strings>) {
    eprintln!("╔══ BUILD RESULT ════════════════════════════════════════╗");
    eprintln!("│ columns: {}, metrics:", eval.n_columns);
    let m = &eval.metrics;
    eprintln!("│   labels={} fwd_margin={} body_hits={} crossings={} staples={} span={} margin_tracks={}",
        m.num_labels, m.num_forward_margin, m.num_body_hits, m.num_crossings, m.num_staples, m.total_span, m.margin_tracks);
    if !eval.fallbacks.is_empty() {
        eprintln!("├── fallbacks ({}):", eval.fallbacks.len());
        for (net, why) in &eval.fallbacks {
            eprintln!("│   ⚠ {} — {why}", net_name(ir, pool, *net));
        }
    }
    eprintln!("╚════════════════════════════════════════════════════════╝");
}

fn keep_best(best: &mut Option<Evaluated>, cand: Evaluated) {
    if best.as_ref().is_none_or(|b| cand.metrics.key() < b.metrics.key()) {
        *best = Some(cand);
    }
}

fn best_order(ctx: &Ctx, splines: &[Spline]) -> Evaluated {
    let swaps = swappable_pairs(ctx, splines);
    if swaps.is_empty() {
        return search_order(ctx, splines);
    }
    let mut best: Option<Evaluated> = None;
    for v in swap_variants(splines, &swaps) {
        keep_best(&mut best, search_order(ctx, &v));
    }
    best.unwrap_or_else(|| evaluate(ctx, &[]))
}

fn search_order(ctx: &Ctx, splines: &[Spline]) -> Evaluated {
    let mut best: Option<Evaluated> = None;
    if splines.len() <= config::cfg().layout.enum_limit {
        let mut idx: Vec<usize> = (0..splines.len()).collect();
        permute(&mut idx, 0, &mut |perm| {
            let order: Vec<&Spline> = perm.iter().map(|&i| &splines[i]).collect();
            let ev = evaluate(ctx, &order);
            if verbose() {
                let m = &ev.metrics;
                eprintln!("  perm {:?} → body={} stap={} span={} cross={} fwd={}",
                    perm, m.num_body_hits, m.num_staples, m.total_span,
                    m.num_crossings, m.num_forward_margin);
            }
            keep_best(&mut best, ev);
        });
    } else {
        for order_idx in greedy_orders(ctx, splines) {
            let order: Vec<&Spline> = order_idx.iter().map(|&i| &splines[i]).collect();
            keep_best(&mut best, evaluate(ctx, &order));
        }
    }
    best.unwrap_or_else(|| evaluate(ctx, &[]))
}

fn swap_variants(splines: &[Spline], pairs: &[(usize, usize)]) -> Vec<Vec<Spline>> {
    let n = pairs.len().min(8);
    (0..1u32 << n)
        .map(|mask| {
            let mut v = splines.to_vec();
            for (bit, &(si, pi)) in pairs[..n].iter().enumerate() {
                if mask & (1 << bit) != 0 {
                    v[si].swap(pi, pi + 1);
                }
            }
            v
        })
        .collect()
}

fn greedy_orders(ctx: &Ctx, splines: &[Spline]) -> Vec<Vec<usize>> {
    use std::collections::HashSet;
    let n = splines.len();
    let nets: Vec<HashSet<usize>> = splines
        .iter()
        .map(|s| {
            let mut ns = HashSet::new();
            for &d in s.iter() {
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
    (0..n)
        .map(|start| {
            let mut order = vec![start];
            let mut placed = vec![false; n];
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
            order
        })
        .collect()
}

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
