//! Behavioral suite for the device vocabulary and the placed-geometry helpers.
//!
//! Two halves. The first pins the *catalog invariants* — the properties the generated table
//! must satisfy for every one of the 96 classes, not just the twelve specimens checked in
//! today. Those are the tests that make machine conversion safe: a generator that drops a
//! role mapping or truncates a coordinate fails here rather than in a drawing three stages
//! downstream. The second half pins the runtime table's index stability and the geometry
//! answers that `geom.zig` exists to keep single-sourced.
//!
//! Expected red until the corresponding function is written. Anything asserting the *table*
//! rather than a function passes today, and that is the point: the data is real.

const std = @import("std");
const ckt = @import("cktimg");

const catalog = ckt.devices.catalog;
const host = ckt.devices.host;
const geom = ckt.geom;
const ids = ckt.ids;

const Allocator = std.mem.Allocator;
const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;
const SymbolIdx = ids.SymbolIdx;
const StrId = ids.StrId;
const Terminal = catalog.Terminal;
const DrawOp = catalog.DrawOp;

// ---------------------------------------------------------------------------
// Fixtures
//
// Built straight out of the public struct fields with an arena, deliberately bypassing the
// front end and the interner: a devices/geometry suite that cannot run until the SPICE parser
// works would be useless for driving this file's implementation order.
// ---------------------------------------------------------------------------

/// Minimal stand-in for the interner: appends NUL-terminated bytes and records spans, exactly
/// as `strings.Interner` documents, without needing it to be implemented.
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

const Dev = struct {
    name: []const u8,
    class: []const u8,
    at: Pt,
    orient: Orient = .{},
};

const Sch = struct {
    ir: ckt.Ir,
    phys: ckt.Physical,
    strings: ckt.Strings,
};

/// Assemble a placed schematic from a device list plus an optional group record.
///
/// Every array is arena-backed, so the caller's `arena.deinit()` is the whole teardown and
/// `std.testing.allocator` still audits it. Pin coordinates are computed here with
/// `ids.Orient.apply` directly rather than through `geom.pinPoint`, so the fixture stays
/// valid input even while that function is a stub.
fn build(
    arena: Allocator,
    devs: []const Dev,
    group_paths: []const []const u8,
    group_masters: []const []const u8,
) !Sch {
    std.debug.assert(group_paths.len == group_masters.len);

    var pool: Pool = .{};
    _ = try pool.add(arena, ""); // StrId.empty, as every pool assigns first

    var pin_total: usize = 0;
    for (devs) |d| pin_total += catalog.at(catalog.indexOf(d.class).?).terminals.len;

    const dev_symbol = try arena.alloc(SymbolIdx, devs.len);
    const dev_orient = try arena.alloc(Orient, devs.len);
    const dev_name = try arena.alloc(StrId, devs.len);
    const dev_value = try arena.alloc(StrId, devs.len);
    const dev_pin0 = try arena.alloc(u32, devs.len + 1);
    const pin_net = try arena.alloc(ids.NetIdx, pin_total);
    const pos = try arena.alloc(Pt, devs.len);
    const pin_xy = try arena.alloc(Pt, pin_total);

    var next_pin: u32 = 0;
    for (devs, 0..) |d, i| {
        const idx = catalog.indexOf(d.class).?;
        const class = catalog.at(idx);
        dev_symbol[i] = idx;
        dev_orient[i] = d.orient;
        dev_name[i] = try pool.add(arena, d.name);
        dev_value[i] = .empty;
        dev_pin0[i] = next_pin;
        pos[i] = d.at;
        for (class.terminals) |t| {
            pin_net[next_pin] = .none;
            pin_xy[next_pin] = d.at.add(d.orient.apply(t.at));
            next_pin += 1;
        }
    }
    dev_pin0[devs.len] = next_pin;

    const group_path = try arena.alloc(StrId, group_paths.len);
    const group_master = try arena.alloc(StrId, group_paths.len);
    for (group_paths, group_masters, 0..) |p, m, i| {
        group_path[i] = try pool.add(arena, p);
        group_master[i] = try pool.add(arena, m);
    }

    // No nets and no wires: CSR offset arrays still have to terminate correctly.
    const net_seg = try arena.alloc(u32, 1);
    net_seg[0] = 0;
    const seg_pt = try arena.alloc(u32, 1);
    seg_pt[0] = 0;

    return .{
        .ir = .{
            .dev_symbol = dev_symbol,
            .dev_orient = dev_orient,
            .dev_pin0 = dev_pin0,
            .pin_net = pin_net,
            .dev_name = dev_name,
            .dev_value = dev_value,
            .net_name = &.{},
            .group_path = group_path,
            .group_master = group_master,
        },
        .phys = .{
            .pos = pos,
            .pin_xy = pin_xy,
            .net_seg = net_seg,
            .seg_pt = seg_pt,
            .wire_pts = &.{},
            .junctions = &.{},
            .labels = &.{},
        },
        .strings = pool.finish(),
    };
}

