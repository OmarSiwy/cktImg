//! Classify one logical line into an [`Item`]: a builtin device, a subckt instantiation, a
//! definition boundary, or a note (ignored-by-design / skipped-because-unrepresentable).
//!
//! NO device data is defined here. Every class decision routes through `devices::class_of`
//! (the single source of truth). The only local table is [`ALIAS`] — a *spelling* map from
//! foreign master names (`resistor`, `vcvs`, …) to builtin class names (`res`, `cvsource`),
//! because Spectre/SPICE spell primitives differently from the CircuiTikZ class set. That is
//! name translation, not a second device vocabulary.

use crate::lines::{Lang, Logical};
use devices::{class_at, class_of};
use std::collections::HashSet;

/// A builtin device ready to emit. `nodes` are exactly the class's `terminal_count`, already
/// in symbol slot order (SPICE node order equals slot order once bulk/substrate is dropped).
/// `value` may still contain `{…}` brace expressions; they are resolved against the parameter
/// scope at emit time.
pub struct Elem {
    pub name: String,
    pub class: usize, // index into devices::CLASSES
    pub value: String,
    pub nodes: Vec<String>,
}

/// A subckt instantiation, to be flattened. `sub` is lowercased for definition lookup; `args`
/// are the `k=v` parameter overrides passed at the call site (raw expressions).
pub struct Inst {
    pub name: String,
    pub sub: String,
    pub nodes: Vec<String>, // actual nets, positional to the definition's formal ports
    pub args: Vec<(String, String)>,
}

pub enum Item {
    Elem(Elem),
    Inst(Inst),
    Ignored(&'static str), // dropped by design: analysis, .model, .option, .include …
    Skipped(&'static str), // wanted to represent it but could not: unknown model, undefined sub …
    Blank,
}

/// A `.subckt`/`subckt` … `.ends`/`ends` boundary, recognized without the def table (phase 1
/// slices bodies before any class resolution). `Begin` carries formal ports and default
/// parameters (`name=expr` on the definition line).
pub enum Boundary {
    Begin {
        name: String,
        ports: Vec<String>,
        params: Vec<(String, String)>,
    },
    End,
}

/// Foreign master spelling -> builtin class name. NOT device definitions — a translation so a
/// Spectre/SPICE primitive name lands on the existing builtin. Unambiguous entries only;
/// polarity-ambiguous names (`bjt`, `mos`) are intentionally absent so they skip+report.
static ALIAS: phf::Map<&'static str, &'static str> = phf::phf_map! {
    "resistor"  => "res",
    "capacitor" => "cap",
    "inductor"  => "ind",
    "vsource"   => "vsource",
    "isource"   => "isource",
    "diode"     => "diode",
    // controlled sources (Spectre spellings) -> the builtin output-port symbol
    "vcvs"      => "cvsource",
    "vccs"      => "cisource",
    "cccs"      => "cisource",
    "ccvs"      => "cvsource",
    "relay"     => "switch",
    "switch"    => "switch",
};

/// Builtin class index for a master/model name (after alias translation). `None` = not a
/// builtin device.
fn resolve_class(name: &str) -> Option<usize> {
    let canon = ALIAS.get(name).copied().unwrap_or(name);
    class_of(canon)
}

fn is_param(tok: &str) -> bool {
    tok.contains('=')
}

/// Split a `k=v` token into a lowercased key and its raw value expression.
fn kv(tok: &str) -> Option<(String, String)> {
    let (k, v) = tok.split_once('=')?;
    if k.is_empty() {
        return None;
    }
    Some((k.to_ascii_lowercase(), v.to_string()))
}

/// All `k=v` parameters in a token slice.
fn params_of(toks: &[String]) -> Vec<(String, String)> {
    toks.iter().filter_map(|t| kv(t)).collect()
}

/// Look up one parameter value by (lowercased) key.
fn param_val<'a>(params: &'a [(String, String)], key: &str) -> Option<&'a str> {
    params
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
}

