//! Behavioral suite for the three foundation modules: `ids`, `strings`, `csr`.
//!
//! These are step 1 of ARCHITECTURE.md §Sequence — pure data structures with no
//! dependency on anything else in the tree — so this file is the one suite that can
//! be driven to green before a single line of the netlist front end exists.
//!
//! What it pins, and why each one is here rather than left to review:
//!
//! - **The sentinel-over-optional rationale is asserted, not just documented.**
//!   `@sizeOf(?NetIdx) == 8` while `@sizeOf(NetIdx) == 4` is the entire justification
//!   for the 1-based net encoding in `ids.zig` and ARCHITECTURE.md §4. If a future
//!   Zig niche-optimizes non-exhaustive enums, this test goes red and the design note
//!   gets revisited deliberately instead of quietly becoming a lie.
//! - **`Rect.intersects` is closed.** Two rectangles that merely touch *do* intersect.
//!   `route/lattice.zig` decides body blocking with this predicate, so whether an edge
//!   grazing a body edge is blocked is settled here rather than rediscovered from a
//!   drawing.
//! - **`Orient.apply` composes mirror *before* rotation**, checked over all eight
//!   transforms against hand-computed points, plus one case where the opposite order
//!   gives a different answer. Every renderer routes through this function, so an
//!   inverted order is a silently wrong drawing rather than a crash.
//! - **CSR construction is a *stable* counting sort.** The fixture interleaves keys so
//!   that an implementation walking its cursors backwards produces reversed value runs
//!   and fails. Stability is the determinism guarantee, not an accident of the
//!   algorithm.
//! - **Case folding collapses `VDD` and `vdd` to one id while `intern` keeps them
//!   apart.** SPICE identifier matching is a property of the pool; the tokenizer never
//!   rewrites its input.
//!
//! Expected red until the corresponding function is written — a `@panic("TODO")`
//! aborts the whole binary rather than failing one test, so the first panic names the
//! next function to implement. The `ids` half is already green: that module is data,
//! not stubs.

const std = @import("std");
const ckt = @import("cktimg");

const ids = ckt.ids;
const csr = ckt.csr;
const strings = ckt.strings;

const Allocator = std.mem.Allocator;
const testing = std.testing;

const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;
const NetIdx = ids.NetIdx;
const PinIdx = ids.PinIdx;
const DeviceIdx = ids.DeviceIdx;
const StrId = ids.StrId;
const Interner = strings.Interner;
const Strings = strings.Strings;

// ===========================================================================
// ids: index encodings
// ===========================================================================

test "net index is one-based so subscript zero is a real net, not the sentinel" {
    // The whole point of the 1-based encoding: net 0 exists and is distinguishable
    // from "floating". A 0-based encoding would make the first net indistinguishable
    // from absence, which is exactly the bug the sentinel is meant to prevent.
    try testing.expect(NetIdx.at(0) != .none);
    try testing.expectEqual(@as(usize, 0), NetIdx.at(0).i());
    try testing.expectEqual(@as(usize, 1), NetIdx.at(1).i());
    try testing.expectEqual(@as(usize, 4095), NetIdx.at(4095).i());

    // Round-trip over a spread of subscripts, including the ones adjacent to the
    // sentinel's numeric value.
    for ([_]usize{ 0, 1, 2, 7, 255, 256, 65535, 1 << 20 }) |n| {
        try testing.expectEqual(n, NetIdx.at(n).i());
        try testing.expect(NetIdx.at(n) != .none);
    }

    // And the raw encoding is exactly "subscript plus one".
    try testing.expectEqual(@as(u32, 0), @intFromEnum(NetIdx.none));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(NetIdx.at(0)));
}

test "device and pin sentinels are maxInt so index zero stays addressable" {
    // Opposite convention to NetIdx, and deliberately so: these columns are dense
    // from 0 and the sentinel has to live somewhere unreachable, not at 0.
    try testing.expectEqual(std.math.maxInt(u32), @intFromEnum(DeviceIdx.none));
    try testing.expectEqual(std.math.maxInt(u32), @intFromEnum(PinIdx.none));
    try testing.expect(@intFromEnum(DeviceIdx.none) != 0);
    try testing.expect(@intFromEnum(PinIdx.none) != 0);

    try testing.expect(DeviceIdx.at(0) != .none);
    try testing.expect(PinIdx.at(0) != .none);
    try testing.expectEqual(@as(usize, 0), DeviceIdx.at(0).i());
    try testing.expectEqual(@as(usize, 0), PinIdx.at(0).i());
    try testing.expectEqual(@as(usize, 12345), DeviceIdx.at(12345).i());
    try testing.expectEqual(@as(usize, 12345), PinIdx.at(12345).i());
}

