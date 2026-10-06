//! Device classes: what each device looks like, supplied by the application.
//!
//! The library ships no symbols. A target (an SVG renderer, a TikZ figure, an
//! xschem exporter) registers one class per device kind it draws — terminal
//! anchor points and body strokes — and the layout reads pin sides and pin
//! reach from those anchors. Nothing about a symbol's size or shape is assumed
//! anywhere else.
//!
//! ## The canonical frame
//!
//! Integer coordinates, origin at the device centre, y down. The principal
//! terminals sit on the x axis (a two-pin symbol at x = -20 and x = +20: one
//! `unit`, pin end to pin end); an auxiliary terminal (a gate, a base) sits off
//! it. A pin faces the side its anchor lies on — the larger of |x| and |y|
//! decides. The layout's horizontal form of a device is this frame as drawn;
//! its vertical form is the frame turned a quarter to the left (`Orient.left`),
//! which puts a MOSFET's drain up, its gate left and its source down.
//!
//! ## Append-only
//!
//! A `ClassId` never changes meaning: registration appends, a same-name
//! registration with the same terminals returns the existing id, and one with
//! different terminals is refused. Placed schematics hold ids, so an id that
//! moved would silently redraw old output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const netlist = @import("netlist.zig");

pub const DeviceKind = netlist.DeviceKind;

// ===========================================================================
// Integer geometry
// ===========================================================================

/// A point in the target's integer coordinates, y down.
pub const Pt = extern struct {
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
};

/// An axis-aligned rectangle, both corners inclusive; `min` is top-left.
pub const Rect = struct {
    min: Pt,
    max: Pt,

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.min.x <= b.max.x and b.min.x <= a.max.x and a.min.y <= b.max.y and b.min.y <= a.max.y;
    }
    pub fn contains(r: Rect, p: Pt) bool {
        return p.x >= r.min.x and p.x <= r.max.x and p.y >= r.min.y and p.y <= r.max.y;
    }
    pub fn merge(a: Rect, b: Rect) Rect {
        return .{
            .min = .{ .x = @min(a.min.x, b.min.x), .y = @min(a.min.y, b.min.y) },
            .max = .{ .x = @max(a.max.x, b.max.x), .y = @max(a.max.y, b.max.y) },
        };
    }
    pub fn point(p: Pt) Rect {
        return .{ .min = p, .max = p };
    }
    pub fn fromCorners(a: Pt, b: Pt) Rect {
        return .{ .min = .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) }, .max = .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) } };
    }
    pub fn translate(r: Rect, by: Pt) Rect {
        return .{ .min = r.min.add(by), .max = r.max.add(by) };
    }
};

