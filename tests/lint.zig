//! Behavioral suite for `lint.zig`: every rule fires, every rule is silenceable, and
//! the rule table survives a round trip through `lint.zon`.
//!
//! ## What is actually being pinned
//!
//! - **Each rule fires on a netlist that violates it.** A rule that cannot fire is
//!   worse than no rule: it reads as a guarantee nobody is enforcing.
//! - **Each rule is silent at `.off`.** Not "filtered from the output" — the scan
//!   does not run, which is what makes an all-`off` table free.
//! - **A clean fixture produces zero findings** under the shipped defaults. Twenty of
//!   the twenty-one gallery fixtures are silent; if the default policy complained
//!   about `tests/fixtures/*.spice` the defaults would be wrong, because those files
//!   are the definition of a schematic this tool draws well. The twenty-first,
//!   `transmission_gate.spice`, has no supply of any kind and is pinned to exactly one
//!   `no_ground` — the rule working, asserted rather than excluded.
//! - **An unknown rule name is reported, not fatal.** Same trade `config.zig` already
//!   makes for unknown keys — a table from a newer version still loads, so a team can
//!   share one `lint.zon` across tool versions.
//! - **Findings reach both report channels**, JSON and text, in the same document as
//!   the front end's notes rather than a second one.
//!
//! No new `.spice` fixture was added. Two rules (`floating_pin`, `symbol_geometry`)
//! are unreachable from *any* netlist — the front end rejects a short card and only a
//! host class can carry colliding anchors — so they are driven through a hand-built
//! `Ir`, which is the surface that actually produces them. The rest fire on small
//! inline decks, kept beside their assertions rather than in a file three directories
//! away.

const std = @import("std");
const ckt = @import("cktimg");

const testing = std.testing;
const Writer = std.Io.Writer;

const lint = ckt.config.lint;
const catalog = ckt.devices.catalog;
const Config = ckt.Config;
const Severity = lint.Severity;
const Rule = lint.Rule;
const Rules = lint.Rules;

/// A netlist placed and linted in one call, with everything freed by `deinit`.
const Linted = struct {
    placed: ckt.Placed,
    report: ckt.Report,
    findings: []lint.Finding,
    /// Owns the rail-appended copy of the source.
    src: []u8,

    fn run(src: []const u8, rules: Rules) !Linted {
        return runWith(src, rules, &Config.default);
    }

    fn runWith(src: []const u8, rules: Rules, cfg: *const Config) !Linted {
        const gpa = testing.allocator;
        const deck = try withRails(gpa, src);
        errdefer gpa.free(deck);

        var placed, var report = try ckt.place(gpa, cfg, deck);
        errdefer {
            placed.deinit(gpa);
            report.deinit(gpa);
        }
        // `place` resolves builtin classes only, so a null table is the whole truth
        // here — see `lint.check`'s contract.
        const findings = try lint.check(gpa, placed, null, rules);
        return .{ .placed = placed, .report = report, .findings = findings, .src = deck };
    }

    fn deinit(self: *Linted) void {
        testing.allocator.free(self.findings);
        self.placed.deinit(testing.allocator);
        self.report.deinit(testing.allocator);
        testing.allocator.free(self.src);
    }

    fn count(self: Linted, rule: Rule) usize {
        var n: usize = 0;
        for (self.findings) |f| {
            if (f.rule == rule) n += 1;
        }
        return n;
    }

    fn first(self: Linted, rule: Rule) ?lint.Finding {
        for (self.findings) |f| {
            if (f.rule == rule) return f;
        }
        return null;
    }
};

/// Append the rail devices a SPICE deck does not carry, exactly as `cktimg-json`,
/// `cktimg-tex` and the gallery all do before calling the library.
///
/// Linting the raw deck instead would measure a schematic nobody draws: every front
/// end adds these, so `vdd` and `gnd` are two-pin nets with a supply symbol on them by
/// the time any user sees geometry. Always returns a fresh buffer, so freeing it is
/// unconditional.
fn withRails(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\n{s}{s}", .{
        src,
        if (hasToken(src, "vdd")) "XVDD vdd vdd\n" else "",
        if (hasToken(src, "gnd")) "XGND gnd gnd\n" else "",
    });
}

