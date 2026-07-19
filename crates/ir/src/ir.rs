use crate::error::LogicalError;
use crate::ids::*;
use crate::logical::*;
use crate::physical::Physical;
use core::marker::PhantomData;

/// The whole IR: SoA circuit topology plus (once placed) geometry.
/// Names are session StrIds resolved via the interner pool; the IR does not own strings.
#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct Ir {
    pub devices: Devices,
    pub pins: Pins,
    pub nets: Nets,
    pub physical: Option<Physical>,
}

impl Ir {
    /// Bulk structural validation — pure array scans, never panics. `n_symbols` is the size
    /// of the `devices` class table, passed in so the IR stays ignorant of device semantics.
    ///
    /// # Errors
    /// The first malformed cross-reference found (bad symbol, bad net, malformed pin CSR).
    pub fn validate(&self, n_symbols: usize) -> Result<(), LogicalError> {
        if self.devices.pin0.len() != self.devices.len() + 1 {
            return Err(LogicalError::BadPinCsr {
                expected: self.devices.len() + 1,
                found: self.devices.pin0.len(),
            });
        }
        for (i, s) in self.devices.symbol.iter().enumerate() {
            if s.index() >= n_symbols {
                return Err(LogicalError::BadSymbol(DeviceIdx(i as u32)));
            }
        }
        for (i, net) in self.pins.net.iter().enumerate() {
            if let Some(net) = net {
                if net.index() >= self.nets.len() {
                    return Err(LogicalError::BadNet(PinIdx(i as u32)));
                }
            }
        }
        Ok(())
    }
}

// ---- typestate: emitting output before resolution is a COMPILE error ----

/// Typestate marker: no geometry yet.
pub enum Unplaced {}
/// Typestate marker: geometry resolved, `physical` is `Some`.
pub enum Placed {}

/// An [`Ir`] tagged with its placement state.
pub struct Schematic<S = Unplaced> {
    ir: Ir,
    _s: PhantomData<S>,
}

impl Schematic<Unplaced> {
    pub fn new(ir: Ir) -> Self {
        Schematic {
            ir,
            _s: PhantomData,
        }
    }
    pub fn ir(&self) -> &Ir {
        &self.ir
    }
    pub fn into_ir(self) -> Ir {
        self.ir
    }
}

impl Schematic<Placed> {
    /// The single promotion point (called by the resolver). Takes Physical by value, so the
    /// invariant "Placed => physical is Some" holds by construction.
    pub fn from_resolved(mut ir: Ir, physical: Physical) -> Self {
        ir.physical = Some(physical);
        Schematic {
            ir,
            _s: PhantomData,
        }
    }
    pub fn ir(&self) -> &Ir {
        &self.ir
    }
    pub fn physical(&self) -> &Physical {
        self.ir
            .physical
            .as_ref()
            .expect("Placed schematic always has physical")
    }
}