test "an optional net index costs twice what the sentinel encoding does" {
    // This is the assertion that keeps ARCHITECTURE.md §4 honest. Zig does not
    // niche-optimize an optional over a non-exhaustive enum, so `?NetIdx` is two
    // words. `pin_net` is the hottest array in the program; at 4 bytes per pin the
    // sentinel encoding halves it.
    try testing.expectEqual(@as(usize, 4), @sizeOf(NetIdx));
    try testing.expectEqual(@as(usize, 8), @sizeOf(?NetIdx));

    // Same story for the other index spaces, so the rule generalizes.
    try testing.expectEqual(@as(usize, 4), @sizeOf(DeviceIdx));
    try testing.expectEqual(@as(usize, 8), @sizeOf(?DeviceIdx));
    try testing.expectEqual(@as(usize, 4), @sizeOf(PinIdx));
    try testing.expectEqual(@as(usize, 4), @sizeOf(StrId));
}

test "orientation packs into one byte" {
    // `dev_orient` is a per-device column; one byte is the documented cost.
    try testing.expectEqual(@as(usize, 1), @sizeOf(Orient));
    try testing.expectEqual(@as(usize, 8), @bitSizeOf(Orient));
}

test "orientation applies mirror before rotation for all eight transforms" {
    // p is chosen asymmetric in both axes and with |x| != |y| so that every one of
    // the eight results is distinct — a symmetric probe point would let three wrong
    // implementations pass.
    const p: Pt = .{ .x = 3, .y = 1 };

    // Hand-computed. Unmirrored: m = (3, 1).
    //   rot 0 -> ( m.x,  m.y) = ( 3,  1)
    //   rot 1 -> (-m.y,  m.x) = (-1,  3)
    //   rot 2 -> (-m.x, -m.y) = (-3, -1)
    //   rot 3 -> ( m.y, -m.x) = ( 1, -3)
    try testing.expectEqual(Pt{ .x = 3, .y = 1 }, (Orient{ .rot = 0, .mirror = false }).apply(p));
    try testing.expectEqual(Pt{ .x = -1, .y = 3 }, (Orient{ .rot = 1, .mirror = false }).apply(p));
    try testing.expectEqual(Pt{ .x = -3, .y = -1 }, (Orient{ .rot = 2, .mirror = false }).apply(p));
    try testing.expectEqual(Pt{ .x = 1, .y = -3 }, (Orient{ .rot = 3, .mirror = false }).apply(p));

    // Mirrored first: m = (-3, 1). The same four formulas over the mirrored point.
    //   rot 0 -> (-3,  1)
    //   rot 1 -> (-1, -3)
    //   rot 2 -> ( 3, -1)
    //   rot 3 -> ( 1,  3)
    try testing.expectEqual(Pt{ .x = -3, .y = 1 }, (Orient{ .rot = 0, .mirror = true }).apply(p));
    try testing.expectEqual(Pt{ .x = -1, .y = -3 }, (Orient{ .rot = 1, .mirror = true }).apply(p));
    try testing.expectEqual(Pt{ .x = 3, .y = -1 }, (Orient{ .rot = 2, .mirror = true }).apply(p));
    try testing.expectEqual(Pt{ .x = 1, .y = 3 }, (Orient{ .rot = 3, .mirror = true }).apply(p));

    // The default is the identity, and it is R0 unmirrored.
    try testing.expectEqual(p, Orient.r0.apply(p));
    try testing.expectEqual(Orient{}, Orient.r0);

    // The origin is fixed by every transform.
    inline for (0..4) |r| {
        inline for ([_]bool{ false, true }) |m| {
            const o: Orient = .{ .rot = @intCast(r), .mirror = m };
            try testing.expectEqual(Pt.zero, o.apply(Pt.zero));
        }
    }
}

