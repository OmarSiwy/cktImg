//! Refdes label placement: a collision-free text anchor per device.
//!
//! Placement is a layout decision, so it lives here — the svg/tikz renderers just
//! draw text at the returned point (left edge, baseline; SVG `<text>` semantics,
//! TikZ `anchor=base west`).
//!
//! For each device the preferred spot (right of the cell, vertically centered) is
//! tried first, then nudges above/below/left, against every wire segment, device
//! body, pin dot, junction, and label already placed. First clear spot wins; if
//! all collide the preferred spot is kept — a readable overlap beats a runaway label.

use devices::{CELL_WIDTH, class_at};
use ir::{Ir, Physical, Pt, Rect, Strings};

/// Text metrics the collision box guarantees — not estimates. Per char, 5 units:
/// the SVG backend forces exactly this advance via `textLength`; the TikZ backend
/// wraps the label in a `\makebox` of exactly this width, and no Computer Modern
/// glyph at `\tiny` (5pt) exceeds it (widest: 'M' ≈ 4.58pt). Height 7 covers a
/// 7px SVG em box and 5pt TeX text; descent 2 covers descenders (g, y, p, q, j)
/// hanging below the baseline in both.
pub const CHAR_W: i32 = 5;
pub const TEXT_H: i32 = 7;
pub const DESCENT: i32 = 2;
/// Breathing room between the device cell and the label's left edge.
const GAP: i32 = 3;

/// Width of a refdes label's collision box — the exact width both renderers draw.
pub fn refdes_width(name: &str) -> i32 {
    CHAR_W * name.len() as i32 + 2
}

/// Anchor (left edge, baseline) for each device's refdes label. Index = DeviceIdx.
pub fn refdes_anchors(ir: &Ir, strings: &Strings, phys: &Physical) -> Vec<Pt> {
    let mut obstacles = obstacle_rects(ir, phys);
    let mut anchors = Vec::with_capacity(ir.devices.len());

    for d in 0..ir.devices.len() {
        let base = phys.pos[d];
        let w = refdes_width(strings.get(ir.devices.name[d]));
        let right = base.x + CELL_WIDTH / 2 + GAP;
        let left = base.x - CELL_WIDTH / 2 - GAP - w;
        // Preference: right → right-above → right-below → left → left-above → left-below.
        let candidates = [
            Pt::new(right, base.y),
            Pt::new(right, base.y - (TEXT_H + DESCENT + GAP)),
            Pt::new(right, base.y + TEXT_H + DESCENT + GAP),
            Pt::new(left, base.y),
            Pt::new(left, base.y - (TEXT_H + DESCENT + GAP)),
            Pt::new(left, base.y + TEXT_H + DESCENT + GAP),
        ];
        let rect_at =
            |a: Pt| Rect::new(Pt::new(a.x, a.y - TEXT_H), Pt::new(a.x + w, a.y + DESCENT));
        let at = candidates
            .into_iter()
            .find(|&a| {
                let r = rect_at(a);
                !obstacles.iter().any(|o| o.intersects(&r))
            })
            .unwrap_or(candidates[0]);
        obstacles.push(rect_at(at)); // later labels dodge this one too
        anchors.push(at);
    }
    anchors
}

/// Everything a label must not sit on, as strict-overlap rects.
fn obstacle_rects(ir: &Ir, phys: &Physical) -> Vec<Rect> {
    let mut out = Vec::new();

    // Wire segments: each polyline edge as a degenerate rect, inflated to stroke width.
    for n in 0..ir.nets.len() {
        for seg in phys.net_seg[n] as usize..phys.net_seg[n + 1] as usize {
            let pts = &phys.wire_pts[phys.seg_pt[seg] as usize..phys.seg_pt[seg + 1] as usize];
            for pair in pts.windows(2) {
                out.push(inflate(Rect::from_corners(pair[0], pair[1]), 1));
            }
        }
    }

    // Device bodies: canonical bbox, oriented and translated like the renderers do.
    for d in 0..ir.devices.len() {
        let o = ir.devices.orient[d];
        let base = phys.pos[d];
        let bb = class_at(ir.devices.symbol[d].index()).bbox();
        let a = base + o.apply(Pt::new(bb.min.x, bb.min.y));
        let b = base + o.apply(Pt::new(bb.max.x, bb.max.y));
        out.push(Rect::from_corners(a, b));
    }

    // Pin dots (r=1.5) and junctions (r=3).
    for &p in &phys.pin_xy {
        out.push(inflate(Rect::new(p, p), 2));
    }
    for &p in &phys.junctions {
        out.push(inflate(Rect::new(p, p), 3));
    }
    out
}

fn inflate(r: Rect, by: i32) -> Rect {
    Rect::new(
        Pt::new(r.min.x - by, r.min.y - by),
        Pt::new(r.max.x + by, r.max.y + by),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // ponytail: one end-to-end check — anchors clear the wires on a real circuit.
    #[test]
    fn anchors_avoid_wires() {
        let mut it = ir::Interner::default();
        let (sch, _) = netlist::parse(
            "R1 vdd out 5k\nM1 out in gnd nmos\nXVDD vdd vdd\nXGND gnd gnd\n",
            &mut it,
        );
        let placed = crate::layout(sch);
        let (ir, s) = (placed.ir(), it.pool());
        let phys = ir.physical.as_ref().unwrap();
        let anchors = refdes_anchors(ir, s, phys);
        assert_eq!(anchors.len(), ir.devices.len());

        // No label rect may cross a wire segment.
        for (d, &a) in anchors.iter().enumerate() {
            let w = refdes_width(s.get(ir.devices.name[d]));
            let r = Rect::new(Pt::new(a.x, a.y - TEXT_H), Pt::new(a.x + w, a.y + DESCENT));
            for n in 0..ir.nets.len() {
                for seg in phys.net_seg[n] as usize..phys.net_seg[n + 1] as usize {
                    let pts =
                        &phys.wire_pts[phys.seg_pt[seg] as usize..phys.seg_pt[seg + 1] as usize];
                    for pair in pts.windows(2) {
                        let wire = Rect::from_corners(pair[0], pair[1]);
                        assert!(
                            !wire.intersects(&r),
                            "label {d} at {a:?} crosses wire {:?}-{:?}",
                            pair[0],
                            pair[1]
                        );
                    }
                }
            }
        }
    }
}