/// SPICE V/I source subtype from the function tokens after the nodes: `SIN(...)` -> sine,
/// a standalone `AC` -> ac, otherwise plain DC.
fn source_class(letter: char, after: &[String]) -> &'static str {
    let has_ac = after.iter().any(|t| t.eq_ignore_ascii_case("ac"));
    let sine = after
        .iter()
        .any(|t| t.to_ascii_lowercase().starts_with("sin"));
    match (letter, sine, has_ac) {
        ('v', true, _) => "vsourcesin",
        ('v', false, true) => "vsourceac",
        ('v', _, _) => "vsource",
        (_, _, true) => "isourceac",
        (_, _, _) => "isource",
    }
}

/// Detect a subckt definition boundary (phase-1 splitting; dialect-aware, def-table-free).
pub fn boundary(l: &Logical) -> Option<Boundary> {
    // ports = bare tokens (not k=v, not parens); params = the k=v tokens.
    let split = |from: usize| -> (Vec<String>, Vec<(String, String)>) {
        let toks = &l.toks[from..];
        let ports = toks
            .iter()
            .filter(|t| !is_param(t) && t.as_str() != "(" && t.as_str() != ")")
            .cloned()
            .collect();
        (ports, params_of(toks))
    };
    match l.lang {
        Lang::Spice => match l.head() {
            ".subckt" if l.toks.len() >= 2 => {
                let (ports, params) = split(2);
                Some(Boundary::Begin {
                    name: l.toks[1].clone(),
                    ports,
                    params,
                })
            }
            ".ends" => Some(Boundary::End),
            _ => None,
        },
        Lang::Spectre => {
            if l.head() == "subckt" && l.toks.len() >= 2 {
                let (ports, params) = split(2);
                Some(Boundary::Begin {
                    name: l.toks[1].clone(),
                    ports,
                    params,
                })
            } else if l.head() == "inline" && l.toks.get(1).map(String::as_str) == Some("subckt") {
                let (ports, params) = split(3);
                Some(Boundary::Begin {
                    name: l.toks.get(2).cloned().unwrap_or_default(),
                    ports,
                    params,
                })
            } else if l.head() == "ends" {
                Some(Boundary::End)
            } else {
                None
            }
        }
    }
}

/// Is this a parameter-definition statement (`.param a=1` / Spectre `parameters a=1`)? Handled
/// by the emitter (it updates the scope) rather than classified into a device.
pub fn is_param_def(l: &Logical) -> bool {
    matches!(
        (l.lang, l.head()),
        (Lang::Spice, ".param") | (Lang::Spectre, "parameters")
    )
}

/// The `k=v` assignments on a parameter-definition line (everything after the keyword).
pub fn param_assignments(l: &Logical) -> Vec<(String, String)> {
    params_of(l.toks.get(1..).unwrap_or(&[]))
}

/// Classify a non-boundary, non-param-def line into an [`Item`].
pub fn classify(l: &Logical, subs: &HashSet<String>) -> Item {
    if l.toks.is_empty() {
        return Item::Blank;
    }
    match l.lang {
        Lang::Spice => classify_spice(l, subs),
        Lang::Spectre => classify_spectre(l, subs),
    }
}

/// Build a 2-terminal device from the first two nodes of a line (controlled/behavioral sources,
/// switches): the symbol shows the output port; control nodes/gain ride along in `value`.
fn two_node(name: String, toks: &[String], class_name: &str, value: String) -> Item {
    if toks.len() < 3 {
        return Item::Skipped("malformed element: too few nodes");
    }
    Item::Elem(Elem {
        name,
        class: class_of(class_name).unwrap(),
        value,
        nodes: toks[1..3].to_vec(),
    })
}

