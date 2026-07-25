//! The builtin device vocabulary: one comptime table, one comptime name index.
//!
//! A device *class* is what a `SymbolIdx` means — terminal names, electrical roles and
//! anchor points, plus the draw primitives that make the symbol. The IR stores only the
//! index; this file owns the interpretation.
//!
//! ## Why the whole table is comptime
//!
//! The builtin vocabulary is fixed when the compiler runs, so it costs nothing at run
//! time: `classes` is one array in `.rodata`, `by_name` is a perfect-hash lookup with no
//! hashing of the stored keys and no buckets to probe, and neither allocates a byte. This
//! is the "program lifetime / static" row of the allocator table in ARCHITECTURE.md §3 —
//! the only lifetime in the program that needs no allocator at all. The Rust original used
//! `phf`; `std.StaticStringMap.initComptime` is the exact analogue and needs no dependency.
//!
//! `by_name` is **derived from `classes`** at comptime rather than written out by hand. The
//! Rust tree maintained the two side by side and needed a test (`by_name_matches_classes`)
//! to catch them drifting apart; deriving one from the other deletes that whole class of
//! bug instead of testing for it.
//!
//! ## Bounding boxes are computed, never stored
//!
//! `DeviceClass.bbox` walks the terminals and draw ops on every call. Storing it would let
//! it drift from the geometry it summarizes — and after a host installs its own anchors
//! (see `host.zig`) a stored box would simply be wrong. It is a handful of integer min/max
//! over a slice that is already in cache; if it ever profiles hot, the fix is for the
//! *placer* to cache one `Rect` per placed device, not for the class to carry a field.
//!
//! ## The geometry contract every class obeys
//!
//! Canonical frame, origin at the device centre, integer grid, y down. Every class is
//! exactly `cell_width` (40) wide so devices pack on a uniform column pitch; height varies
//! freely. A multi-terminal class puts its two principal terminals on the conduction axis
//! at (-20, 0) and (+20, 0) and every auxiliary terminal off that axis; a single-terminal
//! class taps the origin. That is what makes a resistor's pins line up with a MOSFET's
//! drain and source when the placer stacks them in a column, and the tests in
//! `tests/devices.zig` pin it for every entry.
//!
//! ## Text is a layout contract, not an estimate
//!
//! `textWidth` is the width both shipped renderers *force* (`textLength` in SVG,
//! `\makebox` in TikZ), so the box computed here and the glyphs drawn agree in every
//! viewer. Box bodies (`box`) depend on that being exact.

const std = @import("std");
const ids = @import("../ids.zig");

const Pt = ids.Pt;
const Rect = ids.Rect;
const SymbolIdx = ids.SymbolIdx;

/// Canonical width of every device cell, in grid units.
///
/// Uniform by construction so that column pitch, abutment gaps and collision math are the
/// same arithmetic for every device. A class whose glyph exceeded it would be clipped by
/// its own cell, which is why the test suite asserts every draw op stays within ±20.
pub const cell_width: i32 = 40;

/// Half the cell width — the x extent of a canonical bounding box.
pub const cell_half: i32 = cell_width / 2;

/// Electrical role of a terminal.
///
/// Drives the spine walk (does placement current pass through this pin?) and control-net
/// attraction (does a driving net want to land here?). It is *not* a rendering hint.
pub const TerminalRole = enum(u8) {
    /// Two-terminal passive, or any pin with no special electrical meaning.
    passive = 0,
    // MOSFET / JFET / MESFET
    drain,
    source,
    gate,
    bulk,
    // BJT / IGBT
    collector,
    base,
    emitter,
    // diodes
    anode,
    cathode,

    /// True when spine current passes through this terminal, as opposed to controlling it.
    ///
    /// `passive` conducts; `gate`, `base` and `bulk` do not. Pure function of the tag.
    pub fn conducts(r: TerminalRole) bool {
        return switch (r) {
            .passive, .drain, .source, .collector, .emitter, .anode, .cathode => true,
            .gate, .bulk, .base => false,
        };
    }

    /// True for the control terminals (`gate`, `base`).
    pub fn isControl(r: TerminalRole) bool {
        return r == .gate or r == .base;
    }
};

/// Placement role of a class's symbol.
///
/// Net classification scans for these; it never infers a rail from a net's *name*, because
/// a net called `vdd` that no supply symbol touches is a signal. A class carrying any role
/// other than `.none` has exactly one terminal — the placer anchors it to a boundary.
pub const SymbolRole = enum(u8) {
    none = 0,
    power_rail,
    ground_rail,
    input_port,
    output_port,
    bidir_port,
    net_label,
};

/// One terminal of a class: name, electrical role, canonical anchor point.
///
/// `name` is static for builtins and arena-owned for host classes; either way it is
/// borrowed by every consumer and never freed through a `Terminal`.
pub const Terminal = struct {
    /// Lowercase pin name (`"d"`, `"clk"`, `"in+"`). Borrowed; valid as long as the owning
    /// class is.
    name: []const u8,
    role: TerminalRole = .passive,
    /// Anchor point in the canonical frame. Pin order is SPICE node order.
    at: Pt,
};

/// One symbol-body primitive, in canonical (unoriented) coordinates.
///
/// A tagged union rather than a struct with a kind field and unused coordinates: the four
/// shapes carry genuinely different payloads, and the table is static data a renderer
/// switches over exactly once per op.
pub const DrawOp = union(enum) {
    line: struct { a: Pt, b: Pt },
    /// Open polyline; a closed shape repeats its first point. Borrowed, static for
    /// builtins.
    polyline: []const Pt,
    circle: struct { c: Pt, r: i32 },
    /// Symbol-internal text: pin labels and box titles. `at` is the glyph *centre*, and
    /// that anchor is the only thing orientation moves — renderers draw text upright
    /// regardless, so a mirrored flip-flop still reads `CLK` and not `KLC`.
    text: struct { at: Pt, s: []const u8, size: u8 },

    /// Convenience constructor for the common case, so table entries read as coordinates.
    pub fn ln(x1: i32, y1: i32, x2: i32, y2: i32) DrawOp {
        return .{ .line = .{ .a = .{ .x = x1, .y = y1 }, .b = .{ .x = x2, .y = y2 } } };
    }

    /// Convenience constructor for a circle.
    pub fn circ(x: i32, y: i32, r: i32) DrawOp {
        return .{ .circle = .{ .c = .{ .x = x, .y = y }, .r = r } };
    }
};

/// Rendered width of `s` at `size`, in grid units.
///
/// 0.6 em per character is the widest the sans (SVG) / Computer Modern (TikZ) pairing needs
/// at these sizes, and both renderers force exactly this advance — so this is a contract,
/// not an estimate. Integer division truncates, deliberately: the same value must come out
/// at comptime (baking a box body) and at run time (a host class), and float rounding would
/// not be bit-identical across both.
///
/// Works at comptime. Allocation-free.
pub fn textWidth(s: []const u8, size: u8) i32 {
    return @intCast((s.len * @as(usize, size) * 6) / 10);
}

