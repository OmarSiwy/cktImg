//! The intermediate representation: pure topology data, produced once and consumed by the
//! semantic crates (`devices`, `groups`) through their own query traits. The IR knows
//! nothing about what a transistor is or what a current mirror is — it stores only what
//! cannot be derived. Everything semantic is a function over this data, computed elsewhere.

pub mod builder;
pub mod csr;
pub mod error;
pub mod geom;
pub mod ids;
pub mod ir;
pub mod logical;
pub mod physical;
pub mod strings;

pub use builder::IrBuilder;
pub use csr::NetCsr;
pub use error::LogicalError;
pub use geom::{Orientation, Pt, Rect, Rot};
pub use ids::{DeviceIdx, NetIdx, PinIdx, StrId, SymbolIdx};
pub use ir::{Ir, Placed, Schematic, Unplaced};
pub use logical::{Devices, Nets, Pins};
pub use physical::{Label, Physical};
pub use strings::{Interner, Strings};