fn classify_spice(l: &Logical, subs: &HashSet<String>) -> Item {
    let head = l.head();
    if head.starts_with('.') {
        return Item::Ignored("SPICE directive (analysis/model/option) ignored");
    }
    let letter = match head.chars().next() {
        Some(c) => c,
        None => return Item::Blank,
    };
    let name = head.to_string();
    let tail = |n: usize| -> String { l.toks.get(n..).unwrap_or(&[]).join(" ") };

    match letter {
        // passive two-terminals: 3rd token is the value (R/C/L); D ignores its model token.
        'r' | 'c' | 'l' | 'd' => {
            if l.toks.len() < 3 {
                return Item::Skipped("malformed element: too few nodes");
            }
            let class = match letter {
                'r' => "res",
                'c' => "cap",
                'l' => "ind",
                _ => "diode",
            };
            let value = match letter {
                'd' => String::new(),
                _ => l.toks[3..]
                    .iter()
                    .find(|t| !is_param(t))
                    .cloned()
                    .unwrap_or_default(),
            };
            Item::Elem(Elem {
                name,
                class: class_of(class).unwrap(),
                value,
                nodes: l.toks[1..3].to_vec(),
            })
        }
        // sources: subtype by waveform/AC; value = the source spec tail.
        'v' | 'i' => {
            if l.toks.len() < 3 {
                return Item::Skipped("malformed source: too few nodes");
            }
            let after = &l.toks[3..];
            let value = after
                .iter()
                .filter(|t| !is_param(t))
                .cloned()
                .collect::<Vec<_>>()
                .join(" ");
            Item::Elem(Elem {
                name,
                class: class_of(source_class(letter, after)).unwrap(),
                value,
                nodes: l.toks[1..3].to_vec(),
            })
        }
        // transistors: class from the model token, STRICT builtin; value summarizes W/L.
        'm' | 'q' | 'j' => {
            let tc = 3;
            if l.toks.len() < 1 + tc {
                return Item::Skipped("malformed transistor: too few nodes");
            }
            let nodes = l.toks[1..1 + tc].to_vec();
            let model = l.toks[1 + tc..]
                .iter()
                .find(|t| !is_param(t) && resolve_class(t).is_some());
            match model {
                Some(m) => {
                    let p = params_of(&l.toks[1 + tc..]);
                    let value = match (param_val(&p, "w"), param_val(&p, "l")) {
                        (Some(w), Some(l)) => format!("W={w}/L={l}"),
                        (Some(w), None) => format!("W={w}"),
                        _ => String::new(),
                    };
                    Item::Elem(Elem {
                        name,
                        class: resolve_class(m).unwrap(),
                        value,
                        nodes,
                    })
                }
                None => Item::Skipped("transistor model is not a builtin device"),
            }
        }
        // controlled & behavioral sources -> output-port symbol; tail (control nodes/gain) -> value.
        'e' => two_node(name, &l.toks, "cvsource", tail(3)), // VCVS
        'g' => two_node(name, &l.toks, "cisource", tail(3)), // VCCS
        'f' => two_node(name, &l.toks, "cisource", tail(3)), // CCCS
        'h' => two_node(name, &l.toks, "cvsource", tail(3)), // CCVS
        'b' => {
            // behavioral source: V=… -> voltage symbol, I=… -> current symbol
            let is_current = l
                .toks
                .iter()
                .any(|t| t.to_ascii_lowercase().starts_with("i="));
            two_node(
                name,
                &l.toks,
                if is_current { "isource" } else { "vsource" },
                tail(3),
            )
        }
        // switches: 2 output terminals; control nodes + model ride in value.
        's' | 'w' => two_node(name, &l.toks, "switch", tail(3)),
        'x' => classify_xinst(name, &l.toks[1..], subs),
        // inductor coupling has no symbol — a relationship, not a device.
        'k' => Item::Ignored("inductor coupling (no symbol)"),
        // transmission/MESFET/admittance lines have no builtin symbol yet.
        't' | 'o' | 'u' | 'z' | 'y' => Item::Skipped("element type has no builtin symbol"),
        _ => Item::Skipped("unsupported element type"),
    }
}

