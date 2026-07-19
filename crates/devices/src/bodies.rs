//! Symbol bodies: draw primitives per visual family, in canonical coordinates.

use crate::geom::{DrawOp, Pt};

macro_rules! ln {
    ($x1:literal, $y1:literal, $x2:literal, $y2:literal) => {
        DrawOp::Line(Pt { x: $x1, y: $y1 }, Pt { x: $x2, y: $y2 })
    };
}
macro_rules! circ {
    ($x:literal, $y:literal, $r:literal) => {
        DrawOp::Circle {
            c: Pt { x: $x, y: $y },
            r: $r,
        }
    };
}

// ---- symbol bodies, shared per visual family ----
pub(crate) const DRAW_RES: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -10, y: 0 },
        Pt { x: -8, y: 6 },
        Pt { x: -4, y: -6 },
        Pt { x: 0, y: 6 },
        Pt { x: 4, y: -6 },
        Pt { x: 8, y: 6 },
        Pt { x: 10, y: 0 },
    ]),
];
pub(crate) const DRAW_BOX: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
];
pub(crate) const DRAW_CAP: &[DrawOp] = &[
    ln!(-20, 0, -3, 0),
    ln!(3, 0, 20, 0),
    ln!(-3, -8, -3, 8),
    ln!(3, -8, 3, 8),
];
pub(crate) const DRAW_IND: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(-9, 0, 3),
    circ!(-3, 0, 3),
    circ!(3, 0, 3),
    circ!(9, 0, 3),
];
pub(crate) const DRAW_DIODE: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 8, 0),
    ln!(-8, 7, 8, 0),
    ln!(8, -7, 8, 7),
];
pub(crate) const DRAW_LED: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 8, 0),
    ln!(-8, 7, 8, 0),
    ln!(8, -7, 8, 7),
    ln!(2, 10, 8, 16),
    ln!(6, 10, 12, 16), // emission arrows
];
// ---- transistors ----
// Enhancement MOSFET: leads bend up to a 3-segment channel (broken line = enhancement), a
// solid gate plate parallel across the insulator gap. A bulk arrow on the source encodes
// polarity — nmos points into the channel, pmos out.
pub(crate) const DRAW_NMOS: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -4),
    ln!(8, 0, 8, -4),
    ln!(-8, -4, -3, -4),
    ln!(-2, -4, 2, -4),
    ln!(3, -4, 8, -4),
    ln!(-8, -9, 8, -9),
    ln!(0, -9, 0, -20),
    ln!(-8, -4, -11, -1),
    ln!(-8, -4, -5, -1), // bulk arrow into channel (n)
];
pub(crate) const DRAW_PMOS: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -4),
    ln!(8, 0, 8, -4),
    ln!(-8, -4, -3, -4),
    ln!(-2, -4, 2, -4),
    ln!(3, -4, 8, -4),
    ln!(-8, -9, 8, -9),
    ln!(0, -9, 0, -20),
    ln!(-8, 0, -11, -3),
    ln!(-8, 0, -5, -3), // bulk arrow out of channel (p)
];
// JFET: solid channel (no enhancement gaps), gate touches it through an arrow.
pub(crate) const DRAW_NJFET: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -5),
    ln!(8, 0, 8, -5),
    ln!(-8, -5, 8, -5),
    ln!(0, -20, 0, -5),
    ln!(0, -5, -3, -9),
    ln!(0, -5, 3, -9), // gate arrow into channel (n)
];
pub(crate) const DRAW_PJFET: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, 0, -8, -5),
    ln!(8, 0, 8, -5),
    ln!(-8, -5, 8, -5),
    ln!(0, -20, 0, -5),
    ln!(0, -9, -3, -5),
    ln!(0, -9, 3, -5), // gate arrow out of channel (p)
];
// BJT: base bar, emitter/collector diagonals at staggered heights; emitter arrow points out
// for npn, in for pnp.
pub(crate) const DRAW_NPN: &[DrawOp] = &[
    ln!(0, -8, 0, 8),
    ln!(0, -8, 0, -20),
    ln!(-20, 0, -8, 0),
    ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0),
    ln!(8, 0, 0, -5),
    ln!(-8, 0, -5, 4),
    ln!(-8, 0, -3, 1), // emitter out-arrow (npn)
];
pub(crate) const DRAW_PNP: &[DrawOp] = &[
    ln!(0, -8, 0, 8),
    ln!(0, -8, 0, -20),
    ln!(-20, 0, -8, 0),
    ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0),
    ln!(8, 0, 0, -5),
    ln!(0, 5, -3, 4),
    ln!(0, 5, -1, 1), // emitter in-arrow (pnp)
];
// IGBT: BJT output (collector/emitter diagonals + arrow) driven by an insulated gate plate.
pub(crate) const DRAW_NIGBT: &[DrawOp] = &[
    ln!(0, -7, 0, 7),
    ln!(-20, 0, -8, 0),
    ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0),
    ln!(8, 0, 0, -5),
    ln!(-4, -7, -4, 7),
    DrawOp::Polyline(&[
        Pt { x: 0, y: -20 },
        Pt { x: 0, y: -11 },
        Pt { x: -4, y: -11 },
        Pt { x: -4, y: -7 },
    ]),
    ln!(8, 0, 5, 4),
    ln!(8, 0, 3, 1), // collector out-arrow (n)
];
pub(crate) const DRAW_PIGBT: &[DrawOp] = &[
    ln!(0, -7, 0, 7),
    ln!(-20, 0, -8, 0),
    ln!(-8, 0, 0, 5),
    ln!(20, 0, 8, 0),
    ln!(8, 0, 0, -5),
    ln!(-4, -7, -4, 7),
    DrawOp::Polyline(&[
        Pt { x: 0, y: -20 },
        Pt { x: 0, y: -11 },
        Pt { x: -4, y: -11 },
        Pt { x: -4, y: -7 },
    ]),
    ln!(0, 5, -3, 4),
    ln!(0, 5, -1, 1), // emitter in-arrow (p)
];

