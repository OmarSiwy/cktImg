//! The `lint.zon` settings file, three tables:
//!
//! - `.layout`: the wire lengths the layout keeps in each situation
//!   (ALGORITHM.md §5, Geometry);
//! - `.rules`: one severity per lint rule (`lint.zig`);
//! - `.render`: colours and line widths for the TikZ emitter.
//!
//! Lengths are in units, where one unit is a two-pin symbol from pin end to
//! pin end. Every key is optional; an absent key keeps its default, and an
//! unrecognized key or a malformed value is reported, never fatal — failing
//! to draw a schematic over a typo in a style file is the wrong trade.
//!
//! ```zon
//! .{ .layout = .{ .stack = 0.5, .terminal = 1.0 } }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Zoir = std.zig.Zoir;
const lint = @import("lint.zig");

/// Visible wire kept between two things, by situation, in units.
pub const Layout = struct {
    /// Smallest spacing between neighbouring rows or columns, centre to centre.
    min_pitch: f32 = 1.0,
    /// Two devices on one vertical wire: a transistor stack, a load over its driver.
    stack: f32 = 0.25,
    /// Two devices on one horizontal wire: resistors in series.
    series: f32 = 0.25,
    /// A device pin to a supply or ground symbol.
    rail: f32 = 0.5,
    /// A device pin to an input or output terminal.
    terminal: f32 = 0.5,
    /// A device pin to a net label.
    label: f32 = 0.5,
    /// A pin to a junction bar, and a junction bar to its terminal.
    junction: f32 = 0.5,
    /// A pin to the wire it taps, or to the corner where it turns.
    tap: f32 = 0.5,
    /// How far a bend (a wire around a device) leaves a pin before turning.
    bend: f32 = 0.25,
    /// Room kept between a wire and another net's symbol.
    clearance: f32 = 0.2,
};

/// How the TikZ emitter strokes a drawing.
pub const Render = struct {
    /// Wire colour: six hex digits, no `#`.
    wire: []const u8 = "1565c0",
    /// Symbol stroke width, in points.
    sym_w: f32 = 1.2,
    /// Wire stroke width, in points.
    wire_w: f32 = 1.5,
};

pub const Config = struct {
    layout: Layout = .{},
    rules: lint.Rules = .{},
    render: Render = .{},

    pub const default: Config = .{};

    /// Parse a `lint.zon` document. `arena` backs the diagnostics. Malformed
    /// input is reported through `diags` and leaves the affected key at its
    /// default.
    pub fn parse(arena: Allocator, text: []const u8, diags: ?*std.ArrayList(Diagnostic)) Allocator.Error!Config {
        var cfg: Config = .default;
        var sink: Sink = .{ .arena = arena, .out = diags };

        const src = try arena.dupeZ(u8, text);
        const ast = try std.zig.Ast.parse(arena, src, .zon);
        if (ast.errors.len > 0) {
            try sink.add(lineOfToken(ast, ast.errors[0].token), "<document>", .bad_value);
            return cfg;
        }
        const zoir = try std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = false });
        if (zoir.hasCompileErrors()) {
            try sink.add(1, "<document>", .bad_value);
            return cfg;
        }
        const tables = switch (Zoir.Node.Index.root.get(zoir)) {
            .empty_literal => return cfg,
            .struct_literal => |s| s,
            else => {
                try sink.add(1, "<document>", .bad_value);
                return cfg;
            },
        };
        for (tables.names, 0..) |name, i| {
            const key = name.get(zoir);
            const node = tables.vals.at(@intCast(i));
            if (std.mem.eql(u8, key, "layout")) {
                try patch(Layout, arena, ast, zoir, node, &cfg.layout, &sink);
            } else if (std.mem.eql(u8, key, "rules")) {
                try patch(lint.Rules, arena, ast, zoir, node, &cfg.rules, &sink);
            } else if (std.mem.eql(u8, key, "render")) {
                try patch(Render, arena, ast, zoir, node, &cfg.render, &sink);
            } else {
                try sink.add(lineOfNode(ast, zoir, node), key, .unknown_key);
            }
        }
        return cfg;
    }

    /// Load from `path` in `dir`; a missing file gives the defaults.
    pub fn load(arena: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, diags: ?*std.ArrayList(Diagnostic)) Allocator.Error!Config {
        const text = dir.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return .default,
            else => {
                var sink: Sink = .{ .arena = arena, .out = diags };
                try sink.add(1, "<file>", .bad_value);
                return .default;
            },
        };
        return parse(arena, text, diags);
    }
};

