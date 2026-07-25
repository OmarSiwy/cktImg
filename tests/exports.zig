//! Behavioral suite for the three export surfaces: JSON, the C ABI, and the TikZ emitter.
//!
//! These files have an unusual property for this codebase — their contracts are *external*.
//! `include/cktimg.h` is a promise to code we will never see, TikZ syntax is fixed by TeX,
//! and the JSON schema is what someone's post-processing script already parses. So the
//! tests here pin the parts a reasonable implementation would get away with breaking:
//!
//! - **Zero-copy is asserted with pointer arithmetic, not inferred.** `cktimg_device_name`
//!   must return a pointer *inside* the string pool, and `cktimg_wire_segment_points` must
//!   return the exact address of `Physical.wire_pts`. An implementation that duplicates the
//!   schematic the way the Rust ABI did would pass every functional test and fail these two,
//!   which is the entire reason this port exists.
//! - **Every accessor is exercised against a null handle and an out-of-range index.** That is
//!   a trust boundary; "probably safe" is not a test result.
//! - **The JSON path is checked to allocate nothing**, by streaming it into a fixed buffer
//!   and asserting the bytes match the heap-backed run exactly.
//! - **Determinism is checked by running twice and comparing bytes**, because a hash-map
//!   iteration slipping into an emitter is invisible until a golden file diff a month later.
//! - **The TikZ emitter is checked against `ids.Orient.apply` for all eight orientations**,
//!   so a hand-rolled rotation matrix in the emitter fails here rather than in a PDF.
//!
//! ## Fixtures bypass the front end
//!
//! Every schematic below is assembled straight out of `Ir`'s and `Physical`'s public columns
//! with an arena, exactly as `tests/devices.zig` and `tests/place.zig` do. An export suite
//! that could not run until the SPICE parser worked would be useless for driving these
//! files' implementation order, and the parser is being written in parallel. The arena is the
//! whole teardown, so `std.testing.allocator` still audits every byte.
//!
//! Expected red until the corresponding function is written: a `@panic("TODO")` aborts the
//! whole binary rather than failing one test, so the first panic names the next function to
//! implement.

const std = @import("std");
const ckt = @import("cktimg");
const build_options = @import("build_options");

const ids = ckt.ids;
const catalog = ckt.devices.catalog;
const host = ckt.devices.host;
const geom = ckt.geom;
const json = ckt.json;
const abi = ckt.abi;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;
const NetIdx = ids.NetIdx;
const StrId = ids.StrId;
const SymbolIdx = ids.SymbolIdx;
const Config = ckt.Config;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

/// Minimal stand-in for the interner: appends NUL-terminated bytes and records spans,
/// exactly as `strings.Interner` documents, without needing it to be implemented.
///
/// The NUL is what the whole C ABI rests on, so the fixture appends it deliberately rather
/// than relying on an allocator happening to zero the next byte.
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

/// The schematic every test below walks.
///
/// Two devices, three nets, one routed net, one junction, one unrouted-net label, and one
/// floating pin — the smallest shape that exercises every branch the exports have:
///
/// ```text
///   d0  r1   res   value "5k"   at (40,  0)  orient R0
///         pin 0 "a" -> net "out"      pin 1 "b" -> net "gnd"
///   d1  m1   nmos  value ""     at (40, 80)  orient R90 + mirror
///         pin 2 "d" -> net "out"      pin 3 "g" -> FLOATING     pin 4 "s" -> net "gnd"
///
///   net 0 "out"  one 3-point segment  (20,0) -> (20,40) -> (60,40)
///   net 1 "gnd"  no segments          (an unrouted net, on purpose)
///   net 2 "clk"  no segments, one label at (0,120)
///   junction     (20,40)
/// ```
///
/// The mirrored quarter-turn on `m1` is not decoration: it is the orientation that catches
/// an emitter applying rotation before mirroring, since the two orders disagree for exactly
/// this combination.
const Fixture = struct {
    placed: ckt.Placed,
    table: host.Table,
    /// Source text the report's spans index into.
    src: []const u8,
    report: ckt.Report,

    const src_text = ".tran 1n 1u\nr1 out gnd 5k\nm1 out g gnd nmos\n";

    /// Assemble the fixture into `arena`. Everything is arena-backed, so the caller's
    /// `arena.deinit()` is the whole teardown.
    ///
    /// `table` is returned by value and is empty — the fixture uses builtin classes only, so
    /// an empty host table is the correct vocabulary and `deinit` on it is still required.
    fn build(gpa: Allocator, arena: Allocator) !Fixture {
        var pool: Pool = .{};
        _ = try pool.add(arena, ""); // StrId.empty, as every pool assigns first

        const res = catalog.indexOf("res").?;
        const nmos = catalog.indexOf("nmos").?;
        const res_class = catalog.at(res);
        const nmos_class = catalog.at(nmos);

        const n_res = res_class.terminals.len; // 2
        const n_nmos = nmos_class.terminals.len; // 3
        const n_pin = n_res + n_nmos;

        const dev_symbol = try arena.alloc(SymbolIdx, 2);
        const dev_orient = try arena.alloc(Orient, 2);
        const dev_pin0 = try arena.alloc(u32, 3);
        const dev_name = try arena.alloc(StrId, 2);
        const dev_value = try arena.alloc(StrId, 2);
        const net_name = try arena.alloc(StrId, 3);
        const pin_net = try arena.alloc(NetIdx, n_pin);
        const pos = try arena.alloc(Pt, 2);
        const pin_xy = try arena.alloc(Pt, n_pin);

        dev_symbol[0] = res;
        dev_symbol[1] = nmos;
        dev_orient[0] = .r0;
        dev_orient[1] = .{ .rot = 1, .mirror = true };
        dev_pin0[0] = 0;
        dev_pin0[1] = @intCast(n_res);
        dev_pin0[2] = @intCast(n_pin);
        dev_name[0] = try pool.add(arena, "r1");
        dev_name[1] = try pool.add(arena, "m1");
        dev_value[0] = try pool.add(arena, "5k");
        dev_value[1] = .empty;
        net_name[0] = try pool.add(arena, "out");
        net_name[1] = try pool.add(arena, "gnd");
        net_name[2] = try pool.add(arena, "clk");
        pos[0] = .{ .x = 40, .y = 0 };
        pos[1] = .{ .x = 40, .y = 80 };

        // Pin nets: r1.a -> out, r1.b -> gnd, m1.d -> out, m1.g floating, m1.s -> gnd.
        pin_net[0] = NetIdx.at(0);
        pin_net[1] = NetIdx.at(1);
        pin_net[2] = NetIdx.at(0);
        pin_net[3] = .none;
        pin_net[4] = NetIdx.at(1);

        // Pin coordinates via `ids.Orient.apply` directly, so the fixture stays valid input
        // even while `geom.pinPoint` is a stub.
        for (res_class.terminals, 0..) |t, k| pin_xy[k] = pos[0].add(dev_orient[0].apply(t.at));
        for (nmos_class.terminals, 0..) |t, k| {
            pin_xy[n_res + k] = pos[1].add(dev_orient[1].apply(t.at));
        }

        // Nested CSR: net 0 owns segment 0, which owns points 0..3. Nets 1 and 2 own none.
        const net_seg = try arena.alloc(u32, 4);
        net_seg[0] = 0;
        net_seg[1] = 1;
        net_seg[2] = 1;
        net_seg[3] = 1;
        const seg_pt = try arena.alloc(u32, 2);
        seg_pt[0] = 0;
        seg_pt[1] = 3;
        const wire_pts = try arena.alloc(Pt, 3);
        wire_pts[0] = .{ .x = 20, .y = 0 };
        wire_pts[1] = .{ .x = 20, .y = 40 };
        wire_pts[2] = .{ .x = 60, .y = 40 };

        const junctions = try arena.alloc(Pt, 1);
        junctions[0] = .{ .x = 20, .y = 40 };

        const labels = try arena.alloc(ckt.ir.Label, 1);
        labels[0] = .{ .net = NetIdx.at(2), .at = .{ .x = 0, .y = 120 } };

        const ignored = try arena.alloc(ckt.ir.Note, 1);
        ignored[0] = .{ .off = 0, .len = 11, .reason = .analysis_card };

        return .{
            .placed = .{
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
                .physical = .{
                    .pos = pos,
                    .pin_xy = pin_xy,
                    .net_seg = net_seg,
                    .seg_pt = seg_pt,
                    .wire_pts = wire_pts,
                    .junctions = junctions,
                    .labels = labels,
                },
                .strings = pool.finish(),
            },
            .table = host.Table.init(gpa),
            .src = src_text,
            .report = .{ .ignored = ignored, .skipped = &.{} },
        };
    }
};