// ---- diodes (anode left, cathode right; the cathode bar's shape names the variant) ----
pub(crate) const DRAW_SCHOTTKY: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 8, 0),
    ln!(-8, 7, 8, 0),
    DrawOp::Polyline(&[
        Pt { x: 11, y: -4 },
        Pt { x: 11, y: -7 },
        Pt { x: 8, y: -7 },
        Pt { x: 8, y: 7 },
        Pt { x: 5, y: 7 },
        Pt { x: 5, y: 4 },
    ]),
];
pub(crate) const DRAW_ZENER: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 8, 0),
    ln!(-8, 7, 8, 0),
    DrawOp::Polyline(&[
        Pt { x: 5, y: -7 },
        Pt { x: 8, y: -7 },
        Pt { x: 8, y: 7 },
        Pt { x: 11, y: 7 },
    ]),
];
pub(crate) const DRAW_TUNNEL: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 8, 0),
    ln!(-8, 7, 8, 0),
    DrawOp::Polyline(&[
        Pt { x: 5, y: -7 },
        Pt { x: 8, y: -7 },
        Pt { x: 8, y: 7 },
        Pt { x: 5, y: 7 },
    ]),
];
pub(crate) const DRAW_VARCAP: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(11, 0, 20, 0),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 8, 0),
    ln!(-8, 7, 8, 0),
    ln!(8, -7, 8, 7),
    ln!(11, -7, 11, 7), // cathode bar + varactor cap plate
];
pub(crate) const DRAW_TVS: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -7, -10, 7),
    ln!(-10, -7, 0, 0),
    ln!(-10, 7, 0, 0),
    ln!(10, -7, 10, 7),
    ln!(10, -7, 0, 0),
    ln!(10, 7, 0, 0),
    ln!(-10, -7, -13, -7),
    ln!(10, 7, 13, 7), // bent ends: back-to-back
];
pub(crate) const DRAW_PHOTODIODE: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 8, 0),
    ln!(-8, 7, 8, 0),
    ln!(8, -7, 8, 7),
    ln!(12, -16, 4, -8),
    ln!(4, -8, 7, -8),
    ln!(4, -8, 4, -11), // incoming light 1
    ln!(16, -12, 8, -4),
    ln!(8, -4, 11, -4),
    ln!(8, -4, 8, -7), // incoming light 2
];