test "reversing mirror and rotation gives a different point" {
    // The order is only load-bearing if the two orders actually disagree. They do:
    // for R90 + mirror on (3, 1), mirror-then-rotate is (-1, -3) while
    // rotate-then-mirror is (1, 3). Without this case a renderer could reimplement
    // the transform backwards and pass every other assertion in this file.
    const p: Pt = .{ .x = 3, .y = 1 };
    const mirror_then_rotate = (Orient{ .rot = 1, .mirror = true }).apply(p);

    // rotate first: R90 of (3,1) is (-1, 3); then mirror about x: (1, 3).
    const rotated = (Orient{ .rot = 1, .mirror = false }).apply(p);
    const rotate_then_mirror: Pt = .{ .x = -rotated.x, .y = rotated.y };

    try testing.expectEqual(Pt{ .x = -1, .y = -3 }, mirror_then_rotate);
    try testing.expectEqual(Pt{ .x = 1, .y = 3 }, rotate_then_mirror);
    try testing.expect(!mirror_then_rotate.eql(rotate_then_mirror));
}

test "point order is a strict total order over a sample" {
    // `Pt.lessThan` canonicalizes point lists, so a merely *consistent* comparator is
    // not enough — it has to be a strict weak order or `std.mem.sort` may not
    // terminate deterministically. Checked exhaustively over a small sample that
    // includes duplicates, sign changes and both-axis ties.
    const sample = [_]Pt{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = -1, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = 0, .y = -1 },
        .{ .x = 5, .y = -3 },
        .{ .x = -5, .y = 3 },
        .{ .x = 1, .y = 0 }, // duplicate, to pin irreflexivity on equal values
    };

    for (sample) |a| {
        // Irreflexive.
        try testing.expect(!Pt.lessThan({}, a, a));
        for (sample) |b| {
            const ab = Pt.lessThan({}, a, b);
            const ba = Pt.lessThan({}, b, a);
            // Antisymmetric: never both directions.
            try testing.expect(!(ab and ba));
            // Total: equal points compare neither way, distinct points compare one way.
            if (a.eql(b)) {
                try testing.expect(!ab and !ba);
            } else {
                try testing.expect(ab or ba);
            }
            for (sample) |c| {
                if (ab and Pt.lessThan({}, b, c)) {
                    try testing.expect(Pt.lessThan({}, a, c)); // transitive
                }
            }
        }
    }

    // y-major, then x — the documented ordering, not merely *some* ordering.
    try testing.expect(Pt.lessThan({}, .{ .x = 99, .y = 0 }, .{ .x = -99, .y = 1 }));
    try testing.expect(Pt.lessThan({}, .{ .x = -1, .y = 4 }, .{ .x = 0, .y = 4 }));

    // And sorting with it is stable-looking and idempotent.
    var buf = sample;
    std.mem.sort(Pt, &buf, {}, Pt.lessThan);
    for (buf[1..], 0..) |p, i| try testing.expect(!Pt.lessThan({}, p, buf[i]));
}