/// Does any terminal of `class` carry `role`?
fn hasRole(class: catalog.DeviceClass, role: catalog.TerminalRole) bool {
    for (class.terminals) |t| if (t.role == role) return true;
    return false;
}

/// x extent of a draw op, ignoring y — the cell-width guard only cares about x.
fn opXExtent(op: DrawOp) struct { i32, i32 } {
    return switch (op) {
        .line => |l| .{ @min(l.a.x, l.b.x), @max(l.a.x, l.b.x) },
        .circle => |c| .{ c.c.x - c.r, c.c.x + c.r },
        .polyline => |pts| blk: {
            var lo: i32 = std.math.maxInt(i32);
            var hi: i32 = std.math.minInt(i32);
            for (pts) |p| {
                lo = @min(lo, p.x);
                hi = @max(hi, p.x);
            }
            break :blk .{ lo, hi };
        },
        .text => |t| blk: {
            const half = @divTrunc(catalog.textWidth(t.s, t.size), 2);
            break :blk .{ t.at.x - half, t.at.x + half };
        },
    };
}

// ---------------------------------------------------------------------------
// Catalog: the table itself
// ---------------------------------------------------------------------------

test "every builtin class resolves by its own name to its own index" {
    for (catalog.classes, 0..) |class, i| {
        const idx = catalog.indexOf(class.name) orelse {
            std.debug.print("class {s} is not in the name index\n", .{class.name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(i, idx.i());
        try std.testing.expectEqualStrings(class.name, catalog.at(idx).name);
    }
}

test "the name index covers the table exactly, so the two cannot diverge" {
    // The Rust original hand-maintained the PHF beside CLASSES and needed a test to catch
    // them drifting. Here the map is derived, so this asserts the derivation rather than
    // guarding a copy-paste.
    try std.testing.expectEqual(catalog.classes.len, catalog.builtin_count);
    for (catalog.classes) |class| try std.testing.expect(catalog.isBuiltin(class.name));
    try std.testing.expect(!catalog.isBuiltin("no_such_class"));
    try std.testing.expect(catalog.indexOf("no_such_class") == null);
}

test "class lookup resolves at comptime, so static data costs no runtime hashing" {
    comptime {
        const idx = catalog.indexOf("nmos") orelse unreachable;
        std.debug.assert(std.mem.eql(u8, catalog.at(idx).name, "nmos"));
        std.debug.assert(catalog.at(idx).prefix == 'M');
        std.debug.assert(catalog.indexOf("definitely_not_a_class") == null);
        // Names are the map's keys; a comptime-known miss folds to null with no code emitted.
        std.debug.assert(catalog.builtin_count == catalog.classes.len);
    }
}

test "class names are lowercase, because lookup does not fold case" {
    for (catalog.classes) |class| {
        for (class.name) |c| try std.testing.expect(!std.ascii.isUpper(c));
        try std.testing.expect(class.name.len > 0);
    }
}

test "every class is fully defined: terminals, a body, and distinct anchors" {
    for (catalog.classes) |class| {
        try std.testing.expect(class.terminals.len > 0);
        try std.testing.expect(class.draw.len > 0);
        for (class.terminals, 0..) |a, i| {
            for (class.terminals[i + 1 ..]) |b| {
                try std.testing.expect(!a.at.eql(b.at));
                try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
            }
        }
    }
}

test "a multi-terminal class occupies both conduction-axis edges" {
    // The packing condition: any device lines up with any other, so a resistor's pins meet a
    // MOSFET's drain and source without a jog.
    const left: Pt = .{ .x = -20, .y = 0 };
    const right: Pt = .{ .x = 20, .y = 0 };
    for (catalog.classes) |class| {
        if (class.terminals.len == 1) continue;
        var has_left = false;
        var has_right = false;
        for (class.terminals) |t| {
            has_left = has_left or t.at.eql(left);
            has_right = has_right or t.at.eql(right);
        }
        try std.testing.expect(has_left);
        try std.testing.expect(has_right);
        // Every auxiliary terminal is off the axis, so it cannot be mistaken for an edge.
        for (class.terminals) |t| {
            if (t.at.eql(left) or t.at.eql(right)) continue;
            try std.testing.expect(t.at.y != 0);
        }
    }
}

test "a single-terminal class taps the origin" {
    for (catalog.classes) |class| {
        if (class.terminals.len != 1) continue;
        try std.testing.expectEqual(Pt.zero, class.terminals[0].at);
    }
}

test "conduction terminals sit at the bipole edges on y = 0" {
    for (catalog.classes) |class| {
        for (class.terminals) |t| switch (t.role) {
            .drain, .source, .collector, .emitter, .anode, .cathode => {
                try std.testing.expectEqual(@as(i32, 0), t.at.y);
                try std.testing.expect(t.at.x == -catalog.cell_half or t.at.x == catalog.cell_half);
            },
            else => {},
        };
    }
}

test "no glyph point exceeds the cell half-width" {
    // A body wider than its cell would be clipped by the column pitch, so this is the guard
    // the generator has to satisfy for every converted class.
    for (catalog.classes) |class| {
        for (class.terminals) |t| try std.testing.expect(@abs(t.at.x) <= catalog.cell_half);
        for (class.draw) |op| {
            const lo, const hi = opXExtent(op);
            try std.testing.expect(lo >= -catalog.cell_half);
            try std.testing.expect(hi <= catalog.cell_half);
        }
    }
}

test "the refdes prefix agrees with the terminal roles it carries" {
    for (catalog.classes) |class| {
        const mosish = hasRole(class, .drain) or hasRole(class, .source);
        const bjtish = hasRole(class, .collector) or hasRole(class, .emitter);
        const diodeish = hasRole(class, .anode) or hasRole(class, .cathode);

        if (mosish) {
            // MOSFET 'M', JFET 'J', MESFET 'Z' — the three SPICE cards with a channel.
            try std.testing.expect(class.prefix == 'M' or class.prefix == 'J' or class.prefix == 'Z');
        }
        if (bjtish) try std.testing.expectEqual(@as(u8, 'Q'), class.prefix);
        if (diodeish) try std.testing.expectEqual(@as(u8, 'D'), class.prefix);
        try std.testing.expect(!(mosish and bjtish));

        // A placement role means a rail or port: no element card, exactly one terminal.
        if (class.role != .none) {
            try std.testing.expectEqual(@as(u8, ' '), class.prefix);
            try std.testing.expectEqual(@as(usize, 1), class.terminals.len);
        }
        if (class.prefix == ' ') try std.testing.expect(class.role != .none);
        if (class.prefix != ' ') try std.testing.expect(std.ascii.isUpper(class.prefix));
    }
}

test "control terminals do not conduct and conducting ones are not controls" {
    const R = catalog.TerminalRole;
    try std.testing.expect(R.collector.conducts());
    try std.testing.expect(R.passive.conducts());
    try std.testing.expect(!R.base.conducts());
    try std.testing.expect(!R.gate.conducts());
    try std.testing.expect(!R.bulk.conducts());
    try std.testing.expect(R.gate.isControl() and R.base.isControl());
    try std.testing.expect(!R.drain.isControl());
    // The two predicates partition the roles that appear on a spine.
    for (catalog.classes) |class| {
        for (class.terminals) |t| {
            try std.testing.expect(!(t.role.conducts() and t.role.isControl()));
        }
    }
}

test "a terminal role resolves to its pin slot in SPICE node order" {
    const nmos = catalog.at(catalog.indexOf("nmos").?);
    try std.testing.expectEqual(@as(?u8, 0), nmos.termSlot(.drain));
    try std.testing.expectEqual(@as(?u8, 1), nmos.termSlot(.gate));
    try std.testing.expectEqual(@as(?u8, 2), nmos.termSlot(.source));
    try std.testing.expectEqual(@as(?u8, null), nmos.termSlot(.base));
    const npn = catalog.at(catalog.indexOf("npn").?);
    try std.testing.expectEqual(@as(?u8, 1), npn.termSlot(.base));
}

test "electrical defaults survive the conversion" {
    const res = catalog.at(catalog.indexOf("res").?);
    try std.testing.expectEqual(@as(u8, 'R'), res.prefix);
    try std.testing.expectEqualStrings("1k", res.default_value);
    const cap = catalog.at(catalog.indexOf("cap").?);
    try std.testing.expectEqualStrings("1u", cap.default_value);
    try std.testing.expectEqual(catalog.SymbolRole.power_rail, catalog.at(catalog.indexOf("vdd").?).role);
    try std.testing.expectEqual(catalog.SymbolRole.ground_rail, catalog.at(catalog.indexOf("gnd").?).role);
    try std.testing.expectEqualStrings("", catalog.at(catalog.indexOf("vdd").?).default_value);
}

test "text width is the advance both renderers force, not an estimate" {
    // 0.6 em per byte, truncated — the same integer at comptime and at run time.
    try std.testing.expectEqual(@as(i32, 0), catalog.textWidth("", 6));
    try std.testing.expectEqual(@as(i32, 10), catalog.textWidth("DFF", 6));
    try std.testing.expectEqual(@as(i32, 7), catalog.textWidth("clk", 4));
    try std.testing.expectEqual(@as(i32, 2), catalog.textWidth("d", 4));
    comptime std.debug.assert(catalog.textWidth("DFF", 6) == 10);
}

// ---------------------------------------------------------------------------
// Catalog: derived geometry
// ---------------------------------------------------------------------------

test "every class bounding box is exactly one cell wide" {
    for (catalog.classes) |class| {
        const bb = class.bbox();
        try std.testing.expectEqual(catalog.cell_width, bb.max.x - bb.min.x);
        try std.testing.expectEqual(-catalog.cell_half, bb.min.x);
        try std.testing.expect(bb.max.y >= bb.min.y);
    }
}

test "a bounding box encloses every terminal and every glyph point in y" {
    for (catalog.classes) |class| {
        const bb = class.bbox();
        for (class.terminals) |t| {
            try std.testing.expect(bb.min.y <= t.at.y and t.at.y <= bb.max.y);
        }
        for (class.draw) |op| switch (op) {
            .line => |l| try std.testing.expect(bb.contains(l.a) and bb.contains(l.b)),
            .polyline => |pts| for (pts) |p| try std.testing.expect(bb.contains(p)),
            .circle => |c| {
                try std.testing.expect(bb.min.y <= c.c.y - c.r and c.c.y + c.r <= bb.max.y);
            },
            .text => |t| {
                const h = @divTrunc(@as(i32, t.size), 2);
                try std.testing.expect(bb.min.y <= t.at.y - h and t.at.y + h <= bb.max.y);
            },
        };
    }
}

test "a generated box body keeps every label inside its outline" {
    // Port of the Rust `box_labels_fit` guard, asserted against the baked table: if a pin
    // name outgrows its box the fix is a shorter name, because the width is fixed by the cell.
    const dff = catalog.at(catalog.indexOf("dff").?);
    const frame = switch (dff.draw[0]) {
        .polyline => |pts| blk: {
            var r: Rect = .{ .min = pts[0], .max = pts[0] };
            for (pts[1..]) |p| r = r.merge(.{ .min = p, .max = p });
            break :blk r;
        },
        else => return error.TestUnexpectedResult,
    };
    var labels: usize = 0;
    for (dff.draw) |op| switch (op) {
        .text => |t| {
            const half = @divTrunc(catalog.textWidth(t.s, t.size), 2);
            try std.testing.expect(t.at.x - half >= frame.min.x);
            try std.testing.expect(t.at.x + half <= frame.max.x);
            try std.testing.expect(frame.min.y <= t.at.y and t.at.y <= frame.max.y);
            labels += 1;
        },
        else => {},
    };
    // Title plus one label per pin.
    try std.testing.expectEqual(dff.terminals.len + 1, labels);
    try std.testing.expectEqual(catalog.box.bodyLen(dff.terminals.len), dff.draw.len);
}

test "no two labels of a generated box overlap" {
    const dff = catalog.at(catalog.indexOf("dff").?);
    var texts: [16]struct { at: Pt, w: i32, h: i32 } = undefined;
    var n: usize = 0;
    for (dff.draw) |op| switch (op) {
        .text => |t| {
            texts[n] = .{ .at = t.at, .w = catalog.textWidth(t.s, t.size), .h = t.size };
            n += 1;
        },
        else => {},
    };
    for (texts[0..n], 0..) |a, i| {
        for (texts[i + 1 .. n]) |b| {
            const rows_touch = @abs(a.at.y - b.at.y) < @max(a.h, b.h);
            const cols_touch = @abs(a.at.x - b.at.x) < @divTrunc(a.w + b.w, 2);
            try std.testing.expect(!(rows_touch and cols_touch));
        }
    }
}

test "the runtime box rule reproduces the baked builtin box geometry" {
    // One geometry rule for builtins and host classes: `catalog.box` must land exactly where
    // the generator baked `draw_dff`. If these ever disagree, an editor's own symbol and a
    // builtin flip-flop are drawn differently and nobody can tell which is right.
    const dff = catalog.at(catalog.indexOf("dff").?);
    const b = catalog.box.rect(dff.terminals);
    try std.testing.expectEqual(Rect{ .min = .{ .x = -12, .y = -24 }, .max = .{ .x = 12, .y = 4 } }, b);
    try std.testing.expectEqual(Pt{ .x = 0, .y = -20 }, catalog.box.titleAt(b));
    try std.testing.expectEqual(Pt{ .x = -9, .y = 0 }, catalog.box.labelAt(b, .{ .x = -20, .y = 0 }, "d"));
    try std.testing.expectEqual(Pt{ .x = -7, .y = -12 }, catalog.box.labelAt(b, .{ .x = -20, .y = -12 }, "clk"));
    try std.testing.expectEqual(Pt{ .x = 9, .y = 0 }, catalog.box.labelAt(b, .{ .x = 20, .y = 0 }, "q"));
    const outline = catalog.box.outline(b);
    try std.testing.expectEqual(outline[0], outline[4]);
    switch (dff.draw[0]) {
        .polyline => |pts| try std.testing.expectEqualSlices(Pt, &outline, pts),
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// Host table
// ---------------------------------------------------------------------------

const dut_terms: []const Terminal = &.{
    .{ .name = "in", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "out", .role = .passive, .at = .{ .x = 20, .y = 0 } },
    .{ .name = "en", .role = .passive, .at = .{ .x = -20, .y = -12 } },
};

const other_terms: []const Terminal = &.{
    .{ .name = "a", .role = .passive, .at = .{ .x = -20, .y = 0 } },
    .{ .name = "b", .role = .passive, .at = .{ .x = 20, .y = 0 } },
};

test "host indices begin where the builtin table ends" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 0), table.count());

    const idx = try table.register(.{ .name = "my_dut", .terminals = dut_terms });
    try std.testing.expectEqual(@as(usize, catalog.builtin_count), idx.i());
    try std.testing.expectEqual(@as(usize, 1), table.count());
}

test "a host index stays valid after later registrations" {
    // The whole reason the table is append-only: a Placed produced before the second
    // registration still resolves to the same class afterward.
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const a = try table.register(.{ .name = "sym_a", .terminals = dut_terms });
    const b = try table.register(.{ .name = "sym_b", .terminals = other_terms });
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, catalog.builtin_count), a.i());
    try std.testing.expectEqual(@as(usize, catalog.builtin_count + 1), b.i());

    try std.testing.expectEqualStrings("sym_a", table.at(a).name);
    try std.testing.expectEqualStrings("sym_b", table.at(b).name);
    try std.testing.expectEqual(a, table.indexOf("sym_a").?);
    // Registering a third does not disturb the first two.
    _ = try table.register(.{ .name = "sym_c", .terminals = other_terms });
    try std.testing.expectEqual(a, table.indexOf("sym_a").?);
    try std.testing.expectEqualStrings("sym_a", table.at(a).name);
    try std.testing.expectEqual(@as(usize, 3), table.count());
}