/// Symbol placement: a mirror about the vertical axis, then quarter turns
/// clockwise. `apply` is the one place that order is written; every consumer
/// goes through it (the same convention as cktImg).
pub const Orient = packed struct(u8) {
    rot: u2 = 0,
    mirror: bool = false,
    _pad: u5 = 0,

    pub const r0: Orient = .{};
    /// The layout's vertical form: the canonical frame a quarter turn left.
    pub const left: Orient = .{ .rot = 3 };

    pub fn apply(o: Orient, p: Pt) Pt {
        const m: Pt = if (o.mirror) .{ .x = -p.x, .y = p.y } else p;
        return switch (o.rot) {
            0 => m,
            1 => .{ .x = -m.y, .y = m.x },
            2 => .{ .x = -m.x, .y = -m.y },
            3 => .{ .x = m.y, .y = -m.x },
        };
    }

    pub fn applyRect(o: Orient, r: Rect) Rect {
        return Rect.fromCorners(o.apply(r.min), o.apply(r.max));
    }

    /// The orientation that draws `base` and then negates x (`flip_x`) and y
    /// (`flip_y`) of the result — the layout's flips, as mirror-and-rotate.
    pub fn flipped(base: Orient, flip_x: bool, flip_y: bool) Orient {
        const want = struct {
            fn f(b: Orient, fx: bool, fy: bool, p: Pt) Pt {
                const q = b.apply(p);
                return .{ .x = if (fx) -q.x else q.x, .y = if (fy) -q.y else q.y };
            }
        }.f;
        const probes = [_]Pt{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
        for (0..8) |k| {
            const o: Orient = .{ .rot = @intCast(k & 3), .mirror = k >= 4 };
            for (probes) |p| {
                if (!o.apply(p).eql(want(base, flip_x, flip_y, p))) break;
            } else return o;
        }
        unreachable; // the eight orientations are closed under both flips
    }
};

pub const Side = enum(u2) {
    left,
    right,
    up,
    down,

    pub fn opposite(s: Side) Side {
        return switch (s) {
            .left => .right,
            .right => .left,
            .up => .down,
            .down => .up,
        };
    }
    pub fn isHorizontal(s: Side) bool {
        return s == .left or s == .right;
    }
    pub fn perpendicular(a: Side, b: Side) bool {
        return a.isHorizontal() != b.isHorizontal();
    }
    pub fn flipX(s: Side) Side {
        return if (s.isHorizontal()) s.opposite() else s;
    }
    pub fn flipY(s: Side) Side {
        return if (s.isHorizontal()) s else s.opposite();
    }
    /// Unit vector; y grows downward.
    pub fn vec(s: Side) [2]f32 {
        return switch (s) {
            .left => .{ -1, 0 },
            .right => .{ 1, 0 },
            .up => .{ 0, -1 },
            .down => .{ 0, 1 },
        };
    }
    /// The side a point lies on, seen from the origin; null at the origin.
    pub fn of(p: Pt) ?Side {
        if (p.x == 0 and p.y == 0) return null;
        if (@abs(p.x) >= @abs(p.y)) return if (p.x < 0) .left else .right;
        return if (p.y < 0) .up else .down;
    }
};

// ===========================================================================
// Classes
// ===========================================================================

/// What a class is placed as. Rails and ports are the terminal symbols the
/// layout adds for supply, ground, input and output nets.
pub const Role = enum(u8) {
    none = 0,
    power_rail,
    ground_rail,
    input_port,
    output_port,
};

pub const Terminal = struct {
    /// Pin name (`"d"`, `"in+"`). Terminals are in SPICE node order.
    name: []const u8,
    /// Anchor in the canonical frame.
    at: Pt,
    /// Counts for paths but gets no wire (a MOS bulk drawn on the symbol).
    hidden: bool = false,
    /// Gets no wire when its net is ground (an op-amp's reference).
    ground_ref: bool = false,
};

/// One stroke of a symbol body, in the canonical frame.
pub const DrawOp = union(enum) {
    line: struct { a: Pt, b: Pt },
    /// Open; a closed shape repeats its first point.
    polyline: []const Pt,
    circle: struct { c: Pt, r: i32 },
    /// Upright text centred on `at`: orientation moves it, never turns it.
    text: struct { at: Pt, s: []const u8, size: u8 },

    pub fn ln(x1: i32, y1: i32, x2: i32, y2: i32) DrawOp {
        return .{ .line = .{ .a = .{ .x = x1, .y = y1 }, .b = .{ .x = x2, .y = y2 } } };
    }
    pub fn circ(x: i32, y: i32, r: i32) DrawOp {
        return .{ .circle = .{ .c = .{ .x = x, .y = y }, .r = r } };
    }
};

pub const Class = struct {
    name: []const u8,
    role: Role = .none,
    terminals: []const Terminal,
    draw: []const DrawOp,

    /// The side terminal `i` faces under `o`, or null if it is not drawn.
    pub fn side(c: Class, i: usize, o: Orient) ?Side {
        if (i >= c.terminals.len or c.terminals[i].hidden) return null;
        return Side.of(o.apply(c.terminals[i].at));
    }

    /// Bounding box of terminals and strokes, in the canonical frame.
    pub fn bbox(c: Class) Rect {
        var r: ?Rect = null;
        const grow = struct {
            fn f(acc: *?Rect, p: Pt) void {
                acc.* = if (acc.*) |a| a.merge(.point(p)) else .point(p);
            }
        }.f;
        for (c.terminals) |t| grow(&r, t.at);
        for (c.draw) |op| switch (op) {
            .line => |l| {
                grow(&r, l.a);
                grow(&r, l.b);
            },
            .polyline => |ps| for (ps) |p| grow(&r, p),
            .circle => |k| {
                grow(&r, .{ .x = k.c.x - k.r, .y = k.c.y - k.r });
                grow(&r, .{ .x = k.c.x + k.r, .y = k.c.y + k.r });
            },
            .text => |t| grow(&r, t.at),
        };
        return r orelse .point(.zero);
    }
};

pub const ClassId = enum(u32) {
    _,
    pub fn i(c: ClassId) usize {
        return @intFromEnum(c);
    }
};

/// What a caller supplies to register a class. Every slice is copied, so a
/// spec may live on the stack.
pub const Spec = struct {
    name: []const u8,
    role: Role = .none,
    terminals: []const Terminal,
    /// Empty: a labelled box is generated around the terminals.
    draw: []const DrawOp = &.{},
};

pub const RegisterError = error{
    /// A class needs at least one terminal.
    NoTerminals,
    /// Two terminals share an anchor: two nets on one point.
    CollidingTerminals,
    /// The name is registered already, with other terminals. Register the
    /// revision under a new name.
    GeometryChanged,
    OutOfMemory,
};

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    classes: std.ArrayList(Class) = .empty,
    /// One two-pin symbol, pin end to pin end, in the target's coordinates:
    /// the length `Config.layout` measures wires in.
    unit: i32 = 40,

    pub fn init(gpa: Allocator) Library {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Library) void {
        self.classes.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Library) usize {
        return self.classes.items.len;
    }

    /// Adds a class, or returns the id of an identical one. The name is folded
    /// to lowercase. On error the library is unchanged.
    pub fn register(self: *Library, spec: Spec) RegisterError!ClassId {
        if (spec.terminals.len == 0) return error.NoTerminals;
        for (spec.terminals, 0..) |a, i| for (spec.terminals[i + 1 ..]) |b| {
            if (a.at.eql(b.at)) return error.CollidingTerminals;
        };
        for (self.classes.items, 0..) |c, i| {
            if (!std.ascii.eqlIgnoreCase(c.name, spec.name)) continue;
            if (!sameTerminals(c.terminals, spec.terminals) or c.role != spec.role) return error.GeometryChanged;
            return @enumFromInt(i);
        }
        try self.classes.ensureUnusedCapacity(self.arena.child_allocator, 1);
        const a = self.arena.allocator();
        const name = try a.allocSentinel(u8, spec.name.len, 0);
        for (spec.name, name) |s, *d| d.* = std.ascii.toLower(s);
        const terms = try a.alloc(Terminal, spec.terminals.len);
        for (spec.terminals, terms) |s, *d| d.* = .{ .name = try a.dupeSentinel(u8, s.name, 0), .at = s.at, .hidden = s.hidden, .ground_ref = s.ground_ref };
        const draw = if (spec.draw.len > 0) try copyOps(a, spec.draw) else try box(a, terms, name);
        self.classes.appendAssumeCapacity(.{ .name = name, .role = spec.role, .terminals = terms, .draw = draw });
        return @enumFromInt(self.classes.items.len - 1);
    }

    pub fn at(self: *const Library, id: ClassId) Class {
        return self.classes.items[id.i()];
    }

    /// Case-insensitive.
    pub fn find(self: *const Library, name: []const u8) ?ClassId {
        for (self.classes.items, 0..) |c, i| if (std.ascii.eqlIgnoreCase(c.name, name)) return @enumFromInt(i);
        return null;
    }

    /// The first class registered with `role`.
    pub fn findRole(self: *const Library, role: Role) ?ClassId {
        for (self.classes.items, 0..) |c, i| if (c.role == role) return @enumFromInt(i);
        return null;
    }

    /// The class a device is drawn as: its vocabulary name if registered,
    /// else a generated box (`generic<n>`), registered on first use.
    pub fn classFor(self: *Library, kind: DeviceKind, model_type: ?[]const u8, pins: usize) RegisterError!ClassId {
        if (self.find(className(kind, model_type))) |id| return id;
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "generic{d}", .{pins}) catch unreachable;
        if (self.find(name)) |id| return id;
        var terms: [netlist_max_pins]Terminal = undefined;
        var names: [netlist_max_pins][2]u8 = undefined;
        const n = @min(pins, netlist_max_pins);
        for (0..n) |k| {
            names[k] = .{ 'p', '0' + @as(u8, @intCast(k)) };
            // Alternate left and right, down the box.
            const row: i32 = @intCast(k / 2);
            terms[k] = .{ .name = &names[k], .at = .{ .x = if (k % 2 == 0) -20 else 20, .y = row * 20 } };
        }
        return self.register(.{ .name = name, .terminals = terms[0..n] });
    }

    /// The class a subcircuit block is drawn as: one registered under the
    /// subcircuit's name if the caller has one (a real op-amp symbol), else a
    /// generated block, registered on first use as `block:<name>`.
    ///
    /// The generated block puts each port on its side — the definition's
    /// `*@ left/right/top/bottom` directives, else by name: supplies on top,
    /// grounds at the bottom, `out…` on the right, the rest on the left — and
    /// spaces them one unit apart exactly where the layout will put the copies
    /// it splits a crowded side into, so no wire needs a lead.
    pub fn blockFor(self: *Library, def: *const netlist.Subckt) RegisterError!ClassId {
        if (self.find(def.name)) |id| return id;
        var name_buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "block:{s}", .{def.name}) catch def.name;
        if (self.find(name)) |id| return id;

        var arena: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const n = def.ports.len;
        if (n == 0) return error.NoTerminals;
        // Ports per side, in directive order.
        var per: [4]std.ArrayList(usize) = @splat(.empty);
        const order = try a.alloc(usize, n);
        for (order, 0..) |*o, k| o.* = k;
        std.mem.sort(usize, order, def, struct {
            fn lt(d: *const netlist.Subckt, x: usize, y: usize) bool {
                return d.order[x] < d.order[y];
            }
        }.lt);
        for (order) |k| try per[@intFromEnum(def.sides[k] orelse defaultSide(def.ports[k]))].append(a, k);
        const u = self.unit;
        const m_lr = @max(per[0].items.len, per[1].items.len) | 1;
        const m_tb = @max(per[2].items.len, per[3].items.len) | 1;
        const hh: i32 = @as(i32, @intCast(m_lr - 1)) * @divTrunc(u, 2) + @divTrunc(u, 2);
        const hw: i32 = @max(@as(i32, @intCast(m_tb - 1)) * @divTrunc(u, 2) + @divTrunc(u, 2), @divTrunc(3 * u, 4));
        const lead: i32 = @divTrunc(u, 4);
        const terms = try a.alloc(Terminal, n);
        var ops: std.ArrayList(DrawOp) = .empty;
        try ops.append(a, .{ .polyline = try a.dupe(Pt, &.{ .{ .x = -hw, .y = -hh }, .{ .x = hw, .y = -hh }, .{ .x = hw, .y = hh }, .{ .x = -hw, .y = hh }, .{ .x = -hw, .y = -hh } }) });
        for (per, 0..) |list, si| {
            const side: netlist.PortSide = @enumFromInt(si);
            const m = if (si < 2) m_lr else m_tb;
            for (list.items, 0..) |k, j| {
                const along: i32 = (@as(i32, @intCast(centeredSlot(m, list.items.len, j))) - @as(i32, @intCast(m / 2))) * u;
                const pin: Pt, const edge: Pt, const label: Pt = switch (side) {
                    .left => .{ .{ .x = -hw - lead, .y = along }, .{ .x = -hw, .y = along }, .{ .x = -hw + 6 + 3 * @as(i32, @intCast(def.ports[k].len)), .y = along } },
                    .right => .{ .{ .x = hw + lead, .y = along }, .{ .x = hw, .y = along }, .{ .x = hw - 6 - 3 * @as(i32, @intCast(def.ports[k].len)), .y = along } },
                    .top => .{ .{ .x = along, .y = -hh - lead }, .{ .x = along, .y = -hh }, .{ .x = along, .y = -hh + 7 } },
                    .bottom => .{ .{ .x = along, .y = hh + lead }, .{ .x = along, .y = hh }, .{ .x = along, .y = hh - 7 } },
                };
                terms[k] = .{ .name = def.ports[k], .at = pin };
                try ops.append(a, .{ .line = .{ .a = pin, .b = edge } });
                try ops.append(a, .{ .text = .{ .at = label, .s = def.ports[k], .size = 5 } });
            }
        }
        try ops.append(a, .{ .text = .{ .at = .zero, .s = def.name, .size = 7 } });
        return self.register(.{ .name = name, .terminals = terms, .draw = ops.items });
    }

    /// True for a box `classFor` generated.
    pub fn isGeneric(self: *const Library, id: ClassId) bool {
        return std.mem.startsWith(u8, self.at(id).name, "generic");
    }

    /// Registers every class of a symbol file (see `tests/symbols.zon`):
    ///
    /// ```zon
    /// .{ .unit = 40, .classes = .{ .{ .name = "res", .terminals = .{ … }, .draw = .{ … } } } }
    /// ```
    ///
    /// `arena` backs the parse. A class that fails to register is reported in
    /// `diags` (by name) and skipped; a document that does not parse is one
    /// diagnostic and registers nothing.
    pub fn loadZon(self: *Library, arena: Allocator, text: []const u8, diags: ?*std.ArrayList(ZonDiagnostic)) Allocator.Error!void {
        const File = struct {
            unit: i32 = 40,
            classes: []const Spec = &.{},
        };
        const src = try arena.dupeSentinel(u8, text, 0);
        var zd: std.zon.parse.Diagnostics = undefined;
        const file = std.zon.parse.fromSlice(File, .{ .gpa = arena, .arena = arena, .source = src, .diagnostics = &zd }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => {
                if (diags) |d| try d.append(arena, .{ .class = "<document>", .err = error.ParseZon });
                return;
            },
        };
        self.unit = file.unit;
        for (file.classes) |spec| {
            _ = self.register(spec) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |e| if (diags) |d| try d.append(arena, .{ .class = spec.name, .err = e }),
            };
        }
    }
};