// ---- sources & meters (circle body; inner glyph names the variant) ----
pub(crate) const DRAW_VSOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    ln!(-7, -2, -7, 2),
    ln!(-9, 0, -5, 0),
    ln!(5, 0, 9, 0), // + / -
];
pub(crate) const DRAW_VSOURCEAC: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    DrawOp::Polyline(&[
        Pt { x: -7, y: 0 },
        Pt { x: -4, y: -5 },
        Pt { x: 0, y: 0 },
        Pt { x: 4, y: 5 },
        Pt { x: 7, y: 0 },
    ]),
];
pub(crate) const DRAW_ISOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    ln!(0, -6, 0, 6),
    ln!(-3, 3, 0, 6),
    ln!(3, 3, 0, 6), // up arrow
];
pub(crate) const DRAW_ISOURCEAC: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    DrawOp::Polyline(&[
        Pt { x: -7, y: 0 },
        Pt { x: -4, y: -5 },
        Pt { x: 0, y: 0 },
        Pt { x: 4, y: 5 },
        Pt { x: 7, y: 0 },
    ]),
    ln!(12, 0, 9, -2),
    ln!(12, 0, 9, 2), // current-direction arrowhead on lead
];
pub(crate) const DRAW_CVSOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -12, y: 0 },
        Pt { x: 0, y: -12 },
        Pt { x: 12, y: 0 },
        Pt { x: 0, y: 12 },
        Pt { x: -12, y: 0 },
    ]),
    ln!(-7, -2, -7, 2),
    ln!(-9, 0, -5, 0),
    ln!(5, 0, 9, 0), // + / - (controlled = diamond)
];
pub(crate) const DRAW_CISOURCE: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -12, y: 0 },
        Pt { x: 0, y: -12 },
        Pt { x: 12, y: 0 },
        Pt { x: 0, y: 12 },
        Pt { x: -12, y: 0 },
    ]),
    ln!(0, 6, 0, -6),
    ln!(-3, -3, 0, -6),
    ln!(3, -3, 0, -6), // up arrow
];
pub(crate) const DRAW_AMMETER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -4, y: 5 }, Pt { x: 0, y: -5 }, Pt { x: 4, y: 5 }]),
    ln!(-2, 1, 2, 1), // A
];
pub(crate) const DRAW_VOLTMETER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    DrawOp::Polyline(&[Pt { x: -4, y: -5 }, Pt { x: 0, y: 5 }, Pt { x: 4, y: -5 }]), // V
];
pub(crate) const DRAW_OHMMETER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    DrawOp::Polyline(&[
        Pt { x: -5, y: 5 },
        Pt { x: -3, y: 5 },
        Pt { x: -4, y: 1 },
        Pt { x: -2, y: -4 },
        Pt { x: 2, y: -4 },
        Pt { x: 4, y: 1 },
        Pt { x: 3, y: 5 },
        Pt { x: 5, y: 5 },
    ]), // Ω
];
pub(crate) const DRAW_MOTOR: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    DrawOp::Polyline(&[
        Pt { x: -4, y: 5 },
        Pt { x: -4, y: -5 },
        Pt { x: 0, y: 0 },
        Pt { x: 4, y: -5 },
        Pt { x: 4, y: 5 },
    ]), // M
];
pub(crate) const DRAW_LAMP: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(0, 0, 12),
    ln!(-8, -8, 8, 8),
    ln!(-8, 8, 8, -8), // X
];

