//! Stage 5 of ALGORITHM.md (L1–L8): grid coordinates, routes, and the label
//! rule for joins whose order constraints cycle (L4) or whose wires cross or
//! run through something (L7). Bends are a layout detail: joins and edges
//! the grid cannot keep straight are drawn with L-shaped routes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sch = @import("schematic.zig");
const library = @import("library.zig");
const config = @import("config.zig");

pub const Config = config.Config;
const Layout = config.Layout;

const Side = sch.Side;
const Schematic = sch.Schematic;
const Route = sch.Route;
const Edge = sch.Edge;
const none = sch.none;

/// Assigns grid coordinates and routes. A wire (join or straight edge) that
/// cycles, crosses or overlaps is dropped, its net's loose pieces are named,
/// and the layout is redone; each round drops one wire, so this ends.
pub fn layout(gpa: Allocator, s: *Schematic, cfg: *const Config) !void {
    const g = &cfg.layout;
    // S5: a second round only if a rail or junction doubled back.
    var redealt = false;
    // Re-deals before a join gives way (S5). A re-deal only permutes copies,
    // so it may repeat; the cap makes this end, after which joins give way.
    var redeals: usize = 0;
    var rounds: u32 = 0;
    for (0..2) |round| {
        while (true) switch (try place(gpa, s, g, redeals < 4 * s.nodes.len, &rounds)) {
            .done => break,
            .redo => {
                redeals += 1;
                redealt = true;
            },
            .drop => |w| switch (w.kind) {
                .join => try sch.dropJoin(gpa, s, w.id),
                .edge => try sch.dropEdge(gpa, s, w.id),
            },
        };
        if (round == 1 or !try orderCopies(gpa, s)) break;
        redealt = true;
    }
    var labeled: u32 = 0;
    for (s.labeled) |l| labeled += @intFromBool(l);
    s.stats.labeled_nets = labeled;
    s.stats.redealt = redealt;
    s.stats.rounds = rounds;
    try findNoConnects(gpa, s);
}

/// W10: a device pin with no other pin on its net.
fn findNoConnects(gpa: Allocator, s: *Schematic) !void {
    const count = try gpa.alloc(u32, s.net_name.len);
    defer gpa.free(count);
    @memset(count, 0);
    const nets = s.pins.items(.net);
    for (nets) |n| count[n] += 1;
    s.no_connects.clearRetainingCapacity();
    for (nets, s.pins.items(.device), 0..) |n, d, p| {
        if (d != none and count[n] == 1) try s.no_connects.append(s.arena.allocator(), @intCast(p));
    }
}

// ===========================================================================
// Rows and columns (L1, L2)
// ===========================================================================

const Classes = struct {
    parent: []u32,
    next: []u32,

    fn init(gpa: Allocator, n: usize) !Classes {
        const c: Classes = .{ .parent = try gpa.alloc(u32, n), .next = try gpa.alloc(u32, n) };
        for (c.parent, c.next, 0..) |*p, *x, i| {
            p.* = @intCast(i);
            x.* = @intCast(i);
        }
        return c;
    }
    fn deinit(c: *Classes, gpa: Allocator) void {
        gpa.free(c.parent);
        gpa.free(c.next);
    }
    fn find(c: *Classes, x0: u32) u32 {
        var x = x0;
        while (c.parent[x] != x) {
            c.parent[x] = c.parent[c.parent[x]];
            x = c.parent[x];
        }
        return x;
    }
    fn merge(c: *Classes, ra: u32, rb: u32) void {
        c.parent[rb] = ra;
        std.mem.swap(u32, &c.next[ra], &c.next[rb]);
    }
};

/// Would merging these two classes of `same` put two nodes on one cell,
/// i.e. do they share a class of `other`?
fn wouldCollide(same: *Classes, other: *Classes, ra: u32, rb: u32, stamp: []u32, tick: *u32) bool {
    tick.* += 1;
    var u = ra;
    while (true) {
        stamp[other.find(u)] = tick.*;
        u = same.next[u];
        if (u == ra) break;
    }
    var v = rb;
    while (true) {
        if (stamp[other.find(v)] == tick.*) return true;
        v = same.next[v];
        if (v == rb) break;
    }
    return false;
}

fn compact(gpa: Allocator, c: *Classes, out: []u32) !usize {
    const id = try gpa.alloc(u32, out.len);
    defer gpa.free(id);
    @memset(id, none);
    var count: u32 = 0;
    for (out, 0..) |*o, u| {
        const r = c.find(@intCast(u));
        if (id[r] == none) {
            id[r] = count;
            count += 1;
        }
        o.* = id[r];
    }
    return count;
}

/// L1/L2: chains first, then horizontal, then vertical straight edges merge
/// rows and columns unless two nodes would share a cell. `kept[e]` says
/// whether edge e got its line; `cx`, `cy` receive column and row classes.
/// Returns the number of columns and rows.
fn mergeLines(gpa: Allocator, s: *const Schematic, kept: []bool, cx: []u32, cy: []u32) !struct { usize, usize } {
    const n = s.nodes.len;
    const edges = s.edges.items;
    const order = try gpa.alloc(u32, edges.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, edges, struct {
        fn prio(e: Edge) u8 {
            return if (e.kind == .chain) 0 else if (e.side == .right) 1 else 2;
        }
        fn lt(es: []const Edge, x: u32, y: u32) bool {
            const px = prio(es[x]);
            const py = prio(es[y]);
            return if (px != py) px < py else x < y;
        }
    }.lt);
    var rows = try Classes.init(gpa, n);
    defer rows.deinit(gpa);
    var cols = try Classes.init(gpa, n);
    defer cols.deinit(gpa);
    const stamp = try gpa.alloc(u32, n);
    defer gpa.free(stamp);
    @memset(stamp, 0);
    var tick: u32 = 0;
    for (order) |ei| {
        const e = edges[ei];
        kept[ei] = false;
        if (e.kind == .dropped) continue;
        const same, const other = if (e.side == .right) .{ &rows, &cols } else .{ &cols, &rows };
        var ok = other.find(e.a) != other.find(e.b);
        if (ok) {
            const ra = same.find(e.a);
            const rb = same.find(e.b);
            if (ra != rb) {
                if (wouldCollide(same, other, ra, rb, stamp, &tick)) ok = false else same.merge(ra, rb);
            }
        }
        kept[ei] = ok;
    }
    return .{ try compact(gpa, &cols, cx), try compact(gpa, &rows, cy) };
}

// ===========================================================================
// Copies of a net's own node (S5)
// ===========================================================================

/// S5, after a layout: a rail or junction whose chain was drawn bent gets
/// its copies re-dealt by where their partners landed. Returns whether
/// anything moved.
fn orderCopies(gpa: Allocator, s: *Schematic) !bool {
    const want = try gpa.alloc(bool, s.nodes.len);
    defer gpa.free(want);
    @memset(want, false);
    const edges = s.edges.items;
    const groups = s.nodes.items(.group);
    for (s.routes.items) |r| {
        if (r.kind == .edge and edges[r.id].kind == .chain and !r.straight) want[groups[edges[r.id].a]] = true;
    }
    return redeal(gpa, s, s.pos, want);
}

/// S5: the copies of a rail or a junction are interchangeable, so the
/// attachments of each group in `want` (by root) are dealt to its copies in
/// the order of their partners' positions in `pos`. Slots keep their places
/// along the chain (the bare middle copy stays bare). Returns whether
/// anything moved.
fn redeal(gpa: Allocator, s: *Schematic, pos: []const [2]i32, want: []const bool) !bool {
    const n = s.nodes.len;
    const kinds = s.nodes.items(.kind);
    const groups = s.nodes.items(.group);
    const edges = s.edges.items;
    var chain: std.ArrayList(u32) = .empty;
    defer chain.deinit(gpa);
    const Att = struct { slot: u32, edge: u32, a_end: bool, level: i32 };
    var atts: std.ArrayList(Att) = .empty;
    defer atts.deinit(gpa);
    var moved = false;
    for (0..n) |root| {
        if (groups[root] != root or !want[root] or (kinds[root] != .terminal and kinds[root] != .junction)) continue;
        // The chain, head to tail; skip anything but a simple line of copies.
        var head: u32 = @intCast(root);
        var steps: usize = 0;
        while (for (edges) |e| {
            if (e.kind == .chain and e.b == head) break e.a;
        } else null) |prev| : (steps += 1) {
            if (steps > n) return moved;
            head = prev;
        }
        chain.clearRetainingCapacity();
        var along: ?Side = null;
        var at: ?u32 = head;
        while (at) |node| {
            if (chain.items.len > n) return moved;
            try chain.append(gpa, node);
            at = for (edges) |e| {
                if (e.kind == .chain and e.a == node) {
                    along = e.side;
                    break e.b;
                }
            } else null;
        }
        const x_axis = (along orelse continue) == .right;
        for ([_]bool{ true, false }) |a_end| {
            atts.clearRetainingCapacity();
            for (edges, 0..) |e, id| {
                if (e.kind != .straight or e.side.isHorizontal() == x_axis) continue;
                const mine = if (a_end) e.a else e.b;
                const other = if (a_end) e.b else e.a;
                const slot = std.mem.indexOfScalar(u32, chain.items, mine) orelse continue;
                try atts.append(gpa, .{ .slot = @intCast(slot), .edge = @intCast(id), .a_end = a_end, .level = pos[other][if (x_axis) 0 else 1] });
            }
            if (atts.items.len < 2 or atts.items.len > 64) continue;
            // Slots in chain order, attachments in partner order; pair them up.
            var slots: [64]u32 = undefined;
            for (atts.items, 0..) |t, i| slots[i] = t.slot;
            std.mem.sort(u32, slots[0..atts.items.len], {}, std.sort.asc(u32));
            std.mem.sort(Att, atts.items, {}, struct {
                fn lt(_: void, p: Att, q: Att) bool {
                    return if (p.level != q.level) p.level < q.level else p.slot < q.slot;
                }
            }.lt);
            for (atts.items, 0..) |t, i| {
                if (t.slot == slots[i]) continue;
                const copy = chain.items[slots[i]];
                if (t.a_end) edges[t.edge].a = copy else edges[t.edge].b = copy;
                moved = true;
            }
        }
    }
    return moved;
}