/// One device, one orientation, no wires — for the transform tests, where anything else is
/// noise.
fn oneDevice(arena: Allocator, class_name: []const u8, o: Orient, at: Pt) !ckt.Placed {
    var pool: Pool = .{};
    _ = try pool.add(arena, "");

    const idx = catalog.indexOf(class_name).?;
    const class = catalog.at(idx);

    const dev_symbol = try arena.alloc(SymbolIdx, 1);
    const dev_orient = try arena.alloc(Orient, 1);
    const dev_pin0 = try arena.alloc(u32, 2);
    const dev_name = try arena.alloc(StrId, 1);
    const dev_value = try arena.alloc(StrId, 1);
    const pin_net = try arena.alloc(NetIdx, class.terminals.len);
    const pos = try arena.alloc(Pt, 1);
    const pin_xy = try arena.alloc(Pt, class.terminals.len);

    dev_symbol[0] = idx;
    dev_orient[0] = o;
    dev_pin0[0] = 0;
    dev_pin0[1] = @intCast(class.terminals.len);
    dev_name[0] = try pool.add(arena, "x1");
    dev_value[0] = .empty;
    pos[0] = at;
    for (class.terminals, 0..) |t, k| {
        pin_net[k] = .none;
        pin_xy[k] = at.add(o.apply(t.at));
    }

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
            .group_path = &.{},
            .group_master = &.{},
        },
        .physical = .{
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

/// Render the fixture's JSON into a caller-owned slice.
fn jsonToSlice(gpa: Allocator, placed: ckt.Placed) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try json.write(placed, &Config.default, &aw.writer);
    return aw.toOwnedSlice();
}

/// Is `ptr` an address inside `pool.bytes`? The zero-copy predicate.
fn insidePool(pool: ckt.Strings, ptr: [*:0]const u8) bool {
    const base = @intFromPtr(pool.bytes.ptr);
    const p = @intFromPtr(ptr);
    return p >= base and p < base + pool.bytes.len;
}

// ---------------------------------------------------------------------------
// JSON: schema and content
// ---------------------------------------------------------------------------

test "json output is a document std.json can parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const doc = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();
    try expect(parsed.value == .object);
}

test "json carries every key the documented schema promises" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const doc = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    for ([_][]const u8{ "devices", "nets", "wires", "junctions", "labels" }) |key| {
        try expect(root.get(key) != null);
    }

    const devices = root.get("devices").?.array;
    try expectEqual(@as(usize, 2), devices.items.len);
    const d0 = devices.items[0].object;
    for ([_][]const u8{ "name", "class", "value", "rot", "mirror", "pos", "pins" }) |key| {
        try expect(d0.get(key) != null);
    }
    const p0 = d0.get("pins").?.array.items[0].object;
    for ([_][]const u8{ "term", "net", "xy" }) |key| {
        try expect(p0.get(key) != null);
    }
    const w0 = root.get("wires").?.array.items[0].object;
    for ([_][]const u8{ "net", "segments" }) |key| {
        try expect(w0.get(key) != null);
    }
}

test "json resolves names, values and orientation from the pool and the IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const doc = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();
    const devices = parsed.value.object.get("devices").?.array;

    const r1 = devices.items[0].object;
    try expectEqualStrings("r1", r1.get("name").?.string);
    try expectEqualStrings("res", r1.get("class").?.string);
    try expectEqualStrings("5k", r1.get("value").?.string);
    try expectEqual(@as(i64, 0), r1.get("rot").?.integer);
    try expectEqual(false, r1.get("mirror").?.bool);
    try expectEqual(@as(i64, 40), r1.get("pos").?.array.items[0].integer);
    try expectEqual(@as(i64, 0), r1.get("pos").?.array.items[1].integer);

    // The mirrored quarter turn survives the round trip as two independent fields, not as a
    // single fused "rotation" a consumer would have to guess the order of.
    const m1 = devices.items[1].object;
    try expectEqualStrings("m1", m1.get("name").?.string);
    try expectEqualStrings("nmos", m1.get("class").?.string);
    try expectEqualStrings("", m1.get("value").?.string);
    try expectEqual(@as(i64, 1), m1.get("rot").?.integer);
    try expectEqual(true, m1.get("mirror").?.bool);
}

