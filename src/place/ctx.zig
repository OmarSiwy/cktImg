//! Tier-A precompute: everything about a netlist that is true for *every* column
//! order, resolved once and then frozen.
//!
//! ALGORITHM.md splits the placer's knowledge into three tiers by what each
//! quantity depends on. Tier A is the topology-invariant half — pure functions of
//! the netlist graph, identical no matter which left-to-right order the search is
//! currently trying. This file is that tier, and the reason it is a distinct type
//! rather than a bag of helpers on `Ir` is the safety argument in ALGORITHM.md
//! ("Precompute — what's resolved when"): a quantity computed once cannot drift,
//! and a quantity rediscovered per candidate eventually will.
//!
//! What moves through here:
//!
//! ```
//! Ir (pin_net, dev_pin0, dev_symbol)  +  device class table
//!   -> pin -> device            dense reverse map
//!   -> net -> pins              CSR, ascending pin order
//!   -> net class                power / ground / signal, from symbol ROLES
//!   -> device -> conducting pins  CSR, drain/source but never gate
//!   -> ground distance          BFS hop count over conduction edges
//! ```
//!
//! Downstream, `spline.zig` walks the ground-distance field, `column.zig` asks for
//! conducting pins and branch counts, `orient.zig` asks which pins are control
//! pins, and `stack.zig` asks for net degree. None of them recompute any of it.
//!
//! ## Why the reverse map is dense
//!
//! `Ir.deviceOf` binary-searches `dev_pin0` in O(log n). That is the right answer
//! for a one-off lookup and the wrong one here: every pass in `place/` walks a net's
//! pins and immediately asks which device each belongs to, so the query is in the
//! innermost loop of the whole placer. One `u32` per pin buys an array index. The
//! map is dense rather than a hash because a pin index *is* already the key.
//!
//! ## Why conducting pins are a CSR and not a predicate
//!
//! `conducts(pin)` is cheap on its own — one class lookup, one terminal role. But
//! the callers want *the list*: "the other conducting pin of this device", "does
//! this device's second terminal reach ground". Materializing that list per call
//! would allocate inside the spline walk. ALGORITHM.md's Tier-A table asks for a
//! CSR by name, "so a lookup returns a slice, never a fresh allocation", and that
//! is what this is. It also silently encodes the rule that matters: a MOSFET's gate
//! is **not** in the list, so no walk can ever step through a control terminal and
//! mistake a bias net for a conduction path.
//!
//! ## Net class comes from symbols, never from names
//!
//! A net is power or ground because a `vdd` / `gnd` *symbol* touches it, not because
//! it is spelled `vdd`. A netlist that names a signal `vdd` without wiring a supply
//! symbol to it gets a signal net, which is the correct reading of what it wrote.
//!
//! ## Lifetime
//!
//! A `Ctx` is **per-document**: it is built once from the `doc` arena after the front
//! end hands over the IR, and it is immutable for the rest of the run. It must never
//! be allocated from the `search` arena, because `search` is reset between candidate
//! orders and the whole point of Tier A is that it survives them. It borrows `ir` and
//! `table` and outlives neither.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const irm = @import("../ir.zig");
const Csr = @import("../csr.zig").Csr;
const catalog = @import("../devices/catalog.zig");
const host = @import("../devices/host.zig");

const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const NetClass = ids.NetClass;
const Pt = ids.Pt;
const Ir = irm.Ir;
const DeviceClass = catalog.DeviceClass;
const TerminalRole = catalog.TerminalRole;
const SymbolRole = catalog.SymbolRole;