/// S5, before a join gives way (L4): the rails and junctions whose chain
/// order closes a cycle with a bad join are laid out once without that
/// order, and their copies re-dealt by where the partners land. Returns
/// whether anything moved (then the layout runs again).
fn redealCycles(gpa: Allocator, s: *Schematic, nx: usize, ny: usize, cx: []const u32, cy: []const u32, xc: []const Con, yc: []const Con) !bool {
    const want = try gpa.alloc(bool, s.nodes.len);
    defer gpa.free(want);
    @memset(want, false);
    var any = false;
    for ([_][]const Con{ xc, yc }, [_]usize{ nx, ny }) |cons, count| {
        const comp = try scc(gpa, count, cons);
        defer gpa.free(comp);
        for (cons) |c| {
            if (c.group == none or comp[c.a] != comp[c.b]) continue;
            // Only a cycle that also holds a join is worth re-dealing for.
            for (cons) |j| {
                if (j.join != none and comp[j.a] == comp[c.a] and comp[j.b] == comp[c.a]) {
                    want[c.group] = true;
                    any = true;
                    break;
                }
            }
        }
    }
    if (!any) return false;
    // Levels without the chosen groups' chain order.
    var fx: std.ArrayList(Con) = .empty;
    defer fx.deinit(gpa);
    var fy: std.ArrayList(Con) = .empty;
    defer fy.deinit(gpa);
    for (xc) |c| if (c.group == none or !want[c.group]) try fx.append(gpa, c);
    for (yc) |c| if (c.group == none or !want[c.group]) try fy.append(gpa, c);
    const lx = try gpa.alloc(i32, nx);
    defer gpa.free(lx);
    const ly = try gpa.alloc(i32, ny);
    defer gpa.free(ly);
    _ = try assignLevels(gpa, nx, fx.items, lx);
    _ = try assignLevels(gpa, ny, fy.items, ly);
    const pos = try gpa.alloc([2]i32, s.nodes.len);
    defer gpa.free(pos);
    for (pos, 0..) |*p, u| p.* = .{ lx[cx[u]], ly[cy[u]] };
    return redeal(gpa, s, pos, want);
}

// ===========================================================================
// Order constraints (L1, L3)
// ===========================================================================

/// Class `a` at least `gap` levels before class `b`; `join` is the join
/// that asked for it, or `none` for edges and separation.
const Con = struct {
    a: u32,
    b: u32,
    join: u32,
    gap: u8 = 1,
    /// Against the flow: the join needs a node that comes later by key
    /// before one that comes earlier (a feedback wire).
    backward: bool = false,
    /// From the chain of a rail or junction (by root): an order S5 may
    /// re-deal rather than a constraint.
    group: u32 = none,
};

const Order = struct {
    gpa: Allocator,
    cx: []const u32,
    cy: []const u32,
    kx: []const u64,
    ky: []const u64,
    xc: *std.ArrayList(Con),
    yc: *std.ArrayList(Con),
    /// Joins whose constraints contradict the rows and columns outright.
    bad: *std.ArrayList(Wire),

    fn before(o: Order, x_axis: bool, u: u32, v: u32, join: u32) !void {
        const c = if (x_axis) o.cx else o.cy;
        if (c[u] == c[v]) return o.bad.append(o.gpa, .{ .kind = .join, .id = join });
        const k = if (x_axis) o.kx else o.ky;
        try (if (x_axis) o.xc else o.yc).append(o.gpa, .{ .a = c[u], .b = c[v], .join = join, .backward = k[u] > k[v] });
    }
    /// `v` lies on side `side` of `u`.
    fn toward(o: Order, u: u32, side: Side, v: u32, join: u32) !void {
        switch (side) {
            .right => try o.before(true, u, v, join),
            .left => try o.before(true, v, u, join),
            .down => try o.before(false, u, v, join),
            .up => try o.before(false, v, u, join),
        }
    }
};

/// L3: what each join needs for its bend to be drawable.
fn joinOrder(s: *const Schematic, o: Order, j: u32) !void {
    const join = s.joins.items[j];
    const home = s.pins.items(.home);
    const side = s.pins.items(.side);
    switch (join.kind) {
        .bend => {},
        .tap => {
            // The wire lies ahead of the pin, and the pin lies strictly
            // between the wire's ends.
            const p = home[join.p];
            const e = s.edges.items[join.q];
            const along_x = e.side == .right;
            try o.toward(p, side[join.p], e.a, j);
            try o.before(along_x, e.a, p, j);
            try o.before(along_x, p, e.b, j);
        },
        .corner => {
            // Each pin lies ahead of the other.
            try o.toward(home[join.p], side[join.p], home[join.q], j);
            try o.toward(home[join.q], side[join.q], home[join.p], j);
        },
        .cross => {
            // Each wire passes strictly between the other's ends.
            const ev = s.edges.items[join.p];
            const eh = s.edges.items[join.q];
            try o.before(false, ev.a, eh.a, j);
            try o.before(false, eh.a, ev.b, j);
            try o.before(true, eh.a, ev.a, j);
            try o.before(true, ev.a, eh.b, j);
        },
    }
}

/// L4: joins with a constraint inside a strongly connected component, i.e.
/// on a cycle of order constraints.
fn cyclingJoins(gpa: Allocator, n: usize, cons: []const Con, out: *std.ArrayList(Wire)) !void {
    const comp = try scc(gpa, n, cons);
    defer gpa.free(comp);
    for (cons) |c| {
        if (c.join != none and comp[c.a] == comp[c.b]) try out.append(gpa, .{ .kind = .join, .id = c.join, .backward = c.backward });
    }
}

/// Kosaraju, iterative.
fn scc(gpa: Allocator, n: usize, cons: []const Con) ![]u32 {
    const fwd_off = try gpa.alloc(u32, n + 1);
    defer gpa.free(fwd_off);
    const rev_off = try gpa.alloc(u32, n + 1);
    defer gpa.free(rev_off);
    @memset(fwd_off, 0);
    @memset(rev_off, 0);
    for (cons) |c| {
        fwd_off[c.a + 1] += 1;
        rev_off[c.b + 1] += 1;
    }
    for (1..n + 1) |i| {
        fwd_off[i] += fwd_off[i - 1];
        rev_off[i] += rev_off[i - 1];
    }
    const fwd = try gpa.alloc(u32, cons.len);
    defer gpa.free(fwd);
    const rev = try gpa.alloc(u32, cons.len);
    defer gpa.free(rev);
    {
        const fc = try gpa.dupe(u32, fwd_off[0..n]);
        defer gpa.free(fc);
        const rc = try gpa.dupe(u32, rev_off[0..n]);
        defer gpa.free(rc);
        for (cons) |c| {
            fwd[fc[c.a]] = c.b;
            fc[c.a] += 1;
            rev[rc[c.b]] = c.a;
            rc[c.b] += 1;
        }
    }

    const seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    var finish: std.ArrayList(u32) = .empty;
    defer finish.deinit(gpa);
    const Frame = struct { v: u32, it: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    for (0..n) |root| {
        if (seen[root]) continue;
        seen[root] = true;
        try stack.append(gpa, .{ .v = @intCast(root), .it = fwd_off[root] });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.it == fwd_off[top.v + 1]) {
                try finish.append(gpa, top.v);
                _ = stack.pop();
                continue;
            }
            const w = fwd[top.it];
            top.it += 1;
            if (!seen[w]) {
                seen[w] = true;
                try stack.append(gpa, .{ .v = w, .it = fwd_off[w] });
            }
        }
    }

    const comp = try gpa.alloc(u32, n);
    errdefer gpa.free(comp);
    @memset(comp, none);
    var todo: std.ArrayList(u32) = .empty;
    defer todo.deinit(gpa);
    var id: u32 = 0;
    var k = finish.items.len;
    while (k > 0) {
        k -= 1;
        const root = finish.items[k];
        if (comp[root] != none) continue;
        comp[root] = id;
        try todo.append(gpa, root);
        while (todo.pop()) |v| {
            for (rev[rev_off[v]..rev_off[v + 1]]) |u| {
                if (comp[u] != none) continue;
                comp[u] = id;
                try todo.append(gpa, u);
            }
        }
        id += 1;
    }
    return comp;
}

/// A wire that can give way: a join, or a straight edge.
pub const Wire = struct {
    kind: enum { join, edge },
    id: u32,
    /// L4: one of its constraints on the cycle runs against the flow.
    backward: bool = false,
};

fn wireNet(s: *const Schematic, w: Wire) u32 {
    return switch (w.kind) {
        .join => s.joins.items[w.id].net,
        .edge => s.edges.items[w.id].net,
    };
}