// ---- box-derived passives (rectangle + a distinguishing mark) ----
pub(crate) const DRAW_FUSE: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    ln!(-10, 0, 10, 0), // filament
];
pub(crate) const DRAW_VARISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    ln!(-11, 9, 11, -9),
    ln!(11, -9, 6, -8),
    ln!(11, -9, 8, -3), // voltage-dependent arrow
];
pub(crate) const DRAW_THERMISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[Pt { x: -11, y: 9 }, Pt { x: -7, y: 9 }, Pt { x: 11, y: -9 }]), // t° line + foot
];
pub(crate) const DRAW_THERMISTORPTC: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[Pt { x: -11, y: 9 }, Pt { x: -7, y: 9 }, Pt { x: 11, y: -9 }]),
    ln!(4, -9, 8, -9),
    ln!(6, -11, 6, -7), // +t°
];
pub(crate) const DRAW_THERMISTORNTC: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[Pt { x: -11, y: 9 }, Pt { x: -7, y: 9 }, Pt { x: 11, y: -9 }]),
    ln!(4, -9, 8, -9), // -t°
];
pub(crate) const DRAW_PHOTORESISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    ln!(14, -15, 6, -7),
    ln!(6, -7, 9, -7),
    ln!(6, -7, 6, -10), // light in 1
    ln!(18, -11, 10, -3),
    ln!(10, -3, 13, -3),
    ln!(10, -3, 10, -6), // light in 2
];
pub(crate) const DRAW_CRYSTAL: &[DrawOp] = &[
    ln!(-20, 0, -7, 0),
    ln!(7, 0, 20, 0),
    ln!(-7, -7, -7, 7),
    ln!(7, -7, 7, 7), // electrode plates
    ln!(-4, -6, 4, -6),
    ln!(4, -6, 4, 6),
    ln!(4, 6, -4, 6),
    ln!(-4, 6, -4, -6), // resonator
];
pub(crate) const DRAW_MEMRISTOR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    DrawOp::Polyline(&[
        Pt { x: -8, y: 6 },
        Pt { x: -8, y: -6 },
        Pt { x: -3, y: 6 },
        Pt { x: -3, y: -6 },
        Pt { x: 2, y: 6 },
        Pt { x: 2, y: -6 },
    ]),
    ln!(5, 6, 5, -6),
    ln!(5, 6, 9, -6),
    ln!(5, 0, 9, -6),
    ln!(5, -6, 9, -6), // filled cell
];
pub(crate) const DRAW_LOUDSPEAKER: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(8, 0, 20, 0),
    ln!(-12, -5, -6, -5),
    ln!(-6, -5, -6, 5),
    ln!(-6, 5, -12, 5),
    ln!(-12, 5, -12, -5), // magnet
    ln!(-6, -5, 8, -11),
    ln!(8, -11, 8, 11),
    ln!(8, 11, -6, 5), // cone
];
pub(crate) const DRAW_MICROPHONE: &[DrawOp] = &[
    ln!(-20, 0, -6, 0),
    ln!(6, 0, 20, 0),
    circ!(0, 0, 6),
    ln!(6, -7, 6, 7), // capsule + diaphragm
];
pub(crate) const DRAW_BUZZER: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, 6, 10, 6),
    DrawOp::Polyline(&[
        Pt { x: -10, y: 6 },
        Pt { x: -9, y: -3 },
        Pt { x: -5, y: -9 },
        Pt { x: 0, y: -11 },
        Pt { x: 5, y: -9 },
        Pt { x: 9, y: -3 },
        Pt { x: 10, y: 6 },
    ]), // dome
];

// ---- polarized / variable cap & inductor ----
pub(crate) const DRAW_ECAP: &[DrawOp] = &[
    ln!(-20, 0, -3, 0),
    ln!(4, 0, 20, 0),
    ln!(-3, -8, -3, 8), // + plate (straight)
    DrawOp::Polyline(&[
        Pt { x: 7, y: -8 },
        Pt { x: 4, y: -4 },
        Pt { x: 3, y: 0 },
        Pt { x: 4, y: 4 },
        Pt { x: 7, y: 8 },
    ]), // - plate (curved)
    ln!(-9, -8, -5, -8),
    ln!(-7, -10, -7, -6), // + mark
];
pub(crate) const DRAW_VCAP: &[DrawOp] = &[
    ln!(-20, 0, -3, 0),
    ln!(3, 0, 20, 0),
    ln!(-3, -8, -3, 8),
    ln!(3, -8, 3, 8),
    ln!(-9, 9, 9, -9),
    ln!(9, -9, 4, -8),
    ln!(9, -9, 6, -3), // tuning arrow
];
pub(crate) const DRAW_VIND: &[DrawOp] = &[
    ln!(-20, 0, -12, 0),
    ln!(12, 0, 20, 0),
    circ!(-9, 0, 3),
    circ!(-3, 0, 3),
    circ!(3, 0, 3),
    circ!(9, 0, 3),
    ln!(-11, 9, 11, -9),
    ln!(11, -9, 6, -8),
    ln!(11, -9, 8, -3), // tuning arrow
];

