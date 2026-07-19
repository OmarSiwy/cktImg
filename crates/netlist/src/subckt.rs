//! Subckt handling: split definitions out of the line stream (phase 1), then emit every
//! top-level item into the [`IrBuilder`], flattening each instantiation recursively (phase 2).
//!
//! Flattening is pure renaming: a definition's formal ports map positionally to the actual nets
//! at the call site; every other net becomes `instancePrefix.net` so distinct instances never
//! collide; net `0` stays global ground. Device instance names are prefixed the same way.
//! Definitions may nest — a nested `.subckt` is lifted into the (flat) global table — and the
//! flattener recurses through nested *instantiation* too. Parameters flow down: a definition's
//! defaults, overridden by call-site `k=v` args, evaluated and used to resolve `{…}` brace
//! expressions in device value labels.

use crate::Report;
use crate::expr::{self, Scope};
use crate::lines::Logical;
use crate::parse::{
    Boundary, Elem, Inst, Item, boundary, classify, is_param_def, param_assignments,
};
use ir::{IrBuilder, Orientation, SymbolIdx};
use std::collections::{HashMap, HashSet};

/// Cap on instantiation nesting. A well-formed deck nests only a handful deep; hitting this
/// means a definition (transitively) instantiates itself.
const MAX_DEPTH: u32 = 64;

/// One subckt definition: formal ports, default parameters (raw expressions), and body lines.
pub struct Def {
    pub ports: Vec<String>,
    pub params: Vec<(String, String)>,
    pub body: Vec<Logical>,
}

/// All definitions, plus the name set the classifier consults to tell instance from device.
#[derive(Default)]
pub struct Defs {
    pub names: HashSet<String>, // lowercased
    pub map: HashMap<String, Def>,
}

struct Frame {
    name: String,
    ports: Vec<String>,
    params: Vec<(String, String)>,
    body: Vec<Logical>,
}

/// Phase 1: pull `.subckt`/`subckt … .ends`/`ends` blocks out of the stream. Returns the
/// top-level (non-body) lines and the definition table. Definitions may nest: a nested block is
/// captured against the inner frame and lifted into the flat global table on close (most decks
/// use globally-unique subckt names; this matches that and stays simple).
pub fn split(lines: Vec<Logical>, rep: &mut Report) -> (Vec<Logical>, Defs) {
    let mut top = Vec::new();
    let mut defs = Defs::default();
    let mut stack: Vec<Frame> = Vec::new();

    for l in lines {
        if let Some(b) = boundary(&l) {
            match b {
                Boundary::Begin {
                    name,
                    ports,
                    params,
                } => {
                    stack.push(Frame {
                        name: name.to_ascii_lowercase(),
                        ports,
                        params,
                        body: Vec::new(),
                    });
                }
                Boundary::End => match stack.pop() {
                    Some(f) => {
                        defs.names.insert(f.name.clone());
                        defs.map.insert(
                            f.name,
                            Def {
                                ports: f.ports,
                                params: f.params,
                                body: f.body,
                            },
                        );
                    }
                    None => rep.skip(&l, "unmatched .ends/ends"),
                },
            }
            continue;
        }
        match stack.last_mut() {
            Some(f) => f.body.push(l),
            None => top.push(l),
        }
    }
    for f in stack {
        rep.skip_owned(
            0,
            format!(".subckt {}", f.name),
            "unterminated subckt definition",
        );
    }
    (top, defs)
}

/// Renaming context for one flatten level. `port` resolves a formal port to the (already
/// outer-resolved) actual net; `prefix` is the dotted instance path applied to everything else.
struct Ctx {
    port: HashMap<String, String>,
    prefix: String,
}

fn rename_net(ctx: Option<&Ctx>, net: &str) -> String {
    match ctx {
        None => net.to_string(),
        Some(c) => c.port.get(net).cloned().unwrap_or_else(|| {
            if net == "0" {
                "0".to_string() // global ground is never scoped
            } else {
                format!("{}.{}", c.prefix, net)
            }
        }),
    }
}

