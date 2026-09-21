//! Schematic review rules: what a team considers wrong with a netlist, and how
//! badly.
//!
//! ## Immediate mode
//!
//! There is no rule engine to construct, no registry to populate and no context to
//! keep in sync. `check` is one function: hand it the data, get a slice of findings,
//! free the slice. The rule table travels as a **value** (`Rules`, one `Severity` per
//! rule), so two threads can lint two schematics under two different policies with no
//! shared state, and a caller who wants only one rule passes `Rules.off` with that one
//! field set rather than registering and deregistering anything.
//!
//! The consequence worth naming: a caller can lint data this library never produced.
//! `check` takes `Ir` + `Physical` + a class table, all of which are plain arrays a
//! host can fill itself.
//!
//! ## Only what the data already says
//!
//! Every rule here is answerable from the IR columns, the class table, or geometry
//! that is *stored* — never from a fresh measurement pass. `label_fallback` reads
//! `Physical.labels`, which routing already wrote down. Crossings and body hits are
//! deliberately **absent**: `metric.Key` computes both for the winning candidate but
//! the pipeline does not retain it, and re-deriving them here would mean a second
//! O(n²) sweep over the wires to restate a number the placer already knew. See the
//! rule list below.
//!
//! ## Determinism
//!
//! Findings come out in rule-declaration order, and within a rule in ascending index
//! order. `duplicate_refdes` sorts; nothing iterates a hash map (ARCHITECTURE.md §7).
//! Two runs over the same input produce byte-identical reports.
//!
//! ## Severity is the knob, not a boolean
//!
//! `off` suppresses the scan entirely — an `off` rule costs nothing, not even a
//! filtered finding. `warn` and `err` both produce findings and differ only in the
//! `severity` field, because what a build does about an error is the caller's policy,
//! not this module's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("ids.zig");
const irm = @import("ir.zig");
const catalog = @import("devices/catalog.zig");
const host = @import("devices/host.zig");

const DeviceIdx = ids.DeviceIdx;
const NetIdx = ids.NetIdx;
const StrId = ids.StrId;
const Ir = irm.Ir;
const Physical = irm.Physical;
const Placed = irm.Placed;

/// How much a rule's finding is worth.
///
/// `off` is not "report and ignore" — the scan does not run, so an all-`off` table
/// makes `check` a no-op that allocates nothing.
pub const Severity = enum {
    off,
    warn,
    err,
};

/// The rule table, one severity per rule. This is the `.rules` block of `lint.zon`.
///
/// A plain struct with defaults rather than an array, for three reasons: the zon
/// parser matches fields by name and reports an unrecognized one for free (a rule
/// table from a newer version still loads), the defaults are visible at the
/// declaration, and `Rule` below is derived from it so the two can never drift.
///
/// Defaults encode the house style this repository already had: geometry faults were
/// *measured*, not fatal (the retired `layout.strict_geometry` defaulted to false),
/// and a label fallback is a documented outcome rather than a defect.
pub const Rules = struct {
    /// A device terminal wired to no net at all.
    ///
    /// Only a host-built `Ir` can carry one: the netlist front end rejects a short
    /// card rather than emitting `NetIdx.none` (see `flatten.emitElem`). The rule is
    /// on by default anyway, because `Ir` is public surface and a floating pin there
    /// is silently dropped by `netPins` and never routed.
    floating_pin: Severity = .warn,
    /// A net touched by exactly one pin: it connects nothing.
    ///
    /// **Off by default.** In a top-level deck the primary inputs are single-pin nets
    /// — every bias and every gate drive in `tests/fixtures` is one — so a `warn`
    /// default would fire on well-formed input. Turn it on for a closed design, where
    /// a one-pin net really is a typo.
    single_pin_net: Severity = .off,
    /// Two devices sharing a reference designator after flattening.
    duplicate_refdes: Severity = .err,
    /// A subckt master no rule resolved, drawn as the generic labelled box.
    unmapped_master: Severity = .warn,
    /// No ground symbol anywhere in the schematic.
    no_ground: Severity = .warn,
    /// A symbol whose terminals collide or whose arity disagrees with its card.
    /// This is the rule the `layout.strict_geometry` bool used to be.
    symbol_geometry: Severity = .warn,
    /// A net routing proved undrawable and dropped to a name tag.
    label_fallback: Severity = .off,

    /// Every rule silenced. The base for "I want exactly one rule".
    pub const off: Rules = blk: {
        var r: Rules = .{};
        for (@typeInfo(Rules).@"struct".fields) |f| @field(r, f.name) = .off;
        break :blk r;
    };

    /// Severity of `rule` in this table.
    ///
    /// An `inline switch`, so it compiles to the same field load a direct `.floating_pin`
    /// access would — the enum exists to name a rule at run time, not to add a lookup.
    pub fn severityOf(self: Rules, rule: Rule) Severity {
        switch (rule) {
            inline else => |tag| return @field(self, @tagName(tag)),
        }
    }
};

