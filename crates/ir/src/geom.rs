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