fn hasToken(src: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, src, " \t\r\n");
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(t, word)) return true;
    }
    return false;
}

/// Exactly one rule enabled, at `sev`. The way to test a rule without every other
/// rule's findings in the way — and the usage the `Rules.off` base exists for.
fn only(rule: Rule, sev: Severity) Rules {
    var r: Rules = .off;
    switch (rule) {
        inline else => |tag| @field(r, @tagName(tag)) = sev,
    }
    return r;
}

// A deliberately broken deck. Two defects no fixture in the gallery has, because a
// gallery fixture is by definition a schematic worth drawing:
//   - `r1` declared twice     -> duplicate_refdes
//   - no ground symbol at all -> no_ground
const broken =
    \\* deliberately broken
    \\r1 in out 1k
    \\r1 out mid 2k
    \\c1 mid in 1u
    \\
;

const clean =
    \\* one resistor between a source and ground
    \\v1 in gnd dc 1
    \\r1 in gnd 1k
    \\
;

test "each rule fires on a netlist that violates it" {
    // duplicate_refdes: the second `r1` is the finding; the first is the one that is
    // fine, and flagging both would double every complaint.
    {
        var l = try Linted.run(broken, only(.duplicate_refdes, .err));
        defer l.deinit();
        try testing.expectEqual(@as(usize, 1), l.count(.duplicate_refdes));
        const f = l.first(.duplicate_refdes).?;
        try testing.expectEqual(Severity.err, f.severity);
        try testing.expect(f.dev != .none);
        try testing.expect(f.net == .none); // located by device, not by net
        try testing.expectEqualStrings("r1", l.placed.strings.get(l.placed.ir.dev_name[f.dev.i()]));
    }

    // no_ground: a deck with no ground symbol gets exactly one finding, about the
    // schematic rather than about any one device.
    {
        var l = try Linted.run(broken, only(.no_ground, .warn));
        defer l.deinit();
        try testing.expectEqual(@as(usize, 1), l.count(.no_ground));
        const f = l.first(.no_ground).?;
        try testing.expect(f.dev == .none and f.net == .none);
    }

    // floating_pin can only come from a host-built `Ir`: `flatten.emitElem` rejects a
    // short card rather than writing `NetIdx.none`. So it is driven through the IR
    // directly, which is public surface and the documented other producer.
    {
        var dev_symbol = [_]ckt.ids.SymbolIdx{catalog.indexOf("res").?};
        var dev_orient = [_]ckt.ids.Orient{.r0};
        var dev_pin0 = [_]u32{ 0, 2 };
        var pin_net = [_]ckt.ids.NetIdx{ .at(0), .none };
        var strs = [_]ckt.ids.StrId{.empty};
        const ir: ckt.Ir = .{
            .dev_symbol = &dev_symbol,
            .dev_orient = &dev_orient,
            .dev_pin0 = &dev_pin0,
            .pin_net = &pin_net,
            .dev_name = &strs,
            .dev_value = &strs,
            .net_name = &strs,
            .group_path = &.{},
            .group_master = &.{},
        };
        const placed: ckt.Placed = .{ .ir = ir, .physical = .empty, .strings = .empty };
        const hit = try lint.check(testing.allocator, placed, null, only(.floating_pin, .warn));
        defer testing.allocator.free(hit);
        try testing.expectEqual(@as(usize, 1), hit.len);
        try testing.expectEqual(ckt.ids.DeviceIdx.at(0), hit[0].dev);
        try testing.expect(hit[0].net == .none); // located by device: there is no net
    }

    // single_pin_net: `dangle` is named by exactly one pin, so it connects nothing.
    {
        var l = try Linted.run(
            \\v1 in gnd dc 1
            \\r1 in dangle 1k
            \\
        , only(.single_pin_net, .warn));
        defer l.deinit();
        try testing.expectEqual(@as(usize, 1), l.count(.single_pin_net));
        const f = l.first(.single_pin_net).?;
        try testing.expect(f.net != .none);
        try testing.expect(f.dev == .none); // located by net, not by device
        try testing.expectEqualStrings("dangle", l.placed.strings.get(l.placed.ir.net_name[f.net.i()]));
    }

    // unmapped_master: the PDK workflow this rule exists for. A team marks a foundry
    // prefix as a leaf so it is not flattened; the masters that then resolve to
    // nothing become labelled boxes, and this is what tells them which ones.
    {
        var cfg: Config = .default;
        cfg.pdk.leaf = &.{"zzz_*"};
        cfg.pdk.scan = false; // no name-token guess, so the box fallback is reached

        var l = try Linted.runWith(
            \\v1 in gnd dc 1
            \\xu1 in gnd zzz_widget
            \\
        , only(.unmapped_master, .warn), &cfg);
        defer l.deinit();
        try testing.expectEqual(@as(usize, 1), l.count(.unmapped_master));
        const f = l.first(.unmapped_master).?;
        try testing.expect(f.dev != .none);
        try testing.expectEqualStrings("xu1", l.placed.strings.get(l.placed.ir.dev_name[f.dev.i()]));
    }

    // symbol_geometry fires off the *class table*, so it is driven through a host
    // class registered with two terminals on one anchor — the fault the retired
    // `layout.strict_geometry` bool used to turn into a hard error. A netlist cannot
    // produce it; only a host can.
    {
        var table: ckt.devices.host.Table = .init(testing.allocator);
        defer table.deinit();
        const idx = try table.register(.{
            .name = "collided",
            .terminals = &.{
                .{ .name = "a", .at = .{ .x = 0, .y = 0 } },
                .{ .name = "b", .at = .{ .x = 0, .y = 0 } },
            },
        });

        var ir: ckt.Ir = .empty;
        var dev_symbol = [_]ckt.ids.SymbolIdx{idx};
        var dev_orient = [_]ckt.ids.Orient{.r0};
        var dev_pin0 = [_]u32{ 0, 2 };
        var pin_net = [_]ckt.ids.NetIdx{ .at(0), .at(0) };
        var strs = [_]ckt.ids.StrId{.empty};
        ir = .{
            .dev_symbol = &dev_symbol,
            .dev_orient = &dev_orient,
            .dev_pin0 = &dev_pin0,
            .pin_net = &pin_net,
            .dev_name = &strs,
            .dev_value = &strs,
            .net_name = &strs,
            .group_path = &.{},
            .group_master = &.{},
        };
        const placed: ckt.Placed = .{ .ir = ir, .physical = .empty, .strings = .empty };

        const hit = try lint.check(testing.allocator, placed, &table, only(.symbol_geometry, .err));
        defer testing.allocator.free(hit);
        try testing.expectEqual(@as(usize, 1), hit.len);
        try testing.expectEqual(Rule.symbol_geometry, hit[0].rule);
        try testing.expectEqual(Severity.err, hit[0].severity);

        // Arity is the other half of the same rule: one node for a two-terminal class.
        var short_pin0 = [_]u32{ 0, 1 };
        var short_net = [_]ckt.ids.NetIdx{.at(0)};
        var ir2 = ir;
        ir2.dev_pin0 = &short_pin0;
        ir2.pin_net = &short_net;
        const placed2: ckt.Placed = .{ .ir = ir2, .physical = .empty, .strings = .empty };
        const hit2 = try lint.check(testing.allocator, placed2, &table, only(.symbol_geometry, .err));
        defer testing.allocator.free(hit2);
        try testing.expectEqual(@as(usize, 1), hit2.len);
    }

    // label_fallback reads `Physical.labels` — geometry routing already wrote down,
    // never a fresh measurement. Driven directly for that reason: it is a read.
    {
        var labels = [_]ckt.ir.Label{.{ .net = .at(0), .at = .{ .x = 0, .y = 0 } }};
        var phys: ckt.Physical = .empty;
        phys.labels = &labels;
        const placed: ckt.Placed = .{ .ir = .empty, .physical = phys, .strings = .empty };

        const hit = try lint.check(testing.allocator, placed, null, only(.label_fallback, .warn));
        defer testing.allocator.free(hit);
        try testing.expectEqual(@as(usize, 1), hit.len);
        try testing.expectEqual(ckt.ids.NetIdx.at(0), hit[0].net);
    }
}

