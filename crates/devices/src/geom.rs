//! Integer-grid geometry: points, draw primitives, bounding boxes.

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