test "re-registering an identical class is idempotent" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const first = try table.register(.{ .name = "my_dut", .terminals = dut_terms });
    const again = try table.register(.{ .name = "my_dut", .terminals = dut_terms });
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(usize, 1), table.count());
}

test "a same-name class with different geometry is rejected" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.register(.{ .name = "my_dut", .terminals = dut_terms });
    try std.testing.expectError(error.GeometryChanged, table.register(.{
        .name = "my_dut",
        .terminals = other_terms,
    }));
    // Rejected means unchanged: no half-registered entry.
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expectEqual(@as(usize, 3), table.at(table.indexOf("my_dut").?).terminals.len);
}

test "a host class may not shadow a builtin" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectError(error.ShadowsBuiltin, table.register(.{
        .name = "nmos",
        .terminals = dut_terms,
    }));
    try std.testing.expectEqual(@as(usize, 0), table.count());
    // A builtin name still resolves to the builtin index through the combined lookup.
    try std.testing.expectEqual(catalog.indexOf("nmos").?, table.indexOf("nmos").?);
}

test "a class with no terminals is rejected" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();
    try std.testing.expectError(error.NoTerminals, table.register(.{
        .name = "empty",
        .terminals = &.{},
    }));
    try std.testing.expectEqual(@as(usize, 0), table.count());
}

