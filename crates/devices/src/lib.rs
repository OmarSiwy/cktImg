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

/// Integer grid point. Local to `devices` so the crate stays dependency-free; the renderer
/// converts to its own point type at the boundary.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
pub struct Pt {
    pub x: i32,
    pub y: i32,
}

/// A symbol body primitive, in canonical (unoriented) coordinates.
#[derive(Copy, Clone, Debug)]
pub enum DrawOp {
    Line(Pt, Pt),
    Polyline(&'static [Pt]),
    Circle { c: Pt, r: i32 },
}

/// Axis-aligned bounding box. Canonical-frame for a class; the placer applies orientation
/// and position before collision-testing two placed devices.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Rect {
    pub min: Pt,
    pub max: Pt,
}

/// Every device occupies the same canonical width, so they pack on a regular column pitch
/// and spacing/collision math stays uniform. Height varies per device; width never does.
pub const CELL_WIDTH: i32 = 40;

impl Rect {
    pub fn width(&self) -> i32 {
        self.max.x - self.min.x
    }
    pub fn height(&self) -> i32 {
        self.max.y - self.min.y
    }
    /// Do two boxes overlap? Touching edges count as overlap (conservative for collision).
    pub fn intersects(&self, o: &Rect) -> bool {
        self.min.x <= o.max.x
            && o.min.x <= self.max.x
            && self.min.y <= o.max.y
            && o.min.y <= self.max.y
    }
}

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
        matches!(self, Passive | Drain | Source | Collector | Emitter | Anode | Cathode)
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
        let half = CELL_WIDTH / 2;
        let mut ymin = i32::MAX;
        let mut ymax = i32::MIN;
        let mut hit = |y: i32| {
            ymin = ymin.min(y);
            ymax = ymax.max(y);
        };
        for t in self.terminals {
            hit(t.at.y);
        }
        for op in self.draw {
            match *op {
                DrawOp::Line(a, b) => {
                    hit(a.y);
                    hit(b.y);
                }
                DrawOp::Polyline(pts) => {
                    for &p in pts {
                        hit(p.y);
                    }
                }
                DrawOp::Circle { c, r } => {
                    hit(c.y - r);
                    hit(c.y + r);
                }
            }
        }
        Rect { min: Pt { x: -half, y: ymin }, max: Pt { x: half, y: ymax } }
    }
}

// ---- terse constructors ----
macro_rules! t {
    ($n:literal, $r:ident, $x:literal, $y:literal) => {
        Terminal { name: $n, role: TerminalRole::$r, at: Pt { x: $x, y: $y } }
    };
}
macro_rules! ln {
    ($x1:literal, $y1:literal, $x2:literal, $y2:literal) => {
        DrawOp::Line(Pt { x: $x1, y: $y1 }, Pt { x: $x2, y: $y2 })
    };
}
macro_rules! circ {
    ($x:literal, $y:literal, $r:literal) => {
        DrawOp::Circle { c: Pt { x: $x, y: $y }, r: $r }
    };
}
macro_rules! c {
    ($n:literal, $role:ident, $t:ident, $d:ident, $p:literal, $v:literal) => {
        DeviceClass {
            name: $n,
            role: SymbolRole::$role,
            terminals: $t,
            draw: $d,
            prefix: $p,
            default_value: $v,
        }
    };
}

// ---- terminal sets (positions), shared by classes with the same topology ----
// Transistors share the bipole conduction axis: the two conducting terminals at (±20, 0)
// (source left / drain right, emitter left / collector right), control terminal off-axis
// below at (0, -20). So a resistor's pins line up with a MOSFET's drain/source.
const MOS: &[Terminal] = &[t!("d", Drain, 20, 0), t!("g", Gate, 0, -20), t!("s", Source, -20, 0)];
const BJT: &[Terminal] =
    &[t!("c", Collector, 20, 0), t!("b", Base, 0, -20), t!("e", Emitter, -20, 0)];
const IGBT: &[Terminal] =
    &[t!("c", Collector, 20, 0), t!("g", Gate, 0, -20), t!("e", Emitter, -20, 0)];
const TWO: &[Terminal] = &[t!("a", Passive, -20, 0), t!("b", Passive, 20, 0)];
const ONE: &[Terminal] = &[t!("t", Passive, 0, 0)]; // single tap, on the axis
const DIODE: &[Terminal] = &[t!("a", Anode, -20, 0), t!("k", Cathode, 20, 0)];
const POT: &[Terminal] =
    &[t!("a", Passive, -20, 0), t!("b", Passive, 20, 0), t!("w", Passive, 0, 20)];
const TRIAC: &[Terminal] =
    &[t!("a", Passive, -20, 0), t!("b", Passive, 20, 0), t!("g", Gate, 0, -20)];
// in/pole on the left edge, primary throw/output on the right edge; extras off-axis below.
const SPDT: &[Terminal] =
    &[t!("in", Passive, -20, 0), t!("a", Passive, 20, 0), t!("b", Passive, 20, 20)];
const OPAMP: &[Terminal] =
    &[t!("in+", Passive, -20, 0), t!("out", Passive, 20, 0), t!("in-", Passive, -20, -12)];
const FDOPAMP: &[Terminal] = &[
    t!("in+", Passive, -20, 0),
    t!("out+", Passive, 20, 0),
    t!("in-", Passive, -20, -12),
    t!("out-", Passive, 20, -12),
];
const GATE2: &[Terminal] =
    &[t!("in1", Passive, -20, 0), t!("out", Passive, 20, 0), t!("in2", Passive, -20, -12)];