test "touching rectangles intersect" {
    // Closed/inclusive is the contract. `route/lattice.zig` marks an edge blocked with
    // this predicate, so "shares exactly one boundary line" has to be a decision made
    // here rather than an accident.
    const a: Rect = .{ .min = .{ .x = 0, .y = 0 }, .max = .{ .x = 10, .y = 10 } };

    // Edge-to-edge on the right: a.max.x == b.min.x.
    const touch_right: Rect = .{ .min = .{ .x = 10, .y = 0 }, .max = .{ .x = 20, .y = 10 } };
    try testing.expect(a.intersects(touch_right));
    try testing.expect(touch_right.intersects(a)); // symmetric

    // Corner-to-corner: a single shared point still counts.
    const touch_corner: Rect = .{ .min = .{ .x = 10, .y = 10 }, .max = .{ .x = 20, .y = 20 } };
    try testing.expect(a.intersects(touch_corner));

    // One unit of clearance in x is genuinely disjoint.
    const clear: Rect = .{ .min = .{ .x = 11, .y = 0 }, .max = .{ .x = 20, .y = 10 } };
    try testing.expect(!a.intersects(clear));

    // Disjoint in y only is still disjoint, even when x overlaps fully.
    const above: Rect = .{ .min = .{ .x = 0, .y = 11 }, .max = .{ .x = 10, .y = 20 } };
    try testing.expect(!a.intersects(above));

    // Containment and self-intersection.
    const inner: Rect = .{ .min = .{ .x = 2, .y = 2 }, .max = .{ .x = 3, .y = 3 } };
    try testing.expect(a.intersects(inner));
    try testing.expect(a.intersects(a));

    // A degenerate rectangle (a point) behaves like `contains`.
    const dot: Rect = .{ .min = .{ .x = 10, .y = 10 }, .max = .{ .x = 10, .y = 10 } };
    try testing.expect(a.intersects(dot));
    try testing.expect(a.contains(.{ .x = 10, .y = 10 }));
    try testing.expect(a.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(!a.contains(.{ .x = 11, .y = 5 }));
}

test "rectangle merge is associative" {
    const a: Rect = .{ .min = .{ .x = -4, .y = 1 }, .max = .{ .x = 0, .y = 2 } };
    const b: Rect = .{ .min = .{ .x = 3, .y = -7 }, .max = .{ .x = 9, .y = 0 } };
    const c: Rect = .{ .min = .{ .x = 1, .y = 5 }, .max = .{ .x = 2, .y = 11 } };

    const left = Rect.merge(Rect.merge(a, b), c);
    const right = Rect.merge(a, Rect.merge(b, c));
    try testing.expectEqual(left, right);

    // Commutative, idempotent, and actually the *smallest* enclosing box.
    try testing.expectEqual(Rect.merge(a, b), Rect.merge(b, a));
    try testing.expectEqual(a, Rect.merge(a, a));
    try testing.expectEqual(
        Rect{ .min = .{ .x = -4, .y = -7 }, .max = .{ .x = 9, .y = 11 } },
        left,
    );

    // Every input corner lands inside the merge.
    for ([_]Rect{ a, b, c }) |r| {
        try testing.expect(left.contains(r.min));
        try testing.expect(left.contains(r.max));
    }
}

// ===========================================================================
// strings: the interner
// ===========================================================================

test "interning the same bytes twice yields the same id" {
    var it = try Interner.init(testing.allocator);
    defer it.deinit(testing.allocator);

    const a = try it.intern(testing.allocator, "m1");
    const b = try it.intern(testing.allocator, "m1");
    try testing.expectEqual(a, b);

    // Idempotent in pool size as well as in id: the second intern must not append.
    const before = it.bytes.items.len;
    const c = try it.intern(testing.allocator, "m1");
    try testing.expectEqual(a, c);
    try testing.expectEqual(before, it.bytes.items.len);
}

test "distinct bytes get distinct ids" {
    var it = try Interner.init(testing.allocator);
    defer it.deinit(testing.allocator);

    const names = [_][]const u8{ "m1", "m2", "vdd", "vss", "out", "m", "m11", "1m" };
    var seen: [names.len]StrId = undefined;
    for (names, 0..) |n, i| seen[i] = try it.intern(testing.allocator, n);

    for (seen, 0..) |x, i| {
        for (seen[i + 1 ..]) |y| try testing.expect(x != y);
    }

    // And every id resolves back to the bytes that produced it — prefix pairs like
    // "m"/"m1"/"m11" are where a length-blind dedup key would collapse two names.
    for (names, seen) |n, id| try testing.expectEqualStrings(n, it.get(id));
}

test "the empty string is interned before any caller asks" {
    var it = try Interner.init(testing.allocator);
    defer it.deinit(testing.allocator);

    // `StrId.empty` is documented as always valid. Callers rely on it for absent
    // values without paying an intern call, so it must exist immediately after init.
    try testing.expectEqualStrings("", it.get(.empty));
    try testing.expectEqual(@as(usize, 1), it.spans.items.len);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(StrId.empty));

    // Interning it explicitly returns the same id and grows nothing.
    const before = it.bytes.items.len;
    try testing.expectEqual(StrId.empty, try it.intern(testing.allocator, ""));
    try testing.expectEqual(before, it.bytes.items.len);
}

test "every interned string is NUL terminated and getZ agrees with get" {
    var it = try Interner.init(testing.allocator);
    defer it.deinit(testing.allocator);

    const names = [_][]const u8{ "", "vdd", "xtop.xa.r1", "a", "sky130_fd_pr__nfet_01v8" };
    var seen: [names.len]StrId = undefined;
    for (names, 0..) |n, i| seen[i] = try it.intern(testing.allocator, n);

    var pool = try it.finish(testing.allocator);
    defer pool.deinit(testing.allocator);

    for (names, seen) |n, id| {
        const span = pool.spans[id.i()];

        // The span excludes the terminator; the byte just past it is the NUL. This is
        // what buys the C ABI a zero-copy `[*:0]const u8` (ARCHITECTURE.md §9).
        try testing.expectEqual(@as(usize, n.len), @as(usize, span.len));
        try testing.expect(span.off + span.len < pool.bytes.len);
        try testing.expectEqual(@as(u8, 0), pool.bytes[span.off + span.len]);

        try testing.expectEqualStrings(n, pool.get(id));
        try testing.expectEqualStrings(n, std.mem.span(pool.getZ(id)));

        // getZ points *into* the pool rather than at a copy.
        try testing.expectEqual(
            @intFromPtr(pool.bytes.ptr) + span.off,
            @intFromPtr(pool.getZ(id)),
        );
    }
}

