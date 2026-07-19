//! The class model: terminal/symbol roles and the [`DeviceClass`] record.

use crate::geom::{CELL_WIDTH, DrawOp, Pt, Rect};

/// Electrical role of a terminal. Drives the spine walk (conducting vs control) and any
/// builder-side symmetry handling.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum TerminalRole {
    #[default]
    Passive,
    // MOSFET / JFET
    Drain,
    Source,
    Gate,
    Bulk,
    // BJT / IGBT
    Collector,
    Base,
    Emitter,
    // Diodes
    Anode,
    Cathode,
}

impl TerminalRole {
    /// Does the spine current pass through this terminal? (Conducting vs control/body.)
    pub fn conducts(self) -> bool {
        use TerminalRole::*;
        matches!(
            self,
            Passive | Drain | Source | Collector | Emitter | Anode | Cathode
        )
    }
    /// Is this a control terminal (gate/base)?
    pub fn is_control(self) -> bool {
        matches!(self, TerminalRole::Gate | TerminalRole::Base)
    }
}

/// Placement role of a class's symbol. Rails/ports are what net classification scans for;
/// it is never inferred from a net's name.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum SymbolRole {
    #[default]
    None,
    PowerRail,
    GroundRail,
    InputPort,
    OutputPort,
    BidirPort,
    NetLabel,
}

/// One terminal of a class: name, electrical role, and canonical anchor point.
#[derive(Copy, Clone, Debug)]
pub struct Terminal {
    pub name: &'static str,
    pub role: TerminalRole,
    pub at: Pt,
}

/// A fully-defined device type. Pure data — all devices share the same placement algorithm.
#[derive(Copy, Clone, Debug)]
pub struct DeviceClass {
    pub name: &'static str,
    pub role: SymbolRole,
    pub terminals: &'static [Terminal],
    pub draw: &'static [DrawOp],
    /// SPICE reference-designator letter (`'R'`, `'M'`, …); `' '` for rails/ports.
    pub prefix: char,
    /// Default value string (`"1k"`, `"1u"`, …); empty if the device has no value.
    pub default_value: &'static str,
}

impl DeviceClass {
    /// Pin slot of the first terminal with this role (None if the class has no such role).
    pub fn term_slot(&self, role: TerminalRole) -> Option<usize> {
        self.terminals.iter().position(|t| t.role == role)
    }
    pub fn terminal_count(&self) -> usize {
        self.terminals.len()
    }

    /// Canonical bounding box: a fixed [`CELL_WIDTH`] in x (so all devices share one width),
    /// with the height derived from the terminals and draw primitives — never stored, so it
    /// can't drift from the geometry. Collision tests use this (oriented and translated by
    /// the placer). Cache it per placed device if it ever shows up hot.
    pub fn bbox(&self) -> Rect {
        // Width floors at CELL_WIDTH (uniform column pitch for the builtin
        // vocabulary) but grows to cover host classes whose runtime terminals
        // sit wider — the placer packs columns on per-column widths.
        let mut half = CELL_WIDTH / 2;
        let mut ymin = i32::MAX;
        let mut ymax = i32::MIN;
        let mut hit = |half: &mut i32, p: Pt| {
            *half = (*half).max(p.x.abs());
            ymin = ymin.min(p.y);
            ymax = ymax.max(p.y);
        };
        for t in self.terminals {
            hit(&mut half, t.at);
        }
        for op in self.draw {
            match *op {
                DrawOp::Line(a, b) => {
                    hit(&mut half, a);
                    hit(&mut half, b);
                }
                DrawOp::Polyline(pts) => {
                    for &p in pts {
                        hit(&mut half, p);
                    }
                }
                DrawOp::Circle { c, r } => {
                    hit(
                        &mut half,
                        Pt {
                            x: c.x - r,
                            y: c.y - r,
                        },
                    );
                    hit(
                        &mut half,
                        Pt {
                            x: c.x + r,
                            y: c.y + r,
                        },
                    );
                }
            }
        }
        Rect {
            min: Pt { x: -half, y: ymin },
            max: Pt { x: half, y: ymax },
        }
    }
}