const GATE1: &[Terminal] = &[t!("in", Passive, -20, 0), t!("out", Passive, 20, 0)];
const XFMR: &[Terminal] = &[
    t!("l1", Passive, -20, 0),
    t!("r1", Passive, 20, 0),
    t!("l2", Passive, -20, -12),
    t!("r2", Passive, 20, -12),
];
const RAIL: &[Terminal] = &[t!("p", Passive, 0, 0)];

// ---- symbol bodies, shared per visual family ----
const DRAW_RES: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -10, y: 0 }, Pt { x: -8, y: 6 }, Pt { x: -4, y: -6 }, Pt { x: 0, y: 6 },
        Pt { x: 4, y: -6 }, Pt { x: 8, y: 6 }, Pt { x: 10, y: 0 },
    ]),
];
const DRAW_BOX: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
];
const DRAW_CAP: &[DrawOp] =
    &[ln!(-20, 0, -3, 0), ln!(3, 0, 20, 0), ln!(-3, -8, -3, 8), ln!(3, -8, 3, 8)];
const DRAW_IND: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0),
    circ!(-9, 0, 3), circ!(-3, 0, 3), circ!(3, 0, 3), circ!(9, 0, 3),
];
const DRAW_DIODE: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 8, 0), ln!(-8, 7, 8, 0), ln!(8, -7, 8, 7),
];
const DRAW_LED: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 8, 0), ln!(-8, 7, 8, 0), ln!(8, -7, 8, 7),
    ln!(2, 10, 8, 16), ln!(6, 10, 12, 16), // emission arrows
];
// ---- transistors ----
// Enhancement MOSFET: leads bend up to a 3-segment channel (broken line = enhancement), a
// solid gate plate parallel across the insulator gap. A bulk arrow on the source encodes
// polarity — nmos points into the channel, pmos out.
const DRAW_NMOS: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -4), ln!(8, 0, 8, -4),
    ln!(-8, -4, -3, -4), ln!(-2, -4, 2, -4), ln!(3, -4, 8, -4),
    ln!(-8, -9, 8, -9), ln!(0, -9, 0, -20),
    ln!(-8, -4, -11, -1), ln!(-8, -4, -5, -1), // bulk arrow into channel (n)
];
const DRAW_PMOS: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -4), ln!(8, 0, 8, -4),
    ln!(-8, -4, -3, -4), ln!(-2, -4, 2, -4), ln!(3, -4, 8, -4),
    ln!(-8, -9, 8, -9), ln!(0, -9, 0, -20),
    ln!(-8, 0, -11, -3), ln!(-8, 0, -5, -3), // bulk arrow out of channel (p)
];
// JFET: solid channel (no enhancement gaps), gate touches it through an arrow.
const DRAW_NJFET: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -5), ln!(8, 0, 8, -5), ln!(-8, -5, 8, -5),
    ln!(0, -20, 0, -5),
    ln!(0, -5, -3, -9), ln!(0, -5, 3, -9), // gate arrow into channel (n)
];
const DRAW_PJFET: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -5), ln!(8, 0, 8, -5), ln!(-8, -5, 8, -5),
    ln!(0, -20, 0, -5),
    ln!(0, -9, -3, -5), ln!(0, -9, 3, -5), // gate arrow out of channel (p)
];
// BJT: base bar, emitter/collector diagonals at staggered heights; emitter arrow points out
// for npn, in for pnp.
const DRAW_NPN: &[DrawOp] = &[
    ln!(0, -8, 0, 8), ln!(0, -8, 0, -20),
    ln!(-20, 0, -8, 0), ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0), ln!(8, 0, 0, -5),
    ln!(-8, 0, -5, 4), ln!(-8, 0, -3, 1), // emitter out-arrow (npn)
];
const DRAW_PNP: &[DrawOp] = &[
    ln!(0, -8, 0, 8), ln!(0, -8, 0, -20),
    ln!(-20, 0, -8, 0), ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0), ln!(8, 0, 0, -5),
    ln!(0, 5, -3, 4), ln!(0, 5, -1, 1), // emitter in-arrow (pnp)
];
// IGBT: BJT output (collector/emitter diagonals + arrow) driven by an insulated gate plate.
const DRAW_NIGBT: &[DrawOp] = &[
    ln!(0, -7, 0, 7),
    ln!(-20, 0, -8, 0), ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0), ln!(8, 0, 0, -5),
    ln!(-4, -7, -4, 7),
    DrawOp::Polyline(&[Pt { x: 0, y: -20 }, Pt { x: 0, y: -11 }, Pt { x: -4, y: -11 }, Pt { x: -4, y: -7 }]),
    ln!(8, 0, 5, 4), ln!(8, 0, 3, 1), // collector out-arrow (n)
];
const DRAW_PIGBT: &[DrawOp] = &[
    ln!(0, -7, 0, 7),
    ln!(-20, 0, -8, 0), ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0), ln!(8, 0, 0, -5),
    ln!(-4, -7, -4, 7),
    DrawOp::Polyline(&[Pt { x: 0, y: -20 }, Pt { x: 0, y: -11 }, Pt { x: -4, y: -11 }, Pt { x: -4, y: -7 }]),
    ln!(0, 5, -3, 4), ln!(0, 5, -1, 1), // emitter in-arrow (p)
];