pub const ZonDiagnostic = struct { class: []const u8, err: anyerror };

const netlist_max_pins = 7;

/// A port's side when no directive names one.
fn defaultSide(port: []const u8) netlist.PortSide {
    const starts = struct {
        fn f(s: []const u8, xs: []const []const u8) bool {
            for (xs) |x| if (std.mem.startsWith(u8, s, x)) return true;
            return false;
        }
    }.f;
    if (starts(port, &.{ "vdd", "vcc", "avdd", "dvdd", "vpp" })) return .top;
    if (starts(port, &.{ "gnd", "vss", "vee", "agnd", "dgnd" }) or std.mem.eql(u8, port, "0")) return .bottom;
    if (starts(port, &.{ "out", "vout" }) or std.mem.eql(u8, port, "o")) return .right;
    return .left;
}

/// Slot k of `count` pins across `m` rows: centred, skipping the middle row
/// when `count` is even — where the layout's copies put them (S3).
fn centeredSlot(m: usize, count: usize, k: usize) usize {
    const mid = m / 2;
    const first = mid - count / 2;
    const pos = first + k;
    return if (count % 2 == 0 and pos >= mid) pos + 1 else pos;
}

/// The class name a device is looked up by: cktImg's vocabulary.
pub fn className(kind: DeviceKind, model_type: ?[]const u8) []const u8 {
    const m = model_type orelse "";
    const p = m.len > 0 and m[0] == 'p';
    return switch (kind) {
        .resistor => "res",
        .capacitor => "cap",
        .inductor => "ind",
        .vsource => "vsource",
        .isource => "isource",
        .vcvs => "cvsource",
        .ccvs => "ccvs",
        .vccs => "cisource",
        .cccs => "cccs",
        .behavioral => "bsource",
        .diode => "diode",
        .bjt => if (std.mem.eql(u8, m, "pnp")) "pnp" else "npn",
        .jfet => if (p) "pjfet" else "njfet",
        .mesfet => "mesfet",
        .mosfet => if (p or std.mem.indexOf(u8, m, "pfet") != null or std.mem.indexOf(u8, m, "pmos") != null) "pmos" else "nmos",
        .vswitch, .cswitch => "switch",
        .tline, .ltra => "tline",
        .urc => "urc",
        .coupling => "coupling",
        .subckt => "subckt", // by definition: see `Library.blockFor`
    };
}

