//! What every test needs from outside the library: a symbol set.

const std = @import("std");
const np = @import("NetlistParser");

pub const symbols = @embedFile("symbols.zon");

/// The standard symbol set (`symbols.zon`), on the heap so that schematics
/// can point at it while their owner moves.
pub fn library(gpa: std.mem.Allocator) !*np.Library {
    const lib = try gpa.create(np.Library);
    errdefer gpa.destroy(lib);
    lib.* = .init(gpa);
    errdefer lib.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: std.ArrayList(np.library.ZonDiagnostic) = .empty;
    try lib.loadZon(arena.allocator(), symbols, &diags);
    for (diags.items) |d| std.debug.print("symbols.zon: {s}: {s}\n", .{ d.class, @errorName(d.err) });
    if (diags.items.len > 0) return error.BadSymbols;
    return lib;
}

pub fn freeLibrary(gpa: std.mem.Allocator, lib: *np.Library) void {
    lib.deinit();
    gpa.destroy(lib);
}

/// Contacts a netlister that joins by touch (xschem) reads as shorts: a wire
/// segment of one net through or onto a point of another — a pin, a wire
/// end or bend, a label. Two nets' segments overlapping along a line
/// are among them: one holds an end of the other. Returns how many nets have
/// a wire making one; prints the first of each when `print`.
// ponytail: every segment against every point, quadratic; fine at test sizes.
pub fn shorts(gpa: std.mem.Allocator, p: *const np.Placed, print: bool) !u32 {
    const Point = struct { at: np.Pt, net: u32, what: []const u8 };
    var pts: std.ArrayList(Point) = .empty;
    defer pts.deinit(gpa);
    // Every pin, a MOS body past the symbol's terminals too: a target whose
    // symbol has one (xschem's) draws it at the device's origin, its point.
    for (p.pin_xy, p.pin_net) |at, n| if (n != np.placed.no_net) {
        try pts.append(gpa, .{ .at = at, .net = n, .what = "pin" });
    };
    for (p.labels) |l| try pts.append(gpa, .{ .at = l.at, .net = l.net, .what = "label" });
    for (0..p.netCount()) |n| {
        var it = p.segments(n);
        while (it.next()) |poly| for (poly) |at| try pts.append(gpa, .{ .at = at, .net = @intCast(n), .what = "wire end" });
    }
    const bad = try gpa.alloc(bool, p.netCount());
    defer gpa.free(bad);
    @memset(bad, false);
    for (0..p.netCount()) |n| {
        var it = p.segments(n);
        while (it.next()) |poly| for (poly[0 .. poly.len - 1], poly[1..]) |a, b| {
            const r = np.Rect.fromCorners(a, b);
            for (pts.items) |q| {
                if (q.net == n or !r.contains(q.at)) continue;
                if (print and !bad[n]) std.debug.print("net {s}: wire {any}-{any} touches a {s} of net {s} at {any}\n", .{ p.net_name[n], a, b, q.what, p.net_name[q.net], q.at });
                bad[n] = true;
            }
        };
    }
    var count: u32 = 0;
    for (bad) |b| count += @intFromBool(b);
    return count;
}
