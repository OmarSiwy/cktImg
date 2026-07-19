//! The catalog: terminal sets, the [`CLASSES`] table, and the [`BY_NAME`] index.

use crate::bodies::*;
use crate::class::{DeviceClass, SymbolRole, Terminal, TerminalRole};
use crate::geom::Pt;

// ---- terse constructors ----
macro_rules! t {
    ($n:literal, $r:ident, $x:literal, $y:literal) => {
        Terminal {
            name: $n,
            role: TerminalRole::$r,
            at: Pt { x: $x, y: $y },
        }
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
const MOS: &[Terminal] = &[
    t!("d", Drain, 20, 0),
    t!("g", Gate, 0, -20),
    t!("s", Source, -20, 0),
];
const BJT: &[Terminal] = &[
    t!("c", Collector, 20, 0),
    t!("b", Base, 0, -20),
    t!("e", Emitter, -20, 0),
];
const IGBT: &[Terminal] = &[
    t!("c", Collector, 20, 0),
    t!("g", Gate, 0, -20),
    t!("e", Emitter, -20, 0),
];
const TWO: &[Terminal] = &[t!("a", Passive, -20, 0), t!("b", Passive, 20, 0)];
const ONE: &[Terminal] = &[t!("t", Passive, 0, 0)]; // single tap, on the axis
const DIODE: &[Terminal] = &[t!("a", Anode, -20, 0), t!("k", Cathode, 20, 0)];
const POT: &[Terminal] = &[
    t!("a", Passive, -20, 0),
    t!("b", Passive, 20, 0),
    t!("w", Passive, 0, 20),
];
const TRIAC: &[Terminal] = &[
    t!("a", Passive, -20, 0),
    t!("b", Passive, 20, 0),
    t!("g", Gate, 0, -20),
];
// in/pole on the left edge, primary throw/output on the right edge; extras off-axis below.
const SPDT: &[Terminal] = &[
    t!("in", Passive, -20, 0),
    t!("a", Passive, 20, 0),
    t!("b", Passive, 20, 20),
];
const OPAMP: &[Terminal] = &[
    t!("in+", Passive, -20, 0),
    t!("out", Passive, 20, 0),
    t!("in-", Passive, -20, -12),
];
const FDOPAMP: &[Terminal] = &[
    t!("in+", Passive, -20, 0),
    t!("out+", Passive, 20, 0),
    t!("in-", Passive, -20, -12),
    t!("out-", Passive, 20, -12),
];
const GATE2: &[Terminal] = &[
    t!("in1", Passive, -20, 0),
    t!("out", Passive, 20, 0),
    t!("in2", Passive, -20, -12),
];
const GATE1: &[Terminal] = &[t!("in", Passive, -20, 0), t!("out", Passive, 20, 0)];
const XFMR: &[Terminal] = &[
    t!("l1", Passive, -20, 0),
    t!("r1", Passive, 20, 0),
    t!("l2", Passive, -20, -12),
    t!("r2", Passive, 20, -12),
];
const RAIL: &[Terminal] = &[t!("p", Passive, 0, 0)];

/// The known device classes. The IR's `SymbolIdx` indexes this slice. Order is the contract
/// [`BY_NAME`] mirrors — the `by_name_matches_classes` test enforces alignment.
pub static CLASSES: &[DeviceClass] = &[
    // transistors
    c!("nmos", None, MOS, DRAW_NMOS, 'M', ""),    // 0
    c!("pmos", None, MOS, DRAW_PMOS, 'M', ""),    // 1
    c!("nfet", None, MOS, DRAW_NMOS, 'M', ""),    // 2
    c!("pfet", None, MOS, DRAW_PMOS, 'M', ""),    // 3
    c!("nfetd", None, MOS, DRAW_NMOS, 'M', ""),   // 4
    c!("pfetd", None, MOS, DRAW_PMOS, 'M', ""),   // 5
    c!("njfet", None, MOS, DRAW_NJFET, 'J', ""),  // 6
    c!("pjfet", None, MOS, DRAW_PJFET, 'J', ""),  // 7
    c!("npn", None, BJT, DRAW_NPN, 'Q', ""),      // 8
    c!("pnp", None, BJT, DRAW_PNP, 'Q', ""),      // 9
    c!("nigbt", None, IGBT, DRAW_NIGBT, 'Q', ""), // 10
    c!("pigbt", None, IGBT, DRAW_PIGBT, 'Q', ""), // 11
    // passive bipoles
    c!("res", None, TWO, DRAW_RES, 'R', "1k"),         // 12
    c!("generic", None, TWO, DRAW_BOX, 'R', ""),       // 13
    c!("varistor", None, TWO, DRAW_VARISTOR, 'R', ""), // 14
    c!("potentiometer", None, POT, DRAW_POT, 'R', "10k"), // 15
    c!("thermistor", None, TWO, DRAW_THERMISTOR, 'R', ""), // 16
    c!("thermistorptc", None, TWO, DRAW_THERMISTORPTC, 'R', ""), // 17
    c!("thermistorntc", None, TWO, DRAW_THERMISTORNTC, 'R', ""), // 18
    c!("photoresistor", None, TWO, DRAW_PHOTORESISTOR, 'R', ""), // 19
    c!("cap", None, TWO, DRAW_CAP, 'C', "1u"),         // 20
    c!("ecap", None, TWO, DRAW_ECAP, 'C', "1u"),       // 21
    c!("vcap", None, TWO, DRAW_VCAP, 'C', ""),         // 22
    c!("ind", None, TWO, DRAW_IND, 'L', "1m"),         // 23
    c!("cuteind", None, TWO, DRAW_IND, 'L', "1m"),     // 24
    c!("vind", None, TWO, DRAW_VIND, 'L', ""),         // 25
    c!("fuse", None, TWO, DRAW_FUSE, 'F', ""),         // 26
    c!("lamp", None, TWO, DRAW_LAMP, 'X', ""),         // 27
    c!("crystal", None, TWO, DRAW_CRYSTAL, 'X', ""),   // 28
    c!("memristor", None, TWO, DRAW_MEMRISTOR, 'R', ""), // 29
    // diodes
    c!("diode", None, DIODE, DRAW_DIODE, 'D', ""), // 30
    c!("schottky", None, DIODE, DRAW_SCHOTTKY, 'D', ""), // 31
    c!("zener", None, DIODE, DRAW_ZENER, 'D', ""), // 32
    c!("tunneldiode", None, DIODE, DRAW_TUNNEL, 'D', ""), // 33
    c!("led", None, DIODE, DRAW_LED, 'D', ""),     // 34
    c!("photodiode", None, DIODE, DRAW_PHOTODIODE, 'D', ""), // 35
    c!("varcap", None, DIODE, DRAW_VARCAP, 'D', ""), // 36
    c!("tvsdiode", None, DIODE, DRAW_TVS, 'D', ""), // 37
    c!("diac", None, TWO, DRAW_TRIAC, 'D', ""),    // 38
    c!("triac", None, TRIAC, DRAW_TRIAC, 'X', ""), // 39
    // sources & meters
    c!("battery", None, TWO, DRAW_BATTERY, 'V', "9"), // 40
    c!("vsource", None, TWO, DRAW_VSOURCE, 'V', ""),  // 41
    c!("isource", None, TWO, DRAW_ISOURCE, 'I', ""),  // 42
    c!("vsourceac", None, TWO, DRAW_VSOURCEAC, 'V', ""), // 43
    c!("isourceac", None, TWO, DRAW_ISOURCEAC, 'I', ""), // 44
    c!("vsourcesin", None, TWO, DRAW_VSOURCEAC, 'V', ""), // 45
    c!("cvsource", None, TWO, DRAW_CVSOURCE, 'E', ""), // 46
    c!("cisource", None, TWO, DRAW_CISOURCE, 'G', ""), // 47
    c!("ammeter", None, TWO, DRAW_AMMETER, 'X', ""),  // 48
    c!("voltmeter", None, TWO, DRAW_VOLTMETER, 'X', ""), // 49
    c!("ohmmeter", None, TWO, DRAW_OHMMETER, 'X', ""), // 50
    // switches
    c!("switch", None, TWO, DRAW_SWITCH, 'S', ""), // 51
    c!("noswitch", None, TWO, DRAW_SWITCH, 'S', ""), // 52
    c!("ncswitch", None, TWO, DRAW_NCSWITCH, 'S', ""), // 53
    c!("pushbutton", None, TWO, DRAW_PUSHBUTTON, 'S', ""), // 54
    c!("spdt", None, SPDT, DRAW_SPDT, 'S', ""),    // 55
    // amplifiers
    c!("opamp", None, OPAMP, DRAW_OPAMP, 'X', ""), // 56
    c!("fdopamp", None, FDOPAMP, DRAW_OPAMP, 'X', ""), // 57
    c!("transconductor", None, OPAMP, DRAW_OPAMP, 'X', ""), // 58
    // logic gates
    c!("andgate", None, GATE2, DRAW_AND, 'X', ""), // 59
    c!("orgate", None, GATE2, DRAW_OR, 'X', ""),   // 60
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
    c!("motor", None, TWO, DRAW_MOTOR, 'X', ""),     // 70
    c!("buzzer", None, TWO, DRAW_BUZZER, 'X', ""),   // 71
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