// ---- diodes (anode left, cathode right; the cathode bar's shape names the variant) ----
const DRAW_SCHOTTKY: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 8, 0), ln!(-8, 7, 8, 0),
    DrawOp::Polyline(&[Pt { x: 11, y: -4 }, Pt { x: 11, y: -7 }, Pt { x: 8, y: -7 }, Pt { x: 8, y: 7 }, Pt { x: 5, y: 7 }, Pt { x: 5, y: 4 }]),
];
const DRAW_ZENER: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 8, 0), ln!(-8, 7, 8, 0),
    DrawOp::Polyline(&[Pt { x: 5, y: -7 }, Pt { x: 8, y: -7 }, Pt { x: 8, y: 7 }, Pt { x: 11, y: 7 }]),
];
const DRAW_TUNNEL: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 8, 0), ln!(-8, 7, 8, 0),
    DrawOp::Polyline(&[Pt { x: 5, y: -7 }, Pt { x: 8, y: -7 }, Pt { x: 8, y: 7 }, Pt { x: 5, y: 7 }]),
];
const DRAW_VARCAP: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(11, 0, 20, 0),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 8, 0), ln!(-8, 7, 8, 0),
    ln!(8, -7, 8, 7), ln!(11, -7, 11, 7), // cathode bar + varactor cap plate
];
const DRAW_TVS: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -7, -10, 7), ln!(-10, -7, 0, 0), ln!(-10, 7, 0, 0),
    ln!(10, -7, 10, 7), ln!(10, -7, 0, 0), ln!(10, 7, 0, 0),
    ln!(-10, -7, -13, -7), ln!(10, 7, 13, 7), // bent ends: back-to-back
];
const DRAW_PHOTODIODE: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 8, 0), ln!(-8, 7, 8, 0), ln!(8, -7, 8, 7),
    ln!(12, -16, 4, -8), ln!(4, -8, 7, -8), ln!(4, -8, 4, -11),   // incoming light 1
    ln!(16, -12, 8, -4), ln!(8, -4, 11, -4), ln!(8, -4, 8, -7),   // incoming light 2
];

// ---- sources & meters (circle body; inner glyph names the variant) ----
const DRAW_VSOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    ln!(-7, -2, -7, 2), ln!(-9, 0, -5, 0), ln!(5, 0, 9, 0), // + / -
];
const DRAW_VSOURCEAC: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -7, y: 0 }, Pt { x: -4, y: -5 }, Pt { x: 0, y: 0 }, Pt { x: 4, y: 5 }, Pt { x: 7, y: 0 }]),
];
const DRAW_ISOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    ln!(0, -6, 0, 6), ln!(-3, 3, 0, 6), ln!(3, 3, 0, 6), // up arrow
];
const DRAW_ISOURCEAC: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -7, y: 0 }, Pt { x: -4, y: -5 }, Pt { x: 0, y: 0 }, Pt { x: 4, y: 5 }, Pt { x: 7, y: 0 }]),
    ln!(12, 0, 9, -2), ln!(12, 0, 9, 2), // current-direction arrowhead on lead
];
const DRAW_CVSOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0),
    DrawOp::Polyline(&[Pt { x: -12, y: 0 }, Pt { x: 0, y: -12 }, Pt { x: 12, y: 0 }, Pt { x: 0, y: 12 }, Pt { x: -12, y: 0 }]),
    ln!(-7, -2, -7, 2), ln!(-9, 0, -5, 0), ln!(5, 0, 9, 0), // + / - (controlled = diamond)
];
const DRAW_CISOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0),
    DrawOp::Polyline(&[Pt { x: -12, y: 0 }, Pt { x: 0, y: -12 }, Pt { x: 12, y: 0 }, Pt { x: 0, y: 12 }, Pt { x: -12, y: 0 }]),
    ln!(0, 6, 0, -6), ln!(-3, -3, 0, -6), ln!(3, -3, 0, -6), // up arrow
];
const DRAW_AMMETER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -4, y: 5 }, Pt { x: 0, y: -5 }, Pt { x: 4, y: 5 }]), ln!(-2, 1, 2, 1), // A
];
const DRAW_VOLTMETER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -4, y: -5 }, Pt { x: 0, y: 5 }, Pt { x: 4, y: -5 }]), // V
];
const DRAW_OHMMETER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -5, y: 5 }, Pt { x: -3, y: 5 }, Pt { x: -4, y: 1 }, Pt { x: -2, y: -4 }, Pt { x: 2, y: -4 }, Pt { x: 4, y: 1 }, Pt { x: 3, y: 5 }, Pt { x: 5, y: 5 }]), // Ω
];
const DRAW_MOTOR: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -4, y: 5 }, Pt { x: -4, y: -5 }, Pt { x: 0, y: 0 }, Pt { x: 4, y: -5 }, Pt { x: 4, y: 5 }]), // M
];
const DRAW_LAMP: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0), circ!(0, 0, 12),
    ln!(-8, -8, 8, 8), ln!(-8, 8, 8, -8), // X
];