fn sameTerminals(a: []const Terminal, b: []const Terminal) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.at.eql(y.at) or x.hidden != y.hidden or x.ground_ref != y.ground_ref or !std.ascii.eqlIgnoreCase(x.name, y.name)) return false;
    }
    return true;
}

fn copyOps(a: Allocator, ops: []const DrawOp) Allocator.Error![]DrawOp {
    const out = try a.alloc(DrawOp, ops.len);
    for (ops, out) |s, *d| d.* = switch (s) {
        .line, .circle => s,
        .polyline => |ps| .{ .polyline = try a.dupe(Pt, ps) },
        .text => |t| .{ .text = .{ .at = t.at, .s = try a.dupeSentinel(u8, t.s, 0), .size = t.size } },
    };
    return out;
}

/// A labelled box around the terminals: the body of a class registered with
/// no strokes, and of a device whose class nobody registered.
fn box(a: Allocator, terms: []const Terminal, name: []const u8) Allocator.Error![]DrawOp {
    var r: Rect = .point(terms[0].at);
    for (terms) |t| r = r.merge(.point(t.at));
    const pad: i32 = 10;
    const lo: Pt = .{ .x = @max(r.min.x + pad, -10), .y = r.min.y - pad };
    const hi: Pt = .{ .x = @min(r.max.x - pad, 10), .y = r.max.y + pad };
    var ops: std.ArrayList(DrawOp) = .empty;
    try ops.append(a, .{ .polyline = try a.dupe(Pt, &.{ lo, .{ .x = hi.x, .y = lo.y }, hi, .{ .x = lo.x, .y = hi.y }, lo }) });
    for (terms) |t| {
        // A lead from the anchor to the box edge.
        const edge: Pt = if (t.at.x < lo.x) .{ .x = lo.x, .y = t.at.y } else if (t.at.x > hi.x) .{ .x = hi.x, .y = t.at.y } else if (t.at.y < lo.y) .{ .x = t.at.x, .y = lo.y } else .{ .x = t.at.x, .y = hi.y };
        if (!edge.eql(t.at)) try ops.append(a, .{ .line = .{ .a = t.at, .b = edge } });
    }
    try ops.append(a, .{ .text = .{ .at = .{ .x = @divTrunc(lo.x + hi.x, 2), .y = @divTrunc(lo.y + hi.y, 2) }, .s = name, .size = 6 } });
    return ops.toOwnedSlice(a);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const two: []const Terminal = &.{ .{ .name = "a", .at = .{ .x = -20, .y = 0 } }, .{ .name = "b", .at = .{ .x = 20, .y = 0 } } };

test "library: register is append-only, idempotent on a repeat, refuses changed geometry" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    const r = try lib.register(.{ .name = "RES", .terminals = two });
    try testing.expectEqual(r, try lib.register(.{ .name = "res", .terminals = two }));
    try testing.expectEqual(1, lib.count());
    try testing.expectEqualStrings("res", lib.at(r).name);
    const moved: []const Terminal = &.{ .{ .name = "a", .at = .{ .x = -30, .y = 0 } }, .{ .name = "b", .at = .{ .x = 20, .y = 0 } } };
    try testing.expectError(error.GeometryChanged, lib.register(.{ .name = "res", .terminals = moved }));
    try testing.expectError(error.NoTerminals, lib.register(.{ .name = "x", .terminals = &.{} }));
    try testing.expectError(error.CollidingTerminals, lib.register(.{ .name = "y", .terminals = &.{ .{ .name = "a", .at = .zero }, .{ .name = "b", .at = .zero } } }));
    try testing.expectEqual(1, lib.count());
    try testing.expect(lib.at(r).draw.len > 0); // a generated box
}