test "a floating pin's net is json null, not an empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const doc = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();

    const m1_pins = parsed.value.object.get("devices").?.array.items[1].object.get("pins").?.array;
    try expectEqual(@as(usize, 3), m1_pins.items.len);
    // Gate is deliberately unconnected in the fixture.
    try expect(m1_pins.items[1].object.get("net").? == .null);
    try expectEqualStrings("g", m1_pins.items[1].object.get("term").?.string);
    // Its siblings are not.
    try expectEqualStrings("out", m1_pins.items[0].object.get("net").?.string);
}

test "wires carry only nets that actually drew something" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const doc = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Three nets exist; only "out" was routed.
    try expectEqual(@as(usize, 3), root.get("nets").?.array.items.len);
    const wires = root.get("wires").?.array;
    try expectEqual(@as(usize, 1), wires.items.len);
    try expectEqualStrings("out", wires.items[0].object.get("net").?.string);

    const segs = wires.items[0].object.get("segments").?.array;
    try expectEqual(@as(usize, 1), segs.items.len);
    const pts = segs.items[0].array;
    try expectEqual(@as(usize, 3), pts.items.len);
    try expectEqual(@as(i64, 20), pts.items[0].array.items[0].integer);
    try expectEqual(@as(i64, 0), pts.items[0].array.items[1].integer);
    try expectEqual(@as(i64, 60), pts.items[2].array.items[0].integer);
    try expectEqual(@as(i64, 40), pts.items[2].array.items[1].integer);
}

test "labels name the nets routing gave up on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const doc = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(doc);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, doc, .{});
    defer parsed.deinit();

    const labels = parsed.value.object.get("labels").?.array;
    try expectEqual(@as(usize, 1), labels.items.len);
    try expectEqualStrings("clk", labels.items[0].object.get("net").?.string);
    const at = labels.items[0].object.get("at").?.array;
    try expectEqual(@as(i64, 0), at.items[0].integer);
    try expectEqual(@as(i64, 120), at.items[1].integer);
}

test "json is byte-identical across two runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const a = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(a);
    const b = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(b);

    // Not `expectEqual` on lengths first: a byte diff in the middle is the failure worth
    // seeing, and expectEqualSlices prints it.
    try expectEqualSlices(u8, a, b);
}

test "json streams into a fixed buffer, allocating nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const heap = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(heap);

    // No allocator is reachable from here at all; if the emitter needed one it could not
    // compile, and if it buffered internally it would need one at run time.
    var buf: [16 * 1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try json.write(f.placed, &Config.default, &w);
    try expectEqualSlices(u8, heap, w.buffered());
}

test "a fixed buffer one byte short fails rather than truncating silently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const heap = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(heap);

    const small = try std.testing.allocator.alloc(u8, heap.len - 1);
    defer std.testing.allocator.free(small);
    var w = Writer.fixed(small);
    try std.testing.expectError(error.WriteFailed, json.write(f.placed, &Config.default, &w));
}

/// The json path under an injected allocation failure at every allocation point.
///
/// `Writer.Allocating` reports an allocation failure as `WriteFailed` (its documented
/// contract), so it is mapped back here — otherwise `checkAllAllocationFailures` sees an
/// error it did not inject and reports a spurious failure.
fn jsonUnderFailure(gpa: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.build(gpa, arena.allocator());
    defer f.table.deinit();

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    json.write(f.placed, &Config.default, &aw.writer) catch return error.OutOfMemory;

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    try expect(parsed.value == .object);
}

test "the json path leaks nothing when any allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, jsonUnderFailure, .{});
}

test "json string escaping covers quotes, backslashes and control bytes" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try json.writeString(&w, "a\"b\\c\nd\te\x01f");
    try expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001f\"", w.buffered());

    // UTF-8 above 0x7f passes through: re-escaping valid UTF-8 only bloats the diff.
    var buf2: [64]u8 = undefined;
    var w2 = Writer.fixed(&buf2);
    try json.writeString(&w2, "\u{00b5}F");
    try expectEqualStrings("\"\u{00b5}F\"", w2.buffered());
}

// ---------------------------------------------------------------------------
// JSON: the report
// ---------------------------------------------------------------------------

test "the report json keeps ignored and skipped apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try json.writeReport(f.report, f.src, &aw.writer);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        aw.written(),
        .{},
    );
    defer parsed.deinit();

    const ignored = parsed.value.object.get("ignored").?.array;
    const skipped = parsed.value.object.get("skipped").?.array;
    try expectEqual(@as(usize, 1), ignored.items.len);
    try expectEqual(@as(usize, 0), skipped.items.len);

    const n = ignored.items[0].object;
    try expectEqualStrings("analysis_card", n.get("reason").?.string);
    try expectEqual(@as(i64, 1), n.get("line").?.integer);
    try expectEqualStrings(".tran 1n 1u", n.get("text").?.string);
}

test "the report text keeps the line format C consumers already grep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try json.writeReportText(f.report, f.src, &w);
    try expect(std.mem.startsWith(u8, w.buffered(), "ignored line 1: .tran 1n 1u ("));
    try expect(std.mem.endsWith(u8, w.buffered(), "\n"));

    // A clean report writes nothing at all — the empty string the C header promises.
    var buf2: [16]u8 = undefined;
    var w2 = Writer.fixed(&buf2);
    try json.writeReportText(ckt.Report.empty, f.src, &w2);
    try expectEqual(@as(usize, 0), w2.buffered().len);
}

test "a note's line number is counted from the source, not stored" {
    try expectEqual(@as(u32, 1), json.lineOf("abc\ndef\n", 0));
    try expectEqual(@as(u32, 1), json.lineOf("abc\ndef\n", 3));
    try expectEqual(@as(u32, 2), json.lineOf("abc\ndef\n", 4));
    // No source to count in, and an offset past the end: 0, not a crash.
    try expectEqual(@as(u32, 0), json.lineOf("", 7));
    try expectEqual(@as(u32, 0), json.lineOf("abc", 99));
}

// ---------------------------------------------------------------------------
// C ABI: the view property
// ---------------------------------------------------------------------------

test "a device name is a pointer into the string pool, not a copy of it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    const name = abi.cktimg_device_name(h, 0).?;
    try expectEqualStrings("r1", std.mem.span(name));
    // The assertion that distinguishes a view from the Rust's rebuild: the bytes C reads
    // are the bytes the interner wrote, at the interner's own address.
    try expect(insidePool(f.placed.strings, name));

    const value = abi.cktimg_device_value(h, 0).?;
    try expectEqualStrings("5k", std.mem.span(value));
    try expect(insidePool(f.placed.strings, value));

    const net = abi.cktimg_pin_net(h, 0, 0).?;
    try expectEqualStrings("out", std.mem.span(net));
    try expect(insidePool(f.placed.strings, net));

    // Two accessors naming the same interned string return the SAME pointer. A per-call
    // duplicate would return two.
    try expectEqual(
        @intFromPtr(abi.cktimg_net_name(h, 0).?),
        @intFromPtr(abi.cktimg_pin_net(h, 0, 0).?),
    );
}

