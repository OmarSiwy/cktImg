//! Phase 0: structure extraction. Splines (VDD→GND conduction paths, §2.2), column
//! assignment (one column per spline; a device shared by two splines gets its own middle
//! column, §4.2 / Break C′), and per-net case classification (§Classify).

use crate::ctx::Ctx;
use ir::{DeviceIdx, NetIdx};
use std::collections::{HashMap, HashSet, VecDeque};

/// A conduction path VDD→GND, in conduction order (supply end first). §Def 1. A device may
/// appear on more than one spline — that is the shared-device / fan-node case (ARCH §Case 2).
pub type Spline = Vec<DeviceIdx>;

/// Hop-distance from each net to the nearest ground net, over conduction-device edges. A
/// device connects its two conducting nets; BFS from ground floods the conduction graph.
/// Unreachable nets stay `u32::MAX`. This orients "downward" for spline descent.
fn ground_distance(ctx: &Ctx) -> Vec<u32> {
    let mut gd = vec![u32::MAX; ctx.nn()];
    let mut q = VecDeque::new();
    for n in 0..ctx.nn() {
        let net = NetIdx::from_index(n);
        if ctx.is_ground(net) {
            gd[n] = 0;
            q.push_back(net);
        }
    }
    while let Some(n) = q.pop_front() {
        let dn = gd[n.index()];
        for &pin in ctx.members(n) {
            let d = ctx.dev_of(pin);
            if ctx.is_rail(d) || !ctx.conducts(pin) {
                continue;
            }
            for &q2 in ctx.conducting_pins(d) {
                if let Some(m) = ctx.net_of(q2) {
                    if m != n && gd[m.index()] == u32::MAX {
                        gd[m.index()] = dn + 1;
                        q.push_back(m);
                    }
                }
            }
        }
    }
    gd
}

/// Extract splines: each conducting device on a power net starts one branch, walked downward
/// to ground by decreasing ground-distance. Shared/tail devices (a fan node feeding N
/// branches) recur on every branch through them — the shared-column pass then lifts them out
/// (ARCH §Case 2). No single-claim, so branching conduction no longer collapses to a chain.
pub fn extract_splines(ctx: &Ctx) -> Vec<Spline> {
    let gd = ground_distance(ctx);
    let mut splines = Vec::new();
    for pnet in ctx.power_nets() {
        let mut starts: Vec<DeviceIdx> = ctx
            .members(pnet)
            .iter()
            .map(|&p| ctx.dev_of(p))
            .filter(|&d| !ctx.is_rail(d))
            .collect();
        starts.sort_by_key(|d| d.0);
        starts.dedup();
        for d in starts {
            let chain = walk_down(ctx, d, pnet, &gd);
            if !chain.is_empty() {
                splines.push(chain);
            }
        }
    }
    splines.sort_by_key(|s| s.iter().map(|d| d.0).min().unwrap_or(u32::MAX));
    splines
}

fn walk_down(ctx: &Ctx, start: DeviceIdx, power: NetIdx, gd: &[u32]) -> Spline {
    let mut chain = Vec::new();
    let mut dev = start;
    let mut from = power;
    let mut guard = 0;
    loop {
        chain.push(dev);
        guard += 1;
        if guard > ctx.nd() + 2 {
            break; // cycle backstop
        }
        let exit = ctx.conducting_pins(dev).iter().copied().find(|&p| ctx.net_of(p) != Some(from));
        let Some(ex) = exit else { break };
        let Some(nxt) = ctx.net_of(ex) else { break };
        if ctx.is_ground(nxt) {
            break;
        }
        // among devices on `nxt`, take the one whose far net is strictly closer to ground
        let here = gd[nxt.index()];
        let mut best: Option<(u32, DeviceIdx)> = None;
        for &pin in ctx.members(nxt) {
            let d2 = ctx.dev_of(pin);
            if d2 == dev || ctx.is_rail(d2) || !ctx.conducts(pin) {
                continue;
            }
            let far = ctx
                .conducting_pins(d2)
                .iter()
                .copied()
                .find(|&q| ctx.net_of(q) != Some(nxt))
                .and_then(|q| ctx.net_of(q));
            let fardist = far.map(|f| gd[f.index()]).unwrap_or(u32::MAX);
            if fardist >= here {
                continue; // would move away from ground
            }
            if best.is_none_or(|(bf, bd)| (fardist, d2.0) < (bf, bd.0)) {
                best = Some((fardist, d2));
            }
        }
        let Some((_, d2)) = best else { break };
        dev = d2;
        from = nxt;
    }
    chain
}

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum ColumnKind {
    Spline,
    /// A device on two splines, in its own middle column (§4.2 / Break C′ fan node).
    Shared,
    /// A passive bridge (bypass cap / compensation resistor) between two IMMEDIATE-neighbour
    /// signal nodes — its own column of horizontal devices between the bridged columns
    /// (ARCH §subcase D).
    Component,
    /// A bridge device inside a NON-immediate feedback loop (e.g. a nested Miller cap spanning
    /// ≥2 spline columns). It reserves no field width — it is positioned in the backward-route
    /// band (top margin) at the centre between its two node columns, and the two bridged nets
    /// route to its plates, splitting the feedback wire around it (ALGORITHM.md §Device inside
    /// a feedback loop, Non-immediate).
    Feedback,
    /// A conductor touching no rail — pass transistor / transmission gate (Break C).
    SignalSeries,
}