// ---- box-derived passives (rectangle + a distinguishing mark) ----
const DRAW_FUSE: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    ln!(-10, 0, 10, 0), // filament
];
const DRAW_VARISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    ln!(-11, 9, 11, -9), ln!(11, -9, 6, -8), ln!(11, -9, 8, -3), // voltage-dependent arrow
];
const DRAW_THERMISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[Pt { x: -11, y: 9 }, Pt { x: -7, y: 9 }, Pt { x: 11, y: -9 }]), // t° line + foot
];
const DRAW_THERMISTORPTC: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[Pt { x: -11, y: 9 }, Pt { x: -7, y: 9 }, Pt { x: 11, y: -9 }]),
    ln!(4, -9, 8, -9), ln!(6, -11, 6, -7), // +t°
];
const DRAW_THERMISTORNTC: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[Pt { x: -11, y: 9 }, Pt { x: -7, y: 9 }, Pt { x: 11, y: -9 }]),
    ln!(4, -9, 8, -9), // -t°
];
const DRAW_PHOTORESISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    ln!(14, -15, 6, -7), ln!(6, -7, 9, -7), ln!(6, -7, 6, -10),   // light in 1
    ln!(18, -11, 10, -3), ln!(10, -3, 13, -3), ln!(10, -3, 10, -6), // light in 2
];
const DRAW_CRYSTAL: &[DrawOp] = &[
    ln!(-20, 0, -7, 0), ln!(7, 0, 20, 0),
    ln!(-7, -7, -7, 7), ln!(7, -7, 7, 7), // electrode plates
    ln!(-4, -6, 4, -6), ln!(4, -6, 4, 6), ln!(4, 6, -4, 6), ln!(-4, 6, -4, -6), // resonator
];
const DRAW_MEMRISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[Pt { x: -8, y: 6 }, Pt { x: -8, y: -6 }, Pt { x: -3, y: 6 }, Pt { x: -3, y: -6 }, Pt { x: 2, y: 6 }, Pt { x: 2, y: -6 }]),
    ln!(5, 6, 5, -6), ln!(5, 6, 9, -6), ln!(5, 0, 9, -6), ln!(5, -6, 9, -6), // filled cell
];
const DRAW_LOUDSPEAKER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(8, 0, 20, 0),
    ln!(-12, -5, -6, -5), ln!(-6, -5, -6, 5), ln!(-6, 5, -12, 5), ln!(-12, 5, -12, -5), // magnet
    ln!(-6, -5, 8, -11), ln!(8, -11, 8, 11), ln!(8, 11, -6, 5), // cone
];
const DRAW_MICROPHONE: &[DrawOp] = &[
    ln!(-20, 0, -6, 0), ln!(6, 0, 20, 0),
    circ!(0, 0, 6), ln!(6, -7, 6, 7), // capsule + diaphragm
];
const DRAW_BUZZER: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0), ln!(-10, 6, 10, 6),
    DrawOp::Polyline(&[Pt { x: -10, y: 6 }, Pt { x: -9, y: -3 }, Pt { x: -5, y: -9 }, Pt { x: 0, y: -11 }, Pt { x: 5, y: -9 }, Pt { x: 9, y: -3 }, Pt { x: 10, y: 6 }]), // dome
];

// ---- polarized / variable cap & inductor ----
const DRAW_ECAP: &[DrawOp] = &[
    ln!(-20, 0, -3, 0), ln!(4, 0, 20, 0),
    ln!(-3, -8, -3, 8), // + plate (straight)
    DrawOp::Polyline(&[Pt { x: 7, y: -8 }, Pt { x: 4, y: -4 }, Pt { x: 3, y: 0 }, Pt { x: 4, y: 4 }, Pt { x: 7, y: 8 }]), // - plate (curved)
    ln!(-9, -8, -5, -8), ln!(-7, -10, -7, -6), // + mark
];
const DRAW_VCAP: &[DrawOp] = &[
    ln!(-20, 0, -3, 0), ln!(3, 0, 20, 0), ln!(-3, -8, -3, 8), ln!(3, -8, 3, 8),
    ln!(-9, 9, 9, -9), ln!(9, -9, 4, -8), ln!(9, -9, 6, -3), // tuning arrow
];
const DRAW_VIND: &[DrawOp] = &[
    ln!(-20, 0, -12, 0), ln!(12, 0, 20, 0),
    circ!(-9, 0, 3), circ!(-3, 0, 3), circ!(3, 0, 3), circ!(9, 0, 3),
    ln!(-11, 9, 11, -9), ln!(11, -9, 6, -8), ln!(11, -9, 8, -3), // tuning arrow
];

// ---- sources/labels & switches ----
const DRAW_BATTERY: &[DrawOp] = &[
    ln!(-20, 0, -4, 0), ln!(4, 0, 20, 0), ln!(-4, -10, -4, 10), ln!(4, -5, 4, 5),
];
// y is screen-down: GND sits at the bottom so its bars go DOWN (+y) from the pin; VDD sits
// at the top so its bar goes UP (-y).
const DRAW_GROUND: &[DrawOp] =
    &[ln!(0, 0, 0, 8), ln!(-10, 8, 10, 8), ln!(-6, 12, 6, 12), ln!(-2, 16, 2, 16)];
const DRAW_VDD: &[DrawOp] = &[ln!(0, 0, 0, -8), ln!(-8, -8, 8, -8)];
const DRAW_PORT: &[DrawOp] = &[ln!(0, 0, 6, 0), ln!(6, -5, 14, 0), ln!(14, 0, 6, 5), ln!(6, 5, 6, -5)];
const DRAW_SWITCH: &[DrawOp] =
    &[ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0), ln!(-8, 0, 6, 8), circ!(-8, 0, 1), circ!(8, 0, 1)];