test "case folding collapses VDD and vdd while verbatim interning keeps them apart" {
    var it = try Interner.init(testing.allocator);
    defer it.deinit(testing.allocator);

    // internFold is the SPICE identifier path: case-insensitivity is a property of
    // the pool, so no caller has to remember to lowercase.
    const folded_upper = try it.internFold(testing.allocator, "VDD");
    const folded_mixed = try it.internFold(testing.allocator, "Vdd");
    const folded_lower = try it.internFold(testing.allocator, "vdd");
    try testing.expectEqual(folded_upper, folded_mixed);
    try testing.expectEqual(folded_upper, folded_lower);
    try testing.expectEqualStrings("vdd", it.get(folded_upper));

    // intern is byte-exact and must not have been quietly rerouted through the fold.
    const raw_upper = try it.intern(testing.allocator, "VDD");
    try testing.expect(raw_upper != folded_upper);
    try testing.expectEqualStrings("VDD", it.get(raw_upper));
    try testing.expectEqual(raw_upper, try it.intern(testing.allocator, "VDD"));

    // Non-ASCII bytes pass through unchanged rather than being mangled by a naive
    // `| 0x20`, and digits/punctuation are untouched.
    const punct = try it.internFold(testing.allocator, "X_1[3].\xC3\x89");
    try testing.expectEqualStrings("x_1[3].\xC3\x89", it.get(punct));
}

test "case folding handles a name longer than the stack buffer" {
    var it = try Interner.init(testing.allocator);
    defer it.deinit(testing.allocator);

    // Exercises the scratch-allocation path in internFold. The boundary itself and
    // one either side, because an off-by-one here is a buffer overrun rather than a
    // wrong answer.
    const sizes = [_]usize{
        Interner.fold_stack_max - 1,
        Interner.fold_stack_max,
        Interner.fold_stack_max + 1,
        Interner.fold_stack_max * 3,
    };

    for (sizes) |n| {
        const upper = try testing.allocator.alloc(u8, n);
        defer testing.allocator.free(upper);
        const lower = try testing.allocator.alloc(u8, n);
        defer testing.allocator.free(lower);
        for (upper, lower, 0..) |*u, *l, i| {
            // A repeating alphabet so a truncation shows up as a length *and* a
            // content mismatch.
            u.* = 'A' + @as(u8, @intCast(i % 26));
            l.* = 'a' + @as(u8, @intCast(i % 26));
        }

        const id = try it.internFold(testing.allocator, upper);
        try testing.expectEqualStrings(lower, it.get(id));

        // The scratch buffer is released before returning: folding the already-lower
        // form must hit the dedup map and yield the same id.
        try testing.expectEqual(id, try it.internFold(testing.allocator, lower));
    }
}

test "find does not grow the pool" {
    var it = try Interner.init(testing.allocator);
    defer it.deinit(testing.allocator);

    const known = try it.intern(testing.allocator, "vss");
    const bytes_before = it.bytes.items.len;
    const spans_before = it.spans.items.len;

    try testing.expectEqual(@as(?StrId, known), it.find("vss"));
    try testing.expectEqual(@as(?StrId, StrId.empty), it.find(""));
    try testing.expectEqual(@as(?StrId, null), it.find("never_seen"));
    try testing.expectEqual(@as(?StrId, null), it.find("VSS")); // byte-exact, like intern
    try testing.expectEqual(@as(?StrId, null), it.find("vs"));
    try testing.expectEqual(@as(?StrId, null), it.find("vsss"));

    // The whole reason `find` exists: a pass resolving a possibly-unknown port name
    // must not mint an id as a side effect of asking.
    try testing.expectEqual(bytes_before, it.bytes.items.len);
    try testing.expectEqual(spans_before, it.spans.items.len);
}

