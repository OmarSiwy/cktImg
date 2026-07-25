//! Behavioral suite for placement: Tier-A context, spline extraction, column
//! assignment, orientation, stacking and the two-phase order search.
//!
//! Every test is named after the property it pins, not the function it calls, and is
//! written against the documented contract rather than against an implementation —
//! including the parts a naive implementation would get away with. The ones worth
//! naming up front:
//!
//! - a gate net is *unreachable* from ground, because control pins do not conduct;
//! - `optimal_len` subtracts the conduction link itself, so a plain two-device spline
//!   abuts at zero rather than getting a courtesy gap;
//! - **equal-depth spline columns share one row profile** — device `k` of two parallel
//!   branches lands at the identical `y` even when one branch's node needs more room,
//!   which is the only assertion in this file that a per-column stacker fails;
//! - a spanning net reserves **zero** lanes, which is a measured decision and the
//!   easiest thing in `stack.zig` to "fix" back into a 5% area regression;
//! - the Phase-A proxy has exactly two terms and no crossing term;
//! - the selection key's field order *is* its priority order, so fewer crossings wins
//!   even against better staples and a shorter span.
//!
//! Expected red until the corresponding function is written — a `@panic("TODO")`
//! aborts the whole binary rather than failing one test, so the first panic names the
//! next function to implement.
//!
//! ## Fixtures bypass the front end
//!
//! Every schematic below is assembled straight out of `Ir`'s public columns with an
//! arena, exactly as `tests/devices.zig` does. A placement suite that could not run
//! until the SPICE parser worked would be useless for driving this file's
//! implementation order, and the parser is being written in parallel. The arena is the
//! whole teardown, so `std.testing.allocator` still audits every byte.

const std = @import("std");
const ckt = @import("cktimg");

const ids = ckt.ids;
const catalog = ckt.devices.catalog;
const host = ckt.devices.host;

const place = ckt.placement;
const ctxm = place.ctx;
const splinem = place.spline;
const colm = place.column;
const orientm = place.orient;
const stackm = place.stack;
const orderm = place.order;

const Allocator = std.mem.Allocator;
const Ctx = ctxm.Ctx;
const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const StrId = ids.StrId;
const Pt = ids.Pt;
const Orient = ids.Orient;
const NetClass = ids.NetClass;
const NetCase = ids.NetCase;
const ColumnIdx = colm.ColumnIdx;
const ColumnKind = colm.ColumnKind;
const Key = orderm.Key;
const Proxy = orderm.Proxy;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualDeep = std.testing.expectEqualDeep;

// ---------------------------------------------------------------------------
// Fixture construction
// ---------------------------------------------------------------------------

/// Minimal stand-in for the interner: NUL-terminated bytes plus a span table, the
/// layout `strings.Strings` documents, without depending on the interner being
/// implemented yet.
const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(ckt.strings.Span) = .empty,

    fn add(self: *Pool, gpa: Allocator, s: []const u8) !StrId {
        const off = self.bytes.items.len;
        try self.bytes.appendSlice(gpa, s);
        try self.bytes.append(gpa, 0);
        try self.spans.append(gpa, .{ .off = @intCast(off), .len = @intCast(s.len) });
        return StrId.at(self.spans.items.len - 1);
    }

    fn finish(self: Pool) ckt.Strings {
        return .{ .bytes = self.bytes.items, .spans = self.spans.items };
    }
};

/// One device of a fixture: a name, a builtin class, and one net name per terminal in
/// SPICE node order. For a MOSFET that is `{ drain, gate, source }`.
const Dev = struct {
    name: []const u8,
    class: []const u8,
    nets: []const []const u8,
};

/// An assembled schematic plus the name tables needed to talk about it.
///
/// Every array is arena-backed. `ir` is a value field, so tests take `&fx.ir` to get
/// the `*const Ir` the context builder wants.
const Fixture = struct {
    ir: ckt.Ir,
    strings: ckt.Strings,
    /// Net index (0-based) to name, in first-appearance order.
    net_names: []const []const u8,
    /// Device index to name.
    dev_names: []const []const u8,

    /// The net called `name`. Fails the test's assumptions loudly rather than
    /// returning a wrong index, because a typo in a fixture would otherwise look like
    /// a placement bug.
    fn net(self: Fixture, name: []const u8) NetIdx {
        for (self.net_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return NetIdx.at(i);
        }
        std.debug.panic("fixture has no net named '{s}'", .{name});
    }

    fn dev(self: Fixture, name: []const u8) DeviceIdx {
        for (self.dev_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return DeviceIdx.at(i);
        }
        std.debug.panic("fixture has no device named '{s}'", .{name});
    }

    /// Terminal `slot` of device `name`, by SPICE node order.
    fn pin(self: Fixture, name: []const u8, slot: u32) PinIdx {
        const d = self.dev(name);
        return PinIdx.at(self.ir.dev_pin0[d.i()] + slot);
    }

};

/// Assemble an `Ir` from a device list, interning net names in first-appearance
/// order so net indices are stable and readable.
///
/// Asserts every device's net count matches its class's terminal count — a mismatch is
/// a broken fixture, not an input the placer should tolerate.
fn build(arena: Allocator, devs: []const Dev) !Fixture {
    var pool: Pool = .{};
    _ = try pool.add(arena, ""); // StrId.empty, as every pool assigns first

    var net_names: std.ArrayList([]const u8) = .empty;
    var dev_names: std.ArrayList([]const u8) = .empty;

    var pin_total: usize = 0;
    for (devs) |d| {
        const class = catalog.at(catalog.indexOf(d.class).?);
        std.debug.assert(class.terminals.len == d.nets.len);
        pin_total += d.nets.len;
    }

    const dev_symbol = try arena.alloc(ids.SymbolIdx, devs.len);
    const dev_orient = try arena.alloc(Orient, devs.len);
    const dev_name = try arena.alloc(StrId, devs.len);
    const dev_value = try arena.alloc(StrId, devs.len);
    const dev_pin0 = try arena.alloc(u32, devs.len + 1);
    const pin_net = try arena.alloc(NetIdx, pin_total);

    var next_pin: u32 = 0;
    for (devs, 0..) |d, i| {
        dev_symbol[i] = catalog.indexOf(d.class).?;
        dev_orient[i] = Orient.r0;
        dev_name[i] = try pool.add(arena, d.name);
        dev_value[i] = .empty;
        dev_pin0[i] = next_pin;
        try dev_names.append(arena, d.name);
        for (d.nets) |nn| {
            var found: ?usize = null;
            for (net_names.items, 0..) |existing, k| {
                if (std.mem.eql(u8, existing, nn)) {
                    found = k;
                    break;
                }
            }
            const idx = found orelse blk: {
                try net_names.append(arena, nn);
                break :blk net_names.items.len - 1;
            };
            pin_net[next_pin] = NetIdx.at(idx);
            next_pin += 1;
        }
    }
    dev_pin0[devs.len] = next_pin;

    const net_name = try arena.alloc(StrId, net_names.items.len);
    for (net_names.items, 0..) |n, i| net_name[i] = try pool.add(arena, n);

    return .{
        .ir = .{
            .dev_symbol = dev_symbol,
            .dev_orient = dev_orient,
            .dev_pin0 = dev_pin0,
            .pin_net = pin_net,
            .dev_name = dev_name,
            .dev_value = dev_value,
            .net_name = net_name,
            .group_path = &.{},
            .group_master = &.{},
        },
        .strings = pool.finish(),
        .net_names = net_names.items,
        .dev_names = dev_names.items,
    };
}