test "a rule at off produces nothing, for every rule" {
    // The exhaustive half: `inline for` over the table means a rule added later is
    // covered here without an edit, which is the whole reason `Rule` is derived from
    // `Rules` rather than written out twice.
    var l = try Linted.run(broken, .off);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.findings.len);

    // Enabling one rule at a time never reports a *different* rule either: the scan
    // is gated on its own severity and on nothing else.
    inline for (@typeInfo(Rules).@"struct".fields) |f| {
        const rule = @field(Rule, f.name);
        var one = try Linted.run(broken, only(rule, .warn));
        defer one.deinit();
        try testing.expectEqual(one.count(rule), one.findings.len);
    }
}

test "the shipped defaults are silent on a clean schematic" {
    // If the default policy complains about a well-formed deck, the defaults are the
    // bug. This is the assertion that keeps the rule set honest as it grows.
    var l = try Linted.run(clean, .{});
    defer l.deinit();
    if (l.findings.len != 0) {
        for (l.findings) |f| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(f.rule), f.text() });
    }
    try testing.expectEqual(@as(usize, 0), l.findings.len);
}

/// The gallery, embedded rather than read from disk: `zig build test` runs the binary
/// from wherever the build system puts it, and a cwd-relative open would pass or fail
/// on that rather than on the code.
const gallery = [_][]const u8{
    "cascode.spice",             "cascode_current_mirror.spice",
    "common_source.spice",       "cross_coupled_pair.spice",
    "cs_isource_load.spice",     "current_mirror.spice",
    "differential_pair.spice",   "diode_connected.spice",
    "folded_cascode.spice",      "gain_boosted_cascode.spice",
    "inverter_chain.spice",      "ota_5t.spice",
    "push_pull.spice",           "source_degenerated.spice",
    "source_driven_rc.spice",    "stacked_bias_string.spice",
    "tail_current_source.spice", "three_stage_nested_miller.spice",
    "two_stage_miller.spice",    "wilson_mirror.spice",
};

