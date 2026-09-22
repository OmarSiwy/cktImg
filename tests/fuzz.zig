//! Random small netlists through the whole pipeline (`zig build fuzz`).
//! Checks that every layout ends and puts one node per cell, and reports,
//! for each rare case, how many netlists hit it and the smallest one — the
//! source of the example netlists for L2, L5 and L7 in ALGORITHM.md.

const std = @import("std");
const np = @import("NetlistParser");
const netlist = np.netlist;
const sch = np.schematic;
const lay = np.layout_engine;
const support = @import("support.zig");

const runs = 4000;

const Case = struct {
    name: []const u8,
    count: u32 = 0,
    len: usize = std.math.maxInt(usize),
    text: [1024]u8 = undefined,

    fn record(c: *Case, hit: bool, text: []const u8) void {
        if (!hit) return;
        c.count += 1;
        if (text.len >= c.len) return;
        c.len = text.len;
        @memcpy(c.text[0..text.len], text);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const nets = [_][]const u8{ "vdd", "0", "in", "out", "a", "b", "c" };
    var cases = [_]Case{
        .{ .name = "L2 collision (bent edge, no order conflict)" },
        .{ .name = "L5 order conflict" },
        .{ .name = "L7 a straight edge gave way (clean result)" },
        .{ .name = "residual crossing (rails / label stubs)" },
        .{ .name = "residual overlap (rails / label stubs)" },
        .{ .name = "S5 rail or junction re-dealt" },
    };
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);
    var prng = std.Random.DefaultPrng.init(12345);
    const r = prng.random();
    for (0..runs) |_| {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("fuzz\n.model nch nmos level=1\n.model pch pmos level=1\nVdd vdd 0 1.8\nVin in 0 ac 1\n");
        for (0..r.intRangeAtMost(u32, 2, 6)) |i| {
            const p = nets[r.intRangeLessThan(usize, 0, nets.len)];
            const q = nets[r.intRangeLessThan(usize, 0, nets.len)];
            const g = nets[r.intRangeLessThan(usize, 0, nets.len)];
            switch (r.intRangeAtMost(u32, 0, 3)) {
                0 => try w.print("R{d} {s} {s} 1k\n", .{ i, p, q }),
                1 => try w.print("C{d} {s} {s} 1p\n", .{ i, p, q }),
                2 => try w.print("M{d} {s} {s} {s} 0 nch\n", .{ i, p, g, q }),
                else => try w.print("M{d} {s} {s} {s} vdd pch\n", .{ i, p, g, q }),
            }
        }
        const text = w.buffered();
        var nl = netlist.parse(gpa, &.{text}, null) catch continue;
        defer nl.deinit(gpa);
        const roles = try sch.guessRoles(gpa, &nl);
        defer gpa.free(roles);
        var s = try sch.build(gpa, &nl, roles, lib);
        defer s.deinit();
        try lay.layout(gpa, &s, &.default);

        for (s.pos, 0..) |p, i| for (s.pos[i + 1 ..]) |q| {
            if (p[0] == q[0] and p[1] == q[1]) {
                std.debug.print("two nodes on one cell:\n{s}\n", .{text});
                return error.SharedCell;
            }
        };
        const t = s.stats;
        var dropped: u32 = 0;
        for (s.edges.items) |e| dropped += @intFromBool(e.kind == .dropped);
        cases[0].record(t.bent > 0 and t.conflicts == 0, text);
        cases[1].record(t.conflicts > 0, text);
        cases[2].record(dropped > 0 and t.crossings == 0 and t.overlaps == 0, text);
        cases[3].record(t.crossings > 0, text);
        cases[4].record(t.overlaps > 0, text);
        cases[5].record(t.redealt, text);
    }
    std.debug.print("{d} random netlists: every layout ended, one node per cell\n", .{runs});
    for (cases) |c| {
        std.debug.print("\n== {s}: {d}\n", .{ c.name, c.count });
        if (c.count > 0) std.debug.print("{s}", .{c.text[0..c.len]});
    }
}