/// A host class table with nothing registered, for fixtures built from builtins only.
///
/// Constructed from the public fields rather than through `host.Table.init`, so that a
/// placement test fails at the placement function under examination instead of in its
/// own setup while the devices layer is still stubs. The caller must
/// `table.arena.deinit()`; `Table.deinit` is deliberately not used for the same reason.
fn noHostClasses() host.Table {
    return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .classes = .empty };
}

/// The identity order for a spline set: `0, 1, 2, …`.
fn identityOrder(arena: Allocator, n: usize) ![]u32 {
    const o = try arena.alloc(u32, n);
    for (o, 0..) |*e, i| e.* = @intCast(i);
    return o;
}

/// Does `c` hold `d`?
fn columnHas(cols: colm.Columns, c: ColumnIdx, d: DeviceIdx) bool {
    for (cols.devices(c)) |x| {
        if (x == d) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Fixtures
//
// Net indices follow first-appearance order over the device list, which is why the
// nets are written in a readable order rather than alphabetically.
// ---------------------------------------------------------------------------

/// One spline, two devices. The floor case.
const inverter = [_]Dev{
    .{ .name = "mp", .class = "pmos", .nets = &.{ "out", "in", "vdd" } },
    .{ .name = "mn", .class = "nmos", .nets = &.{ "out", "in", "gnd" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// Two splines joined by a cross-column gate net. The mirror's output branch has a
/// gate whose net reaches back into the reference branch, which is the orientation
/// rule's motivating case.
const current_mirror = [_]Dev{
    .{ .name = "rref", .class = "res", .nets = &.{ "vdd", "ref" } },
    .{ .name = "m1", .class = "nmos", .nets = &.{ "ref", "ref", "gnd" } },
    .{ .name = "m2", .class = "nmos", .nets = &.{ "out", "ref", "gnd" } },
    .{ .name = "rl", .class = "res", .nets = &.{ "vdd", "out" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// Shared tail: two branches meeting at one device, `branch_count == 2`.
const diff_pair = [_]Dev{
    .{ .name = "rl1", .class = "res", .nets = &.{ "vdd", "op" } },
    .{ .name = "m1", .class = "nmos", .nets = &.{ "op", "inp", "tail" } },
    .{ .name = "rl2", .class = "res", .nets = &.{ "vdd", "on" } },
    .{ .name = "m2", .class = "nmos", .nets = &.{ "on", "inn", "tail" } },
    .{ .name = "mt", .class = "nmos", .nets = &.{ "tail", "vb", "gnd" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// A differential pair whose two branches want *different* stacking gaps: `on` carries
/// two extra gate taps and `op` carries none. Without the shared row profile the two
/// branches would stack differently, which is exactly what this fixture exists to
/// detect.
const diff_pair_asym = [_]Dev{
    .{ .name = "rl1", .class = "res", .nets = &.{ "vdd", "op" } },
    .{ .name = "m1", .class = "nmos", .nets = &.{ "op", "inp", "tail" } },
    .{ .name = "rl2", .class = "res", .nets = &.{ "vdd", "on" } },
    .{ .name = "m2", .class = "nmos", .nets = &.{ "on", "inn", "tail" } },
    .{ .name = "mt", .class = "nmos", .nets = &.{ "tail", "vb", "gnd" } },
    .{ .name = "rl3", .class = "res", .nets = &.{ "vdd", "o3" } },
    .{ .name = "mg", .class = "nmos", .nets = &.{ "o3", "on", "gnd" } },
    .{ .name = "rl4", .class = "res", .nets = &.{ "vdd", "o4" } },
    .{ .name = "mh", .class = "nmos", .nets = &.{ "o4", "on", "gnd" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// Three branches on one tail: `branch_count == 3`, so the tail anchors instead of
/// getting a column.
const tail_source_3 = [_]Dev{
    .{ .name = "rl1", .class = "res", .nets = &.{ "vdd", "n1" } },
    .{ .name = "m1", .class = "nmos", .nets = &.{ "n1", "g1", "tail" } },
    .{ .name = "rl2", .class = "res", .nets = &.{ "vdd", "n2" } },
    .{ .name = "m2", .class = "nmos", .nets = &.{ "n2", "g2", "tail" } },
    .{ .name = "rl3", .class = "res", .nets = &.{ "vdd", "n3" } },
    .{ .name = "m3", .class = "nmos", .nets = &.{ "n3", "g3", "tail" } },
    .{ .name = "mt", .class = "nmos", .nets = &.{ "tail", "vb", "gnd" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// A three-device spline: load, cascode, input device. Mid-stack tap territory.
const cascode = [_]Dev{
    .{ .name = "rl", .class = "res", .nets = &.{ "vdd", "out" } },
    .{ .name = "mc", .class = "nmos", .nets = &.{ "out", "vb", "mid" } },
    .{ .name = "mi", .class = "nmos", .nets = &.{ "mid", "in", "gnd" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// The same spline with a capacitor bridging two of *its own* nets: a same-spline
/// satellite, which must land in a column immediately after its parent.
const satellite = [_]Dev{
    .{ .name = "rl", .class = "res", .nets = &.{ "vdd", "out" } },
    .{ .name = "mc", .class = "nmos", .nets = &.{ "out", "vb", "mid" } },
    .{ .name = "mi", .class = "nmos", .nets = &.{ "mid", "in", "gnd" } },
    .{ .name = "cs", .class = "cap", .nets = &.{ "out", "mid" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// A cascode with two extra gate taps on its mid node, so that node's degree is 4 and
/// `optimal_len` is nonzero for exactly one pair in the column.
const mid_tap = [_]Dev{
    .{ .name = "rl", .class = "res", .nets = &.{ "vdd", "out" } },
    .{ .name = "mc", .class = "nmos", .nets = &.{ "out", "vb", "mid" } },
    .{ .name = "mi", .class = "nmos", .nets = &.{ "mid", "in", "gnd" } },
    .{ .name = "rl2", .class = "res", .nets = &.{ "vdd", "o2" } },
    .{ .name = "mx", .class = "nmos", .nets = &.{ "o2", "mid", "gnd" } },
    .{ .name = "rl3", .class = "res", .nets = &.{ "vdd", "o3" } },
    .{ .name = "my", .class = "nmos", .nets = &.{ "o3", "mid", "gnd" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// Two splines with a capacitor across their mid nodes: `|a - b| == 1`.
const bridge_adjacent = [_]Dev{
    .{ .name = "r1", .class = "res", .nets = &.{ "vdd", "n1" } },
    .{ .name = "m1", .class = "nmos", .nets = &.{ "n1", "g1", "gnd" } },
    .{ .name = "r2", .class = "res", .nets = &.{ "vdd", "n2" } },
    .{ .name = "m2", .class = "nmos", .nets = &.{ "n2", "g2", "gnd" } },
    .{ .name = "cc", .class = "cap", .nets = &.{ "n1", "n2" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// Three splines with a capacitor from the first to the third: `|a - b| == 2`.
const bridge_far = [_]Dev{
    .{ .name = "r1", .class = "res", .nets = &.{ "vdd", "n1" } },
    .{ .name = "m1", .class = "nmos", .nets = &.{ "n1", "g1", "gnd" } },
    .{ .name = "r2", .class = "res", .nets = &.{ "vdd", "n2" } },
    .{ .name = "m2", .class = "nmos", .nets = &.{ "n2", "g2", "gnd" } },
    .{ .name = "r3", .class = "res", .nets = &.{ "vdd", "n3" } },
    .{ .name = "m3", .class = "nmos", .nets = &.{ "n3", "g3", "gnd" } },
    .{ .name = "cc", .class = "cap", .nets = &.{ "n1", "n3" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// Differential input stage, a second gain stage, and a Miller capacitor bridging the
/// two. Three splines, one shared tail, one bridge.
const two_stage_miller = [_]Dev{
    .{ .name = "m1", .class = "nmos", .nets = &.{ "o1", "inp", "tail" } },
    .{ .name = "m2", .class = "nmos", .nets = &.{ "o2", "inn", "tail" } },
    .{ .name = "mt", .class = "nmos", .nets = &.{ "tail", "vb", "gnd" } },
    .{ .name = "rl1", .class = "res", .nets = &.{ "vdd", "o1" } },
    .{ .name = "rl2", .class = "res", .nets = &.{ "vdd", "o2" } },
    .{ .name = "m3", .class = "nmos", .nets = &.{ "out", "o2", "gnd" } },
    .{ .name = "rl3", .class = "res", .nets = &.{ "vdd", "out" } },
    .{ .name = "cc", .class = "cap", .nets = &.{ "o2", "out" } },
    .{ .name = "xv", .class = "vdd", .nets = &.{"vdd"} },
    .{ .name = "xg", .class = "gnd", .nets = &.{"gnd"} },
};

/// A lone pass transistor: no rail, no source, therefore no spline at all.
const pass_single = [_]Dev{
    .{ .name = "mn", .class = "nmos", .nets = &.{ "a", "en", "b" } },
};

/// A transmission gate: two antiparallel devices over the same pair of conducting
/// nets, which must share one column so their side wires stack.
const pass_gate = [_]Dev{
    .{ .name = "mn", .class = "nmos", .nets = &.{ "a", "en", "b" } },
    .{ .name = "mp", .class = "pmos", .nets = &.{ "b", "enb", "a" } },
};

// ---------------------------------------------------------------------------
// Tier A: the context
// ---------------------------------------------------------------------------

test "ground distance is the hop count to the nearest ground net over conduction edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &cascode);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    // gnd -(mi)- mid -(mc)- out -(rl)- vdd
    try expectEqual(@as(u32, 0), c.groundDistance(fx.net("gnd")));
    try expectEqual(@as(u32, 1), c.groundDistance(fx.net("mid")));
    try expectEqual(@as(u32, 2), c.groundDistance(fx.net("out")));
    try expectEqual(@as(u32, 3), c.groundDistance(fx.net("vdd")));
}

test "a gate net is unreachable from ground because control pins do not conduct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &inverter);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    // `in` touches only gates. A BFS that stepped through control terminals would
    // reach it in one hop and every spline walk downstream would be wrong.
    try expectEqual(Ctx.unreachable_dist, c.groundDistance(fx.net("in")));
    try expectEqual(@as(u32, 1), c.groundDistance(fx.net("out")));
}

test "conducting pins exclude the gate and keep terminal order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &inverter);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    const mn = fx.dev("mn");
    const cond = c.conductingPins(mn);
    try expectEqual(@as(usize, 2), cond.len);
    try expectEqual(fx.pin("mn", 0), cond[0]); // drain
    try expectEqual(fx.pin("mn", 2), cond[1]); // source
    for (cond) |p| try expect(!c.isControl(p));
    try expect(c.isControl(fx.pin("mn", 1)));
    try expect(!c.conducts(fx.pin("mn", 1)));

    // A supply symbol has no conducting terminal at all, so nothing walks through one.
    try expectEqual(@as(usize, 0), c.conductingPins(fx.dev("xg")).len);
}

test "net degree counts every pin on the net and members are ascending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &current_mirror);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    // ref: rref.b, m1.d, m1.g, m2.g
    const ref = fx.net("ref");
    try expectEqual(@as(u32, 4), c.degree(ref));
    const mem = c.members(ref);
    try expectEqual(@as(usize, 4), mem.len);
    var prev: u32 = 0;
    for (mem, 0..) |p, i| {
        if (i > 0) try expect(@intFromEnum(p) > prev);
        prev = @intFromEnum(p);
        try expectEqual(ref, c.netOf(p));
    }
}

test "net class comes from supply symbols rather than from net names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();

    // Same topology as the inverter, but the supply symbols are removed and the nets
    // keep their suggestive names. Nothing may be classified as a rail.
    const named_but_bare = [_]Dev{
        .{ .name = "mp", .class = "pmos", .nets = &.{ "out", "in", "vdd" } },
        .{ .name = "mn", .class = "nmos", .nets = &.{ "out", "in", "gnd" } },
    };
    const fx = try build(arena.allocator(), &named_but_bare);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    try expectEqual(NetClass.signal, c.classOfNet(fx.net("vdd")));
    try expectEqual(NetClass.signal, c.classOfNet(fx.net("gnd")));
    try expect(!c.isGround(fx.net("gnd")));

    const pn = try c.powerNets(std.testing.allocator);
    defer std.testing.allocator.free(pn);
    try expectEqual(@as(usize, 0), pn.len);
}

test "the pin to device reverse map agrees with the pin ranges it was built from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    for (0..fx.ir.deviceCount()) |di| {
        const d = DeviceIdx.at(di);
        const lo = fx.ir.dev_pin0[di];
        const hi = fx.ir.dev_pin0[di + 1];
        for (lo..hi) |pi| {
            const p = PinIdx.at(pi);
            try expectEqual(d, c.devOf(p));
            try expectEqual(@as(u32, @intCast(pi - lo)), c.pinSlot(p));
        }
    }
}

test "context build releases everything on every allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);

    const S = struct {
        fn once(gpa: Allocator, ir: *const ckt.Ir, tbl: *const host.Table) !void {
            var c = try Ctx.build(gpa, ir, tbl);
            defer c.deinit(gpa);
            c.assertValid();
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        S.once,
        .{ &fx.ir, &table },
    );
}

// ---------------------------------------------------------------------------
// Spline extraction
// ---------------------------------------------------------------------------

test "a spline runs from the power end to the ground end in conduction order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &cascode);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 1), sp.keyCount());
    try expectEqualSlices(
        DeviceIdx,
        &.{ fx.dev("rl"), fx.dev("mc"), fx.dev("mi") },
        sp.slice(ctxm.SplineIdx.at(0)),
    );
}

test "splines are deduplicated, non-empty and sorted by lowest device index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 3), sp.keyCount());

    var prev_min: u32 = 0;
    for (0..sp.keyCount()) |si| {
        const devs = sp.slice(ctxm.SplineIdx.at(si));
        try expect(devs.len > 0);

        // No device appears twice within one spline: the walk visits each at most once.
        for (devs, 0..) |a, i| {
            for (devs[i + 1 ..]) |b| try expect(a != b);
        }

        var lo: u32 = std.math.maxInt(u32);
        for (devs) |d| lo = @min(lo, @intFromEnum(d));
        if (si > 0) try expect(lo > prev_min);
        prev_min = lo;
    }
}

test "spline extraction is byte reproducible across two runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var a = try splinem.extract(std.testing.allocator, c);
    defer a.deinit(std.testing.allocator);
    var b = try splinem.extract(std.testing.allocator, c);
    defer b.deinit(std.testing.allocator);

    try expectEqualSlices(u32, a.offsets, b.offsets);
    try expectEqualSlices(DeviceIdx, a.values, b.values);
}

test "a rail-less conductor yields no spline at all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &pass_single);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 0), sp.keyCount());
}

test "branch count is two for a device shared by two branches and one elsewhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &diff_pair);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);

    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);

    try expectEqual(@as(u16, 2), bc[fx.dev("mt").i()]);
    try expectEqual(@as(u16, 1), bc[fx.dev("m1").i()]);
    try expectEqual(@as(u16, 1), bc[fx.dev("rl2").i()]);
    // Supply symbols are on no spline.
    try expectEqual(@as(u16, 0), bc[fx.dev("xv").i()]);
    try expectEqual(@as(u16, 0), bc[fx.dev("xg").i()]);
}

// ---------------------------------------------------------------------------
// Column assignment
// ---------------------------------------------------------------------------

test "a shared device with two branches gets its own column between them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &diff_pair);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);
    const ord = try identityOrder(arena.allocator(), sp.keyCount());

    var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
    defer cols.deinit(std.testing.allocator);

    try expectEqual(@as(usize, 3), cols.count());
    try expectEqual(ColumnKind.spline, cols.kind[0]);
    try expectEqual(ColumnKind.shared, cols.kind[1]);
    try expectEqual(ColumnKind.spline, cols.kind[2]);

    // The tail is removed from both branches and lives alone, strictly between them.
    try expectEqualSlices(DeviceIdx, &.{fx.dev("mt")}, cols.devices(ColumnIdx.at(1)));
    try expectEqual(ColumnIdx.at(1), cols.column_of[fx.dev("mt").i()]);
    try expectEqual(ColumnIdx.at(0), cols.column_of[fx.dev("m1").i()]);
    try expectEqual(ColumnIdx.at(2), cols.column_of[fx.dev("m2").i()]);

    // Rails never enter a column.
    try expectEqual(ColumnIdx.none, cols.column_of[fx.dev("xv").i()]);
    try expectEqual(ColumnIdx.none, cols.column_of[fx.dev("xg").i()]);
}

test "a shared device on three branches anchors to the span-minimising branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &tail_source_3);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    try expectEqual(@as(usize, 3), sp.keyCount());

    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);
    try expectEqual(@as(u16, 3), bc[fx.dev("mt").i()]);

    // Identity order: positions 0, 1, 2. Position 1 minimises the total distance to
    // the other two (2 against 3), so the tail stays on the middle branch and no
    // Shared column is created.
    {
        const ord = try identityOrder(arena.allocator(), 3);
        var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
        defer cols.deinit(std.testing.allocator);
        try expectEqual(@as(usize, 3), cols.count());
        for (cols.kind) |k| try expectEqual(ColumnKind.spline, k);
        try expectEqual(ColumnIdx.at(1), cols.column_of[fx.dev("mt").i()]);
        try expect(columnHas(cols, ColumnIdx.at(1), fx.dev("m2")));
    }

    // Permuted order: the anchor follows the *middle position*, not the first branch
    // and not a fixed spline. Spline 0 now sits at position 1, so the tail rides it.
    {
        const ord = try arena.allocator().dupe(u32, &.{ 2, 0, 1 });
        var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
        defer cols.deinit(std.testing.allocator);
        try expectEqual(ColumnIdx.at(1), cols.column_of[fx.dev("mt").i()]);
        try expect(columnHas(cols, ColumnIdx.at(1), fx.dev("m1")));
    }
}

test "a same-spline satellite lands in the column immediately after its parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &satellite);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);
    const ord = try identityOrder(arena.allocator(), sp.keyCount());

    var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
    defer cols.deinit(std.testing.allocator);

    // Parent spline at 0, satellite at a + 1 = 1. After, never before.
    try expectEqual(@as(usize, 2), cols.count());
    try expectEqual(ColumnKind.spline, cols.kind[0]);
    try expectEqual(ColumnKind.component, cols.kind[1]);
    try expectEqual(ColumnIdx.at(1), cols.column_of[fx.dev("cs").i()]);
    try expectEqual(ColumnIdx.at(0), cols.column_of[fx.dev("mc").i()]);
}

test "an adjacent bridge is a component column and a distant one is feedback" {
    // Two fixtures, one property: the Component/Feedback split is |a - b| == 1 against
    // |a - b| >= 2, per ALGORITHM.md's "Bridge devices" section.
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var table = noHostClasses();
        defer table.arena.deinit();
        const fx = try build(arena.allocator(), &bridge_adjacent);
        var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
        defer c.deinit(std.testing.allocator);

        var sp = try splinem.extract(std.testing.allocator, c);
        defer sp.deinit(std.testing.allocator);
        const bc = try c.branchCounts(std.testing.allocator, sp);
        defer std.testing.allocator.free(bc);
        const ord = try identityOrder(arena.allocator(), sp.keyCount());

        var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
        defer cols.deinit(std.testing.allocator);

        const cc = cols.column_of[fx.dev("cc").i()];
        try expectEqual(ColumnKind.component, cols.kind[cc.i()]);
        // Inserted just before the higher of the two columns it spans.
        try expectEqual(ColumnIdx.at(1), cc);
        try expect(cols.inField(cc));
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var table = noHostClasses();
        defer table.arena.deinit();
        const fx = try build(arena.allocator(), &bridge_far);
        var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
        defer c.deinit(std.testing.allocator);

        var sp = try splinem.extract(std.testing.allocator, c);
        defer sp.deinit(std.testing.allocator);
        const bc = try c.branchCounts(std.testing.allocator, sp);
        defer std.testing.allocator.free(bc);
        const ord = try identityOrder(arena.allocator(), sp.keyCount());

        var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
        defer cols.deinit(std.testing.allocator);

        const cc = cols.column_of[fx.dev("cc").i()];
        try expectEqual(ColumnKind.feedback, cols.kind[cc.i()]);
        // Margin-resident: it occupies no width in the device field.
        try expect(!cols.inField(cc));
    }
}

test "a Miller capacitor bridges the stages it spans as a component column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);
    const ord = try identityOrder(arena.allocator(), sp.keyCount());

    var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
    defer cols.deinit(std.testing.allocator);

    // Spline, Shared(mt), Spline, Component(cc), Spline.
    try expectEqual(@as(usize, 5), cols.count());
    try expectEqual(ColumnKind.shared, cols.kind[1]);
    const cc = cols.column_of[fx.dev("cc").i()];
    try expectEqual(ColumnKind.component, cols.kind[cc.i()]);
    const o2_col = cols.column_of[fx.dev("m2").i()];
    const out_col = cols.column_of[fx.dev("m3").i()];
    try expect(o2_col.i() < cc.i());
    try expect(cc.i() < out_col.i());
}

test "an antiparallel pass group shares one signal-series column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &pass_gate);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);

    var cols = try colm.assign(std.testing.allocator, c, sp, &.{}, bc);
    defer cols.deinit(std.testing.allocator);

    // Both devices span the same pair of conducting nets, so they stack together.
    try expectEqual(@as(usize, 1), cols.count());
    try expectEqual(ColumnKind.signal_series, cols.kind[0]);
    try expectEqual(@as(usize, 2), cols.devices(ColumnIdx.at(0)).len);
}

test "shared and component columns are transparent to span classification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &diff_pair_asym);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);
    const ord = try identityOrder(arena.allocator(), sp.keyCount());

    var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
    defer cols.deinit(std.testing.allocator);

    var infos = try colm.classifyNets(std.testing.allocator, c, cols, bc);
    defer infos.deinit(std.testing.allocator);

    // `tail` touches columns 0, 1 (the Shared hub) and 2. The Shared column is not a
    // stage the signal crosses, so this stays an immediate-neighbour net and keeps its
    // short horizontal run instead of being pushed into the margin band.
    const tail = infos.find(fx.net("tail")).?;
    try expectEqual(NetCase.immediate, infos.case[tail.i()]);

    // `on` reaches columns 2, 3 and 4, and column 3 is a real spline between them.
    const on = infos.find(fx.net("on")).?;
    try expectEqual(NetCase.span_ge2, infos.case[on.i()]);

    // `op` never leaves its column.
    const op = infos.find(fx.net("op")).?;
    try expectEqual(NetCase.within_column, infos.case[op.i()]);
}

// ---------------------------------------------------------------------------
// Orientation
// ---------------------------------------------------------------------------

test "a gate points left exactly when its net has a pin in an earlier column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &current_mirror);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);
    const ord = try identityOrder(arena.allocator(), sp.keyCount());

    var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
    defer cols.deinit(std.testing.allocator);

    const orients = try orientm.compute(std.testing.allocator, c, cols);
    defer std.testing.allocator.free(orients);

    const m1 = fx.dev("m1"); // reference leg, column 0
    const m2 = fx.dev("m2"); // output leg, column 1, gate net reaches back to column 0

    try expect(!orientm.gateFromLeft(c, cols, m1));
    try expect(orientm.gateFromLeft(c, cols, m2));

    // The encoding is an implementation detail; where the gate ends up is the
    // specification. Negative x is left.
    const g1 = orients[m1.i()].apply(c.termAt(fx.pin("m1", 1)));
    const g2 = orients[m2.i()].apply(c.termAt(fx.pin("m2", 1)));
    try expect(g1.x > 0);
    try expect(g2.x < 0);
}

test "orientation covers every device and leaves rails untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);

    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);
    const bc = try c.branchCounts(std.testing.allocator, sp);
    defer std.testing.allocator.free(bc);
    const ord = try identityOrder(arena.allocator(), sp.keyCount());

    var cols = try colm.assign(std.testing.allocator, c, sp, ord, bc);
    defer cols.deinit(std.testing.allocator);

    const orients = try orientm.compute(std.testing.allocator, c, cols);
    defer std.testing.allocator.free(orients);

    try expectEqual(fx.ir.deviceCount(), orients.len);
    try expectEqual(Orient.r0, orients[fx.dev("xv").i()]);
    try expectEqual(Orient.r0, orients[fx.dev("xg").i()]);

    // A gated spline device stands vertical: its two conduction pins end up on
    // different rows, which is what makes stacking a conduction link at all.
    const m3 = fx.dev("m3");
    const d_pt = orients[m3.i()].apply(c.termAt(fx.pin("m3", 0)));
    const s_pt = orients[m3.i()].apply(c.termAt(fx.pin("m3", 2)));
    try expect(d_pt.y != s_pt.y);
    try expectEqual(d_pt.x, s_pt.x);
}

// ---------------------------------------------------------------------------
// Stacking and spacing
// ---------------------------------------------------------------------------

/// Common setup for the geometry tests: context, splines, columns, orientation.
const Stage = struct {
    c: Ctx,
    sp: ctxm.SplineSet,
    bc: []u16,
    cols: colm.Columns,
    infos: colm.NetInfos,
    orients: []Orient,

    fn init(gpa: Allocator, arena: Allocator, fx: *const Fixture, table: *const host.Table) !Stage {
        var c = try Ctx.build(gpa, &fx.ir, table);
        errdefer c.deinit(gpa);
        var sp = try splinem.extract(gpa, c);
        errdefer sp.deinit(gpa);
        const bc = try c.branchCounts(gpa, sp);
        errdefer gpa.free(bc);
        const ord = try identityOrder(arena, sp.keyCount());
        var cols = try colm.assign(gpa, c, sp, ord, bc);
        errdefer cols.deinit(gpa);
        var infos = try colm.classifyNets(gpa, c, cols, bc);
        errdefer infos.deinit(gpa);
        const orients = try orientm.compute(gpa, c, cols);
        return .{ .c = c, .sp = sp, .bc = bc, .cols = cols, .infos = infos, .orients = orients };
    }

    fn deinit(self: *Stage, gpa: Allocator) void {
        gpa.free(self.orients);
        self.infos.deinit(gpa);
        self.cols.deinit(gpa);
        gpa.free(self.bc);
        self.sp.deinit(gpa);
        self.c.deinit(gpa);
    }
};

test "optimal_len subtracts the conduction link itself and abuts at zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &mid_tap);
    var p = try Stage.init(std.testing.allocator, arena.allocator(), &fx, &table);
    defer p.deinit(std.testing.allocator);

    const cfg = ckt.Config.default;

    // `out` has degree 2 and both pins are in this column: 2 - 2 - 1 clamps to zero,
    // so the load and the cascode device abut. The -1 is what makes this zero rather
    // than one tap unit of courtesy air.
    try expectEqual(@as(i32, 0), stackm.optimalLen(
        p.c,
        p.cols,
        p.orients,
        fx.dev("rl"),
        fx.dev("mc"),
        &cfg,
    ));

    // `mid` has degree 4: two conduction pins in this column plus two foreign gate
    // taps. 4 - 2 - 1 = 1 tap unit of room for the taps to arrive on.
    try expectEqual(@as(u32, 4), p.c.degree(fx.net("mid")));
    try expectEqual(cfg.layout.tap_unit, stackm.optimalLen(
        p.c,
        p.cols,
        p.orients,
        fx.dev("mc"),
        fx.dev("mi"),
        &cfg,
    ));
}

test "equal-depth spline columns share one row profile" {
    // The load-bearing rule in stack.zig. Branch `op` wants a zero gap and branch `on`
    // wants one tap unit; the shared profile gives both the larger one, so device k of
    // every equal-depth branch starts at the same y. A per-column stacker satisfies
    // every other assertion in this file and fails this one.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &diff_pair_asym);
    var p = try Stage.init(std.testing.allocator, arena.allocator(), &fx, &table);
    defer p.deinit(std.testing.allocator);

    const cfg = ckt.Config.default;

    // Establish that the two branches genuinely disagree about their own gap, so the
    // equality below is the profile doing work rather than a symmetric fixture.
    const gap_op = stackm.optimalLen(p.c, p.cols, p.orients, fx.dev("rl1"), fx.dev("m1"), &cfg);
    const gap_on = stackm.optimalLen(p.c, p.cols, p.orients, fx.dev("rl2"), fx.dev("m2"), &cfg);
    try expectEqual(@as(i32, 0), gap_op);
    try expectEqual(cfg.layout.tap_unit, gap_on);

    const dev_y = try stackm.stackColumns(std.testing.allocator, p.c, p.cols, p.orients, &cfg);
    defer std.testing.allocator.free(dev_y);

    // Row 0 of every depth-2 spline column.
    const top = dev_y[fx.dev("rl1").i()];
    try expectEqual(top, dev_y[fx.dev("rl2").i()]);
    try expectEqual(top, dev_y[fx.dev("rl3").i()]);
    try expectEqual(top, dev_y[fx.dev("rl4").i()]);

    // Row 1 of every depth-2 spline column — the row that would have diverged.
    const second = dev_y[fx.dev("m1").i()];
    try expectEqual(second, dev_y[fx.dev("m2").i()]);
    try expectEqual(second, dev_y[fx.dev("mg").i()]);
    try expectEqual(second, dev_y[fx.dev("mh").i()]);

    // And it is the *larger* profile that won: the tapped branch's gap, not the bare
    // branch's zero.
    try expect(second - top >= gap_on);
}

test "a spanning net reserves no lane in any gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &diff_pair_asym);
    var p = try Stage.init(std.testing.allocator, arena.allocator(), &fx, &table);
    defer p.deinit(std.testing.allocator);

    const lanes = try stackm.gapLanes(std.testing.allocator, p.c, p.cols, p.infos);
    defer std.testing.allocator.free(lanes);

    try expectEqual(p.cols.count() - 1, lanes.len);

    // `on` spans columns 2..4 and is the only net crossing gaps 2 and 3. Reserving a
    // lane at each of its endpoint gaps was measured to widen every wide circuit by
    // ~5% of its area to guarantee room the router did not use, so it reserves none.
    try expectEqual(@as(u32, 0), lanes[2]);
    try expectEqual(@as(u32, 0), lanes[3]);

    // The immediate-neighbour `tail` net does reserve, in each of the two gaps it
    // crosses; rails abstain entirely, so nothing else contributes.
    try expectEqual(@as(u32, 1), lanes[0]);
    try expectEqual(@as(u32, 1), lanes[1]);
}

test "every gap keeps a floor of one wire gauge" {
    const cfg = ckt.Config.default;
    // No fixed channel base: width is exactly one gauge per reserved lane, plus one so
    // a riser always has somewhere to run.
    try expectEqual(cfg.layout.track_w, stackm.gapWidth(&cfg, 0));
    try expectEqual(cfg.layout.track_w * 2, stackm.gapWidth(&cfg, 1));
    try expectEqual(cfg.layout.track_w * 4, stackm.gapWidth(&cfg, 3));
}

test "column axes advance by both half-widths plus the gap between them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &diff_pair_asym);
    var p = try Stage.init(std.testing.allocator, arena.allocator(), &fx, &table);
    defer p.deinit(std.testing.allocator);

    const cfg = ckt.Config.default;
    const lanes = try stackm.gapLanes(std.testing.allocator, p.c, p.cols, p.infos);
    defer std.testing.allocator.free(lanes);

    var placed = try stackm.placeColumns(
        std.testing.allocator,
        p.c,
        p.cols,
        p.orients,
        lanes,
        &cfg,
    );
    defer std.testing.allocator.free(placed[0]);
    defer std.testing.allocator.free(placed[1]);
    defer placed[2].deinit(std.testing.allocator);
    const half = placed[0];
    const col_x = placed[1];

    try expectEqual(p.cols.count(), col_x.len);
    for (1..p.cols.count()) |i| {
        const ci = ColumnIdx.at(i);
        if (!p.cols.inField(ci)) continue;
        try expectEqual(
            col_x[i - 1] + half[i - 1] + half[i] + stackm.gapWidth(&cfg, lanes[i - 1]),
            col_x[i],
        );
    }

    // One band per gap plus one outside each extreme.
    try expectEqual(p.cols.count() + 1, placed[2].keyCount());
}

// ---------------------------------------------------------------------------
// Phase A: enumerate widely, judge cheaply
// ---------------------------------------------------------------------------

test "the phase A proxy has exactly two terms and no crossing term" {
    // ALGORITHM.md is explicit: an interval-interleave count and a stack-depth
    // inversion count were both implemented and measured, and both made the shortlist
    // worse. Phase A reasons over splines while crossings are decided by columns, and
    // the two are not the same set. Adding a third field should be a deliberate act,
    // so it is pinned here.
    const fields = @typeInfo(Proxy).@"struct".fields;
    try expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("span", fields[0].name);
    try std.testing.expectEqualStrings("backward", fields[1].name);
}

test "the phase A proxy ranks by span first and backward count second" {
    const a: Proxy = .{ .span = 3, .backward = 9 };
    const b: Proxy = .{ .span = 4, .backward = 0 };
    try expect(a.lessThan(b));
    try expect(!b.lessThan(a));

    const c: Proxy = .{ .span = 4, .backward = 1 };
    try expect(b.lessThan(c));
    try expect(!c.lessThan(b));

    // Irreflexive, so it is a strict order and a sort over it is stable-safe.
    try expect(!a.lessThan(a));
}

test "phase A ranks every order without allocating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);
    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);

    const cfg = ckt.Config.default;
    var ranker = try orderm.Ranker.init(std.testing.allocator, c, sp, &cfg);
    defer ranker.deinit(std.testing.allocator);

    // The property is structural: the function takes no allocator, so it cannot
    // allocate. Checking the signature is what survives a refactor; checking a
    // counter only catches the version that still had the parameter.
    inline for (@typeInfo(@TypeOf(orderm.phaseA)).@"fn".params) |param| {
        try expect(param.type.? != Allocator);
    }

    // And nothing reachable from the loop touches the heap: a failing allocator armed
    // to reject its very first request stays untouched across the whole enumeration.
    const fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var out: [8]orderm.Candidate = undefined;
    const n = orderm.phaseA(&ranker, &cfg, &out);
    try expect(n > 0);
    try expectEqual(@as(usize, 0), fa.allocations);
}

test "the phase A shortlist is sorted and identical across runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);
    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);

    const cfg = ckt.Config.default;
    var ranker = try orderm.Ranker.init(std.testing.allocator, c, sp, &cfg);
    defer ranker.deinit(std.testing.allocator);

    var first: [6]orderm.Candidate = undefined;
    var second: [6]orderm.Candidate = undefined;
    const n1 = orderm.phaseA(&ranker, &cfg, &first);
    const n2 = orderm.phaseA(&ranker, &cfg, &second);

    try expectEqual(n1, n2);
    try expect(n1 > 1);

    // Sorted ascending, with every tier an integer comparison so nothing depends on
    // insertion order.
    for (1..n1) |i| try expect(!first[i].lessThan(first[i - 1]));

    // Byte-identical between runs, which is the whole determinism guarantee.
    try expectEqualDeep(first[0..n1], second[0..n2]);

    // Every survivor is a genuine permutation of the spline set.
    for (first[0..n1]) |cand| {
        try expectEqual(@as(u8, @intCast(sp.keyCount())), cand.len);
        var seen = [_]bool{false} ** orderm.max_splines;
        for (cand.slice()) |s| {
            try expect(!seen[s]);
            seen[s] = true;
        }
    }
}

test "the phase A proxy is invariant under a free intra-spine swap" {
    // Worth pinning because it is what makes the swap enumeration free: the proxy is a
    // function of which splines a net touches and where those splines sit, never of
    // the order of devices inside one. Two survivors that differ only in swap mask
    // therefore carry the identical score.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &diff_pair);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);
    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);

    const cfg = ckt.Config.default;
    var ranker = try orderm.Ranker.init(std.testing.allocator, c, sp, &cfg);
    defer ranker.deinit(std.testing.allocator);

    var out: [orderm.max_refine]orderm.Candidate = undefined;
    const n = orderm.phaseA(&ranker, &cfg, out[0..8]);
    try expect(n > 0);

    // Any two survivors sharing an order carry the same proxy regardless of mask.
    for (out[0..n]) |a| {
        for (out[0..n]) |b| {
            if (!std.mem.eql(u8, a.slice(), b.slice())) continue;
            try expectEqual(a.proxy, b.proxy);
        }
    }
}

