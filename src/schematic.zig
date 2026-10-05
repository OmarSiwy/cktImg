//! Stages 1–4 of ALGORITHM.md: roles, orientation, wiring, supernodes.
//! Stage 5 (coordinates, and labels for joins that cycle or cross) is in
//! layout.zig; drawing is in draw.zig. Case ids in comments (R1, O3, W4, …)
//! refer to ALGORITHM.md.
//!
//! The output graph has three kinds of node: devices, terminal leaves (the
//! supply / sink / input / output nets) and labels. Nets are never nodes.
//! A net is realised as straight edges between facing pins, joins (bends
//! drawn by the layout), or labels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const netlist = @import("netlist.zig");
const csr = @import("csr.zig");
const library = @import("library.zig");

pub const Circuit = netlist.Circuit;
pub const DeviceKind = netlist.DeviceKind;
const EdgeId = csr.EdgeId;
const VertexId = csr.VertexId;

pub const none: u32 = std.math.maxInt(u32);
pub const no_pin: u8 = 0xff;
const unreached: u32 = std.math.maxInt(u32);
const mid_key: u64 = std.math.maxInt(u64) / 2;

// ===========================================================================
// Vocabulary
// ===========================================================================

pub const Side = library.Side;
pub const Library = library.Library;
pub const ClassId = library.ClassId;
pub const Orient = library.Orient;
pub const Pt = library.Pt;

pub const Orientation = enum(u1) { vertical, horizontal };

pub const Role = enum(u8) {
    internal,
    supply,
    sink,
    input,
    output,
    bias,

    /// When a join must give way (L4, L7), the net with the highest rank does
    /// so first; ties go to the later net.
    pub fn rank(r: Role) u8 {
        return switch (r) {
            .supply, .sink => 0,
            .input, .output => 1,
            .internal, .bias => 2,
        };
    }
};

// ===========================================================================
// Device pin sides, from each device's class (library.zig). The horizontal
// form is the class as drawn; the vertical form is it turned a quarter left.
// A pin with no side is not drawn (a MOS bulk, a terminal the class lacks) and
// does not count for paths.
// ===========================================================================

/// Card pins past this many are not drawn. A block has one per port, so it
/// is generous; a pin's index is a `u8` with `no_pin` reserved.
pub const max_pins = 64;

fn form(o: Orientation) Orient {
    return if (o == .vertical) .left else .r0;
}

fn baseSide(s: *const Schematic, d: u32, o: Orientation, pin: usize) ?Side {
    if (pin >= max_pins) return null;
    return s.lib.at(s.devices.items(.class)[d]).side(pin, form(o));
}

fn visible(s: *const Schematic, d: u32, pin: usize) bool {
    return baseSide(s, d, .vertical, pin) != null;
}

/// Has a left or right pin in its vertical form (gate, base, control input).
pub fn hasSidePin(s: *const Schematic, d: u32) bool {
    const c = s.lib.at(s.devices.items(.class)[d]);
    for (0..c.terminals.len) |i| if (c.side(i, .left)) |sd| if (sd.isHorizontal()) return true;
    return false;
}

// ===========================================================================
// Output types
// ===========================================================================

pub const PairHalf = enum(u2) { none, left, right };

pub const DeviceInfo = struct {
    /// In the schematic graph: drivers of terminal nets and pinless devices
    /// are not (R3).
    kept: bool,
    /// A source driving a terminal net from the sink (R3): drawn apart, as
    /// an island with its own terminal symbols (`Placed`).
    driver: bool,
    on_power_path: bool,
    on_signal_path: bool,
    orientation: Orientation,
    flip_x: bool,
    flip_y: bool,
    /// (distance from the inputs, index) and (distance from the supply, index).
    x_key: u64,
    y_key: u64,
    pair_half: PairHalf,
    /// What the device is drawn as (library.zig).
    class: ClassId,
    /// The class's placement: orientation and flips as mirror-and-rotate.
    orient: Orient,
    /// Where the device's row and column lines cross, from its origin: the
    /// x of its up/down pins and the y of its left/right pins, placed.
    grid: Pt,
    /// Per side (`@intFromEnum(Side)`): how far its pins reach from `grid`.
    reach: [4]i32,
};

pub const NodeKind = enum(u8) {
    device,
    terminal,
    label,
    /// A net's own branching point (J1, J2): no symbol, drawn as the bar its
    /// copies make.
    junction,
};

pub const Node = struct {
    kind: NodeKind,
    /// device: device index; terminal and label: net index.
    ref: u32,
    /// Supernode id: every copy shares the id of the node it was copied from.
    group: u32,
    /// Ordering keys along x and y (sorting copies, separating overlaps).
    x_key: u64,
    y_key: u64,
};

pub const Pin = struct {
    /// The node (or supernode copy) the pin is drawn on.
    home: u32,
    side: Side,
    net: u32,
    /// Device index, or `none` for a terminal, label or junction pin.
    device: u32,
    index: u8,
};

pub const EdgeKind = enum(u8) {
    /// Two facing pins of one net: `b` lies on side `side` of `a`.
    straight,
    /// Consecutive copies of one supernode.
    chain,
    /// A straight edge given up for labels (L7); ignored from then on.
    dropped,
};

pub const Edge = struct {
    kind: EdgeKind,
    a: u32,
    b: u32,
    /// Always `.right` or `.down`.
    side: Side,
    /// The net drawn along the edge; `none` for a chain inside a device.
    net: u32,
    pa: u32,
    pb: u32,
};

pub const JoinKind = enum(u8) {
    /// W3/W4: pin `p` runs in its direction until it meets wire (edge) `q`.
    tap,
    /// W5: pins `p` and `q` face perpendicular ways; their wires meet at a corner.
    corner,
    /// W6: vertical edge `p` and horizontal edge `q` of one net cross.
    cross,
    /// W7: pins `p` and `q` of one device are joined around the device.
    bend,
};

pub const Join = struct {
    kind: JoinKind,
    net: u32,
    p: u32,
    q: u32,
    active: bool,
};

pub const RouteKind = enum(u8) { edge, bar, join };

pub const Route = struct {
    pts: [6][2]f32,
    len: u8,
    net: u32,
    kind: RouteKind,
    id: u32,
    /// false: a straight edge the grid could not keep straight.
    straight: bool,
    /// Supernode groups the route belongs to (it may run through them).
    owners: [3]u32,
};

pub const Stats = struct {
    /// Straight edges drawn with bends (L2, L5).
    bent: u32 = 0,
    /// Order constraints dropped between straight edges (L5).
    conflicts: u32 = 0,
    /// Wires of different nets crossing.
    crossings: u32 = 0,
    /// Wires of different nets overlapping or touching, or a wire through a node.
    overlaps: u32 = 0,
    /// Nets drawn with labels.
    labeled_nets: u32 = 0,
    /// A rail's or junction's copies were re-dealt and laid out again (S5).
    redealt: bool = false,
    /// Level assignments over the whole layout, every pass and L6 round:
    /// the layout's work, which grows with the drawing, not its square.
    rounds: u32 = 0,
};