pub struct Column {
    pub kind: ColumnKind,
    pub devices: Vec<DeviceIdx>, // top → bottom (VDD → GND conduction order)
}

/// Branch count per device: how many splines pass through it (Tier-A precompute). A device is
/// shared (§Shared) iff its count ≥ 2 — N=2 gets its own column, N>2 anchors to its
/// span-minimising branch. Invariant across the order search: the spline *set* is fixed, only
/// its order varies.
pub fn branch_counts(ctx: &Ctx, order: &[&Spline]) -> Vec<u32> {
    let mut count = vec![0u32; ctx.nd()];
    for s in order {
        for &d in s.iter() {
            count[d.index()] += 1;
        }
    }
    count
}

/// Assign devices to columns for a given spline order. Spline columns first. A device shared by
/// exactly two branches is lifted into its own column placed right after its first spline (so it
/// lands BETWEEN them, §Shared N=2); a device shared by three+ branches stays on its
/// span-minimising anchor spline (§Shared N>2). Bridge passives go into a Component column
/// inserted between the two node columns they span; remaining non-rail conductors become
/// signal-series columns.
pub fn assign_columns(ctx: &Ctx, order: &[&Spline]) -> Vec<Column> {
    let count = branch_counts(ctx, order);
    // §Shared. A device on exactly two branches (N=2) gets its own middle column. A device on
    // three+ branches (N>2) stays on its span-minimising anchor — no new column — and the
    // other branches reach it via the fan bus (`route_fan`, keyed off branch count).
    let own_column = |d: DeviceIdx| count[d.index()] == 2;
    let anchored = |d: DeviceIdx| count[d.index()] >= 3;

    // N>2: pick anchor spline minimising sum(|anchor - branch|) over all branches
    let mut anchor_at: HashMap<u32, usize> = HashMap::new();
    for di in 0..ctx.nd() {
        let d = DeviceIdx(di as u32);
        if count[d.index()] < 3 {
            continue;
        }
        let idxs: Vec<usize> = order
            .iter()
            .enumerate()
            .filter(|(_, s)| s.contains(&d))
            .map(|(si, _)| si)
            .collect();
        let best = idxs
            .iter()
            .copied()
            .min_by_key(|&si| idxs.iter().map(|&sj| si.abs_diff(sj)).sum::<usize>())
            .unwrap_or(0);
        anchor_at.insert(d.0, best);
    }

    let mut cols = Vec::new();
    let mut shared_placed: HashSet<u32> = HashSet::new();
    for (si, s) in order.iter().enumerate() {
        let devices: Vec<DeviceIdx> = s
            .iter()
            .copied()
            .filter(|&d| {
                if own_column(d) {
                    false // lifted into its own Shared column
                } else if anchored(d) {
                    anchor_at.get(&d.0) == Some(&si)
                } else {
                    true
                }
            })
            .collect();
        cols.push(Column { kind: ColumnKind::Spline, devices });
        for &d in s.iter() {
            if own_column(d) && shared_placed.insert(d.0) {
                cols.push(Column { kind: ColumnKind::Shared, devices: vec![d] });
            }
        }
    }

    // classify leftovers: bridge passive → Component (between its two node columns);
    // everything else non-rail (pass transistors) → signal-series.
    let on_spline: HashSet<u32> = order.iter().flat_map(|s| s.iter().map(|d| d.0)).collect();
    let col_of_net = |net: NetIdx, cols: &[Column]| -> Option<usize> {
        for &p in ctx.members(net) {
            let d = ctx.dev_of(p);
            if let Some(ci) = cols.iter().position(|c| c.devices.contains(&d)) {
                return Some(ci);
            }
        }
        None
    };

    let mut inserts: Vec<(DeviceIdx, usize, ColumnKind)> = Vec::new(); // (device, index, kind)
    let mut series: Vec<DeviceIdx> = Vec::new();
    for i in 0..ctx.nd() {
        let d = DeviceIdx(i as u32);
        if ctx.is_rail(d) || on_spline.contains(&d.0) {
            continue;
        }
        let cps = ctx.conducting_pins(d);
        let is_bridge_passive = cps.len() == 2
            && cps.iter().all(|&p| ctx.role_of(p) == devices::TerminalRole::Passive);
        if is_bridge_passive {
            let a = ctx.net_of(cps[0]).and_then(|n| col_of_net(n, &cols));
            let b = ctx.net_of(cps[1]).and_then(|n| col_of_net(n, &cols));
            if let (Some(a), Some(b)) = (a, b) {
                // §"Device inside a feedback loop": a bridge whose two node columns are NON-
                // immediate (≥2 spline columns apart) is split into the backward-route band —
                // a zero-width Feedback column positioned in the margin. An immediate bridge
                // keeps its own field column (Component).
                let kind = if a.abs_diff(b) >= 2 { ColumnKind::Feedback } else { ColumnKind::Component };
                inserts.push((d, a.max(b), kind)); // insert just before the right column
                continue;
            }
        }
        series.push(d);
    }

    // insert high-index-first so earlier insertion indices stay valid
    inserts.sort_by_key(|&(_, ins, _)| std::cmp::Reverse(ins));
    for (d, ins, kind) in inserts {
        cols.insert(ins, Column { kind, devices: vec![d] });
    }
    for d in series {
        cols.push(Column { kind: ColumnKind::SignalSeries, devices: vec![d] });
    }
    cols
}