test "finish transfers the pool and leaves the interner empty" {
    var it = try Interner.init(testing.allocator);
    var it_dead = false;
    defer if (!it_dead) it.deinit(testing.allocator);

    const a = try it.intern(testing.allocator, "n1");
    const b = try it.internFold(testing.allocator, "N2");

    var pool = try it.finish(testing.allocator);
    defer pool.deinit(testing.allocator);

    // Ownership moved: the pool still reads correctly, and the count includes the
    // empty string that `init` seeded.
    try testing.expectEqualStrings("n1", pool.get(a));
    try testing.expectEqualStrings("n2", pool.get(b));
    try testing.expectEqual(@as(usize, 3), pool.count());
    try testing.expectEqual(pool.count(), pool.spans.len);

    // The interner is left `.empty`, so a second finish transfers nothing rather than
    // handing out a second owner of the same bytes. Freeing both is leak-free and
    // double-free-free, which `testing.allocator` is what proves.
    try testing.expectEqual(@as(usize, 0), it.bytes.items.len);
    try testing.expectEqual(@as(usize, 0), it.spans.items.len);

    var second = try it.finish(testing.allocator);
    defer second.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), second.count());
    try testing.expectEqual(@as(usize, 0), second.bytes.len);

    // And a deinit after finish is safe — this is the ordinary shape of an errdefer
    // that survives past the ownership transfer.
    it.deinit(testing.allocator);
    it_dead = true;
}

test "id assignment order is identical across two identical sequences" {
    // Ids are assigned in first-intern order, and that is what makes the whole
    // program's output byte-reproducible: a hash-seeded or insertion-order-sensitive
    // dedup that leaked into numbering would show up here and nowhere else until a
    // golden file diffed.
    const seq = [_][]const u8{ "m1", "vdd", "m1", "OUT", "vss", "out", "m2", "vdd", "" };

    var first: [seq.len]StrId = undefined;
    var second: [seq.len]StrId = undefined;

    var a = try Interner.init(testing.allocator);
    defer a.deinit(testing.allocator);
    for (seq, 0..) |s, i| first[i] = try a.internFold(testing.allocator, s);

    var b = try Interner.init(testing.allocator);
    defer b.deinit(testing.allocator);
    for (seq, 0..) |s, i| second[i] = try b.internFold(testing.allocator, s);

    try testing.expectEqualSlices(StrId, &first, &second);
    try testing.expectEqualSlices(u8, a.bytes.items, b.bytes.items);
    try testing.expectEqual(a.spans.items.len, b.spans.items.len);

    // Ids are dense and ascending in first-sight order: empty=0, then m1, vdd, out, m2.
    try testing.expectEqual(StrId.at(0), StrId.empty);
    try testing.expectEqual(StrId.at(1), first[0]); // m1
    try testing.expectEqual(StrId.at(2), first[1]); // vdd
    try testing.expectEqual(first[0], first[2]); // m1 again
    try testing.expectEqual(StrId.at(3), first[3]); // out (folded from OUT)
    try testing.expectEqual(first[3], first[5]); // out
    try testing.expectEqual(StrId.empty, first[8]);
}

fn internSequenceLeakFree(gpa: Allocator, names: []const []const u8) !void {
    var it = try Interner.init(gpa);
    errdefer it.deinit(gpa);
    for (names) |n| _ = try it.internFold(gpa, n);
    var pool = try it.finish(gpa);
    defer pool.deinit(gpa);
    std.debug.assert(pool.count() >= 1);
}

test "the interner leaks nothing when any single allocation fails" {
    // The only way the errdefers in `intern`, `internFold` and `finish` actually
    // execute. A long name is included so the scratch-fold path is among the failure
    // points, and repeats are included so a failure mid-dedup is covered too.
    const names = [_][]const u8{
        "m1",  "vdd", "M1",  "vss",
        "out", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ++
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ++
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ++
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "m2",  "",
    };
    try testing.checkAllAllocationFailures(
        testing.allocator,
        internSequenceLeakFree,
        .{@as([]const []const u8, &names)},
    );
}

// ===========================================================================
// csr: the counting-sort relation builder
// ===========================================================================

/// One observation feeding the builder. `key == null` models a floating pin: an item
/// that belongs to no key and must be dropped rather than bucketed anywhere.
const Item = struct {
    key: ?u32,
    val: u32,
};

const Rel = csr.Csr(NetIdx, u32);

fn keyOfItem(_: void, it: Item) ?NetIdx {
    return if (it.key) |k| NetIdx.at(k) else null;
}

fn valOfItem(_: void, it: Item) u32 {
    return it.val;
}