fn rename_name(ctx: Option<&Ctx>, name: &str) -> String {
    match ctx {
        None => name.to_string(),
        Some(c) => format!("{}.{}", c.prefix, name),
    }
}

/// Phase 2: emit `top` (and, recursively, every instantiated body) into the builder, starting
/// from an empty global parameter scope that top-level `.param` lines fill in.
pub fn emit(
    top: &[Logical],
    defs: &Defs,
    models: &HashMap<String, String>,
    b: &mut IrBuilder,
    rep: &mut Report,
) {
    let mut scope = Scope::new();
    let mut out = Out {
        defs,
        models,
        b,
        rep,
    };
    emit_lines(top, None, &mut scope, 0, &mut out);
}

/// The read-only subckt table plus the two sinks, threaded through the
/// emit recursion as one unit.
struct Out<'a, 'i> {
    defs: &'a Defs,
    models: &'a HashMap<String, String>,
    b: &'a mut IrBuilder<'i>,
    rep: &'a mut Report,
}

fn emit_lines(lines: &[Logical], ctx: Option<&Ctx>, scope: &mut Scope, depth: u32, out: &mut Out) {
    for l in lines {
        // `.param`/`parameters` update the scope in source order; they are consumed, not reported.
        if is_param_def(l) {
            for (k, v) in param_assignments(l) {
                if let Some(x) = expr::eval(&v, scope) {
                    scope.insert(k, x);
                }
            }
            continue;
        }
        match classify(l, &out.defs.names, out.models) {
            Item::Elem(e) => emit_elem(&e, ctx, scope, out.b),
            Item::Inst(i) => emit_inst(&i, l, ctx, scope, depth, out),
            Item::Ignored(r) => {
                if depth == 0 {
                    out.rep.ignore(l, r);
                }
            }
            Item::Skipped(r) => out.rep.skip(l, r),
            Item::Blank => {}
        }
    }
}

fn emit_elem(e: &Elem, ctx: Option<&Ctx>, scope: &Scope, b: &mut IrBuilder) {
    let name = rename_name(ctx, &e.name);
    let value = expr::resolve_braces(&e.value, scope);
    let nodes: Vec<String> = e.nodes.iter().map(|n| rename_net(ctx, n)).collect();
    let pins: Vec<Option<&str>> = nodes.iter().map(|s| Some(s.as_str())).collect();
    b.device(
        &name,
        SymbolIdx(e.class as u32),
        &value,
        Orientation::default(),
        &pins,
    );
}

