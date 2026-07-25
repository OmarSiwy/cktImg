//! The schematic, as struct-of-arrays.
//!
//! This is the hinge of the whole program: the front end produces it, placement
//! consumes it and appends `Physical`, and every renderer reads it. Its layout is
//! therefore chosen around the *passes*, not around the concept of "a device".
//!
//! ## Columns, not records
//!
//! There is no `Device` struct. A device is an index, and its attributes live in
//! parallel arrays. The reason is that no pass over this data wants all of a
//! device's fields:
//!
//! - Place-and-route reads `dev_symbol`, `dev_pin0`, `pin_net`, `dev_orient`.
//!   It never reads a name or a value text.
//! - Rendering reads everything, but exactly once.
//!
//! Interleaving the render-only columns (`dev_name`, `dev_value`) with the hot ones
//! would drag two `StrId`s into cache for every device the router touches, for no
//! benefit. Splitting them is the hot/cold rule applied literally.
//!
//! ## Pins are CSR, and pin names do not exist
//!
//! `dev_pin0` is a CSR offset array: device `d`'s pins are the half-open range
//! `dev_pin0[d] .. dev_pin0[d + 1]`, so it has `device_count + 1` entries. Pin names
//! are *derived* — pin `k` of device `d` is terminal `k` of `d`'s symbol class.
//! Storing them per instance would duplicate the same handful of strings across
//! every device in the schematic.
//!
//! ## Nets are 1-based
//!
//! `NetIdx.none == 0` means a floating pin, so `pin_net` stays 4 bytes per pin
//! rather than the 8 an optional would cost. `pin_net` is the array the router
//! touches most; see ids.zig for the full argument.
//!
//! ## Placement is a separate block, appended
//!
//! `Ir` is constraint-free: it records what the netlist said and nothing about where
//! anything goes. `Physical` is a distinct structure produced by placement and
//! attached afterward. `Placed` is the type that guarantees both are present, so no
//! consumer needs to check for a missing geometry block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ids = @import("ids.zig");
const Csr = @import("csr.zig").Csr;

const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const SymbolIdx = ids.SymbolIdx;
const StrId = ids.StrId;
const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;