test "every gallery fixture is clean under the shipped defaults" {
    // The gallery is the definition of a schematic this tool draws well, so the
    // default severities must not fire on any of it. A default that complains here is
    // a default that would complain about every real design review — which is the
    // reason `single_pin_net` ships `.off`: the bias and gate-drive nets of an open
    // top-level deck are one-pin nets by construction.
    inline for (gallery) |name| {
        var l = try Linted.run(@embedFile("fixtures/" ++ name), .{});
        defer l.deinit();
        if (l.findings.len != 0) {
            std.debug.print("{s}:\n", .{name});
            for (l.findings) |f| std.debug.print("  {s} {s}\n", .{ @tagName(f.rule), f.text() });
        }
        try testing.expectEqual(@as(usize, 0), l.findings.len);
    }

    // The twenty-first fixture is the exception, and it is the rule working rather
    // than failing: a transmission gate is a fragment with no supply of any kind, so
    // `no_ground` fires — once, and alone.
    var tg = try Linted.run(@embedFile("fixtures/transmission_gate.spice"), .{});
    defer tg.deinit();
    try testing.expectEqual(@as(usize, 1), tg.findings.len);
    try testing.expectEqual(Rule.no_ground, tg.findings[0].rule);
}

test "severities come from lint.zon and an unknown rule is reported, not fatal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var diags: std.ArrayList(ckt.config.Diagnostic) = .empty;
    defer diags.deinit(testing.allocator);

    const cfg = try Config.parse(arena.allocator(),
        \\.{
        \\    .rules = .{
        \\        .duplicate_refdes = .warn,
        \\        .no_ground = .off,
        \\        .wire_crossing = .err,
        \\    },
        \\}
    , &diags);

    // Named rules took the document's severity; siblings kept their defaults.
    try testing.expectEqual(Severity.warn, cfg.rules.duplicate_refdes);
    try testing.expectEqual(Severity.off, cfg.rules.no_ground);
    try testing.expectEqual(Severity.warn, cfg.rules.floating_pin);

    // `wire_crossing` is a rule this version deliberately does not implement (the
    // placer's crossing count is not retained past candidate selection). A config
    // naming it still loads.
    var found_unknown = false;
    for (diags.items) |d| {
        if (d.kind == .unknown_key and std.mem.eql(u8, d.key, "wire_crossing")) found_unknown = true;
    }
    try testing.expect(found_unknown);

    // And the parsed table drives `check`: `no_ground` is off, so the deck that would
    // otherwise report it is silent, while `duplicate_refdes` downgrades to a warning.
    var l = try Linted.run(broken, cfg.rules);
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.count(.no_ground));
    try testing.expectEqual(@as(usize, 1), l.count(.duplicate_refdes));
    try testing.expectEqual(Severity.warn, l.first(.duplicate_refdes).?.severity);
}

