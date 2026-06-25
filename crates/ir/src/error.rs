use crate::ids::{DeviceIdx, PinIdx};

#[derive(Debug, thiserror::Error)]
pub enum LogicalError {
    #[error("device {0:?} references a symbol index out of range")]
    BadSymbol(DeviceIdx),
    #[error("pin {0:?} references a net index out of range")]
    BadNet(PinIdx),
    #[error("pin0 CSR malformed: expected {expected} entries, found {found}")]
    BadPinCsr { expected: usize, found: usize },
}
