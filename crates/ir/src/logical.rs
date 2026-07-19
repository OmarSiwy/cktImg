use crate::geom::Orientation;
use crate::ids::*;
use std::ops::Range;

/// Devices: struct-of-arrays, indexed by [`DeviceIdx`].
#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct Devices {
    pub name: Vec<StrId>,
    pub symbol: Vec<SymbolIdx>,
    pub value: Vec<StrId>,
    pub orient: Vec<Orientation>,
    pub pin0: Vec<PinIdx>, // CSR offsets into Pins; len == devices + 1 (trailing sentinel)
}

impl Devices {
    pub fn len(&self) -> usize {
        self.name.len()
    }
    pub fn is_empty(&self) -> bool {
        self.name.is_empty()
    }
    /// The pin indices of device `d` (a contiguous CSR slice of the pin arrays).
    pub fn pin_range(&self, d: DeviceIdx) -> Range<usize> {
        self.pin0[d.index()].index()..self.pin0[d.index() + 1].index()
    }
}

/// Pins: one entry per pin, in symbol terminal order. A pin stores ONLY the net it
/// touches (paper §2.1); its name is the symbol terminal's name, derived from class + slot.
#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct Pins {
    pub net: Vec<Option<NetIdx>>, // None = floating; niche keeps this 4 bytes/entry
}

impl Pins {
    pub fn len(&self) -> usize {
        self.net.len()
    }
    pub fn is_empty(&self) -> bool {
        self.net.is_empty()
    }
}

/// Nets: members deliberately ABSENT — derived on demand via [`crate::NetCsr`].
#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct Nets {
    pub name: Vec<StrId>,
}

impl Nets {
    pub fn len(&self) -> usize {
        self.name.len()
    }
    pub fn is_empty(&self) -> bool {
        self.name.is_empty()
    }
}

// No constraints. The placement algorithm (paper §5) is a pure function of the netlist, the
// symbol geometry, and the chosen column order — it authors every coordinate and consumes no
// user-supplied placement hints. Anything an `At`/`Rel`/`Align`/`Abut` constraint used to
// express is derived, so the IR carries none.
