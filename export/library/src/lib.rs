//! cktImg as a library: SPICE/netlist text in, schematic out.
//!
//! The pipeline is `parse -> place -> render`. The render step is whatever
//! function you hand it — a *backend* is just `Fn(&Ir, &Strings) -> String`.
//! [`backend::json`] already has that shape; so does any dumper you write
//! (xschem `.sch`, KiCad, SVG, …). Bring your own.
//!
//! ```ignore
//! let (out, report) = cktimg::run(spice, cktimg::backend::json);
//! ```

pub use build;
pub use config;
pub use devices;
pub use ir;
pub use netlist;

pub use ir::{Ir, Strings};
pub use netlist::Report;

/// A backend turns a placed IR + its string pool into a textual document
/// (JSON, xschem `.sch`, SVG, …). [`backend::json`] is one; write your own
/// with the same signature and pass it to [`run`].
pub trait Backend: Fn(&Ir, &Strings) -> String {}
impl<F: Fn(&Ir, &Strings) -> String> Backend for F {}

/// Parse → place → render with `backend`. Returns the rendered document and the
/// parse report (ignored/skipped lines). Panics-free parsing; placement is total.
///
/// The placer anchors its spines on explicit rail devices, but plain SPICE only
/// carries rail *nets* (`vdd`/`vcc` power, `gnd`/`vss`/`0` ground). If the
/// netlist names those nets and draws no rails, matching rail devices are
/// auto-inserted (they show up in the output as `xvdd`/`xgnd`/…).
pub fn run(src: &str, backend: impl Backend) -> (String, Report) {
    let (placed, it, report) = place(src);
    (backend(placed.ir(), it.pool()), report)
}

/// Parse → place, without rendering: the placed schematic, its string pool
/// (as the owning [`ir::Interner`]), and the parse report. [`run`] is this
/// plus one backend call; use `place` when you want the IR itself (e.g. to
/// build a [`json::Schematic`] and walk it from bindings).
pub fn place(src: &str) -> (ir::Schematic<ir::Placed>, ir::Interner, Report) {
    let mut it = ir::Interner::default();
    let (mut sch, mut report) = netlist::parse(src, &mut it);
    if let Some(rails) = missing_rails(sch.ir(), it.pool()) {
        it = ir::Interner::default();
        (sch, report) = netlist::parse(&format!("{src}\n{rails}"), &mut it);
    }
    (build::layout(sch), it, report)
}

/// Netlist lines instantiating the rail devices the parsed IR names as nets but
/// doesn't draw — `None` if nothing is missing. Same convention as the repo's
/// test fixtures: `XVDD vdd vdd` / `XGND gnd gnd`. Power names: vdd/vcc; ground:
/// gnd/vss/0. One rail per matched net; instance names dodge existing refdes.
fn missing_rails(ir: &Ir, s: &Strings) -> Option<String> {
    use devices::{SymbolRole, class_at};
    let has_role =
        |role| (0..ir.devices.len()).any(|d| class_at(ir.devices.symbol[d].index()).role == role);
    let nets_named = |names: &[&str]| -> Vec<String> {
        (0..ir.nets.len())
            .map(|n| s.get(ir.nets.name[n]))
            .filter(|net| names.iter().any(|m| net.eq_ignore_ascii_case(m)))
            .map(str::to_string)
            .collect()
    };
    // The parser lowercases refdes; match case-insensitively to be safe.
    let name_taken = |name: &str| {
        (0..ir.devices.len()).any(|d| s.get(ir.devices.name[d]).eq_ignore_ascii_case(name))
    };
    let fresh_name = |base: &str| {
        if !name_taken(base) {
            return base.to_string();
        }
        (2..) // X0 taken? try X0_2, X0_3, … — first free suffix wins
            .map(|i| format!("{base}_{i}"))
            .find(|n| !name_taken(n))
            .expect("unbounded suffix search always terminates")
    };

    let mut out = String::new();
    if !has_role(SymbolRole::PowerRail) {
        for net in nets_named(&["vdd", "vcc"]) {
            let inst = fresh_name(&format!("X{}", net.to_uppercase()));
            out.push_str(&format!("{inst} {net} vdd\n"));
        }
    }
    if !has_role(SymbolRole::GroundRail) {
        for net in nets_named(&["gnd", "vss", "0"]) {
            let base = if net == "0" {
                "XGND".to_string()
            } else {
                format!("X{}", net.to_uppercase())
            };
            let inst = fresh_name(&base);
            out.push_str(&format!("{inst} {net} gnd\n"));
        }
    }
    (!out.is_empty()).then_some(out)
}

pub mod backend {
    //! Built-in backends. Each is a plain `fn(&Ir, &Strings) -> String`.
    use super::*;