const DRAW_NCSWITCH: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0), ln!(-8, 0, 9, -2), circ!(-8, 0, 1), circ!(8, 0, 1),
    ln!(9, -6, 9, 4), // normally-closed contact bar the lever bridges
];
const DRAW_PUSHBUTTON: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0), circ!(-8, 0, 1), circ!(8, 0, 1),
    ln!(-9, -6, 9, -6),               // floating contact
    ln!(0, -6, 0, -12), ln!(-5, -12, 5, -12), // plunger + button cap
];
const DRAW_SPDT: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0), ln!(8, 20, 20, 20),
    circ!(-8, 0, 1), circ!(8, 0, 1), circ!(8, 20, 1), ln!(-8, 0, 8, 6),
];
const DRAW_ANTENNA: &[DrawOp] = &[ln!(0, 0, 0, -12), ln!(-8, -20, 0, -12), ln!(8, -20, 0, -12)];
const DRAW_POT: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6), ln!(10, -6, 10, 6), ln!(10, 6, -10, 6), ln!(-10, 6, -10, -6),
    ln!(0, 20, 0, 8), ln!(-3, 11, 0, 8), ln!(3, 11, 0, 8), // wiper arrow
];
const DRAW_TRIAC: &[DrawOp] = &[
    ln!(-20, 0, -8, 0), ln!(8, 0, 20, 0), ln!(0, -20, 0, -6),
    ln!(-8, -7, -8, 7), ln!(-8, -7, 0, 0), ln!(-8, 7, 0, 0),
    ln!(8, -7, 8, 7), ln!(8, -7, 0, 0), ln!(8, 7, 0, 0),
];

// ---- amplifiers & logic gates (body centred on y=0; inputs jog from the terminal rows) ----
const DRAW_OPAMP: &[DrawOp] = &[
    ln!(-20, 0, -12, 6),    // in+ lead
    ln!(-20, -12, -12, -6), // in- lead
    ln!(12, 0, 20, 0),      // out lead
    ln!(-12, 12, -12, -12), ln!(-12, 12, 12, 0), ln!(-12, -12, 12, 0), // triangle
];
const DRAW_AND: &[DrawOp] = &[
    ln!(-20, 0, -10, 5), ln!(-20, -12, -10, -5), ln!(13, 0, 20, 0),
    ln!(-10, 12, -10, -12), ln!(-10, -12, 2, -12), ln!(-10, 12, 2, 12),
    DrawOp::Polyline(&[Pt { x: 2, y: -12 }, Pt { x: 9, y: -10 }, Pt { x: 12, y: -6 }, Pt { x: 13, y: 0 }, Pt { x: 12, y: 6 }, Pt { x: 9, y: 10 }, Pt { x: 2, y: 12 }]),
];
const DRAW_NAND: &[DrawOp] = &[
    ln!(-20, 0, -10, 5), ln!(-20, -12, -10, -5), ln!(17, 0, 20, 0),
    ln!(-10, 12, -10, -12), ln!(-10, -12, 2, -12), ln!(-10, 12, 2, 12),
    DrawOp::Polyline(&[Pt { x: 2, y: -12 }, Pt { x: 9, y: -10 }, Pt { x: 12, y: -6 }, Pt { x: 13, y: 0 }, Pt { x: 12, y: 6 }, Pt { x: 9, y: 10 }, Pt { x: 2, y: 12 }]),
    circ!(15, 0, 2),
];
const DRAW_OR: &[DrawOp] = &[
    ln!(-20, 0, -9, 4), ln!(-20, -12, -9, -4), ln!(13, 0, 20, 0),
    DrawOp::Polyline(&[Pt { x: -10, y: 12 }, Pt { x: -6, y: 0 }, Pt { x: -10, y: -12 }]),
    DrawOp::Polyline(&[Pt { x: -10, y: -12 }, Pt { x: 3, y: -11 }, Pt { x: 10, y: -6 }, Pt { x: 13, y: 0 }, Pt { x: 10, y: 6 }, Pt { x: 3, y: 11 }, Pt { x: -10, y: 12 }]),
];
const DRAW_NOR: &[DrawOp] = &[
    ln!(-20, 0, -9, 4), ln!(-20, -12, -9, -4), ln!(17, 0, 20, 0),
    DrawOp::Polyline(&[Pt { x: -10, y: 12 }, Pt { x: -6, y: 0 }, Pt { x: -10, y: -12 }]),
    DrawOp::Polyline(&[Pt { x: -10, y: -12 }, Pt { x: 3, y: -11 }, Pt { x: 10, y: -6 }, Pt { x: 13, y: 0 }, Pt { x: 10, y: 6 }, Pt { x: 3, y: 11 }, Pt { x: -10, y: 12 }]),
    circ!(15, 0, 2),
];
const DRAW_XOR: &[DrawOp] = &[
    ln!(-20, 0, -12, 4), ln!(-20, -12, -12, -4), ln!(13, 0, 20, 0),
    DrawOp::Polyline(&[Pt { x: -13, y: 12 }, Pt { x: -9, y: 0 }, Pt { x: -13, y: -12 }]), // extra back arc
    DrawOp::Polyline(&[Pt { x: -10, y: 12 }, Pt { x: -6, y: 0 }, Pt { x: -10, y: -12 }]),
    DrawOp::Polyline(&[Pt { x: -10, y: -12 }, Pt { x: 3, y: -11 }, Pt { x: 10, y: -6 }, Pt { x: 13, y: 0 }, Pt { x: 10, y: 6 }, Pt { x: 3, y: 11 }, Pt { x: -10, y: 12 }]),
];
const DRAW_XNOR: &[DrawOp] = &[
    ln!(-20, 0, -12, 4), ln!(-20, -12, -12, -4), ln!(17, 0, 20, 0),
    DrawOp::Polyline(&[Pt { x: -13, y: 12 }, Pt { x: -9, y: 0 }, Pt { x: -13, y: -12 }]),
    DrawOp::Polyline(&[Pt { x: -10, y: 12 }, Pt { x: -6, y: 0 }, Pt { x: -10, y: -12 }]),
    DrawOp::Polyline(&[Pt { x: -10, y: -12 }, Pt { x: 3, y: -11 }, Pt { x: 10, y: -6 }, Pt { x: 13, y: 0 }, Pt { x: 10, y: 6 }, Pt { x: 3, y: 11 }, Pt { x: -10, y: 12 }]),
    circ!(15, 0, 2),
];
const DRAW_NOT: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(14, 0, 20, 0),
    ln!(-10, -12, -10, 12), ln!(-10, 12, 10, 0), ln!(10, 0, -10, -12),
    circ!(12, 0, 2),
];
const DRAW_BUFFER: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(10, 0, 20, 0),
    ln!(-10, -12, -10, 12), ln!(-10, 12, 10, 0), ln!(10, 0, -10, -12),
];
const DRAW_XFMR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0), ln!(-20, -12, -10, -12), ln!(20, 0, 10, 0), ln!(20, -12, 10, -12),
    circ!(-8, -2, 5), circ!(-8, -10, 5), // left winding
    circ!(8, -2, 5), circ!(8, -10, 5),   // right winding
    ln!(-2, -18, -2, 6), ln!(2, -18, 2, 6), // core
];