test "csr values keep items order within a key" {
    // The fixture interleaves two keys so that stability is *observable*. A builder
    // that walks its cursors from the end of each bucket, or that sorts by key with
    // an unstable sort, produces [30, 20, 10] here and fails. Stability is the
    // determinism guarantee (ARCHITECTURE.md §7), so it is contract, not luck.
    const items = [_]Item{
        .{ .key = 0, .val = 10 },
        .{ .key = 1, .val = 11 },
        .{ .key = 0, .val = 20 },
        .{ .key = 1, .val = 21 },
        .{ .key = 0, .val = 30 },
    };

    var rel = try Rel.build(testing.allocator, 3, &items, {}, keyOfItem, valOfItem);
    defer rel.deinit(testing.allocator);
    rel.assertValid();

    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, rel.slice(NetIdx.at(0)));
    try testing.expectEqualSlices(u32, &.{ 11, 21 }, rel.slice(NetIdx.at(1)));
    try testing.expectEqual(@as(usize, 3), rel.keyCount());
}

test "a key with no values returns an empty slice" {
    // Sparse keys are the common case (nets with every pin floating, columns with no
    // devices). An empty run must be a zero-length slice, not a panic and not a
    // one-element slice borrowed from the next key.
    const items = [_]Item{
        .{ .key = 3, .val = 7 },
        .{ .key = 0, .val = 1 },
        .{ .key = 3, .val = 8 },
    };

    var rel = try Rel.build(testing.allocator, 5, &items, {}, keyOfItem, valOfItem);
    defer rel.deinit(testing.allocator);
    rel.assertValid();

    try testing.expectEqual(@as(usize, 5), rel.keyCount());
    try testing.expectEqualSlices(u32, &.{1}, rel.slice(NetIdx.at(0)));
    try testing.expectEqualSlices(u32, &.{}, rel.slice(NetIdx.at(1)));
    try testing.expectEqualSlices(u32, &.{}, rel.slice(NetIdx.at(2)));
    try testing.expectEqualSlices(u32, &.{ 7, 8 }, rel.slice(NetIdx.at(3)));
    try testing.expectEqualSlices(u32, &.{}, rel.slice(NetIdx.at(4)));

    try testing.expectEqual(@as(u32, 0), rel.count(NetIdx.at(1)));
    try testing.expectEqual(@as(u32, 2), rel.count(NetIdx.at(3)));

    // The last key being empty is the case where a missing terminating sentinel
    // shows up as an out-of-bounds slice rather than a wrong answer.
    try testing.expectEqual(@as(usize, 6), rel.offsets.len);
    try testing.expectEqual(@as(u32, @intCast(rel.values.len)), rel.offsets[5]);
}

test "csr round-trips a known relation and drops keyless items" {
    // A hand-checked net -> pin relation, exactly the shape `Ir.netPins` produces.
    // Items with a null key (floating pins) belong to no net and must vanish, not
    // land under key 0.
    const items = [_]Item{
        .{ .key = 1, .val = 100 },
        .{ .key = null, .val = 999 },
        .{ .key = 0, .val = 200 },
        .{ .key = 1, .val = 101 },
        .{ .key = null, .val = 998 },
        .{ .key = 2, .val = 300 },
        .{ .key = 1, .val = 102 },
    };

    var rel = try Rel.build(testing.allocator, 3, &items, {}, keyOfItem, valOfItem);
    defer rel.deinit(testing.allocator);
    rel.assertValid();

    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, rel.offsets);
    try testing.expectEqualSlices(u32, &.{ 200, 100, 101, 102, 300 }, rel.values);
    try testing.expectEqual(@as(usize, 5), rel.values.len); // the two 99x are gone

    for (rel.values) |v| try testing.expect(v != 999 and v != 998);

    // Slices agree with the raw offsets, which is the invariant `slice` exists to
    // uphold: values[offsets[k] .. offsets[k+1]].
    var k: usize = 0;
    while (k < rel.keyCount()) : (k += 1) {
        const key = NetIdx.at(k);
        const lo = rel.offsets[k];
        const hi = rel.offsets[k + 1];
        try testing.expectEqualSlices(u32, rel.values[lo..hi], rel.slice(key));
        try testing.expectEqual(hi - lo, rel.count(key));
    }

    // An empty relation is a legal, freeable value. Passed as a slice rather than as
    // `&[_]Item{}`: `build` types its callbacks off `@TypeOf(items[0])`, which cannot
    // be evaluated for a zero-length *array* literal.
    const no_items: []const Item = &.{};
    var none = try Rel.build(testing.allocator, 0, no_items, {}, keyOfItem, valOfItem);
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.keyCount());
}