test "borrowed strings are NUL-terminated at exactly their reported length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    // Read the terminator out of the pool itself rather than trusting the sentinel type:
    // the whole zero-copy design rests on that byte physically existing.
    const name = abi.cktimg_device_name(h, 0).?;
    const off = @intFromPtr(name) - @intFromPtr(f.placed.strings.bytes.ptr);
    const len = std.mem.span(name).len;
    try expectEqual(@as(usize, 2), len);
    try expectEqual(@as(u8, 0), f.placed.strings.bytes[off + len]);

    // An empty value is the empty string, not null — a terminator with nothing before it.
    const empty = abi.cktimg_device_value(h, 1).?;
    try expectEqual(@as(usize, 0), std.mem.span(empty).len);
    try expectEqual(@as(u8, 0), empty[0]);

    // Class and terminal names come from the class table, not the pool, and must carry the
    // same terminator or the accessors are unsound.
    const class = abi.cktimg_device_class(h, 0).?;
    try expectEqualStrings("res", std.mem.span(class));
    const term = abi.cktimg_pin_term(h, 1, 1).?;
    try expectEqualStrings("g", std.mem.span(term));
}

test "wire segment points alias Physical.wire_pts at the same address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    var xy: ?[*]const i32 = null;
    const n = abi.cktimg_wire_segment_points(h, 0, 0, &xy);
    try expectEqual(@as(usize, 3), n);

    // Not "equal contents" — the same pointer. `Pt` is two i32 with no padding, so the
    // router's array IS the flat array C asked for and nothing was reshaped.
    try expectEqual(@intFromPtr(f.placed.physical.wire_pts.ptr), @intFromPtr(xy.?));

    const flat = xy.?[0 .. 2 * n];
    try expectEqualSlices(i32, &.{ 20, 0, 20, 40, 60, 40 }, flat);
}

test "wire index is net index and an unrouted net reports zero segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    try expectEqual(abi.cktimg_net_count(h), abi.cktimg_wire_count(h));
    try expectEqual(@as(usize, 3), abi.cktimg_wire_count(h));

    for (0..abi.cktimg_wire_count(h)) |wi| {
        try expectEqualStrings(
            std.mem.span(abi.cktimg_net_name(h, wi).?),
            std.mem.span(abi.cktimg_wire_net(h, wi).?),
        );
    }
    try expectEqual(@as(usize, 1), abi.cktimg_wire_segment_count(h, 0));
    try expectEqual(@as(usize, 0), abi.cktimg_wire_segment_count(h, 1));
    try expectEqual(@as(usize, 0), abi.cktimg_wire_segment_count(h, 2));
}

test "the handle walks devices, pins, nets, junctions and labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    try expectEqual(@as(usize, 2), abi.cktimg_device_count(h));
    try expectEqual(@as(usize, 2), abi.cktimg_device_pin_count(h, 0));
    try expectEqual(@as(usize, 3), abi.cktimg_device_pin_count(h, 1));
    try expectEqual(@as(u8, 0), abi.cktimg_device_rot(h, 0));
    try expectEqual(false, abi.cktimg_device_mirror(h, 0));
    try expectEqual(@as(u8, 1), abi.cktimg_device_rot(h, 1));
    try expectEqual(true, abi.cktimg_device_mirror(h, 1));

    var x: i32 = 0;
    var y: i32 = 0;
    try expect(abi.cktimg_device_pos(h, 1, &x, &y));
    try expectEqual(@as(i32, 40), x);
    try expectEqual(@as(i32, 80), y);

    // A null out-pointer skips that half rather than being an error.
    try expect(abi.cktimg_device_pos(h, 0, &x, null));
    try expectEqual(@as(i32, 40), x);

    try expect(abi.cktimg_pin_xy(h, 0, 0, &x, &y));
    try expectEqual(f.placed.physical.pin_xy[0], Pt{ .x = x, .y = y });

    // A floating pin has coordinates but no net.
    try expect(abi.cktimg_pin_xy(h, 1, 1, &x, &y));
    try expect(abi.cktimg_pin_net(h, 1, 1) == null);

    try expectEqual(@as(usize, 1), abi.cktimg_junction_count(h));
    try expect(abi.cktimg_junction(h, 0, &x, &y));
    try expectEqual(@as(i32, 20), x);
    try expectEqual(@as(i32, 40), y);

    try expectEqual(@as(usize, 1), abi.cktimg_label_count(h));
    try expectEqualStrings("clk", std.mem.span(abi.cktimg_label_net(h, 0).?));
    try expect(abi.cktimg_label_xy(h, 0, &x, &y));
    try expectEqual(@as(i32, 0), x);
    try expectEqual(@as(i32, 120), y);
}

test "the report is borrowed from the handle and never null for a live one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    const txt = abi.cktimg_report(h).?;
    try expect(std.mem.startsWith(u8, std.mem.span(txt), "ignored line 1:"));
    // Borrowed: the same pointer every time, so a caller may cache it.
    try expectEqual(@intFromPtr(txt), @intFromPtr(abi.cktimg_report(h).?));
}

// ---------------------------------------------------------------------------
// C ABI: the trust boundary
// ---------------------------------------------------------------------------