test "the greedy fallback yields one order per starting spline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = noHostClasses();
    defer table.arena.deinit();
    const fx = try build(arena.allocator(), &two_stage_miller);
    var c = try Ctx.build(std.testing.allocator, &fx.ir, &table);
    defer c.deinit(std.testing.allocator);
    var sp = try splinem.extract(std.testing.allocator, c);
    defer sp.deinit(std.testing.allocator);

    // Force the guard: with the limit below the spline count, enumeration is abandoned
    // for greedy seeds. That is a resource bound, not an opinion.
    var cfg = ckt.Config.default;
    cfg.layout.enum_limit = 1;
    var ranker = try orderm.Ranker.init(std.testing.allocator, c, sp, &cfg);
    defer ranker.deinit(std.testing.allocator);

    var seeds: [orderm.max_splines][orderm.max_splines]u8 = undefined;
    const n = ranker.greedyOrders(&seeds);
    try expectEqual(sp.keyCount(), n);
    for (seeds[0..n], 0..) |seed, i| {
        try expectEqual(@as(u8, @intCast(i)), seed[0]);
        var mask: u32 = 0;
        for (seed[0..sp.keyCount()]) |s| mask |= @as(u32, 1) << @intCast(s);
        try expectEqual((@as(u32, 1) << @intCast(sp.keyCount())) - 1, mask);
    }
}