pub const Schematic = struct {
    arena: std.heap.ArenaAllocator,
    /// The classes devices are drawn as. Borrowed.
    lib: *const Library,
    // Borrowed from the circuit's heap storage: valid while the netlist
    // lives, however the Netlist and Schematic structs are moved.
    device_kind: []const DeviceKind,
    device_name: []const []const u8,
    net_name: []const []const u8,
    device_pin_count: []const u8,
    roles: []const Role,

    devices: std.MultiArrayList(DeviceInfo) = .empty,
    nodes: std.MultiArrayList(Node) = .empty,
    pins: std.MultiArrayList(Pin) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    joins: std.ArrayList(Join) = .empty,
    /// Per net: drawn with labels (W8, W9, L4, L7).
    labeled: []bool = &.{},
    /// Wired pieces of labelled nets, each named once: an edge id.
    annotations: std.ArrayList(u32) = .empty,

    // Filled by layout.zig.
    /// Grid cell (column, row) of each node: the order of rows and columns.
    pos: [][2]i32 = &.{},
    /// Where each node's row and column lines cross, in units: the grid with
    /// each gap between neighbouring rows or columns as wide as the wires in
    /// it need (§5, Geometry).
    xy: [][2]f32 = &.{},
    /// Device pins alone on their net (W10), drawn with a no-connect mark.
    no_connects: std.ArrayList(u32) = .empty,
    routes: std.ArrayList(Route) = .empty,
    dots: std.ArrayList([2]f32) = .empty,
    stats: Stats = .{},

    pub fn deinit(self: *Schematic) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// See `build`.
    pub const build = @import("schematic.zig").build;

    /// Side a device pin faces after orientation, flips and mirroring.
    pub fn pinSide(self: *const Schematic, d: u32, pin: usize) ?Side {
        const info = self.devices.get(d);
        var side = baseSide(self, d, info.orientation, pin) orelse return null;
        if (info.flip_x) side = side.flipX();
        if (info.flip_y) side = side.flipY();
        return side;
    }

    /// How far a node's pins facing `side` reach from its grid point, in the
    /// target's units: the class geometry for devices, zero for terminals,
    /// labels and junctions (they connect at their point).
    pub fn reach(self: *const Schematic, node: u32, side: Side) f32 {
        if (self.nodes.items(.kind)[node] != .device) return 0;
        const d = self.nodes.items(.ref)[node];
        return @floatFromInt(self.devices.items(.reach)[d][@intFromEnum(side)]);
    }

    /// Where a pin sits on its device's symbol, placed and relative to the
    /// device's grid point; null for terminal, label and junction pins.
    pub fn pinOffset(self: *const Schematic, p: u32) ?Pt {
        const d = self.pins.items(.device)[p];
        if (d == none) return null;
        const info = self.devices.get(d);
        const t = self.lib.at(info.class).terminals[self.pins.items(.index)[p]];
        return info.orient.apply(t.at).sub(info.grid);
    }

    /// The node a device's symbol is drawn on (its supernode's middle copy).
    pub fn deviceNode(self: *const Schematic, d: u32) ?u32 {
        const kinds = self.nodes.items(.kind);
        for (kinds, self.nodes.items(.ref), self.nodes.items(.group), 0..) |k, r, g, i| {
            if (k == .device and r == d and g == i) return @intCast(i);
        }
        return null;
    }

    pub fn terminalNode(self: *const Schematic, net: u32) ?u32 {
        for (self.nodes.items(.kind), self.nodes.items(.ref), self.nodes.items(.group), 0..) |k, r, g, i| {
            if (k == .terminal and r == net and g == i) return @intCast(i);
        }
        return null;
    }

    pub fn pinOf(self: *const Schematic, d: u32, index: u8) ?u32 {
        for (self.pins.items(.device), self.pins.items(.index), 0..) |dev, idx, i| {
            if (dev == d and idx == index) return @intCast(i);
        }
        return null;
    }

    /// A terminal leaf's own pin.
    pub fn isTerminalPin(self: *const Schematic, p: u32) bool {
        return self.nodes.items(.kind)[self.pins.items(.home)[p]] == .terminal;
    }

    /// The junction a pin belongs to (its supernode group), or `none`.
    pub fn junctionOf(self: *const Schematic, p: u32) u32 {
        const home = self.pins.items(.home)[p];
        if (self.nodes.items(.kind)[home] != .junction) return none;
        return self.nodes.items(.group)[home];
    }

    pub fn groupSize(self: *const Schematic, group: u32) u32 {
        var n: u32 = 0;
        for (self.nodes.items(.group)) |g| n += @intFromBool(g == group);
        return n;
    }

    pub fn addNode(self: *Schematic, node: Node) !u32 {
        const id: u32 = @intCast(self.nodes.len);
        var n = node;
        if (n.group == none) n.group = id;
        try self.nodes.append(self.arena.allocator(), n);
        return id;
    }

    pub fn addPin(self: *Schematic, pin: Pin) !u32 {
        const id: u32 = @intCast(self.pins.len);
        try self.pins.append(self.arena.allocator(), pin);
        return id;
    }

    pub fn addEdge(self: *Schematic, edge: Edge) !u32 {
        const id: u32 = @intCast(self.edges.items.len);
        try self.edges.append(self.arena.allocator(), edge);
        return id;
    }

    pub fn addJoin(self: *Schematic, join: Join) !u32 {
        const id: u32 = @intCast(self.joins.items.len);
        try self.joins.append(self.arena.allocator(), join);
        return id;
    }

    /// A straight edge between two facing pins, stored with `side` right/down.
    pub fn addStraight(self: *Schematic, p: u32, q: u32) !u32 {
        const sides = self.pins.items(.side);
        std.debug.assert(sides[p] == sides[q].opposite());
        const first, const second = if (sides[p] == .right or sides[p] == .down) .{ p, q } else .{ q, p };
        const homes = self.pins.items(.home);
        return self.addEdge(.{
            .kind = .straight,
            .a = homes[first],
            .b = homes[second],
            .side = sides[first],
            .net = self.pins.items(.net)[p],
            .pa = first,
            .pb = second,
        });
    }
};

// ===========================================================================
// Stage 1 — Roles (R1, R2)
// ===========================================================================

/// R1: by name. R2: nets driven from ground by a V source. Edit the result
/// freely before `build`.
pub fn guessRoles(gpa: Allocator, nl: *const netlist.Netlist) Allocator.Error![]Role {
    const circuit = &nl.graph;
    const names = circuit.vertices.items(.name);
    const roles = try gpa.alloc(Role, names.len);
    for (names, roles, 0..) |name, *r, i| r.* = if (i == 0) .sink else roleFromName(name);

    for (circuit.edges.items(.kind), 0..) |k, d| {
        if (k != .vsource) continue;
        const pins = circuit.members(EdgeId.from(d));
        if (pins.len < 2) continue;
        const a = pins[0].index();
        const b = pins[1].index();
        const driven = if (roles[b] == .sink) a else if (roles[a] == .sink) b else continue;
        if (roles[driven] != .internal) continue;
        roles[driven] = if (isSignalSource(nl, @intCast(d))) .input else .bias;
    }
    return roles;
}

fn roleFromName(name: []const u8) Role {
    const eqlAny = struct {
        fn f(n: []const u8, xs: []const []const u8) bool {
            for (xs) |x| if (std.mem.eql(u8, n, x)) return true;
            return false;
        }
    }.f;
    const startsAny = struct {
        fn f(n: []const u8, xs: []const []const u8) bool {
            for (xs) |x| if (std.mem.startsWith(u8, n, x)) return true;
            return false;
        }
    }.f;
    if (eqlAny(name, &.{ "gnd", "vss", "vee", "agnd", "dgnd", "vssa", "gnda" })) return .sink;
    if (startsAny(name, &.{ "vdd", "vcc", "avdd", "dvdd" }) or eqlAny(name, &.{"vpp"})) return .supply;
    if (startsAny(name, &.{ "vb", "bias" })) return .bias;
    if (startsAny(name, &.{ "vin", "in" })) return .input;
    if (startsAny(name, &.{ "vout", "out", "vref" }) or eqlAny(name, &.{"vo"})) return .output;
    return .internal;
}

fn isSignalSource(nl: *const netlist.Netlist, d: u32) bool {
    const signal_words = [_][]const u8{ "ac", "sin", "pulse", "pwl", "exp", "sffm", "am", "trnoise", "trrandom" };
    for (nl.params(EdgeId.from(d))) |tok| {
        for (signal_words) |w| if (std.mem.eql(u8, tok, w)) return true;
    }
    return false;
}

// ===========================================================================
// Entry point
// ===========================================================================

/// Netlist → schematic graph (stages 2–4). Each device is drawn as the
/// class `lib` has for it (a generated box when it has none, registered into
/// `lib`). `layout.layout` assigns coordinates afterwards.
pub fn build(gpa: Allocator, nl: *const netlist.Netlist, roles: []const Role, lib: *Library) !Schematic {
    const circuit = &nl.graph;
    std.debug.assert(roles.len == circuit.vertexCount());
    const classes = try gpa.alloc(ClassId, circuit.edgeCount());
    defer gpa.free(classes);
    for (classes, circuit.edges.items(.kind), 0..) |*c, k, d| {
        const e = EdgeId.from(d);
        c.* = if (nl.defOf(e)) |def| try lib.blockFor(def) else try lib.classFor(k, nl.modelType(e), circuit.members(e).len);
    }
    var s: Schematic = .{
        .arena = .init(gpa),
        .lib = lib,
        .device_kind = circuit.edges.items(.kind),
        .device_name = circuit.edges.items(.name),
        .net_name = circuit.vertices.items(.name),
        .device_pin_count = &.{},
        .roles = &.{},
    };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    s.roles = try a.dupe(Role, roles);
    const counts = try a.alloc(u8, circuit.edgeCount());
    for (counts, 0..) |*c, d| c.* = @intCast(circuit.members(EdgeId.from(d)).len);
    s.device_pin_count = counts;
    s.labeled = try a.alloc(bool, circuit.vertexCount());
    @memset(s.labeled, false);
    try s.devices.resize(a, circuit.edgeCount());
    @memcpy(s.devices.items(.class), classes);

    try orient(gpa, &s, circuit);
    try wire(gpa, &s, circuit);
    try splitSupernodes(gpa, &s);
    for (0..s.labeled.len) |n| {
        if (s.labeled[n]) try nameNet(gpa, &s, @intCast(n));
    }
    return s;
}

// ===========================================================================
// Stage 2 — Orientation (O1–O9)
// ===========================================================================

/// Simple undirected graph over [nets | devices | S | T] in CSR form with a
/// virtual edge S–T: path membership (blocks) and distances (BFS).
const Conn = struct {
    offsets: []u32,
    adj: []u32,
    eid: []u32,
    ends: [][2]u32,
    n_nets: u32,
    n_devs: u32,
    src: u32,
    dst: u32,
    special: u32,

    fn deinit(c: *Conn, gpa: Allocator) void {
        gpa.free(c.offsets);
        gpa.free(c.adj);
        gpa.free(c.eid);
        gpa.free(c.ends);
    }
};