test "a host spec may be stack-allocated and discarded immediately" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const idx = blk: {
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "tmp_{d}", .{7}) catch unreachable;
        var terms: [2]Terminal = .{
            .{ .name = "l", .at = .{ .x = -20, .y = 0 } },
            .{ .name = "r", .at = .{ .x = 20, .y = 0 } },
        };
        break :blk try table.register(.{ .name = name, .terminals = &terms });
    };
    // Everything the class points at was copied into the table's arena.
    try std.testing.expectEqualStrings("tmp_7", table.at(idx).name);
    try std.testing.expectEqualStrings("l", table.at(idx).terminals[0].name);
    try std.testing.expectEqual(idx, table.indexOf("tmp_7").?);
}

test "a host class without geometry gets the generated box body" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const idx = try table.register(.{ .name = "my_dut", .terminals = dut_terms });
    const class = table.at(idx);
    try std.testing.expectEqual(catalog.box.bodyLen(dut_terms.len), class.draw.len);
    try std.testing.expectEqual(catalog.SymbolRole.none, class.role);
    try std.testing.expectEqual(@as(u8, 'X'), class.prefix);
    // Outline first, title second — the shape `box.body` documents.
    try std.testing.expect(class.draw[0] == .polyline);
    switch (class.draw[1]) {
        .text => |t| try std.testing.expectEqualStrings("my_dut", t.s),
        else => return error.TestUnexpectedResult,
    }
}

