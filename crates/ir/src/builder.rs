use crate::geom::Orientation;
use crate::ids::*;
use crate::ir::{Ir, Schematic, Unplaced};
use crate::logical::*;
use crate::strings::Interner;
use std::collections::HashMap;

// Low-level constructor. Borrows the shared interner and holds the name->idx scaffolding
// maps; the maps are dropped at `finish` and never enter `Ir`.
pub struct IrBuilder<'i> {
    interner: &'i mut Interner,
    devices: Devices,
    pins: Pins,
    nets: Nets,
    device_ix: HashMap<StrId, DeviceIdx>,
    net_ix: HashMap<StrId, NetIdx>,
    cur_pins: u32, // running pin count for the CSR
}

impl<'i> IrBuilder<'i> {
    pub fn new(interner: &'i mut Interner) -> Self {
        let mut b = IrBuilder {
            interner,
            devices: Devices::default(),
            pins: Pins::default(),
            nets: Nets::default(),
            device_ix: HashMap::new(),
            net_ix: HashMap::new(),
            cur_pins: 0,
        };
        b.devices.pin0.push(PinIdx(0)); // CSR base offset
        b
    }

    pub fn intern(&mut self, s: &str) -> StrId {
        self.interner.intern(s)
    }

    pub fn net(&mut self, name: &str) -> NetIdx {
        let id = self.interner.intern(name);
        if let Some(&n) = self.net_ix.get(&id) {
            return n;
        }
        let n = NetIdx::from_index(self.nets.len());
        self.nets.name.push(id);
        self.net_ix.insert(id, n);
        n
    }

    // Add a device and its pins. `pins` are the nets each terminal touches, in the symbol's
    // terminal (slot) order — the parser resolves `s=vdd` to slot order before calling this.
    pub fn device(
        &mut self,
        name: &str,
        symbol: SymbolIdx,
        value: &str,
        orient: Orientation,
        pins: &[Option<&str>],
    ) -> DeviceIdx {
        let d = DeviceIdx(self.devices.len() as u32);
        let nm = self.interner.intern(name);
        let val = self.interner.intern(value);
        self.devices.name.push(nm);
        self.devices.symbol.push(symbol);
        self.devices.value.push(val);
        self.devices.orient.push(orient);
        for net in pins {
            let net = net.map(|n| self.net(n));
            self.pins.net.push(net);
            self.cur_pins += 1;
        }
        self.devices.pin0.push(PinIdx(self.cur_pins)); // CSR end-of-device sentinel
        self.device_ix.insert(nm, d);
        d
    }

    pub fn device_idx(&self, name: &str) -> Option<DeviceIdx> {
        self.interner
            .get_id(name)
            .and_then(|id| self.device_ix.get(&id).copied())
    }

    pub fn finish(self) -> Schematic<Unplaced> {
        Schematic::new(Ir {
            devices: self.devices,
            pins: self.pins,
            nets: self.nets,
            physical: None,
        })
    }
}