/// One rule, named. Derived from `Rules`' fields so adding a field adds a rule and
/// there is no second list to forget.
///
/// `@tagName` is the wire name a report prints and a `lint.zon` writes.
pub const Rule = std.meta.FieldEnum(Rules);

/// One complaint about a schematic.
///
/// ## Why this is not an `ir.Note`
///
/// `Note` is located by **source span** (`off`, `len` into the netlist text). The IR
/// does not keep a per-device or per-net span — `dev_name` is a `StrId` and the
/// tokens it came from are gone by the time placement runs — so every lint finding
/// forced into a `Note` would carry a fabricated offset, and a consumer highlighting
/// it would underline the wrong line. Locating by index is the truth the data
/// actually supports; a caller who wants a line number can find the device by name in
/// the source it still holds.
///
/// Both locators use the sentinel convention from `ids.zig`: `.none` means "this rule
/// is not about one of those". `no_ground` carries neither, because it is about the
/// schematic as a whole.
pub const Finding = struct {
    rule: Rule,
    /// Never `.off` — an `off` rule produces no findings.
    severity: Severity,
    /// The offending device, or `.none`.
    dev: DeviceIdx = .none,
    /// The offending net, or `.none`.
    net: NetIdx = .none,

    /// Static one-line description of the rule. No allocation.
    pub fn text(self: Finding) []const u8 {
        return switch (self.rule) {
            .floating_pin => "device terminal is connected to no net",
            .single_pin_net => "net is touched by only one pin",
            .duplicate_refdes => "reference designator is not unique",
            .unmapped_master => "subckt master resolved to the generic box",
            .no_ground => "schematic has no ground symbol",
            .symbol_geometry => "symbol terminals collide or the pin count disagrees",
            .label_fallback => "net could not be routed and became a name tag",
        };
    }
};

/// Run every enabled rule over a placed schematic.
///
/// `table` resolves `SymbolIdx` to a class; pass `null` when the schematic is
/// builtin-only, exactly as `json.write` does — a stray host index with a `null`
/// table is a producer bug and is asserted, not papered over.
///
/// Caller owns the result and frees it with `gpa`. Follows the arena discipline in
/// `root.zig`'s header: pass the `out` arena and the findings die with the drawing;
/// pass a gpa and free the one slice. Nothing else is allocated and nothing is
/// retained — call it again with a different `Rules` and the two answers are
/// independent.
///
/// Errors: `OutOfMemory` only. A malformed schematic produces findings, never an
/// error. Complexity O(devices × terminals² + pins + nets + devices log devices).
pub fn check(
    gpa: Allocator,
    placed: Placed,
    table: ?*const host.Table,
    rules: Rules,
) Allocator.Error![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(gpa);
    const ir = placed.ir;

    // Rule order is declaration order, so the report reads the same way every time.
    if (rules.floating_pin != .off) {
        for (0..ir.deviceCount()) |di| {
            const lo, const hi = ir.pinRange(.at(di));
            for (lo..hi) |p| {
                if (ir.pin_net[p] != .none) continue;
                try out.append(gpa, .{
                    .rule = .floating_pin,
                    .severity = rules.floating_pin,
                    .dev = .at(di),
                });
            }
        }
    }

    if (rules.single_pin_net != .off) {
        // A dense count rather than the `netPins` CSR: the question is only "how
        // many", so the values array that CSR would build is pure waste here.
        const tally = try gpa.alloc(u32, ir.netCount());
        defer gpa.free(tally);
        @memset(tally, 0);
        for (ir.pin_net) |n| {
            if (n != .none) tally[n.i()] += 1;
        }
        for (tally, 0..) |k, ni| {
            if (k != 1) continue;
            try out.append(gpa, .{
                .rule = .single_pin_net,
                .severity = rules.single_pin_net,
                .net = .at(ni),
            });
        }
    }

    if (rules.duplicate_refdes != .off) {
        try findDuplicates(gpa, ir, rules.duplicate_refdes, &out);
    }

    if (rules.unmapped_master != .off) {
        // The fallback class the front end substitutes when `pdk.unknown_as_box` is
        // on. Compared by index, not by name, so a host class that happens to be
        // called "generic" is not mistaken for it.
        const generic = catalog.indexOf("generic");
        if (generic) |g| {
            for (ir.dev_symbol, 0..) |s, di| {
                if (s != g) continue;
                try out.append(gpa, .{
                    .rule = .unmapped_master,
                    .severity = rules.unmapped_master,
                    .dev = .at(di),
                });
            }
        }
    }

    if (rules.no_ground != .off) {
        // The same definition `place/ctx.zig` uses: a schematic is grounded because a
        // ground *symbol* is in it, never because a net is spelled `gnd`.
        var grounded = false;
        for (ir.dev_symbol) |s| {
            if (classOf(table, s).role == .ground_rail) {
                grounded = true;
                break;
            }
        }
        if (!grounded) try out.append(gpa, .{
            .rule = .no_ground,
            .severity = rules.no_ground,
        });
    }

    if (rules.symbol_geometry != .off) {
        for (ir.dev_symbol, 0..) |s, di| {
            const class = classOf(table, s);
            if (!badGeometry(class, ir.pinCountOf(.at(di)))) continue;
            try out.append(gpa, .{
                .rule = .symbol_geometry,
                .severity = rules.symbol_geometry,
                .dev = .at(di),
            });
        }
    }

    if (rules.label_fallback != .off) {
        // Stored, not measured: routing wrote this list when it gave up on a net.
        for (placed.physical.labels) |l| {
            try out.append(gpa, .{
                .rule = .label_fallback,
                .severity = rules.label_fallback,
                .net = l.net,
            });
        }
    }

    return out.toOwnedSlice(gpa);
}

