use core::num::NonZeroU32;

macro_rules! idx {
    ($name:ident) => {
        #[derive(
            Copy,
            Clone,
            PartialEq,
            Eq,
            Hash,
            PartialOrd,
            Ord,
            Debug,
            serde::Serialize,
            serde::Deserialize,
        )]
        pub struct $name(pub u32);
        impl $name {
            #[inline]
            pub fn index(self) -> usize {
                self.0 as usize
            }
        }
    };
}

idx!(DeviceIdx);
idx!(PinIdx);
idx!(SymbolIdx); // opaque: indexes the `devices` class table; IR never interprets it
idx!(StrId);

// NetIdx wraps NonZeroU32 so `Option<NetIdx>` niche-optimizes to 4 bytes and a floating pin
// is `None`. Stored value = index + 1; index 0 maps to NonZero(1).
#[derive(
    Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug, serde::Serialize, serde::Deserialize,
)]
pub struct NetIdx(NonZeroU32);

impl NetIdx {
    #[inline]
    pub fn from_index(i: usize) -> Self {
        match NonZeroU32::new(i as u32 + 1) {
            Some(nz) => NetIdx(nz),
            None => unreachable!("net index + 1 is always nonzero"),
        }
    }
    #[inline]
    pub fn index(self) -> usize {
        (self.0.get() - 1) as usize
    }
}