fn buildConn(
    gpa: Allocator,
    s: *const Schematic,
    circuit: *const Circuit.Graph,
    include_dev: []const bool,
    net_ok: []const bool,
    is_src: []const bool,
    is_dst: []const bool,
) !Conn {
    const n_nets = circuit.vertexCount();
    const n_devs = circuit.edgeCount();
    const S = n_nets + n_devs;
    const T = S + 1;
    const nv = T + 1;
    var ends: std.ArrayList([2]u32) = .empty;
    errdefer ends.deinit(gpa);
    for (0..n_devs) |d| {
        if (!include_dev[d]) continue;
        var seen: [max_pins]u32 = undefined;
        var k: usize = 0;
        for (circuit.members(EdgeId.from(d)), 0..) |net, i| {
            if (!visible(s, @intCast(d), i)) continue;
            const n = net.index();
            if (!net_ok[n] or std.mem.indexOfScalar(u32, seen[0..k], n) != null) continue;
            seen[k] = n;
            k += 1;
            try ends.append(gpa, .{ n_nets + @as(u32, @intCast(d)), n });
        }
    }
    for (0..n_nets) |n| {
        if (is_src[n]) try ends.append(gpa, .{ S, @intCast(n) });
        if (is_dst[n]) try ends.append(gpa, .{ T, @intCast(n) });
    }
    const special: u32 = @intCast(ends.items.len);
    try ends.append(gpa, .{ S, T });

    const offsets = try gpa.alloc(u32, nv + 1);
    errdefer gpa.free(offsets);
    @memset(offsets, 0);
    for (ends.items) |e| {
        offsets[e[0] + 1] += 1;
        offsets[e[1] + 1] += 1;
    }
    for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
    const adj = try gpa.alloc(u32, offsets[nv]);
    errdefer gpa.free(adj);
    const eid = try gpa.alloc(u32, offsets[nv]);
    errdefer gpa.free(eid);
    const cursor = try gpa.dupe(u32, offsets[0..nv]);
    defer gpa.free(cursor);
    for (ends.items, 0..) |e, id| {
        adj[cursor[e[0]]] = e[1];
        eid[cursor[e[0]]] = @intCast(id);
        cursor[e[0]] += 1;
        adj[cursor[e[1]]] = e[0];
        eid[cursor[e[1]]] = @intCast(id);
        cursor[e[1]] += 1;
    }
    return .{
        .offsets = offsets,
        .adj = adj,
        .eid = eid,
        .ends = try ends.toOwnedSlice(gpa),
        .n_nets = n_nets,
        .n_devs = n_devs,
        .src = S,
        .dst = T,
        .special = special,
    };
}

/// Marks every device on some simple S→T path: exactly the biconnected block
/// containing the virtual edge S–T (Menger). One iterative Tarjan pass.
fn markPathDevices(gpa: Allocator, c: *const Conn, out: []bool) !void {
    @memset(out, false);
    const nv = c.offsets.len - 1;
    const disc = try gpa.alloc(u32, nv);
    defer gpa.free(disc);
    const low = try gpa.alloc(u32, nv);
    defer gpa.free(low);
    @memset(disc, unreached);

    const Frame = struct { v: u32, pe: u32, it: u32 };
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    var estack: std.ArrayList(u32) = .empty;
    defer estack.deinit(gpa);
    var block: std.ArrayList(u32) = .empty;
    defer block.deinit(gpa);

    var time: u32 = 0;
    disc[c.src] = 0;
    low[c.src] = 0;
    try frames.append(gpa, .{ .v = c.src, .pe = none, .it = c.offsets[c.src] });
    while (frames.items.len > 0) {
        const top = &frames.items[frames.items.len - 1];
        const v = top.v;
        if (top.it < c.offsets[v + 1]) {
            const k = top.it;
            top.it += 1;
            const w = c.adj[k];
            const e = c.eid[k];
            if (e == top.pe) continue;
            if (disc[w] == unreached) {
                time += 1;
                disc[w] = time;
                low[w] = time;
                try estack.append(gpa, e);
                try frames.append(gpa, .{ .v = w, .pe = e, .it = c.offsets[w] });
            } else if (disc[w] < disc[v]) {
                try estack.append(gpa, e);
                low[v] = @min(low[v], disc[w]);
            }
            continue;
        }
        const done = frames.pop().?;
        if (frames.items.len == 0) break;
        const u = frames.items[frames.items.len - 1].v;
        low[u] = @min(low[u], low[done.v]);
        if (low[done.v] < disc[u]) continue;
        block.clearRetainingCapacity();
        var has_special = false;
        while (estack.pop()) |e| {
            try block.append(gpa, e);
            has_special = has_special or e == c.special;
            if (e == done.pe) break;
        }
        if (!has_special) continue;
        for (block.items) |e| for (c.ends[e]) |x| {
            if (x >= c.n_nets and x < c.n_nets + c.n_devs) out[x - c.n_nets] = true;
        };
    }
}

fn bfsLevels(gpa: Allocator, c: *const Conn, start: u32) ![]u32 {
    const nv = c.offsets.len - 1;
    const level = try gpa.alloc(u32, nv);
    errdefer gpa.free(level);
    @memset(level, unreached);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);
    level[start] = 0;
    try queue.append(gpa, start);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const v = queue.items[head];
        for (c.offsets[v]..c.offsets[v + 1]) |k| {
            if (c.eid[k] == c.special) continue;
            const w = c.adj[k];
            if (level[w] != unreached) continue;
            level[w] = level[v] + 1;
            try queue.append(gpa, w);
        }
    }
    return level;
}

fn orient(gpa: Allocator, s: *Schematic, circuit: *const Circuit.Graph) !void {
    const n_nets = circuit.vertexCount();
    const n_devs = circuit.edgeCount();
    const roles = s.roles;

    const kept = s.devices.items(.kept);
    const on_power = s.devices.items(.on_power_path);
    const on_signal = s.devices.items(.on_signal_path);
    const orientation = s.devices.items(.orientation);
    const flip_x = s.devices.items(.flip_x);
    const flip_y = s.devices.items(.flip_y);
    const x_key = s.devices.items(.x_key);
    const y_key = s.devices.items(.y_key);
    @memset(s.devices.items(.pair_half), .none);

    // R3: a V source from a terminal net to the sink *is* that terminal.
    const drawable = try gpa.alloc(bool, n_devs);
    defer gpa.free(drawable);
    for (0..n_devs) |d| {
        var n_visible: usize = 0;
        for (0..circuit.members(EdgeId.from(d)).len) |i| n_visible += @intFromBool(visible(s, @intCast(d), i));
        drawable[d] = n_visible > 0;
        s.devices.items(.driver)[d] = drawable[d] and isDriver(circuit, roles, @intCast(d));
        kept[d] = drawable[d] and !s.devices.items(.driver)[d];
    }

    const masks = try gpa.alloc(bool, n_nets * 6);
    defer gpa.free(masks);
    const all_nets = masks[0..n_nets];
    const signal_nets = masks[n_nets .. 2 * n_nets];
    const is_supply = masks[2 * n_nets .. 3 * n_nets];
    const is_sink = masks[3 * n_nets .. 4 * n_nets];
    const is_input = masks[4 * n_nets .. 5 * n_nets];
    const is_output = masks[5 * n_nets .. 6 * n_nets];
    for (roles, 0..) |r, n| {
        all_nets[n] = true;
        // Supply, sink and bias nets are AC ground: signal paths don't cross them.
        signal_nets[n] = !(r == .supply or r == .sink or r == .bias);
        is_supply[n] = r == .supply;
        is_sink[n] = r == .sink;
        is_input[n] = r == .input;
        is_output[n] = r == .output;
    }

    // The power pass keeps drivers: a common-gate stage's DC path runs through
    // its input source. Distances use drawn devices only: through the Vdd
    // source, ground would look one hop from the supply.
    var power = try buildConn(gpa, s, circuit, drawable, all_nets, is_supply, is_sink);
    defer power.deinit(gpa);
    var drawn = try buildConn(gpa, s, circuit, kept, all_nets, is_supply, is_sink);
    defer drawn.deinit(gpa);
    var signal = try buildConn(gpa, s, circuit, kept, signal_nets, is_input, is_output);
    defer signal.deinit(gpa);

    try markPathDevices(gpa, &power, on_power);
    try markPathDevices(gpa, &signal, on_signal);
    const d_supply = try bfsLevels(gpa, &drawn, drawn.src);
    defer gpa.free(d_supply);
    const d_sink = try bfsLevels(gpa, &drawn, drawn.dst);
    defer gpa.free(d_sink);
    const d_in = try bfsLevels(gpa, &signal, signal.src);
    defer gpa.free(d_in);
    const d_out = try bfsLevels(gpa, &signal, signal.dst);
    defer gpa.free(d_out);

    for (0..n_devs) |d| {
        x_key[d] = (@as(u64, d_in[n_nets + d]) << 32) | d;
        y_key[d] = (@as(u64, d_supply[n_nets + d]) << 32) | d;

        // O1–O5; a subcircuit block keeps the shape it was given (O10).
        orientation[d] = if (s.device_kind[d] == .subckt)
            .horizontal
        else if (on_power[d] and on_signal[d])
            (if (hasSidePin(s, @intCast(d))) .vertical else .horizontal)
        else if (on_signal[d]) .horizontal else .vertical;

        // O6, O7: flip along the flow.
        const pins = circuit.members(EdgeId.from(d));
        flip_x[d] = false;
        flip_y[d] = false;
        if (orientation[d] == .vertical) {
            const up = minLevel(s, @intCast(d), d_supply, pins, .vertical, .up);
            const down = minLevel(s, @intCast(d), d_supply, pins, .vertical, .down);
            flip_y[d] = down < up or (down == up and minLevel(s, @intCast(d), d_sink, pins, .vertical, .up) < minLevel(s, @intCast(d), d_sink, pins, .vertical, .down));
        } else {
            const left = minLevel(s, @intCast(d), d_in, pins, .horizontal, .left);
            const right = minLevel(s, @intCast(d), d_in, pins, .horizontal, .right);
            flip_x[d] = right < left or (right == left and minLevel(s, @intCast(d), d_out, pins, .horizontal, .left) < minLevel(s, @intCast(d), d_out, pins, .horizontal, .right));
        }
    }

    const fixed = try gpa.alloc(bool, n_devs);
    defer gpa.free(fixed);
    @memset(fixed, false);
    differentialPairs(s, circuit, fixed);
    mirrorPairs(s, circuit, fixed);
    settle(s, circuit);
}

