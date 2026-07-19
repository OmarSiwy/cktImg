use core::num::NonZeroU32;

macro_rules! idx {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
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
            /// This id as a `usize` array index.
            #[inline]
            #[must_use]
            pub fn index(self) -> usize {
                self.0 as usize
            }
        }
    };
}

idx!(
    /// Index into the [`crate::Devices`] arrays.
    DeviceIdx
);
idx!(
    /// Index into the [`crate::Pins`] arrays.
    PinIdx
);
idx!(
    /// Opaque: indexes the `devices` class table; IR never interprets it.
    SymbolIdx
);
idx!(
    /// Id of an interned string in the [`crate::Strings`] pool.
    StrId
);

/// Index into the [`crate::Nets`] arrays. Wraps `NonZeroU32` so `Option<NetIdx>`
/// niche-optimizes to 4 bytes and a floating pin is `None`.
/// Stored value = index + 1; index 0 maps to NonZero(1).
#[derive(
    Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug, serde::Serialize, serde::Deserialize,
)]
pub struct NetIdx(NonZeroU32);

impl NetIdx {
    /// The `NetIdx` for array index `i`.
    #[inline]
    #[must_use]
    pub fn from_index(i: usize) -> Self {
        match NonZeroU32::new(i as u32 + 1) {
            Some(nz) => NetIdx(nz),
            None => unreachable!("net index + 1 is always nonzero"),
        }
    }
    /// This id as a `usize` array index.
    #[inline]
    #[must_use]
    pub fn index(self) -> usize {
        (self.0.get() - 1) as usize
    }
}
