//! Schematic review rules: what a team considers wrong with a drawing, and
//! how badly. The `.rules` table of `lint.zon`.
//!
//! Immediate mode, as in cktImg: `check` takes the data and a rule table (a
//! value — one severity per rule) and returns findings; there is nothing to
//! construct or keep in sync. It reads only `Placed` and the library, so a
//! host can lint a drawing it built itself.
//!
//! Findings come out in rule order, then device or net order: two runs over
//! one input give identical reports.

const std = @import("std");
const Allocator = std.mem.Allocator;
const library = @import("library.zig");
const placed_mod = @import("placed.zig");

const Placed = placed_mod.Placed;
const Library = library.Library;
const no_net = placed_mod.no_net;

pub const Severity = enum { off, warn, err };

pub const Rules = struct {
    /// A device pin on no net.
    floating_pin: Severity = .warn,
    /// A net with exactly one pin: it connects nothing (off by default: a
    /// top-level deck's inputs are one-pin nets).
    single_pin_net: Severity = .off,
    /// Two devices with one reference designator.
    duplicate_refdes: Severity = .err,
    /// A device drawn as a generated box because no class was registered for
    /// its kind.
    unmapped_master: Severity = .warn,
    /// No ground symbol anywhere in the drawing.
    no_ground: Severity = .warn,
    /// A symbol with terminals the card has no pins for.
    symbol_geometry: Severity = .warn,
    /// A net drawn with name labels where a wire gave way.
    label_fallback: Severity = .off,

    /// Every rule off: the base for "just this one".
    pub const off: Rules = blk: {
        var r: Rules = .{};
        for (@typeInfo(Rules).@"struct".fields) |f| @field(r, f.name) = .off;
        break :blk r;
    };

    pub fn severityOf(self: Rules, rule: Rule) Severity {
        switch (rule) {
            inline else => |tag| return @field(self, @tagName(tag)),
        }
    }
};

/// One rule, named; derived from `Rules` so the two cannot drift.
pub const Rule = std.meta.FieldEnum(Rules);

pub const Finding = struct {
    rule: Rule,
    severity: Severity,
    /// The device it is about, or null.
    dev: ?u32 = null,
    /// The net it is about, or null.
    net: ?u32 = null,

    pub fn text(self: Finding) []const u8 {
        return switch (self.rule) {
            .floating_pin => "device terminal is connected to no net",
            .single_pin_net => "net is touched by only one pin",
            .duplicate_refdes => "reference designator is not unique",
            .unmapped_master => "no symbol registered for this device kind; drawn as a box",
            .no_ground => "schematic has no ground symbol",
            .symbol_geometry => "symbol has terminals the card has no pins for",
            .label_fallback => "net is drawn with name labels where a wire gave way",
        };
    }
};