/// `X`/`subckt`-style instance: bare tokens are `[nodes…, master]`; `k=v` overrides follow.
fn classify_xinst(name: String, rest: &[String], subs: &HashSet<String>) -> Item {
    let bare: Vec<&String> = rest.iter().take_while(|t| !is_param(t)).collect();
    let args = params_of(rest);
    let (master, nodes) = match bare.split_last() {
        Some((m, ns)) => (m.as_str(), ns),
        None => return Item::Skipped("subckt instance: missing master name"),
    };
    let master_lc = master.to_ascii_lowercase();
    // builtin device (e.g. `Xo a b c opamp`, whose symbol prefix is 'X')
    if let Some(class) = resolve_class(&master_lc) {
        let tc = class_at(class).terminal_count();
        if nodes.len() < tc {
            return Item::Skipped("builtin instance: too few nodes");
        }
        let nodes = nodes[..tc].iter().map(|s| s.to_string()).collect();
        return Item::Elem(Elem {
            name,
            class,
            value: String::new(),
            nodes,
        });
    }
    if subs.contains(&master_lc) {
        return Item::Inst(Inst {
            name,
            sub: master_lc,
            nodes: nodes.iter().map(|s| s.to_string()).collect(),
            args,
        });
    }
    Item::Skipped("undefined subckt / unknown master")
}

fn classify_spectre(l: &Logical, subs: &HashSet<String>) -> Item {
    // Spectre element/instance form: `name ( n1 n2 … ) master params`.
    if l.toks.get(1).map(String::as_str) == Some("(") {
        let rparen = match l.toks.iter().position(|t| t == ")") {
            Some(i) => i,
            None => return Item::Skipped("malformed Spectre instance: unclosed '('"),
        };
        let name = l.toks[0].clone();
        let nodes: Vec<String> = l.toks[2..rparen].to_vec();
        let master = match l.toks.get(rparen + 1) {
            Some(m) => m,
            None => return Item::Skipped("Spectre instance: missing master"),
        };
        let master_lc = master.to_ascii_lowercase();
        let after = &l.toks[rparen + 2..];
        if let Some(class) = resolve_class(&master_lc) {
            let tc = class_at(class).terminal_count();
            if nodes.len() < tc {
                return Item::Skipped("Spectre builtin: too few nodes");
            }
            return Item::Elem(Elem {
                name,
                class,
                value: spectre_value(after),
                nodes: nodes[..tc].to_vec(),
            });
        }
        if subs.contains(&master_lc) {
            return Item::Inst(Inst {
                name,
                sub: master_lc,
                nodes,
                args: params_of(after),
            });
        }
        return Item::Skipped("Spectre master is neither builtin nor a defined subckt");
    }
    Item::Ignored("Spectre control statement (analysis/model/options) ignored")
}