/// The flattened schematic: devices, their pins, and the nets joining them.
///
/// All arrays are owned and freed by `deinit`. Column lengths are related by the
/// invariants `assertValid` checks; violating them is a bug in the front end, not a
/// recoverable condition.
pub const Ir = struct {
    // --- hot columns: read by every place-and-route pass ---

    /// Symbol class per device. Indexed by `DeviceIdx`.
    dev_symbol: []SymbolIdx,
    /// Placement transform per device. Written by the orientation pass, read by
    /// routing (body extents) and rendering.
    dev_orient: []Orient,
    /// CSR offsets into the pin columns. Length `device_count + 1`.
    dev_pin0: []u32,
    /// Net per pin, or `.none` when floating. The most frequently read array in the
    /// program.
    pin_net: []NetIdx,

    // --- cold columns: read once, at render ---

    /// Device reference designator, for example `m1` or `xtop.xa.r1`.
    dev_name: []StrId,
    /// Device value text as written, after parameter substitution.
    dev_value: []StrId,
    /// Net name. Indexed by `NetIdx` (subtract one — use `NetIdx.i()`).
    net_name: []StrId,

    // --- hierarchy record: annotation only, never affects placement ---

    /// Dotted instance path of each flattened subckt occurrence, for group framing.
    group_path: []StrId,
    /// Subckt master name per group.
    group_master: []StrId,

    pub const empty: Ir = .{
        .dev_symbol = &.{},
        .dev_orient = &.{},
        .dev_pin0 = &.{},
        .pin_net = &.{},
        .dev_name = &.{},
        .dev_value = &.{},
        .net_name = &.{},
        .group_path = &.{},
        .group_master = &.{},
    };

    /// Release every column. Safe on `.empty`.
    ///
    /// Does not touch the string pool — `StrId`s are indices, and the pool is owned
    /// separately because it outlives placement.
    pub fn deinit(self: *Ir, gpa: Allocator) void {
        gpa.free(self.dev_symbol);
        gpa.free(self.dev_orient);
        gpa.free(self.dev_pin0);
        gpa.free(self.pin_net);
        gpa.free(self.dev_name);
        gpa.free(self.dev_value);
        gpa.free(self.net_name);
        gpa.free(self.group_path);
        gpa.free(self.group_master);
        self.* = .empty;
    }

    pub fn deviceCount(self: Ir) usize {
        return self.dev_symbol.len;
    }

    pub fn pinCount(self: Ir) usize {
        return self.pin_net.len;
    }

    pub fn netCount(self: Ir) usize {
        return self.net_name.len;
    }

    pub fn groupCount(self: Ir) usize {
        return self.group_path.len;
    }

    /// The pins of `d`, as a contiguous index range.
    ///
    /// Returns `.{ first, last_exclusive }` as plain subscripts, because callers
    /// almost always want to iterate the range and index the columns directly rather
    /// than materialize a slice of `PinIdx`.
    pub fn pinRange(self: Ir, d: DeviceIdx) struct { u32, u32 } {
        const i = d.i();
        std.debug.assert(i < self.deviceCount());
        return .{ self.dev_pin0[i], self.dev_pin0[i + 1] };
    }

    /// Number of pins on `d`.
    pub fn pinCountOf(self: Ir, d: DeviceIdx) u32 {
        const lo, const hi = self.pinRange(d);
        return hi - lo;
    }

    /// The device owning `p`.
    ///
    /// Binary search over `dev_pin0`, which is sorted by construction. O(log n) and
    /// allocation-free. Passes that need this per pin in a loop should build the
    /// dense reverse map in `place/ctx.zig` instead of calling this repeatedly.
    pub fn deviceOf(self: Ir, p: PinIdx) DeviceIdx {
        const target = p.i();
        std.debug.assert(target < self.pinCount());
        // Largest d with dev_pin0[d] <= target. The range is non-empty because a pin
        // exists, so `lo` is always a real device.
        var lo: usize = 0;
        var hi: usize = self.deviceCount();
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.dev_pin0[mid] <= target) lo = mid else hi = mid;
        }
        return .at(lo);
    }

    /// The k-th pin of `d`, by symbol terminal order.
    ///
    /// Asserts `k < pinCountOf(d)`.
    pub fn pinAt(self: Ir, d: DeviceIdx, k: u32) PinIdx {
        const lo, const hi = self.pinRange(d);
        std.debug.assert(k < hi - lo);
        return .at(lo + k);
    }

    /// Build the net→pins relation.
    ///
    /// Counting sort over `pin_net`, so pins appear under each net in ascending pin
    /// order — deterministic, and the order every downstream pass assumes. Floating
    /// pins (`.none`) belong to no net and are omitted entirely.
    ///
    /// Caller owns the result and must `deinit` it.
    pub fn netPins(self: Ir, gpa: Allocator) Allocator.Error!Csr(NetIdx, PinIdx) {
        // ponytail: the counting sort is open-coded rather than routed through
        // `Csr.build` because `build`'s callbacks see an item's *value*, and the value
        // wanted here is the item's *index* into `pin_net`. Feeding it would mean
        // materializing a 0..pinCount index array — more memory than the whole result.
        const nets = self.netCount();
        const offsets = try gpa.alloc(u32, nets + 1);
        errdefer gpa.free(offsets);
        @memset(offsets, 0);

        // Counts land one slot high, so the prefix sum below turns them into starts.
        var total: u32 = 0;
        for (self.pin_net) |n| {
            if (n == .none) continue; // floating: belongs to no net
            offsets[n.i() + 1] += 1;
            total += 1;
        }
        for (1..nets + 1) |k| offsets[k] += offsets[k - 1];

        const values = try gpa.alloc(PinIdx, total);
        // `offsets[k]` doubles as key k's cursor; ascending pin order in, ascending out.
        for (self.pin_net, 0..) |n, p| {
            if (n == .none) continue;
            values[offsets[n.i()]] = .at(p);
            offsets[n.i()] += 1;
        }
        // Each cursor now sits at the next key's start: shift right to restore offsets.
        var k = nets;
        while (k > 0) : (k -= 1) offsets[k] = offsets[k - 1];
        offsets[0] = 0;

        return .{ .offsets = offsets, .values = values };
    }

    /// Check every structural invariant:
    ///
    /// - `dev_pin0.len == deviceCount() + 1`, non-decreasing, ending at `pinCount()`
    /// - all hot device columns the same length; all cold device columns likewise
    /// - `group_path.len == group_master.len`
    /// - every non-`.none` entry of `pin_net` is within `netCount()`
    ///
    /// Called by the front end at handoff and by tests. Panics on violation — these
    /// are producer bugs, and letting a malformed IR reach the router turns a clear
    /// failure into a mysterious drawing.
    pub fn assertValid(self: Ir) void {
        const n = self.deviceCount();
        std.debug.assert(self.dev_orient.len == n);
        std.debug.assert(self.dev_name.len == n);
        std.debug.assert(self.dev_value.len == n);
        std.debug.assert(self.group_path.len == self.group_master.len);

        std.debug.assert(self.dev_pin0.len == n + 1);
        for (self.dev_pin0[1..], self.dev_pin0[0..n]) |hi, lo| std.debug.assert(hi >= lo);
        std.debug.assert(self.dev_pin0[n] == self.pinCount());

        const nets = self.netCount();
        for (self.pin_net) |net| std.debug.assert(net == .none or net.i() < nets);
    }
};

