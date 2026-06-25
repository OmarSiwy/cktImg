//! Minimal SVG renderer for a placed schematic. Takes a `Placed` IR (device positions +
//! wires in `physical`) and the string pool (for refdes labels), emits an SVG string. Pure
//! data transformation: coordinates → markup, no layout decisions here.

use devices::{class_at, DrawOp};
use ir::{Ir, Orientation, Pt, Strings};
use std::fmt::Write;

/// Render a placed IR to an SVG document.
pub fn render(ir: &Ir, strings: &Strings) -> String {
    let phys = ir.physical.as_ref().expect("render requires a placed IR (physical present)");

    // Opinion-based style from lint.toml.
    let r = &config::cfg().render;
    let stroke = r.stroke.as_str();
    let wire = format!("#{}", r.wire);
    let sym_w = r.sym_w;
    let wire_w = r.wire_w;

    // device symbol transform: canonical point → screen point
    let tx = |o: Orientation, base: Pt, p: devices::Pt| -> Pt {
        let q = o.apply(Pt::new(p.x, p.y));
        Pt::new(base.x + q.x, base.y + q.y)
    };

    // --- bounds over device bodies, wires, pins ---
    let mut bb = Bounds::new();
    for d in 0..ir.devices.len() {
        let o = ir.devices.orient[d];
        let base = phys.pos[d];
        for op in class_at(ir.devices.symbol[d].index()).draw {
            match *op {
                DrawOp::Line(a, b) => {
                    bb.hit(tx(o, base, a));
                    bb.hit(tx(o, base, b));
                }
                DrawOp::Polyline(ps) => ps.iter().for_each(|&p| bb.hit(tx(o, base, p))),
                DrawOp::Circle { c, r } => {
                    let q = tx(o, base, c);
                    bb.hit(Pt::new(q.x - r, q.y - r));
                    bb.hit(Pt::new(q.x + r, q.y + r));
                }
            }
        }
    }
    phys.wire_pts.iter().for_each(|&p| bb.hit(p));
    phys.pin_xy.iter().for_each(|&p| bb.hit(p));
    let (minx, miny, w, h) = bb.viewbox(r.pad);

    let mut s = String::new();
    let _ = write!(
        s,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{minx} {miny} {w} {h}\" font-family=\"sans-serif\">\n"
    );
    let _ = write!(s, "<rect x=\"{minx}\" y=\"{miny}\" width=\"{w}\" height=\"{h}\" fill=\"white\"/>\n");

    // --- wires (per net, per segment) ---
    for n in 0..ir.nets.len() {
        for seg in phys.net_seg[n] as usize..phys.net_seg[n + 1] as usize {
            let pts = &phys.wire_pts[phys.seg_pt[seg] as usize..phys.seg_pt[seg + 1] as usize];
            if pts.len() < 2 {
                continue;
            }
            let _ = write!(s, "<polyline points=\"");
            for p in pts {
                let _ = write!(s, "{},{} ", p.x, p.y);
            }
            let _ = write!(s, "\" fill=\"none\" stroke=\"{wire}\" stroke-width=\"{wire_w}\"/>\n");
        }
    }

    // --- device symbols + refdes label ---
    for d in 0..ir.devices.len() {
        let o = ir.devices.orient[d];
        let base = phys.pos[d];
        for op in class_at(ir.devices.symbol[d].index()).draw {
            match *op {
                DrawOp::Line(a, b) => {
                    let (a, b) = (tx(o, base, a), tx(o, base, b));
                    let _ = write!(s, "<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"{stroke}\" stroke-width=\"{sym_w}\"/>\n", a.x, a.y, b.x, b.y);
                }
                DrawOp::Polyline(ps) => {
                    let _ = write!(s, "<polyline points=\"");
                    for &p in ps {
                        let q = tx(o, base, p);
                        let _ = write!(s, "{},{} ", q.x, q.y);
                    }
                    let _ = write!(s, "\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"{sym_w}\"/>\n");
                }
                DrawOp::Circle { c, r } => {
                    let q = tx(o, base, c);
                    let _ = write!(s, "<circle cx=\"{}\" cy=\"{}\" r=\"{r}\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"{sym_w}\"/>\n", q.x, q.y);
                }
            }
        }
        let name = strings.get(ir.devices.name[d]);
        let _ = write!(s, "<text x=\"{}\" y=\"{}\" font-size=\"7\" fill=\"#444\">{}</text>\n", base.x + devices::CELL_WIDTH / 2 + 3, base.y, esc(name));
    }

    // --- pin dots + junctions ---
    for &p in &phys.pin_xy {
        let _ = write!(s, "<circle cx=\"{}\" cy=\"{}\" r=\"1.5\" fill=\"{wire}\"/>\n", p.x, p.y);
    }
    for &p in &phys.junctions {
        let _ = write!(s, "<circle cx=\"{}\" cy=\"{}\" r=\"3\" fill=\"{wire}\"/>\n", p.x, p.y);
    }

    s.push_str("</svg>\n");
    s
}

struct Bounds {
    minx: i32,
    miny: i32,
    maxx: i32,
    maxy: i32,
}
impl Bounds {
    fn new() -> Self {
        Bounds { minx: i32::MAX, miny: i32::MAX, maxx: i32::MIN, maxy: i32::MIN }
    }
    fn hit(&mut self, p: Pt) {
        self.minx = self.minx.min(p.x);
        self.miny = self.miny.min(p.y);
        self.maxx = self.maxx.max(p.x);
        self.maxy = self.maxy.max(p.y);
    }
    fn viewbox(&self, pad: i32) -> (i32, i32, i32, i32) {
        if self.minx > self.maxx {
            return (0, 0, 1, 1); // empty
        }
        (self.minx - pad, self.miny - pad, (self.maxx - self.minx) + 2 * pad, (self.maxy - self.miny) + 2 * pad)
    }
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}
