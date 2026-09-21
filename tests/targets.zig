//! The shipped target manifests, checked against the device catalog.
//!
//! A target manifest (`docs/TARGETS.md`) says "cktImg's class `opamp` is my symbol
//! `devices/opamp.sym`, and my pin order is in+, in-, out". Get that pin order wrong by
//! one slot and the emitted schematic is *wired differently* from the netlist it came
//! from — it still parses, still renders, still looks plausible, and is wrong. There is
//! no downstream check that would catch it: this file is the check.
//!
//! So the suite asserts three separate things, and all three matter:
//!
//!   1. **Every shipped manifest parses.** A `targets/*.json` that the tool rejects is a
//!      broken release, and nothing else in `zig build test` would notice.
//!   2. **Every `pins` array is a permutation of that class's catalog terminals.** The
//!      parser enforces it; this re-derives the resulting slot order independently and
//!      checks it visits each catalog slot exactly once, so a parser that accepted a bad
//!      array would be caught rather than trusted.
//!   3. **Coverage is what the manifest claims.** A manifest is allowed to omit classes,
//!      but then its `unmapped` policy is what those devices get. Pinning the counts is
//!      what turns "someone deleted a line" into a test failure instead of a silently
//!      boxed device.
//!
//! Plus the negative half: a deliberately malformed manifest must be *rejected*, with a
//! message naming the file and the offending key. A validator that never says no is not
//! a validator.
//!
//! ## Why this imports `json_main`
//!
//! Manifest parsing is front-end code, not library code — `libcktimg` never reads these
//! files (see the header of `src/json_main.zig`). `build.zig` therefore gives this suite
//! the front end's own module, so what is tested is the code the binary runs.
//!
//! ## Working directory
//!
//! The shipped manifests are read from `targets/` **relative to the build root**, which
//! is where `zig build test` runs the test binary. They are read rather than embedded on
//! purpose: the bytes checked here are the bytes that ship.

const std = @import("std");
const ckt = @import("cktimg");
const cli = @import("json_main");

const catalog = ckt.devices.catalog;
const Target = cli.Target;
const testing = std.testing;

/// Every manifest in the repository, with what it promises about catalog coverage.
///
/// The counts are deliberately hard-coded rather than computed from the file: a computed
/// count agrees with itself no matter what the file says, which tests nothing.
const shipped = [_]struct {
    path: []const u8,
    /// Catalog classes mapped explicitly.
    mapped: usize,
    /// What the classes it omits are supposed to get.
    unmapped: std.meta.Tag(cli.Unmapped),
}{
    .{ .path = "targets/xschem.json", .mapped = 73, .unmapped = .box },
    .{ .path = "targets/web.json", .mapped = 96, .unmapped = .fail },
    .{ .path = "targets/schemify.json", .mapped = 96, .unmapped = .fail },
};

/// Read a shipped manifest and parse it, failing the test with its own error message.
fn load(arena: std.mem.Allocator, path: []const u8) !Target {
    const cwd: std.Io.Dir = .cwd();
    const text = cwd.readFileAlloc(testing.io, path, arena, .limited(1 << 22)) catch |err| {
        std.debug.print("cannot read '{s}': {t} (is the cwd the build root?)\n", .{ path, err });
        return error.ManifestUnreadable;
    };
    switch (try Target.parse(arena, path, text)) {
        .ok => |t| return t,
        .err => |msg| {
            std.debug.print("{s}\n", .{msg});
            return error.ManifestRejected;
        },
    }
}

test "every shipped manifest parses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (shipped) |s| {
        const t = try load(arena.allocator(), s.path);
        try testing.expect(t.name.len > 0);
        try testing.expectEqual(@as(u32, 1), t.version);
        try testing.expect(t.classes.len == catalog.builtin_count);
    }
}