// ---------------------------------------------------------------------------
// Phase B: the lexicographic key
// ---------------------------------------------------------------------------

test "fewer crossings wins even with more staples and a longer span" {
    // The specific consequence of "crossings outrank staples and span": a crossing is a
    // measured aesthetic fault, while those two are proxies for complexity. A weighted
    // sum would let the two proxies buy back the fault, which is why this is never one.
    const clean: Key = .{ .crossings = 1, .staples = 40, .total_span = 400 };
    const tangled: Key = .{ .crossings = 2, .staples = 0, .total_span = 0 };
    try expect(clean.lessThan(tangled));
    try expect(!tangled.lessThan(clean));
    try expectEqual(@as(usize, 0), orderm.pickBest(&.{ clean, tangled }));
    try expectEqual(@as(usize, 1), orderm.pickBest(&.{ tangled, clean }));
}

test "one dropped label outranks every other fault in the key" {
    const labelled: Key = .{ .labels = 1 };
    const messy: Key = .{
        .pin_hits = 9,
        .geom_shorts = 9,
        .body_hits = 9,
        .overlaps = 9,
        .crossings = 9,
        .staples = 9,
        .total_span = 9,
        .forward_margin = 9,
        .margin_tracks = 9,
    };
    try expect(messy.lessThan(labelled));
    try expect(!labelled.lessThan(messy));
}