test "host-supplied geometry comes back verbatim" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const ops: []const DrawOp = &.{
        DrawOp.ln(-20, 0, 20, 0),
        DrawOp.circ(0, 0, 9),
    };
    const idx = try table.register(.{ .name = "glyphy", .terminals = other_terms, .draw = ops });
    const class = table.at(idx);
    try std.testing.expectEqual(@as(usize, 2), class.draw.len);
    try std.testing.expectEqual(ops[0], class.draw[0]);
    try std.testing.expectEqual(ops[1], class.draw[1]);
}

test "a symbol index below the split resolves through the comptime catalog" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();
    const host_idx = try table.register(.{ .name = "my_dut", .terminals = dut_terms });

    const builtin_idx = catalog.indexOf("res").?;
    try std.testing.expectEqualStrings("res", table.at(builtin_idx).name);
    try std.testing.expectEqualStrings("my_dut", table.at(host_idx).name);
    // Both halves answer through one call, which is what lets the router stay ignorant of
    // where a class came from.
    try std.testing.expect(builtin_idx.i() < catalog.builtin_count);
    try std.testing.expect(host_idx.i() >= catalog.builtin_count);
}

test "moved anchors change the bounding box without changing the pin set" {
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const idx = try table.register(.{ .name = "my_dut", .terminals = dut_terms });
    const before = table.at(idx).bbox();
    try table.setAnchors(idx, &.{
        .{ .x = -20, .y = 0 },
        .{ .x = 20, .y = 0 },
        .{ .x = -20, .y = -40 },
    });
    const after = table.at(idx);
    try std.testing.expectEqualStrings("en", after.terminals[2].name);
    try std.testing.expectEqual(catalog.TerminalRole.passive, after.terminals[2].role);
    try std.testing.expectEqual(@as(i32, -40), after.terminals[2].at.y);
    try std.testing.expect(after.bbox().min.y < before.min.y);
    // Wrong anchor count is a refusal, not a partial application.
    try std.testing.expectError(error.GeometryChanged, table.setAnchors(idx, &.{.{ .x = 0, .y = 0 }}));
    try std.testing.expectEqual(@as(i32, -40), table.at(idx).terminals[2].at.y);
}

