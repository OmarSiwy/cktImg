use crate::ids::{NetIdx, PinIdx};
use crate::logical::{Nets, Pins};

/// Derived net -> pins adjacency. Built on demand in one O(pins) counting-sort pass.
/// Deterministic: members emitted in ascending PinIdx order.
pub struct NetCsr {
    pub offsets: Vec<u32>, // len == nets + 1
    pub pins: Vec<PinIdx>,
}

impl NetCsr {
    /// Build the adjacency from the pin -> net column.
    #[must_use]
    pub fn build(pins: &Pins, nets: &Nets) -> Self {
        let n = nets.len();
        let mut offsets = vec![0u32; n + 1];
        for net in pins.net.iter().flatten() {
            offsets[net.index() + 1] += 1; // count into i+1 for an in-place prefix sum
        }
        for i in 0..n {
            offsets[i + 1] += offsets[i];
        }

        let mut cursor = offsets.clone();
        let mut out = vec![PinIdx(0); offsets[n] as usize];
        for (pi, net) in pins.net.iter().enumerate() {
            if let Some(net) = net {
                let slot = &mut cursor[net.index()];
                out[*slot as usize] = PinIdx(pi as u32);
                *slot += 1;
            }
        }
        NetCsr { offsets, pins: out }
    }

    /// The pins on `net`, in ascending `PinIdx` order.
    pub fn members(&self, net: NetIdx) -> &[PinIdx] {
        let a = self.offsets[net.index()] as usize;
        let b = self.offsets[net.index() + 1] as usize;
        &self.pins[a..b]
    }
}