/// A fully-defined device type. Pure data — every device shares one placement algorithm,
/// so there is no per-class behavior and no vtable anywhere in this program.
///
/// All four slice fields are borrowed: static for builtins, owned by a `host.Table`'s arena
/// for host classes. Copying a `DeviceClass` copies the views, never the data, which is why
/// `host.Table.at` can safely return one by value.
pub const DeviceClass = struct {
    /// Lowercase class name, unique across the table. Lookup keys are matched byte-exactly,
    /// so callers fold case before asking (`strings.Interner.internFold` already does).
    name: []const u8,
    role: SymbolRole = .none,
    /// Terminals in SPICE node order. Non-empty for every class.
    terminals: []const Terminal,
    /// Symbol body. Non-empty for every class.
    draw: []const DrawOp,
    /// SPICE reference-designator letter (`'R'`, `'M'`, …), or `' '` for rails and ports,
    /// which have no element card. A `u8`, not a 4-byte `char`: every value is ASCII.
    prefix: u8,
    /// Default value text (`"1k"`, `"1u"`), empty when the device has no value.
    default_value: []const u8 = "",

    /// Pin slot of the first terminal with `role`, or null when the class has none.
    ///
    /// Linear scan over at most a handful of terminals — a lookup table per role would be
    /// larger than the data it indexes. Works at comptime.
    pub fn termSlot(self: DeviceClass, role: TerminalRole) ?u8 {
        for (self.terminals, 0..) |t, i| {
            if (t.role == role) return @intCast(i);
        }
        return null;
    }

    pub fn terminalCount(self: DeviceClass) u8 {
        return @intCast(self.terminals.len);
    }

    /// Canonical bounding box: `cell_width` wide, height derived from the geometry.
    ///
    /// Computed on every call, never stored — see the module header. The x half-extent
    /// *floors* at `cell_half` so the builtin vocabulary is uniform, but grows to cover a
    /// host class whose runtime anchors sit wider; the placer packs on per-column widths, so
    /// a wide host symbol costs space rather than correctness.
    ///
    /// Accounts for every op: line endpoints, all polyline points, the circle's enclosing
    /// square, and a text op's forced box (`textWidth` wide, `size` tall, centred on `at`).
    ///
    /// Returns the box in canonical coordinates; `geom.placedRect` is what orients and
    /// translates it. Never empty — every class has at least one terminal, so the y range is
    /// always initialized. O(terminals + draw ops), allocation-free.
    pub fn bbox(self: DeviceClass) Rect {
        // Width floors at `cell_half` so the builtin vocabulary shares one column pitch, but
        // grows for a host class whose anchors sit wider. y is unseeded: every class has at
        // least one terminal, so the first `hit` initializes it.
        var half: i32 = cell_half;
        var ymin: i32 = std.math.maxInt(i32);
        var ymax: i32 = std.math.minInt(i32);

        const H = struct {
            fn hit(hl: *i32, lo: *i32, hi: *i32, p: Pt) void {
                hl.* = @max(hl.*, if (p.x < 0) -p.x else p.x);
                lo.* = @min(lo.*, p.y);
                hi.* = @max(hi.*, p.y);
            }
        };

        for (self.terminals) |t| H.hit(&half, &ymin, &ymax, t.at);
        for (self.draw) |op| switch (op) {
            .line => |l| {
                H.hit(&half, &ymin, &ymax, l.a);
                H.hit(&half, &ymin, &ymax, l.b);
            },
            .polyline => |pts| for (pts) |p| H.hit(&half, &ymin, &ymax, p),
            .circle => |c| {
                H.hit(&half, &ymin, &ymax, .{ .x = c.c.x - c.r, .y = c.c.y - c.r });
                H.hit(&half, &ymin, &ymax, .{ .x = c.c.x + c.r, .y = c.c.y + c.r });
            },
            .text => |t| {
                const w = @divTrunc(textWidth(t.s, t.size), 2);
                const h = @divTrunc(@as(i32, t.size), 2);
                H.hit(&half, &ymin, &ymax, .{ .x = t.at.x - w, .y = t.at.y - h });
                H.hit(&half, &ymin, &ymax, .{ .x = t.at.x + w, .y = t.at.y + h });
            },
        };

        return .{ .min = .{ .x = -half, .y = ymin }, .max = .{ .x = half, .y = ymax } };
    }
};

// ---------------------------------------------------------------------------
// Terminal sets, shared by every class with the same topology.
//
// Sharing them is not just brevity: it is what guarantees a `nfet` and a `pfet` present
// identical pin geometry to the placer, so a netlist that swaps one for the other places
// the same way.
// ---------------------------------------------------------------------------

/// MOSFET / JFET / MESFET: conducting pair on the axis, gate off-axis above.
pub const mos: []const Terminal = &.{
    .{ .name = "d", .role = .drain, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "g", .role = .gate, .at = .{ .x = 0, .y = -20 } },
    .{ .name = "s", .role = .source, .at = .{ .x = -20, .y = 0 } },
};

/// BJT: collector/emitter on the axis, base off-axis above.
pub const bjt: []const Terminal = &.{
    .{ .name = "c", .role = .collector, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "b", .role = .base, .at = .{ .x = 0, .y = -20 } },
    .{ .name = "e", .role = .emitter, .at = .{ .x = -20, .y = 0 } },
};

/// Any two-terminal passive bipole.
pub const two: []const Terminal = &.{
    .{ .name = "a", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "b", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};

/// IGBT: collector/emitter on the axis, insulated gate off-axis above.
pub const igbt: []const Terminal = &.{
    .{ .name = "c", .role = .collector, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "g", .role = .gate, .at = .{ .x = 0, .y = -20 } },
    .{ .name = "e", .role = .emitter, .at = .{ .x = -20, .y = 0 } },
};

/// Diode: anode left, cathode right.
pub const diode_t: []const Terminal = &.{
    .{ .name = "a", .role = .anode, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "k", .role = .cathode, .at = .{ .x = 20, .y = 0 } },
};

/// Single tap at the origin: rails, supplies and ports.
pub const rail: []const Terminal = &.{
    .{ .name = "p", .role = .passive, .at = .{ .x = 0, .y = 0 } },
};

/// Single tap at the origin for a one-ended element (antenna). Same geometry as `rail`, a
/// different pin name, because a netlist writes the pin by name.
pub const one: []const Terminal = &.{
    .{ .name = "t", .role = .passive, .at = .{ .x = 0, .y = 0 } },
};

/// Potentiometer: bipole plus a wiper below the axis.
pub const pot_t: []const Terminal = &.{
    .{ .name = "a", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "b", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "w", .role = .passive, .at = .{ .x = 0, .y = 20 } },
};

/// Triac / thyristor: bipole plus a gate above the axis.
pub const triac_t: []const Terminal = &.{
    .{ .name = "a", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "b", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "g", .role = .gate, .at = .{ .x = 0, .y = -20 } },
};

/// SPDT switch: pole on the left edge, primary throw on the right edge, second throw below.
pub const spdt_t: []const Terminal = &.{
    .{ .name = "in", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "a", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "b", .role = .passive, .at = .{ .x = 20, .y = 20 } },
};

/// Single-ended op-amp / transconductor.
pub const opamp_t: []const Terminal = &.{
    .{ .name = "in+", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "in-", .role = .passive, .at = .{ .x = -20, .y = -12 } },
};

/// Fully differential op-amp.
pub const fdopamp_t: []const Terminal = &.{
    .{ .name = "in+", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "out+", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "in-", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "out-", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};

/// Two-input logic gate.
pub const gate2: []const Terminal = &.{
    .{ .name = "in1", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "in2", .role = .passive, .at = .{ .x = -20, .y = -12 } },
};

/// One-input logic gate (inverter, buffer, Schmitt trigger).
pub const gate1: []const Terminal = &.{
    .{ .name = "in", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};

/// Two-winding transformer: primary on the axis, secondary above it.
pub const xfmr_t: []const Terminal = &.{
    .{ .name = "l1", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "r1", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "l2", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "r2", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};

/// D flip-flop pin set. Pin order is the SPICE node order of an `X` instance.
pub const dff_t: []const Terminal = &.{
    .{ .name = "d", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "clk", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "q", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "qb", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};

// ---------------------------------------------------------------------------
// Symbol bodies, shared per visual family.
// ---------------------------------------------------------------------------

const ln = DrawOp.ln;
const circ = DrawOp.circ;

/// Enhancement NMOS: leads bend up to a three-segment channel (the breaks mean
/// enhancement), a solid gate plate across the insulator gap, bulk arrow pointing *into*
/// the channel for n-type.
pub const draw_nmos: []const DrawOp = &.{
    ln(-20, 0, -8, 0),  ln(8, 0, 20, 0),
    ln(-8, 0, -8, -4),  ln(8, 0, 8, -4),
    ln(-8, -4, -3, -4), ln(-2, -4, 2, -4),
    ln(3, -4, 8, -4),   ln(-8, -9, 8, -9),
    ln(0, -9, 0, -20),  ln(-8, -4, -11, -1),
    ln(-8, -4, -5, -1),
};

/// Enhancement PMOS: identical to `draw_nmos` except the bulk arrow points *out*.
pub const draw_pmos: []const DrawOp = &.{
    ln(-20, 0, -8, 0),  ln(8, 0, 20, 0),
    ln(-8, 0, -8, -4),  ln(8, 0, 8, -4),
    ln(-8, -4, -3, -4), ln(-2, -4, 2, -4),
    ln(3, -4, 8, -4),   ln(-8, -9, 8, -9),
    ln(0, -9, 0, -20),  ln(-8, 0, -11, -3),
    ln(-8, 0, -5, -3),
};

/// NPN: base bar, emitter/collector diagonals, emitter arrow pointing out.
pub const draw_npn: []const DrawOp = &.{
    ln(0, -8, 0, 8),   ln(0, -8, 0, -20),
    ln(-20, 0, -8, 0), ln(-8, 0, 0, 5),
    ln(20, 0, 8, 0),   ln(8, 0, 0, -5),
    ln(-8, 0, -5, 4),  ln(-8, 0, -3, 1),
};

/// Resistor, american zigzag.
pub const draw_res: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    .{ .polyline = &.{
        .{ .x = -10, .y = 0 }, .{ .x = -8, .y = 6 }, .{ .x = -4, .y = -6 },
        .{ .x = 0, .y = 6 },   .{ .x = 4, .y = -6 }, .{ .x = 8, .y = 6 },
        .{ .x = 10, .y = 0 },
    } },
};

/// Non-polarized capacitor: two straight plates.
pub const draw_cap: []const DrawOp = &.{
    ln(-20, 0, -3, 0), ln(3, 0, 20, 0),
    ln(-3, -8, -3, 8), ln(3, -8, 3, 8),
};

/// Diode: triangle into a cathode bar.
pub const draw_diode: []const DrawOp = &.{
    ln(-20, 0, -8, 0), ln(8, 0, 20, 0),
    ln(-8, -7, -8, 7), ln(-8, -7, 8, 0),
    ln(-8, 7, 8, 0),   ln(8, -7, 8, 7),
};

/// DC voltage source: circle body with a `+`/`-` glyph.
pub const draw_vsource: []const DrawOp = &.{
    ln(-20, 0, -12, 0), ln(12, 0, 20, 0),
    circ(0, 0, 12),     ln(-7, -2, -7, 2),
    ln(-9, 0, -5, 0),   ln(5, 0, 9, 0),
};

/// Ground: three shrinking bars *below* the pin. y is screen-down, and ground sits at the
/// bottom of a schematic, so the bars grow in +y.
pub const draw_ground: []const DrawOp = &.{
    ln(0, 0, 0, 8),    ln(-10, 8, 10, 8),
    ln(-6, 12, 6, 12), ln(-2, 16, 2, 16),
};

/// Supply rail: one bar *above* the pin (−y), mirroring `draw_ground`.
pub const draw_vdd: []const DrawOp = &.{ ln(0, 0, 0, -8), ln(-8, -8, 8, -8) };

/// Unmodelled two-terminal element: a plain rectangle with leads. This is the fallback the
/// front end reaches for when `Config.pdk.unknown_as_box` is set.
pub const draw_box: []const DrawOp = &.{
    ln(-20, 0, -10, 0),  ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6), ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),   ln(-10, 6, -10, -6),
};

/// D flip-flop: a generated box body. Every op below is exactly what `box.bodyLen`-many
/// calls to `box.outline` / `box.titleAt` / `box.lead` / `box.labelAt` produce for `dff_t`,
/// baked in by the generator so the table stays pure data.
///
/// Box rect for `dff_t` is (-12, -24)..(12, 4): x inset by `box.pin_len` from the ±20 pin
/// columns, y grown by `box.pad` below and `box.pad + box.title_h` above to reserve the
/// title strip.
pub const draw_dff: []const DrawOp = &.{
    .{ .polyline = &.{
        .{ .x = -12, .y = -24 }, .{ .x = 12, .y = -24 },  .{ .x = 12, .y = 4 },
        .{ .x = -12, .y = 4 },   .{ .x = -12, .y = -24 },
    } },
    .{ .text = .{ .at = .{ .x = 0, .y = -20 }, .s = "DFF", .size = box.title_size } },
    ln(-20, 0, -12, 0),
    ln(-20, -12, -12, -12),
    ln(20, 0, 12, 0),
    ln(20, -12, 12, -12),
    // -9, not -11: `box.labelAt` is `min.x + label_inset + half`, and half of the forced
    // width of "d" at size 4 is 1. The other three labels here already follow that rule.
    .{ .text = .{ .at = .{ .x = -9, .y = 0 }, .s = "d", .size = box.pin_size } },
    .{ .text = .{ .at = .{ .x = -7, .y = -12 }, .s = "clk", .size = box.pin_size } },
    .{ .text = .{ .at = .{ .x = 9, .y = 0 }, .s = "q", .size = box.pin_size } },
    .{ .text = .{ .at = .{ .x = 8, .y = -12 }, .s = "qb", .size = box.pin_size } },
};

// ---------------------------------------------------------------------------
// The remaining bodies, mechanically converted from the Rust `bodies.rs` table.
// Coordinates are transcribed verbatim; see the generation contract on `classes`.
// ---------------------------------------------------------------------------

pub const draw_ind: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(-9, 0, 3),
    circ(-3, 0, 3),
    circ(3, 0, 3),
    circ(9, 0, 3),
};

pub const draw_led: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, -7, -8, 7),
    ln(-8, -7, 8, 0),
    ln(-8, 7, 8, 0),
    ln(8, -7, 8, 7),
    ln(2, 10, 8, 16),
    ln(6, 10, 12, 16),
};