// ---- sources/labels & switches ----
pub(crate) const DRAW_BATTERY: &[DrawOp] = &[
    ln!(-20, 0, -4, 0),
    ln!(4, 0, 20, 0),
    ln!(-4, -10, -4, 10),
    ln!(4, -5, 4, 5),
];
// y is screen-down: GND sits at the bottom so its bars go DOWN (+y) from the pin; VDD sits
// at the top so its bar goes UP (-y).
pub(crate) const DRAW_GROUND: &[DrawOp] = &[
    ln!(0, 0, 0, 8),
    ln!(-10, 8, 10, 8),
    ln!(-6, 12, 6, 12),
    ln!(-2, 16, 2, 16),
];
pub(crate) const DRAW_VDD: &[DrawOp] = &[ln!(0, 0, 0, -8), ln!(-8, -8, 8, -8)];
pub(crate) const DRAW_PORT: &[DrawOp] = &[
    ln!(0, 0, 6, 0),
    ln!(6, -5, 14, 0),
    ln!(14, 0, 6, 5),
    ln!(6, 5, 6, -5),
];
pub(crate) const DRAW_SWITCH: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, 0, 6, 8),
    circ!(-8, 0, 1),
    circ!(8, 0, 1),
];
pub(crate) const DRAW_NCSWITCH: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(-8, 0, 9, -2),
    circ!(-8, 0, 1),
    circ!(8, 0, 1),
    ln!(9, -6, 9, 4), // normally-closed contact bar the lever bridges
];
pub(crate) const DRAW_PUSHBUTTON: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    circ!(-8, 0, 1),
    circ!(8, 0, 1),
    ln!(-9, -6, 9, -6), // floating contact
    ln!(0, -6, 0, -12),
    ln!(-5, -12, 5, -12), // plunger + button cap
];
pub(crate) const DRAW_SPDT: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(8, 20, 20, 20),
    circ!(-8, 0, 1),
    circ!(8, 0, 1),
    circ!(8, 20, 1),
    ln!(-8, 0, 8, 6),
];
pub(crate) const DRAW_ANTENNA: &[DrawOp] =
    &[ln!(0, 0, 0, -12), ln!(-8, -20, 0, -12), ln!(8, -20, 0, -12)];
pub(crate) const DRAW_POT: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -6, 10, -6),
    ln!(10, -6, 10, 6),
    ln!(10, 6, -10, 6),
    ln!(-10, 6, -10, -6),
    ln!(0, 20, 0, 8),
    ln!(-3, 11, 0, 8),
    ln!(3, 11, 0, 8), // wiper arrow
];
pub(crate) const DRAW_TRIAC: &[DrawOp] = &[
    ln!(-20, 0, -8, 0),
    ln!(8, 0, 20, 0),
    ln!(0, -20, 0, -6),
    ln!(-8, -7, -8, 7),
    ln!(-8, -7, 0, 0),
    ln!(-8, 7, 0, 0),
    ln!(8, -7, 8, 7),
    ln!(8, -7, 0, 0),
    ln!(8, 7, 0, 0),
];