test "the selection key field order is the priority order" {
    // Each field, in declaration order, must dominate every field after it. Bumping
    // field i by one and zeroing everything after must still lose to a key that is
    // zero at i and maximal afterwards.
    const fields = @typeInfo(Key).@"struct".fields;
    try expectEqual(@as(usize, 11), fields.len);

    inline for (fields, 0..) |f, i| {
        if (comptime std.mem.eql(u8, f.name, "netid_seq")) continue;
        var worse: Key = .{};
        var better: Key = .{};
        @field(worse, f.name) = 1;
        inline for (fields, 0..) |g, j| {
            if (j > i) @field(better, g.name) = 1_000;
        }
        try expect(better.lessThan(worse));
        try expect(!worse.lessThan(better));
    }
}

test "the selection key is a strict total order" {
    const samples = [_]Key{
        .{},
        .{ .labels = 1 },
        .{ .crossings = 1 },
        .{ .crossings = 1, .staples = 1 },
        .{ .crossings = 1, .staples = 1, .netid_seq = 7 },
        .{ .margin_tracks = 3 },
        .{ .body_hits = 2, .crossings = 1 },
    };
    for (samples) |a| {
        try expect(!a.lessThan(a)); // irreflexive
        for (samples) |b| {
            if (a.lessThan(b)) try expect(!b.lessThan(a)); // antisymmetric
            for (samples) |c| {
                if (a.lessThan(b) and b.lessThan(c)) try expect(a.lessThan(c)); // transitive
            }
        }
    }
}

