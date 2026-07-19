//! spline extraction, column assignment, net case classification.

use crate::ctx::Ctx;
use ir::{DeviceIdx, NetIdx};
use std::collections::{HashMap, HashSet, VecDeque};

pub type Spline = Vec<DeviceIdx>;

#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum ColumnKind {
    Spline,
    Shared,
    Component,
    /// Non-immediate feedback bridge — zero-width, positioned in margin band.
    Feedback,
    /// Conductor touching no rail (pass transistor / transmission gate).
    SignalSeries,
}

pub struct Column {
    pub kind: ColumnKind,
    pub devices: Vec<DeviceIdx>,
}

impl Column {
    /// Feedback columns are margin-resident; everything else lives in the device field.
    pub fn in_field(&self) -> bool {
        self.kind != ColumnKind::Feedback
    }
}

/// How a net relates to the column order (drives its routing strategy).
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Case {
    WithinSpline,
    ImmediateNeighbor,
    SpanGe2,
}

// ── splines ─────────────────────────────────────────────────────────────────

/// Walk every VDD→GND conduction path. Shared/tail devices recur on every branch.
///
/// Circuits with no power net at all (source-driven passives: RC filters,
/// bridges) fall back to seeding from each independent source's hot nets —
/// the source IS the rail there, and without a seed every device would land
/// in the horizontal leftover pass instead of a vertical spline.
pub fn extract_splines(ctx: &Ctx) -> Vec<Spline> {
    let gd = ground_distance(ctx);
    let mut splines = Vec::new();
    let seed = |pnet: NetIdx, splines: &mut Vec<Spline>| {
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
    };
    for pnet in ctx.power_nets() {
        seed(pnet, &mut splines);
    }
    if splines.is_empty() {
        let mut hot = source_hot_nets(ctx);
        hot.sort_by_key(|n| n.index());
        hot.dedup();
        for n in hot {
            seed(n, &mut splines);
        }
    }
    splines.sort_by_key(|s| s.iter().map(|d| d.0).min().unwrap_or(u32::MAX));
    splines
}

/// Non-ground conduction nets of independent sources (SPICE prefix V/I).
fn source_hot_nets(ctx: &Ctx) -> Vec<NetIdx> {
    (0..ctx.nd())
        .map(|d| DeviceIdx(d as u32))
        .filter(|&d| !ctx.is_rail(d) && matches!(ctx.class(d).prefix, 'V' | 'I'))
        .flat_map(|d| ctx.conducting_pins(d).iter().copied())
        .filter_map(|p| ctx.net_of(p))
        .filter(|&n| !ctx.is_ground(n))
        .collect()
}

/// Follow conduction pins from `start` toward ground, always stepping to the
/// neighbour whose far net is strictly closer to ground.
fn walk_down(ctx: &Ctx, start: DeviceIdx, power: NetIdx, gd: &[u32]) -> Spline {
    let mut chain = Vec::new();
    let mut dev = start;
    let mut from = power;
    let mut guard = 0;
    loop {
        chain.push(dev);
        guard += 1;
        if guard > ctx.nd() + 2 {
            break;
        }
        let exit = ctx
            .conducting_pins(dev)
            .iter()
            .copied()
            .find(|&p| ctx.net_of(p) != Some(from));
        let Some(ex) = exit else { break };
        let Some(nxt) = ctx.net_of(ex) else { break };
        if ctx.is_ground(nxt) {
            break;
        }
        let here = gd[nxt.index()];
        let mut best: Option<(u32, DeviceIdx)> = None;
        let mut level: Option<DeviceIdx> = None;
        let mut level_count = 0usize;
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
            if fardist == here && !chain.contains(&d2) {
                level = Some(d2);
                level_count += 1;
            }
            if fardist >= here {
                continue;
            }
            if best.is_none_or(|(bf, bd)| (fardist, d2.0) < (bf, bd.0)) {
                best = Some((fardist, d2));
            }
        }
        // Plateau: when ground is reachable from BOTH ends of a passive
        // ladder (a source shortcuts the seed end), the watershed nets in
        // the middle tie on distance and strict descent stalls there. Cross
        // the plateau when there is exactly one unvisited continuation — a
        // plain series chain — so the whole ladder stays one spline.
        if best.is_none() && level_count == 1 {
            best = level.map(|d2| (here, d2));
        }
        let Some((_, d2)) = best else { break };
        dev = d2;
        from = nxt;
    }
    chain
}

