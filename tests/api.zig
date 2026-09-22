//! The public surface, as a caller uses it: the tiers agree, the result is
//! well-formed plain data, and nothing is lost between netlist and drawing.

const std = @import("std");
const testing = std.testing;
const np = @import("NetlistParser");
const support = @import("support.zig");
const textbook = @import("textbook.zig");

fn placeText(lib: *np.Library, src: []const u8) !np.Placed {
    return np.place(testing.allocator, &.default, lib, &.{src}, null);
}

/// Wires are Manhattan polylines; every pin with company on its net is on a
/// wire of that net, a label of it, or a symbol of it — nothing floats.
fn expectWellFormed(p: *const np.Placed, lib: *const np.Library) !void {
    try testing.expectEqual(p.netCount() + 1, p.net_seg.len);
    for (0..p.netCount()) |n| {
        var it = p.segments(n);
        while (it.next()) |poly| {
            try testing.expect(poly.len >= 2);
            for (poly[0 .. poly.len - 1], poly[1..]) |a, b| try testing.expect(a.x == b.x or a.y == b.y);
        }
    }
    var count: []u32 = try testing.allocator.alloc(u32, p.netCount());
    defer testing.allocator.free(count);
    @memset(count, 0);
    for (p.pin_net) |n| if (n != np.placed.no_net) {
        count[n] += 1;
    };
    for (0..p.deviceCount()) |d| {
        const class = lib.at(p.dev_class[d]);
        const lo, const hi = p.pinRange(d);
        for (lo..hi) |pin| {
            const n = p.pin_net[pin];
            const k = pin - lo;
            if (n == np.placed.no_net or k >= class.terminals.len or class.terminals[k].hidden) continue;
            if (count[n] < 2) continue;
            if (class.terminals[k].ground_ref) continue; // may be left unwired on ground
            const at = p.pin_xy[pin];
            var found = false;
            var it = p.segments(n);
            while (it.next()) |poly| for (poly[0 .. poly.len - 1], poly[1..]) |a, b| {
                if (np.Rect.fromCorners(a, b).contains(at)) found = true;
            };
            for (p.labels) |l| found = found or (l.net == n and l.at.eql(at));
            // A lone terminal symbol on the pin itself names it.
            for (0..p.deviceCount()) |e| {
                if (e == d) continue;
                const elo, const ehi = p.pinRange(e);
                for (elo..ehi) |q| found = found or (p.pin_net[q] == n and p.pin_xy[q].eql(at));
            }
            if (!found) {
                std.debug.print("pin {d} of {s} ({s}) on net {s} at {any} touches nothing\n", .{ k, p.dev_name[d], class.name, p.net_name[n], at });
                return error.FloatingPin;
            }
        }
    }
}

test "place: one call and the stages give the same drawing" {
    const gpa = testing.allocator;
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    const src = textbook.all[2].spice;
    var one = try placeText(lib, src);
    defer one.deinit();

    var nl = try np.netlist.parse(gpa, &.{src}, null);
    defer nl.deinit(gpa);
    const roles = try np.guessRoles(gpa, &nl);
    defer gpa.free(roles);
    var s = try np.Schematic.build(gpa, &nl, roles, lib);
    defer s.deinit();
    try np.layout(gpa, &s, &.default);
    var staged = try np.Placed.init(gpa, &s, &nl);
    defer staged.deinit();

    try testing.expectEqualSlices(np.Pt, one.dev_pos, staged.dev_pos);
    try testing.expectEqualSlices(np.Pt, one.wire_pts, staged.wire_pts);
}

test "pipeline: borrowed results, pages kept across documents" {
    const gpa = testing.allocator;
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    var p = np.Pipeline.init(gpa, &.default, lib);
    defer p.deinit();
    for (textbook.all) |c| {
        const got = try p.run(&.{c.spice}, null);
        var own = try placeText(lib, c.spice);
        defer own.deinit();
        try testing.expectEqualSlices(np.Pt, own.pin_xy, got.pin_xy);
    }
}

test "placed: every textbook drawing is well-formed and loses no device" {
    const gpa = testing.allocator;
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    for (textbook.all ++ textbook.beyond) |c| {
        errdefer std.debug.print("circuit: {s}\n", .{c.name});
        var p = try placeText(lib, c.spice);
        defer p.deinit();
        try expectWellFormed(&p, lib);
        // Every netlist device with a pin is drawn exactly once (drivers apart).
        var nl = try np.netlist.parse(gpa, &.{c.spice}, null);
        defer nl.deinit(gpa);
        for (nl.graph.edges.items(.name)) |name| {
            var seen: u32 = 0;
            for (p.dev_name) |dn| seen += @intFromBool(std.mem.eql(u8, dn, name));
            try testing.expectEqual(1, seen);
        }
    }
}

