//! Index types and the sentinel conventions that make the SoA layout safe.
//!
//! Every cross-reference in this program is a `u32` index into an array, never a
//! pointer. Indices survive array growth and reallocation, cost half of a pointer,
//! and cannot dangle — the worst they can do is point at the wrong element, which
//! a distinct enum type per index space prevents.
//!
//! Each index is a non-exhaustive `enum(u32)` so that arithmetic on it is a compile
//! error. Convert explicitly at the array access with `.i()`.
//!
//! ## Why sentinels instead of optionals
//!
//! Zig does not niche-optimize an optional over a non-exhaustive enum: `?NetIdx`
//! occupies 8 bytes. The pin→net column is the hottest array in place-and-route, so
//! it uses a reserved in-band value instead and stays at 4 bytes per pin. Types that
//! need absence declare a `none` member; types that never need it declare no
//! sentinel and are dense from 0.

const std = @import("std");

/// A device (transistor, resistor, source, …) in the flattened schematic.
///
/// Dense from 0. Indexes the `dev_*` columns of `Ir`.
pub const DeviceIdx = enum(u32) {
    /// No device. Used by lattice blocking arrays to mean "this edge is clear".
    none = std.math.maxInt(u32),
    _,

    /// Array subscript for this index. Asserts the value is not `.none`.
    pub fn i(d: DeviceIdx) usize {
        std.debug.assert(d != .none);
        return @intFromEnum(d);
    }

    /// Build an index from a subscript. Asserts it is in the representable range.
    pub fn at(n: usize) DeviceIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// One terminal of one device instance.
///
/// Dense from 0, grouped by owning device: the pins of device `d` occupy the
/// half-open range `dev_pin0[d] .. dev_pin0[d + 1]`. Pin *names* are not stored —
/// they are derived from the device's symbol class and the pin's position within
/// its device's range.
pub const PinIdx = enum(u32) {
    /// No pin. Used by lattice node arrays to mean "no pin sits on this node".
    none = std.math.maxInt(u32),
    _,

    pub fn i(p: PinIdx) usize {
        std.debug.assert(p != .none);
        return @intFromEnum(p);
    }

    pub fn at(n: usize) PinIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// An electrical node joining a set of pins.
///
/// **1-based**: index 0 is reserved as `.none`, meaning a pin is floating. This is
/// the one sentinel that is load-bearing for memory layout rather than convenience
/// (see the module header). Subscript is therefore `@intFromEnum(n) - 1`, which
/// `i()` handles.
pub const NetIdx = enum(u32) {
    /// A floating pin, or an absent net reference.
    none = 0,
    _,

    /// Array subscript for this net. Asserts the net is not `.none`.
    pub fn i(n: NetIdx) usize {
        std.debug.assert(n != .none);
        return @intFromEnum(n) - 1;
    }

    /// Build a net index from a 0-based subscript.
    pub fn at(n: usize) NetIdx {
        std.debug.assert(n < std.math.maxInt(u32) - 1);
        return @enumFromInt(@as(u32, @intCast(n)) + 1);
    }
};

/// A device *class* — the symbol drawn for a device, and the terminal names and
/// anchor offsets that come with it.
///
/// Opaque to the IR: the IR stores it, compares it, and never interprets it. Values
/// below `devices.builtin_count` index the comptime catalog; values at or above it
/// index the runtime host-class table. Once handed out, a `SymbolIdx` never changes
/// meaning for the life of the process.
pub const SymbolIdx = enum(u32) {
    _,

    pub fn i(s: SymbolIdx) usize {
        return @intFromEnum(s);
    }

    pub fn at(n: usize) SymbolIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// An interned string: a byte offset into the string pool, resolvable only through
/// the `Strings` table that produced it.
///
/// Equal `StrId`s mean equal bytes, so name comparison is an integer compare. IDs
/// are assigned in first-intern order, which is what makes output ordering
/// reproducible across runs.
pub const StrId = enum(u32) {
    /// The empty string. Every pool interns it first, so this is always valid.
    empty = 0,
    _,

    pub fn i(s: StrId) usize {
        return @intFromEnum(s);
    }

    pub fn at(n: usize) StrId {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// A lattice column index (a distinct x coordinate in the routing grid).
pub const ColIdx = enum(u32) { _ };

/// An integer point on the layout grid.
///
/// Place-and-route is integer-only. Floats appear nowhere in geometry, so every
/// comparison is exact, every tie breaks deterministically, and output is
/// byte-reproducible without epsilon discipline. Units are host grid units; the
/// standard device cell is 40 wide.
pub const Pt = struct {
    x: i32,
    y: i32,

    pub const zero: Pt = .{ .x = 0, .y = 0 };

    pub fn add(a: Pt, b: Pt) Pt {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Pt, b: Pt) Pt {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn eql(a: Pt, b: Pt) bool {
        return a.x == b.x and a.y == b.y;
    }

    /// Total order on points, y-major then x. Used to canonicalize point lists so
    /// that geometrically identical output sorts identically.
    pub fn lessThan(_: void, a: Pt, b: Pt) bool {
        if (a.y != b.y) return a.y < b.y;
        return a.x < b.x;
    }
};

/// An axis-aligned rectangle, inclusive of both corners.
///
/// Used for device body extents and collision queries. `min` is top-left in the
/// layout's y-down coordinate system.
pub const Rect = struct {
    min: Pt,
    max: Pt,

    /// True when the two rectangles share at least one point.
    pub fn intersects(a: Rect, b: Rect) bool {
        return a.min.x <= b.max.x and b.min.x <= a.max.x and
            a.min.y <= b.max.y and b.min.y <= a.max.y;
    }

    /// True when `p` lies inside or on the boundary of the rectangle.
    pub fn contains(r: Rect, p: Pt) bool {
        return p.x >= r.min.x and p.x <= r.max.x and p.y >= r.min.y and p.y <= r.max.y;
    }

    /// Smallest rectangle containing both inputs.
    pub fn merge(a: Rect, b: Rect) Rect {
        return .{
            .min = .{ .x = @min(a.min.x, b.min.x), .y = @min(a.min.y, b.min.y) },
            .max = .{ .x = @max(a.max.x, b.max.x), .y = @max(a.max.y, b.max.y) },
        };
    }
};

/// Symbol placement transform: a quarter-turn rotation plus an optional mirror.
///
/// One byte, so the `dev_orient` column costs one byte per device. Mirror is
/// applied about the vertical axis *before* rotation; `apply` is the single
/// definition of that order and every renderer must go through it rather than
/// reimplementing the math.
pub const Orient = packed struct(u8) {
    /// Quarter turns clockwise: 0 = R0, 1 = R90, 2 = R180, 3 = R270.
    rot: u2 = 0,
    /// Mirror about the vertical axis, applied before rotation.
    mirror: bool = false,
    _pad: u5 = 0,

    pub const r0: Orient = .{};

    /// Transform a symbol-local point into device-local space.
    ///
    /// Pure function of the orientation; no allocation. This is the *only* place
    /// the mirror-then-rotate order is encoded.
    pub fn apply(o: Orient, p: Pt) Pt {
        const m: Pt = if (o.mirror) .{ .x = -p.x, .y = p.y } else p;
        return switch (o.rot) {
            0 => m,
            1 => .{ .x = -m.y, .y = m.x },
            2 => .{ .x = -m.x, .y = -m.y },
            3 => .{ .x = m.y, .y = -m.x },
        };
    }
};

/// Which electrical role a net plays, decided once during context build.
///
/// Drives routing costs (a rail owns its bus row) and excludes rails from the
/// per-net wire routing entirely.
pub const NetClass = enum(u8) {
    signal,
    power,
    ground,
};

/// How far a net reaches across columns, classified before any wire is drawn.
///
/// This is an input to channel width and cost only — never to control flow. All
/// three cases route through the identical tree search.
pub const NetCase = enum(u8) {
    /// All pins in one column.
    within_column,
    /// Pins span exactly two adjacent columns.
    immediate,
    /// Pins span two or more gaps.
    span_ge2,
};

test "net index round-trips through the 1-based encoding" {
    try std.testing.expectEqual(@as(usize, 0), NetIdx.at(0).i());
    try std.testing.expectEqual(@as(usize, 7), NetIdx.at(7).i());
    try std.testing.expect(NetIdx.at(0) != .none);
}

test "orientation composes mirror before rotation" {
    const p: Pt = .{ .x = 3, .y = 1 };
    try std.testing.expectEqual(Pt{ .x = 3, .y = 1 }, Orient.r0.apply(p));
    try std.testing.expectEqual(Pt{ .x = -3, .y = 1 }, (Orient{ .mirror = true }).apply(p));
    // Mirror then a quarter turn: (-3,1) -> (-1,-3)
    try std.testing.expectEqual(Pt{ .x = -1, .y = -3 }, (Orient{ .rot = 1, .mirror = true }).apply(p));
}

test "orientation is one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Orient));
}