fn registerPair(gpa: Allocator) !void {
    var table = host.Table.init(gpa);
    defer table.deinit();
    _ = try table.register(.{ .name = "sym_a", .terminals = dut_terms });
    _ = try table.register(.{ .name = "sym_b", .terminals = other_terms, .draw = &.{
        DrawOp.ln(-20, 0, 20, 0),
    } });
}

test "host registration releases everything when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registerPair, .{});
}

// ---------------------------------------------------------------------------
// geom: the transform
// ---------------------------------------------------------------------------

test "mirror is applied before rotation for all eight orientations" {
    const r: Rect = .{ .min = .{ .x = -20, .y = -8 }, .max = .{ .x = 20, .y = 4 } };
    for ([_]u2{ 0, 1, 2, 3 }) |rot| {
        for ([_]bool{ false, true }) |mirror| {
            const o: Orient = .{ .rot = rot, .mirror = mirror };
            const got = geom.transformRect(o, r);
            const want = geom.fromCorners(o.apply(r.min), o.apply(r.max));
            try std.testing.expectEqual(want, got);
            // Normalized, always: an inverted rect makes `intersects` report no collision.
            try std.testing.expect(got.min.x <= got.max.x and got.min.y <= got.max.y);
            // A quarter turn swaps the extents; a mirror preserves both.
            const w = r.max.x - r.min.x;
            const h = r.max.y - r.min.y;
            const gw = got.max.x - got.min.x;
            const gh = got.max.y - got.min.y;
            if (rot % 2 == 0) {
                try std.testing.expectEqual(w, gw);
                try std.testing.expectEqual(h, gh);
            } else {
                try std.testing.expectEqual(h, gw);
                try std.testing.expectEqual(w, gh);
            }
        }
    }
}

test "a placed box is the class box oriented then translated" {
    const nmos = catalog.at(catalog.indexOf("nmos").?);
    const bb = nmos.bbox();
    const at: Pt = .{ .x = 100, .y = 40 };
    for ([_]u2{ 0, 1, 2, 3 }) |rot| {
        const o: Orient = .{ .rot = rot };
        const got = geom.placedRect(nmos.*, o, at);
        const local = geom.transformRect(o, bb);
        try std.testing.expectEqual(local.min.add(at), got.min);
        try std.testing.expectEqual(local.max.add(at), got.max);
    }
}

test "a placed box is derived from orientation, never stored" {
    // Mutating the orientation column and re-asking must move the box: nothing caches it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{
        .{ .name = "m1", .class = "nmos", .at = .{ .x = 0, .y = 0 } },
    }, &.{}, &.{});

    const d = ids.DeviceIdx.at(0);
    const upright = geom.deviceRect(sch.ir, sch.phys, &table, d);
    sch.ir.dev_orient[0] = .{ .rot = 1 };
    const turned = geom.deviceRect(sch.ir, sch.phys, &table, d);
    try std.testing.expect(!std.meta.eql(upright, turned));
    try std.testing.expectEqual(upright.max.x - upright.min.x, turned.max.y - turned.min.y);
    try std.testing.expectEqual(
        geom.transformRect(.{ .rot = 1 }, catalog.at(catalog.indexOf("nmos").?).bbox()),
        turned,
    );

    sch.ir.dev_orient[0] = .{};
    try std.testing.expectEqual(upright, geom.deviceRect(sch.ir, sch.phys, &table, d));
}

test "a placed pin lands on its terminal anchor under every orientation" {
    const res = catalog.at(catalog.indexOf("res").?);
    const at: Pt = .{ .x = 60, .y = -20 };
    for ([_]u2{ 0, 1, 2, 3 }) |rot| {
        for ([_]bool{ false, true }) |mirror| {
            const o: Orient = .{ .rot = rot, .mirror = mirror };
            for (res.terminals, 0..) |t, slot| {
                const got = geom.pinPoint(res.*, o, at, @intCast(slot));
                try std.testing.expectEqual(at.add(o.apply(t.at)), got);
                // A pin never lands outside its own placed body.
                try std.testing.expect(geom.placedRect(res.*, o, at).contains(got));
            }
        }
    }
}

