//! String interning: one byte arena, one span table, integer-compare equality.
//!
//! Every name in the program (device, net, subckt path, value text) lives once in a
//! single growing byte buffer. A `StrId` names a position in the span table; two
//! equal `StrId`s mean equal bytes, so name comparison never touches memory.
//!
//! ## Two structures, two lifetimes
//!
//! `Interner` is the build-time form: pool plus a dedup hash map. It exists only
//! while the front end is running. `finish` drops the map and hands back a
//! `Strings` — the read-only form that the IR, renderers and C ABI hold. The dedup
//! map is the single largest transient allocation in the front end and there is no
//! reason to carry it for the life of the document.
//!
//! ## Every string is NUL-terminated
//!
//! `intern` appends a `0` byte after each string and excludes it from the recorded
//! length. This costs one byte per *distinct* name and buys the C ABI a
//! `[*:0]const u8` straight out of the pool, with no per-call copy and no shadow
//! table of C strings. See docs/ARCHITECTURE.md §9.
//!
//! ## Case folding happens here, once
//!
//! SPICE is case-insensitive for identifiers. Rather than lowercasing every token
//! during tokenization, callers intern through `internFold`, which folds ASCII case
//! on the way in. The tokenizer therefore never allocates and never rewrites its
//! input, and the original spelling stays available in the source buffer for
//! diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StrId = @import("ids.zig").StrId;

/// Where one interned string lives in the byte pool.
///
/// 8 bytes. A `u32` length caps a single name at 4 GiB, which is not a constraint
/// any netlist will meet.
pub const Span = struct {
    off: u32,
    len: u32,
};

/// The read-only string pool handed to every consumer downstream of parsing.
///
/// Owns both arrays. Immutable once produced by `Interner.finish` — no consumer may
/// add to it, which is what lets `StrId`s be freely copied and compared.
pub const Strings = struct {
    /// Concatenated string bytes, each followed by a NUL not counted in its span.
    /// Always valid UTF-8 in the counted regions.
    bytes: []u8,
    /// One span per `StrId`, in assignment order.
    spans: []Span,

    pub const empty: Strings = .{ .bytes = &.{}, .spans = &.{} };

    /// Release both arrays. Safe on `.empty`.
    pub fn deinit(self: *Strings, gpa: Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.spans);
        self.* = .empty;
    }

    /// The bytes of `id`, without its NUL terminator.
    ///
    /// Borrowed from the pool; valid until `deinit`. Never free it. Asserts `id` is
    /// within the table — an unknown `StrId` means it came from a different pool,
    /// which is a programming error.
    pub fn get(self: Strings, id: StrId) []const u8 {
        std.debug.assert(id.i() < self.spans.len);
        const span = self.spans[id.i()];
        return self.bytes[span.off..][0..span.len];
    }

    /// The bytes of `id` as a NUL-terminated C string.
    ///
    /// Zero-copy: points directly into the pool. Borrowed with the same lifetime as
    /// `get`. This is the accessor the C ABI uses.
    pub fn getZ(self: Strings, id: StrId) [*:0]const u8 {
        std.debug.assert(id.i() < self.spans.len);
        const span = self.spans[id.i()];
        std.debug.assert(self.bytes[span.off + span.len] == 0);
        return @ptrCast(self.bytes.ptr + span.off);
    }

    /// Number of distinct interned strings.
    pub fn count(self: Strings) usize {
        return self.spans.len;
    }
};

