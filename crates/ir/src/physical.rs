use crate::geom::Pt;
use crate::ids::NetIdx;

// Born ONLY in the resolver. All SoA; indices align with the logical layer. Wires are a
// nested CSR: net -> segments (via net_seg), segment -> points (via seg_pt). A 2-pin net is
// one or two segments; a multi-pin net is a trunk + stubs.
#[derive(serde::Serialize, serde::Deserialize)]
pub struct Physical {
    pub pos: Vec<Pt>,      // by DeviceIdx
    pub pin_xy: Vec<Pt>,   // by PinIdx — parallels Pins exactly, zero lookups
    pub net_seg: Vec<u32>, // CSR by NetIdx into seg_pt; len == nets + 1
    pub seg_pt: Vec<u32>,  // CSR by segment into wire_pts; len == segments + 1
    pub wire_pts: Vec<Pt>,
    pub junctions: Vec<Pt>,
}

impl Physical {
    // Polyline segments of a net's wiring, in deterministic order (trunk then stubs).
    pub fn segments(&self, n: NetIdx) -> impl Iterator<Item = &[Pt]> + '_ {
        let s = self.net_seg[n.index()] as usize;
        let e = self.net_seg[n.index() + 1] as usize;
        (s..e).map(move |seg| {
            let a = self.seg_pt[seg] as usize;
            let b = self.seg_pt[seg + 1] as usize;
            &self.wire_pts[a..b]
        })
    }
}