test "rectangle helpers normalize and inflate symmetrically" {
    const r = geom.fromCorners(.{ .x = 10, .y = 4 }, .{ .x = -6, .y = 20 });
    try std.testing.expectEqual(Rect{ .min = .{ .x = -6, .y = 4 }, .max = .{ .x = 10, .y = 20 } }, r);
    try std.testing.expectEqual(r, geom.inflate(r, 0));
    const big = geom.inflate(r, 3);
    try std.testing.expectEqual(Rect{ .min = .{ .x = -9, .y = 1 }, .max = .{ .x = 13, .y = 23 } }, big);
    try std.testing.expect(big.intersects(r));
    // Touching edges count as a collision — conservative, as the router requires.
    const touching: Rect = .{ .min = .{ .x = 10, .y = 4 }, .max = .{ .x = 30, .y = 20 } };
    try std.testing.expect(r.intersects(touching));
}

// ---------------------------------------------------------------------------
// geom: refdes anchors
// ---------------------------------------------------------------------------

test "a refdes box is the width both renderers force" {
    try std.testing.expectEqual(@as(i32, 2), geom.refdesWidth(""));
    try std.testing.expectEqual(@as(i32, 12), geom.refdesWidth("m1"));
    const r = geom.refdesRect(.{ .x = 30, .y = 10 }, "m1");
    // Anchor is the left edge on the baseline.
    try std.testing.expectEqual(Pt{ .x = 30, .y = 10 - geom.text_h }, r.min);
    try std.testing.expectEqual(Pt{ .x = 30 + geom.refdesWidth("m1"), .y = 10 + geom.descent }, r.max);
}

test "refdes anchors never overlap a device body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{
        .{ .name = "m1", .class = "nmos", .at = .{ .x = 0, .y = 0 } },
        .{ .name = "r1", .class = "res", .at = .{ .x = 0, .y = 80 } },
        .{ .name = "xgnd", .class = "gnd", .at = .{ .x = 0, .y = 160 } },
    }, &.{}, &.{});

    const anchors = try geom.refdesAnchors(
        std.testing.allocator,
        sch.ir,
        sch.phys,
        sch.strings,
        &table,
    );
    defer std.testing.allocator.free(anchors);

    try std.testing.expectEqual(sch.ir.deviceCount(), anchors.len);
    for (anchors, 0..) |a, d| {
        const label = geom.refdesRect(a, sch.strings.get(sch.ir.dev_name[d]));
        for (0..sch.ir.deviceCount()) |other| {
            const body = geom.deviceRect(sch.ir, sch.phys, &table, ids.DeviceIdx.at(other));
            try std.testing.expect(!body.intersects(label));
        }
        // And never on another label.
        for (anchors[0..d], 0..) |b, e| {
            const prior = geom.refdesRect(b, sch.strings.get(sch.ir.dev_name[e]));
            try std.testing.expect(!prior.intersects(label));
        }
    }
}

test "refdes placement prefers the right of the cell and is reproducible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{
        .{ .name = "r1", .class = "res", .at = .{ .x = 0, .y = 0 } },
    }, &.{}, &.{});

    const first = try geom.refdesAnchors(std.testing.allocator, sch.ir, sch.phys, sch.strings, &table);
    defer std.testing.allocator.free(first);
    const second = try geom.refdesAnchors(std.testing.allocator, sch.ir, sch.phys, sch.strings, &table);
    defer std.testing.allocator.free(second);

    // A lone device has nothing to dodge, so it gets the preferred spot: right of the cell,
    // vertically centred on the device origin.
    try std.testing.expectEqual(Pt{ .x = catalog.cell_half + geom.label_gap, .y = 0 }, first[0]);
    // Same input, same output — the whole determinism guarantee in one assertion.
    try std.testing.expectEqualSlices(Pt, first, second);
}

test "the obstacle set is bodies, pins and junctions in a fixed order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{
        .{ .name = "r1", .class = "res", .at = .{ .x = 0, .y = 0 } },
    }, &.{}, &.{});

    const obs = try geom.obstacleRects(std.testing.allocator, sch.ir, sch.phys, &table);
    defer std.testing.allocator.free(obs);
    // No wires and no junctions here: one body plus one rect per pin.
    try std.testing.expectEqual(@as(usize, 1 + sch.phys.pin_xy.len), obs.len);
    try std.testing.expectEqual(geom.deviceRect(sch.ir, sch.phys, &table, ids.DeviceIdx.at(0)), obs[0]);
    for (sch.phys.pin_xy, obs[1..]) |p, r| try std.testing.expect(r.contains(p));
}

// ---------------------------------------------------------------------------
// geom: group frames
// ---------------------------------------------------------------------------