// ---- amplifiers & logic gates (body centred on y=0; inputs jog from the terminal rows) ----
pub(crate) const DRAW_OPAMP: &[DrawOp] = &[
    ln!(-20, 0, -12, 6),    // in+ lead
    ln!(-20, -12, -12, -6), // in- lead
    ln!(12, 0, 20, 0),      // out lead
    ln!(-12, 12, -12, -12),
    ln!(-12, 12, 12, 0),
    ln!(-12, -12, 12, 0), // triangle
];
pub(crate) const DRAW_AND: &[DrawOp] = &[
    ln!(-20, 0, -10, 5),
    ln!(-20, -12, -10, -5),
    ln!(13, 0, 20, 0),
    ln!(-10, 12, -10, -12),
    ln!(-10, -12, 2, -12),
    ln!(-10, 12, 2, 12),
    DrawOp::Polyline(&[
        Pt { x: 2, y: -12 },
        Pt { x: 9, y: -10 },
        Pt { x: 12, y: -6 },
        Pt { x: 13, y: 0 },
        Pt { x: 12, y: 6 },
        Pt { x: 9, y: 10 },
        Pt { x: 2, y: 12 },
    ]),
];
pub(crate) const DRAW_NAND: &[DrawOp] = &[
    ln!(-20, 0, -10, 5),
    ln!(-20, -12, -10, -5),
    ln!(17, 0, 20, 0),
    ln!(-10, 12, -10, -12),
    ln!(-10, -12, 2, -12),
    ln!(-10, 12, 2, 12),
    DrawOp::Polyline(&[
        Pt { x: 2, y: -12 },
        Pt { x: 9, y: -10 },
        Pt { x: 12, y: -6 },
        Pt { x: 13, y: 0 },
        Pt { x: 12, y: 6 },
        Pt { x: 9, y: 10 },
        Pt { x: 2, y: 12 },
    ]),
    circ!(15, 0, 2),
];
pub(crate) const DRAW_OR: &[DrawOp] = &[
    ln!(-20, 0, -9, 4),
    ln!(-20, -12, -9, -4),
    ln!(13, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -10, y: 12 },
        Pt { x: -6, y: 0 },
        Pt { x: -10, y: -12 },
    ]),
    DrawOp::Polyline(&[
        Pt { x: -10, y: -12 },
        Pt { x: 3, y: -11 },
        Pt { x: 10, y: -6 },
        Pt { x: 13, y: 0 },
        Pt { x: 10, y: 6 },
        Pt { x: 3, y: 11 },
        Pt { x: -10, y: 12 },
    ]),
];
pub(crate) const DRAW_NOR: &[DrawOp] = &[
    ln!(-20, 0, -9, 4),
    ln!(-20, -12, -9, -4),
    ln!(17, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -10, y: 12 },
        Pt { x: -6, y: 0 },
        Pt { x: -10, y: -12 },
    ]),
    DrawOp::Polyline(&[
        Pt { x: -10, y: -12 },
        Pt { x: 3, y: -11 },
        Pt { x: 10, y: -6 },
        Pt { x: 13, y: 0 },
        Pt { x: 10, y: 6 },
        Pt { x: 3, y: 11 },
        Pt { x: -10, y: 12 },
    ]),
    circ!(15, 0, 2),
];
pub(crate) const DRAW_XOR: &[DrawOp] = &[
    ln!(-20, 0, -12, 4),
    ln!(-20, -12, -12, -4),
    ln!(13, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -13, y: 12 },
        Pt { x: -9, y: 0 },
        Pt { x: -13, y: -12 },
    ]), // extra back arc
    DrawOp::Polyline(&[
        Pt { x: -10, y: 12 },
        Pt { x: -6, y: 0 },
        Pt { x: -10, y: -12 },
    ]),
    DrawOp::Polyline(&[
        Pt { x: -10, y: -12 },
        Pt { x: 3, y: -11 },
        Pt { x: 10, y: -6 },
        Pt { x: 13, y: 0 },
        Pt { x: 10, y: 6 },
        Pt { x: 3, y: 11 },
        Pt { x: -10, y: 12 },
    ]),
];
pub(crate) const DRAW_XNOR: &[DrawOp] = &[
    ln!(-20, 0, -12, 4),
    ln!(-20, -12, -12, -4),
    ln!(17, 0, 20, 0),
    DrawOp::Polyline(&[
        Pt { x: -13, y: 12 },
        Pt { x: -9, y: 0 },
        Pt { x: -13, y: -12 },
    ]),
    DrawOp::Polyline(&[
        Pt { x: -10, y: 12 },
        Pt { x: -6, y: 0 },
        Pt { x: -10, y: -12 },
    ]),
    DrawOp::Polyline(&[
        Pt { x: -10, y: -12 },
        Pt { x: 3, y: -11 },
        Pt { x: 10, y: -6 },
        Pt { x: 13, y: 0 },
        Pt { x: 10, y: 6 },
        Pt { x: 3, y: 11 },
        Pt { x: -10, y: 12 },
    ]),
    circ!(15, 0, 2),
];
pub(crate) const DRAW_NOT: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(14, 0, 20, 0),
    ln!(-10, -12, -10, 12),
    ln!(-10, 12, 10, 0),
    ln!(10, 0, -10, -12),
    circ!(12, 0, 2),
];
pub(crate) const DRAW_BUFFER: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(10, 0, 20, 0),
    ln!(-10, -12, -10, 12),
    ln!(-10, 12, 10, 0),
    ln!(10, 0, -10, -12),
];
pub(crate) const DRAW_XFMR: &[DrawOp] = &[
    ln!(-20, 0, -10, 0),
    ln!(-20, -12, -10, -12),
    ln!(20, 0, 10, 0),
    ln!(20, -12, 10, -12),
    circ!(-8, -2, 5),
    circ!(-8, -10, 5), // left winding
    circ!(8, -2, 5),
    circ!(8, -10, 5), // right winding
    ln!(-2, -18, -2, 6),
    ln!(2, -18, 2, 6), // core
];