/// A complaint about the config document. Lines are 1-based.
pub const Diagnostic = struct {
    line: u32,
    key: []const u8,
    kind: Kind,

    pub const Kind = enum { unknown_key, bad_value };
};

/// Overwrites only the fields `node` names; each is parsed on its own, so one
/// bad value costs one key rather than the table.
fn patch(comptime T: type, arena: Allocator, ast: std.zig.Ast, zoir: Zoir, node: Zoir.Node.Index, out: *T, sink: *Sink) Allocator.Error!void {
    const lit = switch (node.get(zoir)) {
        .empty_literal => return,
        .struct_literal => |s| s,
        else => return sink.add(lineOfNode(ast, zoir, node), @typeName(T), .bad_value),
    };
    outer: for (lit.names, 0..) |name, i| {
        const key = name.get(zoir);
        const child = lit.vals.at(@intCast(i));
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (std.mem.eql(u8, key, f.name)) {
                const v = std.zon.parse.fromZoirNodeAlloc(f.type, arena, ast, zoir, child, null, .{ .free_on_error = false }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ParseZon => {
                        try sink.add(lineOfNode(ast, zoir, child), key, .bad_value);
                        continue :outer;
                    },
                };
                // A length must be a length.
                if (comptime f.type == f32) if (!(v >= 0)) {
                    try sink.add(lineOfNode(ast, zoir, child), key, .bad_value);
                    continue :outer;
                };
                if (comptime f.type == []const u8) if (!validHex(v)) {
                    try sink.add(lineOfNode(ast, zoir, child), key, .bad_value);
                    continue :outer;
                };
                @field(out, f.name) = v;
                continue :outer;
            }
        }
        try sink.add(lineOfNode(ast, zoir, child), key, .unknown_key);
    }
}

const Sink = struct {
    arena: Allocator,
    out: ?*std.ArrayList(Diagnostic),

    fn add(self: *Sink, line: u32, key: []const u8, kind: Diagnostic.Kind) Allocator.Error!void {
        const out = self.out orelse return;
        try out.append(self.arena, .{ .line = line, .key = try self.arena.dupe(u8, key), .kind = kind });
    }
};

fn lineOfToken(ast: std.zig.Ast, token: std.zig.Ast.TokenIndex) u32 {
    return @intCast(ast.tokenLocation(0, token).line + 1);
}

fn lineOfNode(ast: std.zig.Ast, zoir: Zoir, node: Zoir.Node.Index) u32 {
    return lineOfToken(ast, ast.nodeMainToken(node.getAstNode(zoir)));
}

/// Six hex digits: what TikZ's HTML colour model takes.
fn validHex(s: []const u8) bool {
    if (s.len != 6) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

test "config: rules and render tables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: std.ArrayList(Diagnostic) = .empty;
    const cfg = try Config.parse(arena.allocator(),
        \\.{ .rules = .{ .no_ground = .err, .nonsense = .warn }, .render = .{ .wire = "ff0000", .sym_w = 2 } }
    , &diags);
    try std.testing.expectEqual(lint.Severity.err, cfg.rules.no_ground);
    try std.testing.expectEqualStrings("ff0000", cfg.render.wire);
    try std.testing.expectEqual(2, cfg.render.sym_w);
    try std.testing.expectEqual(1, diags.items.len);
}

test "config: absent keys keep defaults, unknown keys and bad values are reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: std.ArrayList(Diagnostic) = .empty;
    const cfg = try Config.parse(a,
        \\.{
        \\    .layout = .{ .stack = 0.5, .wobble = 3, .tap = -1 },
        \\    .colours = .{},
        \\}
    , &diags);
    try std.testing.expectEqual(0.5, cfg.layout.stack);
    try std.testing.expectEqual((Layout{}).tap, cfg.layout.tap); // -1 rejected
    try std.testing.expectEqual((Layout{}).terminal, cfg.layout.terminal);
    try std.testing.expectEqual(3, diags.items.len);
    try std.testing.expectEqualStrings("wobble", diags.items[0].key);
    try std.testing.expectEqual(Diagnostic.Kind.unknown_key, diags.items[0].kind);
    try std.testing.expectEqualStrings("tap", diags.items[1].key);
    try std.testing.expectEqual(Diagnostic.Kind.bad_value, diags.items[1].kind);
    try std.testing.expectEqualStrings("colours", diags.items[2].key);
}

test "config: a malformed document gives the defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: std.ArrayList(Diagnostic) = .empty;
    const cfg = try Config.parse(arena.allocator(), ".{ .layout = ", &diags);
    try std.testing.expectEqual(Layout{}, cfg.layout);
    try std.testing.expectEqual(1, diags.items.len);
}