fn emit_inst(i: &Inst, l: &Logical, ctx: Option<&Ctx>, scope: &Scope, depth: u32, out: &mut Out) {
    if depth >= MAX_DEPTH {
        out.rep
            .skip(l, "subckt recursion too deep (cyclic instantiation?)");
        return;
    }
    let Some(def) = out.defs.map.get(&i.sub) else {
        out.rep.skip(l, "undefined subckt");
        return;
    };
    if i.nodes.len() != def.ports.len() {
        out.rep.skip(l, "subckt port count mismatch");
        return;
    }
    // Resolve actual nets through the current context first, so an inner port wired to an
    // outer-scoped net carries the full path down.
    let actual: Vec<String> = i.nodes.iter().map(|n| rename_net(ctx, n)).collect();
    let prefix = match ctx {
        None => i.name.clone(),
        Some(c) => format!("{}.{}", c.prefix, i.name),
    };
    let port: HashMap<String, String> = def.ports.iter().cloned().zip(actual).collect();
    let child_ctx = Ctx { port, prefix };

    // Child parameter scope: globals visible, then definition defaults (evaluated in the child
    // scope), then call-site overrides (evaluated in the PARENT scope, SPICE semantics).
    let mut child_scope = scope.clone();
    for (k, vexpr) in &def.params {
        if let Some(v) = expr::eval(vexpr, &child_scope) {
            child_scope.insert(k.clone(), v);
        }
    }
    for (k, vexpr) in &i.args {
        if let Some(v) = expr::eval(vexpr, scope) {
            child_scope.insert(k.clone(), v);
        }
    }

    emit_lines(
        &def.body,
        Some(&child_ctx),
        &mut child_scope,
        depth + 1,
        out,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lines::assemble;
    use ir::Interner;

    fn build(src: &str) -> (Interner, ir::Schematic<ir::Unplaced>, Report) {
        let mut interner = Interner::default();
        let mut rep = Report::default();
        let (top, defs) = split(assemble(src), &mut rep);
        let mut b = IrBuilder::new(&mut interner);
        emit(&top, &defs, &Default::default(), &mut b, &mut rep);
        let sch = b.finish();
        (interner, sch, rep)
    }

    fn nets_of(interner: &Interner, ir: &ir::Ir, d: usize) -> Vec<String> {
        ir.pins.net[ir.devices.pin_range(ir::DeviceIdx(d as u32))]
            .iter()
            .map(|n| {
                interner
                    .resolve(ir.nets.name[n.unwrap().index()])
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn flatten_renames_ports_and_internals() {
        let (interner, sch, rep) =
            build(".subckt inv in out\nM1 out in vss vss nmos\n.ends\nX1 a y inv\n");
        let ir = sch.ir();
        assert_eq!(ir.devices.len(), 1);
        assert_eq!(interner.resolve(ir.devices.name[0]), "x1.m1");
        assert_eq!(nets_of(&interner, ir, 0), ["y", "a", "x1.vss"]);
        assert!(
            rep.skipped.is_empty(),
            "unexpected skips: {:?}",
            rep.skipped
        );
    }

    #[test]
    fn nested_instantiation_paths_compose() {
        let (interner, sch, _) = build(
            ".subckt leaf p\nR1 p 0 1k\n.ends\n.subckt mid q\nXa q leaf\n.ends\nXtop net1 mid\n",
        );
        let ir = sch.ir();
        assert_eq!(ir.devices.len(), 1);
        assert_eq!(interner.resolve(ir.devices.name[0]), "xtop.xa.r1");
        assert_eq!(nets_of(&interner, ir, 0), ["net1", "0"]);
    }

    #[test]
    fn nested_definition_is_lifted_global() {
        // `cell` is defined INSIDE `top`; it must still be instantiable.
        let (interner, sch, rep) = build(
            ".subckt top a\n.subckt cell n\nR1 n 0 1k\n.ends\nXc a cell\n.ends\nXt net top\n",
        );
        let ir = sch.ir();
        assert_eq!(ir.devices.len(), 1);
        assert_eq!(interner.resolve(ir.devices.name[0]), "xt.xc.r1");
        assert!(
            rep.skipped.is_empty(),
            "unexpected skips: {:?}",
            rep.skipped
        );
    }

    #[test]
    fn parameters_flow_into_value_labels() {
        // global g=2; default W=1k overridden to 3k at the call site; R value = {W*g} = 6000.
        let (interner, sch, _) =
            build(".param g=2\n.subckt rload n W=1k\nR1 n 0 {W*g}\n.ends\nX1 a rload W=3k\n");
        let ir = sch.ir();
        assert_eq!(ir.devices.len(), 1);
        assert_eq!(interner.resolve(ir.devices.value[0]), "6000");
    }

    #[test]
    fn recursion_cap_reports_not_panics() {
        // self-instantiating subckt: must report a skip, never blow the stack.
        let (_i, _s, rep) = build(".subckt loop a\nX1 a loop\n.ends\nXt net loop\n");
        assert!(rep.skipped.iter().any(|n| n.reason.contains("too deep")));
    }
}