/// The known device classes. The IR's `SymbolIdx` indexes this slice. Order is the contract
/// [`BY_NAME`] mirrors — the `by_name_matches_classes` test enforces alignment.
pub static CLASSES: &[DeviceClass] = &[
    // transistors
    c!("nmos", None, MOS, DRAW_NMOS, 'M', ""),   // 0
    c!("pmos", None, MOS, DRAW_PMOS, 'M', ""),   // 1
    c!("nfet", None, MOS, DRAW_NMOS, 'M', ""),   // 2
    c!("pfet", None, MOS, DRAW_PMOS, 'M', ""),   // 3
    c!("nfetd", None, MOS, DRAW_NMOS, 'M', ""),  // 4
    c!("pfetd", None, MOS, DRAW_PMOS, 'M', ""),  // 5
    c!("njfet", None, MOS, DRAW_NJFET, 'J', ""), // 6
    c!("pjfet", None, MOS, DRAW_PJFET, 'J', ""), // 7
    c!("npn", None, BJT, DRAW_NPN, 'Q', ""),     // 8
    c!("pnp", None, BJT, DRAW_PNP, 'Q', ""),     // 9
    c!("nigbt", None, IGBT, DRAW_NIGBT, 'Q', ""), // 10
    c!("pigbt", None, IGBT, DRAW_PIGBT, 'Q', ""), // 11
    // passive bipoles
    c!("res", None, TWO, DRAW_RES, 'R', "1k"),   // 12
    c!("generic", None, TWO, DRAW_BOX, 'R', ""), // 13
    c!("varistor", None, TWO, DRAW_VARISTOR, 'R', ""), // 14
    c!("potentiometer", None, POT, DRAW_POT, 'R', "10k"), // 15
    c!("thermistor", None, TWO, DRAW_THERMISTOR, 'R', ""), // 16
    c!("thermistorptc", None, TWO, DRAW_THERMISTORPTC, 'R', ""), // 17
    c!("thermistorntc", None, TWO, DRAW_THERMISTORNTC, 'R', ""), // 18
    c!("photoresistor", None, TWO, DRAW_PHOTORESISTOR, 'R', ""), // 19
    c!("cap", None, TWO, DRAW_CAP, 'C', "1u"),   // 20
    c!("ecap", None, TWO, DRAW_ECAP, 'C', "1u"), // 21
    c!("vcap", None, TWO, DRAW_VCAP, 'C', ""),   // 22
    c!("ind", None, TWO, DRAW_IND, 'L', "1m"),   // 23
    c!("cuteind", None, TWO, DRAW_IND, 'L', "1m"), // 24
    c!("vind", None, TWO, DRAW_VIND, 'L', ""),   // 25
    c!("fuse", None, TWO, DRAW_FUSE, 'F', ""),   // 26
    c!("lamp", None, TWO, DRAW_LAMP, 'X', ""),   // 27
    c!("crystal", None, TWO, DRAW_CRYSTAL, 'X', ""), // 28
    c!("memristor", None, TWO, DRAW_MEMRISTOR, 'R', ""), // 29
    // diodes
    c!("diode", None, DIODE, DRAW_DIODE, 'D', ""), // 30
    c!("schottky", None, DIODE, DRAW_SCHOTTKY, 'D', ""), // 31
    c!("zener", None, DIODE, DRAW_ZENER, 'D', ""), // 32
    c!("tunneldiode", None, DIODE, DRAW_TUNNEL, 'D', ""), // 33
    c!("led", None, DIODE, DRAW_LED, 'D', ""),   // 34
    c!("photodiode", None, DIODE, DRAW_PHOTODIODE, 'D', ""), // 35
    c!("varcap", None, DIODE, DRAW_VARCAP, 'D', ""), // 36
    c!("tvsdiode", None, DIODE, DRAW_TVS, 'D', ""), // 37
    c!("diac", None, TWO, DRAW_TRIAC, 'D', ""),  // 38
    c!("triac", None, TRIAC, DRAW_TRIAC, 'X', ""), // 39
    // sources & meters
    c!("battery", None, TWO, DRAW_BATTERY, 'V', "9"), // 40
    c!("vsource", None, TWO, DRAW_VSOURCE, 'V', ""), // 41
    c!("isource", None, TWO, DRAW_ISOURCE, 'I', ""), // 42
    c!("vsourceac", None, TWO, DRAW_VSOURCEAC, 'V', ""), // 43
    c!("isourceac", None, TWO, DRAW_ISOURCEAC, 'I', ""), // 44
    c!("vsourcesin", None, TWO, DRAW_VSOURCEAC, 'V', ""), // 45
    c!("cvsource", None, TWO, DRAW_CVSOURCE, 'E', ""), // 46
    c!("cisource", None, TWO, DRAW_CISOURCE, 'G', ""), // 47
    c!("ammeter", None, TWO, DRAW_AMMETER, 'X', ""), // 48
    c!("voltmeter", None, TWO, DRAW_VOLTMETER, 'X', ""), // 49
    c!("ohmmeter", None, TWO, DRAW_OHMMETER, 'X', ""), // 50
    // switches
    c!("switch", None, TWO, DRAW_SWITCH, 'S', ""), // 51
    c!("noswitch", None, TWO, DRAW_SWITCH, 'S', ""), // 52
    c!("ncswitch", None, TWO, DRAW_NCSWITCH, 'S', ""), // 53
    c!("pushbutton", None, TWO, DRAW_PUSHBUTTON, 'S', ""), // 54
    c!("spdt", None, SPDT, DRAW_SPDT, 'S', ""),  // 55
    // amplifiers
    c!("opamp", None, OPAMP, DRAW_OPAMP, 'X', ""), // 56
    c!("fdopamp", None, FDOPAMP, DRAW_OPAMP, 'X', ""), // 57
    c!("transconductor", None, OPAMP, DRAW_OPAMP, 'X', ""), // 58
    // logic gates
    c!("andgate", None, GATE2, DRAW_AND, 'X', ""), // 59
    c!("orgate", None, GATE2, DRAW_OR, 'X', ""), // 60
    c!("notgate", None, GATE1, DRAW_NOT, 'X', ""), // 61
    c!("nandgate", None, GATE2, DRAW_NAND, 'X', ""), // 62
    c!("norgate", None, GATE2, DRAW_NOR, 'X', ""), // 63
    c!("xorgate", None, GATE2, DRAW_XOR, 'X', ""), // 64
    c!("xnorgate", None, GATE2, DRAW_XNOR, 'X', ""), // 65
    c!("buffergate", None, GATE1, DRAW_BUFFER, 'X', ""), // 66
    // transducers / misc
    c!("antenna", None, ONE, DRAW_ANTENNA, 'X', ""), // 67
    c!("loudspeaker", None, TWO, DRAW_LOUDSPEAKER, 'X', ""), // 68
    c!("microphone", None, TWO, DRAW_MICROPHONE, 'X', ""), // 69
    c!("motor", None, TWO, DRAW_MOTOR, 'X', ""), // 70
    c!("buzzer", None, TWO, DRAW_BUZZER, 'X', ""),  // 71
    c!("transformer", None, XFMR, DRAW_XFMR, 'X', ""), // 72
    // rails / supplies (carry a placement role; net classification scans for these)
    c!("vdd", PowerRail, RAIL, DRAW_VDD, ' ', ""), // 73
    c!("vcc", PowerRail, RAIL, DRAW_VDD, ' ', ""), // 74
    c!("gnd", GroundRail, RAIL, DRAW_GROUND, ' ', ""), // 75
    c!("ground", GroundRail, RAIL, DRAW_GROUND, ' ', ""), // 76
    c!("vss", GroundRail, RAIL, DRAW_GROUND, ' ', ""), // 77
    c!("vee", GroundRail, RAIL, DRAW_GROUND, ' ', ""), // 78
    // ports (single terminal; carry a placement role for boundary placement)
    c!("ipin", InputPort, RAIL, DRAW_PORT, ' ', ""), // 79
    c!("opin", OutputPort, RAIL, DRAW_PORT, ' ', ""), // 80
    c!("iopin", BidirPort, RAIL, DRAW_PORT, ' ', ""), // 81
];