test "every shipped pin order is a permutation of the class's catalog terminals" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var checked: usize = 0;
    for (shipped) |s| {
        const t = try load(arena.allocator(), s.path);
        for (t.classes, 0..) |maybe, i| {
            const map = maybe orelse continue;
            const class = catalog.classes[i];
            try testing.expect(map.sym.len > 0);
            // An absent `pins` is the identity order and needs no check.
            if (map.order.len == 0) continue;
            checked += 1;

            try testing.expectEqual(class.terminals.len, map.order.len);
            // Independent of the parser: mark each catalog slot the order visits and
            // require every one, exactly once.
            var seen = [_]bool{false} ** 8;
            for (map.order) |slot| {
                try testing.expect(slot < class.terminals.len);
                try testing.expect(!seen[slot]);
                seen[slot] = true;
            }
            for (0..class.terminals.len) |slot| try testing.expect(seen[slot]);
        }
    }
    // A run in which no manifest reorders anything would pass every assertion above
    // while testing nothing. The shipped set does reorder (op-amps and logic gates), so
    // a zero here means the data, not the code, has regressed.
    try testing.expect(checked > 0);
}

test "shipped manifests cover the catalog as documented" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (shipped) |s| {
        const t = try load(arena.allocator(), s.path);
        try testing.expectEqual(s.mapped, t.mappedCount());
        try testing.expectEqual(s.unmapped, @as(std.meta.Tag(cli.Unmapped), t.unmapped));
        // A manifest that omits classes must say what happens to them, and one that
        // covers everything must still be able to state a policy. Both are checked by
        // `parse` requiring the key; this pins the *shipped* choice.
        if (t.mappedCount() < catalog.builtin_count) {
            try testing.expect(t.unmapped != .fail or s.unmapped == .fail);
        }
    }
}

test "a manifest's pin order is applied, not merely accepted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `opamp`'s catalog terminals are in+, out, in- — the output sits between the inputs
    // because that is where the geometry puts it. Nearly every editor lists inputs first,
    // so this is the permutation that actually occurs in practice.
    const text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "opamp": { "sym": "x", "pins": ["in+", "in-", "out"] } } }
    ;
    const t = switch (try Target.parse(arena.allocator(), "inline", text)) {
        .ok => |v| v,
        .err => |msg| {
            std.debug.print("{s}\n", .{msg});
            return error.UnexpectedRejection;
        },
    };
    const idx = catalog.indexOf("opamp").?;
    const map = t.classes[idx.i()].?;
    try testing.expectEqualSlices(u8, &.{ 0, 2, 1 }, map.order);
}

test "the emitted pin list is an index permutation into the document's own pins" {
    // `target.devices[].pins` carries **indices** into `devices[].pins`, not a second
    // copy of term/net/xy. So the property to pin is not "the copy agrees with the
    // original" — there is no copy — but "the indices are a permutation of exactly this
    // device's pin slots". Anything else either drops a pin or points at a neighbouring
    // device's net, which is the silent miswire the whole manifest path exists to stop.
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "box", "sym": "b"},
        \\  "classes": { "opamp": { "sym": "x", "pins": ["in+", "in-", "out"] } } }
    ;
    const t = switch (try Target.parse(arena.allocator(), "inline", text)) {
        .ok => |v| v,
        .err => |msg| {
            std.debug.print("{s}\n", .{msg});
            return error.UnexpectedRejection;
        },
    };

    var placed, var report = try ckt.place(gpa, &ckt.Config.default,
        \\xu1 inp inn out opamp
        \\r1 out inn 1k
        \\
    );
    defer placed.deinit(gpa);
    defer report.deinit(gpa);

    // The whole document, so the assertion is made against the bytes a consumer reads
    // rather than against the parsed manifest a second time.
    var doc: std.Io.Writer.Allocating = .init(gpa);
    defer doc.deinit();
    var table: ckt.devices.host.Table = .init(gpa);
    defer table.deinit();
    try ckt.json.writeOpen(placed, &table, &doc.writer);
    try doc.writer.writeAll(",\n");
    try t.writeBlock(placed, &doc.writer);
    try ckt.json.writeClose(&doc.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, doc.written(), .{});
    defer parsed.deinit();
    const devices = parsed.value.object.get("devices").?.array.items;
    const tdevices = parsed.value.object.get("target").?.object.get("devices").?.array.items;
    try testing.expectEqual(devices.len, tdevices.len);

    var saw_reorder = false;
    for (tdevices) |entry| {
        const d: usize = @intCast(entry.object.get("device").?.integer);
        const pins = entry.object.get("pins").?.array.items;
        const slots = devices[d].object.get("pins").?.array.items;
        try testing.expectEqual(slots.len, pins.len);

        var seen = [_]bool{false} ** 8;
        for (pins, 0..) |p, j| {
            const slot: usize = @intCast(p.integer);
            try testing.expect(slot < slots.len);
            try testing.expect(!seen[slot]);
            seen[slot] = true;
            if (slot != j) saw_reorder = true;
        }
        for (0..slots.len) |slot| try testing.expect(seen[slot]);
    }
    // An identity-only run would satisfy every assertion above while testing nothing;
    // `opamp` is mapped in+, in-, out over a catalog order of in+, out, in-.
    try testing.expect(saw_reorder);
}