test "every accessor answers null, zero or false for a null handle" {
    const h: ?*const abi.Sch = null;
    var x: i32 = 7;
    var y: i32 = 7;
    var sz: u8 = 7;
    var xy: ?[*]const i32 = @ptrFromInt(@alignOf(i32)); // poison: must be overwritten
    var pts: [8]i32 = undefined;

    try expectEqual(@as(usize, 0), abi.cktimg_device_count(h));
    try expect(abi.cktimg_device_name(h, 0) == null);
    try expect(abi.cktimg_device_class(h, 0) == null);
    try expect(abi.cktimg_device_value(h, 0) == null);
    try expectEqual(@as(u8, 0), abi.cktimg_device_rot(h, 0));
    try expectEqual(false, abi.cktimg_device_mirror(h, 0));
    try expectEqual(false, abi.cktimg_device_pos(h, 0, &x, &y));
    try expectEqual(false, abi.cktimg_device_refdes_anchor(h, 0, &x, &y));

    try expectEqual(@as(usize, 0), abi.cktimg_device_pin_count(h, 0));
    try expect(abi.cktimg_pin_term(h, 0, 0) == null);
    try expect(abi.cktimg_pin_net(h, 0, 0) == null);
    try expectEqual(false, abi.cktimg_pin_xy(h, 0, 0, &x, &y));

    try expectEqual(@as(usize, 0), abi.cktimg_net_count(h));
    try expect(abi.cktimg_net_name(h, 0) == null);

    try expectEqual(@as(usize, 0), abi.cktimg_wire_count(h));
    try expect(abi.cktimg_wire_net(h, 0) == null);
    try expectEqual(@as(usize, 0), abi.cktimg_wire_segment_count(h, 0));
    try expectEqual(@as(usize, 0), abi.cktimg_wire_segment_points(h, 0, 0, &xy));
    try expect(xy == null); // written even on a miss

    try expectEqual(@as(usize, 0), abi.cktimg_junction_count(h));
    try expectEqual(false, abi.cktimg_junction(h, 0, &x, &y));

    try expectEqual(@as(usize, 0), abi.cktimg_label_count(h));
    try expect(abi.cktimg_label_net(h, 0) == null);
    try expectEqual(false, abi.cktimg_label_xy(h, 0, &x, &y));

    try expectEqual(false, abi.cktimg_bounds(h, &x, &y, &x, &y));
    try expectEqual(false, abi.cktimg_device_bounds(h, 0, &x, &y, &x, &y));
    try expectEqual(@as(usize, 0), abi.cktimg_device_op_count(h, 0));
    try expectEqual(@intFromEnum(abi.OpKind.none), abi.cktimg_device_op_kind(h, 0, 0));
    try expectEqual(@as(usize, 0), abi.cktimg_device_op_points(h, 0, 0, &pts, pts.len));
    try expectEqual(false, abi.cktimg_device_op_circle(h, 0, 0, &x, &y, &x));
    try expect(abi.cktimg_device_op_text(h, 0, 0, &x, &y, &sz) == null);

    try expect(abi.cktimg_report(h) == null);
    try expectEqual(@as(usize, 0), abi.cktimg_json(h, null, 0));

    // No out-parameter was touched.
    try expectEqual(@as(i32, 7), x);
    try expectEqual(@as(i32, 7), y);
    try expectEqual(@as(u8, 7), sz);

    // And the frees are no-ops on null.
    abi.cktimg_sch_free(null);
    abi.cktimg_string_free(null);
    try expect(abi.cktimg_parse_place(null) == null);
    var rep: ?[*:0]u8 = @ptrFromInt(@alignOf(u8));
    try expect(abi.cktimg_parse_place_with_report(null, &rep) == null);
    try expect(rep == null);
    try expect(abi.cktimg_run_json(null) == null);
}

test "every accessor answers null, zero or false for an out-of-range index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    const nd = abi.cktimg_device_count(h);
    const nn = abi.cktimg_net_count(h);
    const nw = abi.cktimg_wire_count(h);
    const nj = abi.cktimg_junction_count(h);
    const nl = abi.cktimg_label_count(h);

    var x: i32 = 7;
    var y: i32 = 7;
    var sz: u8 = 7;
    var xy: ?[*]const i32 = @ptrFromInt(@alignOf(i32));
    var pts: [8]i32 = undefined;

    try expect(abi.cktimg_device_name(h, nd) == null);
    try expect(abi.cktimg_device_class(h, nd) == null);
    try expect(abi.cktimg_device_value(h, nd) == null);
    try expectEqual(@as(u8, 0), abi.cktimg_device_rot(h, nd));
    try expectEqual(false, abi.cktimg_device_mirror(h, nd));
    try expectEqual(false, abi.cktimg_device_pos(h, nd, &x, &y));
    try expectEqual(false, abi.cktimg_device_refdes_anchor(h, nd, &x, &y));
    try expectEqual(@as(usize, 0), abi.cktimg_device_pin_count(h, nd));

    // Valid device, invalid pin.
    try expect(abi.cktimg_pin_term(h, 0, 99) == null);
    try expect(abi.cktimg_pin_net(h, 0, 99) == null);
    try expectEqual(false, abi.cktimg_pin_xy(h, 0, 99, &x, &y));

    try expect(abi.cktimg_net_name(h, nn) == null);
    try expect(abi.cktimg_wire_net(h, nw) == null);
    try expectEqual(@as(usize, 0), abi.cktimg_wire_segment_count(h, nw));
    // Valid wire, invalid segment: still writes null through the out-pointer.
    try expectEqual(@as(usize, 0), abi.cktimg_wire_segment_points(h, 0, 99, &xy));
    try expect(xy == null);
    try expectEqual(@as(usize, 0), abi.cktimg_wire_segment_points(h, nw, 0, &xy));

    try expectEqual(false, abi.cktimg_junction(h, nj, &x, &y));
    try expect(abi.cktimg_label_net(h, nl) == null);
    try expectEqual(false, abi.cktimg_label_xy(h, nl, &x, &y));

    try expectEqual(false, abi.cktimg_device_bounds(h, nd, &x, &y, &x, &y));
    try expectEqual(@as(usize, 0), abi.cktimg_device_op_count(h, nd));
    try expectEqual(@intFromEnum(abi.OpKind.none), abi.cktimg_device_op_kind(h, 0, 9999));
    try expectEqual(@intFromEnum(abi.OpKind.none), abi.cktimg_device_op_kind(h, nd, 0));
    try expectEqual(@as(usize, 0), abi.cktimg_device_op_points(h, 0, 9999, &pts, pts.len));
    try expectEqual(false, abi.cktimg_device_op_circle(h, 0, 9999, &x, &y, &x));
    try expect(abi.cktimg_device_op_text(h, 0, 9999, &x, &y, &sz) == null);

    try expectEqual(@as(i32, 7), x);
    try expectEqual(@as(i32, 7), y);
    try expectEqual(@as(u8, 7), sz);
}

// ---------------------------------------------------------------------------
// C ABI: drawing
// ---------------------------------------------------------------------------

