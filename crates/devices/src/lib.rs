//! Device vocabulary: data, not behavior. Every device walks the spine the same way, so
//! there is no per-device trait — only data tables that consumers parameterize on. A
//! device "class" (nmos, pmos, vdd, …) is a fully-defined [`DeviceClass`]: terminal roles
//! AND positions, a symbol body (draw primitives), and electrical data (SPICE refdes +
//! default value). The IR stores only an opaque index into [`CLASSES`]; this crate owns
//! what that index means.
//!
//! Geometry convention: canonical orientation, origin at the device centre, integer grid.
//! Default bipole spans 40 units along its lead axis (terminals at ±20). The emitter
//! orients/translates these canonical coordinates. Visually-identical CircuiTikZ variants
//! (american/european resistor, plain/cute inductor) share one family body until an SVG
//! renderer justifies bespoke glyphs.

mod bodies;
mod catalog;
mod class;
mod geom;
mod registry;

pub use catalog::{BY_NAME, CLASSES};
pub use class::{DeviceClass, SymbolRole, Terminal, TerminalRole};
pub use geom::{CELL_WIDTH, DrawOp, Pt, Rect};
pub use registry::{
    HostClass, class_at, class_of, install_anchor_overrides, install_host_classes, is_builtin,
    register_host_class,
};

#[cfg(test)]
mod tests {
    use super::*;

    // The hand-maintained PHF must stay in lockstep with CLASSES order.
    #[test]
    fn by_name_matches_classes() {
        for (name, &i) in BY_NAME.entries() {
            assert_eq!(CLASSES[i].name, *name, "PHF entry {name:?} -> wrong class");
        }
        assert_eq!(
            BY_NAME.len(),
            CLASSES.len(),
            "PHF and CLASSES diverged in length"
        );
    }

    // Every class is fully defined: terminals present with distinct positions, a non-empty
    // body, and a rail/port iff it carries a placement role.
    #[test]
    fn every_class_is_defined() {
        for cl in CLASSES {
            assert!(!cl.terminals.is_empty(), "{}: no terminals", cl.name);
            assert!(!cl.draw.is_empty(), "{}: no symbol body", cl.name);
            for (i, a) in cl.terminals.iter().enumerate() {
                for b in &cl.terminals[i + 1..] {
                    assert!(
                        a.at != b.at,
                        "{}: terminals {} and {} coincide",
                        cl.name,
                        a.name,
                        b.name
                    );
                }
            }
            // a placement role (rail/port) implies a single terminal; not the converse
            // (an antenna is single-terminal with no role).
            if cl.role != SymbolRole::None {
                assert_eq!(
                    cl.terminals.len(),
                    1,
                    "{}: rail/port must be single-terminal",
                    cl.name
                );
            }
        }
    }

    // Anchor overrides move terminal points (and thus bbox) without touching
    // names, roles, or other classes. One test only: the table installs once
    // per process.
    #[test]
    fn anchor_overrides_replace_terminals() {
        install_anchor_overrides(&[("res", &[Pt { x: 0, y: -30 }, Pt { x: 0, y: 30 }])]);
        let cl = class_at(class_of("res").unwrap());
        assert_eq!(cl.terminals[0].at, Pt { x: 0, y: -30 });
        assert_eq!(cl.terminals[1].at, Pt { x: 0, y: 30 });
        assert_eq!(cl.terminals[0].name, "a");
        assert_eq!(cl.bbox().max.y, 30);
        let cap = class_at(class_of("cap").unwrap());
        assert_eq!(
            cap.terminals[0].at,
            Pt { x: -20, y: 0 },
            "other classes untouched"
        );
    }