/// Where everything ended up. Produced by placement; absent until then.
///
/// Nested CSR for wires: a net owns a run of segments, a segment owns a run of
/// points. Two offset arrays and one point array replace what would otherwise be a
/// `Vec<Vec<Vec<Pt>>>`, and the whole geometry block frees in four calls.
pub const Physical = struct {
    /// Device origin. Indexed by `DeviceIdx`.
    pos: []Pt,
    /// Absolute pin location. Indexed by `PinIdx`, parallel to `Ir.pin_net`.
    pin_xy: []Pt,
    /// CSR: net → its segments. Length `net_count + 1`.
    net_seg: []u32,
    /// CSR: segment → its points. Length `segment_count + 1`.
    seg_pt: []u32,
    /// All wire polyline vertices, packed.
    wire_pts: []Pt,
    /// Points where three or more same-net wire arms meet, so a connection dot is
    /// drawn. Two arms is a corner and gets no dot.
    junctions: []Pt,
    /// Nets that could not be routed and were dropped to name labels.
    labels: []Label,

    pub const empty: Physical = .{
        .pos = &.{},
        .pin_xy = &.{},
        .net_seg = &.{},
        .seg_pt = &.{},
        .wire_pts = &.{},
        .junctions = &.{},
        .labels = &.{},
    };

    pub fn deinit(self: *Physical, gpa: Allocator) void {
        gpa.free(self.pos);
        gpa.free(self.pin_xy);
        gpa.free(self.net_seg);
        gpa.free(self.seg_pt);
        gpa.free(self.wire_pts);
        gpa.free(self.junctions);
        gpa.free(self.labels);
        self.* = .empty;
    }

    /// Number of segments belonging to `n`.
    pub fn segmentCount(self: Physical, n: NetIdx) u32 {
        const i = n.i();
        std.debug.assert(i + 1 < self.net_seg.len);
        return self.net_seg[i + 1] - self.net_seg[i];
    }

    /// The points of segment `s` of net `n`, as a borrowed polyline.
    ///
    /// At least two points. Consecutive points are always axis-aligned — the router
    /// emits Manhattan geometry only, and a diagonal here means a bug upstream.
    /// Aliases `wire_pts`; never free it.
    pub fn segment(self: Physical, n: NetIdx, s: u32) []const Pt {
        std.debug.assert(s < self.segmentCount(n));
        const seg = self.net_seg[n.i()] + s;
        return self.wire_pts[self.seg_pt[seg]..self.seg_pt[seg + 1]];
    }

    /// Bounding box over devices, wires, junctions and labels.
    ///
    /// Returns null for an empty layout. Does not include render padding — that is
    /// the renderer's to add from `Config.render.pad`.
    pub fn bounds(self: Physical, ir: Ir, symbols: anytype) ?Rect {
        return @import("geom.zig").bounds(ir, self, symbols);
    }

    /// Check: column lengths match the IR, CSR offsets are monotone and terminate
    /// correctly, and every segment is a Manhattan polyline of at least two points.
    pub fn assertValid(self: Physical, ir: Ir) void {
        std.debug.assert(self.pos.len == ir.deviceCount());
        std.debug.assert(self.pin_xy.len == ir.pinCount());

        std.debug.assert(self.net_seg.len == ir.netCount() + 1);
        std.debug.assert(self.seg_pt.len >= 1);
        for (self.net_seg[1..], self.net_seg[0 .. self.net_seg.len - 1]) |hi, lo| {
            std.debug.assert(hi >= lo);
        }
        // The last net offset is the segment count, which is what `seg_pt` indexes.
        std.debug.assert(self.net_seg[self.net_seg.len - 1] == self.seg_pt.len - 1);

        std.debug.assert(self.seg_pt[self.seg_pt.len - 1] == self.wire_pts.len);
        for (self.seg_pt[1..], self.seg_pt[0 .. self.seg_pt.len - 1]) |hi, lo| {
            std.debug.assert(hi >= lo); // monotone; the slice below would trap anyway
            const poly = self.wire_pts[lo..hi];
            std.debug.assert(poly.len >= 2);
            for (poly[1..], poly[0 .. poly.len - 1]) |b, a| {
                std.debug.assert(a.x == b.x or a.y == b.y);
            }
        }
    }
};