/// Runs every rule that is not `off`. Caller frees the result with `gpa`.
pub fn check(gpa: Allocator, p: *const Placed, lib: *const Library, rules: Rules) Allocator.Error![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(gpa);

    if (rules.floating_pin != .off) {
        for (0..p.deviceCount()) |d| {
            const lo, const hi = p.pinRange(d);
            for (lo..hi) |pin| if (p.pin_net[pin] == no_net) {
                try out.append(gpa, .{ .rule = .floating_pin, .severity = rules.floating_pin, .dev = @intCast(d) });
            };
        }
    }
    if (rules.single_pin_net != .off) {
        const tally = try gpa.alloc(u32, p.netCount());
        defer gpa.free(tally);
        @memset(tally, 0);
        for (p.dev_name, 0..) |name, d| {
            // The rails and ports the layout added repeat a net; they do not count.
            if (name.len == 0) continue;
            const lo, const hi = p.pinRange(d);
            for (p.pin_net[lo..hi]) |n| if (n != no_net) {
                tally[n] += 1;
            };
        }
        for (tally, 0..) |k, n| if (k == 1) {
            try out.append(gpa, .{ .rule = .single_pin_net, .severity = rules.single_pin_net, .net = @intCast(n) });
        };
    }
    if (rules.duplicate_refdes != .off) {
        for (p.dev_name, 0..) |name, d| {
            if (name.len == 0) continue;
            for (p.dev_name[0..d]) |earlier| if (std.mem.eql(u8, earlier, name)) {
                try out.append(gpa, .{ .rule = .duplicate_refdes, .severity = rules.duplicate_refdes, .dev = @intCast(d) });
                break;
            };
        }
    }
    if (rules.unmapped_master != .off) {
        for (p.dev_class, 0..) |c, d| if (lib.isGeneric(c)) {
            try out.append(gpa, .{ .rule = .unmapped_master, .severity = rules.unmapped_master, .dev = @intCast(d) });
        };
    }
    if (rules.no_ground != .off) {
        for (p.dev_class) |c| {
            if (lib.at(c).role == .ground_rail) break;
        } else try out.append(gpa, .{ .rule = .no_ground, .severity = rules.no_ground });
    }
    if (rules.symbol_geometry != .off) {
        for (p.dev_class, 0..) |c, d| {
            const lo, const hi = p.pinRange(d);
            if (hi - lo < lib.at(c).terminals.len) {
                try out.append(gpa, .{ .rule = .symbol_geometry, .severity = rules.symbol_geometry, .dev = @intCast(d) });
            }
        }
    }
    if (rules.label_fallback != .off) {
        var seen: std.ArrayList(u32) = .empty;
        defer seen.deinit(gpa);
        for (p.labels) |l| {
            if (std.mem.indexOfScalar(u32, seen.items, l.net) != null) continue;
            try seen.append(gpa, l.net);
        }
        std.mem.sort(u32, seen.items, {}, std.sort.asc(u32));
        for (seen.items) |n| try out.append(gpa, .{ .rule = .label_fallback, .severity = rules.label_fallback, .net = n });
    }
    return out.toOwnedSlice(gpa);
}

/// `lint <sev> <rule>: <device or net or schematic> (<text>)`, one line.
pub fn format(f: Finding, p: *const Placed, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("lint {s} {s}: ", .{ if (f.severity == .err) "err" else "warn", @tagName(f.rule) });
    if (f.dev) |d| {
        try w.print("device {s}", .{if (p.dev_name[d].len > 0) p.dev_name[d] else "(symbol)"});
    } else if (f.net) |n| {
        try w.print("net {s}", .{p.net_name[n]});
    } else try w.writeAll("schematic");
    try w.print(" ({s})\n", .{f.text()});
}

test "lint: an off table runs nothing and allocates nothing" {
    var lib = Library.init(std.testing.allocator);
    defer lib.deinit();
    const empty: Placed = .{
        .arena = .init(std.testing.allocator),
        .dev_name = &.{},
        .dev_class = &.{},
        .dev_value = &.{},
        .dev_pos = &.{},
        .dev_orient = &.{},
        .dev_pin0 = &.{0},
        .pin_net = &.{},
        .pin_xy = &.{},
        .net_name = &.{},
        .net_seg = &.{0},
        .seg_pt = &.{0},
        .wire_pts = &.{},
        .junctions = &.{},
        .labels = &.{},
        .no_connects = &.{},
    };
    const found = try check(std.testing.failing_allocator, &empty, &lib, .off);
    try std.testing.expectEqual(0, found.len);
}

test "lint: the rule enum tracks the table" {
    try std.testing.expectEqual(@typeInfo(Rules).@"struct".fields.len, @typeInfo(Rule).@"enum".fields.len);
    const r: Rules = .{ .floating_pin = .err };
    try std.testing.expectEqual(Severity.err, r.severityOf(.floating_pin));
    try std.testing.expectEqual(Severity.off, Rules.off.severityOf(.duplicate_refdes));
}