/// The wire that gives way first. Joins before straight edges, whatever
/// their nets: a straight edge only gives way once no join is to blame.
/// Among those, the net with the highest role rank, then fewest straight
/// edges (a net made only of joins is all cross-links), then the latest
/// net; within the net, the latest wire.
fn worstWire(s: *const Schematic, all: []const Wire) Wire {
    var any_join = false;
    var any_backward = false;
    for (all) |w| any_join = any_join or w.kind == .join;
    for (all) |w| any_backward = any_backward or w.backward;
    var buf: [256]Wire = undefined;
    var len: usize = 0;
    for (all) |w| {
        if (any_join and w.kind != .join) continue;
        // A cycle breaks at its feedback wire, not at a wire along the flow.
        if (any_backward and !w.backward) continue;
        if (len < buf.len) {
            buf[len] = w;
            len += 1;
        }
    }
    const wires = buf[0..len];
    const Key = struct { rank: u8, straight: u32, net: u32 };
    const key = struct {
        fn f(sc: *const Schematic, net: u32) Key {
            var n: u32 = 0;
            for (sc.edges.items) |e| n += @intFromBool(e.kind == .straight and e.net == net);
            return .{ .rank = sc.roles[net].rank(), .straight = n, .net = net };
        }
        fn worse(a: Key, b: Key) bool {
            if (a.rank != b.rank) return a.rank > b.rank;
            if (a.straight != b.straight) return a.straight < b.straight;
            return a.net > b.net;
        }
    };
    var net_key: ?Key = null;
    for (wires) |w| {
        const k = key.f(s, wireNet(s, w));
        if (net_key == null or key.worse(k, net_key.?)) net_key = k;
    }
    var best: ?Wire = null;
    for (wires) |w| {
        if (wireNet(s, w) != net_key.?.net) continue;
        const b = best orelse {
            best = w;
            continue;
        };
        if (w.id > b.id) best = w;
    }
    return best.?;
}

// ===========================================================================
// Levels (L5, L6, L8)
// ===========================================================================

/// Longest-path levels over `n` classes. L5: back edges of a DFS are dropped
/// (count returned); only straight-edge constraints can be left on cycles.
/// L8: classes with no predecessor move up against their successors.
fn assignLevels(gpa: Allocator, n: usize, cons: []const Con, levels: []i32) !u32 {
    const offsets = try gpa.alloc(u32, n + 1);
    defer gpa.free(offsets);
    @memset(offsets, 0);
    for (cons) |c| offsets[c.a + 1] += 1;
    for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
    const succ = try gpa.alloc(u32, cons.len);
    defer gpa.free(succ);
    const gap = try gpa.alloc(u8, cons.len);
    defer gpa.free(gap);
    const alive = try gpa.alloc(bool, cons.len);
    defer gpa.free(alive);
    @memset(alive, true);
    {
        const cur = try gpa.dupe(u32, offsets[0..n]);
        defer gpa.free(cur);
        for (cons) |c| {
            succ[cur[c.a]] = c.b;
            gap[cur[c.a]] = c.gap;
            cur[c.a] += 1;
        }
    }

    const color = try gpa.alloc(u8, n);
    defer gpa.free(color);
    @memset(color, 0);
    var dropped: u32 = 0;
    const Frame = struct { v: u32, it: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    for (0..n) |root| {
        if (color[root] != 0) continue;
        color[root] = 1;
        try stack.append(gpa, .{ .v = @intCast(root), .it = offsets[root] });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.it == offsets[top.v + 1]) {
                color[top.v] = 2;
                _ = stack.pop();
                continue;
            }
            const k = top.it;
            top.it += 1;
            const w = succ[k];
            if (color[w] == 1) {
                alive[k] = false;
                dropped += 1;
            } else if (color[w] == 0) {
                color[w] = 1;
                try stack.append(gpa, .{ .v = w, .it = offsets[w] });
            }
        }
    }

    const indeg = try gpa.alloc(u32, n);
    defer gpa.free(indeg);
    @memset(indeg, 0);
    for (succ, alive) |w, ok| {
        if (ok) indeg[w] += 1;
    }
    const has_pred = try gpa.alloc(bool, n);
    defer gpa.free(has_pred);
    for (indeg, has_pred) |d, *h| h.* = d > 0;
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    @memset(levels, 0);
    for (0..n) |v| if (indeg[v] == 0) try order.append(gpa, @intCast(v));
    var head: usize = 0;
    while (head < order.items.len) : (head += 1) {
        const v = order.items[head];
        for (offsets[v]..offsets[v + 1]) |k| {
            if (!alive[k]) continue;
            const w = succ[k];
            levels[w] = @max(levels[w], levels[v] + gap[k]);
            indeg[w] -= 1;
            if (indeg[w] == 0) try order.append(gpa, w);
        }
    }

    var idx = order.items.len;
    while (idx > 0) {
        idx -= 1;
        const v = order.items[idx];
        if (has_pred[v]) continue;
        var best: i32 = std.math.maxInt(i32);
        for (offsets[v]..offsets[v + 1]) |k| {
            if (alive[k]) best = @min(best, levels[succ[k]] - gap[k]);
        }
        if (best != std.math.maxInt(i32)) levels[v] = best;
    }
    return dropped;
}

fn reachable(gpa: Allocator, n: usize, cons: []const Con, from: u32, to: u32) !bool {
    // CSR adjacency, so the search is O(n + cons) rather than O(n * cons):
    // the L6 loop asks this once per round.
    const off = try gpa.alloc(u32, n + 1);
    defer gpa.free(off);
    @memset(off, 0);
    for (cons) |c| off[c.a + 1] += 1;
    for (1..off.len) |i| off[i] += off[i - 1];
    const succ = try gpa.alloc(u32, cons.len);
    defer gpa.free(succ);
    const seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(seen, false);
    // Fill by bumping each start, then shift the starts back.
    for (cons) |c| {
        succ[off[c.a]] = c.b;
        off[c.a] += 1;
    }
    var i = n;
    while (i > 0) : (i -= 1) off[i] = off[i - 1];
    off[0] = 0;
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, from);
    seen[from] = true;
    while (stack.pop()) |v| {
        if (v == to) return true;
        for (succ[off[v]..off[v + 1]]) |w| if (!seen[w]) {
            seen[w] = true;
            try stack.append(gpa, w);
        };
    }
    return false;
}

/// L6, two nodes on one cell: whether `u` goes first. A leaf (terminal or
/// label) keeps to its partner's side of the other node, so it stays beside
/// what it is wired to (L8); otherwise by key.
fn clashFirst(s: *const Schematic, lv: []const i32, c: []const u32, k: []const u64, u: u32, v: u32) bool {
    if (leafPartner(s, u)) |p| if (lv[c[p]] != lv[c[v]]) return lv[c[p]] < lv[c[v]];
    if (leafPartner(s, v)) |p| if (lv[c[p]] != lv[c[u]]) return lv[c[u]] < lv[c[p]];
    return k[u] < k[v] or (k[u] == k[v] and u < v);
}

/// The node a terminal or label copy is wired to by its straight edge.
fn leafPartner(s: *const Schematic, u: u32) ?u32 {
    const kind = s.nodes.items(.kind)[u];
    if (kind != .terminal and kind != .label) return null;
    for (s.edges.items) |e| {
        if (e.kind != .straight) continue;
        if (e.a == u) return e.b;
        if (e.b == u) return e.a;
    }
    return null;
}

/// One axis's order constraints, with the largest gap asked of each ordered
/// pair so a repeated request is seen in O(1).
const Axis = struct {
    n: usize,
    cons: *std.ArrayList(Con),
    gaps: std.AutoHashMapUnmanaged([2]u32, u8) = .empty,

    fn init(gpa: Allocator, n: usize, cons: *std.ArrayList(Con)) !Axis {
        var x: Axis = .{ .n = n, .cons = cons };
        for (cons.items) |c| {
            const gop = try x.gaps.getOrPut(gpa, .{ c.a, c.b });
            gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, c.gap) else c.gap;
        }
        return x;
    }
    fn deinit(x: *Axis, gpa: Allocator) void {
        x.gaps.deinit(gpa);
    }

    /// Appends `c` unless the pair is already ordered at least that far
    /// apart; returns whether it did. A repeat leaves the levels as they
    /// are, so the request that asked for it would come back every round.
    fn addNew(x: *Axis, gpa: Allocator, c: Con) !bool {
        const gop = try x.gaps.getOrPut(gpa, .{ c.a, c.b });
        if (gop.found_existing and gop.value_ptr.* >= c.gap) return false;
        gop.value_ptr.* = c.gap;
        try x.cons.append(gpa, c);
        return true;
    }

    /// L6: order two classes, by key unless that would close a cycle.
    /// `may_reach` false: the caller knows neither reaches the other.
    fn addOrdered(x: *Axis, gpa: Allocator, a: u32, b: u32, a_first: bool, may_reach: bool) !bool {
        var lo, var hi = if (a_first) .{ a, b } else .{ b, a };
        if (may_reach and try reachable(gpa, x.n, x.cons.items, hi, lo)) std.mem.swap(u32, &lo, &hi);
        return x.addNew(gpa, .{ .a = lo, .b = hi, .join = none });
    }
};

// ===========================================================================
// One layout round
// ===========================================================================

/// Lays the graph out once. Returns the wire to drop next (L4, L7), or null
/// when the layout stands.
const Outcome = union(enum) {
    /// The layout stands.
    done,
    /// This wire gives way (L4, L7); lay out again.
    drop: Wire,
    /// Copies were re-dealt (S5); lay out again.
    redo,
};

/// L6 resolves one clash per round in drawings of at most this many nodes,
/// for at most this many rounds; then every clash of a round at once. Every
/// circuit in the tests and examples stays within it (at most 142 rounds, a
/// 147-node driver); a drawing of many independent pieces needs thousands.
const batch_after = 256;