pub const draw_njfet: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, 0, -8, -5),
    ln(8, 0, 8, -5),
    ln(-8, -5, 8, -5),
    ln(0, -20, 0, -5),
    ln(0, -5, -3, -9),
    ln(0, -5, 3, -9),
};

pub const draw_pjfet: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, 0, -8, -5),
    ln(8, 0, 8, -5),
    ln(-8, -5, 8, -5),
    ln(0, -20, 0, -5),
    ln(0, -9, -3, -5),
    ln(0, -9, 3, -5),
};

pub const draw_pnp: []const DrawOp = &.{
    ln(0, -8, 0, 8),
    ln(0, -8, 0, -20),
    ln(-20, 0, -8, 0),
    ln(-8, 0, 0, 5),
    ln(20, 0, 8, 0),
    ln(8, 0, 0, -5),
    ln(0, 5, -3, 4),
    ln(0, 5, -1, 1),
};

pub const draw_nigbt: []const DrawOp = &.{
    ln(0, -7, 0, 7),
    ln(-20, 0, -8, 0),
    ln(-8, 0, 0, 5),
    ln(20, 0, 8, 0),
    ln(8, 0, 0, -5),
    ln(-4, -7, -4, 7),
    .{ .polyline = &.{ .{ .x = 0, .y = -20 }, .{ .x = 0, .y = -11 }, .{ .x = -4, .y = -11 }, .{ .x = -4, .y = -7 } } },
    ln(8, 0, 5, 4),
    ln(8, 0, 3, 1),
};

pub const draw_pigbt: []const DrawOp = &.{
    ln(0, -7, 0, 7),
    ln(-20, 0, -8, 0),
    ln(-8, 0, 0, 5),
    ln(20, 0, 8, 0),
    ln(8, 0, 0, -5),
    ln(-4, -7, -4, 7),
    .{ .polyline = &.{ .{ .x = 0, .y = -20 }, .{ .x = 0, .y = -11 }, .{ .x = -4, .y = -11 }, .{ .x = -4, .y = -7 } } },
    ln(0, 5, -3, 4),
    ln(0, 5, -1, 1),
};

pub const draw_schottky: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, -7, -8, 7),
    ln(-8, -7, 8, 0),
    ln(-8, 7, 8, 0),
    .{ .polyline = &.{ .{ .x = 11, .y = -4 }, .{ .x = 11, .y = -7 }, .{ .x = 8, .y = -7 }, .{ .x = 8, .y = 7 }, .{ .x = 5, .y = 7 }, .{ .x = 5, .y = 4 } } },
};

pub const draw_zener: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, -7, -8, 7),
    ln(-8, -7, 8, 0),
    ln(-8, 7, 8, 0),
    .{ .polyline = &.{ .{ .x = 5, .y = -7 }, .{ .x = 8, .y = -7 }, .{ .x = 8, .y = 7 }, .{ .x = 11, .y = 7 } } },
};

pub const draw_tunnel: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, -7, -8, 7),
    ln(-8, -7, 8, 0),
    ln(-8, 7, 8, 0),
    .{ .polyline = &.{ .{ .x = 5, .y = -7 }, .{ .x = 8, .y = -7 }, .{ .x = 8, .y = 7 }, .{ .x = 5, .y = 7 } } },
};

pub const draw_varcap: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(11, 0, 20, 0),
    ln(-8, -7, -8, 7),
    ln(-8, -7, 8, 0),
    ln(-8, 7, 8, 0),
    ln(8, -7, 8, 7),
    ln(11, -7, 11, 7),
};

pub const draw_tvs: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -7, -10, 7),
    ln(-10, -7, 0, 0),
    ln(-10, 7, 0, 0),
    ln(10, -7, 10, 7),
    ln(10, -7, 0, 0),
    ln(10, 7, 0, 0),
    ln(-10, -7, -13, -7),
    ln(10, 7, 13, 7),
};

pub const draw_photodiode: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, -7, -8, 7),
    ln(-8, -7, 8, 0),
    ln(-8, 7, 8, 0),
    ln(8, -7, 8, 7),
    ln(12, -16, 4, -8),
    ln(4, -8, 7, -8),
    ln(4, -8, 4, -11),
    ln(16, -12, 8, -4),
    ln(8, -4, 11, -4),
    ln(8, -4, 8, -7),
};