/// Report the second and later device under each repeated name.
///
/// Sorts `(name, device)` pairs and walks for adjacent equal names, so the output is
/// ascending by device index within a name and no hash map is involved. The *first*
/// occurrence is left alone deliberately: it is the one that is fine, and flagging it
/// would double every complaint.
///
/// Unnamed devices (`StrId.empty`) are skipped — rails and ports carry no reference
/// designator, and treating them as all-identical would bury the real duplicates.
fn findDuplicates(
    gpa: Allocator,
    ir: Ir,
    severity: Severity,
    out: *std.ArrayList(Finding),
) Allocator.Error!void {
    const Pair = struct {
        name: StrId,
        dev: u32,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            if (a.name != b.name) return @intFromEnum(a.name) < @intFromEnum(b.name);
            return a.dev < b.dev;
        }
    };

    var pairs = try gpa.alloc(Pair, ir.deviceCount());
    defer gpa.free(pairs);
    var n: usize = 0;
    for (ir.dev_name, 0..) |name, di| {
        if (name == .empty) continue;
        pairs[n] = .{ .name = name, .dev = @intCast(di) };
        n += 1;
    }
    pairs = pairs[0..n];
    std.mem.sort(Pair, pairs, {}, Pair.lessThan);

    // Equal `StrId` means equal bytes: the interner dedups, so this is the byte
    // comparison without touching the pool.
    var dups: std.ArrayList(Finding) = .empty;
    defer dups.deinit(gpa);
    for (pairs, 0..) |p, i| {
        if (i == 0 or pairs[i - 1].name != p.name) continue;
        try dups.append(gpa, .{
            .rule = .duplicate_refdes,
            .severity = severity,
            .dev = .at(p.dev),
        });
    }
    // Name order is intern order, which is first-mention order and not device order.
    // Re-sort so the report walks devices ascending like every other rule.
    std.mem.sort(Finding, dups.items, {}, devLessThan);
    try out.appendSlice(gpa, dups.items);
}

fn devLessThan(_: void, a: Finding, b: Finding) bool {
    return @intFromEnum(a.dev) < @intFromEnum(b.dev);
}

/// Is this class's geometry unusable as drawn?
///
/// Two defects, both of which a host can introduce through `host.Table.register` or
/// `setAnchors` and neither of which the placer can repair:
///
/// - **Colliding terminals.** Two pins at one anchor point put two nets on one
///   coordinate, which a geometric-connectivity consumer reads as a short. This is
///   the fault the retired `layout.strict_geometry` bool turned into a hard error.
/// - **Arity disagreement.** The card supplied a different number of nodes than the
///   symbol has terminals, so some pin has no anchor and renders at the origin.
///
/// `// ponytail: O(terminals²) per device, re-run per instance — terminal counts are
/// single digits, so a per-class memo would cost more than it saves.`
fn badGeometry(class: catalog.DeviceClass, pins: u32) bool {
    if (pins != class.terminalCount()) return true;
    for (class.terminals, 0..) |a, i| {
        for (class.terminals[i + 1 ..]) |b| {
            if (a.at.eql(b.at)) return true;
        }
    }
    return false;
}

/// Resolve a device's class. `null` table means builtin-only; a host index then is a
/// producer bug, asserted rather than given a fallback symbol.
fn classOf(table: ?*const host.Table, s: ids.SymbolIdx) catalog.DeviceClass {
    if (table) |t| return t.at(s);
    std.debug.assert(s.i() < catalog.builtin_count);
    return catalog.at(s).*;
}

test "an off table runs nothing and allocates nothing" {
    const placed: Placed = .{ .ir = .empty, .physical = .empty, .strings = .empty };
    const found = try check(std.testing.failing_allocator, placed, null, .off);
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "the rule enum tracks the table's fields" {
    // The derivation is the point: a rule added to `Rules` is a `Rule` with no second
    // edit, and `severityOf` keeps compiling because it is an inline switch.
    try std.testing.expectEqual(
        @typeInfo(Rules).@"struct".fields.len,
        @typeInfo(Rule).@"enum".fields.len,
    );
    const r: Rules = .{ .floating_pin = .err };
    try std.testing.expectEqual(Severity.err, r.severityOf(.floating_pin));
    try std.testing.expectEqual(Severity.off, Rules.off.severityOf(.duplicate_refdes));
}