/// Spectre passive value from `k=v` params (`r=`, `c=`, `l=`, `dc=`, `value=`), brace exprs
/// preserved for emit-time resolution.
fn spectre_value(params: &[String]) -> String {
    for p in params {
        if let Some((k, v)) = p.split_once('=') {
            if matches!(
                k.to_ascii_lowercase().as_str(),
                "r" | "c" | "l" | "dc" | "value"
            ) {
                return v.to_string();
            }
        }
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lines::assemble;

    fn one(src: &str, subs: &HashSet<String>) -> Item {
        let ls = assemble(src);
        classify(&ls[0], subs)
    }
    fn name_of(class: usize) -> &'static str {
        class_at(class).name
    }
    fn elem(it: Item) -> Elem {
        match it {
            Item::Elem(e) => e,
            _ => panic!("expected Elem"),
        }
    }

    #[test]
    fn spice_passive_and_value() {
        let subs = HashSet::new();
        let e = elem(one("R1 in out 4k7", &subs));
        assert_eq!(name_of(e.class), "res");
        assert_eq!(e.nodes, ["in", "out"]);
        assert_eq!(e.value, "4k7");
    }

    #[test]
    fn source_subtypes() {
        let subs = HashSet::new();
        assert_eq!(name_of(elem(one("V1 a 0 dc 5", &subs)).class), "vsource");
        assert_eq!(
            name_of(elem(one("V2 a 0 sin(0 1 1k)", &subs)).class),
            "vsourcesin"
        );
        assert_eq!(name_of(elem(one("V3 a 0 ac 1", &subs)).class), "vsourceac");
        assert_eq!(name_of(elem(one("I1 a 0 ac 1", &subs)).class), "isourceac");
    }

    #[test]
    fn spice_mosfet_strict_model_with_wl() {
        let subs = HashSet::new();
        let e = elem(one("M1 d g s b nmos w=1u l=0.1u", &subs));
        assert_eq!(name_of(e.class), "nmos");
        assert_eq!(e.nodes, ["d", "g", "s"]); // bulk dropped
        assert_eq!(e.value, "W=1u/L=0.1u");
        assert!(matches!(
            one("M2 d g s b nch_25 w=1u", &subs),
            Item::Skipped(_)
        ));
    }

    #[test]
    fn controlled_behavioral_switch() {
        let subs = HashSet::new();
        assert_eq!(
            name_of(elem(one("E1 outp outn inp inn 2.0", &subs)).class),
            "cvsource"
        );
        assert_eq!(
            name_of(elem(one("G1 outp outn inp inn 1m", &subs)).class),
            "cisource"
        );
        assert_eq!(
            name_of(elem(one("F1 outp outn vsense 10", &subs)).class),
            "cisource"
        );
        assert_eq!(
            name_of(elem(one("S1 a b cp cn smod", &subs)).class),
            "switch"
        );
        assert_eq!(
            name_of(elem(one("B1 a 0 v=v(b)*2", &subs)).class),
            "vsource"
        );
        assert_eq!(
            name_of(elem(one("B2 a 0 i=v(b)*2", &subs)).class),
            "isource"
        );
        // coupling ignored, transmission line skipped
        assert!(matches!(one("K1 L1 L2 0.9", &subs), Item::Ignored(_)));
        assert!(matches!(one("T1 a 0 b 0 z0=50", &subs), Item::Skipped(_)));
    }

    #[test]
    fn xinst_builtin_vs_subckt_vs_unknown() {
        let mut subs = HashSet::new();
        subs.insert("inv".to_string());
        assert!(matches!(one("Xo inp inn out opamp", &subs), Item::Elem(_)));
        match one("X1 a y inv W=2u", &subs) {
            Item::Inst(i) => {
                assert_eq!(i.sub, "inv");
                assert_eq!(i.nodes, ["a", "y"]);
                assert_eq!(i.args, [("w".to_string(), "2u".to_string())]);
            }
            _ => panic!("X1 should instantiate subckt inv"),
        }
        assert!(matches!(one("X2 a b nosuch", &subs), Item::Skipped(_)));
    }

    #[test]
    fn spectre_element_alias_and_controlled() {
        let subs = HashSet::new();
        let src = "simulator lang=spectre\nr1 (a b) resistor r=2k";
        let ls = assemble(src);
        let e = elem(classify(&ls[1], &subs));
        assert_eq!(name_of(e.class), "res");
        assert_eq!(e.value, "2k");

        let src2 = "simulator lang=spectre\ne1 (op on ip in) vcvs gain=2";
        let ls2 = assemble(src2);
        assert_eq!(name_of(elem(classify(&ls2[1], &subs)).class), "cvsource");
    }

    #[test]
    fn subckt_boundary_captures_ports_and_params() {
        let ls = assemble(".subckt inv in out vdd W=1u L=0.1u");
        match boundary(&ls[0]).unwrap() {
            Boundary::Begin {
                name,
                ports,
                params,
            } => {
                assert_eq!(name, "inv");
                assert_eq!(ports, ["in", "out", "vdd"]);
                assert_eq!(
                    params,
                    [("w".into(), "1u".into()), ("l".into(), "0.1u".into())]
                );
            }
            _ => panic!(),
        }
    }
}