/// Compile-time perfect hash: class name -> index into [`CLASSES`]. No runtime hashing, no
/// HashMap — the class set is fixed and known at build time.
pub static BY_NAME: phf::Map<&'static str, usize> = phf::phf_map! {
    "nmos" => 0, "pmos" => 1, "nfet" => 2, "pfet" => 3, "nfetd" => 4, "pfetd" => 5,
    "njfet" => 6, "pjfet" => 7, "npn" => 8, "pnp" => 9, "nigbt" => 10, "pigbt" => 11,
    "res" => 12, "generic" => 13, "varistor" => 14, "potentiometer" => 15,
    "thermistor" => 16, "thermistorptc" => 17, "thermistorntc" => 18, "photoresistor" => 19,
    "cap" => 20, "ecap" => 21, "vcap" => 22, "ind" => 23, "cuteind" => 24, "vind" => 25,
    "fuse" => 26, "lamp" => 27, "crystal" => 28, "memristor" => 29,
    "diode" => 30, "schottky" => 31, "zener" => 32, "tunneldiode" => 33, "led" => 34,
    "photodiode" => 35, "varcap" => 36, "tvsdiode" => 37, "diac" => 38, "triac" => 39,
    "battery" => 40, "vsource" => 41, "isource" => 42, "vsourceac" => 43, "isourceac" => 44,
    "vsourcesin" => 45, "cvsource" => 46, "cisource" => 47,
    "ammeter" => 48, "voltmeter" => 49, "ohmmeter" => 50,
    "switch" => 51, "noswitch" => 52, "ncswitch" => 53, "pushbutton" => 54, "spdt" => 55,
    "opamp" => 56, "fdopamp" => 57, "transconductor" => 58,
    "andgate" => 59, "orgate" => 60, "notgate" => 61, "nandgate" => 62, "norgate" => 63,
    "xorgate" => 64, "xnorgate" => 65, "buffergate" => 66,
    "antenna" => 67, "loudspeaker" => 68, "microphone" => 69, "motor" => 70, "buzzer" => 71,
    "transformer" => 72,
    "vdd" => 73, "vcc" => 74, "gnd" => 75, "ground" => 76, "vss" => 77, "vee" => 78,
    "ipin" => 79, "opin" => 80, "iopin" => 81,
};

