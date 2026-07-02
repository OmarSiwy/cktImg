#[derive(Copy, Clone, PartialEq, Eq, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct Pt {
    pub x: i32,
    pub y: i32,
}

impl Pt {
    pub const fn new(x: i32, y: i32) -> Self {
        Self { x, y }
    }
}

impl std::ops::Add for Pt {
    type Output = Pt;
    fn add(self, o: Pt) -> Pt {
        Pt::new(self.x + o.x, self.y + o.y)
    }
}

/// An axis-aligned rectangle, `min` the lower-left corner, `max` the upper-right. Used for
/// real collision checking (ALGORITHM.md §"Collision is checked strictly"): a device's box, or
/// a routed wire's bounding box (degenerate in one axis for an axis-aligned segment).
#[derive(Copy, Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct Rect {
    pub min: Pt,
    pub max: Pt,
}

impl Rect {
    pub const fn new(min: Pt, max: Pt) -> Self {
        Self { min, max }
    }

    /// The bounding rectangle of two corners, in any order.
    pub fn from_corners(a: Pt, b: Pt) -> Self {
        Self {
            min: Pt::new(a.x.min(b.x), a.y.min(b.y)),
            max: Pt::new(a.x.max(b.x), a.y.max(b.y)),
        }
    }

    /// Strict (open-interior) overlap: rectangles that merely share an edge or corner do NOT
    /// intersect — a wire is free to run flush along a device's boundary. For an axis-aligned
    /// segment passed as a degenerate rect (min==max in one axis) this reduces to the segment
    /// passing strictly through the other rect's interior on that axis.
    pub fn intersects(&self, other: &Rect) -> bool {
        self.min.x < other.max.x
            && other.min.x < self.max.x
            && self.min.y < other.max.y
            && other.min.y < self.max.y
    }

    /// Is `p` strictly inside this rectangle?
    pub fn contains(&self, p: Pt) -> bool {
        self.min.x < p.x && p.x < self.max.x && self.min.y < p.y && p.y < self.max.y
    }
}

#[derive(Copy, Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[repr(u8)]
pub enum Rot {
    R0 = 0,
    R90 = 1,
    R180 = 2,
    R270 = 3,
}

// Packed: bits [mirror:1][rot:2]. One byte.
#[derive(Copy, Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
pub struct Orientation(u8);

impl Default for Orientation {
    fn default() -> Self {
        Orientation::H
    }
}

impl Orientation {
    pub const H: Orientation = Orientation(0); // R0, no mirror
    pub const V: Orientation = Orientation(Rot::R90 as u8); // R90, no mirror

    pub fn new(rot: Rot, mirror: bool) -> Self {
        Orientation((rot as u8) | ((mirror as u8) << 2))
    }
    pub fn rot(self) -> Rot {
        match self.0 & 0b11 {
            0 => Rot::R0,
            1 => Rot::R90,
            2 => Rot::R180,
            _ => Rot::R270,
        }
    }
    pub fn mirror(self) -> bool {
        self.0 & 0b100 != 0
    }

    // Apply to a canonical (R0) point: mirror flips x, then rotate. Pure integer math.
    pub fn apply(self, p: Pt) -> Pt {
        let p = if self.mirror() { Pt::new(-p.x, p.y) } else { p };
        match self.rot() {
            Rot::R0 => p,
            Rot::R90 => Pt::new(-p.y, p.x),
            Rot::R180 => Pt::new(-p.x, -p.y),
            Rot::R270 => Pt::new(p.y, -p.x),
        }
    }
}