fn place(gpa: Allocator, s: *Schematic, g: *const Layout, may_redeal: bool, work: *u32) !Outcome {
    const n = s.nodes.len;
    const edges = s.edges.items;
    const kept = try gpa.alloc(bool, edges.len);
    defer gpa.free(kept);
    const cx = try gpa.alloc(u32, n);
    defer gpa.free(cx);
    const cy = try gpa.alloc(u32, n);
    defer gpa.free(cy);
    const nx, const ny = try mergeLines(gpa, s, kept, cx, cy);

    // L1/L3: order constraints.
    var xc: std.ArrayList(Con) = .empty;
    defer xc.deinit(gpa);
    var yc: std.ArrayList(Con) = .empty;
    defer yc.deinit(gpa);
    var bad: std.ArrayList(Wire) = .empty;
    defer bad.deinit(gpa);
    const node_kinds = s.nodes.items(.kind);
    const node_groups = s.nodes.items(.group);
    for (edges) |e| {
        if (e.kind == .dropped) continue;
        const group: u32 = if (e.kind == .chain and (node_kinds[e.a] == .terminal or node_kinds[e.a] == .junction)) node_groups[e.a] else none;
        if (e.side == .right) {
            if (cx[e.a] != cx[e.b]) try xc.append(gpa, .{ .a = cx[e.a], .b = cx[e.b], .join = none, .group = group });
        } else {
            if (cy[e.a] != cy[e.b]) try yc.append(gpa, .{ .a = cy[e.a], .b = cy[e.b], .join = none, .group = group });
        }
    }
    const o: Order = .{ .gpa = gpa, .cx = cx, .cy = cy, .kx = s.nodes.items(.x_key), .ky = s.nodes.items(.y_key), .xc = &xc, .yc = &yc, .bad = &bad };
    for (s.joins.items, 0..) |j, ji| {
        if (j.active) try joinOrder(s, o, @intCast(ji));
    }

    // L4 — after S5 has had its chance to take a rail's arbitrary order out
    // of the cycle.
    try cyclingJoins(gpa, nx, xc.items, &bad);
    try cyclingJoins(gpa, ny, yc.items, &bad);
    if (bad.items.len > 0) {
        if (may_redeal and try redealCycles(gpa, s, nx, ny, cx, cy, xc.items, yc.items)) return .redo;
        return .{ .drop = worstWire(s, bad.items) };
    }

    // L5, L6, L8: levels; separate nodes that share a cell, repeat.
    const lx = try gpa.alloc(i32, nx);
    defer gpa.free(lx);
    const ly = try gpa.alloc(i32, ny);
    defer gpa.free(ly);
    const kx = s.nodes.items(.x_key);
    const ky = s.nodes.items(.y_key);
    var cells: std.AutoHashMapUnmanaged([2]i32, u32) = .empty;
    defer cells.deinit(gpa);
    s.pos = try s.arena.allocator().alloc([2]i32, n);
    s.xy = try s.arena.allocator().alloc([2]f32, n);
    const groups = s.nodes.items(.group);
    const text_dir = try textDirections(gpa, s);
    defer gpa.free(text_dir);
    var ax = try Axis.init(gpa, nx, &xc);
    defer ax.deinit(gpa);
    var ay = try Axis.init(gpa, ny, &yc);
    defer ay.deinit(gpa);
    const touched_x = try gpa.alloc(bool, nx);
    defer gpa.free(touched_x);
    const touched_y = try gpa.alloc(bool, ny);
    defer gpa.free(touched_y);
    var rounds: usize = 0;
    var dropped: u32 = 0;
    while (true) : (rounds += 1) {
        const dropped_x = try assignLevels(gpa, nx, xc.items, lx);
        const dropped_y = try assignLevels(gpa, ny, yc.items, ly);
        dropped = dropped_x + dropped_y;
        work.* += 1;
        if (rounds > 4 * n * n) break;

        // L6: two nodes on one cell. One clash per round, the first in node
        // order. A drawing of many independent pieces would take a number
        // of rounds quadratic in its size that way — each piece steps past
        // the others one at a time — so past `batch_after` rounds (or
        // nodes) every clash of the scan is ordered at once, at most one
        // per class and axis. The two classes of a clash share a level, and
        // the levels meet every constraint kept, so neither reaches the
        // other through kept constraints; a batch that is a matching closes
        // no cycle among them either. Only a constraint L5 dropped could
        // close one: the one-at-a-time rounds check for that, a batch does
        // not (L5 would drop one constraint of it again).
        cells.clearRetainingCapacity();
        const batch = n > batch_after or rounds >= batch_after;
        if (batch) {
            @memset(touched_x, false);
            @memset(touched_y, false);
        }
        var clashes: usize = 0;
        var added = false;
        for (0..n) |w| {
            const gop = try cells.getOrPut(gpa, .{ lx[cx[w]], ly[cy[w]] });
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(w);
                continue;
            }
            const u = gop.value_ptr.*;
            const v: u32 = @intCast(w);
            clashes += 1;
            const x_axis = cy[u] == cy[v] or cx[u] != cx[v];
            const c = if (x_axis) cx else cy;
            if (batch) {
                const touched = if (x_axis) touched_x else touched_y;
                if (touched[c[u]] or touched[c[v]]) continue;
                touched[c[u]] = true;
                touched[c[v]] = true;
            }
            added = (if (x_axis)
                try ax.addOrdered(gpa, cx[u], cx[v], clashFirst(s, lx, cx, kx, u, v), !batch and dropped_x > 0)
            else
                try ay.addOrdered(gpa, cy[u], cy[v], clashFirst(s, ly, cy, ky, u, v), !batch and dropped_y > 0)) or added;
            if (!batch) break;
        }
        if (clashes > 0) {
            if (!added) break;
            continue;
        }

        // L6: a terminal's or label's name fills the next cell on its far
        // side; a node there moves one column further out (or, if its column
        // is tied to the name's, to another row).
        // `first` is never after `second` by level, so it can be reached
        // from `second` only through a constraint L5 dropped (as above).
        // Batched like the clashes.
        if (batch) {
            @memset(touched_x, false);
            @memset(touched_y, false);
        }
        var moved: ?bool = null;
        for (0..n) |u| {
            const dir = text_dir[u] orelse continue;
            const v = cells.get(.{ lx[cx[u]] + dir[0], ly[cy[u]] + dir[1] }) orelse continue;
            if (groups[v] == groups[u]) continue;
            const first, const second = if (dir[0] < 0) .{ cx[v], cx[u] } else .{ cx[u], cx[v] };
            const x_axis = first != second and !(!batch and dropped_x > 0 and try reachable(gpa, nx, xc.items, second, first));
            if (!x_axis and cy[u] == cy[v]) continue;
            if (batch) {
                const touched, const a, const b = if (x_axis) .{ touched_x, first, second } else .{ touched_y, cy[u], cy[v] };
                if (touched[a] or touched[b]) continue;
                touched[a] = true;
                touched[b] = true;
            }
            const ok = if (x_axis)
                try ax.addNew(gpa, .{ .a = first, .b = second, .join = none, .gap = 2 })
            else
                try ay.addOrdered(gpa, cy[u], cy[v], ky[u] < ky[v] or (ky[u] == ky[v] and u < v), !batch);
            moved = ok or (moved orelse false);
            if (!batch) break;
        }
        if (moved) |ok| if (ok) continue else break;

        // L6: a wire through a node, or two nets' wires on one line.
        for (s.pos, 0..) |*p, u| p.* = .{ lx[cx[u]], ly[cy[u]] };
        try setXY(gpa, s, g, kept);
        s.stats = .{};
        try buildRoutes(gpa, s, kept, g);
        const req = try separation(gpa, s, cx, cy) orelse break;
        const keys = if (req.x_axis) kx else ky;
        const first = keys[req.ka] < keys[req.kb] or (keys[req.ka] == keys[req.kb] and req.ka < req.kb);
        // A request no order can satisfy (a wire through a block's box)
        // repeats unchanged; the layout stands as it is and L7 judges it.
        if (!try (if (req.x_axis) &ax else &ay).addOrdered(gpa, req.a, req.b, first, true)) break;
    }

    var min: [2]i32 = .{ std.math.maxInt(i32), std.math.maxInt(i32) };
    for (s.pos, 0..) |*p, u| {
        p.* = .{ lx[cx[u]], ly[cy[u]] };
        min = .{ @min(min[0], p[0]), @min(min[1], p[1]) };
    }
    for (s.pos) |*p| p.* = .{ p[0] - min[0], p[1] - min[1] };
    try setXY(gpa, s, g, kept);

    s.stats = .{ .conflicts = dropped };
    try buildRoutes(gpa, s, kept, g);
    try findDots(gpa, s);

    // L7.
    bad.clearRetainingCapacity();
    try measure(gpa, s, &bad);
    if (bad.items.len > 0) return .{ .drop = worstWire(s, bad.items) };
    return .done;
}

// ===========================================================================
// Geometry (§5): from grid cells to coordinates
// ===========================================================================

/// Every coordinate is a whole number of the target's units (f32 holds those
/// exactly), so sums stay exact and equal lines compare equal in every build
/// mode. Lengths from the settings are rounded up to it.
pub fn snap(x: f32) f32 {
    return @ceil(x);
}

/// A length from the settings (in units) in the target's integer
/// coordinates, rounded up.
fn units(s: *const Schematic, x: f32) f32 {
    return snap(x * unitLen(s));
}

fn unitLen(s: *const Schematic) f32 {
    return @floatFromInt(s.lib.unit);
}

/// Half the size of a supply or ground symbol across its wire.
const rail_half_width: f32 = 0.22; // in units, when no rail class says
/// Half the size of a terminal circle, a label's stub, a junction.
const mark_half: f32 = 0.06;