test "library: an unregistered kind gets a generated box, once per pin count" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    const a = try lib.classFor(.mosfet, "nmos", 3);
    try testing.expect(lib.isGeneric(a));
    try testing.expectEqual(a, try lib.classFor(.bjt, "npn", 3));
    try testing.expectEqual(3, lib.at(a).terminals.len);
}

test "orient: mirror then rotate; the vertical form puts a MOSFET's drain up and gate left" {
    const d: Pt = .{ .x = 20, .y = 0 };
    const g: Pt = .{ .x = 0, .y = -20 };
    try testing.expectEqual(Side.up, Side.of(Orient.left.apply(d)).?);
    try testing.expectEqual(Side.left, Side.of(Orient.left.apply(g)).?);
    // Flips compose into one of the eight orientations.
    for ([_]Orient{ .r0, .left }) |base| for ([_]bool{ false, true }) |fx| for ([_]bool{ false, true }) |fy| {
        const o = Orient.flipped(base, fx, fy);
        const q = base.apply(g);
        try testing.expectEqual(Pt{ .x = if (fx) -q.x else q.x, .y = if (fy) -q.y else q.y }, o.apply(g));
    };
}

test "library: a symbol file registers its classes and reports the bad ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    var diags: std.ArrayList(ZonDiagnostic) = .empty;
    try lib.loadZon(arena.allocator(),
        \\.{ .unit = 40, .classes = .{
        \\    .{ .name = "res", .terminals = .{ .{ .name = "a", .at = .{ .x = -20, .y = 0 } }, .{ .name = "b", .at = .{ .x = 20, .y = 0 } } },
        \\       .draw = .{ .{ .line = .{ .a = .{ .x = -20, .y = 0 }, .b = .{ .x = 20, .y = 0 } } } } },
        \\    .{ .name = "vdd", .role = .power_rail, .terminals = .{ .{ .name = "p", .at = .{ .x = 0, .y = 0 } } } },
        \\    .{ .name = "bad", .terminals = .{} },
        \\} }
    , &diags);
    try testing.expectEqual(2, lib.count());
    try testing.expect(lib.findRole(.power_rail) != null);
    try testing.expectEqual(1, diags.items.len);
    try testing.expectEqualStrings("bad", diags.items[0].class);
}