    /// A resolved, name-bearing JSON view of the placed schematic — the seam
    /// for tools that post-process geometry (e.g. SINA cleanup). All StrIds are
    /// resolved to strings; coordinates come from the physical layer.
    pub fn json(ir: &Ir, strings: &Strings) -> String {
        serde_json::to_string_pretty(&crate::json::Schematic::from_ir(ir, strings))
            .expect("JsonSchematic is plain data, serialization cannot fail")
    }
}

/// Resolved, serializable mirror of the IR — strings resolved, geometry flattened.
/// This is what the [`backend::json`] backend emits and what the Python bindings expose.
pub mod json {
    use crate::devices::class_at;
    use crate::ir::Ir;
    use crate::ir::Strings;
    use crate::ir::ids::NetIdx;

    #[derive(serde::Serialize)]
    pub struct Schematic {
        pub devices: Vec<Device>,
        pub nets: Vec<String>,
        pub wires: Vec<Wire>,
        pub junctions: Vec<[i32; 2]>,
    }

    /// A net's routed geometry: the trunk + stub polylines the router laid down.
    #[derive(serde::Serialize)]
    pub struct Wire {
        pub net: String,
        pub segments: Vec<Vec<[i32; 2]>>,
    }

    #[derive(serde::Serialize)]
    pub struct Device {
        pub name: String,
        pub class: String,
        pub value: String,
        pub rot: u8, // 0/90/180/270 → 0..=3
        pub mirror: bool,
        pub pos: Option<[i32; 2]>,
        pub pins: Vec<Pin>,
    }

    #[derive(serde::Serialize)]
    pub struct Pin {
        pub term: String,
        pub net: Option<String>,
        pub xy: Option<[i32; 2]>,
    }

    impl Schematic {
        pub fn from_ir(ir: &Ir, s: &Strings) -> Self {
            let phys = ir.physical.as_ref();
            let nets = ir.nets.name.iter().map(|&n| s.get(n).to_string()).collect();
            let junctions = phys
                .map(|p| p.junctions.iter().map(|j| [j.x, j.y]).collect())
                .unwrap_or_default();

            // Routed polylines per net (only nets that actually carry wire).
            let wires = phys
                .map(|p| {
                    (0..ir.nets.len())
                        .filter_map(|n| {
                            let segments: Vec<Vec<[i32; 2]>> = p
                                .segments(NetIdx::from_index(n))
                                .map(|seg| seg.iter().map(|q| [q.x, q.y]).collect())
                                .filter(|seg: &Vec<[i32; 2]>| seg.len() >= 2)
                                .collect();
                            (!segments.is_empty()).then(|| Wire {
                                net: s.get(ir.nets.name[n]).to_string(),
                                segments,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();

            let devices = (0..ir.devices.len())
                .map(|d| {
                    let class = class_at(ir.devices.symbol[d].index());
                    let orient = ir.devices.orient[d];
                    let pin_range = ir.devices.pin0[d].index()..ir.devices.pin0[d + 1].index();
                    let pins = pin_range
                        .clone()
                        .enumerate()
                        .map(|(slot, pi)| Pin {
                            term: class
                                .terminals
                                .get(slot)
                                .map(|t| t.name.to_string())
                                .unwrap_or_default(),
                            net: ir.pins.net[pi]
                                .map(|n| s.get(ir.nets.name[n.index()]).to_string()),
                            xy: phys.map(|p| {
                                let q = p.pin_xy[pi];
                                [q.x, q.y]
                            }),
                        })
                        .collect();
                    Device {
                        name: s.get(ir.devices.name[d]).to_string(),
                        class: class.name.to_string(),
                        value: s.get(ir.devices.value[d]).to_string(),
                        rot: orient.rot() as u8,
                        mirror: orient.mirror(),
                        pos: phys.map(|p| {
                            let q = p.pos[d];
                            [q.x, q.y]
                        }),
                        pins,
                    }
                })
                .collect();

            Schematic {
                devices,
                nets,
                wires,
                junctions,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    // Rail auto-insertion: vdd/vcc power, gnd/vss/0 ground, refdes-collision suffix.
    #[test]
    fn rails_auto_inserted() {
        let (json, _) = crate::run(
            "R1 vcc out 5k\nM1 out in vss nmos\nXVSS a b res\n",
            crate::backend::json,
        );
        for want in ["xvcc", "xvss_2", "\"vdd\"", "\"gnd\""] {
            assert!(json.contains(want), "missing {want} in:\n{json}");
        }
    }

    // Explicit rails are respected — nothing added.
    #[test]
    fn explicit_rails_untouched() {
        let (json, _) = crate::run(
            "R1 vdd out 5k\nM1 out in gnd nmos\nXP vdd vdd\nXG gnd gnd\n",
            crate::backend::json,
        );
        assert!(
            !json.contains("xvdd"),
            "no auto rail when one exists:\n{json}"
        );
        assert!(
            !json.contains("xgnd"),
            "no auto rail when one exists:\n{json}"
        );
    }
}
