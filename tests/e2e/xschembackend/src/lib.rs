//! xschem backend: placed IR → `.sch` file that xschem can open and netlist.

use devices::class_at;
use ir::{Ir, Pt, Strings};
use std::fmt::Write;

/// xschem symbol pin positions in symbol coordinates (before rotation/mirror).
/// Order matches cktImg's terminal slot order for each class.
fn xschem_pins(sym: &str) -> &'static [(i32, i32)] {
    match sym {
        // 3-terminal: slot 0=drain, 1=gate, 2=source
        "devices/nmos.sym" => &[(20, -30), (-20, 0), (20, 30)],
        "devices/pmos.sym" => &[(20, 30), (-20, 0), (20, -30)],
        "devices/njfet.sym" => &[(20, -30), (-20, 0), (20, 30)],
        "devices/pjfet.sym" => &[(20, -30), (-20, 0), (20, 30)],
        // BJT: slot 0=collector, 1=base, 2=emitter
        "devices/npn.sym" => &[(20, -30), (-20, 0), (20, 30)],
        "devices/pnp.sym" => &[(20, 30), (-20, 0), (20, -30)],
        // 2-terminal: slot 0=a/p, 1=b/m
        "devices/res.sym" | "devices/capa.sym" | "devices/ind.sym" | "devices/vsource.sym"
        | "devices/isource.sym" | "devices/diode.sym" | "devices/switch.sym" => {
            &[(0, -30), (0, 30)]
        }
        // 1-terminal: slot 0
        "devices/vdd.sym" | "devices/gnd.sym" | "devices/ipin.sym" | "devices/opin.sym"
        | "devices/iopin.sym" => &[(0, 0)],
        // opamp: slot 0=in+, 1=out, 2=in-
        "devices/opamp.sym" => &[(-20, 0), (20, 0), (-20, -12)],
        _ => &[],
    }
}

/// Map cktImg class name → xschem symbol path.
fn xschem_sym(class_name: &str) -> &'static str {
    match class_name {
        "nmos" | "nfet" | "nfetd" => "devices/nmos.sym",
        "pmos" | "pfet" | "pfetd" => "devices/pmos.sym",
        "njfet" => "devices/njfet.sym",
        "pjfet" => "devices/pjfet.sym",
        "npn" => "devices/npn.sym",
        "pnp" => "devices/pnp.sym",
        "nigbt" | "pigbt" => "devices/npn.sym",
        "res" | "generic" | "varistor" | "potentiometer" | "thermistor" | "thermistorptc"
        | "thermistorntc" | "photoresistor" | "fuse" | "crystal" | "memristor" | "ammeter"
        | "voltmeter" | "ohmmeter" | "lamp" | "loudspeaker" | "microphone" | "motor"
        | "buzzer" | "antenna" | "transformer" | "andgate" | "orgate" | "notgate"
        | "nandgate" | "norgate" | "xorgate" | "xnorgate" | "buffergate" => "devices/res.sym",
        "cap" | "ecap" | "vcap" => "devices/capa.sym",
        "ind" | "cuteind" | "vind" => "devices/ind.sym",
        "diode" | "schottky" | "zener" | "tunneldiode" | "led" | "photodiode" | "varcap"
        | "tvsdiode" | "diac" | "triac" => "devices/diode.sym",
        "battery" | "vsource" | "vsourceac" | "vsourcesin" | "cvsource" => "devices/vsource.sym",
        "isource" | "isourceac" | "cisource" => "devices/isource.sym",
        "switch" | "noswitch" | "ncswitch" | "pushbutton" | "spdt" => "devices/switch.sym",
        "opamp" | "fdopamp" | "transconductor" => "devices/opamp.sym",
        "vdd" | "vcc" => "devices/vdd.sym",
        "gnd" | "ground" | "vss" | "vee" => "devices/gnd.sym",
        "ipin" => "devices/ipin.sym",
        "opin" => "devices/opin.sym",
        "iopin" => "devices/iopin.sym",
        _ => "devices/res.sym",
    }
}

/// Is this class a transistor that needs a `model=` property?
fn is_transistor(class_name: &str) -> bool {
    matches!(
        class_name,
        "nmos"
            | "pmos"
            | "nfet"
            | "pfet"
            | "nfetd"
            | "pfetd"
            | "njfet"
            | "pjfet"
            | "npn"
            | "pnp"
            | "nigbt"
            | "pigbt"
    )
}

/// Map cktImg Rot enum value to xschem rotation integer.
fn xschem_rot(rot: ir::Rot) -> u8 {
    match rot {
        ir::Rot::R0 => 0,
        ir::Rot::R90 => 1,
        ir::Rot::R180 => 2,
        ir::Rot::R270 => 3,
    }
}

/// Render a placed IR to an xschem `.sch` document.
/// Net connectivity uses `lab_pin.sym` at each pin position (name-based, not geometric wiring).
pub fn render(ir: &Ir, strings: &Strings) -> String {
    let phys = ir.physical.as_ref().expect("render requires a placed IR");
    let mut s = String::new();

    // header
    let _ = writeln!(s, "v {{xschem version=3.4.6 file_version=1.2}}");
    for section in ["G", "K", "V", "S", "E"] {
        let _ = writeln!(s, "{section} {{}}");
    }

    // components + pin labels
    for d in 0..ir.devices.len() {
        let class = class_at(ir.devices.symbol[d].index());
        let sym = xschem_sym(class.name);
        let pos = phys.pos[d];
        let orient = ir.devices.orient[d];
        let rot = xschem_rot(orient.rot());
        let flip: u8 = if orient.mirror() { 1 } else { 0 };
        let name = strings.get(ir.devices.name[d]);
        let value = strings.get(ir.devices.value[d]);

        // component line
        let _ = write!(s, "C {{{sym}}} {} {} {rot} {flip} {{name={name}", pos.x, pos.y);
        if is_transistor(class.name) {
            let _ = write!(s, " model={}", class.name);
        }
        if !value.is_empty() && !is_transistor(class.name) {
            let _ = write!(s, " value={value}");
        }
        let _ = writeln!(s, "}}");

        // lab_pin at each pin's xschem position
        let sym_pins = xschem_pins(sym);
        let pin_range = ir.devices.pin_range(ir::ids::DeviceIdx(d as u32));
        for (slot, pi) in pin_range.enumerate() {
            let net = match ir.pins.net[pi] {
                Some(n) => strings.get(ir.nets.name[n.index()]),
                None => continue,
            };
            if let Some(&(px, py)) = sym_pins.get(slot) {
                let pin_local = Pt::new(px, py);
                let pin_screen = orient.apply(pin_local);
                let lx = pos.x + pin_screen.x;
                let ly = pos.y + pin_screen.y;
                let _ = writeln!(
                    s,
                    "C {{devices/lab_pin.sym}} {lx} {ly} 0 0 {{name=l{d}_{slot} sig_type=std_logic lab={net}}}"
                );
            }
        }
    }

    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sym_mapping_covers_all_classes() {
        for class in devices::CLASSES {
            let sym = xschem_sym(class.name);
            assert!(sym.starts_with("devices/"), "{}: bad sym path {sym}", class.name);
            assert!(sym.ends_with(".sym"), "{}: bad sym path {sym}", class.name);
        }
    }

    #[test]
    fn pins_defined_for_all_used_syms() {
        let syms: std::collections::HashSet<&str> =
            devices::CLASSES.iter().map(|c| xschem_sym(c.name)).collect();
        for sym in syms {
            let pins = xschem_pins(sym);
            assert!(!pins.is_empty(), "{sym}: no pin positions defined");
        }
    }
}