/// One extracted conduction path from a power net down to ground.
///
/// Declared *here* rather than in `spline.zig` on purpose. ALGORITHM.md's Tier-A
/// table lists `branch_count(dev)` — how many splines pass through a device — as
/// topology-invariant, "invariant because the spline *set* is fixed; only its order
/// is searched". `Ctx.branchCounts` therefore has to name the spline index space, and
/// putting the index here keeps the dependency one-way: `spline.zig` imports `ctx.zig`
/// and never the reverse.
pub const SplineIdx = enum(u32) {
    /// Not on any spline. Used by the device→splines reverse relation in `order.zig`.
    none = std.math.maxInt(u32),
    _,

    pub fn i(s: SplineIdx) usize {
        std.debug.assert(s != .none);
        return @intFromEnum(s);
    }

    pub fn at(n: usize) SplineIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// The full spline set: spline → its devices, in conduction order from the power
/// end toward ground.
///
/// A CSR rather than `[][]DeviceIdx` because a shared device appears on several
/// splines and the whole set is built, read and freed as one unit. Order *within* a
/// spline is conduction order and is load-bearing — `column.zig` stacks devices in
/// exactly this sequence.
pub const SplineSet = Csr(SplineIdx, DeviceIdx);

/// Derived, order-independent facts about one schematic.
///
/// Every field is owned and released by `deinit`, except `ir` and `table`, which are
/// **borrowed** and must outlive the `Ctx`. Immutable after `build` returns: nothing
/// in `place/` writes through a `*Ctx`, and the accessors all take it by value.
pub const Ctx = struct {
    /// Borrowed. Valid until the document arena is reset.
    ir: *const Ir,
    /// Borrowed class table for resolving a `SymbolIdx` above `catalog.builtin_count`.
    /// Valid until the table's `deinit`.
    table: *const host.Table,

    /// Owning device per pin, dense. Indexed by `PinIdx`; length `ir.pinCount()`.
    pin_dev: []DeviceIdx,
    /// net → its pins, ascending by pin index. Floating pins appear nowhere.
    net_pins: Csr(NetIdx, PinIdx),
    /// Electrical class per net. Indexed by `NetIdx` (so subscript with `.i()`).
    net_class: []NetClass,
    /// device → the terminals that carry current. Excludes gate, base and bulk.
    cond: Csr(DeviceIdx, PinIdx),
    /// Hop distance from each net to the nearest ground net over conduction edges.
    /// `unreachable_dist` where no path exists — gate-only nets are the normal case.
    gnd_dist: []u32,

    /// The distance a net gets when no conduction path reaches ground.
    ///
    /// Chosen as `maxInt(u32)` so that "strictly closer to ground" comparisons in the
    /// spline walk reject an unreachable net without a special case, and so that an
    /// unreachable net can never win a minimum.
    pub const unreachable_dist: u32 = std.math.maxInt(u32);

    pub const empty: Ctx = .{
        .ir = undefined,
        .table = undefined,
        .pin_dev = &.{},
        .net_pins = .empty,
        .net_class = &.{},
        .cond = .empty,
        .gnd_dist = &.{},
    };

    /// Build the whole Tier-A block in five linear passes.
    ///
    /// `ir` must already satisfy `Ir.assertValid` — a malformed IR is a front-end bug
    /// and is asserted, not handled. `table` resolves host symbol classes; pass a
    /// table with zero registered classes when the schematic uses only builtins.
    ///
    /// Caller owns the result and must `deinit` it with the same allocator. In
    /// practice that allocator is the pipeline's **`doc` arena**, matching the
    /// per-document lifetime described in the module header; `deinit` then costs
    /// nothing but is still correct under a general-purpose allocator, which is what
    /// lets tests run it under `std.testing.allocator`.
    ///
    /// Errors: `OutOfMemory` only. Every intermediate is `errdefer`-released, so a
    /// failure at any of the five passes leaks nothing — this is the property
    /// `std.testing.checkAllAllocationFailures` exists to prove.
    ///
    /// Edge cases: an IR with zero devices yields a `Ctx` whose every array is empty
    /// and whose accessors are all safe to call with no key. A net with no pins (never
    /// produced by the front end, but representable) gets degree 0, class `.signal`
    /// and `unreachable_dist`.
    ///
    /// Complexity: O(devices + pins + nets) for the four table passes, plus O(pins)
    /// for the ground BFS, which visits each net once and each incident pin once.
    pub fn build(gpa: Allocator, ir: *const Ir, table: *const host.Table) Allocator.Error!Ctx {
        ir.assertValid();
        const nd = ir.deviceCount();
        const np = ir.pinCount();
        const nn = ir.netCount();

        // Pass 1: dense pin -> device.
        const pin_dev = try gpa.alloc(DeviceIdx, np);
        errdefer gpa.free(pin_dev);
        for (0..nd) |d| {
            const lo, const hi = ir.pinRange(DeviceIdx.at(d));
            for (lo..hi) |p| pin_dev[p] = DeviceIdx.at(d);
        }

        // Pass 2: net -> pins, ascending by pin index (counting sort in `Ir`).
        var net_pins = try ir.netPins(gpa);
        errdefer net_pins.deinit(gpa);

        // Pass 3: net class, from the *symbols* on the net and never from its name.
        const net_class = try gpa.alloc(NetClass, nn);
        errdefer gpa.free(net_class);
        for (net_class, 0..) |*cls, n| {
            var pwr = false;
            var gnd = false;
            for (net_pins.slice(NetIdx.at(n))) |p| {
                switch (classIn(ir, table, pin_dev[p.i()]).role) {
                    .power_rail => pwr = true,
                    .ground_rail => gnd = true,
                    else => {},
                }
            }
            cls.* = if (pwr) .power else if (gnd) .ground else .signal;
        }

        // Pass 4: device -> conducting pins. Counted, then filled: the predicate is
        // one class lookup per pin and running it twice is cheaper than a scratch list.
        const counts = try gpa.alloc(u32, nd);
        defer gpa.free(counts);
        for (0..nd) |d| {
            const cls = classIn(ir, table, DeviceIdx.at(d));
            // Current passes *through* a device, so a one-terminal class — every rail,
            // supply and port glyph — conducts nothing no matter what its terminal
            // role says. Without this a ground symbol would look like a conductor and
            // every walk would step into the bus.
            if (cls.terminals.len < 2) {
                counts[d] = 0;
                continue;
            }
            const lo, const hi = ir.pinRange(DeviceIdx.at(d));
            var k: u32 = 0;
            for (lo..hi) |p| {
                if (cls.terminals[p - lo].role.conducts()) k += 1;
            }
            counts[d] = k;
        }
        var cond = try Csr(DeviceIdx, PinIdx).fromCounts(gpa, counts);
        errdefer cond.deinit(gpa);
        for (0..nd) |d| {
            const cls = classIn(ir, table, DeviceIdx.at(d));
            // Current passes *through* a device, so a one-terminal class — every rail,
            // supply and port glyph — conducts nothing no matter what its terminal
            // role says. Without this a ground symbol would look like a conductor and
            // every walk would step into the bus.
            if (cls.terminals.len < 2) continue;
            const lo, const hi = ir.pinRange(DeviceIdx.at(d));
            var w: usize = cond.offsets[d];
            for (lo..hi) |p| {
                if (cls.terminals[p - lo].role.conducts()) {
                    cond.values[w] = PinIdx.at(p);
                    w += 1;
                }
            }
        }

        // Pass 5: BFS from every ground net over conduction edges.
        const gnd_dist = try gpa.alloc(u32, nn);
        errdefer gpa.free(gnd_dist);
        @memset(gnd_dist, unreachable_dist);
        const queue = try gpa.alloc(NetIdx, nn);
        defer gpa.free(queue);
        var tail: usize = 0;
        for (net_class, 0..) |cls, n| {
            if (cls != .ground) continue;
            gnd_dist[n] = 0;
            queue[tail] = NetIdx.at(n);
            tail += 1;
        }
        var head: usize = 0;
        while (head < tail) : (head += 1) {
            const n = queue[head];
            const dn = gnd_dist[n.i()];
            for (net_pins.slice(n)) |pin| {
                const d = pin_dev[pin.i()];
                const cls = classIn(ir, table, d);
                if (isRailRole(cls.role)) continue;
                const slot = pin.i() - ir.dev_pin0[d.i()];
                if (!cls.terminals[slot].role.conducts()) continue;
                for (cond.slice(d)) |q| {
                    const m = ir.pin_net[q.i()];
                    if (m == .none or m == n) continue;
                    if (gnd_dist[m.i()] != unreachable_dist) continue;
                    gnd_dist[m.i()] = dn + 1;
                    queue[tail] = m;
                    tail += 1;
                }
            }
        }

        return .{
            .ir = ir,
            .table = table,
            .pin_dev = pin_dev,
            .net_pins = net_pins,
            .net_class = net_class,
            .cond = cond,
            .gnd_dist = gnd_dist,
        };
    }

    /// Release every owned array. Does not touch `ir` or `table`. Safe on `.empty`.
    pub fn deinit(self: *Ctx, gpa: Allocator) void {
        gpa.free(self.pin_dev);
        self.net_pins.deinit(gpa);
        gpa.free(self.net_class);
        self.cond.deinit(gpa);
        gpa.free(self.gnd_dist);
        self.pin_dev = &.{};
        self.net_class = &.{};
        self.gnd_dist = &.{};
    }

    pub fn deviceCount(self: Ctx) usize {
        return self.ir.deviceCount();
    }

    pub fn netCount(self: Ctx) usize {
        return self.ir.netCount();
    }

    pub fn pinCount(self: Ctx) usize {
        return self.ir.pinCount();
    }

    /// The class record for `d`, resolved across the builtin catalog and the host
    /// table.
    ///
    /// Returned by value; the slices inside are borrowed from static data or the
    /// table's arena and are valid as long as `table` is. Asserts the symbol index is
    /// in range for one of the two tables.
    pub fn classOf(self: Ctx, d: DeviceIdx) DeviceClass {
        return self.table.at(self.ir.dev_symbol[d.i()]);
    }

    /// Placement role of `d`'s symbol: `.power_rail`, `.ground_rail`, a port, or
    /// `.none` for an ordinary device.
    pub fn symbolRoleOf(self: Ctx, d: DeviceIdx) SymbolRole {
        return self.classOf(d).role;
    }

    /// True when `d` is a supply symbol rather than a circuit element.
    ///
    /// Rails are excluded from splines, from column membership, from foreign-pin
    /// blocking and from the collision metrics: they are drawn as bus rows, not as
    /// placed devices. Every walk in `place/` skips them, so this predicate is the
    /// single definition of "not a real device".
    pub fn isRail(self: Ctx, d: DeviceIdx) bool {
        return isRailRole(self.symbolRoleOf(d));
    }

    /// The device owning `p`. One array read — this is the dense map the module
    /// header argues for, not `Ir.deviceOf`'s binary search.
    pub fn devOf(self: Ctx, p: PinIdx) DeviceIdx {
        return self.pin_dev[p.i()];
    }

    /// The net `p` sits on, or `.none` when the pin is floating.
    pub fn netOf(self: Ctx, p: PinIdx) NetIdx {
        return self.ir.pin_net[p.i()];
    }

    /// `p`'s position within its device's terminal list, which is also its index into
    /// the class's `terminals`. Range `0 .. class.terminalCount()`.
    pub fn pinSlot(self: Ctx, p: PinIdx) u32 {
        return @intCast(p.i() - self.ir.dev_pin0[self.devOf(p).i()]);
    }

    /// Electrical role of `p`'s terminal: drain, gate, passive, and so on.
    pub fn roleOf(self: Ctx, p: PinIdx) TerminalRole {
        return self.classOf(self.devOf(p)).terminals[self.pinSlot(p)].role;
    }

    /// `p`'s anchor point in the class's canonical (unoriented) frame.
    ///
    /// Orientation is applied by the caller — `stack.zig` and `orient.zig` both need
    /// the canonical point *and* the oriented one, and combining them here would force
    /// the orientation array through every accessor in this file.
    pub fn termAt(self: Ctx, p: PinIdx) Pt {
        return self.classOf(self.devOf(p)).terminals[self.pinSlot(p)].at;
    }

    /// True when current passes through `p` rather than controlling it.
    ///
    /// Equivalent to `roleOf(p).conducts()`, and equivalent to `p` appearing in
    /// `conductingPins(devOf(p))`. Both forms exist because the walk wants the
    /// predicate on a pin it already has, and the extractor wants the list.
    pub fn conducts(self: Ctx, p: PinIdx) bool {
        return self.roleOf(p).conducts();
    }

    /// True when `p` is a control terminal (gate or base).
    ///
    /// Not simply `!conducts(p)`: bulk conducts nothing and controls nothing, so the
    /// two predicates are independent, and the orientation and backward-net rules key
    /// on control specifically.
    pub fn isControl(self: Ctx, p: PinIdx) bool {
        return self.roleOf(p).isControl();
    }

    /// `d`'s current-carrying terminals, in terminal-slot order.
    ///
    /// Borrowed from `cond.values`; valid until `deinit`, never freed by the caller.
    /// Empty for a rail symbol and for any single-terminal class. Two entries for a
    /// MOSFET (drain, source) and for every two-terminal passive — the gate is absent
    /// by construction, which is what makes the bridge test in `column.zig` a pure
    /// count of this slice.
    pub fn conductingPins(self: Ctx, d: DeviceIdx) []const PinIdx {
        return self.cond.slice(d);
    }

    /// Every pin on `n`, ascending by pin index.
    ///
    /// Ascending order is a contract, not an artifact: it is what makes
    /// "first pin of this net" a deterministic tie-break in column resolution and in
    /// the label fallback. Borrowed; valid until `deinit`.
    pub fn members(self: Ctx, n: NetIdx) []const PinIdx {
        return self.net_pins.slice(n);
    }

    /// `|pins on n|` — the net degree of ALGORITHM.md's Tier-A table.
    ///
    /// Stored implicitly as a CSR count rather than as its own array: it is one
    /// subtraction of two offsets already in cache, and a parallel `[]u32` would be a
    /// second copy of the same fact with a second chance to be wrong.
    ///
    /// This is the `N` in `optimal_len = N - (pins in the same column) - 1`.
    pub fn degree(self: Ctx, n: NetIdx) u32 {
        return self.net_pins.count(n);
    }

    /// Electrical class of `n`, decided by the symbol roles on it (see the header).
    pub fn classOfNet(self: Ctx, n: NetIdx) NetClass {
        return self.net_class[n.i()];
    }

    /// True when `n` is a ground net — the terminating condition of every spline walk.
    pub fn isGround(self: Ctx, n: NetIdx) bool {
        return self.classOfNet(n) == .ground;
    }

    /// True when `n` is power or ground rather than signal.
    ///
    /// Used wherever ALGORITHM.md says a rail abstains: rails reserve no gap lanes,
    /// cast no vote in bridge mirroring, and never resolve a bridge terminal to a
    /// column — "touches ground" says nothing about horizontal position.
    pub fn isRailNet(self: Ctx, n: NetIdx) bool {
        return self.classOfNet(n) != .signal;
    }

    /// Hop distance from `n` to the nearest ground net over conduction edges, or
    /// `unreachable_dist`.
    ///
    /// Two nets are adjacent when one device has conducting pins on both. Gate nets
    /// are therefore usually unreachable, which is correct: a bias net is not part of
    /// any conduction path and must never be walked as one.
    pub fn groundDistance(self: Ctx, n: NetIdx) u32 {
        return self.gnd_dist[n.i()];
    }

    /// Every power net, ascending by net index.
    ///
    /// Caller owns the returned slice and frees it with `gpa`. Ascending order is what
    /// makes spline seeding reproducible; a `HashMap` iteration here would silently
    /// reorder the whole spline set between runs, which is the determinism rule in
    /// ARCHITECTURE.md §7 and not a style preference.
    ///
    /// Returns an empty slice for a circuit with no supply symbol — the rail-less case
    /// that `spline.zig` falls back on.
    pub fn powerNets(self: Ctx, gpa: Allocator) Allocator.Error![]NetIdx {
        var n: usize = 0;
        for (self.net_class) |cls| {
            if (cls == .power) n += 1;
        }
        const out = try gpa.alloc(NetIdx, n);
        var w: usize = 0;
        for (self.net_class, 0..) |cls, k| {
            if (cls != .power) continue;
            out[w] = NetIdx.at(k);
            w += 1;
        }
        return out;
    }

    /// `branch_count(dev)` for every device: how many splines pass through it.
    ///
    /// A device is *shared* when this is at least 2, which is what drives the two
    /// placements ALGORITHM.md specifies — `N == 2` gets its own column between the two
    /// branches, `N > 2` anchors to the span-minimising branch. Devices on no spline
    /// (bridges, satellites, rail-less series elements) count 0.
    ///
    /// **Order-invariant**, and that is the whole reason this lives in Tier A: it
    /// counts membership in a fixed *set* of splines, and the order search only
    /// permutes that set. Computing it per candidate order would be identical work with
    /// an extra chance to drift.
    ///
    /// `u16` because the count cannot exceed the spline count; a schematic with more
    /// than 65535 splines is asserted against rather than handled, since the order
    /// search abandons exhaustive enumeration above `enum_limit` (default 10) anyway.
    ///
    /// Caller owns the returned slice, length `deviceCount()`, and frees it with `gpa`.
    /// Linear in the total spline length.
    pub fn branchCounts(self: Ctx, gpa: Allocator, splines: SplineSet) Allocator.Error![]u16 {
        std.debug.assert(splines.keyCount() <= std.math.maxInt(u16));
        const out = try gpa.alloc(u16, self.deviceCount());
        @memset(out, 0);
        for (splines.values) |d| out[d.i()] += 1;
        return out;
    }

    /// Check every invariant this type promises:
    ///
    /// - `pin_dev.len == pinCount()` and every entry is a valid device
    /// - `net_pins` covers `netCount()` keys and its values are ascending within a key
    /// - `cond` covers `deviceCount()` keys and every value is a conducting terminal
    /// - `net_class.len == gnd_dist.len == netCount()`
    /// - every ground net has `gnd_dist == 0`
    ///
    /// Panics on violation. These are producer bugs; letting a malformed `Ctx` reach
    /// the spline walk turns a clear failure into a mysterious drawing.
    pub fn assertValid(self: Ctx) void {
        const nd = self.deviceCount();
        std.debug.assert(self.pin_dev.len == self.pinCount());
        for (self.pin_dev) |d| std.debug.assert(d.i() < nd);

        std.debug.assert(self.net_pins.keyCount() == self.netCount());
        self.net_pins.assertValid();
        for (0..self.netCount()) |n| {
            const mem = self.net_pins.slice(NetIdx.at(n));
            for (mem, 0..) |p, k| {
                std.debug.assert(self.netOf(p) == NetIdx.at(n));
                if (k > 0) std.debug.assert(@intFromEnum(p) > @intFromEnum(mem[k - 1]));
            }
        }

        std.debug.assert(self.cond.keyCount() == nd);
        self.cond.assertValid();
        for (0..nd) |d| {
            for (self.cond.slice(DeviceIdx.at(d))) |p| {
                std.debug.assert(self.devOf(p) == DeviceIdx.at(d));
                std.debug.assert(self.conducts(p));
            }
        }

        std.debug.assert(self.net_class.len == self.netCount());
        std.debug.assert(self.gnd_dist.len == self.netCount());
        for (self.net_class, self.gnd_dist) |cls, dist| {
            if (cls == .ground) std.debug.assert(dist == 0);
        }
    }
};

/// Is this symbol role a supply glyph rather than a circuit element?
///
/// The one definition of "not a real device", used by `Ctx.isRail` and by `build`
/// before a `Ctx` exists to ask.
fn isRailRole(r: SymbolRole) bool {
    return r == .power_rail or r == .ground_rail;
}

/// Class lookup during `build`, where there is no `Ctx` to call `classOf` on.
fn classIn(ir: *const Ir, table: *const host.Table, d: DeviceIdx) DeviceClass {
    return table.at(ir.dev_symbol[d.i()]);
}