/// Each gap between neighbouring columns (rows) is as wide as the widest
/// thing in it needs — a wire's length for its situation plus the reach of
/// the symbols at its ends — and never under `min_pitch`. Rows and columns
/// keep their order; only the spacing changes.
fn setXY(gpa: Allocator, s: *Schematic, g: *const Layout, kept: []const bool) !void {
    var lo: [2]i32 = .{ std.math.maxInt(i32), std.math.maxInt(i32) };
    var hi: [2]i32 = .{ std.math.minInt(i32), std.math.minInt(i32) };
    for (s.pos) |p| for (0..2) |ax| {
        lo[ax] = @min(lo[ax], p[ax]);
        hi[ax] = @max(hi[ax], p[ax]);
    };
    if (s.pos.len == 0) return;
    var pitch: [2][]f32 = undefined;
    for (0..2) |ax| {
        pitch[ax] = try gpa.alloc(f32, @intCast(hi[ax] - lo[ax] + 1));
        @memset(pitch[ax], units(s, g.min_pitch));
    }
    defer for (pitch) |p| gpa.free(p);
    const Gap = struct {
        pitch: *const [2][]f32,
        lo: [2]i32,
        /// The gap between levels a and b along `ax`, if they are neighbours, needs `len`.
        fn need(self: @This(), ax: usize, a: i32, b: i32, len: f32) void {
            if (@abs(a - b) != 1) return;
            const i: usize = @intCast(@min(a, b) - self.lo[ax]);
            self.pitch[ax][i] = @max(self.pitch[ax][i], len);
        }
    };
    const gap: Gap = .{ .pitch = &pitch, .lo = lo };
    var cells: std.AutoHashMapUnmanaged([2]i32, u32) = .empty;
    defer cells.deinit(gpa);
    for (s.pos, 0..) |p, u| try cells.put(gpa, p, @intCast(u));

    const homes = s.pins.items(.home);
    const sides = s.pins.items(.side);
    for (s.edges.items, kept) |e, straight| {
        if (e.kind != .straight) continue;
        const ax: usize = if (e.side == .right) 0 else 1;
        if (straight) {
            gap.need(ax, s.pos[e.a][ax], s.pos[e.b][ax], s.reach(e.a, e.side) + units(s, wireLength(s, g, e.a, e.b, ax == 0)) + s.reach(e.b, e.side.opposite()));
        } else {
            stubRoom(s, g, gap, &cells, e.a, e.side);
            stubRoom(s, g, gap, &cells, e.b, e.side.opposite());
        }
    }
    for (s.joins.items) |j| {
        if (!j.active) continue;
        switch (j.kind) {
            .tap => {
                const u = homes[j.p];
                const ax: usize = if (sides[j.p].isHorizontal()) 0 else 1;
                gap.need(ax, s.pos[u][ax], s.pos[s.edges.items[j.q].a][ax], s.reach(u, sides[j.p]) + units(s, g.tap));
            },
            .corner => for ([2][2]u32{ .{ j.p, j.q }, .{ j.q, j.p } }) |pq| {
                const u = homes[pq[0]];
                const ax: usize = if (sides[pq[0]].isHorizontal()) 0 else 1;
                gap.need(ax, s.pos[u][ax], s.pos[homes[pq[1]]][ax], s.reach(u, sides[pq[0]]) + units(s, g.tap));
            },
            .bend => for ([2]u32{ j.p, j.q }) |p| stubRoom(s, g, gap, &cells, homes[p], sides[p]),
            .cross => {},
        }
    }

    var at: [2][]f32 = undefined;
    for (0..2) |ax| {
        for (pitch[ax]) |*p| p.* = snap(p.*);
        at[ax] = try gpa.alloc(f32, pitch[ax].len);
        at[ax][0] = 0;
        for (1..at[ax].len) |i| at[ax][i] = at[ax][i - 1] + pitch[ax][i - 1];
    }
    defer for (at) |a| gpa.free(a);
    for (s.pos, s.xy) |p, *q| q.* = .{ at[0][@intCast(p[0] - lo[0])], at[1][@intCast(p[1] - lo[1])] };
}

/// A wire leaving `node` towards `side` turns after `bend`: the gap to the
/// next node that way must fit the stub and keep `clearance` from its symbol.
fn stubRoom(s: *const Schematic, g: *const Layout, gap: anytype, cells: *const std.AutoHashMapUnmanaged([2]i32, u32), node: u32, side: Side) void {
    const v = side.vec();
    const p = s.pos[node];
    const next = cells.get(.{ p[0] + @as(i32, @intFromFloat(v[0])), p[1] + @as(i32, @intFromFloat(v[1])) }) orelse return;
    const ax: usize = if (side.isHorizontal()) 0 else 1;
    gap.need(ax, p[ax], s.pos[next][ax], s.reach(node, side) + units(s, g.bend + g.clearance) + halfSize(s, next, side.opposite()));
}

/// How far a node's symbol reaches towards `side`, in the target's units.
fn halfSize(s: *const Schematic, node: u32, side: Side) f32 {
    const u = unitLen(s);
    return switch (s.nodes.items(.kind)[node]) {
        .device => @max(s.reach(node, side), 0.2 * u),
        .terminal => if (railBox(s, node)) |b| switch (side) {
            .left => @floatFromInt(-b.min.x),
            .right => @floatFromInt(b.max.x),
            .up => @floatFromInt(-b.min.y),
            .down => @floatFromInt(b.max.y),
        } else mark_half * u,
        .label, .junction => mark_half * u,
    };
}

/// The symbol box of a terminal node's rail or port class, around its point.
fn railBox(s: *const Schematic, node: u32) ?library.Rect {
    const role: library.Role = switch (s.roles[s.nodes.items(.ref)[node]]) {
        .supply => .power_rail,
        .sink => .ground_rail,
        .input => .input_port,
        .output => .output_port,
        else => return null,
    };
    const id = s.lib.findRole(role) orelse return null;
    return s.lib.at(id).bbox();
}

/// The visible wire the settings ask for between two nodes on one straight
/// edge, by what the two nodes are.
fn wireLength(s: *const Schematic, g: *const Layout, a: u32, b: u32, horizontal: bool) f32 {
    const kinds = s.nodes.items(.kind);
    var length: f32 = if (horizontal) g.series else g.stack;
    for ([2]u32{ a, b }) |n| switch (kinds[n]) {
        .device => {},
        .label => length = g.label,
        .junction => length = g.junction,
        .terminal => length = switch (s.roles[s.nodes.items(.ref)[n]]) {
            .supply, .sink => g.rail,
            else => g.terminal,
        },
    };
    return length;
}

/// For terminals and labels whose name is written beside them: the cell a
/// name of three or more characters runs into (away from the wire). Supply and ground symbols carry
/// their name above or below and need none.
fn textDirections(gpa: Allocator, s: *const Schematic) ![]?[2]i32 {
    const out = try gpa.alloc(?[2]i32, s.nodes.len);
    @memset(out, null);
    const kinds = s.nodes.items(.kind);
    const refs = s.nodes.items(.ref);
    for (s.pins.items(.home), s.pins.items(.side), s.pins.items(.device)) |home, side, d| {
        if (d != none or kinds[home] == .device) continue;
        if (kinds[home] == .junction) continue;
        if (kinds[home] == .terminal) {
            const r = s.roles[refs[home]];
            if (r == .supply or r == .sink) continue;
        }
        // Names shorter than three characters stay within their own cell.
        if (!side.isHorizontal() or s.net_name[refs[home]].len < 3) continue;
        out[home] = if (side == .left) .{ 1, 0 } else .{ -1, 0 };
    }
    return out;
}

// ===========================================================================
// Separation (L6)
// ===========================================================================

/// The row (horizontal) or column (vertical) class a wire segment lies on,
/// and a node whose key orders it. Only segments that sit on a node's centre
/// line have one; bars and the jogs of bends don't.
const Line = struct { horizontal: bool, class: u32, node: u32 };

fn segmentLine(s: *const Schematic, r: Route, k: usize, cx: []const u32, cy: []const u32) ?Line {
    const homes = s.pins.items(.home);
    const sides = s.pins.items(.side);
    const line = struct {
        fn f(h: bool, node: u32, x: []const u32, y: []const u32) Line {
            return .{ .horizontal = h, .class = if (h) y[node] else x[node], .node = node };
        }
    }.f;
    switch (r.kind) {
        .bar => return null,
        .edge => {
            if (!r.straight) return null;
            const e = s.edges.items[r.id];
            return line(e.side == .right, e.a, cx, cy);
        },
        .join => {
            const j = s.joins.items[r.id];
            switch (j.kind) {
                .tap => return if (k == 0) line(sides[j.p].isHorizontal(), homes[j.p], cx, cy) else null,
                .corner => {
                    const pin = if (k == 0) j.p else j.q;
                    return line(sides[pin].isHorizontal(), homes[pin], cx, cy);
                },
                .cross, .bend => return null,
            }
        },
    }
}

const Request = struct {
    /// Separate along x (columns) or y (rows).
    x_axis: bool,
    a: u32,
    b: u32,
    /// Nodes whose keys decide which class goes first.
    ka: u32,
    kb: u32,
};

