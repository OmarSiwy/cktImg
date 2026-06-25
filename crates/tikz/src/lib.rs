//! Native TikZ/PGF renderer for a placed schematic. Same job as the `svg` crate,
//! same DrawOps — but emits `\draw` commands that `pdflatex` draws itself. No SVG,
//! no raster, no external converter.
//!
//! Coordinates are emitted in absolute `pt` (schematic y is negated, since TikZ is
//! y-up and the placer is y-down). No `x=/y=` unit trickery, so node labels stay
//! upright and circle radii are unambiguous.

use devices::{class_at, DrawOp, CELL_WIDTH};
use ir::{Ir, Orientation, Pt, Strings};
use std::fmt::Write;

const WIRE_HEX: &str = "1565C0";

/// Render a placed IR to a `tikzpicture` (with a leading `\definecolor`). Drop it
/// straight into a document that has `\usepackage{tikz,xcolor}`, or `\input` it.
pub fn render(ir: &Ir, strings: &Strings) -> String {
    let phys = ir.physical.as_ref().expect("render requires a placed IR (physical present)");

    // canonical device point -> placed point
    let tx = |o: Orientation, base: Pt, p: devices::Pt| -> Pt {
        let q = o.apply(Pt::new(p.x, p.y));
        Pt::new(base.x + q.x, base.y + q.y)
    };
    // placed point -> TikZ coordinate literal (pt, y flipped)
    let pt = |p: Pt| format!("({}pt,{}pt)", p.x, -p.y);

    let mut s = String::new();
    let _ = write!(s, "\\definecolor{{cktwire}}{{HTML}}{{{WIRE_HEX}}}%\n");
    s.push_str("\\begin{tikzpicture}[\n");
    s.push_str("  cktsym/.style={draw=black,line width=1.2pt,line cap=round,line join=round},\n");
    s.push_str("  cktwire/.style={draw=cktwire,line width=1.5pt,line cap=round,line join=round},\n");
    s.push_str("  cktdot/.style={fill=cktwire},\n");
    s.push_str("  cktlbl/.style={font=\\tiny,text=black!55,anchor=west,inner sep=1pt}]\n");

    // --- wires (per net, per segment) ---
    for n in 0..ir.nets.len() {
        for seg in phys.net_seg[n] as usize..phys.net_seg[n + 1] as usize {
            let pts = &phys.wire_pts[phys.seg_pt[seg] as usize..phys.seg_pt[seg + 1] as usize];
            if pts.len() < 2 {
                continue;
            }
            s.push_str("  \\draw[cktwire] ");
            for (i, &p) in pts.iter().enumerate() {
                if i > 0 {
                    s.push_str(" -- ");
                }
                s.push_str(&pt(p));
            }
            s.push_str(";\n");
        }
    }

    // --- device symbols + refdes label ---
    for d in 0..ir.devices.len() {
        let o = ir.devices.orient[d];
        let base = phys.pos[d];
        for op in class_at(ir.devices.symbol[d].index()).draw {
            match *op {
                DrawOp::Line(a, b) => {
                    let _ = write!(s, "  \\draw[cktsym] {} -- {};\n", pt(tx(o, base, a)), pt(tx(o, base, b)));
                }
                DrawOp::Polyline(ps) => {
                    s.push_str("  \\draw[cktsym] ");
                    for (i, &p) in ps.iter().enumerate() {
                        if i > 0 {
                            s.push_str(" -- ");
                        }
                        s.push_str(&pt(tx(o, base, p)));
                    }
                    s.push_str(";\n");
                }
                DrawOp::Circle { c, r } => {
                    let _ = write!(s, "  \\draw[cktsym] {} circle[radius={r}pt];\n", pt(tx(o, base, c)));
                }
            }
        }
        let label_at = Pt::new(base.x + CELL_WIDTH / 2 + 3, base.y);
        let _ = write!(s, "  \\node[cktlbl] at {} {{{}}};\n", pt(label_at), esc(strings.get(ir.devices.name[d])));
    }

    // --- pin dots + junctions ---
    for &p in &phys.pin_xy {
        let _ = write!(s, "  \\fill[cktdot] {} circle[radius=1.5pt];\n", pt(p));
    }
    for &p in &phys.junctions {
        let _ = write!(s, "  \\fill[cktdot] {} circle[radius=3pt];\n", pt(p));
    }

    s.push_str("\\end{tikzpicture}\n");
    s
}

/// Escape the TeX specials that can appear in a refdes/name.
fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => o.push_str("\\textbackslash{}"),
            '^' => o.push_str("\\textasciicircum{}"),
            '~' => o.push_str("\\textasciitilde{}"),
            '&' | '%' | '$' | '#' | '_' | '{' | '}' => {
                o.push('\\');
                o.push(c);
            }
            _ => o.push(c),
        }
    }
    o
}