test "net pins are stable in ascending pin order and floating pins are omitted" {
    // Three devices with 2, 3 and 1 pins. Pins 1 and 4 float; the rest interleave two
    // nets, so a builder that walked its cursors backwards would be visible here.
    var dev_symbol = [_]SymbolIdx{ .at(0), .at(0), .at(0) };
    var dev_orient = [_]Orient{ .r0, .r0, .r0 };
    var dev_pin0 = [_]u32{ 0, 2, 5, 6 };
    var pin_net = [_]NetIdx{ .at(1), .none, .at(0), .at(1), .none, .at(0) };
    var strs = [_]StrId{ .empty, .empty, .empty };
    const ir: Ir = .{
        .dev_symbol = &dev_symbol,
        .dev_orient = &dev_orient,
        .dev_pin0 = &dev_pin0,
        .pin_net = &pin_net,
        .dev_name = &strs,
        .dev_value = &strs,
        .net_name = strs[0..2],
        .group_path = &.{},
        .group_master = &.{},
    };
    ir.assertValid();

    var rel = try ir.netPins(std.testing.allocator);
    defer rel.deinit(std.testing.allocator);
    rel.assertValid();
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4 }, rel.offsets);
    try std.testing.expectEqualSlices(PinIdx, &.{ .at(2), .at(5) }, rel.slice(.at(0)));
    try std.testing.expectEqualSlices(PinIdx, &.{ .at(0), .at(3) }, rel.slice(.at(1)));

    try std.testing.expectEqual(@as(u32, 3), ir.pinCountOf(.at(1)));
    try std.testing.expectEqual(PinIdx.at(4), ir.pinAt(.at(1), 2));
    // Binary search hits both the first pin of a device and an interior one.
    for ([_]usize{ 0, 1, 2, 3, 4, 5 }, [_]usize{ 0, 0, 1, 1, 1, 2 }) |p, d| {
        try std.testing.expectEqual(DeviceIdx.at(d), ir.deviceOf(.at(p)));
    }
}

/// A net that routing could not connect, rendered as a name tag instead of a wire.
///
/// Labels are a real guarantee, not a shape gap: one is emitted only after the
/// lattice search has proven no tree exists. They are the first term of the
/// selection key, so the placer avoids them ahead of everything else.
pub const Label = struct {
    net: NetIdx,
    at: Pt,
};

/// A schematic with geometry — the front end's output plus placement's.
///
/// Bundles the string pool because every consumer needs both and separating them
/// only invites mismatched pairs. Deinit-complete: releases IR, geometry and pool.
pub const Placed = struct {
    ir: Ir,
    physical: Physical,
    strings: @import("strings.zig").Strings,

    pub fn deinit(self: *Placed, gpa: Allocator) void {
        self.ir.deinit(gpa);
        self.physical.deinit(gpa);
        self.strings.deinit(gpa);
    }
};

/// What the front end chose not to represent, and why.
///
/// Two categories, because they mean different things to a user: `ignored` is
/// by-design (an analysis card has no schematic meaning), while `skipped` is a
/// limitation (an unresolvable model). Conflating them makes a clean parse look
/// lossy.
pub const Report = struct {
    ignored: []Note,
    skipped: []Note,

    pub const empty: Report = .{ .ignored = &.{}, .skipped = &.{} };

    pub fn deinit(self: *Report, gpa: Allocator) void {
        gpa.free(self.ignored);
        gpa.free(self.skipped);
        self.* = .empty;
    }
};

/// One front-end complaint, located by source span rather than line number.
///
/// 12 bytes and no allocation: the reason is an enum resolved to text only when a
/// report is formatted, and the offending text is recoverable from the source buffer
/// via the span. The Rust original stored a reassembled copy of every ignored line,
/// which is pure cost in the common case where nobody reads the report.
pub const Note = struct {
    /// Byte offset into the concatenated source arena.
    off: u32,
    /// Length of the offending span.
    len: u32,
    reason: Reason,

    pub const Reason = enum(u32) {
        // ignored by design
        analysis_card,
        option_card,
        param_card,
        model_card,
        comment,
        // skipped as a limitation
        unknown_class,
        undefined_subckt,
        subckt_too_deep,
        port_arity_mismatch,
        unresolved_expression,
        include_not_found,
        include_cycle,

        /// True when this reason is a by-design omission rather than a limitation.
        pub fn isByDesign(r: Reason) bool {
            // The declaration order is the split: everything up to `comment` is a
            // by-design omission, everything after it is a limitation.
            return @intFromEnum(r) <= @intFromEnum(Reason.comment);
        }

        /// Human-readable text. Static; no allocation.
        pub fn text(r: Reason) []const u8 {
            return switch (r) {
                .analysis_card => "analysis card has no schematic meaning",
                .option_card => "simulator option card",
                .param_card => "parameter definition card",
                .model_card => "model card",
                .comment => "comment",
                .unknown_class => "unknown device class",
                .undefined_subckt => "undefined subckt",
                .subckt_too_deep => "subckt nesting past the depth cap",
                .port_arity_mismatch => "subckt port count mismatch",
                .unresolved_expression => "expression could not be evaluated",
                .include_not_found => "include file not found",
                .include_cycle => "include cycle",
            };
        }
    };
};