/// L6 for wires: a wire through a node it doesn't belong to, or two nets'
/// wires on one line, when the two sit in different row/column classes.
fn separation(gpa: Allocator, s: *const Schematic, cx: []const u32, cy: []const u32) !?Request {
    const Seg = struct { u: [2]f32, v: [2]f32, net: u32, route: u32, line: ?Line };
    var segs: std.ArrayList(Seg) = .empty;
    defer segs.deinit(gpa);
    for (s.routes.items, 0..) |r, ri| {
        for (0..r.len - 1) |k| {
            if (near(r.pts[k], r.pts[k + 1])) continue;
            try segs.append(gpa, .{ .u = r.pts[k], .v = r.pts[k + 1], .net = r.net, .route = @intCast(ri), .line = segmentLine(s, r, k, cx, cy) });
        }
    }
    const kinds = s.nodes.items(.kind);
    const groups = s.nodes.items(.group);
    const refs = s.nodes.items(.ref);
    const boxed = try boxedNodes(gpa, s);
    defer gpa.free(boxed);
    var grid = try BoxGrid.init(gpa, boxed, unitLen(s));
    defer grid.deinit(gpa);
    var near_boxes: std.ArrayList(u32) = .empty;
    defer near_boxes.deinit(gpa);

    for (segs.items) |g| {
        const r = s.routes.items[g.route];
        // The boxes the segment's x-range meets, in node order: the same
        // first hit as scanning every node.
        try grid.near(gpa, @min(g.u[0], g.v[0]), @max(g.u[0], g.v[0]), &near_boxes);
        for (near_boxes.items) |bi| {
            const b = boxed[bi];
            const node = b.node;
            if (kinds[node] != .device and refs[node] == g.net) continue;
            if (!throughNode(g.u, g.v, r.owners, groups[node], b.box)) continue;
            if (g.line) |line| {
                const other = if (line.horizontal) cy[node] else cx[node];
                if (other == line.class) continue;
                return .{ .x_axis = !line.horizontal, .a = line.class, .b = other, .ka = line.node, .kb = @intCast(node) };
            }
            // Off the grid lines (a bend, a bar): move the node to other rows
            // than the wire's own device, or else other columns.
            const own = routeAnchor(s, r);
            if (cy[own] != cy[node]) return .{ .x_axis = false, .a = cy[own], .b = cy[node], .ka = own, .kb = @intCast(node) };
            if (cx[own] != cx[node]) return .{ .x_axis = true, .a = cx[own], .b = cx[node], .ka = own, .kb = @intCast(node) };
        }
    }
    // Two wires on one line: only segments on the same horizontal or
    // vertical line can overlap, and coordinates are whole numbers (§5), so
    // each segment is compared with the later ones on its line.
    var lines: std.AutoHashMapUnmanaged(struct { bool, i64 }, std.ArrayList(u32)) = .empty;
    defer {
        var it = lines.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        lines.deinit(gpa);
    }
    for (segs.items, 0..) |p, i| {
        const lp = p.line orelse continue;
        const ax: usize = if (lp.horizontal) 0 else 1;
        const gop = try lines.getOrPut(gpa, .{ lp.horizontal, @intFromFloat(@round(p.u[1 - ax])) });
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, @intCast(i));
    }
    for (segs.items, 0..) |p, i| {
        const lp0 = p.line orelse continue;
        const ax0: usize = if (lp0.horizontal) 0 else 1;
        const same = lines.get(.{ lp0.horizontal, @intFromFloat(@round(p.u[1 - ax0])) }).?.items;
        const after = same[std.mem.indexOfScalar(u32, same, @intCast(i)).? + 1 ..];
        for (after) |j| {
            const q = segs.items[j];
            if (p.net == q.net) continue;
            const lp = p.line orelse continue;
            const lq = q.line orelse continue;
            if (lp.horizontal != lq.horizontal or lp.class == lq.class) continue;
            const ax: usize = if (lp.horizontal) 0 else 1;
            if (@abs(p.u[1 - ax] - q.u[1 - ax]) > eps) continue;
            const lo = @max(@min(p.u[ax], p.v[ax]), @min(q.u[ax], q.v[ax]));
            const hi = @min(@max(p.u[ax], p.v[ax]), @max(q.u[ax], q.v[ax]));
            if (hi - lo <= eps) continue;
            return .{ .x_axis = !lp.horizontal, .a = lp.class, .b = lq.class, .ka = lp.node, .kb = lq.node };
        }
    }
    return null;
}

/// Boxes bucketed by x, one bucket per `width`, for finding the boxes a
/// segment may run through without testing every node.
const BoxGrid = struct {
    x0: f32,
    width: f32,
    /// Box indices per bucket, in box order.
    buckets: []std.ArrayList(u32),
    seen: []bool,

    fn init(gpa: Allocator, boxed: []const Boxed, width: f32) !BoxGrid {
        var x0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        for (boxed) |b| {
            x0 = @min(x0, b.box[0]);
            x1 = @max(x1, b.box[2]);
        }
        const count: usize = if (boxed.len == 0) 1 else @as(usize, @intFromFloat(@floor((x1 - x0) / width))) + 1;
        var g: BoxGrid = .{ .x0 = if (boxed.len == 0) 0 else x0, .width = width, .buckets = try gpa.alloc(std.ArrayList(u32), count), .seen = try gpa.alloc(bool, boxed.len) };
        @memset(g.buckets, .empty);
        @memset(g.seen, false);
        for (boxed, 0..) |b, i| {
            const lo, const hi = g.span(b.box[0], b.box[2]);
            for (g.buckets[lo .. hi + 1]) |*k| try k.append(gpa, @intCast(i));
        }
        return g;
    }
    fn deinit(g: *BoxGrid, gpa: Allocator) void {
        for (g.buckets) |*k| k.deinit(gpa);
        gpa.free(g.buckets);
        gpa.free(g.seen);
    }
    fn span(g: *const BoxGrid, a: f32, b: f32) struct { usize, usize } {
        const last: f32 = @floatFromInt(g.buckets.len - 1);
        const lo = std.math.clamp(@floor((a - g.x0) / g.width), 0, last);
        const hi = std.math.clamp(@floor((b - g.x0) / g.width), 0, last);
        return .{ @intFromFloat(lo), @intFromFloat(hi) };
    }
    /// The boxes in the buckets x-range [a, b] meets, ascending.
    fn near(g: *BoxGrid, gpa: Allocator, a: f32, b: f32, out: *std.ArrayList(u32)) !void {
        out.clearRetainingCapacity();
        const lo, const hi = g.span(a, b);
        for (g.buckets[lo .. hi + 1]) |k| for (k.items) |i| if (!g.seen[i]) {
            g.seen[i] = true;
            try out.append(gpa, i);
        };
        for (out.items) |i| g.seen[i] = false;
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    }
};

/// Does segment u–v run through `node`'s symbol (not its own ends)?
fn throughNode(u: [2]f32, v: [2]f32, owners: [3]u32, group: u32, box: ?[4]f32) bool {
    const b = box orelse return false;
    return @max(u[0], v[0]) > b[0] and @min(u[0], v[0]) < b[2] and
        @max(u[1], v[1]) > b[1] and @min(u[1], v[1]) < b[3] and
        std.mem.indexOfScalar(u32, &owners, group) == null;
}

/// Per node, the box a wire of another net must not enter: a device's core,
/// the whole body of a device spanning its copies (S1, on its middle copy),
/// the point of a terminal or label. Null for plain copies.
fn symbolBoxes(gpa: Allocator, s: *const Schematic) ![]?[4]f32 {
    const out = try gpa.alloc(?[4]f32, s.nodes.len);
    @memset(out, null);
    const spans = try spanningGroups(gpa, s);
    defer gpa.free(spans);
    const kinds = s.nodes.items(.kind);
    const groups = s.nodes.items(.group);
    const u = unitLen(s);
    for (0..s.nodes.len) |node| {
        const c = s.xy[node];
        const g = groups[node];
        if (kinds[node] != .device) {
            if (g == node) {
                if (kinds[node] == .terminal) if (railBox(s, @intCast(node))) |b| {
                    out[node] = .{ c[0] + @as(f32, @floatFromInt(b.min.x)), c[1] + @as(f32, @floatFromInt(b.min.y)), c[0] + @as(f32, @floatFromInt(b.max.x)), c[1] + @as(f32, @floatFromInt(b.max.y)) };
                    continue;
                };
                const m = 0.05 * u;
                out[node] = .{ c[0] - m, c[1] - m, c[0] + m, c[1] + m };
            }
            continue;
        }
        if (!spans[node]) {
            if (g == node) out[node] = .{ c[0] - 0.2 * u, c[1] - 0.2 * u, c[0] + 0.2 * u, c[1] + 0.2 * u };
            continue;
        }
        if (g != node) continue;
        out[node] = .{ c[0], c[1], c[0], c[1] };
    }
    // A spanning device's box: around all its copies, then the margin.
    for (groups, 0..) |g, other| {
        if (g == none or !spans[g] or kinds[g] != .device) continue;
        if (out[g]) |*b| {
            const o = s.xy[other];
            b.* = .{ @min(b[0], o[0]), @min(b[1], o[1]), @max(b[2], o[0]), @max(b[3], o[1]) };
        }
    }
    for (out, 0..) |*b, node| if (kinds[node] == .device and spans[node] and groups[node] == node) {
        const v = b.*.?;
        b.* = .{ v[0] - 0.32 * u, v[1] - 0.32 * u, v[2] + 0.42 * u, v[3] + 0.32 * u };
    };
    return out;
}

const Boxed = struct { node: u32, box: [4]f32 };

/// The nodes that have a box (`symbolBoxes`), in node order.
fn boxedNodes(gpa: Allocator, s: *const Schematic) ![]Boxed {
    const boxes = try symbolBoxes(gpa, s);
    defer gpa.free(boxes);
    var out: std.ArrayList(Boxed) = .empty;
    errdefer out.deinit(gpa);
    for (boxes, 0..) |b, node| if (b) |box| try out.append(gpa, .{ .node = @intCast(node), .box = box });
    return out.toOwnedSlice(gpa);
}

/// Per node: the root of a device whose symbol spans its copies (S1).
fn spanningGroups(gpa: Allocator, s: *const Schematic) ![]bool {
    const out = try gpa.alloc(bool, s.nodes.len);
    @memset(out, false);
    const kinds = s.nodes.items(.kind);
    const refs = s.nodes.items(.ref);
    const count = try gpa.alloc([4]u32, s.device_name.len);
    defer gpa.free(count);
    @memset(count, @splat(0));
    for (s.pins.items(.device), s.pins.items(.side)) |dev, side| {
        if (dev != none) count[dev][@intFromEnum(side)] += 1;
    }
    for (0..s.nodes.len) |node| {
        if (kinds[node] != .device) continue;
        const c = count[refs[node]];
        out[node] = @max(@max(c[0], c[1]), @max(c[2], c[3])) > 1;
    }
    return out;
}