test "library: a subcircuit block puts its ports where the layout's copies go" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    const def: netlist.Subckt = .{
        .name = "opamp",
        .ports = &.{ "inp", "inn", "out", "vdd", "vss" },
        .sides = &.{ null, null, null, null, null },
        .order = &.{ 1000, 1001, 1002, 1003, 1004 },
        .expand = false,
        .body = "",
    };
    const id = try lib.blockFor(&def);
    const c = lib.at(id);
    try testing.expectEqualStrings("block:opamp", c.name);
    // Two inputs left, one unit either side of the middle row; out right in it.
    try testing.expectEqual(Side.left, c.side(0, .r0).?);
    try testing.expectEqual(@as(i32, -40), c.terminals[0].at.y);
    try testing.expectEqual(@as(i32, 40), c.terminals[1].at.y);
    try testing.expectEqual(Side.right, c.side(2, .r0).?);
    try testing.expectEqual(@as(i32, 0), c.terminals[2].at.y);
    try testing.expectEqual(Side.up, c.side(3, .r0).?);
    try testing.expectEqual(Side.down, c.side(4, .r0).?);
    try testing.expectEqual(id, try lib.blockFor(&def));
    // A symbol the caller registered under the name wins.
    var lib2 = Library.init(testing.allocator);
    defer lib2.deinit();
    const mine = try lib2.register(.{ .name = "opamp", .terminals = two });
    try testing.expectEqual(mine, try lib2.blockFor(&def));
}

test "library: a PDK model name says which MOS it is" {
    try testing.expectEqualStrings("pmos", className(.mosfet, "sky130_fd_pr__pfet_01v8"));
    try testing.expectEqualStrings("nmos", className(.mosfet, "sky130_fd_pr__nfet_01v8"));
    try testing.expectEqualStrings("pmos", className(.mosfet, "pch"));
}
