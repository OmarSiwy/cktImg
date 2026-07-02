//! Run one netlist through every backend — and a custom one — to show the seam.
//!
//!     cargo run -p cktimg --example backends

// A common-source stage: NMOS with a resistor load to VDD.
const SPICE: &str = "R1 vdd out 5k\nM1 out in 0 0 nmos\n";

// "Bring your own backend": any `fn(&Ir, &Strings) -> String`. Here, a toy
// xschem-style component dump — proof you don't need to touch the core.
fn xschem(ir: &cktimg::Ir, s: &cktimg::Strings) -> String {
    use std::fmt::Write;
    let phys = ir.physical.as_ref().unwrap();
    let mut out = String::from("v {xschem version=3.4.5 file_version=1.2}\n");
    for d in 0..ir.devices.len() {
        let name = s.get(ir.devices.name[d]);
        let class = cktimg::devices::class_at(ir.devices.symbol[d].index()).name;
        let p = phys.pos[d];
        let _ = writeln!(out, "C {{{class}.sym}} {} {} 0 0 {{name={name}}}", p.x, p.y);
    }
    out
}

fn main() {
    let (json, report) = cktimg::run(SPICE, cktimg::backend::json);
    let (sch, _) = cktimg::run(SPICE, xschem);

    println!("netlist:\n{SPICE}");
    println!("parse report clean: {}", report.is_clean());
    println!("json : {} bytes", json.len());
    println!("\ncustom xschem backend output:\n{sch}");

    // Sanity: every backend produced something for both devices.
    assert!(json.contains("\"devices\""));
    assert_eq!(sch.matches("C {").count(), 2, "two components dumped");
    println!("all backends OK");
}