/// One bad manifest and the phrase its rejection must contain.
const rejections = [_]struct { why: []const u8, text: []const u8, expect: []const u8 }{
    .{
        .why = "pins names a terminal the class does not have",
        .text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "nmos": { "sym": "x", "pins": ["d", "g", "b"] } } }
        ,
        .expect = "\"b\" is not a terminal of this class",
    },
    .{
        .why = "pins repeats a terminal",
        .text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "res": { "sym": "x", "pins": ["a", "a"] } } }
        ,
        .expect = "\"a\" appears twice",
    },
    .{
        .why = "pins is the wrong length",
        .text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "npn": { "sym": "x", "pins": ["c", "e"] } } }
        ,
        .expect = "has 2 entries, the class has 3 terminals",
    },
    .{
        .why = "the class is not in the catalog",
        .text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "nmoss": { "sym": "x" } } }
        ,
        .expect = "class \"nmoss\" is not in the cktImg catalog",
    },
    .{
        .why = "the same class is mapped twice",
        .text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "res": { "sym": "a" }, "res": { "sym": "b" } } }
        ,
        .expect = "DuplicateField",
    },
    .{
        .why = "the JSON is malformed",
        .text = "{ \"target\": \"t\", ",
        .expect = "malformed",
    },
    .{
        .why = "a class entry has no symbol",
        .text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "res": { "pins": ["a", "b"] } } }
        ,
        .expect = "class \"res\" has no \"sym\"",
    },
    .{
        .why = "box mode has nothing to draw the box with",
        .text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "box"}, "classes": {} }
        ,
        .expect = "no \"sym\" to draw it with",
    },
    .{
        .why = "the version is from the future",
        .text =
        \\{ "target": "t", "version": 2, "unmapped": {"mode": "skip"}, "classes": {} }
        ,
        .expect = "this build understands 1",
    },
    .{
        .why = "there is no unmapped policy",
        .text =
        \\{ "target": "t", "version": 1, "classes": {} }
        ,
        .expect = "missing \"unmapped\"",
    },
};

test "a bad manifest is rejected, by name and by key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for (rejections) |r| {
        switch (try Target.parse(arena.allocator(), "targets/bad.json", r.text)) {
            .ok => {
                std.debug.print("accepted a manifest that {s}\n", .{r.why});
                return error.BadManifestAccepted;
            },
            .err => |msg| {
                // Every message names the file: a build log full of bare "not a
                // permutation" lines is useless when three manifests are in flight.
                testing.expect(std.mem.indexOf(u8, msg, "targets/bad.json") != null) catch {
                    std.debug.print("message does not name the file: {s}\n", .{msg});
                    return error.MessageMissingPath;
                };
                testing.expect(std.mem.indexOf(u8, msg, r.expect) != null) catch {
                    std.debug.print("expected '{s}' in: {s}\n", .{ r.expect, msg });
                    return error.WrongMessage;
                };
            },
        }
    }
}

test "the message for a bad pin order shows the terminals it should have used" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const text =
        \\{ "target": "t", "version": 1, "unmapped": {"mode": "skip"},
        \\  "classes": { "nmos": { "sym": "x", "pins": ["d", "g", "b"] } } }
    ;
    const msg = (try Target.parse(arena.allocator(), "targets/bad.json", text)).err;
    // Naming the offending pin is not enough; the author needs the vocabulary.
    try testing.expect(std.mem.indexOf(u8, msg, "catalog terminals are d, g, s") != null);
}