pub const draw_vsourceac: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    .{ .polyline = &.{ .{ .x = -7, .y = 0 }, .{ .x = -4, .y = -5 }, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 5 }, .{ .x = 7, .y = 0 } } },
};

pub const draw_isource: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    ln(0, -6, 0, 6),
    ln(-3, 3, 0, 6),
    ln(3, 3, 0, 6),
};

pub const draw_isourceac: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    .{ .polyline = &.{ .{ .x = -7, .y = 0 }, .{ .x = -4, .y = -5 }, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 5 }, .{ .x = 7, .y = 0 } } },
    ln(12, 0, 9, -2),
    ln(12, 0, 9, 2),
};

pub const draw_cvsource: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    .{ .polyline = &.{ .{ .x = -12, .y = 0 }, .{ .x = 0, .y = -12 }, .{ .x = 12, .y = 0 }, .{ .x = 0, .y = 12 }, .{ .x = -12, .y = 0 } } },
    ln(-7, -2, -7, 2),
    ln(-9, 0, -5, 0),
    ln(5, 0, 9, 0),
};

pub const draw_cisource: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    .{ .polyline = &.{ .{ .x = -12, .y = 0 }, .{ .x = 0, .y = -12 }, .{ .x = 12, .y = 0 }, .{ .x = 0, .y = 12 }, .{ .x = -12, .y = 0 } } },
    ln(0, 6, 0, -6),
    ln(-3, -3, 0, -6),
    ln(3, -3, 0, -6),
};

pub const draw_ammeter: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    .{ .polyline = &.{ .{ .x = -4, .y = 5 }, .{ .x = 0, .y = -5 }, .{ .x = 4, .y = 5 } } },
    ln(-2, 1, 2, 1),
};

pub const draw_voltmeter: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    .{ .polyline = &.{ .{ .x = -4, .y = -5 }, .{ .x = 0, .y = 5 }, .{ .x = 4, .y = -5 } } },
};

pub const draw_ohmmeter: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    .{ .polyline = &.{ .{ .x = -5, .y = 5 }, .{ .x = -3, .y = 5 }, .{ .x = -4, .y = 1 }, .{ .x = -2, .y = -4 }, .{ .x = 2, .y = -4 }, .{ .x = 4, .y = 1 }, .{ .x = 3, .y = 5 }, .{ .x = 5, .y = 5 } } },
};

pub const draw_motor: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    .{ .polyline = &.{ .{ .x = -4, .y = 5 }, .{ .x = -4, .y = -5 }, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = -5 }, .{ .x = 4, .y = 5 } } },
};

pub const draw_lamp: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(0, 0, 12),
    ln(-8, -8, 8, 8),
    ln(-8, 8, 8, -8),
};

pub const draw_fuse: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    ln(-10, 0, 10, 0),
};

pub const draw_varistor: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    ln(-11, 9, 11, -9),
    ln(11, -9, 6, -8),
    ln(11, -9, 8, -3),
};

pub const draw_thermistor: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    .{ .polyline = &.{ .{ .x = -11, .y = 9 }, .{ .x = -7, .y = 9 }, .{ .x = 11, .y = -9 } } },
};

pub const draw_thermistorptc: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    .{ .polyline = &.{ .{ .x = -11, .y = 9 }, .{ .x = -7, .y = 9 }, .{ .x = 11, .y = -9 } } },
    ln(4, -9, 8, -9),
    ln(6, -11, 6, -7),
};

pub const draw_thermistorntc: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    .{ .polyline = &.{ .{ .x = -11, .y = 9 }, .{ .x = -7, .y = 9 }, .{ .x = 11, .y = -9 } } },
    ln(4, -9, 8, -9),
};

pub const draw_photoresistor: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    ln(14, -15, 6, -7),
    ln(6, -7, 9, -7),
    ln(6, -7, 6, -10),
    ln(18, -11, 10, -3),
    ln(10, -3, 13, -3),
    ln(10, -3, 10, -6),
};

pub const draw_crystal: []const DrawOp = &.{
    ln(-20, 0, -7, 0),
    ln(7, 0, 20, 0),
    ln(-7, -7, -7, 7),
    ln(7, -7, 7, 7),
    ln(-4, -6, 4, -6),
    ln(4, -6, 4, 6),
    ln(4, 6, -4, 6),
    ln(-4, 6, -4, -6),
};

pub const draw_memristor: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    .{ .polyline = &.{ .{ .x = -8, .y = 6 }, .{ .x = -8, .y = -6 }, .{ .x = -3, .y = 6 }, .{ .x = -3, .y = -6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = -6 } } },
    ln(5, 6, 5, -6),
    ln(5, 6, 9, -6),
    ln(5, 0, 9, -6),
    ln(5, -6, 9, -6),
};

pub const draw_loudspeaker: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(8, 0, 20, 0),
    ln(-12, -5, -6, -5),
    ln(-6, -5, -6, 5),
    ln(-6, 5, -12, 5),
    ln(-12, 5, -12, -5),
    ln(-6, -5, 8, -11),
    ln(8, -11, 8, 11),
    ln(8, 11, -6, 5),
};

pub const draw_microphone: []const DrawOp = &.{
    ln(-20, 0, -6, 0),
    ln(6, 0, 20, 0),
    circ(0, 0, 6),
    ln(6, -7, 6, 7),
};

pub const draw_buzzer: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, 6, 10, 6),
    .{ .polyline = &.{ .{ .x = -10, .y = 6 }, .{ .x = -9, .y = -3 }, .{ .x = -5, .y = -9 }, .{ .x = 0, .y = -11 }, .{ .x = 5, .y = -9 }, .{ .x = 9, .y = -3 }, .{ .x = 10, .y = 6 } } },
};

pub const draw_ecap: []const DrawOp = &.{
    ln(-20, 0, -3, 0),
    ln(4, 0, 20, 0),
    ln(-3, -8, -3, 8),
    .{ .polyline = &.{ .{ .x = 7, .y = -8 }, .{ .x = 4, .y = -4 }, .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 7, .y = 8 } } },
    ln(-9, -8, -5, -8),
    ln(-7, -10, -7, -6),
};

pub const draw_vcap: []const DrawOp = &.{
    ln(-20, 0, -3, 0),
    ln(3, 0, 20, 0),
    ln(-3, -8, -3, 8),
    ln(3, -8, 3, 8),
    ln(-9, 9, 9, -9),
    ln(9, -9, 4, -8),
    ln(9, -9, 6, -3),
};

pub const draw_vind: []const DrawOp = &.{
    ln(-20, 0, -12, 0),
    ln(12, 0, 20, 0),
    circ(-9, 0, 3),
    circ(-3, 0, 3),
    circ(3, 0, 3),
    circ(9, 0, 3),
    ln(-11, 9, 11, -9),
    ln(11, -9, 6, -8),
    ln(11, -9, 8, -3),
};

pub const draw_battery: []const DrawOp = &.{
    ln(-20, 0, -4, 0),
    ln(4, 0, 20, 0),
    ln(-4, -10, -4, 10),
    ln(4, -5, 4, 5),
};

pub const draw_port: []const DrawOp = &.{
    ln(0, 0, 6, 0),
    ln(6, -5, 14, 0),
    ln(14, 0, 6, 5),
    ln(6, 5, 6, -5),
};

pub const draw_switch: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, 0, 6, 8),
    circ(-8, 0, 1),
    circ(8, 0, 1),
};

pub const draw_ncswitch: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(-8, 0, 9, -2),
    circ(-8, 0, 1),
    circ(8, 0, 1),
    ln(9, -6, 9, 4),
};

pub const draw_pushbutton: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    circ(-8, 0, 1),
    circ(8, 0, 1),
    ln(-9, -6, 9, -6),
    ln(0, -6, 0, -12),
    ln(-5, -12, 5, -12),
};

pub const draw_spdt: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(8, 20, 20, 20),
    circ(-8, 0, 1),
    circ(8, 0, 1),
    circ(8, 20, 1),
    ln(-8, 0, 8, 6),
};

pub const draw_antenna: []const DrawOp = &.{
    ln(0, 0, 0, -12),
    ln(-8, -20, 0, -12),
    ln(8, -20, 0, -12),
};

pub const draw_pot: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -6, 10, -6),
    ln(10, -6, 10, 6),
    ln(10, 6, -10, 6),
    ln(-10, 6, -10, -6),
    ln(0, 20, 0, 8),
    ln(-3, 11, 0, 8),
    ln(3, 11, 0, 8),
};