    #[test]
    fn bbox_encloses_geometry_and_collides() {
        let half = CELL_WIDTH / 2;
        for cl in CLASSES {
            let bb = cl.bbox();
            // the condition: every device is exactly CELL_WIDTH wide
            assert_eq!(bb.width(), CELL_WIDTH, "{}: width not uniform", cl.name);
            assert!(bb.height() >= 0, "{}: empty bbox", cl.name);
            for t in cl.terminals {
                assert!(
                    bb.min.y <= t.at.y && t.at.y <= bb.max.y,
                    "{}: terminal {} outside bbox in y",
                    cl.name,
                    t.name
                );
            }
            // guard: no glyph point may exceed the fixed cell in x, or the box would clip it
            for op in cl.draw {
                let xs: &[i32] = match op {
                    DrawOp::Line(a, b) => &[a.x, b.x],
                    DrawOp::Circle { c, r } => &[c.x - r, c.x + r],
                    DrawOp::Polyline(_) => &[],
                };
                for &x in xs {
                    assert!(
                        x.abs() <= half,
                        "{}: glyph x={x} exceeds cell ±{half}",
                        cl.name
                    );
                }
                if let DrawOp::Polyline(pts) = op {
                    for p in *pts {
                        assert!(
                            p.x.abs() <= half,
                            "{}: polyline x={} exceeds cell",
                            cl.name,
                            p.x
                        );
                    }
                }
            }
        }
        // collision predicate: disjoint vs overlapping
        let a = Rect {
            min: Pt { x: 0, y: 0 },
            max: Pt { x: 10, y: 10 },
        };
        let far = Rect {
            min: Pt { x: 20, y: 0 },
            max: Pt { x: 30, y: 10 },
        };
        let over = Rect {
            min: Pt { x: 5, y: 5 },
            max: Pt { x: 15, y: 15 },
        };
        assert!(!a.intersects(&far));
        assert!(a.intersects(&over));
    }

    // The condition: a device's conducting pins (drain/source, collector/emitter,
    // anode/cathode) sit on the same axis at the same x as a two-terminal bipole — so they
    // line up when packed. Checked against the resistor's terminal x-positions.
    #[test]
    fn conduction_terminals_align() {
        use TerminalRole::*;
        // Builtin table, not class_at: the anchor-override test may have
        // installed different geometry in this process.
        let res = &CLASSES[class_of("res").unwrap()];
        let edge: Vec<i32> = res.terminals.iter().map(|t| t.at.x).collect(); // [-20, 20]
        for cl in CLASSES {
            for t in cl.terminals {
                if matches!(
                    t.role,
                    Drain | Source | Collector | Emitter | Anode | Cathode
                ) {
                    assert_eq!(t.at.y, 0, "{}: {} off the conduction axis", cl.name, t.name);
                    assert!(
                        edge.contains(&t.at.x),
                        "{}: {} not at a bipole edge",
                        cl.name,
                        t.name
                    );
                }
            }
        }
    }

    // The condition, generalized to ALL devices: a multi-terminal device occupies both
    // conduction-axis edges (-20,0) and (20,0); a single-terminal device taps the origin;
    // every non-edge terminal is off the axis (y != 0). So any device lines up with any
    // other when packed.
    #[test]
    fn principal_terminals_on_axis() {
        let left = Pt { x: -20, y: 0 };
        let right = Pt { x: 20, y: 0 };
        let origin = Pt { x: 0, y: 0 };
        for cl in CLASSES {
            if cl.terminals.len() == 1 {
                assert_eq!(
                    cl.terminals[0].at, origin,
                    "{}: single tap off origin",
                    cl.name
                );
                continue;
            }
            assert!(
                cl.terminals.iter().any(|t| t.at == left)
                    && cl.terminals.iter().any(|t| t.at == right),
                "{}: missing a conduction-axis edge terminal",
                cl.name
            );
            for t in cl.terminals {
                if t.at != left && t.at != right {
                    assert_ne!(
                        t.at.y, 0,
                        "{}: aux terminal {} sits on the axis",
                        cl.name, t.name
                    );
                }
            }
        }
    }

    #[test]
    fn roles_and_electrical() {
        let nmos = class_at(class_of("nmos").unwrap());
        assert_eq!(nmos.term_slot(TerminalRole::Gate), Some(1));
        assert_eq!(nmos.prefix, 'M');
        let npn = class_at(class_of("npn").unwrap());
        assert_eq!(npn.term_slot(TerminalRole::Base), Some(1));
        assert!(TerminalRole::Collector.conducts() && !TerminalRole::Base.conducts());
        let res = class_at(class_of("res").unwrap());
        assert_eq!((res.prefix, res.default_value), ('R', "1k"));
        assert_eq!(
            class_at(class_of("vdd").unwrap()).role,
            SymbolRole::PowerRail
        );
    }
}