/// The routing case of a net, by the relationship between the columns it joins (§Classify).
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Case {
    WithinSpline,
    ImmediateNeighbor,
    SpanGe2,
}

/// Column membership map: device → column index (usize::MAX if unplaced, e.g. a rail).
pub fn column_of(ctx: &Ctx, cols: &[Column]) -> Vec<usize> {
    let mut m = vec![usize::MAX; ctx.nd()];
    for (ci, c) in cols.iter().enumerate() {
        for &d in &c.devices {
            m[d.index()] = ci;
        }
    }
    m
}

/// Distinct columns a net touches (rails excluded — they sit at column ends, not in the
/// column grid), sorted ascending.
pub fn net_columns(ctx: &Ctx, net: NetIdx, col_of: &[usize]) -> Vec<usize> {
    let mut cs: Vec<usize> = ctx
        .members(net)
        .iter()
        .map(|&p| col_of[ctx.dev_of(p).index()])
        .filter(|&c| c != usize::MAX)
        .collect();
    cs.sort_unstable();
    cs.dedup();
    cs
}

/// Adjacent devices in a spline that can be swapped without changing the circuit: same device
/// class (symbol) and same value (W/L). Returns `(spline_index, position_in_spline)` pairs.
/// Tier A: topology-invariant, computed once.
pub fn swappable_pairs(ctx: &Ctx, splines: &[Spline]) -> Vec<(usize, usize)> {
    let mut pairs = Vec::new();
    for (si, spline) in splines.iter().enumerate() {
        for i in 0..spline.len().saturating_sub(1) {
            let a = spline[i];
            let b = spline[i + 1];
            if ctx.ir.devices.symbol[a.index()] == ctx.ir.devices.symbol[b.index()]
                && ctx.ir.devices.value[a.index()] == ctx.ir.devices.value[b.index()]
            {
                pairs.push((si, i));
            }
        }
    }
    pairs
}

/// Spline-distance classification: Shared, Component, and Feedback columns are transparent —
/// two spines separated only by auxiliary columns are still immediate neighbors.
pub fn classify(net_cols: &[usize], col_kinds: &[ColumnKind]) -> Case {
    if net_cols.len() <= 1 {
        return Case::WithinSpline;
    }
    let lo = *net_cols.first().unwrap();
    let hi = *net_cols.last().unwrap();
    let spines_between = ((lo + 1)..hi)
        .filter(|&c| matches!(col_kinds[c], ColumnKind::Spline | ColumnKind::SignalSeries))
        .count();
    if spines_between == 0 {
        Case::ImmediateNeighbor
    } else {
        Case::SpanGe2
    }
}