pub const draw_triac: []const DrawOp = &.{
    ln(-20, 0, -8, 0),
    ln(8, 0, 20, 0),
    ln(0, -20, 0, -6),
    ln(-8, -7, -8, 7),
    ln(-8, -7, 0, 0),
    ln(-8, 7, 0, 0),
    ln(8, -7, 8, 7),
    ln(8, -7, 0, 0),
    ln(8, 7, 0, 0),
};

pub const draw_opamp: []const DrawOp = &.{
    ln(-20, 0, -12, 6),
    ln(-20, -12, -12, -6),
    ln(12, 0, 20, 0),
    ln(-12, 12, -12, -12),
    ln(-12, 12, 12, 0),
    ln(-12, -12, 12, 0),
};

pub const draw_and: []const DrawOp = &.{
    ln(-20, 0, -10, 5),
    ln(-20, -12, -10, -5),
    ln(13, 0, 20, 0),
    ln(-10, 12, -10, -12),
    ln(-10, -12, 2, -12),
    ln(-10, 12, 2, 12),
    .{ .polyline = &.{ .{ .x = 2, .y = -12 }, .{ .x = 9, .y = -10 }, .{ .x = 12, .y = -6 }, .{ .x = 13, .y = 0 }, .{ .x = 12, .y = 6 }, .{ .x = 9, .y = 10 }, .{ .x = 2, .y = 12 } } },
};

pub const draw_nand: []const DrawOp = &.{
    ln(-20, 0, -10, 5),
    ln(-20, -12, -10, -5),
    ln(17, 0, 20, 0),
    ln(-10, 12, -10, -12),
    ln(-10, -12, 2, -12),
    ln(-10, 12, 2, 12),
    .{ .polyline = &.{ .{ .x = 2, .y = -12 }, .{ .x = 9, .y = -10 }, .{ .x = 12, .y = -6 }, .{ .x = 13, .y = 0 }, .{ .x = 12, .y = 6 }, .{ .x = 9, .y = 10 }, .{ .x = 2, .y = 12 } } },
    circ(15, 0, 2),
};

pub const draw_or: []const DrawOp = &.{
    ln(-20, 0, -9, 4),
    ln(-20, -12, -9, -4),
    ln(13, 0, 20, 0),
    .{ .polyline = &.{ .{ .x = -10, .y = 12 }, .{ .x = -6, .y = 0 }, .{ .x = -10, .y = -12 } } },
    .{ .polyline = &.{ .{ .x = -10, .y = -12 }, .{ .x = 3, .y = -11 }, .{ .x = 10, .y = -6 }, .{ .x = 13, .y = 0 }, .{ .x = 10, .y = 6 }, .{ .x = 3, .y = 11 }, .{ .x = -10, .y = 12 } } },
};

pub const draw_nor: []const DrawOp = &.{
    ln(-20, 0, -9, 4),
    ln(-20, -12, -9, -4),
    ln(17, 0, 20, 0),
    .{ .polyline = &.{ .{ .x = -10, .y = 12 }, .{ .x = -6, .y = 0 }, .{ .x = -10, .y = -12 } } },
    .{ .polyline = &.{ .{ .x = -10, .y = -12 }, .{ .x = 3, .y = -11 }, .{ .x = 10, .y = -6 }, .{ .x = 13, .y = 0 }, .{ .x = 10, .y = 6 }, .{ .x = 3, .y = 11 }, .{ .x = -10, .y = 12 } } },
    circ(15, 0, 2),
};

pub const draw_xor: []const DrawOp = &.{
    ln(-20, 0, -12, 4),
    ln(-20, -12, -12, -4),
    ln(13, 0, 20, 0),
    .{ .polyline = &.{ .{ .x = -13, .y = 12 }, .{ .x = -9, .y = 0 }, .{ .x = -13, .y = -12 } } },
    .{ .polyline = &.{ .{ .x = -10, .y = 12 }, .{ .x = -6, .y = 0 }, .{ .x = -10, .y = -12 } } },
    .{ .polyline = &.{ .{ .x = -10, .y = -12 }, .{ .x = 3, .y = -11 }, .{ .x = 10, .y = -6 }, .{ .x = 13, .y = 0 }, .{ .x = 10, .y = 6 }, .{ .x = 3, .y = 11 }, .{ .x = -10, .y = 12 } } },
};

pub const draw_xnor: []const DrawOp = &.{
    ln(-20, 0, -12, 4),
    ln(-20, -12, -12, -4),
    ln(17, 0, 20, 0),
    .{ .polyline = &.{ .{ .x = -13, .y = 12 }, .{ .x = -9, .y = 0 }, .{ .x = -13, .y = -12 } } },
    .{ .polyline = &.{ .{ .x = -10, .y = 12 }, .{ .x = -6, .y = 0 }, .{ .x = -10, .y = -12 } } },
    .{ .polyline = &.{ .{ .x = -10, .y = -12 }, .{ .x = 3, .y = -11 }, .{ .x = 10, .y = -6 }, .{ .x = 13, .y = 0 }, .{ .x = 10, .y = 6 }, .{ .x = 3, .y = 11 }, .{ .x = -10, .y = 12 } } },
    circ(15, 0, 2),
};

pub const draw_not: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(14, 0, 20, 0),
    ln(-10, -12, -10, 12),
    ln(-10, 12, 10, 0),
    ln(10, 0, -10, -12),
    circ(12, 0, 2),
};

pub const draw_buffer: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(10, 0, 20, 0),
    ln(-10, -12, -10, 12),
    ln(-10, 12, 10, 0),
    ln(10, 0, -10, -12),
};

pub const draw_xfmr: []const DrawOp = &.{
    ln(-20, 0, -10, 0),
    ln(-20, -12, -10, -12),
    ln(20, 0, 10, 0),
    ln(20, -12, 10, -12),
    circ(-8, -2, 5),
    circ(-8, -10, 5),
    circ(8, -2, 5),
    circ(8, -10, 5),
    ln(-2, -18, -2, 6),
    ln(2, -18, 2, 6),
};

// ---------------------------------------------------------------------------
// Box devices: terminals declared, body generated by `boxBody` at comptime.
// ---------------------------------------------------------------------------