test "findings are ordered by rule then by index, reproducibly" {
    var l = try Linted.run(broken, .{});
    defer l.deinit();
    try testing.expect(l.findings.len >= 2);

    // Rule order is declaration order; within a rule, ascending index. No hash map is
    // iterated anywhere in `check`, which is what makes this hold across runs.
    var prev: usize = 0;
    for (l.findings) |f| {
        const k = @intFromEnum(f.rule);
        try testing.expect(k >= prev);
        prev = k;
    }

    var again = try Linted.run(broken, .{});
    defer again.deinit();
    try testing.expectEqualSlices(lint.Finding, l.findings, again.findings);
}

test "findings reach both report channels, beside the front end's notes" {
    var l = try Linted.run(broken, .{});
    defer l.deinit();
    try testing.expect(l.findings.len >= 1);

    // JSON: one document, `lint` beside `ignored` and `skipped`.
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try ckt.json.writeReportWith(l.report, l.findings, l.placed, "", &aw.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("lint").?.array;
    try testing.expectEqual(l.findings.len, arr.items.len);
    try testing.expect(parsed.value.object.get("ignored") != null);
    try testing.expect(parsed.value.object.get("skipped") != null);

    const dup = arr.items[0].object;
    try testing.expectEqualStrings("duplicate_refdes", dup.get("rule").?.string);
    try testing.expectEqualStrings("err", dup.get("severity").?.string);
    try testing.expectEqualStrings("r1", dup.get("dev").?.string);
    try testing.expectEqual(std.json.Value.null, dup.get("net").?);

    // The three-argument form emits the same shape with an empty array, so a consumer
    // reads `lint` unconditionally.
    var aw2: Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try ckt.json.writeReport(l.report, "", &aw2.writer);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw2.written(), .{});
    defer parsed2.deinit();
    try testing.expectEqual(@as(usize, 0), parsed2.value.object.get("lint").?.array.items.len);

    // Text: severity is the second field, so `grep '^lint err'` is the build gate.
    var tw: Writer.Allocating = .init(testing.allocator);
    defer tw.deinit();
    try ckt.json.writeReportTextWith(l.report, l.findings, l.placed, "", &tw.writer);
    try testing.expect(std.mem.indexOf(u8, tw.written(), "lint err duplicate_refdes: device r1 (") != null);
    try testing.expect(std.mem.indexOf(u8, tw.written(), "lint warn no_ground: schematic (") != null);

    // A clean netlist with nothing to say still writes nothing at all.
    var cw: Writer.Allocating = .init(testing.allocator);
    defer cw.deinit();
    try ckt.json.writeReportTextWith(ckt.Report.empty, &.{}, null, "", &cw.writer);
    try testing.expectEqual(@as(usize, 0), cw.written().len);
}