/// Build-time interner: the pool being grown, plus the dedup index.
///
/// Deinit-complete — `deinit` releases the pool and the map both. If you intend to
/// keep the pool, call `finish` instead, which transfers ownership of the pool out
/// and releases only the map.
pub const Interner = struct {
    bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    /// Maps already-interned content to its id. Keys alias `bytes`, so this map owns
    /// nothing and must be dropped before or with the pool, never after.
    dedup: std.StringHashMapUnmanaged(StrId) = .empty,

    pub const empty: Interner = .{};

    /// Create an interner with `StrId.empty` already assigned to the empty string.
    ///
    /// Callers rely on `StrId.empty` being valid without interning it, so this is
    /// the only correct way to construct one.
    pub fn init(gpa: Allocator) Allocator.Error!Interner {
        var self: Interner = .empty;
        errdefer self.deinit(gpa);
        std.debug.assert(try self.intern(gpa, "") == .empty);
        return self;
    }

    /// Release everything, including the pool. Use when parsing failed and the pool
    /// is being discarded.
    pub fn deinit(self: *Interner, gpa: Allocator) void {
        self.dedup.deinit(gpa);
        self.bytes.deinit(gpa);
        self.spans.deinit(gpa);
        self.* = .empty;
    }

    /// Intern `s` verbatim, returning its existing id if already present.
    ///
    /// Appends `s` plus a NUL to the pool on a miss. The returned id is stable for
    /// the life of the pool. Byte-exact: `"VDD"` and `"vdd"` are distinct ids —
    /// use `internFold` for identifiers.
    ///
    /// Errors: `OutOfMemory`. On failure the pool is unchanged and no id is
    /// consumed, so a retry produces the same numbering.
    pub fn intern(self: *Interner, gpa: Allocator, s: []const u8) Allocator.Error!StrId {
        if (self.dedup.get(s)) |id| return id;

        // Every fallible step happens before any mutation, so a failure here leaves
        // the pool byte-identical and consumes no id — `intern` is retryable and the
        // numbering is unchanged. That is also why there is no errdefer: nothing is
        // half-built at any point a `try` can unwind from.
        const old_ptr = self.bytes.items.ptr;
        try self.bytes.ensureUnusedCapacity(gpa, s.len + 1);
        // The dedup keys are slices *into* `bytes`, so the reserve above may have
        // just dangled every one of them. Repoint them at the new buffer before
        // anything hashes or compares a key. Each key's content is unchanged, so the
        // stored hashes stay correct and no rehash is needed; the span table gives
        // the offset, so no arithmetic touches the freed pointer. Cost is O(entries)
        // per reallocation, and reallocation is geometric, so it is amortized O(1).
        if (self.bytes.items.ptr != old_ptr) self.rebaseKeys();

        try self.spans.ensureUnusedCapacity(gpa, 1);
        try self.dedup.ensureUnusedCapacity(gpa, 1);

        const off: u32 = @intCast(self.bytes.items.len);
        self.bytes.appendSliceAssumeCapacity(s);
        self.bytes.appendAssumeCapacity(0);

        const id = StrId.at(self.spans.items.len);
        self.spans.appendAssumeCapacity(.{ .off = off, .len = @intCast(s.len) });
        self.dedup.putAssumeCapacityNoClobber(self.bytes.items[off..][0..s.len], id);
        return id;
    }

    /// Repoint every dedup key at the current `bytes` buffer, using the span table
    /// as the source of truth for each key's offset.
    ///
    /// Iterating the map is safe here because nothing observable is produced by the
    /// iteration — it mutates in place and emits no order-dependent output.
    fn rebaseKeys(self: *Interner) void {
        var it = self.dedup.iterator();
        while (it.next()) |e| {
            const span = self.spans.items[e.value_ptr.i()];
            e.key_ptr.* = self.bytes.items.ptr[span.off..][0..span.len];
        }
    }

    /// Intern `s` with ASCII case folded to lowercase.
    ///
    /// The single entry point for SPICE identifiers, so that case-insensitive
    /// matching is a property of the pool rather than a rule every caller must
    /// remember. Non-ASCII bytes pass through unchanged.
    ///
    /// Folding is done into a small stack buffer for typical names and falls back to
    /// a scratch allocation for names longer than `fold_stack_max`; the scratch is
    /// released before returning, so this function allocates only in the pool on a
    /// miss.
    pub fn internFold(self: *Interner, gpa: Allocator, s: []const u8) Allocator.Error!StrId {
        if (s.len <= fold_stack_max) {
            var stack: [fold_stack_max]u8 = undefined;
            return self.intern(gpa, foldInto(stack[0..s.len], s));
        }
        const scratch = try gpa.alloc(u8, s.len);
        defer gpa.free(scratch);
        return self.intern(gpa, foldInto(scratch, s));
    }

    /// Copy `src` into `dst` with ASCII upper-case folded down, returning `dst`.
    /// Bytes >= 0x80 pass through, so UTF-8 continuation bytes are never mangled.
    fn foldInto(dst: []u8, src: []const u8) []u8 {
        for (dst, src) |*d, c| d.* = std.ascii.toLower(c);
        return dst;
    }

    /// Longest name handled without a scratch allocation in `internFold`.
    pub const fold_stack_max = 256;

    /// Look up `s` without interning it.
    ///
    /// Returns null when absent. Used by passes that must not grow the pool — for
    /// instance resolving a `.subckt` port name that, if unknown, is a diagnostic
    /// rather than a new name.
    pub fn find(self: Interner, s: []const u8) ?StrId {
        return self.dedup.get(s);
    }

    /// Bytes of an already-interned id, for use mid-build.
    ///
    /// Borrowed and invalidated by any subsequent `intern` that grows the pool —
    /// copy it or re-fetch after interning. This hazard is why the read-only
    /// `Strings` form exists at all.
    pub fn get(self: Interner, id: StrId) []const u8 {
        std.debug.assert(id.i() < self.spans.items.len);
        const span = self.spans.items[id.i()];
        return self.bytes.items[span.off..][0..span.len];
    }

    /// Finalize: drop the dedup map, transfer the pool out.
    ///
    /// Caller owns the returned `Strings` and must `deinit` it with the same
    /// allocator. `self` is left `.empty` and must not be used again, so a
    /// double-finish cannot double-transfer.
    pub fn finish(self: *Interner, gpa: Allocator) Allocator.Error!Strings {
        // Drop the map first: its keys alias the pool, and `toOwnedSlice` may move it.
        self.dedup.deinit(gpa);
        self.dedup = .empty;

        const bytes = try self.bytes.toOwnedSlice(gpa);
        errdefer gpa.free(bytes);
        const spans = try self.spans.toOwnedSlice(gpa);
        return .{ .bytes = bytes, .spans = spans };
    }
};
