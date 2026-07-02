//! Generate a TikZ figure from SPICE — the pre-generate path (no shell-escape).
//!
//!     cargo run -p cktimg-latex --example figure
//!
//! Writes `target/example-cs.tex`; `\input` it from a document with
//! `\usepackage{tikz,xcolor}`.

const SPICE: &str = "R1 vdd out 5k\nM1 out in 0 0 nmos\n";

fn main() {
    let out = "target/example-cs.tex";
    let (path, report) = cktimg_latex::figure(SPICE, out).expect("write figure");

    println!("wrote {}", path.display());
    println!("parse clean: {}", report.is_clean());

    let tex = std::fs::read_to_string(&path).unwrap();
    assert!(
        tex.contains("\\begin{tikzpicture}"),
        "must be a tikzpicture"
    );
    assert!(tex.contains("\\draw[cktsym]"), "must draw device symbols");
    assert!(tex.contains("\\draw[cktwire]"), "must draw wires");
    println!(
        "figure is native TikZ ({} bytes), no converter needed",
        tex.len()
    );
    println!("\n--- {out} ---\n{tex}");
}
