use crate::ids::StrId;
use std::collections::HashMap;

/// Persisted string pool: bytes + span table, indexed by [`StrId`]. No map field.
#[derive(Default, Clone, serde::Serialize, serde::Deserialize)]
pub struct Strings {
    bytes: Vec<u8>,
    spans: Vec<Span>, // index == StrId
}

#[derive(Copy, Clone, serde::Serialize, serde::Deserialize)]
struct Span {
    off: u32,
    len: u32,
}

impl Strings {
    pub fn len(&self) -> usize {
        self.spans.len()
    }
    pub fn is_empty(&self) -> bool {
        self.spans.is_empty()
    }
    /// The string for `id`.
    ///
    /// # Panics
    /// If `id` was not interned in this pool.
    pub fn get(&self, id: StrId) -> &str {
        let s = self.spans[id.index()];
        let bytes = &self.bytes[s.off as usize..(s.off + s.len) as usize];
        // Invariant: only valid UTF-8 is ever interned.
        core::str::from_utf8(bytes).expect("interned bytes are valid UTF-8")
    }
}

/// Build-time interner. Holds the dedup map; NOT part of `Ir`. Dropped at `finish`. StrIds
/// are assigned in interning (= source) order, so output stays deterministic.
#[derive(Default)]
pub struct Interner {
    pool: Strings,
    dedup: HashMap<Box<str>, StrId>,
}

impl Interner {
    /// The id for `s`, interning it on first sight.
    pub fn intern(&mut self, s: &str) -> StrId {
        if let Some(&id) = self.dedup.get(s) {
            return id;
        }
        let off = self.pool.bytes.len() as u32;
        self.pool.bytes.extend_from_slice(s.as_bytes());
        let id = StrId(self.pool.spans.len() as u32);
        self.pool.spans.push(Span {
            off,
            len: s.len() as u32,
        });
        self.dedup.insert(s.into(), id);
        id
    }
    /// The id for `s` if already interned.
    pub fn get_id(&self, s: &str) -> Option<StrId> {
        self.dedup.get(s).copied()
    }
    /// The string for `id` (see [`Strings::get`]).
    pub fn resolve(&self, id: StrId) -> &str {
        self.pool.get(id)
    }
    /// The pool built so far.
    pub fn pool(&self) -> &Strings {
        &self.pool
    }
    /// Drop the dedup map and keep only the persisted pool.
    #[must_use]
    pub fn finish(self) -> Strings {
        self.pool
    }
}