test "bounds is the same answer geom gives, so two renderers cannot disagree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    const want = geom.bounds(f.placed.ir, f.placed.physical, abi.table()).?;
    var lo_x: i32 = 0;
    var lo_y: i32 = 0;
    var hi_x: i32 = 0;
    var hi_y: i32 = 0;
    try expect(abi.cktimg_bounds(h, &lo_x, &lo_y, &hi_x, &hi_y));
    try expectEqual(want, Rect{
        .min = .{ .x = lo_x, .y = lo_y },
        .max = .{ .x = hi_x, .y = hi_y },
    });

    const want_d = geom.deviceRect(f.placed.ir, f.placed.physical, abi.table(), .at(1));
    try expect(abi.cktimg_device_bounds(h, 1, &lo_x, &lo_y, &hi_x, &hi_y));
    try expectEqual(want_d, Rect{
        .min = .{ .x = lo_x, .y = lo_y },
        .max = .{ .x = hi_x, .y = hi_y },
    });
}

test "draw ops come back placed, with mirror applied before rotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    const class = catalog.at(f.placed.ir.dev_symbol[1]); // nmos, R90 + mirror
    const o = f.placed.ir.dev_orient[1];
    const base = f.placed.physical.pos[1];
    try expectEqual(class.draw.len, abi.cktimg_device_op_count(h, 1));

    // Op 0 of draw_nmos is `ln(-20, 0, -8, 0)`.
    try expectEqual(@intFromEnum(abi.OpKind.line), abi.cktimg_device_op_kind(h, 1, 0));
    var xy: [4]i32 = undefined;
    try expectEqual(@as(usize, 2), abi.cktimg_device_op_points(h, 1, 0, &xy, xy.len));

    const a = base.add(o.apply(class.draw[0].line.a));
    const b = base.add(o.apply(class.draw[0].line.b));
    try expectEqualSlices(i32, &.{ a.x, a.y, b.x, b.y }, &xy);

    // Sizing call: the count comes back regardless of capacity, and nothing is written.
    var untouched: [4]i32 = .{ -1, -1, -1, -1 };
    try expectEqual(@as(usize, 2), abi.cktimg_device_op_points(h, 1, 0, null, 0));
    try expectEqual(@as(usize, 2), abi.cktimg_device_op_points(h, 1, 0, &untouched, 0));
    try expectEqualSlices(i32, &.{ -1, -1, -1, -1 }, &untouched);
}

test "a polyline op reports its own point count and a circle keeps its radius" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // r1 is a resistor: its body ends in a 7-point polyline. A vsource has the circle.
    const placed = try oneDevice(arena.allocator(), "vsource", .{ .rot = 2 }, .{ .x = 0, .y = 0 });

    const h = try abi.wrap(std.testing.allocator, placed, "", ckt.Report.empty);
    defer abi.cktimg_sch_free(h);

    const class = catalog.at(placed.ir.dev_symbol[0]);
    var found_circle = false;
    for (class.draw, 0..) |op, i| {
        switch (op) {
            .circle => |c| {
                found_circle = true;
                try expectEqual(@intFromEnum(abi.OpKind.circle), abi.cktimg_device_op_kind(h, 0, i));
                var cx: i32 = 0;
                var cy: i32 = 0;
                var r: i32 = 0;
                try expect(abi.cktimg_device_op_circle(h, 0, i, &cx, &cy, &r));
                const want = placed.physical.pos[0].add(placed.ir.dev_orient[0].apply(c.c));
                try expectEqual(want, Pt{ .x = cx, .y = cy });
                // Rotation and mirroring preserve a radius; there is no scaling here.
                try expectEqual(c.r, r);
                // A circle is not a point list.
                try expectEqual(@as(usize, 0), abi.cktimg_device_op_points(h, 0, i, null, 0));
            },
            .polyline => |ps| {
                try expectEqual(
                    @intFromEnum(abi.OpKind.polyline),
                    abi.cktimg_device_op_kind(h, 0, i),
                );
                try expectEqual(ps.len, abi.cktimg_device_op_points(h, 0, i, null, 0));
            },
            else => {},
        }
    }
    try expect(found_circle);
}

test "a text op keeps its string upright and places only its anchor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The D flip-flop is the builtin with a generated box body, so it has text ops.
    const placed = try oneDevice(arena.allocator(), "dff", .{ .rot = 1 }, .{ .x = 100, .y = 100 });

    const h = try abi.wrap(std.testing.allocator, placed, "", ckt.Report.empty);
    defer abi.cktimg_sch_free(h);

    const class = catalog.at(placed.ir.dev_symbol[0]);
    var seen: usize = 0;
    for (class.draw, 0..) |op, i| {
        const t = switch (op) {
            .text => |t| t,
            else => continue,
        };
        seen += 1;
        try expectEqual(@intFromEnum(abi.OpKind.text), abi.cktimg_device_op_kind(h, 0, i));
        var x: i32 = 0;
        var y: i32 = 0;
        var size: u8 = 0;
        const s = abi.cktimg_device_op_text(h, 0, i, &x, &y, &size).?;
        // The string is byte-identical: orientation moves where text sits, never how it
        // reads, so a mirrored flip-flop must not render "KLC".
        try expectEqualStrings(t.s, std.mem.span(s));
        try expectEqual(t.size, size);
        const want = placed.physical.pos[0].add(placed.ir.dev_orient[0].apply(t.at));
        try expectEqual(want, Pt{ .x = x, .y = y });
    }
    try expect(seen > 0);
}

test "refdes anchors are computed once and stay stable across calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    var x0: i32 = 0;
    var y0: i32 = 0;
    try expect(abi.cktimg_device_refdes_anchor(h, 0, &x0, &y0));

    // The placement is sequential — label 1 dodges label 0 — so the answer must not change
    // depending on which device was asked about first, or in what order.
    var x1: i32 = 0;
    var y1: i32 = 0;
    try expect(abi.cktimg_device_refdes_anchor(h, 1, &x1, &y1));
    var again_x: i32 = 0;
    var again_y: i32 = 0;
    try expect(abi.cktimg_device_refdes_anchor(h, 0, &again_x, &again_y));
    try expectEqual(x0, again_x);
    try expectEqual(y0, again_y);

    // And it is the same answer `geom` gives our own renderers.
    const want = try geom.refdesAnchors(
        std.testing.allocator,
        f.placed.ir,
        f.placed.physical,
        f.placed.strings,
        abi.table(),
    );
    defer std.testing.allocator.free(want);
    try expectEqual(want[0], Pt{ .x = x0, .y = y0 });
    try expectEqual(want[1], Pt{ .x = x1, .y = y1 });
}