/// Each device's final placement: orientation and flips as one `Orient`,
/// and from it where its row and column lines cross and how far its drawn
/// pins reach on each side.
fn settle(s: *Schematic, circuit: *const Circuit.Graph) void {
    const info = s.devices.slice();
    for (0..circuit.edgeCount()) |d| {
        const o = Orient.flipped(form(info.items(.orientation)[d]), info.items(.flip_x)[d], info.items(.flip_y)[d]);
        info.items(.orient)[d] = o;
        const c = s.lib.at(info.items(.class)[d]);
        // The middle of the up/down pins' x and of the left/right pins' y:
        // with several pins on a side (S1) the middle copy's line, pin or not.
        var lo: [2]i32 = .{ std.math.maxInt(i32), std.math.maxInt(i32) };
        var hi: [2]i32 = .{ std.math.minInt(i32), std.math.minInt(i32) };
        const members = circuit.members(EdgeId.from(d));
        for (c.terminals, 0..) |t, i| {
            if (i >= members.len or referencePin(s, @intCast(d), i, members[i].index())) continue;
            const side = c.side(i, o) orelse continue;
            const p = o.apply(t.at);
            const ax: usize = if (side.isHorizontal()) 1 else 0;
            const v = if (ax == 0) p.x else p.y;
            lo[ax] = @min(lo[ax], v);
            hi[ax] = @max(hi[ax], v);
        }
        var grid: Pt = .zero;
        if (lo[0] <= hi[0]) grid.x = @divFloor(lo[0] + hi[0], 2);
        if (lo[1] <= hi[1]) grid.y = @divFloor(lo[1] + hi[1], 2);
        var reach: [4]i32 = @splat(0);
        for (c.terminals, 0..) |t, i| {
            if (i >= members.len or referencePin(s, @intCast(d), i, members[i].index())) continue;
            const side = c.side(i, o) orelse continue;
            const p = o.apply(t.at).sub(grid);
            const r: i32 = @intCast(if (side.isHorizontal()) @abs(p.x) else @abs(p.y));
            reach[@intFromEnum(side)] = @max(reach[@intFromEnum(side)], r);
        }
        info.items(.grid)[d] = grid;
        info.items(.reach)[d] = reach;
    }
}

/// One device's down pin and the other's up pin share a net: one sits on
/// top of the other (an inverter's two transistors), not beside it.
fn stacked(s: *const Schematic, circuit: *const Circuit.Graph, a: u32, b: u32) bool {
    return stackedAlong(s, circuit, a, b, true);
}

/// `stacked` along either axis: `vertical` links a down pin to an up pin,
/// otherwise a right pin to a left pin.
fn stackedAlong(s: *const Schematic, circuit: *const Circuit.Graph, a: u32, b: u32, vertical: bool) bool {
    for (circuit.members(EdgeId.from(a)), 0..) |na, i| {
        const sa = s.pinSide(a, i) orelse continue;
        if (sa.isHorizontal() == vertical) continue;
        for (circuit.members(EdgeId.from(b)), 0..) |nb, k| {
            const sb = s.pinSide(b, k) orelse continue;
            if (na.index() == nb.index() and sb == sa.opposite()) return true;
        }
    }
    return false;
}

fn isDriver(circuit: *const Circuit.Graph, roles: []const Role, d: u32) bool {
    if (circuit.edges.items(.kind)[d] != .vsource) return false;
    const pins = circuit.members(EdgeId.from(d));
    if (pins.len < 2) return false;
    const a = roles[pins[0].index()];
    const b = roles[pins[1].index()];
    const terminal = struct {
        fn f(r: Role) bool {
            return r == .supply or r == .input or r == .bias;
        }
    }.f;
    return (b == .sink and terminal(a)) or (a == .sink and terminal(b));
}

fn minLevel(s: *const Schematic, d: u32, level: []const u32, pins: []const VertexId, o: Orientation, want: Side) u32 {
    var best: u32 = unreached;
    for (pins, 0..) |net, i| {
        if (baseSide(s, d, o, i) == want) best = @min(best, level[net.index()]);
    }
    return best;
}

/// O9: an internal net joining the up/down pins of exactly two vertical
/// devices whose side pins go to two different input nets. The right one is
/// mirrored so both inputs face outwards.
fn differentialPairs(s: *Schematic, circuit: *const Circuit.Graph, fixed: []bool) void {
    const kept = s.devices.items(.kept);
    const orientation = s.devices.items(.orientation);
    const flip_x = s.devices.items(.flip_x);
    const x_key = s.devices.items(.x_key);
    const half = s.devices.items(.pair_half);

    for (s.roles, 0..) |role, n| {
        if (role != .internal) continue;
        var dev: [2]u32 = undefined;
        var input: [2]u32 = undefined;
        var gate_side: [2]Side = undefined;
        var count: usize = 0;
        for (circuit.incident(VertexId.from(n))) |e| {
            const d = e.index();
            if (!kept[d] or orientation[d] != .vertical or fixed[d]) continue;
            if (count > 0 and dev[count - 1] == d) continue;
            var on_tail = false;
            var gate: ?struct { net: u32, side: Side } = null;
            for (circuit.members(e), 0..) |net, i| {
                const sd = s.pinSide(d, i) orelse continue;
                if (net.index() == n and !sd.isHorizontal()) on_tail = true;
                if (sd.isHorizontal() and s.roles[net.index()] == .input) gate = .{ .net = net.index(), .side = sd };
            }
            const g = gate orelse continue;
            if (!on_tail) continue;
            if (count == 2) {
                count = 3;
                break;
            }
            dev[count] = d;
            input[count] = g.net;
            gate_side[count] = g.side;
            count += 1;
        }
        if (count != 2 or input[0] == input[1]) continue;
        const lo: usize = if (x_key[dev[0]] <= x_key[dev[1]]) 0 else 1;
        const hi = 1 - lo;
        if (gate_side[lo] == .right) flip_x[dev[lo]] = !flip_x[dev[lo]];
        if (gate_side[hi] == .left) flip_x[dev[hi]] = !flip_x[dev[hi]];
        half[dev[lo]] = .left;
        half[dev[hi]] = .right;
        fixed[dev[lo]] = true;
        fixed[dev[hi]] = true;
    }
}

/// O8: an internal net joining the side pins of exactly two vertical
/// devices that are not stacked: the left one faces right, the right one
/// faces left.
fn mirrorPairs(s: *Schematic, circuit: *const Circuit.Graph, fixed: []bool) void {
    const kept = s.devices.items(.kept);
    const orientation = s.devices.items(.orientation);
    const flip_x = s.devices.items(.flip_x);
    const x_key = s.devices.items(.x_key);

    for (s.roles, 0..) |role, n| {
        if (role != .internal) continue;
        var dev: [2]u32 = undefined;
        var side: [2]Side = undefined;
        var count: usize = 0;
        outer: for (circuit.incident(VertexId.from(n))) |e| {
            const d = e.index();
            if (!kept[d] or orientation[d] != .vertical) continue;
            for (circuit.members(e), 0..) |net, i| {
                if (net.index() != n) continue;
                const sd = s.pinSide(d, i) orelse continue;
                if (!sd.isHorizontal()) continue;
                if (count > 0 and dev[count - 1] == d) continue;
                if (count == 2) {
                    count = 3;
                    break :outer;
                }
                dev[count] = d;
                side[count] = sd;
                count += 1;
            }
        }
        if (count != 2 or stacked(s, circuit, dev[0], dev[1])) continue;
        const lo: usize = if (x_key[dev[0]] <= x_key[dev[1]]) 0 else 1;
        const hi = 1 - lo;
        if (!fixed[dev[lo]] and side[lo] == .left) flip_x[dev[lo]] = !flip_x[dev[lo]];
        if (!fixed[dev[hi]] and side[hi] == .right) flip_x[dev[hi]] = !flip_x[dev[hi]];
        fixed[dev[lo]] = true;
        fixed[dev[hi]] = true;
    }
}

// ===========================================================================
// Stage 3 — Wiring (W1–W10)
// ===========================================================================