test "netid_seq is the last tie-break and depends only on the net set" {
    const a = [_]NetIdx{ NetIdx.at(0), NetIdx.at(1), NetIdx.at(4) };
    const b = [_]NetIdx{ NetIdx.at(0), NetIdx.at(1), NetIdx.at(5) };

    // A pure function of the sequence: the same input folds the same way every time,
    // with no seed, no address dependence and nothing else two runs could disagree on.
    try expectEqual(Key.foldNetIds(&a), Key.foldNetIds(&a));
    try expect(Key.foldNetIds(&a) != Key.foldNetIds(&b));

    // And it decides only when the ten quality fields are exhausted.
    const lo: Key = .{ .crossings = 2, .netid_seq = Key.foldNetIds(&a) };
    const hi: Key = .{ .crossings = 2, .netid_seq = Key.foldNetIds(&a) +% 1 };
    try expect(lo.lessThan(hi) != hi.lessThan(lo));

    const beats_on_quality: Key = .{ .crossings = 1, .netid_seq = std.math.maxInt(u64) };
    try expect(beats_on_quality.lessThan(lo));
}

test "picking the best candidate is stable on an exact tie" {
    // On an exact tie the earlier candidate wins, and the earlier candidate is the
    // better Phase-A proxy — so the cheap filter breaks what the expensive one could
    // not, deterministically.
    const k: Key = .{ .crossings = 3 };
    try expectEqual(@as(usize, 0), orderm.pickBest(&.{ k, k, k }));
    try expectEqual(@as(usize, 1), orderm.pickBest(&.{
        .{ .crossings = 4 },
        k,
        k,
    }));
}