/// Index of a class by name, for the loader to stamp into the IR's `SymbolIdx`.
pub fn class_of(name: &str) -> Option<usize> {
    BY_NAME.get(name).copied()
}

/// The class at an index (i.e. what a `SymbolIdx` resolves to).
pub fn class_at(id: usize) -> &'static DeviceClass {
    &CLASSES[id]
}

#[cfg(test)]
mod tests {
    use super::*;

    // The hand-maintained PHF must stay in lockstep with CLASSES order.
    #[test]
    fn by_name_matches_classes() {
        for (name, &i) in BY_NAME.entries() {
            assert_eq!(CLASSES[i].name, *name, "PHF entry {name:?} -> wrong class");
        }
        assert_eq!(BY_NAME.len(), CLASSES.len(), "PHF and CLASSES diverged in length");
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
                    assert!(a.at != b.at, "{}: terminals {} and {} coincide", cl.name, a.name, b.name);
                }
            }
            // a placement role (rail/port) implies a single terminal; not the converse
            // (an antenna is single-terminal with no role).
            if cl.role != SymbolRole::None {
                assert_eq!(cl.terminals.len(), 1, "{}: rail/port must be single-terminal", cl.name);
            }
        }
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
                    "{}: terminal {} outside bbox in y", cl.name, t.name
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
                    assert!(x.abs() <= half, "{}: glyph x={x} exceeds cell ±{half}", cl.name);
                }
                if let DrawOp::Polyline(pts) = op {
                    for p in *pts {
                        assert!(p.x.abs() <= half, "{}: polyline x={} exceeds cell", cl.name, p.x);
                    }
                }
            }
        }
        // collision predicate: disjoint vs overlapping
        let a = Rect { min: Pt { x: 0, y: 0 }, max: Pt { x: 10, y: 10 } };
        let far = Rect { min: Pt { x: 20, y: 0 }, max: Pt { x: 30, y: 10 } };
        let over = Rect { min: Pt { x: 5, y: 5 }, max: Pt { x: 15, y: 15 } };
        assert!(!a.intersects(&far));
        assert!(a.intersects(&over));
    }

    // The condition: a device's conducting pins (drain/source, collector/emitter,
    // anode/cathode) sit on the same axis at the same x as a two-terminal bipole — so they
    // line up when packed. Checked against the resistor's terminal x-positions.
    #[test]
    fn conduction_terminals_align() {
        use TerminalRole::*;
        let res = class_at(class_of("res").unwrap());
        let edge: Vec<i32> = res.terminals.iter().map(|t| t.at.x).collect(); // [-20, 20]
        for cl in CLASSES {
            for t in cl.terminals {
                if matches!(t.role, Drain | Source | Collector | Emitter | Anode | Cathode) {
                    assert_eq!(t.at.y, 0, "{}: {} off the conduction axis", cl.name, t.name);
                    assert!(edge.contains(&t.at.x), "{}: {} not at a bipole edge", cl.name, t.name);
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
                assert_eq!(cl.terminals[0].at, origin, "{}: single tap off origin", cl.name);
                continue;
            }
            assert!(
                cl.terminals.iter().any(|t| t.at == left)
                    && cl.terminals.iter().any(|t| t.at == right),
                "{}: missing a conduction-axis edge terminal", cl.name
            );
            for t in cl.terminals {
                if t.at != left && t.at != right {
                    assert_ne!(t.at.y, 0, "{}: aux terminal {} sits on the axis", cl.name, t.name);
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
        assert_eq!(class_at(class_of("vdd").unwrap()).role, SymbolRole::PowerRail);
    }
}