test "cktimg_json sizes with a null buffer and NUL-terminates a short one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.build(std.testing.allocator, arena.allocator());
    defer f.table.deinit();

    const h = try abi.wrap(std.testing.allocator, f.placed, f.src, f.report);
    defer abi.cktimg_sch_free(h);

    const want = try jsonToSlice(std.testing.allocator, f.placed);
    defer std.testing.allocator.free(want);

    // Sizing call: the length excludes the terminator, whatever the capacity is.
    try expectEqual(want.len, abi.cktimg_json(h, null, 0));

    const buf = try std.testing.allocator.alloc(u8, want.len + 1);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0xAA);
    try expectEqual(want.len, abi.cktimg_json(h, buf.ptr, buf.len));
    try expectEqualSlices(u8, want, buf[0..want.len]);
    try expectEqual(@as(u8, 0), buf[want.len]);

    // Truncation is detectable (return >= cap) and still leaves a valid C string.
    var small: [8]u8 = undefined;
    try expectEqual(want.len, abi.cktimg_json(h, &small, small.len));
    try expectEqual(@as(u8, 0), small[small.len - 1]);
    try expectEqualSlices(u8, want[0 .. small.len - 1], small[0 .. small.len - 1]);
}

// ---------------------------------------------------------------------------
// C ABI: host class registration
// ---------------------------------------------------------------------------

test "a class built through the C builder registers and resolves by name" {
    try expect(abi.cktimg_class_begin("exports_test_opamp"));
    try expect(abi.cktimg_class_pin("in", @intFromEnum(abi.Role.passive), -20, 0));
    try expect(abi.cktimg_class_pin("out", @intFromEnum(abi.Role.passive), 20, 0));
    const idx = abi.cktimg_class_register();
    try expect(idx != std.math.maxInt(usize));
    try expect(idx >= catalog.builtin_count);

    // Registration is append-only and idempotent on an exact repeat, so a host may re-scan
    // its symbol library every parse without growing the table.
    try expect(abi.cktimg_class_begin("exports_test_opamp"));
    try expect(abi.cktimg_class_pin("in", @intFromEnum(abi.Role.passive), -20, 0));
    try expect(abi.cktimg_class_pin("out", @intFromEnum(abi.Role.passive), 20, 0));
    try expectEqual(idx, abi.cktimg_class_register());

    const resolved = abi.table().indexOf("exports_test_opamp").?;
    try expectEqual(idx, resolved.i());
    try expectEqual(@as(u8, 2), abi.table().at(resolved).terminalCount());
}

test "the class builder refuses what the header says it refuses" {
    // No class in progress: every append fails rather than starting one implicitly.
    _ = abi.cktimg_class_register(); // drain any leftover builder
    try expectEqual(false, abi.cktimg_class_pin("p", 0, 0, 0));
    try expectEqual(false, abi.cktimg_class_line(0, 0, 1, 1));
    try expectEqual(false, abi.cktimg_class_circle(0, 0, 3));
    try expectEqual(false, abi.cktimg_class_text("t", 0, 0, 4));
    try expectEqual(std.math.maxInt(usize), abi.cktimg_class_register());

    // Null strings.
    try expectEqual(false, abi.cktimg_class_begin(null));

    // Unknown role, and a polyline too short to be one.
    try expect(abi.cktimg_class_begin("exports_test_bad"));
    try expectEqual(false, abi.cktimg_class_pin("p", 200, 0, 0));
    try expectEqual(false, abi.cktimg_class_polyline(null, 4));
    const one_point: [2]i32 = .{ 0, 0 };
    try expectEqual(false, abi.cktimg_class_polyline(&one_point, 1));
    // No pins were accepted, so registration fails and consumes the builder.
    try expectEqual(std.math.maxInt(usize), abi.cktimg_class_register());
    try expectEqual(std.math.maxInt(usize), abi.cktimg_class_register());

    // Shadowing a builtin is refused outright.
    try expect(abi.cktimg_class_begin("nmos"));
    try expect(abi.cktimg_class_pin("d", @intFromEnum(abi.Role.drain), 20, 0));
    try expectEqual(std.math.maxInt(usize), abi.cktimg_class_register());
}

test "the C role wire values match TerminalRole member for member" {
    // The header repeats these numbers; a drift here silently mis-roles every host pin,
    // which shows up as a placement difference nobody traces back to an enum.
    const pairs = .{
        .{ abi.Role.passive, catalog.TerminalRole.passive },
        .{ abi.Role.drain, catalog.TerminalRole.drain },
        .{ abi.Role.source, catalog.TerminalRole.source },
        .{ abi.Role.gate, catalog.TerminalRole.gate },
        .{ abi.Role.bulk, catalog.TerminalRole.bulk },
        .{ abi.Role.collector, catalog.TerminalRole.collector },
        .{ abi.Role.base, catalog.TerminalRole.base },
        .{ abi.Role.emitter, catalog.TerminalRole.emitter },
        .{ abi.Role.anode, catalog.TerminalRole.anode },
        .{ abi.Role.cathode, catalog.TerminalRole.cathode },
    };
    inline for (pairs) |p| {
        try expectEqual(@intFromEnum(p[0]), @intFromEnum(p[1]));
        try expectEqual(p[1], abi.Role.toTerminal(@intFromEnum(p[0])).?);
    }
    try expect(abi.Role.toTerminal(10) == null);
    try expect(abi.Role.toTerminal(255) == null);
}

// ---------------------------------------------------------------------------
// TikZ
// ---------------------------------------------------------------------------

test "the latex module is void unless the build option asked for it" {
    if (build_options.latex_renderer) {
        comptime std.debug.assert(ckt.latex != void);
    } else {
        comptime std.debug.assert(ckt.latex == void);
    }
}

test "tikz escapes every TeX special character" {
    if (!build_options.latex_renderer) return error.SkipZigTest;

    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    // Every special the escaper claims to handle, in one string.
    try ckt.latex.escape(&w, "\\^~&%$#_{}");
    try expectEqualStrings(
        "\\textbackslash{}\\textasciicircum{}\\textasciitilde{}\\&\\%\\$\\#\\_\\{\\}",
        w.buffered(),
    );

    // Ordinary bytes pass through untouched, including the ones that only *look* special.
    var buf2: [128]u8 = undefined;
    var w2 = Writer.fixed(&buf2);
    try ckt.latex.escape(&w2, "m1.xu1[3]/a-b+c");
    try expectEqualStrings("m1.xu1[3]/a-b+c", w2.buffered());
}