test "err fails the build and warn does not — the whole reason for two severities" {
    // `json.anyError` is the CI contract `cktimg-json --lint` and `cktimg-tex --lint`
    // turn into exit status 2. If it ever answered true for a `warn`, every schematic
    // with a groundless fragment would break somebody's pipeline; if it answered false
    // for an `err`, the linter would be decorative. Both directions are pinned.
    try testing.expect(!ckt.json.anyError(&.{}));

    var only_warn = try Linted.run(broken, only(.no_ground, .warn));
    defer only_warn.deinit();
    try testing.expect(only_warn.findings.len > 0);
    try testing.expect(!ckt.json.anyError(only_warn.findings));

    // The shipped defaults put `duplicate_refdes` at `.err`, so the deck with two `r1`s
    // is exactly the case a build gate must reject — and it reaches that verdict through
    // `lint.zon`, not through a hard-coded list of fatal rules.
    var defaults = try Linted.run(broken, .{});
    defer defaults.deinit();
    try testing.expect(ckt.json.anyError(defaults.findings));

    // ...and the same deck under a table that downgrades it passes, because which rules
    // are fatal is the config's call.
    var downgraded = try Linted.run(broken, .{ .duplicate_refdes = .warn });
    defer downgraded.deinit();
    try testing.expect(downgraded.count(.duplicate_refdes) == 1);
    try testing.expect(!ckt.json.anyError(downgraded.findings));
}

test "the lint member splices into the geometry document without materializing it" {
    // What `cktimg-json --lint` emits: `writeOpen`, one keyed member, `writeClose`. The
    // point of the split is that the document never exists in memory here — the only
    // buffer is the test's, and the bytes are the same ones the CLI streams to a file.
    var l = try Linted.run(broken, .{});
    defer l.deinit();
    try testing.expect(l.findings.len >= 1);

    var table: ckt.devices.host.Table = .init(testing.allocator);
    defer table.deinit();

    var doc: Writer.Allocating = .init(testing.allocator);
    defer doc.deinit();
    try ckt.json.writeOpen(l.placed, &table, &doc.writer);
    try doc.writer.writeAll(",\n");
    try ckt.json.writeLint(&doc.writer, l.findings, l.placed);
    try ckt.json.writeClose(&doc.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, doc.written(), .{});
    defer parsed.deinit();
    // The geometry keys are untouched and `lint` sits beside them.
    for ([_][]const u8{ "devices", "nets", "wires", "junctions", "labels" }) |k| {
        try testing.expect(parsed.value.object.get(k) != null);
    }
    const arr = parsed.value.object.get("lint").?.array;
    try testing.expectEqual(l.findings.len, arr.items.len);
    try testing.expectEqualStrings("duplicate_refdes", arr.items[0].object.get("rule").?.string);
    try testing.expectEqualStrings("r1", arr.items[0].object.get("dev").?.string);

    // Without the member the two halves are exactly `writeWith`, which is what keeps the
    // no-flag document byte-for-byte what it has always been.
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try ckt.json.writeOpen(l.placed, &table, &plain.writer);
    try ckt.json.writeClose(&plain.writer);

    var whole: Writer.Allocating = .init(testing.allocator);
    defer whole.deinit();
    try ckt.json.writeWith(l.placed, &table, &ckt.Config.default, &whole.writer);
    try testing.expectEqualStrings(whole.written(), plain.written());

    // An empty findings list still emits the key: "the rules ran and found nothing" is a
    // different statement from "the rules did not run", and a consumer reads it either way.
    var empty: Writer.Allocating = .init(testing.allocator);
    defer empty.deinit();
    try ckt.json.writeLint(&empty.writer, &.{}, l.placed);
    try testing.expectEqualStrings("  \"lint\": []", empty.written());
}