test "fromCounts prefix-sums the histogram" {
    // For passes that already know the per-key counts and emit values as a side
    // effect of a walk they cannot cheaply repeat. Offsets must be the exclusive
    // prefix sum; the values array is sized but uninitialized.
    const counts = [_]u32{ 2, 0, 3, 1, 0 };

    var rel = try Rel.fromCounts(testing.allocator, &counts);
    defer rel.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), rel.keyCount());
    try testing.expectEqualSlices(u32, &.{ 0, 2, 2, 5, 6, 6 }, rel.offsets);
    try testing.expectEqual(@as(usize, 6), rel.values.len);
    for (counts, 0..) |c, k| try testing.expectEqual(c, rel.count(NetIdx.at(k)));

    // Fill every slot, then read back — the documented usage.
    var next: u32 = 0;
    for (0..rel.keyCount()) |k| {
        for (rel.sliceMut(NetIdx.at(k))) |*v| {
            v.* = next;
            next += 1;
        }
    }
    rel.assertValid();
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, rel.slice(NetIdx.at(0)));
    try testing.expectEqualSlices(u32, &.{ 2, 3, 4 }, rel.slice(NetIdx.at(2)));
    try testing.expectEqualSlices(u32, &.{5}, rel.slice(NetIdx.at(3)));

    // An all-zero histogram is legal and yields no values.
    var flat = try Rel.fromCounts(testing.allocator, &[_]u32{ 0, 0 });
    defer flat.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, flat.offsets);
    try testing.expectEqual(@as(usize, 0), flat.values.len);
}

test "sliceMut aliases the same storage as slice" {
    // Passes canonicalize a net's pin list in place (sorting it ascending), so the
    // mutable view has to be the *same* memory, not a copy handed back by value.
    const items = [_]Item{
        .{ .key = 0, .val = 30 },
        .{ .key = 0, .val = 10 },
        .{ .key = 0, .val = 20 },
    };
    var rel = try Rel.build(testing.allocator, 1, &items, {}, keyOfItem, valOfItem);
    defer rel.deinit(testing.allocator);

    const m = rel.sliceMut(NetIdx.at(0));
    try testing.expectEqual(@intFromPtr(rel.slice(NetIdx.at(0)).ptr), @intFromPtr(m.ptr));
    std.mem.sort(u32, m, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, rel.slice(NetIdx.at(0)));
}

test "assertValid accepts a well-formed relation and the invariant it checks is real" {
    const items = [_]Item{
        .{ .key = 0, .val = 1 },
        .{ .key = 2, .val = 2 },
    };
    var rel = try Rel.build(testing.allocator, 3, &items, {}, keyOfItem, valOfItem);
    defer rel.deinit(testing.allocator);

    rel.assertValid(); // must not panic
    try testing.expect(rel.offsets.len == rel.keyCount() + 1);
    try testing.expectEqual(@as(u32, @intCast(rel.values.len)), rel.offsets[rel.offsets.len - 1]);

    // The negative case — a non-monotone offsets array — cannot be exercised in
    // process: `assertValid` is documented to *panic*, and Zig has no catchable
    // panic. So the malformed fixture is checked against the same predicate here,
    // which at least pins that the fixture really does violate the invariant and
    // would trip a correct implementation.
    // ponytail: in-process predicate check; promote to a child-process death test
    // only if assertValid ever grows logic worth isolating.
    const bad_offsets = [_]u32{ 0, 3, 1, 4 };
    try testing.expect(!isMonotone(&bad_offsets));
    try testing.expect(isMonotone(rel.offsets));

    // Terminating at the wrong place is the other half of the invariant.
    const short_terminator = [_]u32{ 0, 1, 2 };
    try testing.expect(isMonotone(&short_terminator));
    try testing.expect(short_terminator[short_terminator.len - 1] != 5);
}

fn isMonotone(offsets: []const u32) bool {
    if (offsets.len == 0) return false;
    for (offsets[1..], 0..) |o, i| if (o < offsets[i]) return false;
    return true;
}

fn buildRelationLeakFree(gpa: Allocator, items: []const Item) !void {
    var rel = try Rel.build(gpa, 4, items, {}, keyOfItem, valOfItem);
    defer rel.deinit(gpa);
    std.debug.assert(rel.keyCount() == 4);
}

test "csr build leaks nothing when any single allocation fails" {
    // `build` allocates two arrays; failing the second must release the first. This
    // is the only check that the errdefer between them exists.
    const items = [_]Item{
        .{ .key = 0, .val = 1 },
        .{ .key = 3, .val = 2 },
        .{ .key = null, .val = 3 },
        .{ .key = 0, .val = 4 },
        .{ .key = 2, .val = 5 },
    };
    try testing.checkAllAllocationFailures(
        testing.allocator,
        buildRelationLeakFree,
        .{@as([]const Item, &items)},
    );
}