test "placed: a driver stands apart, between its terminal symbol and ground" {
    const gpa = testing.allocator;
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    var p = try placeText(lib, textbook.all[1].spice); // cs_resistive: Vdd and Vin drive terminals
    defer p.deinit();
    const vdd = for (p.dev_name, 0..) |n, d| {
        if (std.mem.eql(u8, n, "vdd")) break d;
    } else unreachable;
    // Left of everything else that is not an island.
    const rd = for (p.dev_name, 0..) |n, d| {
        if (std.mem.eql(u8, n, "rd")) break d;
    } else unreachable;
    try testing.expect(p.dev_pos[vdd].x < p.dev_pos[rd].x);
    // Its + pin (on net vdd) is above its - pin, each wired to a symbol.
    const lo, _ = p.pinRange(vdd);
    try testing.expect(p.pin_xy[lo].y < p.pin_xy[lo + 1].y);
    var rails: u32 = 0;
    for (p.dev_class, p.dev_name) |c, n| rails += @intFromBool(n.len == 0 and lib.at(c).role == .power_rail);
    try testing.expectEqual(2, rails); // the circuit's rail and the island's
}

test "placed: a pin off the layout's line gets a lead onto it" {
    // The op-amp's inputs are 40 apart on the symbol; the copies the layout
    // splits it into are a pitch apart. Either way, the wires end on the pins.
    const gpa = testing.allocator;
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    var cfg: np.Config = .default;
    cfg.layout.min_pitch = 1.5;
    var p = try np.place(gpa, &cfg, lib, &.{textbook.all[13].spice}, null);
    defer p.deinit();
    try expectWellFormed(&p, lib);
}

test "placed: a device kind with no class is drawn as a generated box" {
    const gpa = testing.allocator;
    var lib = np.Library.init(gpa);
    defer lib.deinit();
    var p = try placeText(&lib, "t\nR1 a b 1k\nR2 b 0 1k\n");
    defer p.deinit();
    try testing.expect(lib.isGeneric(p.dev_class[0]));
}

const with_block =
    \\Non-inverting amplifier around an op-amp block
    \\.subckt opamp inp inn out vdd vss
    \\*@ left inp inn
    \\*@ right out
    \\E1 out 0 inp inn 1e5
    \\R1 vdd vss 1meg
    \\.ends
    \\Vdd vdd 0 1.8
    \\Vin in 0 ac 1
    \\X1 in fb out vdd 0 opamp
    \\Rf out fb 10k
    \\Rg fb 0 1k
;

test "blocks: a subcircuit is one block, its ports on the sides its directives say" {
    const gpa = testing.allocator;
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    var s: np.Schematic = undefined;
    var nl = try np.netlist.parse(gpa, &.{with_block}, null);
    defer nl.deinit(gpa);
    const roles = try np.guessRoles(gpa, &nl);
    defer gpa.free(roles);
    s = try np.Schematic.build(gpa, &nl, roles, lib);
    defer s.deinit();
    try np.layout(gpa, &s, &.default);
    try testing.expectEqual(0, s.stats.crossings);
    try testing.expectEqual(0, s.stats.overlaps);
    var p = try np.Placed.init(gpa, &s, &nl);
    defer p.deinit();
    try expectWellFormed(&p, lib);

    const x = for (p.dev_name, 0..) |n, d| {
        if (std.mem.eql(u8, n, "x1")) break d;
    } else return error.NoBlock;
    try testing.expectEqualStrings("block:opamp", lib.at(p.dev_class[x]).name);
    // Nothing from inside is drawn.
    for (p.dev_name) |n| try testing.expect(std.mem.indexOf(u8, n, ".x1.") == null);
    // inp and inn on the left, inp above inn; out on the right.
    const lo, _ = p.pinRange(x);
    const at = p.dev_pos[x];
    try testing.expect(p.pin_xy[lo].x < at.x and p.pin_xy[lo + 1].x < at.x);
    try testing.expect(p.pin_xy[lo].y < p.pin_xy[lo + 1].y);
    try testing.expect(p.pin_xy[lo + 2].x > at.x);
}

test "blocks: *@ expand draws what is inside instead" {
    const gpa = testing.allocator;
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    const src = try std.mem.replaceOwned(u8, gpa, with_block, "*@ right out", "*@ right out\n*@ expand");
    defer gpa.free(src);
    var p = try placeText(lib, src);
    defer p.deinit();
    try expectWellFormed(&p, lib);
    var inside: u32 = 0;
    for (p.dev_name, p.dev_class) |n, c| {
        try testing.expect(!std.mem.startsWith(u8, lib.at(c).name, "block:"));
        inside += @intFromBool(std.mem.eql(u8, n, "e.x1.e1") or std.mem.eql(u8, n, "r.x1.r1"));
    }
    try testing.expectEqual(2, inside);
}