/// BFS hop-distance from each net to the nearest ground net, over conduction edges.
fn ground_distance(ctx: &Ctx) -> Vec<u32> {
    let mut gd = vec![u32::MAX; ctx.nn()];
    let mut q = VecDeque::new();
    for (n, d) in gd.iter_mut().enumerate() {
        let net = NetIdx::from_index(n);
        if ctx.is_ground(net) {
            *d = 0;
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

// ── columns ─────────────────────────────────────────────────────────────────

/// N=2 shared → own column; N>2 → anchor on span-minimising branch.
pub fn assign_columns(ctx: &Ctx, order: &[&Spline]) -> Vec<Column> {
    let count = branch_counts(ctx, order);
    let own_column = |d: DeviceIdx| count[d.index()] == 2;
    let anchored = |d: DeviceIdx| count[d.index()] >= 3;

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
                    false
                } else if anchored(d) {
                    anchor_at.get(&d.0) == Some(&si)
                } else {
                    true
                }
            })
            .collect();
        cols.push(Column {
            kind: ColumnKind::Spline,
            devices,
        });
        for &d in s.iter() {
            if own_column(d) && shared_placed.insert(d.0) {
                cols.push(Column {
                    kind: ColumnKind::Shared,
                    devices: vec![d],
                });
            }
        }
    }

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

    let mut inserts: Vec<(Vec<DeviceIdx>, usize, ColumnKind)> = Vec::new();
    let mut satellites: HashMap<usize, Vec<DeviceIdx>> = HashMap::new();
    let mut series: Vec<DeviceIdx> = Vec::new();
    for i in 0..ctx.nd() {
        let d = DeviceIdx(i as u32);
        if ctx.is_rail(d) || on_spline.contains(&d.0) {
            continue;
        }
        let cps = ctx.conducting_pins(d);
        if cps.len() == 2 {
            // Rail nets never resolve to a column: "touches ground/power"
            // says nothing about horizontal position — col_of_net would pick
            // whichever rail-tied device happens to sit in a column, turning
            // grounded sources and divider bottom legs into cross-field
            // Feedback bridges parked in the margin band over the rail bus.
            // A rail-tied bipole hangs beside its signal column instead; the
            // rail pin drops to the bus.
            let rail = |n: NetIdx| ctx.net_class(n) != crate::ctx::NetClass::Signal;
            let col = |p| {
                ctx.net_of(p)
                    .filter(|&n| !rail(n))
                    .and_then(|n| col_of_net(n, &cols))
            };
            let rail_side = |p| ctx.net_of(p).is_some_and(rail);
            match (col(cps[0]), col(cps[1])) {
                (Some(a), Some(b)) if a == b => {
                    satellites.entry(a).or_default().push(d);
                    continue;
                }
                (Some(a), Some(b)) => {
                    let kind = if a.abs_diff(b) >= 3 {
                        ColumnKind::Feedback
                    } else {
                        ColumnKind::Component
                    };
                    inserts.push((vec![d], a.max(b), kind));
                    continue;
                }
                (Some(a), None) if rail_side(cps[1]) => {
                    satellites.entry(a).or_default().push(d);
                    continue;
                }
                (None, Some(b)) if rail_side(cps[0]) => {
                    satellites.entry(b).or_default().push(d);
                    continue;
                }
                _ => {}
            }
        }
        series.push(d);
    }

    // Merge base columns, satellites, and bridges by (anchor, rank) in one stable
    // sort instead of index-shifted inserts: a satellite sits right after its parent
    // column, a bridge just before the higher column it spans.
    let mut keyed: Vec<((usize, u8), Column)> = cols
        .into_iter()
        .enumerate()
        .map(|(i, c)| ((i, 0), c))
        .collect();
    for (parent, devices) in satellites {
        keyed.push((
            (parent, 1),
            Column {
                kind: ColumnKind::Component,
                devices,
            },
        ));
    }
    for (devices, ins, kind) in inserts {
        keyed.push(((ins - 1, 2), Column { kind, devices }));
    }
    keyed.sort_by(|(a, _), (b, _)| a.cmp(b));
    let mut cols: Vec<Column> = keyed.into_iter().map(|(_, c)| c).collect();

    // Group series devices that share the same set of ≥2 conducting nets
    // (antiparallel pass structures like transmission gates) into one column.
    let mut net_groups: HashMap<Vec<usize>, Vec<DeviceIdx>> = HashMap::new();
    for d in series {
        let mut nets: Vec<usize> = ctx
            .conducting_pins(d)
            .iter()
            .filter_map(|&p| ctx.net_of(p))
            .map(|n| n.index())
            .collect();
        nets.sort_unstable();
        nets.dedup();
        net_groups.entry(nets).or_default().push(d);
    }
    let mut groups: Vec<(Vec<usize>, Vec<DeviceIdx>)> = net_groups.into_iter().collect();
    groups.sort_by_key(|(_, devs)| devs.iter().map(|d| d.0).min().unwrap_or(u32::MAX));
    for (nets, devs) in groups {
        if nets.len() >= 2 && devs.len() >= 2 {
            cols.push(Column {
                kind: ColumnKind::SignalSeries,
                devices: devs,
            });
        } else {
            for d in devs {
                cols.push(Column {
                    kind: ColumnKind::SignalSeries,
                    devices: vec![d],
                });
            }
        }
    }
    cols
}