pub const jkff_t: []const Terminal = &.{
    .{ .name = "j", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "k", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "clk", .role = .passive, .at = .{ .x = -20, .y = -24 } },
    .{ .name = "q", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "qb", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};
pub const draw_jkff: []const DrawOp = boxBody(jkff_t, "JKFF");

pub const srff_t: []const Terminal = &.{
    .{ .name = "s", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "r", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "clk", .role = .passive, .at = .{ .x = -20, .y = -24 } },
    .{ .name = "q", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "qb", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};
pub const draw_srff: []const DrawOp = boxBody(srff_t, "SRFF");

pub const dlatch_t: []const Terminal = &.{
    .{ .name = "d", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "en", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "q", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "qb", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};
pub const draw_dlatch: []const DrawOp = boxBody(dlatch_t, "DLAT");

pub const mux_t: []const Terminal = &.{
    .{ .name = "i0", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "i1", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "sel", .role = .passive, .at = .{ .x = -20, .y = -24 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};
pub const draw_mux: []const DrawOp = boxBody(mux_t, "MUX");

pub const demux_t: []const Terminal = &.{
    .{ .name = "in", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "sel", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "o0", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "o1", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};
pub const draw_demux: []const DrawOp = boxBody(demux_t, "DMUX");

pub const tristate_t: []const Terminal = &.{
    .{ .name = "in", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "en", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};
pub const draw_tristate: []const DrawOp = boxBody(tristate_t, "TRI");

pub const adc_t: []const Terminal = &.{
    .{ .name = "in", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "clk", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};
pub const draw_adc: []const DrawOp = boxBody(adc_t, "ADC");

pub const dac_t: []const Terminal = &.{
    .{ .name = "in", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "clk", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};
pub const draw_dac: []const DrawOp = boxBody(dac_t, "DAC");

pub const comparator_t: []const Terminal = &.{
    .{ .name = "in+", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "in-", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};
pub const draw_comparator: []const DrawOp = boxBody(comparator_t, "CMP");

pub const draw_schmitt: []const DrawOp = boxBody(gate1, "SCHM");

pub const mixer_t: []const Terminal = &.{
    .{ .name = "in1", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "in2", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};
pub const draw_mixer: []const DrawOp = boxBody(mixer_t, "MIX");

pub const tline_t: []const Terminal = &.{
    .{ .name = "a+", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "a-", .role = .passive, .at = .{ .x = -20, .y = -12 } },
    .{ .name = "b+", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "b-", .role = .passive, .at = .{ .x = 20, .y = -12 } },
};
pub const draw_tline: []const DrawOp = boxBody(tline_t, "TLIN");

pub const draw_mesfet: []const DrawOp = boxBody(mos, "MESF");

// ---------------------------------------------------------------------------
// The table.
// ---------------------------------------------------------------------------

/// The builtin device classes. A `SymbolIdx` below `builtin_count` indexes this array.
///
/// **Index order is a contract.** It is the order of the Rust `CLASSES` table, it is what a
/// serialized `SymbolIdx` in a golden fixture means, and the generator preserves it. Adding
/// a class appends; nothing is ever reordered or removed. `by_name` is derived from this
/// array, so a new entry needs no second edit.
///
/// ## THIS IS A REPRESENTATIVE SUBSET — the rest is generated
///
/// The Rust tree defines **96** classes across 1,034 lines of coordinate tables. Retyping
/// them by hand would manufacture exactly the transcription errors a port is supposed to
/// avoid, so per ARCHITECTURE.md "Tier 3 — mechanical" they are machine-converted. The
/// twelve entries below are the hand-written *specimens*: one per structural shape the
/// generator must reproduce (three-terminal with roles, two-terminal passive, diode,
/// circle-bodied source, single-terminal rail with a placement role, polyline body, plain
/// box body, and a generated box body with text ops). They are real, complete and
/// byte-faithful to the Rust originals — they are not placeholders.
///
/// ### Generation contract
///
/// 1. **Dump.** A one-off Rust binary in the `devices` crate serializes `CLASSES` to JSON,
///    in table order, one object per class:
///    ```json
///    { "name": "nmos", "role": "None", "prefix": "M", "default_value": "",
///      "terminals": [ { "name": "d", "role": "Drain", "at": [20, 0] }, … ],
///      "draw": [ {"line": [[-20,0],[-8,0]]},
///                {"polyline": [[-10,0],[-8,6]]},
///                {"circle": {"c": [0,0], "r": 12}},
///                {"text": {"at": [0,-20], "s": "DFF", "size": 6}} ] }
///    ```
///    Bodies are dumped **fully expanded**: shared constants (`DRAW_NMOS`) and macro-built
///    box bodies (`boxdev!`) are both emitted as literal op lists. The generator does not
///    re-derive box geometry, so `box` below and the Rust `box_rect`/`label_at` cannot
///    disagree by construction.
/// 2. **Emit.** A script rewrites this array from the JSON. Deduplicating identical
///    terminal sets and identical bodies into named consts (as above) is cosmetic and
///    optional; correctness does not depend on it.
/// 3. **Map the enums.** `SymbolRole::None -> .none`, `PowerRail -> .power_rail`, and so on
///    for `TerminalRole`; a name the mapping does not cover is a hard failure of the
///    generator, never a silent `.passive`.
/// 4. **Escape.** Class, terminal and text strings are ASCII in the source table (`"in+"`,
///    `"in-"`, `"a+"`) — emit them as Zig string literals with `\"` and `\\` escaped. A
///    non-ASCII byte is a hard failure: `textWidth` counts bytes, so a multi-byte glyph
///    would silently widen every box containing it.
/// 5. **Verify, on output not on source.** Every test in `tests/devices.zig` must pass over
///    the full table — in particular uniform `cell_width`, conduction terminals at (±20, 0),
///    and generated box labels inside their outline. Then render each of the 96 symbols
///    through both implementations and diff the SVG. A diff is a conversion bug; the tests
///    catch shape errors, the diff catches coordinate errors.
pub const classes: []const DeviceClass = &.{
    .{ .name = "nmos", .terminals = mos, .draw = draw_nmos, .prefix = 'M' }, // 0
    .{ .name = "pmos", .terminals = mos, .draw = draw_pmos, .prefix = 'M' }, // 1
    .{ .name = "nfet", .terminals = mos, .draw = draw_nmos, .prefix = 'M' }, // 2
    .{ .name = "pfet", .terminals = mos, .draw = draw_pmos, .prefix = 'M' }, // 3
    .{ .name = "nfetd", .terminals = mos, .draw = draw_nmos, .prefix = 'M' }, // 4
    .{ .name = "pfetd", .terminals = mos, .draw = draw_pmos, .prefix = 'M' }, // 5
    .{ .name = "njfet", .terminals = mos, .draw = draw_njfet, .prefix = 'J' }, // 6
    .{ .name = "pjfet", .terminals = mos, .draw = draw_pjfet, .prefix = 'J' }, // 7
    .{ .name = "npn", .terminals = bjt, .draw = draw_npn, .prefix = 'Q' }, // 8
    .{ .name = "pnp", .terminals = bjt, .draw = draw_pnp, .prefix = 'Q' }, // 9
    .{ .name = "nigbt", .terminals = igbt, .draw = draw_nigbt, .prefix = 'Q' }, // 10
    .{ .name = "pigbt", .terminals = igbt, .draw = draw_pigbt, .prefix = 'Q' }, // 11
    .{ .name = "res", .terminals = two, .draw = draw_res, .prefix = 'R', .default_value = "1k" }, // 12
    .{ .name = "generic", .terminals = two, .draw = draw_box, .prefix = 'R' }, // 13
    .{ .name = "varistor", .terminals = two, .draw = draw_varistor, .prefix = 'R' }, // 14
    .{ .name = "potentiometer", .terminals = pot_t, .draw = draw_pot, .prefix = 'R', .default_value = "10k" }, // 15
    .{ .name = "thermistor", .terminals = two, .draw = draw_thermistor, .prefix = 'R' }, // 16
    .{ .name = "thermistorptc", .terminals = two, .draw = draw_thermistorptc, .prefix = 'R' }, // 17
    .{ .name = "thermistorntc", .terminals = two, .draw = draw_thermistorntc, .prefix = 'R' }, // 18
    .{ .name = "photoresistor", .terminals = two, .draw = draw_photoresistor, .prefix = 'R' }, // 19
    .{ .name = "cap", .terminals = two, .draw = draw_cap, .prefix = 'C', .default_value = "1u" }, // 20
    .{ .name = "ecap", .terminals = two, .draw = draw_ecap, .prefix = 'C', .default_value = "1u" }, // 21
    .{ .name = "vcap", .terminals = two, .draw = draw_vcap, .prefix = 'C' }, // 22
    .{ .name = "ind", .terminals = two, .draw = draw_ind, .prefix = 'L', .default_value = "1m" }, // 23
    .{ .name = "cuteind", .terminals = two, .draw = draw_ind, .prefix = 'L', .default_value = "1m" }, // 24
    .{ .name = "vind", .terminals = two, .draw = draw_vind, .prefix = 'L' }, // 25
    .{ .name = "fuse", .terminals = two, .draw = draw_fuse, .prefix = 'F' }, // 26
    .{ .name = "lamp", .terminals = two, .draw = draw_lamp, .prefix = 'X' }, // 27
    .{ .name = "crystal", .terminals = two, .draw = draw_crystal, .prefix = 'X' }, // 28
    .{ .name = "memristor", .terminals = two, .draw = draw_memristor, .prefix = 'R' }, // 29
    .{ .name = "diode", .terminals = diode_t, .draw = draw_diode, .prefix = 'D' }, // 30
    .{ .name = "schottky", .terminals = diode_t, .draw = draw_schottky, .prefix = 'D' }, // 31
    .{ .name = "zener", .terminals = diode_t, .draw = draw_zener, .prefix = 'D' }, // 32
    .{ .name = "tunneldiode", .terminals = diode_t, .draw = draw_tunnel, .prefix = 'D' }, // 33
    .{ .name = "led", .terminals = diode_t, .draw = draw_led, .prefix = 'D' }, // 34
    .{ .name = "photodiode", .terminals = diode_t, .draw = draw_photodiode, .prefix = 'D' }, // 35
    .{ .name = "varcap", .terminals = diode_t, .draw = draw_varcap, .prefix = 'D' }, // 36
    .{ .name = "tvsdiode", .terminals = diode_t, .draw = draw_tvs, .prefix = 'D' }, // 37
    .{ .name = "diac", .terminals = two, .draw = draw_triac, .prefix = 'D' }, // 38
    .{ .name = "triac", .terminals = triac_t, .draw = draw_triac, .prefix = 'X' }, // 39
    .{ .name = "battery", .terminals = two, .draw = draw_battery, .prefix = 'V', .default_value = "9" }, // 40
    .{ .name = "vsource", .terminals = two, .draw = draw_vsource, .prefix = 'V' }, // 41
    .{ .name = "isource", .terminals = two, .draw = draw_isource, .prefix = 'I' }, // 42
    .{ .name = "vsourceac", .terminals = two, .draw = draw_vsourceac, .prefix = 'V' }, // 43
    .{ .name = "isourceac", .terminals = two, .draw = draw_isourceac, .prefix = 'I' }, // 44
    .{ .name = "vsourcesin", .terminals = two, .draw = draw_vsourceac, .prefix = 'V' }, // 45
    .{ .name = "cvsource", .terminals = two, .draw = draw_cvsource, .prefix = 'E' }, // 46
    .{ .name = "cisource", .terminals = two, .draw = draw_cisource, .prefix = 'G' }, // 47
    .{ .name = "ammeter", .terminals = two, .draw = draw_ammeter, .prefix = 'X' }, // 48
    .{ .name = "voltmeter", .terminals = two, .draw = draw_voltmeter, .prefix = 'X' }, // 49
    .{ .name = "ohmmeter", .terminals = two, .draw = draw_ohmmeter, .prefix = 'X' }, // 50
    .{ .name = "switch", .terminals = two, .draw = draw_switch, .prefix = 'S' }, // 51
    .{ .name = "noswitch", .terminals = two, .draw = draw_switch, .prefix = 'S' }, // 52
    .{ .name = "ncswitch", .terminals = two, .draw = draw_ncswitch, .prefix = 'S' }, // 53
    .{ .name = "pushbutton", .terminals = two, .draw = draw_pushbutton, .prefix = 'S' }, // 54
    .{ .name = "spdt", .terminals = spdt_t, .draw = draw_spdt, .prefix = 'S' }, // 55
    .{ .name = "opamp", .terminals = opamp_t, .draw = draw_opamp, .prefix = 'X' }, // 56
    .{ .name = "fdopamp", .terminals = fdopamp_t, .draw = draw_opamp, .prefix = 'X' }, // 57
    .{ .name = "transconductor", .terminals = opamp_t, .draw = draw_opamp, .prefix = 'X' }, // 58
    .{ .name = "andgate", .terminals = gate2, .draw = draw_and, .prefix = 'X' }, // 59
    .{ .name = "orgate", .terminals = gate2, .draw = draw_or, .prefix = 'X' }, // 60
    .{ .name = "notgate", .terminals = gate1, .draw = draw_not, .prefix = 'X' }, // 61
    .{ .name = "nandgate", .terminals = gate2, .draw = draw_nand, .prefix = 'X' }, // 62
    .{ .name = "norgate", .terminals = gate2, .draw = draw_nor, .prefix = 'X' }, // 63
    .{ .name = "xorgate", .terminals = gate2, .draw = draw_xor, .prefix = 'X' }, // 64
    .{ .name = "xnorgate", .terminals = gate2, .draw = draw_xnor, .prefix = 'X' }, // 65
    .{ .name = "buffergate", .terminals = gate1, .draw = draw_buffer, .prefix = 'X' }, // 66
    .{ .name = "antenna", .terminals = one, .draw = draw_antenna, .prefix = 'X' }, // 67
    .{ .name = "loudspeaker", .terminals = two, .draw = draw_loudspeaker, .prefix = 'X' }, // 68
    .{ .name = "microphone", .terminals = two, .draw = draw_microphone, .prefix = 'X' }, // 69
    .{ .name = "motor", .terminals = two, .draw = draw_motor, .prefix = 'X' }, // 70
    .{ .name = "buzzer", .terminals = two, .draw = draw_buzzer, .prefix = 'X' }, // 71
    .{ .name = "transformer", .terminals = xfmr_t, .draw = draw_xfmr, .prefix = 'X' }, // 72
    .{ .name = "vdd", .role = .power_rail, .terminals = rail, .draw = draw_vdd, .prefix = ' ' }, // 73
    .{ .name = "vcc", .role = .power_rail, .terminals = rail, .draw = draw_vdd, .prefix = ' ' }, // 74
    .{ .name = "gnd", .role = .ground_rail, .terminals = rail, .draw = draw_ground, .prefix = ' ' }, // 75
    .{ .name = "ground", .role = .ground_rail, .terminals = rail, .draw = draw_ground, .prefix = ' ' }, // 76
    .{ .name = "vss", .role = .ground_rail, .terminals = rail, .draw = draw_ground, .prefix = ' ' }, // 77
    .{ .name = "vee", .role = .ground_rail, .terminals = rail, .draw = draw_ground, .prefix = ' ' }, // 78
    .{ .name = "ipin", .role = .input_port, .terminals = rail, .draw = draw_port, .prefix = ' ' }, // 79
    .{ .name = "opin", .role = .output_port, .terminals = rail, .draw = draw_port, .prefix = ' ' }, // 80
    .{ .name = "iopin", .role = .bidir_port, .terminals = rail, .draw = draw_port, .prefix = ' ' }, // 81
    .{ .name = "dff", .terminals = dff_t, .draw = draw_dff, .prefix = 'X' }, // 82
    .{ .name = "jkff", .terminals = jkff_t, .draw = draw_jkff, .prefix = 'X' }, // 83
    .{ .name = "srff", .terminals = srff_t, .draw = draw_srff, .prefix = 'X' }, // 84
    .{ .name = "dlatch", .terminals = dlatch_t, .draw = draw_dlatch, .prefix = 'X' }, // 85
    .{ .name = "mux", .terminals = mux_t, .draw = draw_mux, .prefix = 'X' }, // 86
    .{ .name = "demux", .terminals = demux_t, .draw = draw_demux, .prefix = 'X' }, // 87
    .{ .name = "tristate", .terminals = tristate_t, .draw = draw_tristate, .prefix = 'X' }, // 88
    .{ .name = "adc", .terminals = adc_t, .draw = draw_adc, .prefix = 'X' }, // 89
    .{ .name = "dac", .terminals = dac_t, .draw = draw_dac, .prefix = 'X' }, // 90
    .{ .name = "comparator", .terminals = comparator_t, .draw = draw_comparator, .prefix = 'X' }, // 91
    .{ .name = "schmitt", .terminals = gate1, .draw = draw_schmitt, .prefix = 'X' }, // 92
    .{ .name = "mixer", .terminals = mixer_t, .draw = draw_mixer, .prefix = 'X' }, // 93
    .{ .name = "tline", .terminals = tline_t, .draw = draw_tline, .prefix = 'T' }, // 94
    .{ .name = "mesfet", .terminals = mos, .draw = draw_mesfet, .prefix = 'Z' }, // 95
};

/// How many builtin classes exist. `SymbolIdx` values at or above this index a
/// `host.Table`; see `host.zig`.
pub const builtin_count: u32 = classes.len;

/// Comptime perfect hash: class name -> index into `classes`.
///
/// Derived from `classes`, so the two cannot drift. No runtime hashing of the stored keys,
/// no buckets, no allocation — the lookup is a length bucket plus a handful of `memcmp`s
/// against static data, and it evaluates at comptime when the key is comptime-known.
const by_name = std.StaticStringMap(u32).initComptime(kvs: {
    var out: [classes.len]struct { []const u8, u32 } = undefined;
    for (classes, 0..) |c, i| out[i] = .{ c.name, @intCast(i) };
    break :kvs out;
});

/// Index of the builtin class named `name`, or null when there is none.
///
/// **Does not fold case.** Every catalog name is lowercase and SPICE identifiers are folded
/// once at intern time (`strings.Interner.internFold`), so folding again here would be a
/// second place for the rule to live. A caller holding an unfolded string folds it first.
///
/// Consults builtins only — a host class is found through `host.Table.indexOf`, which
/// checks this first. Evaluates at comptime for a comptime `name`. Allocation-free, O(len).
pub fn indexOf(name: []const u8) ?SymbolIdx {
    if (by_name.get(name)) |i| return @enumFromInt(i);
    return null;
}

/// True when `name` is a builtin class. Host classes may not shadow one.
///
/// Same case rule as `indexOf`.
pub fn isBuiltin(name: []const u8) bool {
    return by_name.get(name) != null;
}

/// The builtin class at `idx`.
///
/// Borrowed from static memory; valid for the life of the program and never freed. Asserts
/// `idx < builtin_count` — a `SymbolIdx` at or above that belongs to a `host.Table` and
/// reaching here with one is a programming error, not a data condition. Use
/// `host.Table.at` when the index may be either.
pub fn at(idx: SymbolIdx) *const DeviceClass {
    std.debug.assert(idx.i() < builtin_count);
    return &classes[idx.i()];
}

/// Box-body geometry: the one rule for turning a terminal set into a labelled rectangle.
///
/// Flip-flops, latches, mux/demux, converters, comparators and every host class that ships
/// no glyph are the same picture — a rectangle with its pins named — so none of them get
/// hand-drawn geometry. This namespace is the single definition, used by the generator at
/// comptime (baking `draw_dff` and its 12 siblings) and by `host.Table.register` at run
/// time. One rule means an editor's own symbol and a builtin flip-flop are drawn
/// identically; two rules would mean a bug report nobody can reproduce.
///
/// Every function here is pure and works at comptime.
pub const box = struct {
    /// Lead length from a hull-edge pin to the box outline.
    pub const pin_len: i32 = 8;
    /// Clearance between the outermost pin row and the box edge.
    pub const pad: i32 = 4;
    /// Height of the strip reserved at the top for the title, so a title can never collide
    /// with a pin label no matter where the pins sit.
    pub const title_h: i32 = 8;
    pub const title_size: u8 = 6;
    pub const pin_size: u8 = 4;
    /// Inset from the box edge to the near edge of a pin label.
    pub const label_inset: i32 = 2;

    /// Axis-aligned hull of the terminal anchors.
    ///
    /// Asserts `ts` is non-empty — a class with no terminals is rejected long before here.
    pub fn hull(ts: []const Terminal) Rect {
        std.debug.assert(ts.len > 0);
        var r: Rect = .{ .min = ts[0].at, .max = ts[0].at };
        for (ts[1..]) |t| {
            r.min.x = @min(r.min.x, t.at.x);
            r.min.y = @min(r.min.y, t.at.y);
            r.max.x = @max(r.max.x, t.at.x);
            r.max.y = @max(r.max.y, t.at.y);
        }
        return r;
    }

    /// The outline rectangle for a terminal set.
    ///
    /// Inset by `pin_len` in x so side leads stay visible, grown by `pad` below and by
    /// `pad + title_h` above to reserve the title strip. A degenerate hull (every pin in one
    /// column, so the inset would invert the box) is *grown* by `pin_len` instead, which is
    /// what keeps a two-pin vertical set from producing a zero-width rectangle.
    ///
    /// A pin whose x falls strictly inside the box enters vertically, so the y growth is
    /// pulled back to leave that pin and its lead outside the outline — otherwise the
    /// padding would swallow a top or bottom pin into the body.
    ///
    /// Works at comptime. Allocation-free, O(terminals).
    pub fn rect(ts: []const Terminal) Rect {
        const h = hull(ts);
        // A degenerate hull (all pins in one column) grows instead of insetting, so it still
        // gets a real box rather than an inverted one.
        const l, const r = if (h.max.x - h.min.x > 2 * pin_len)
            .{ h.min.x + pin_len, h.max.x - pin_len }
        else
            .{ h.min.x - pin_len, h.max.x + pin_len };

        var t = h.min.y - pad - title_h;
        var b = h.max.y + pad;
        const mid = @divTrunc(h.min.y + h.max.y, 2);
        for (ts) |term| {
            const p = term.at;
            if (p.x > l and p.x < r) {
                if (p.y <= mid) {
                    t = @max(t, p.y + pin_len);
                } else {
                    b = @min(b, p.y - pin_len);
                }
            }
        }
        return .{ .min = .{ .x = l, .y = t }, .max = .{ .x = r, .y = b } };
    }

    /// Closed rectangle path for a `.polyline` op: five points, first repeated last.
    pub fn outline(b: Rect) [5]Pt {
        return .{
            .{ .x = b.min.x, .y = b.min.y },
            .{ .x = b.max.x, .y = b.min.y },
            .{ .x = b.max.x, .y = b.max.y },
            .{ .x = b.min.x, .y = b.max.y },
            .{ .x = b.min.x, .y = b.min.y },
        };
    }

    /// Centre of the reserved title strip, for the title `.text` op.
    pub fn titleAt(b: Rect) Pt {
        return .{ .x = @divTrunc(b.min.x + b.max.x, 2), .y = b.min.y + @divTrunc(title_h, 2) };
    }

    /// Lead from a pin to the nearest box edge.
    ///
    /// Pins left of or on `b.min.x` (respectively right of `b.max.x`) get a horizontal
    /// lead; anything else is a top or bottom pin and gets a vertical one. The order of
    /// those tests is the tie-break for a pin sitting exactly on a corner: horizontal wins.
    pub fn lead(b: Rect, p: Pt) DrawOp {
        if (p.x <= b.min.x) return DrawOp.ln(p.x, p.y, b.min.x, p.y);
        if (p.x >= b.max.x) return DrawOp.ln(p.x, p.y, b.max.x, p.y);
        if (p.y <= b.min.y) return DrawOp.ln(p.x, p.y, p.x, b.min.y);
        return DrawOp.ln(p.x, p.y, p.x, b.max.y);
    }

    /// Centre point for a pin's label, tucked just inside the edge its lead enters.
    ///
    /// Side labels are inset by `label_inset` plus half the forced text width, so the glyph
    /// box lands inside the outline rather than straddling it. A top pin's label clears the
    /// whole title strip instead of merely the edge, which is what makes titles and pin
    /// names non-overlapping for every terminal set rather than for the ones that happened
    /// to be tested.
    ///
    /// Uses `textWidth`, so it agrees exactly with what a renderer draws.
    pub fn labelAt(b: Rect, p: Pt, name: []const u8) Pt {
        const half = @divTrunc(textWidth(name, pin_size), 2);
        if (p.x <= b.min.x) return .{ .x = b.min.x + label_inset + half, .y = p.y };
        if (p.x >= b.max.x) return .{ .x = b.max.x - label_inset - half, .y = p.y };
        // A top pin clears the whole title strip, not merely the edge.
        if (p.y <= b.min.y) return .{ .x = p.x, .y = b.min.y + title_h + pin_size };
        return .{ .x = p.x, .y = b.max.y - label_inset - pin_size };
    }

    /// Number of ops `body` produces: outline, title, then a lead and a label per terminal.
    pub fn bodyLen(terminal_count: usize) usize {
        return 2 + 2 * terminal_count;
    }

    /// Generate the full body for `ts` titled `title`.
    ///
    /// Caller owns the returned slice and must free it with `gpa`; `host.Table.register`
    /// allocates it from the table's arena so it is released with the table. The polyline
    /// point array is allocated too, and the returned `.text` ops **borrow** `title` and
    /// each terminal's `name` — those must outlive the ops, which is why `register` copies
    /// them into its arena before calling.
    ///
    /// Exactly `bodyLen(ts.len)` ops, in that order, so a caller can size a buffer up
    /// front. Errors: `OutOfMemory`.
    pub fn body(
        gpa: std.mem.Allocator,
        ts: []const Terminal,
        title: []const u8,
    ) std.mem.Allocator.Error![]DrawOp {
        const b = rect(ts);

        const pts = try gpa.create([5]Pt);
        errdefer gpa.destroy(pts);
        pts.* = outline(b);

        const ops = try gpa.alloc(DrawOp, bodyLen(ts.len));
        ops[0] = .{ .polyline = pts };
        ops[1] = .{ .text = .{ .at = titleAt(b), .s = title, .size = title_size } };
        for (ts, 0..) |t, i| {
            ops[2 + 2 * i] = lead(b, t.at);
            ops[3 + 2 * i] = .{
                .text = .{ .at = labelAt(b, t.at, t.name), .s = t.name, .size = pin_size },
            };
        }
        return ops;
    }
};

/// Comptime twin of `box.body`: the same outline, title, leads and labels, laid out in the
/// order the Rust `boxdev!` macro baked them (all leads, then all labels) so a converted
/// builtin body is byte-identical to the table it came from.
///
/// Comptime-only — the result lives in `.rodata`, allocates nothing, and is what the box
/// classes below use in place of a hand-retyped coordinate list.
fn boxBody(comptime ts: []const Terminal, comptime title: []const u8) []const DrawOp {
    comptime {
        const b = box.rect(ts);
        const pts: [5]Pt = box.outline(b);
        var ops: [box.bodyLen(ts.len)]DrawOp = undefined;
        ops[0] = .{ .polyline = &pts };
        ops[1] = .{ .text = .{ .at = box.titleAt(b), .s = title, .size = box.title_size } };
        for (ts, 0..) |t, i| {
            ops[2 + i] = box.lead(b, t.at);
            ops[2 + ts.len + i] = .{
                .text = .{ .at = box.labelAt(b, t.at, t.name), .s = t.name, .size = box.pin_size },
            };
        }
        const frozen = ops;
        return &frozen;
    }
}

test "the builtin table and its name index cannot disagree" {
    // Cheap in-source invariant on the derived map; behavior lives in tests/devices.zig.
    try std.testing.expectEqual(@as(usize, classes.len), by_name.keys().len);
    try std.testing.expectEqual(@as(u32, classes.len), builtin_count);
}
