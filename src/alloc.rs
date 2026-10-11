//! Guest allocator (wasm32 only): power-of-two size classes of 8–1024 bytes carved from
//! 64 KiB slabs, each class with its own free list; anything larger or more aligned goes
//! to the system allocator (dlmalloc).
//!
//! Why (profile, `tests/guest.rs` fuel report): under wasmi a dlmalloc alloc/free pair of
//! a small string costs ~2,400 fuel, and a conversion makes ~100 small allocations per
//! device, which put a 100-device netlist past the default 10^8 fuel budget. A free-list
//! pop/push costs a few dozen instructions. Small blocks are reused but never returned
//! to dlmalloc, so memory is bounded by the peak live small allocations of one import.

#![allow(unsafe_code)]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

/// Size classes: 8 << c bytes for c in 0..CLASSES.
const CLASSES: usize = 8;
/// Bytes per slab requested from the system allocator.
const SLAB: usize = 64 << 10;

/// Free-list heads per class and the current slab's bump range (addresses; 0 = none).
struct Classes {
    free: [Cell<usize>; CLASSES],
    next: Cell<usize>,
    end: Cell<usize>,
}

// SAFETY: wasm32-unknown-unknown guests are single-threaded (no threads, no atomics
// feature), so the cells are never accessed concurrently.
unsafe impl Sync for Classes {}

/// Class of `l`, or `None` for the system allocator.
fn class(l: Layout) -> Option<usize> {
    if l.size() > 8 << (CLASSES - 1) || l.align() > 8 {
        return None;
    }
    let size = l.size().max(8).next_power_of_two();
    let c = (size.trailing_zeros() - 3) as usize;
    debug_assert!(c < CLASSES && 8 << c >= l.size());
    Some(c)
}

// SAFETY: every block handed out is 8-aligned (slabs are 8-aligned, block sizes are
// multiples of 8, requests aligned above 8 go to `System`) and at least `size` bytes;
// a block is on at most one free list, and only `dealloc` (given the block's own layout,
// per the `GlobalAlloc` contract) puts it there; its first word holds the next pointer
// only while it is free.
unsafe impl GlobalAlloc for Classes {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let Some(c) = class(l) else {
            // SAFETY: forwarded unchanged; `l` has non-zero size per the caller's contract.
            return unsafe { System.alloc(l) };
        };
        let head = self.free[c].get();
        if head != 0 {
            // SAFETY: `head` is a free block of class `c`; its first word is the next one.
            self.free[c].set(unsafe { *(head as *const usize) });
            return head as *mut u8;
        }
        let size = 8 << c;
        if self.next.get() + size > self.end.get() {
            let slab = Layout::from_size_align(SLAB, 8).expect("constant layout");
            // SAFETY: non-zero size; the slab is never freed (blocks are recycled).
            let base = unsafe { System.alloc(slab) } as usize;
            if base == 0 {
                return std::ptr::null_mut();
            }
            self.next.set(base);
            self.end.set(base + SLAB);
        }
        let p = self.next.get();
        self.next.set(p + size);
        p as *mut u8
    }

    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        match class(l) {
            // SAFETY: `p` came from `System.alloc(l)` (same layout ⇒ same class decision).
            None => unsafe { System.dealloc(p, l) },
            Some(c) => {
                // SAFETY: `p` is a live block of class `c` the caller gives up; it is at
                // least 8 bytes and 8-aligned, so it can hold the next pointer.
                unsafe { *(p as *mut usize) = self.free[c].get() };
                self.free[c].set(p as usize);
            }
        }
    }

    unsafe fn realloc(&self, p: *mut u8, l: Layout, new_size: usize) -> *mut u8 {
        let new =
            Layout::from_size_align(new_size, l.align()).expect("valid per the caller's contract");
        match (class(l), class(new)) {
            (Some(a), Some(b)) if a == b => p,
            // SAFETY: both blocks belong to the system allocator.
            (None, None) => unsafe { System.realloc(p, l, new_size) },
            _ => {
                // SAFETY: `new` is a valid non-zero layout; the copy stays within both
                // blocks; `p` is released with its own layout.
                unsafe {
                    let q = self.alloc(new);
                    if !q.is_null() {
                        std::ptr::copy_nonoverlapping(p, q, l.size().min(new_size));
                        self.dealloc(p, l);
                    }
                    q
                }
            }
        }
    }
}

#[global_allocator]
static ALLOC: Classes = Classes {
    free: [const { Cell::new(0) }; CLASSES],
    next: Cell::new(0),
    end: Cell::new(0),
};