/// The node a route belongs to, for separating it from a node it runs
/// through when it lies on no row or column line (bends, bars, bent edges).
fn routeAnchor(s: *const Schematic, r: Route) u32 {
    const homes = s.pins.items(.home);
    return switch (r.kind) {
        .edge => s.edges.items[r.id].a,
        .bar => homes[r.id],
        .join => homes[s.joins.items[r.id].p],
    };
}

// ===========================================================================
// Routes
// ===========================================================================

/// Where a wire meets a node: a device's pin is on its cell edge; terminals
/// and labels connect at their centre.
pub fn anchor(s: *const Schematic, node: u32, side: Side) [2]f32 {
    // Reach is measured from the device's middle copy (S1): along the pin's
    // own axis, a pin on an end copy sits where the symbol has it.
    var p = s.xy[node];
    const root = s.nodes.items(.group)[node];
    if (s.nodes.items(.kind)[node] == .device) {
        const ax: usize = if (side.isHorizontal()) 0 else 1;
        p[ax] = s.xy[root][ax];
    }
    return step(p, side, s.reach(node, side));
}

pub fn pinPoint(s: *const Schematic, pin: u32) [2]f32 {
    return anchor(s, s.pins.items(.home)[pin], s.pins.items(.side)[pin]);
}

fn step(p: [2]f32, side: Side, d: f32) [2]f32 {
    const v = side.vec();
    return .{ p[0] + d * v[0], p[1] + d * v[1] };
}

fn buildRoutes(gpa: Allocator, s: *Schematic, kept: []const bool, g: *const Layout) !void {
    const a = s.arena.allocator();
    s.routes.clearRetainingCapacity();
    const kinds = s.nodes.items(.kind);
    const groups = s.nodes.items(.group);
    const homes = s.pins.items(.home);
    const sides = s.pins.items(.side);

    for (s.edges.items, 0..) |e, id| {
        // Chains inside a device are drawn as bars; a leaf's chain is its rail.
        if (e.kind == .dropped or (e.kind == .chain and e.net == none)) continue;
        const r = edgeRoute(s, @intCast(id), kept[id], g);
        s.stats.bent += @intFromBool(!r.straight);
        try s.routes.append(a, r);
    }

    // S2 bars: a device pin whose straight edges end on other copies than
    // its own runs along them — however many edges it has left (one of a
    // fan's may have given way).
    // Each pin's straight edges, in edge order: off[p]..off[p + 1] in `ends`.
    const off = try gpa.alloc(u32, s.pins.len + 1);
    defer gpa.free(off);
    @memset(off, 0);
    for (s.edges.items) |e| {
        if (e.kind != .straight) continue;
        off[e.pa + 1] += 1;
        off[e.pb + 1] += 1;
    }
    for (1..off.len) |i| off[i] += off[i - 1];
    const ends = try gpa.alloc([2]f32, off[s.pins.len]);
    defer gpa.free(ends);
    {
        const fill = try gpa.dupe(u32, off[0..s.pins.len]);
        defer gpa.free(fill);
        for (s.edges.items) |e| {
            if (e.kind != .straight) continue;
            ends[fill[e.pa]] = anchor(s, e.a, e.side);
            fill[e.pa] += 1;
            ends[fill[e.pb]] = anchor(s, e.b, e.side.opposite());
            fill[e.pb] += 1;
        }
    }
    var pts: std.ArrayList([2]f32) = .empty;
    defer pts.deinit(gpa);
    for (0..s.pins.len) |p| {
        if (off[p + 1] == off[p] or kinds[homes[p]] != .device) continue;
        pts.clearRetainingCapacity();
        try pts.append(gpa, pinPoint(s, @intCast(p)));
        try pts.appendSlice(gpa, ends[off[p]..off[p + 1]]);
        const axis: usize = if (sides[p].isHorizontal()) 1 else 0;
        std.mem.sort([2]f32, pts.items, axis, struct {
            fn lt(ax: usize, x: [2]f32, y: [2]f32) bool {
                return x[ax] < y[ax];
            }
        }.lt);
        const grp = groups[homes[p]];
        for (pts.items[0 .. pts.items.len - 1], pts.items[1..]) |u, v| {
            if (u[axis] == v[axis]) continue;
            var r: Route = .{ .pts = undefined, .len = 2, .net = s.pins.items(.net)[p], .kind = .bar, .id = @intCast(p), .straight = true, .owners = .{ grp, none, none } };
            r.pts[0] = u;
            r.pts[1] = v;
            try s.routes.append(a, r);
        }
    }

    for (s.joins.items, 0..) |j, id| {
        if (!j.active) continue;
        if (joinRoute(s, @intCast(id), g)) |r| try s.routes.append(a, r);
    }
}

fn edgeRoute(s: *const Schematic, id: u32, keep: bool, g: *const Layout) Route {
    const e = s.edges.items[id];
    const groups = s.nodes.items(.group);
    const pu = anchor(s, e.a, e.side);
    const pv = anchor(s, e.b, e.side.opposite());
    var r: Route = .{ .pts = undefined, .len = 0, .net = e.net, .kind = .edge, .id = id, .straight = true, .owners = .{ groups[e.a], groups[e.b], none } };
    const aligned = if (e.side.isHorizontal()) pu[1] == pv[1] else pu[0] == pv[0];
    const reversed = if (e.side.isHorizontal()) pv[0] < pu[0] else pv[1] < pu[1];
    if (keep and aligned and !reversed) {
        r.pts[0] = pu;
        r.pts[1] = pv;
        r.len = 2;
        return r;
    }
    r.straight = false;
    const su = step(pu, e.side, units(s, g.bend));
    const sv = step(pv, e.side.opposite(), units(s, g.bend));
    if (reversed) {
        // Leave each end in its own pin direction and come around.
        if (e.side.isHorizontal()) {
            const m = if (pu[1] == pv[1]) pu[1] + unitLen(s) / 2 else snap((pu[1] + pv[1]) / 2);
            r.pts = .{ pu, su, .{ su[0], m }, .{ sv[0], m }, sv, pv };
        } else {
            const m = if (pu[0] == pv[0]) pu[0] + unitLen(s) / 2 else snap((pu[0] + pv[0]) / 2);
            r.pts = .{ pu, su, .{ m, su[1] }, .{ m, sv[1] }, sv, pv };
        }
        r.len = 6;
        return r;
    }
    const corner: [2]f32 = if (e.side.isHorizontal()) .{ su[0], pv[1] } else .{ pv[0], su[1] };
    r.pts[0] = pu;
    r.pts[1] = su;
    r.pts[2] = corner;
    r.pts[3] = pv;
    r.len = 4;
    return r;
}

fn joinRoute(s: *const Schematic, id: u32, g: *const Layout) ?Route {
    const j = s.joins.items[id];
    const homes = s.pins.items(.home);
    const sides = s.pins.items(.side);
    const groups = s.nodes.items(.group);
    var r: Route = .{ .pts = undefined, .len = 0, .net = j.net, .kind = .join, .id = id, .straight = true, .owners = .{ none, none, none } };
    switch (j.kind) {
        .cross => return null,
        .tap => {
            const pp = pinPoint(s, j.p);
            const e = s.edges.items[j.q];
            const end: [2]f32 = if (e.side == .down) .{ anchor(s, e.a, .down)[0], pp[1] } else .{ pp[0], anchor(s, e.a, .right)[1] };
            r.pts[0] = pp;
            r.pts[1] = end;
            r.len = 2;
            r.owners = .{ groups[homes[j.p]], groups[e.a], groups[e.b] };
        },
        .corner => {
            const pp = pinPoint(s, j.p);
            const pq = pinPoint(s, j.q);
            r.pts[0] = pp;
            r.pts[1] = if (sides[j.p].isHorizontal()) .{ pq[0], pp[1] } else .{ pp[0], pq[1] };
            r.pts[2] = pq;
            r.len = 3;
            r.owners = .{ groups[homes[j.p]], groups[homes[j.q]], none };
        },
        .bend => {
            // Around the device: out of each pin a quarter cell, then an L.
            const sp_side = sides[j.p];
            const sq_side = sides[j.q];
            const pp = pinPoint(s, j.p);
            const pq = pinPoint(s, j.q);
            const sp = step(pp, sp_side, units(s, g.bend));
            const sq = step(pq, sq_side, units(s, g.bend));
            r.owners = .{ groups[homes[j.p]], groups[homes[j.q]], none };
            if (sp_side.perpendicular(sq_side)) {
                const corner: [2]f32 = if (sp_side.isHorizontal()) .{ sp[0], sq[1] } else .{ sq[0], sp[1] };
                r.pts[0] = pp;
                r.pts[1] = sp;
                r.pts[2] = corner;
                r.pts[3] = sq;
                r.pts[4] = pq;
                r.len = 5;
            } else if (sp_side == sq_side) {
                r.pts[0] = pp;
                r.pts[1] = sp;
                r.pts[2] = if (sp_side.isHorizontal()) .{ sp[0], sq[1] } else .{ sq[0], sp[1] };
                r.pts[3] = sq;
                r.pts[4] = pq;
                r.len = 5;
            } else {
                // Opposite sides: around the whole body, on the side nearer
                // the second pin (a buffer's feedback runs under the op-amp
                // to its lower input).
                const grp = groups[homes[j.p]];
                var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
                var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
                for (groups, 0..) |gg, node| {
                    if (gg != grp) continue;
                    const c = s.xy[node];
                    lo = .{ @min(lo[0], c[0]), @min(lo[1], c[1]) };
                    hi = .{ @max(hi[0], c[0]), @max(hi[1], c[1]) };
                }
                const around: [2][2]f32 = if (sp_side.isHorizontal()) blk: {
                    const y = if (pq[1] > (lo[1] + hi[1]) / 2) hi[1] + unitLen(s) / 2 + units(s, g.bend) else lo[1] - unitLen(s) / 2 - units(s, g.bend);
                    break :blk .{ .{ sp[0], y }, .{ sq[0], y } };
                } else blk: {
                    const x = if (pq[0] > (lo[0] + hi[0]) / 2) hi[0] + unitLen(s) / 2 + units(s, g.bend) else lo[0] - unitLen(s) / 2 - units(s, g.bend);
                    break :blk .{ .{ x, sp[1] }, .{ x, sq[1] } };
                };
                r.pts = .{ pp, sp, around[0], around[1], sq, pq };
                r.len = 6;
            }
        },
    }
    return r;
}