/// How many spline branches each device appears on (≥2 ⇒ shared).
pub fn branch_counts(ctx: &Ctx, order: &[&Spline]) -> Vec<u32> {
    let mut count = vec![0u32; ctx.nd()];
    for s in order {
        for &d in s.iter() {
            count[d.index()] += 1;
        }
    }
    count
}

/// Device index → column index (`usize::MAX` for rails / unplaced).
pub fn column_of(ctx: &Ctx, cols: &[Column]) -> Vec<usize> {
    let mut m = vec![usize::MAX; ctx.nd()];
    for (ci, c) in cols.iter().enumerate() {
        for &d in &c.devices {
            m[d.index()] = ci;
        }
    }
    m
}

/// Sorted, deduped column indices a net's pins touch.
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

// ── net classification ──────────────────────────────────────────────────────

/// Shared/Component/Feedback columns are transparent to spline distance.
pub fn classify(net_cols: &[usize], col_kinds: &[ColumnKind]) -> Case {
    if net_cols.len() <= 1 {
        return Case::WithinSpline;
    }
    let (lo, hi) = (*net_cols.first().unwrap(), *net_cols.last().unwrap());
    let spines_between = ((lo + 1)..hi)
        .filter(|&c| matches!(col_kinds[c], ColumnKind::Spline | ColumnKind::SignalSeries))
        .count();
    if spines_between == 0 {
        Case::ImmediateNeighbor
    } else {
        Case::SpanGe2
    }
}

/// Adjacent same-symbol, same-value spline positions whose order is free to flip.
pub fn swappable_pairs(ctx: &Ctx, splines: &[Spline]) -> Vec<(usize, usize)> {
    let mut pairs = Vec::new();
    for (si, spline) in splines.iter().enumerate() {
        for i in 0..spline.len().saturating_sub(1) {
            let (a, b) = (spline[i], spline[i + 1]);
            if ctx.ir.devices.symbol[a.index()] == ctx.ir.devices.symbol[b.index()]
                && ctx.ir.devices.value[a.index()] == ctx.ir.devices.value[b.index()]
            {
                pairs.push((si, i));
            }
        }
    }
    pairs
}
