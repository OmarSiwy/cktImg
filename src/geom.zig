//! Answers every renderer of a `Placed` needs and must not work out on its
//! own: where a symbol's stroke lands, and where a device's name fits. Two
//! renderers that each placed their own names would disagree, so both the
//! C accessors and the TikZ emitter ask here (as in cktImg).

const std = @import("std");
const Allocator = std.mem.Allocator;
const library = @import("library.zig");
const placed_mod = @import("placed.zig");

const Pt = library.Pt;
const Rect = library.Rect;
const Orient = library.Orient;
const Library = library.Library;
const Placed = placed_mod.Placed;

/// Name text: advance per character, cap height, descent, gap to a symbol.
pub const char_w: i32 = 5;
pub const text_h: i32 = 7;
pub const descent: i32 = 2;
pub const label_gap: i32 = 3;
/// Dot radii: a pin, a junction (larger, so a T reads as a connection).
pub const pin_dot_r: i32 = 2;
pub const junction_dot_r: i32 = 3;

/// A canonical symbol point, placed: orient, then move to `base`.
pub fn placePoint(o: Orient, base: Pt, p: Pt) Pt {
    return base.add(o.apply(p));
}

/// Width a name is set in, forced by every renderer so the box a label was
/// collided against is the box it occupies.
pub fn refdesWidth(name: []const u8) i32 {
    return char_w * @as(i32, @intCast(name.len)) + 2;
}

/// The box a name occupies with its anchor at the left end of the baseline.
pub fn refdesRect(anchor: Pt, name: []const u8) Rect {
    return .{
        .min = .{ .x = anchor.x, .y = anchor.y - text_h },
        .max = .{ .x = anchor.x + refdesWidth(name), .y = anchor.y + descent },
    };
}

/// One anchor per device for its name: left end of the baseline. Tries
/// right of the symbol, then above and below that, then the same on the left,
/// and takes the first spot clear of symbols, wires and names placed so far —
/// so the answer depends on order, and is computed for all devices at once.
/// Unnamed devices (the rails and ports the layout added) get their origin.
///
/// Caller owns the result.
pub fn refdesAnchors(gpa: Allocator, p: *const Placed, lib: *const Library) Allocator.Error![]Pt {
    const n = p.deviceCount();
    const anchors = try gpa.alloc(Pt, n);
    errdefer gpa.free(anchors);
    var obstacles: std.ArrayList(Rect) = .empty;
    defer obstacles.deinit(gpa);
    for (0..n) |d| try obstacles.append(gpa, p.deviceRect(lib, d));
    for (0..p.netCount()) |net| {
        var it = p.segments(net);
        while (it.next()) |poly| for (poly[0 .. poly.len - 1], poly[1..]) |a, b| try obstacles.append(gpa, Rect.fromCorners(a, b));
    }
    const step = text_h + descent + label_gap;
    for (0..n) |d| {
        const name = p.dev_name[d];
        if (name.len == 0) {
            anchors[d] = p.dev_pos[d];
            continue;
        }
        const box = p.deviceRect(lib, d);
        const w = refdesWidth(name);
        const y = p.dev_pos[d].y;
        const right = box.max.x + label_gap;
        const left = box.min.x - label_gap - w;
        const candidates = [6]Pt{
            .{ .x = right, .y = y },
            .{ .x = right, .y = y - step },
            .{ .x = right, .y = y + step },
            .{ .x = left, .y = y },
            .{ .x = left, .y = y - step },
            .{ .x = left, .y = y + step },
        };
        var at = candidates[0];
        for (candidates) |c| {
            const r = refdesRect(c, name);
            for (obstacles.items) |o| {
                if (o.intersects(r)) break;
            } else {
                at = c;
                break;
            }
        }
        try obstacles.append(gpa, refdesRect(at, name));
        anchors[d] = at;
    }
    return anchors;
}

/// The side a pin's name goes on: away from the wire that meets it (a port
/// whose wire leaves to the right is named on its left). Right when no wire
/// meets it.
pub fn nameSide(p: *const Placed, pin: u32) library.Side {
    const at = p.pin_xy[pin];
    const net = p.pin_net[pin];
    if (net == placed_mod.no_net) return .right;
    var it = p.segments(net);
    while (it.next()) |poly| {
        const ends = [2][2]Pt{ .{ poly[0], poly[1] }, .{ poly[poly.len - 1], poly[poly.len - 2] } };
        for (ends) |e| {
            if (!e[0].eql(at)) continue;
            if (e[1].x > at.x) return .left;
            if (e[1].x < at.x) return .right;
            if (e[1].y > at.y) return .up;
            return .down;
        }
    }
    return .right;
}

/// Whether a rail's net name is worth writing: not for the ground net "0".
pub fn namesRail(net_name: []const u8) bool {
    return !std.mem.eql(u8, net_name, "0");
}
