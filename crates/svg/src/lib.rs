//! Minimal SVG renderer for a placed schematic. Takes a `Placed` IR (device positions +
//! wires in `physical`) and the string pool (for refdes labels), emits an SVG string. Pure
//! data transformation: coordinates → markup, no layout decisions here.

use devices::{DrawOp, class_at};
use ir::{Ir, NetIdx, Orientation, Pt, Strings};
use std::fmt::Write;

/// Render a placed IR to an SVG document.
#[must_use]
pub fn render(ir: &Ir, strings: &Strings) -> String {
    let phys = ir
        .physical
        .as_ref()
        .expect("render requires a placed IR (physical present)");

    // Opinion-based style from lint.toml.
    let r = &config::cfg().render;
    let stroke = r.stroke.as_str();
    let wire = format!("#{}", r.wire);
    let sym_w = r.sym_w;
    let wire_w = r.wire_w;

    // device symbol transform: canonical point → screen point
    let tx = |o: Orientation, base: Pt, p: devices::Pt| -> Pt { base + o.apply(Pt::new(p.x, p.y)) };

    // Refdes label anchors: collision-avoided on the layout side (shared with tikz).
    // `textLength` below forces the rendered width to exactly match the collision box,
    // so the avoidance holds in any viewer regardless of its sans-serif metrics.
    let anchors = build::refdes_anchors(ir, strings, phys);
    let label_end =
        |a: Pt, name: &str| Pt::new(a.x + build::refdes_width(name), a.y - build::TEXT_H);

    // --- bounds over device bodies, wires, pins, labels ---
    let mut bb = Bounds::new();
    for (d, &anchor) in anchors.iter().enumerate() {
        let o = ir.devices.orient[d];
        let base = phys.pos[d];
        bb.hit(Pt::new(anchor.x, anchor.y + build::DESCENT));
        bb.hit(label_end(anchor, strings.get(ir.devices.name[d])));
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
    let _ = writeln!(
        s,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{minx} {miny} {w} {h}\" font-family=\"sans-serif\">"
    );
    let _ = writeln!(
        s,
        "<rect x=\"{minx}\" y=\"{miny}\" width=\"{w}\" height=\"{h}\" fill=\"white\"/>"
    );

    // --- wires (per net, per segment) ---
    for n in 0..ir.nets.len() {
        for pts in phys.segments(NetIdx::from_index(n)) {
            if pts.len() < 2 {
                continue;
            }
            let _ = write!(s, "<polyline points=\"");
            for p in pts {
                let _ = write!(s, "{},{} ", p.x, p.y);
            }
            let _ = writeln!(
                s,
                "\" fill=\"none\" stroke=\"{wire}\" stroke-width=\"{wire_w}\"/>"
            );
        }
    }

    // --- device symbols + refdes label ---
    for (d, &at) in anchors.iter().enumerate() {
        let o = ir.devices.orient[d];
        let base = phys.pos[d];
        for op in class_at(ir.devices.symbol[d].index()).draw {
            match *op {
                DrawOp::Line(a, b) => {
                    let (a, b) = (tx(o, base, a), tx(o, base, b));
                    let _ = writeln!(
                        s,
                        "<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\" stroke=\"{stroke}\" stroke-width=\"{sym_w}\"/>",
                        a.x, a.y, b.x, b.y
                    );
                }
                DrawOp::Polyline(ps) => {
                    let _ = write!(s, "<polyline points=\"");
                    for &p in ps {
                        let q = tx(o, base, p);
                        let _ = write!(s, "{},{} ", q.x, q.y);
                    }
                    let _ = writeln!(
                        s,
                        "\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"{sym_w}\"/>"
                    );
                }
                DrawOp::Circle { c, r } => {
                    let q = tx(o, base, c);
                    let _ = writeln!(
                        s,
                        "<circle cx=\"{}\" cy=\"{}\" r=\"{r}\" fill=\"none\" stroke=\"{stroke}\" stroke-width=\"{sym_w}\"/>",
                        q.x, q.y
                    );
                }
            }
        }
        let name = strings.get(ir.devices.name[d]);
        let _ = writeln!(
            s,
            "<text x=\"{}\" y=\"{}\" font-size=\"7\" fill=\"#444\" textLength=\"{}\" lengthAdjust=\"spacingAndGlyphs\">{}</text>",
            at.x,
            at.y,
            build::refdes_width(name) - 2, // box width minus its padding
            esc(name)
        );
    }

    // --- pin dots + junctions ---
    for &p in &phys.pin_xy {
        let _ = writeln!(
            s,
            "<circle cx=\"{}\" cy=\"{}\" r=\"1.5\" fill=\"{wire}\"/>",
            p.x, p.y
        );
    }
    for &p in &phys.junctions {
        let _ = writeln!(
            s,
            "<circle cx=\"{}\" cy=\"{}\" r=\"3\" fill=\"{wire}\"/>",
            p.x, p.y
        );
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
        Bounds {
            minx: i32::MAX,
            miny: i32::MAX,
            maxx: i32::MIN,
            maxy: i32::MIN,
        }
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
        (
            self.minx - pad,
            self.miny - pad,
            (self.maxx - self.minx) + 2 * pad,
            (self.maxy - self.miny) + 2 * pad,
        )
    }
}

fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c => out.push(c),
        }
    }
    out
}