// ===========================================================================
// Junction dots
// ===========================================================================

const eps: f32 = 1e-4;

fn near(p: [2]f32, q: [2]f32) bool {
    return @abs(p[0] - q[0]) < eps and @abs(p[1] - q[1]) < eps;
}

/// Is `p` strictly inside axis-aligned segment u–v?
fn inside(p: [2]f32, u: [2]f32, v: [2]f32) bool {
    if (@abs(u[1] - v[1]) < eps) {
        return @abs(p[1] - u[1]) < eps and p[0] > @min(u[0], v[0]) + eps and p[0] < @max(u[0], v[0]) - eps;
    }
    return @abs(p[0] - u[0]) < eps and p[1] > @min(u[1], v[1]) + eps and p[1] < @max(u[1], v[1]) - eps;
}

/// A dot wherever a net's wires leave a point in three or more directions
/// (a device lead counts as one). Overlapping wires of one net count once.
fn findDots(gpa: Allocator, s: *Schematic) !void {
    const a = s.arena.allocator();
    s.dots.clearRetainingCapacity();
    const Cand = struct { p: [2]f32, net: u32 };
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(gpa);
    for (s.routes.items) |r| for (r.pts[0..r.len]) |p| try cands.append(gpa, .{ .p = p, .net = r.net });
    for (s.joins.items) |j| {
        if (!j.active or j.kind != .cross) continue;
        const ev = s.edges.items[j.p];
        const eh = s.edges.items[j.q];
        try cands.append(gpa, .{ .p = .{ anchor(s, ev.a, .down)[0], anchor(s, eh.a, .right)[1] }, .net = j.net });
    }
    const pin_net = s.pins.items(.net);
    const pin_dev = s.pins.items(.device);
    const pin_side = s.pins.items(.side);
    // Routes and device pins by net.
    const nets = s.net_name.len;
    const r_off = try gpa.alloc(u32, nets + 1);
    defer gpa.free(r_off);
    const p_off = try gpa.alloc(u32, nets + 1);
    defer gpa.free(p_off);
    @memset(r_off, 0);
    @memset(p_off, 0);
    for (s.routes.items) |r| r_off[r.net + 1] += 1;
    for (pin_net, pin_dev) |n, d| if (d != none) {
        p_off[n + 1] += 1;
    };
    for (1..nets + 1) |i| {
        r_off[i] += r_off[i - 1];
        p_off[i] += p_off[i - 1];
    }
    const r_by_net = try gpa.alloc(u32, s.routes.items.len);
    defer gpa.free(r_by_net);
    const p_by_net = try gpa.alloc(u32, p_off[nets]);
    defer gpa.free(p_by_net);
    {
        const rf = try gpa.dupe(u32, r_off[0..nets]);
        defer gpa.free(rf);
        for (s.routes.items, 0..) |r, i| {
            r_by_net[rf[r.net]] = @intCast(i);
            rf[r.net] += 1;
        }
        const pf = try gpa.dupe(u32, p_off[0..nets]);
        defer gpa.free(pf);
        for (pin_net, pin_dev, 0..) |n, d, p| if (d != none) {
            p_by_net[pf[n]] = @intCast(p);
            pf[n] += 1;
        };
    }
    for (cands.items) |c| {
        var dirs: [4]bool = @splat(false);
        for (r_by_net[r_off[c.net]..r_off[c.net + 1]]) |ri| {
            const r = s.routes.items[ri];
            for (r.pts[0 .. r.len - 1], r.pts[1..r.len]) |u, v| {
                if (near(u, v)) continue;
                if (inside(c.p, u, v)) {
                    const horiz = @abs(u[1] - v[1]) < eps;
                    dirs[@intFromEnum(if (horiz) Side.left else Side.up)] = true;
                    dirs[@intFromEnum(if (horiz) Side.right else Side.down)] = true;
                } else if (near(c.p, u)) {
                    dirs[@intFromEnum(toward(u, v))] = true;
                } else if (near(c.p, v)) {
                    dirs[@intFromEnum(toward(v, u))] = true;
                }
            }
        }
        for (p_by_net[p_off[c.net]..p_off[c.net + 1]]) |p| {
            if (near(pinPoint(s, p), c.p)) dirs[@intFromEnum(pin_side[p].opposite())] = true;
        }
        var count: u32 = 0;
        for (dirs) |x| count += @intFromBool(x);
        if (count < 3) continue;
        for (s.dots.items) |d| {
            if (near(d, c.p)) break;
        } else try s.dots.append(a, c.p);
    }
}

/// Direction from u to v along an axis-aligned segment.
fn toward(u: [2]f32, v: [2]f32) Side {
    if (@abs(u[1] - v[1]) < eps) return if (v[0] > u[0]) .right else .left;
    return if (v[1] > u[1]) .down else .up;
}

// ===========================================================================
// Crossings (L7)
// ===========================================================================

/// Counts crossings and overlaps between nets and wires through nodes, and
/// reports the wires involved that can give way (L7): joins, straight edges,
/// and a fan bar through its pin's edges. Rails (a leaf's chain) never do.
fn measure(gpa: Allocator, s: *Schematic, blamed: *std.ArrayList(Wire)) !void {
    const Seg = struct { u: [2]f32, v: [2]f32, net: u32, route: u32 };
    var list: std.ArrayList(Seg) = .empty;
    defer list.deinit(gpa);
    for (s.routes.items, 0..) |r, ri| {
        for (0..r.len - 1) |k| {
            if (near(r.pts[k], r.pts[k + 1])) continue;
            try list.append(gpa, .{ .u = r.pts[k], .v = r.pts[k + 1], .net = r.net, .route = @intCast(ri) });
        }
    }
    const segs = list.items;
    const routes = s.routes.items;
    const horizontal = struct {
        fn f(g: Seg) bool {
            return @abs(g.u[1] - g.v[1]) < eps;
        }
    }.f;
    const blame = struct {
        fn f(gp: Allocator, out: *std.ArrayList(Wire), sc: *const Schematic, ri: u32) !void {
            const r = sc.routes.items[ri];
            switch (r.kind) {
                .join => try out.append(gp, .{ .kind = .join, .id = r.id }),
                .edge => if (givesWay(sc, r.id)) try out.append(gp, .{ .kind = .edge, .id = r.id }),
                .bar => for (sc.edges.items, 0..) |e, id| {
                    if ((e.pa == r.id or e.pb == r.id) and givesWay(sc, @intCast(id))) try out.append(gp, .{ .kind = .edge, .id = @intCast(id) });
                },
            }
        }
    }.f;

    for (segs, 0..) |p, i| for (segs[i + 1 ..]) |q| {
        if (p.net == q.net) continue;
        var hit = false;
        if (horizontal(p) != horizontal(q)) {
            const h = if (horizontal(p)) p else q;
            const v = if (horizontal(p)) q else p;
            const x = v.u[0];
            const y = h.u[1];
            if (x > @min(h.u[0], h.v[0]) + eps and x < @max(h.u[0], h.v[0]) - eps and
                y > @min(v.u[1], v.v[1]) + eps and y < @max(v.u[1], v.v[1]) - eps)
            {
                s.stats.crossings += 1;
                hit = true;
            }
        } else {
            const ax: usize = if (horizontal(p)) 0 else 1;
            const other = 1 - ax;
            if (@abs(p.u[other] - q.u[other]) < eps) {
                const lo = @max(@min(p.u[ax], p.v[ax]), @min(q.u[ax], q.v[ax]));
                const hi = @min(@max(p.u[ax], p.v[ax]), @max(q.u[ax], q.v[ax]));
                if (hi - lo > eps) {
                    s.stats.overlaps += 1;
                    hit = true;
                }
            }
        }
        // A wire ending on another net's wire looks connected.
        if (!hit and (inside(p.u, q.u, q.v) or inside(p.v, q.u, q.v) or inside(q.u, p.u, p.v) or inside(q.v, p.u, p.v))) {
            s.stats.overlaps += 1;
            hit = true;
        }
        if (hit) {
            try blame(gpa, blamed, s, p.route);
            try blame(gpa, blamed, s, q.route);
        }
    };

    // Wires through a node other than their own ends.
    const kinds = s.nodes.items(.kind);
    const groups = s.nodes.items(.group);
    const refs = s.nodes.items(.ref);
    const boxed = try boxedNodes(gpa, s);
    defer gpa.free(boxed);
    for (segs) |g| {
        const owners = routes[g.route].owners;
        for (boxed) |b| {
            if (kinds[b.node] != .device and refs[b.node] == g.net) continue;
            if (!throughNode(g.u, g.v, owners, groups[b.node], b.box)) continue;
            s.stats.overlaps += 1;
            try blame(gpa, blamed, s, g.route);
        }
    }
}

/// A straight edge can give way unless it is a label's own stub: that edge
/// is the label, and dropping it would only hang another.
fn givesWay(s: *const Schematic, e: u32) bool {
    const edge = s.edges.items[e];
    const kinds = s.nodes.items(.kind);
    // A terminal's own edge neither: a supply or ground cut loose floats.
    const fixed = struct {
        fn f(k: sch.NodeKind) bool {
            return k == .label or k == .terminal;
        }
    }.f;
    return edge.kind == .straight and !fixed(kinds[edge.a]) and !fixed(kinds[edge.b]);
}