fn wire(gpa: Allocator, s: *Schematic, circuit: *const Circuit.Graph) !void {
    const n_nets = circuit.vertexCount();
    const kept = s.devices.items(.kept);

    for (0..circuit.edgeCount()) |d| {
        if (!kept[d]) continue;
        const info = s.devices.get(d);
        const node = try s.addNode(.{ .kind = .device, .ref = @intCast(d), .group = none, .x_key = info.x_key, .y_key = info.y_key });
        for (circuit.members(EdgeId.from(d)), 0..) |net, i| {
            const side = s.pinSide(@intCast(d), i) orelse continue;
            if (referencePin(s, @intCast(d), i, net.index())) continue;
            _ = try s.addPin(.{ .home = node, .side = side, .net = net.index(), .device = @intCast(d), .index = @intCast(i) });
        }
    }

    // One leaf per terminal net that a drawn pin touches; W8 labels bias nets.
    const has_pin = try gpa.alloc(bool, n_nets);
    defer gpa.free(has_pin);
    @memset(has_pin, false);
    for (s.pins.items(.net)) |n| has_pin[n] = true;
    for (s.roles, 0..) |role, n| {
        if (role == .internal or !has_pin[n]) continue;
        if (role == .bias) {
            s.labeled[n] = true;
            continue;
        }
        const side = leafSide(s, role, @intCast(n));
        const node = try s.addNode(.{
            .kind = .terminal,
            .ref = @intCast(n),
            .group = none,
            .x_key = switch (side) {
                .right => 0,
                .left => std.math.maxInt(u64),
                else => mid_key,
            },
            .y_key = switch (side) {
                .down => 0,
                .up => std.math.maxInt(u64),
                else => mid_key,
            },
        });
        _ = try s.addPin(.{ .home = node, .side = side, .net = @intCast(n), .device = none, .index = no_pin });
    }

    try junctions(gpa, s, circuit);

    const order = try gpa.alloc(u32, s.pins.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const nets = s.pins.items(.net);
    std.mem.sort(u32, order, nets, struct {
        fn lt(ns: []const u32, x: u32, y: u32) bool {
            return if (ns[x] != ns[y]) ns[x] < ns[y] else x < y;
        }
    }.lt);
    const local = try gpa.alloc(u32, s.pins.len);
    defer gpa.free(local);
    var i: usize = 0;
    while (i < order.len) {
        var j = i;
        while (j < order.len and nets[order[j]] == nets[order[i]]) j += 1;
        const net = nets[order[i]];
        if (!s.labeled[net]) try wireNet(gpa, s, net, order[i..j], local);
        i = j;
    }
    leafKeys(s);
}

/// A terminal leaf sorts right beside the device it is wired to: its
/// partner's keys, one step towards the side it sits on (L6, L8).
fn leafKeys(s: *Schematic) void {
    const kinds = s.nodes.items(.kind);
    const x_key = s.nodes.items(.x_key);
    const y_key = s.nodes.items(.y_key);
    const homes = s.pins.items(.home);
    const sides = s.pins.items(.side);
    for (s.pins.items(.device), 0..) |d, p| {
        if (d != none or kinds[homes[p]] != .terminal) continue;
        var partner: u32 = none;
        for (s.edges.items) |e| {
            if (e.kind != .straight) continue;
            if (e.pa == p) partner = e.b;
            if (e.pb == p) partner = e.a;
            if (partner != none) break;
        }
        if (partner == none) for (s.joins.items) |j| {
            if (j.kind == .tap and j.p == p) partner = s.edges.items[j.q].a;
            if (j.kind == .corner and j.p == p) partner = homes[j.q];
            if (j.kind == .corner and j.q == p) partner = homes[j.p];
            if (partner != none) break;
        };
        if (partner == none or kinds[partner] == .terminal or kinds[partner] == .label) continue;
        const t = homes[p];
        x_key[t] = x_key[partner];
        y_key[t] = y_key[partner];
        // The leaf's pin faces its partner, so the leaf sits the other way.
        switch (sides[p]) {
            .left => x_key[t] +|= 1,
            .right => x_key[t] -|= 1,
            .up => y_key[t] +|= 1,
            .down => y_key[t] -|= 1,
        }
    }
}

/// O0: a controlled source's out- on the sink is the op-amp's reference;
/// like a MOS bulk it counts for paths but is not drawn.
fn referencePin(s: *const Schematic, d: u32, pin: usize, net: u32) bool {
    const c = s.lib.at(s.devices.items(.class)[d]);
    return pin < c.terminals.len and c.terminals[pin].ground_ref and s.roles[net] == .sink;
}

/// The side a terminal leaf's own pin faces. O9: an input faces the gates it
/// drives (so a mirrored gate's input sits on the right); an output taken
/// from the left half of a differential pair sits on the left.
fn leafSide(s: *const Schematic, role: Role, net: u32) Side {
    var faces_left = false;
    var faces_right = false;
    var left_half = false;
    const half = s.devices.items(.pair_half);
    for (s.pins.items(.net), s.pins.items(.side), s.pins.items(.device)) |n, side, d| {
        if (n != net) continue;
        faces_left = faces_left or side == .left;
        faces_right = faces_right or side == .right;
        if (d != none and half[d] == .left) left_half = true;
    }
    return switch (role) {
        .supply => .down,
        .sink => .up,
        .input, .bias => if (faces_right and !faces_left) .left else .right,
        .output => if (left_half) .right else .left,
        .internal => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Junctions (J1, J2)
// ---------------------------------------------------------------------------

/// J1, J2: groups of same-facing pins that a bar joins better than a fan
/// from a terminal or a label per pin. Each becomes a junction node on the
/// side the group faces: a fan pin wired to every pin of the group (S2 turns
/// it into a bar) and a back pin facing on, which the rest of the net meets.
fn junctions(gpa: Allocator, s: *Schematic, circuit: *const Circuit.Graph) !void {
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    var group: std.ArrayList(u32) = .empty;
    defer group.deinit(gpa);
    const n_pins: u32 = @intCast(s.pins.len);
    for (0..s.net_name.len) |net| {
        if (s.labeled[net]) continue;
        ids.clearRetainingCapacity();
        for (s.pins.items(.net)[0..n_pins], 0..) |pn, p| if (pn == net) try ids.append(gpa, @intCast(p));
        if (ids.items.len < 3) continue;
        var count: [4]u32 = @splat(0);
        for (ids.items) |p| count[@intFromEnum(s.pins.items(.side)[p])] += 1;

        for ([_]Side{ .left, .right, .up, .down }) |face| {
            const back = face.opposite();
            const across: [2]Side = if (face.isHorizontal()) .{ .up, .down } else .{ .left, .right };
            const other_axis_pairs = count[@intFromEnum(across[0])] > 0 and count[@intFromEnum(across[1])] > 0;
            group.clearRetainingCapacity();
            for (ids.items) |p| if (s.pins.items(.side)[p] == face) try group.append(gpa, p);
            if (group.items.len < 2) continue;

            if (count[@intFromEnum(back)] == 0) {
                // J2: nothing faces the group, and its devices stand in one stack.
                if (!oneStack(gpa, s, circuit, group.items, face.isHorizontal())) continue;
                _ = try addJunction(s, @intCast(net), group.items, face);
                break;
            }
            // J1: the only pin facing the group is an input or output leaf, and
            // no wire of the other axis will be there for the group to tap.
            if (count[@intFromEnum(back)] != 1 or other_axis_pairs) continue;
            const leaf = for (ids.items) |p| {
                if (s.pins.items(.side)[p] == back) break p;
            } else unreachable;
            if (!s.isTerminalPin(leaf)) continue;
            const role = s.roles[net];
            if (role != .input and role != .output) continue;
            const b = try addJunction(s, @intCast(net), group.items, face);
            _ = try s.addStraight(leaf, b);
            break;
        }
    }
}

/// A junction on side `face` of `group` (pins that face `face`): its fan pin
/// is wired to each of them. Returns its back pin.
fn addJunction(s: *Schematic, net: u32, group: []const u32, face: Side) !u32 {
    const homes = s.pins.items(.home);
    const x_keys = s.nodes.items(.x_key);
    const y_keys = s.nodes.items(.y_key);
    // Keys: just past the group on the side it faces, level with its middle.
    var lo: [2]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64) };
    var hi: [2]u64 = .{ 0, 0 };
    for (group) |p| {
        const k = [2]u64{ x_keys[homes[p]], y_keys[homes[p]] };
        for (0..2) |a| {
            lo[a] = @min(lo[a], k[a]);
            hi[a] = @max(hi[a], k[a]);
        }
    }
    const mid: [2]u64 = .{ lo[0] + (hi[0] - lo[0]) / 2, lo[1] + (hi[1] - lo[1]) / 2 };
    const key: [2]u64 = switch (face) {
        .left => .{ lo[0] -| 1, mid[1] },
        .right => .{ hi[0] +| 1, mid[1] },
        .up => .{ mid[0], lo[1] -| 1 },
        .down => .{ mid[0], hi[1] +| 1 },
    };
    const node = try s.addNode(.{ .kind = .junction, .ref = net, .group = none, .x_key = key[0], .y_key = key[1] });
    const fan = try s.addPin(.{ .home = node, .side = face.opposite(), .net = net, .device = none, .index = no_pin });
    const back = try s.addPin(.{ .home = node, .side = face, .net = net, .device = none, .index = no_pin });
    for (group) |p| _ = try s.addStraight(fan, p);
    return back;
}

/// The group's devices stand in one stack along the axis across `horizontal`
/// pins (a vertical stack for pins facing left or right), each linked to the
/// rest through `stacked`.
fn oneStack(gpa: Allocator, s: *const Schematic, circuit: *const Circuit.Graph, group: []const u32, horizontal: bool) bool {
    var devs: [16]u32 = undefined;
    if (group.len > devs.len) return false;
    for (group, 0..) |p, i| {
        devs[i] = s.pins.items(.device)[p];
        if (devs[i] == none) return false;
        for (devs[0..i]) |d| if (d == devs[i]) return false;
    }
    _ = gpa;
    // Grow one component from the first device.
    var in: [16]bool = @splat(false);
    in[0] = true;
    var grew = true;
    while (grew) {
        grew = false;
        for (0..group.len) |i| {
            if (in[i]) continue;
            for (0..group.len) |k| {
                if (!in[k] or !stackedAlong(s, circuit, devs[i], devs[k], horizontal)) continue;
                in[i] = true;
                grew = true;
                break;
            }
        }
    }
    for (in[0..group.len]) |x| if (!x) return false;
    return true;
}

const NetWiring = struct {
    gpa: Allocator,
    s: *Schematic,
    net: u32,
    ids: []const u32,
    local: []const u32,
    parent: []u32,
    paired: []bool,
    tapped: []bool,
    edges: std.ArrayList(u32) = .empty,

    fn find(w: *NetWiring, start: usize) usize {
        var i = start;
        while (w.parent[i] != i) {
            w.parent[i] = w.parent[w.parent[i]];
            i = w.parent[i];
        }
        return i;
    }
    fn unite(w: *NetWiring, i: usize, j: usize) void {
        w.parent[w.find(i)] = @intCast(w.find(j));
    }
    fn components(w: *NetWiring) usize {
        var n: usize = 0;
        for (0..w.ids.len) |i| n += @intFromBool(w.find(i) == i);
        return n;
    }
    fn side(w: *const NetWiring, i: usize) Side {
        return w.s.pins.items(.side)[w.ids[i]];
    }
    fn device(w: *const NetWiring, i: usize) u32 {
        return w.s.pins.items(.device)[w.ids[i]];
    }
    fn key(w: *const NetWiring, i: usize, x_axis: bool) u64 {
        const home = w.s.pins.items(.home)[w.ids[i]];
        return if (x_axis) w.s.nodes.items(.x_key)[home] else w.s.nodes.items(.y_key)[home];
    }
    fn sameDev(w: *const NetWiring, i: usize, j: usize) bool {
        return w.device(i) != none and w.device(i) == w.device(j);
    }
    /// A transistor-like device: part of the stack a straight wire should follow.
    fn spine(w: *const NetWiring, i: usize) bool {
        const d = w.device(i);
        return d != none and hasSidePin(w.s, d);
    }
    fn endOf(w: *const NetWiring, e: u32) usize {
        return w.local[w.s.edges.items[e].pa];
    }
    fn straight(w: *NetWiring, i: usize, j: usize) !void {
        const e = try w.s.addStraight(w.ids[i], w.ids[j]);
        try w.edges.append(w.gpa, e);
        w.paired[i] = true;
        w.paired[j] = true;
        w.unite(i, j);
    }
    fn join(w: *NetWiring, kind: JoinKind, p: u32, q: u32, i: usize, j: usize) !void {
        _ = try w.s.addJoin(.{ .kind = kind, .net = w.net, .p = p, .q = q, .active = true });
        w.unite(i, j);
    }
    /// A wire of this net perpendicular to pin i's direction, in another
    /// component, not ending on pin i's own node (a tap needs the pin's node
    /// strictly between the wire's ends).
    fn perpendicularWire(w: *NetWiring, i: usize) ?u32 {
        const home = w.s.pins.items(.home)[w.ids[i]];
        for (w.edges.items) |e| {
            const edge = w.s.edges.items[e];
            if (edge.side.isHorizontal() == w.side(i).isHorizontal()) continue;
            if (edge.a == home or edge.b == home) continue;
            if (w.find(w.endOf(e)) != w.find(i)) return e;
        }
        return null;
    }
    /// W1: a straight wire from pin i to pin j would join two devices that
    /// a straight wire already joins along the other axis. No placement
    /// keeps both straight (one would be bent, L2), so j is left for a
    /// bend to its own device.
    fn crossPaired(w: *const NetWiring, i: usize, j: usize) bool {
        const di = w.device(i);
        const dj = w.device(j);
        if (di == none or dj == none) return false;
        const devices = w.s.pins.items(.device);
        const horizontal = w.side(i).isHorizontal();
        for (w.s.edges.items) |e| {
            if (e.kind != .straight or e.side.isHorizontal() == horizontal) continue;
            const a = devices[e.pa];
            const b = devices[e.pb];
            if ((a == di and b == dj) or (a == dj and b == di)) return true;
        }
        return false;
    }
    /// Another pin of the same device in another component; perpendicular first.
    fn sameDevice(w: *NetWiring, i: usize) ?usize {
        const d = w.device(i);
        if (d == none) return null;
        var fallback: ?usize = null;
        for (0..w.ids.len) |j| {
            if (j == i or w.device(j) != d or w.find(j) == w.find(i)) continue;
            if (w.side(j).perpendicular(w.side(i))) return j;
            fallback = fallback orelse j;
        }
        return fallback;
    }
    fn lonePerpendicular(w: *NetWiring, i: usize) ?usize {
        for (0..w.ids.len) |j| {
            if (j == i or w.paired[j] or w.tapped[j] or w.find(j) == w.find(i)) continue;
            if (w.side(j).perpendicular(w.side(i))) return j;
        }
        return null;
    }

    fn sortByKey(w: *const NetWiring, list: []usize, x_axis: bool) void {
        const Ctx = struct { w: *const NetWiring, x: bool };
        std.mem.sort(usize, list, Ctx{ .w = w, .x = x_axis }, struct {
            fn lt(c: Ctx, a: usize, b: usize) bool {
                const ka = c.w.key(a, c.x);
                const kb = c.w.key(b, c.x);
                return if (ka != kb) ka < kb else a < b;
            }
        }.lt);
    }

    /// W6/W7 between wired pieces.
    fn joinClusters(w: *NetWiring) !void {
        for (0..w.ids.len) |i| {
            if (!w.paired[i]) continue;
            for (i + 1..w.ids.len) |j| {
                if (!w.paired[j] or w.device(i) == none or w.device(i) != w.device(j) or w.find(i) == w.find(j)) continue;
                try w.join(.bend, w.ids[i], w.ids[j], i, j);
            }
        }
        for (w.edges.items) |ev| {
            if (w.s.edges.items[ev].side != .down or w.fanEdge(ev)) continue;
            for (w.edges.items) |eh| {
                if (w.s.edges.items[eh].side != .right or w.fanEdge(eh)) continue;
                if (w.find(w.endOf(ev)) == w.find(w.endOf(eh))) continue;
                try w.join(.cross, ev, eh, w.endOf(ev), w.endOf(eh));
            }
        }
    }

    /// A junction's fan: a stub from its bar to one pin of its group. The
    /// junction meets the rest of the net through its back pin, never by a
    /// cross through these.
    fn fanEdge(w: *const NetWiring, e: u32) bool {
        const edge = w.s.edges.items[e];
        return w.s.junctionOf(edge.pa) != none or w.s.junctionOf(edge.pb) != none;
    }

    /// J1, J2: a junction's back pin taps a wire of the net, or turns a
    /// corner to a lone pin, before any other join.
    fn joinJunctions(w: *NetWiring) !void {
        for (0..w.ids.len) |i| {
            if (w.paired[i] or w.tapped[i] or w.s.junctionOf(w.ids[i]) == none) continue;
            if (w.perpendicularWire(i)) |e| {
                try w.join(.tap, w.ids[i], e, i, w.endOf(e));
                w.tapped[i] = true;
            } else if (w.lonePerpendicular(i)) |j| {
                try w.join(.corner, w.ids[i], w.ids[j], i, j);
            }
        }
    }

    /// W7, W4, W5 for pins with no wire of their own.
    fn joinLone(w: *NetWiring) !void {
        for (0..w.ids.len) |i| {
            if (w.paired[i] or w.tapped[i]) continue;
            if (w.components() == 1) return;
            if (w.sameDevice(i)) |j| {
                try w.join(.bend, w.ids[i], w.ids[j], i, j);
            } else if (w.perpendicularWire(i)) |e| {
                try w.join(.tap, w.ids[i], e, i, w.endOf(e));
            } else if (w.lonePerpendicular(i)) |j| {
                try w.join(.corner, w.ids[i], w.ids[j], i, j);
            }
        }
    }
};

fn wireNet(gpa: Allocator, s: *Schematic, net: u32, ids: []const u32, local: []u32) !void {
    if (ids.len < 2) return; // W10
    for (ids, 0..) |id, i| local[id] = @intCast(i);
    const parent = try gpa.alloc(u32, ids.len);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const flags = try gpa.alloc(bool, 2 * ids.len);
    defer gpa.free(flags);
    @memset(flags, false);
    var w: NetWiring = .{
        .gpa = gpa,
        .s = s,
        .net = net,
        .ids = ids,
        .local = local,
        .parent = parent,
        .paired = flags[0..ids.len],
        .tapped = flags[ids.len..],
    };
    defer w.edges.deinit(gpa);
    // A junction's pins are one point; its fans (J1, J2) are wired already.
    for (0..ids.len) |i| for (i + 1..ids.len) |j| {
        if (s.junctionOf(ids[i]) != none and s.junctionOf(ids[i]) == s.junctionOf(ids[j])) w.unite(i, j);
    };
    for (s.edges.items, 0..) |e, id| {
        if (e.kind != .straight or e.net != net) continue;
        const i = local[e.pa];
        const j = local[e.pb];
        try w.edges.append(gpa, @intCast(id));
        w.paired[i] = true;
        w.paired[j] = true;
        w.unite(i, j);
    }

    // W1/W2: per axis, the pins facing down (right) meet the pins facing up
    // (left). The smaller side's pins are the hubs.
    var unpaired: std.ArrayList([2]usize) = .empty;
    defer unpaired.deinit(gpa);
    var groups: [2]std.ArrayList(usize) = .{ .empty, .empty };
    defer for (&groups) |*g| g.deinit(gpa);
    for ([_]Side{ .down, .right }) |a_side| {
        for (&groups) |*g| g.clearRetainingCapacity();
        for (0..ids.len) |i| {
            if (w.paired[i]) continue;
            if (w.side(i) == a_side) try groups[0].append(gpa, i);
            if (w.side(i) == a_side.opposite()) try groups[1].append(gpa, i);
        }
        if (groups[0].items.len == 0 or groups[1].items.len == 0) continue;
        const x_axis = a_side == .down; // a vertical group spreads along x
        w.sortByKey(groups[0].items, x_axis);
        w.sortByKey(groups[1].items, x_axis);
        const hubs, const partners = if (groups[0].items.len <= groups[1].items.len)
            .{ groups[0].items, groups[1].items }
        else
            .{ groups[1].items, groups[0].items };
        // Each hub, in order, takes its best free partner: a transistor if
        // any, never a pin of its own device (those get a bend, W7). With
        // one hub this is W1/W2; with several on both sides, a matching.
        const used = try gpa.alloc(bool, partners.len);
        defer gpa.free(used);
        @memset(used, false);
        var first_hub: ?usize = null;
        for (hubs) |h| {
            var best: ?usize = null;
            for (partners, 0..) |p, k| {
                if (used[k] or w.sameDev(h, p) or w.crossPaired(h, p)) continue;
                if (best == null or (w.spine(p) and !w.spine(partners[best.?]))) best = k;
            }
            const k = best orelse continue;
            used[k] = true;
            try w.straight(h, partners[k]);
            first_hub = first_hub orelse h;
        }
        const hub = first_hub orelse continue;
        for (partners, used) |p, u| {
            if (!u and !w.sameDev(hub, p) and !w.crossPaired(hub, p)) try unpaired.append(gpa, .{ p, hub });
        }
    }

    // W3 / W2: the rest of a group taps a perpendicular wire if the net has
    // one, otherwise fans out from the hub (which S2 turns into a bar).
    for (unpaired.items) |u| {
        const i, const hub = u;
        if (w.perpendicularWire(i)) |e| {
            try w.join(.tap, ids[i], e, i, w.endOf(e));
            w.tapped[i] = true;
        } else {
            try w.straight(hub, i);
        }
    }

    try w.joinJunctions();
    try w.joinClusters();
    try w.joinLone();
    try w.joinClusters();
    if (w.components() > 1) s.labeled[net] = true; // W9
}

// ===========================================================================
// Stage 4 — Supernodes (S1–S4)
// ===========================================================================

const Point = struct {
    kind: enum(u2) { edge_a, edge_b, pin },
    id: u32,

    fn side(p: Point, s: *const Schematic) Side {
        return switch (p.kind) {
            .edge_a => s.edges.items[p.id].side,
            .edge_b => s.edges.items[p.id].side.opposite(),
            .pin => s.pins.items(.side)[p.id],
        };
    }
    fn pin(p: Point, s: *const Schematic) u32 {
        return switch (p.kind) {
            .edge_a => s.edges.items[p.id].pa,
            .edge_b => s.edges.items[p.id].pb,
            .pin => p.id,
        };
    }
    fn partner(p: Point, s: *const Schematic) u32 {
        return switch (p.kind) {
            .edge_a => s.edges.items[p.id].b,
            .edge_b => s.edges.items[p.id].a,
            .pin => none,
        };
    }
};

/// S1/S2: a node with more than one attachment on a side (several pins
/// there, or one pin with several straight edges) becomes a supernode:
/// copies chained perpendicular to that side, one attachment per copy.
fn splitSupernodes(gpa: Allocator, s: *Schematic) !void {
    const pin_edges = try gpa.alloc(u32, s.pins.len);
    defer gpa.free(pin_edges);
    @memset(pin_edges, 0);
    for (s.edges.items) |e| {
        if (e.kind != .straight) continue;
        pin_edges[e.pa] += 1;
        pin_edges[e.pb] += 1;
    }

    const Work = struct { node: u32, start: u32, len: u32 };
    const Tagged = struct { node: u32, pt: Point };
    var pool: std.ArrayList(Point) = .empty;
    defer pool.deinit(gpa);
    var work: std.ArrayList(Work) = .empty;
    defer work.deinit(gpa);
    {
        var all: std.ArrayList(Tagged) = .empty;
        defer all.deinit(gpa);
        for (s.edges.items, 0..) |e, id| {
            try all.append(gpa, .{ .node = e.a, .pt = .{ .kind = .edge_a, .id = @intCast(id) } });
            try all.append(gpa, .{ .node = e.b, .pt = .{ .kind = .edge_b, .id = @intCast(id) } });
        }
        for (s.pins.items(.home), 0..) |home, p| {
            if (pin_edges[p] == 0) try all.append(gpa, .{ .node = home, .pt = .{ .kind = .pin, .id = @intCast(p) } });
        }
        std.mem.sort(Tagged, all.items, {}, struct {
            fn lt(_: void, x: Tagged, y: Tagged) bool {
                return x.node < y.node;
            }
        }.lt);
        var i: usize = 0;
        while (i < all.items.len) {
            var j = i;
            while (j < all.items.len and all.items[j].node == all.items[i].node) j += 1;
            const start: u32 = @intCast(pool.items.len);
            for (all.items[i..j]) |x| try pool.append(gpa, x.pt);
            try work.append(gpa, .{ .node = all.items[i].node, .start = start, .len = @intCast(j - i) });
            i = j;
        }
    }

    var side_pts: std.ArrayList(Point) = .empty;
    defer side_pts.deinit(gpa);
    while (work.pop()) |item| {
        const pts = try gpa.dupe(Point, pool.items[item.start..][0..item.len]);
        defer gpa.free(pts);
        var count: [4]usize = @splat(0);
        for (pts) |p| count[@intFromEnum(p.side(s))] += 1;
        if (@max(@max(count[0], count[1]), @max(count[2], count[3])) <= 1) continue;

        const vertical_chain = @max(count[0], count[1]) > @max(count[2], count[3]);
        const across: [2]Side = if (vertical_chain) .{ .left, .right } else .{ .up, .down };
        const along: [2]Side = if (vertical_chain) .{ .up, .down } else .{ .left, .right };
        const n = @max(count[@intFromEnum(across[0])], count[@intFromEnum(across[1])]);
        const m = n | 1; // S3: odd width, the node itself in the middle
        const mid = m / 2;

        const x = s.nodes.get(item.node);
        const copies = try gpa.alloc(u32, m);
        defer gpa.free(copies);
        for (copies, 0..) |*c, k| c.* = if (k == mid) item.node else try s.addNode(x);
        const chain_net: u32 = if (x.kind == .device) none else x.ref;
        const chain_start: u32 = @intCast(s.edges.items.len);
        for (0..m - 1) |k| {
            _ = try s.addEdge(.{ .kind = .chain, .a = copies[k], .b = copies[k + 1], .side = along[1], .net = chain_net, .pa = none, .pb = none });
        }

        const lists = try gpa.alloc(std.ArrayList(Point), m);
        defer {
            for (lists) |*l| l.deinit(gpa);
            gpa.free(lists);
        }
        @memset(lists, .empty);

        for (across) |side| {
            side_pts.clearRetainingCapacity();
            for (pts) |p| if (p.side(s) == side) try side_pts.append(gpa, p);
            const Ctx = struct { s: *const Schematic, x_axis: bool };
            std.mem.sort(Point, side_pts.items, Ctx{ .s = s, .x_axis = !vertical_chain }, struct {
                /// Where the pin sits along the chain on the symbol, then its
                /// partner's key: copies follow the class's own pin order.
                fn key(c: Ctx, p: Point) struct { i32, u64 } {
                    const pin = p.pin(c.s);
                    const at: i32 = if (pin == none) 0 else if (c.s.pinOffset(pin)) |o| (if (c.x_axis) o.x else o.y) else 0;
                    const other = p.partner(c.s);
                    const k: u64 = if (other == none) 0 else if (c.x_axis) c.s.nodes.items(.x_key)[other] else c.s.nodes.items(.y_key)[other];
                    return .{ at, k };
                }
                fn lt(c: Ctx, a: Point, b: Point) bool {
                    const ka = key(c, a);
                    const kb = key(c, b);
                    return if (ka[0] != kb[0]) ka[0] < kb[0] else ka[1] < kb[1];
                }
            }.lt);
            for (side_pts.items, 0..) |p, k| {
                const slot = centeredSlot(m, side_pts.items.len, k);
                bind(s, p, copies[slot], pin_edges);
                try lists[slot].append(gpa, p);
            }
        }
        // S4: along-side attachments go to the chain's ends.
        for (pts) |p| {
            const side = p.side(s);
            if (side == along[0]) {
                bind(s, p, copies[0], pin_edges);
                try lists[0].append(gpa, p);
            } else if (side == along[1]) {
                bind(s, p, copies[m - 1], pin_edges);
                try lists[m - 1].append(gpa, p);
            }
        }
        for (0..m - 1) |k| {
            const e: u32 = chain_start + @as(u32, @intCast(k));
            try lists[k].append(gpa, .{ .kind = .edge_a, .id = e });
            try lists[k + 1].append(gpa, .{ .kind = .edge_b, .id = e });
        }
        for (lists, copies) |l, c| {
            var cnt: [4]usize = @splat(0);
            for (l.items) |p| cnt[@intFromEnum(p.side(s))] += 1;
            if (@max(@max(cnt[0], cnt[1]), @max(cnt[2], cnt[3])) <= 1) continue;
            const start: u32 = @intCast(pool.items.len);
            try pool.appendSlice(gpa, l.items);
            try work.append(gpa, .{ .node = c, .start = start, .len = @intCast(l.items.len) });
        }
    }
}

/// Slot k of `count` attachments across a chain of `m` copies: centred,
/// skipping the middle copy when `count` is even.
fn centeredSlot(m: usize, count: usize, k: usize) usize {
    const mid = m / 2;
    const first = mid - count / 2;
    const pos = first + k;
    return if (count % 2 == 0 and pos >= mid) pos + 1 else pos;
}

fn bind(s: *Schematic, p: Point, copy: u32, pin_edges: []const u32) void {
    const homes = s.pins.items(.home);
    const pin = p.pin(s);
    switch (p.kind) {
        .edge_a => s.edges.items[p.id].a = copy,
        .edge_b => s.edges.items[p.id].b = copy,
        .pin => homes[p.id] = copy,
    }
    // A pin with one edge lives where its edge ends; a fan pin stays on the
    // middle copy, where its symbol is drawn.
    if (pin != none and p.kind != .pin and pin_edges[pin] == 1) homes[pin] = copy;
}

// ===========================================================================
// Labels (W8, W9, L4, L7)
// ===========================================================================

/// L4, L7: a join that cycles or crosses gives way, and with it every join
/// of its net — the net's cross-links go together — except the net's
/// same-device bends and the join that attaches its terminal leaf, which
/// stay unless they are the one to blame. The net's loose pieces are named.
pub fn dropJoin(gpa: Allocator, s: *Schematic, j: u32) !void {
    const net = s.joins.items[j].net;
    for (s.joins.items, 0..) |*jj, id| {
        if (!jj.active or jj.net != net) continue;
        const leaf = switch (jj.kind) {
            .tap => s.isTerminalPin(jj.p),
            .corner => s.isTerminalPin(jj.p) or s.isTerminalPin(jj.q),
            .cross, .bend => false,
        };
        if (id == j or !(jj.kind == .bend or leaf)) jj.active = false;
    }
    trimJunctions(s);
    try nameNet(gpa, s, net);
}

/// L7: a straight edge that cannot be drawn cleanly is given up; its net's
/// loose pieces are named instead. A join that met the net on that wire (a
/// tap onto it, a cross through it) goes with it: kept, it would still be
/// drawn to where the wire was, ending in the open, and would count its pin
/// as joined to a piece it no longer reaches.
pub fn dropEdge(gpa: Allocator, s: *Schematic, e: u32) !void {
    s.edges.items[e].kind = .dropped;
    for (s.joins.items) |*j| switch (j.kind) {
        .tap => if (j.q == e) {
            j.active = false;
        },
        .cross => if (j.p == e or j.q == e) {
            j.active = false;
        },
        .corner, .bend => {},
    };
    trimJunctions(s);
    try nameNet(gpa, s, s.edges.items[e].net);
}

/// After a wire gives way: a junction copy left with nothing attached leaves
/// its chain, which would otherwise end in a stub. A bare copy in the middle
/// is spliced out, or stays as a plain pass-through if it is the root (its
/// pins live there).
fn trimJunctions(s: *Schematic) void {
    const edges = s.edges.items;
    const kinds = s.nodes.items(.kind);
    const homes = s.pins.items(.home);
    var changed = true;
    while (changed) {
        changed = false;
        for (0..s.nodes.len) |i| {
            const u: u32 = @intCast(i);
            if (kinds[u] != .junction) continue;
            const bare = for (edges) |x| {
                if (x.kind == .straight and (x.a == u or x.b == u)) break false;
            } else for (s.joins.items) |j| {
                if (!j.active) continue;
                const p_here = j.kind != .cross and homes[j.p] == u;
                const q_here = (j.kind == .corner or j.kind == .bend) and homes[j.q] == u;
                if (p_here or q_here) break false;
            } else true;
            if (!bare) continue;
            var in: ?*Edge = null;
            var out: ?*Edge = null;
            for (edges) |*x| if (x.kind == .chain) {
                if (x.b == u) in = x;
                if (x.a == u) out = x;
            };
            if (in != null and out != null) {
                if (s.nodes.items(.group)[u] == u) continue;
                in.?.b = out.?.b;
                out.?.kind = .dropped;
            } else if (in orelse out) |x| {
                x.kind = .dropped;
            } else continue;
            changed = true;
        }
    }
}

/// W8, W9 and after `dropJoin`/`dropEdge`: every piece of `net` (pins connected by
/// straight edges and active joins) that carries no name gets one. A piece
/// with a wire gets an annotation on it; otherwise a label node hangs on a
/// pin with nothing attached. The terminal leaf, a label node or an
/// annotation names a piece.
pub fn nameNet(gpa: Allocator, s: *Schematic, net: u32) !void {
    s.labeled[net] = true;
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    for (s.pins.items(.net), 0..) |n, p| if (n == net) try ids.append(gpa, @intCast(p));
    if (ids.items.len == 0) return;
    const parent = try gpa.alloc(u32, ids.items.len);
    defer gpa.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const Uf = struct {
        list: []const u32,
        par: []u32,
        fn find(u: @This(), start: usize) usize {
            var i = start;
            while (u.par[i] != i) i = u.par[i];
            return i;
        }
        fn unite(u: @This(), a: u32, b: u32) void {
            const la = std.mem.indexOfScalar(u32, u.list, a).?;
            const lb = std.mem.indexOfScalar(u32, u.list, b).?;
            u.par[u.find(la)] = @intCast(u.find(lb));
        }
    };
    const uf: Uf = .{ .list = ids.items, .par = parent };
    const joined = try gpa.alloc(bool, ids.items.len);
    defer gpa.free(joined);
    @memset(joined, false);
    for (s.edges.items) |e| {
        if (e.kind == .straight and e.net == net) uf.unite(e.pa, e.pb);
    }
    for (ids.items) |p| for (ids.items) |q| {
        if (p < q and s.junctionOf(p) != none and s.junctionOf(p) == s.junctionOf(q)) uf.unite(p, q);
    };
    for (s.joins.items) |j| {
        if (!j.active or j.net != net) continue;
        const a, const b = switch (j.kind) {
            .tap => .{ j.p, s.edges.items[j.q].pa },
            .corner, .bend => .{ j.p, j.q },
            .cross => .{ s.edges.items[j.p].pa, s.edges.items[j.q].pa },
        };
        uf.unite(a, b);
        for ([_]u32{ j.p, j.q }) |x| {
            if (j.kind == .corner or j.kind == .bend or (j.kind == .tap and x == j.p)) {
                joined[std.mem.indexOfScalar(u32, ids.items, x).?] = true;
            }
        }
    }

    // Decide per piece first: naming appends pins and edges.
    const Piece = struct { pin: u32, edge: u32 };
    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(gpa);
    const devices = s.pins.items(.device);
    for (0..ids.items.len) |i| {
        if (uf.find(i) != i) continue;
        var named = false;
        var bare: u32 = none;
        var lone: u32 = none;
        for (ids.items, 0..) |p, k| {
            if (uf.find(k) != i) continue;
            if (devices[p] == none and s.nodes.items(.kind)[s.pins.items(.home)[p]] != .junction) named = true; // terminal or label pin
            var has_edge = false;
            for (s.edges.items) |e| has_edge = has_edge or (e.kind == .straight and (e.pa == p or e.pb == p));
            if (!has_edge and lone == none) lone = p;
            if (!has_edge and !joined[k] and bare == none) bare = p;
        }
        var wire_edge: u32 = none;
        for (s.edges.items, 0..) |e, id| {
            if (e.kind != .straight or e.net != net or uf.find(std.mem.indexOfScalar(u32, ids.items, e.pa).?) != i) continue;
            if (wire_edge == none) wire_edge = @intCast(id);
            if (std.mem.indexOfScalar(u32, s.annotations.items, @intCast(id)) != null) named = true;
        }
        if (named) continue;
        try pieces.append(gpa, .{ .pin = if (bare != none) bare else lone, .edge = wire_edge });
    }
    for (pieces.items) |piece| {
        if (piece.edge != none) {
            try s.annotations.append(s.arena.allocator(), piece.edge);
        } else {
            try hangLabel(s, piece.pin);
        }
    }
}

fn hangLabel(s: *Schematic, pin: u32) !void {
    const home = s.pins.items(.home)[pin];
    const side = s.pins.items(.side)[pin];
    var xk = s.nodes.items(.x_key)[home];
    var yk = s.nodes.items(.y_key)[home];
    switch (side) {
        .left => xk -|= 1,
        .right => xk +|= 1,
        .up => yk -|= 1,
        .down => yk +|= 1,
    }
    const net = s.pins.items(.net)[pin];
    const node = try s.addNode(.{ .kind = .label, .ref = net, .group = none, .x_key = xk, .y_key = yk });
    const lp = try s.addPin(.{ .home = node, .side = side.opposite(), .net = net, .device = none, .index = no_pin });
    _ = try s.addStraight(pin, lp);
}