test "tikz negates y, because the layout is y-down and TikZ is y-up" {
    if (!build_options.latex_renderer) return error.SkipZigTest;

    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try ckt.latex.writePoint(&w, .{ .x = 40, .y = 80 });
    try expectEqualStrings("(40pt,-80pt)", w.buffered());

    // A negative layout y becomes a positive TikZ y — the flip is unconditional, not a
    // clamp.
    var buf2: [64]u8 = undefined;
    var w2 = Writer.fixed(&buf2);
    try ckt.latex.writePoint(&w2, .{ .x = -12, .y = -20 });
    try expectEqualStrings("(-12pt,20pt)", w2.buffered());

    var buf3: [64]u8 = undefined;
    var w3 = Writer.fixed(&buf3);
    try ckt.latex.writePoint(&w3, .{ .x = 0, .y = 0 });
    try expectEqualStrings("(0pt,0pt)", w3.buffered());
}

test "tikz symbol geometry matches ids.Orient.apply for all eight orientations" {
    if (!build_options.latex_renderer) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var table = host.Table.init(gpa);
    defer table.deinit();

    for ([_]bool{ false, true }) |mirror| {
        for (0..4) |rot| {
            const o: Orient = .{ .rot = @intCast(rot), .mirror = mirror };
            const base: Pt = .{ .x = 100, .y = 60 };

            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const placed = try oneDevice(arena.allocator(), "nmos", o, base);

            var aw: Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try ckt.latex.write(gpa, placed, &table, &ckt.Config.default, &aw.writer);
            const out = aw.written();

            // Every line endpoint of the symbol body must appear, transformed by the one
            // definition of mirror-then-rotate. An emitter with its own rotation matrix
            // agrees for R0 and diverges for at least one of the other seven.
            const class = catalog.at(placed.ir.dev_symbol[0]);
            for (class.draw) |op| {
                const l = switch (op) {
                    .line => |l| l,
                    else => continue,
                };
                for ([_]Pt{ l.a, l.b }) |p| {
                    const want = base.add(o.apply(p));
                    // The library's own helper must agree with the raw transform, too.
                    try expectEqual(want, ckt.latex.placePoint(o, base, p));

                    var lit: [64]u8 = undefined;
                    const text = try std.fmt.bufPrint(
                        &lit,
                        "({d}pt,{d}pt)",
                        .{ want.x, -want.y },
                    );
                    if (std.mem.indexOf(u8, out, text) == null) {
                        std.debug.print(
                            "rot={d} mirror={} missing {s}\n",
                            .{ rot, mirror, text },
                        );
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
    }
}

test "tikz emits a self-contained picture in the documented draw order" {
    if (!build_options.latex_renderer) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.build(gpa, arena.allocator());
    defer f.table.deinit();

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try ckt.latex.write(gpa, f.placed, &f.table, &ckt.Config.default, &aw.writer);
    const out = aw.written();

    try expect(std.mem.indexOf(u8, out, "\\definecolor{cktwire}{HTML}{") != null);
    try expect(std.mem.startsWith(u8, out, "\\definecolor"));
    try expect(std.mem.endsWith(u8, out, "\\end{tikzpicture}\n"));
    for ([_][]const u8{
        "cktsym/.style=",
        "cktwire/.style=",
        "cktdot/.style=",
        "cktlbl/.style=",
        "cktsymlbl/.style=",
        "cktgroup/.style=",
        "cktgrouplbl/.style=",
    }) |style| {
        try expect(std.mem.indexOf(u8, out, style) != null);
    }

    // The routed net's polyline, y-negated, in one `\draw[cktwire]` path.
    try expect(std.mem.indexOf(
        u8,
        out,
        "\\draw[cktwire] (20pt,0pt) -- (20pt,-40pt) -- (60pt,-40pt);",
    ) != null);

    // The junction dot is larger than a pin dot, so the two read differently.
    try expect(std.mem.indexOf(u8, out, "\\fill[cktdot] (20pt,-40pt) circle[radius=3pt];") != null);

    // Refdes labels are forced to the width the layout collided against.
    try expect(std.mem.indexOf(u8, out, "\\node[cktlbl] at ") != null);
    var width_buf: [32]u8 = undefined;
    const makebox = try std.fmt.bufPrint(
        &width_buf,
        "\\makebox[{d}pt][l]{{r1}}",
        .{geom.refdesWidth("r1")},
    );
    try expect(std.mem.indexOf(u8, out, makebox) != null);

    // The unrouted net gets a tag; the Rust renderer dropped it silently.
    try expect(std.mem.indexOf(u8, out, "clk") != null);

    // Wires are emitted before device symbols, which are emitted before the dots.
    const wire_at = std.mem.indexOf(u8, out, "\\draw[cktwire]").?;
    const sym_at = std.mem.indexOf(u8, out, "\\draw[cktsym]").?;
    const dot_at = std.mem.indexOf(u8, out, "\\fill[cktdot]").?;
    try expect(wire_at < sym_at);
    try expect(sym_at < dot_at);
}

test "tikz output is byte-identical across two runs" {
    if (!build_options.latex_renderer) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.build(gpa, arena.allocator());
    defer f.table.deinit();

    var a: Writer.Allocating = .init(gpa);
    defer a.deinit();
    var b: Writer.Allocating = .init(gpa);
    defer b.deinit();
    try ckt.latex.write(gpa, f.placed, &f.table, &ckt.Config.default, &a.writer);
    try ckt.latex.write(gpa, f.placed, &f.table, &ckt.Config.default, &b.writer);
    try expectEqualSlices(u8, a.written(), b.written());
}

test "tikz streams into a fixed buffer with no allocation beyond the layout passes" {
    if (!build_options.latex_renderer) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.build(gpa, arena.allocator());
    defer f.table.deinit();

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try ckt.latex.write(gpa, f.placed, &f.table, &ckt.Config.default, &aw.writer);

    var buf: [64 * 1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try ckt.latex.write(gpa, f.placed, &f.table, &ckt.Config.default, &w);
    try expectEqualSlices(u8, aw.written(), w.buffered());
}

test "the tikz emitter leaks nothing when any allocation fails" {
    if (!build_options.latex_renderer) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, tikzUnderFailure, .{});
}

/// The TikZ path under an injected allocation failure at every allocation point.
///
/// Same `Writer.Allocating` caveat as `jsonUnderFailure`: an allocation failure surfaces as
/// `WriteFailed` and is mapped back so the checker sees the failure it injected.
fn tikzUnderFailure(gpa: Allocator) !void {
    if (!build_options.latex_renderer) return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f = try Fixture.build(gpa, arena.allocator());
    defer f.table.deinit();

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    ckt.latex.write(gpa, f.placed, &f.table, &ckt.Config.default, &aw.writer) catch |e| {
        return switch (e) {
            error.WriteFailed => error.OutOfMemory,
            else => e,
        };
    };
}