test "a dotted prefix owns only whole path components" {
    try std.testing.expect(geom.inGroup("xu1.m0", "xu1"));
    try std.testing.expect(geom.inGroup("xtop.xa.m0", "xtop"));
    try std.testing.expect(geom.inGroup("xtop.xa.m0", "xtop.xa"));
    try std.testing.expect(!geom.inGroup("xu1b.m0", "xu1"));
    try std.testing.expect(!geom.inGroup("xu1", "xu1"));
    try std.testing.expect(!geom.inGroup("xu1", "xu1.m0"));
    try std.testing.expect(!geom.inGroup("m0", "xu1"));
}

test "group frames nest for dotted instance paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    // Two sibling instances, far apart so neither frame claims the other's devices, both
    // inside one top-level instance.
    const sch = try build(arena.allocator(), &.{
        .{ .name = "xtop.xa.m0", .class = "nmos", .at = .{ .x = 0, .y = 0 } },
        .{ .name = "xtop.xa.m1", .class = "nmos", .at = .{ .x = 0, .y = 80 } },
        .{ .name = "xtop.xb.r0", .class = "res", .at = .{ .x = 400, .y = 0 } },
        .{ .name = "xtop.xb.r1", .class = "res", .at = .{ .x = 400, .y = 80 } },
    }, &.{ "xtop", "xtop.xa", "xtop.xb" }, &.{ "top", "amp", "load" });

    const frames = try geom.groupFrames(
        std.testing.allocator,
        sch.ir,
        sch.phys,
        sch.strings,
        &table,
    );
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);
    // Outermost first, so a renderer drawing in order puts children on top.
    try std.testing.expectEqual(@as(u16, 0), frames[0].depth);
    try std.testing.expectEqualStrings("xtop", sch.strings.get(frames[0].path));
    try std.testing.expectEqualStrings("top", sch.strings.get(frames[0].master));
    try std.testing.expect(frames[1].depth == 1 and frames[2].depth == 1);

    // Geometric nesting: the parent contains both children whole.
    const outer = frames[0].rect;
    for (frames[1..]) |g| {
        try std.testing.expect(outer.contains(g.rect.min));
        try std.testing.expect(outer.contains(g.rect.max));
    }
    // Siblings do not overlap; if they had, one would have been dropped instead.
    try std.testing.expect(!frames[1].rect.intersects(frames[2].rect));

    // Every member body is inside its own frame, with clearance.
    for (frames) |g| {
        const path = sch.strings.get(g.path);
        for (0..sch.ir.deviceCount()) |d| {
            const name = sch.strings.get(sch.ir.dev_name[d]);
            const body = geom.deviceRect(sch.ir, sch.phys, &table, ids.DeviceIdx.at(d));
            if (geom.inGroup(name, path)) {
                try std.testing.expect(g.rect.contains(body.min));
                try std.testing.expect(g.rect.contains(body.max));
            } else {
                // A frame may clip an outsider's box but never claim its origin.
                try std.testing.expect(!g.rect.contains(sch.phys.pos[d]));
            }
        }
        // The label sits inside its own frame, in the padding band.
        try std.testing.expect(g.rect.contains(g.label_at));
        try std.testing.expect(g.labelWidth(sch.strings) > 0);
    }
}

test "a one-device instance gets no frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{
        .{ .name = "xu1.r0", .class = "res", .at = .{ .x = 0, .y = 0 } },
    }, &.{"xu1"}, &.{"load"});

    const frames = try geom.groupFrames(std.testing.allocator, sch.ir, sch.phys, sch.strings, &table);
    defer std.testing.allocator.free(frames);
    try std.testing.expectEqual(@as(usize, 0), frames.len);
}

test "a flat netlist produces no frames and needs no allocation to say so" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{
        .{ .name = "r1", .class = "res", .at = .{ .x = 0, .y = 0 } },
        .{ .name = "r2", .class = "res", .at = .{ .x = 80, .y = 0 } },
    }, &.{}, &.{});

    const frames = try geom.groupFrames(std.testing.allocator, sch.ir, sch.phys, sch.strings, &table);
    defer std.testing.allocator.free(frames);
    try std.testing.expectEqual(@as(usize, 0), frames.len);
}

test "layout bounds cover every device body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{
        .{ .name = "r1", .class = "res", .at = .{ .x = 0, .y = 0 } },
        .{ .name = "r2", .class = "res", .at = .{ .x = 200, .y = 60 } },
    }, &.{}, &.{});

    const bb = geom.bounds(sch.ir, sch.phys, &table) orelse return error.TestUnexpectedResult;
    for (0..sch.ir.deviceCount()) |d| {
        const body = geom.deviceRect(sch.ir, sch.phys, &table, ids.DeviceIdx.at(d));
        try std.testing.expect(bb.contains(body.min) and bb.contains(body.max));
    }
    // No render padding: that is the emitter's to add from Config.render.pad.
    try std.testing.expectEqual(@as(i32, -catalog.cell_half), bb.min.x);
}

test "an empty layout has no bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var table = host.Table.init(std.testing.allocator);
    defer table.deinit();

    const sch = try build(arena.allocator(), &.{}, &.{}, &.{});
    try std.testing.expect(geom.bounds(sch.ir, sch.phys, &table) == null);
}
