//! The seam: consume the one-time IR into the query layer the placement engine reads.
//! Every derived index (pin→device, net→pins, net class) is computed once here; the engine
//! never touches IR layout directly.

use devices::{DeviceClass, SymbolRole, TerminalRole};
use ir::{DeviceIdx, Ir, NetCsr, NetIdx, PinIdx};

/// Derived electrical class of a net — from the rail device classes on it, never its name.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum NetClass {
    Signal,
    Power,
    Ground,
}

pub struct Ctx<'a> {
    pub ir: &'a Ir,
    pin_dev: Vec<DeviceIdx>,
    csr: NetCsr,
    net_class: Vec<NetClass>,
    // Conducting pins per device as a CSR (Tier-A precompute): flat pin array + per-device
    // offsets (len nd+1). Topology-invariant, so it's built once and read as a slice.
    cond_pins: Vec<PinIdx>,
    cond_off: Vec<u32>,
}

impl<'a> Ctx<'a> {
    pub fn build(ir: &'a Ir) -> Self {
        let mut pin_dev = vec![DeviceIdx(0); ir.pins.len()];
        for d in 0..ir.devices.len() {
            for p in ir.devices.pin_range(DeviceIdx(d as u32)) {
                pin_dev[p] = DeviceIdx(d as u32);
            }
        }
        let csr = NetCsr::build(&ir.pins, &ir.nets);
        let mut net_class = vec![NetClass::Signal; ir.nets.len()];
        for n in 0..ir.nets.len() {
            let (mut pwr, mut gnd) = (false, false);
            for &pin in csr.members(NetIdx::from_index(n)) {
                match Self::class_of(ir, pin_dev[pin.index()]).role {
                    SymbolRole::PowerRail => pwr = true,
                    SymbolRole::GroundRail => gnd = true,
                    _ => {}
                }
            }
            net_class[n] = if pwr {
                NetClass::Power
            } else if gnd {
                NetClass::Ground
            } else {
                NetClass::Signal
            };
        }
        let mut cond_pins: Vec<PinIdx> = Vec::with_capacity(ir.pins.len());
        let mut cond_off = vec![0u32; ir.devices.len() + 1];
        for d in 0..ir.devices.len() {
            let cls = Self::class_of(ir, DeviceIdx(d as u32));
            for (slot, p) in ir.devices.pin_range(DeviceIdx(d as u32)).enumerate() {
                if cls.terminals[slot].role.conducts() {
                    cond_pins.push(PinIdx(p as u32));
                }
            }
            cond_off[d + 1] = cond_pins.len() as u32;
        }
        Ctx { ir, pin_dev, csr, net_class, cond_pins, cond_off }
    }

    fn class_of(ir: &Ir, d: DeviceIdx) -> &'static DeviceClass {
        devices::class_at(ir.devices.symbol[d.index()].index())
    }

    pub fn nd(&self) -> usize {
        self.ir.devices.len()
    }
    pub fn nn(&self) -> usize {
        self.ir.nets.len()
    }
    pub fn class(&self, d: DeviceIdx) -> &'static DeviceClass {
        Self::class_of(self.ir, d)
    }
    pub fn role(&self, d: DeviceIdx) -> SymbolRole {
        self.class(d).role
    }
    pub fn is_rail(&self, d: DeviceIdx) -> bool {
        matches!(self.role(d), SymbolRole::PowerRail | SymbolRole::GroundRail)
    }
    pub fn orient(&self, d: DeviceIdx) -> ir::Orientation {
        self.ir.devices.orient[d.index()]
    }
    pub fn dev_of(&self, p: PinIdx) -> DeviceIdx {
        self.pin_dev[p.index()]
    }
    pub fn net_of(&self, p: PinIdx) -> Option<NetIdx> {
        self.ir.pins.net[p.index()]
    }
    pub fn members(&self, n: NetIdx) -> &[PinIdx] {
        self.csr.members(n)
    }
    pub fn net_class(&self, n: NetIdx) -> NetClass {
        self.net_class[n.index()]
    }
    pub fn is_ground(&self, n: NetIdx) -> bool {
        self.net_class(n) == NetClass::Ground
    }
    pub fn degree(&self, n: NetIdx) -> usize {
        self.members(n).len()
    }
    pub fn pins(&self, d: DeviceIdx) -> impl Iterator<Item = PinIdx> + '_ {
        self.ir.devices.pin_range(d).map(|p| PinIdx(p as u32))
    }
    pub fn pin_slot(&self, p: PinIdx) -> usize {
        p.index() - self.ir.devices.pin0[self.dev_of(p).index()].index()
    }
    pub fn role_of(&self, p: PinIdx) -> TerminalRole {
        self.class(self.dev_of(p)).terminals[self.pin_slot(p)].role
    }
    pub fn term_at(&self, p: PinIdx) -> devices::Pt {
        self.class(self.dev_of(p)).terminals[self.pin_slot(p)].at
    }
    pub fn conducts(&self, p: PinIdx) -> bool {
        self.role_of(p).conducts()
    }
    pub fn conducting_pins(&self, d: DeviceIdx) -> &[PinIdx] {
        let (s, e) = (self.cond_off[d.index()] as usize, self.cond_off[d.index() + 1] as usize);
        &self.cond_pins[s..e]
    }
    pub fn power_nets(&self) -> Vec<NetIdx> {
        (0..self.nn())
            .map(NetIdx::from_index)
            .filter(|&n| self.net_class(n) == NetClass::Power)
            .collect()
    }
}
