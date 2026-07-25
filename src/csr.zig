//! Compressed sparse row: the one representation for every many-to-many relation
//! in this program.
//!
//! A CSR is two arrays. `offsets` has one entry per key plus a terminating
//! sentinel; `values` holds every key's values back to back. The values for key `k`
//! are `values[offsets[k] .. offsets[k + 1]]`. A lookup is two loads and a slice —
//! no allocation, no per-key list header, no pointer chase.
//!
//! Relations built with this: net→pins, device→conducting-pins, column→devices,
//! spline→devices, net→segments, segment→points.
//!
//! ## Why not a list of lists
//!
//! `[][]T` costs a 16-byte header plus a separate allocation per key, scatters the
//! values across the heap, and makes the whole relation impossible to free in one
//! call. For a relation over every pin in a schematic, the header overhead alone
//! exceeds the payload.
//!
//! ## Construction is always two counting passes
//!
//! Count occurrences per key, prefix-sum the counts into offsets, then place values
//! using a moving cursor. This is a counting sort, so it is linear and — critically
//! for reproducible output — **stable**: values land in the order they were
//! observed, never in hash order. `build` enforces the pattern so no caller
//! open-codes it and accidentally introduces nondeterminism.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A CSR relation from `Key` (any index enum with `.i()`) to `Val`.
///
/// Owns both arrays. Allocated from a single allocator and freed with `deinit`.
pub fn Csr(comptime Key: type, comptime Val: type) type {
    return struct {
        const Self = @This();

        /// Length `key_count + 1`. Monotonically non-decreasing; last entry equals
        /// `values.len`.
        offsets: []u32,
        /// All values, grouped by key, in observation order within each key.
        values: []Val,

        pub const empty: Self = .{ .offsets = &.{}, .values = &.{} };

        /// Release both arrays. Safe on `.empty`.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.offsets);
            gpa.free(self.values);
            self.* = .empty;
        }

        /// Number of keys the relation covers.
        ///
        /// Zero for `.empty`; otherwise `offsets.len - 1`.
        pub fn keyCount(self: Self) usize {
            return if (self.offsets.len == 0) 0 else self.offsets.len - 1;
        }

        /// The values associated with `key`, in stable observation order.
        ///
        /// Returns an empty slice for a key with no values. Asserts `key` is within
        /// `keyCount()` — an out-of-range key is a programming error, not a runtime
        /// condition.
        ///
        /// Borrowed: the returned slice aliases `values` and is invalidated by
        /// `deinit`. Never free it.
        pub fn slice(self: Self, key: Key) []const Val {
            return self.sliceMut(key);
        }

        /// Mutable view of `key`'s values, for passes that rewrite in place (for
        /// example canonicalizing each net's pin list into sorted order).
        ///
        /// Same aliasing rules as `slice`.
        pub fn sliceMut(self: Self, key: Key) []Val {
            const k = key.i();
            std.debug.assert(k < self.keyCount());
            return self.values[self.offsets[k]..self.offsets[k + 1]];
        }

        /// Number of values under `key`, without materializing the slice.
        pub fn count(self: Self, key: Key) u32 {
            const k = key.i();
            std.debug.assert(k < self.keyCount());
            return self.offsets[k + 1] - self.offsets[k];
        }

        /// Build a relation by counting sort.
        ///
        /// `key_count` fixes the key space. `ctx` is passed to both callbacks
        /// untouched. `keyOf` maps an input item to its key; `valOf` maps it to the
        /// stored value. Both are called exactly twice per item (once per pass) and
        /// must be pure — an inconsistent `keyOf` between passes corrupts the
        /// relation, which is asserted in safe builds.
        ///
        /// Caller owns the returned relation and must `deinit` it. On allocation
        /// failure nothing is leaked.
        ///
        /// Stability guarantee: within a key, values appear in `items` order. This
        /// is what makes downstream output reproducible, so it is part of the
        /// contract rather than an accident of the algorithm.
        ///
        /// Linear in `items.len + key_count`.
        ///
        /// `items` is any memory span — slice, array, or pointer to one. The element
        /// type comes from `std.meta.Elem` rather than `@TypeOf(items[0])` so that a
        /// zero-length array literal is a legal argument.
        pub fn build(
            gpa: Allocator,
            key_count: usize,
            items: anytype,
            ctx: anytype,
            comptime keyOf: fn (@TypeOf(ctx), std.meta.Elem(@TypeOf(items))) ?Key,
            comptime valOf: fn (@TypeOf(ctx), std.meta.Elem(@TypeOf(items))) Val,
        ) Allocator.Error!Self {
            const offsets = try gpa.alloc(u32, key_count + 1);
            errdefer gpa.free(offsets);
            @memset(offsets, 0);

            // Pass 1: counts land in offsets[k], one slot left of where they will
            // finally live.
            var total: usize = 0;
            for (items) |item| {
                const key = keyOf(ctx, item) orelse continue;
                const k = key.i();
                std.debug.assert(k < key_count);
                offsets[k] += 1;
                total += 1;
            }

            // Exclusive prefix sum.
            var running: u32 = 0;
            for (offsets[0..key_count]) |*o| {
                const c = o.*;
                o.* = running;
                running += c;
            }
            offsets[key_count] = running;
            std.debug.assert(running == total);

            const values = try gpa.alloc(Val, total);
            errdefer gpa.free(values);

            // Pass 2: offsets[k] doubles as key k's moving cursor, so no scratch
            // array is needed. Forward iteration keeps values in `items` order,
            // which is the stability guarantee.
            var placed: usize = 0;
            for (items) |item| {
                const key = keyOf(ctx, item) orelse continue;
                const k = key.i();
                std.debug.assert(k < key_count);
                values[offsets[k]] = valOf(ctx, item);
                offsets[k] += 1;
                placed += 1;
            }
            // An impure `keyOf` shows up here as a count mismatch.
            std.debug.assert(placed == total);

            // Each cursor now sits at its bucket's end, i.e. offsets[k] holds the
            // true offsets[k + 1]. Shift right and restore the leading zero.
            std.mem.copyBackwards(u32, offsets[1..], offsets[0..key_count]);
            offsets[0] = 0;

            const self: Self = .{ .offsets = offsets, .values = values };
            self.assertValid();
            return self;
        }

        /// Build from a pre-counted histogram, for callers that already know the
        /// per-key counts and want to fill values themselves.
        ///
        /// `counts` has one entry per key. Returns a relation whose `offsets` are
        /// the prefix sum of `counts` and whose `values` are **uninitialized** — the
        /// caller must write every slot before reading any. Intended for the passes
        /// that emit values as a side effect of a walk they cannot cheaply repeat.
        ///
        /// Caller owns the result.
        pub fn fromCounts(gpa: Allocator, counts: []const u32) Allocator.Error!Self {
            const offsets = try gpa.alloc(u32, counts.len + 1);
            errdefer gpa.free(offsets);

            var running: u32 = 0;
            for (counts, 0..) |c, k| {
                offsets[k] = running;
                running += c;
            }
            offsets[counts.len] = running;

            const values = try gpa.alloc(Val, running);
            return .{ .offsets = offsets, .values = values };
        }

        /// Assert the structural invariants: `offsets` non-empty, monotonically
        /// non-decreasing, and terminating exactly at `values.len`.
        ///
        /// Called by tests and by `build` in safe modes. No-op in `ReleaseFast`.
        pub fn assertValid(self: Self) void {
            if (!std.debug.runtime_safety) return;
            std.debug.assert(self.offsets.len > 0);
            for (self.offsets[1..], 0..) |o, k| std.debug.assert(o >= self.offsets[k]);
            std.debug.assert(self.offsets[self.offsets.len - 1] == self.values.len);
        }
    };
}
