//! Tunable knobs, read from `lint.zon`.
//!
//! ## What belongs here and what does not
//!
//! This holds **spacing and resource bounds** — quantities where a caller may
//! legitimately want a different number and still get the same *reasoning*. It does
//! not hold the router's cost weights. Those live as comptime constants in
//! `route/dijkstra.zig` because they encode what a schematic means; a caller who
//! retunes them gets a differently-reasoned drawing rather than a differently-spaced
//! one. See docs/ALGORITHM.md, "The costs are the opinions".
//!
//! ## Threaded, not global
//!
//! There is no process-wide singleton and no lazy initialization. A `*const Config`
//! is a field on the pipeline context and is passed down through placement and
//! rendering. That costs one parameter and buys: tests that vary knobs without
//! touching global state, and two schematics placed concurrently on two threads.
//!
//! ## Who allocates the diagnostics
//!
//! `parse` is handed an arena and no general-purpose allocator, so diagnostic entries
//! and their key strings can only come from that arena. The caller's
//! `ArrayList(Diagnostic)` is therefore *replaced* with an arena-backed view whose
//! `capacity` is 0, which makes the caller's `deinit(gpa)` a no-op rather than a
//! cross-allocator free — the alternative, appending into the caller's list, would
//! need a second allocator parameter the signature does not have. Entries already in
//! the list are copied forward, so repeated calls still accumulate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Zoir = std.zig.Zoir;

/// Spacing and search-budget knobs.
pub const Layout = struct {
    /// Minimum vertical gap between two abutting devices (`optimal_len == 0`).
    abut_gap: i32 = 8,
    /// Extra vertical room granted per fan-out tap on a node.
    tap_unit: i32 = 12,
    /// Width of one wire track. Channel width is a multiple of this.
    track_w: i32 = 8,
    /// Vertical pitch between margin tracks.
    track_h: i32 = 10,
    /// Distance from the device field to the first margin track.
    margin_gap: i32 = 16,
    /// Distance from the device field to a VDD/GND bus row.
    bus_gap: i32 = 24,
    /// Above this spline count, exhaustive order enumeration is abandoned for a
    /// greedy seed. A resource bound, not an opinion: `n!` growth is the known gap
    /// documented in ALGORITHM.md and this is the guard, not the fix.
    enum_limit: u32 = 10,
    /// How many Phase-A survivors get fully placed, routed and measured in Phase B.
    /// Quality saturates at 2 on the current fixture set; the default is headroom.
    refine: u32 = 16,
    /// Placement quantization. 1 means no quantization.
    grid: i32 = 1,
    /// When true, host-supplied symbol geometry violations are hard errors instead
    /// of measured faults.
    strict_geometry: bool = false,
};

/// Output styling. Consumed only by renderers; never reaches place-and-route.
pub const Render = struct {
    /// Stroke color for device symbols.
    stroke: []const u8 = "black",
    /// Wire color, bare hex without a leading `#`.
    wire: []const u8 = "1565c0",
    /// Symbol stroke width.
    sym_w: f32 = 1.2,
    /// Wire stroke width.
    wire_w: f32 = 1.5,
    /// Padding added around the content bounding box.
    pad: i32 = 24,
};

/// Process-design-kit resolution: how unrecognized subckt masters map to symbols.
pub const Pdk = struct {
    /// Glob patterns naming masters to treat as leaf primitives rather than
    /// flattening (for example `sky130_fd_pr__*`). Borrowed from the config's
    /// arena; not individually owned.
    leaf: []const []const u8 = &.{},
    /// Explicit master-name to builtin-class mappings, sorted by key so lookup is a
    /// binary search and iteration order is deterministic.
    alias: []const Alias = &.{},
    /// Scan unresolved leaf names for a recognizable builtin class token.
    scan: bool = true,
    /// Unresolved leaves become a generic box symbol. When false they are dropped
    /// and reported as skipped.
    unknown_as_box: bool = true,

    pub const Alias = struct {
        master: []const u8,
        class: []const u8,

        /// Order by master name. Keeps `alias` binary-searchable and its iteration
        /// reproducible.
        pub fn lessThan(_: void, a: Alias, b: Alias) bool {
            return std.mem.lessThan(u8, a.master, b.master);
        }
    };
};

/// The full knob set.
///
/// All string and slice fields are borrowed from the arena passed to `parse`. A
/// `Config` built by `default` borrows only static data and needs no arena at all.
pub const Config = struct {
    layout: Layout = .{},
    render: Render = .{},
    pdk: Pdk = .{},

    /// Every default, borrowing only static data. Valid for the life of the program
    /// and safe to share across threads.
    pub const default: Config = .{};

    /// Parse a `lint.zon` document.
    ///
    /// `arena` backs every string and slice in the result; the caller frees it in
    /// one call and the `Config` dies with it. Absent keys keep their defaults, and
    /// **unrecognized keys are reported, not fatal** — a config from a newer version
    /// of the tool still loads.
    ///
    /// `diags`, when non-null, receives one entry per unrecognized key or
    /// unparsable value. A malformed value leaves that key at its default.
    ///
    /// Errors: `OutOfMemory` only. Malformed input is reported through `diags` and
    /// never fails the parse, because failing to draw a schematic over a typo in a
    /// style file is the wrong trade.
    ///
    /// Post-condition: `pdk.alias` is sorted by master name.
    pub fn parse(
        arena: Allocator,
        text: []const u8,
        diags: ?*std.ArrayList(Diagnostic),
    ) Allocator.Error!Config {
        var cfg: Config = .default;
        var sink: Sink = .{ .arena = arena, .out = diags };
        defer sink.publish();

        const src = try arena.dupeZ(u8, text);
        const ast = try std.zig.Ast.parse(arena, src, .zon);
        if (ast.errors.len > 0) {
            try sink.add(lineOfToken(ast, ast.errors[0].token), "<document>", .bad_value);
            return cfg;
        }

        const zoir = try std.zig.ZonGen.generate(arena, ast, .{ .parse_str_lits = false });
        if (zoir.hasCompileErrors()) {
            const e = zoir.compile_errors[0];
            const line: u32 = if (e.token.unwrap()) |t|
                lineOfToken(ast, t)
            else
                lineOfNode(ast, zoir, @enumFromInt(e.node_or_offset));
            try sink.add(line, "<document>", .bad_value);
            return cfg;
        }

        const root = Zoir.Node.Index.root;
        const tables = switch (root.get(zoir)) {
            .empty_literal => return cfg,
            .struct_literal => |s| s,
            else => {
                try sink.add(lineOfNode(ast, zoir, root), "<document>", .bad_value);
                return cfg;
            },
        };

        for (tables.names, 0..) |name, i| {
            const key = name.get(zoir);
            const node = tables.vals.at(@intCast(i));
            if (std.mem.eql(u8, key, "layout")) {
                try patch(Layout, arena, ast, zoir, node, &cfg.layout, &sink);
            } else if (std.mem.eql(u8, key, "render")) {
                try patch(Render, arena, ast, zoir, node, &cfg.render, &sink);
            } else if (std.mem.eql(u8, key, "pdk")) {
                try patch(Pdk, arena, ast, zoir, node, &cfg.pdk, &sink);
                // Post-condition: binary-searchable and reproducible to iterate.
                std.mem.sort(Pdk.Alias, @constCast(cfg.pdk.alias), {}, Pdk.Alias.lessThan);
                try checkGlobs(cfg.pdk.leaf, lineOfField(ast, zoir, node, "leaf"), &sink);
            } else {
                try sink.add(lineOfNode(ast, zoir, node), key, .unknown_key);
            }
        }
        return cfg;
    }

    /// Load from `path`, falling back to `default` when the file does not exist.
    ///
    /// A missing config is the normal case and not an error, so this returns
    /// defaults rather than failing — a schematic should draw whether or not the
    /// user has written a style file. An unreadable or malformed file likewise
    /// yields defaults plus diagnostics.
    ///
    /// `io` performs the read. As of 0.16 I/O is an interface passed explicitly, the
    /// same way an allocator is; there is no ambient filesystem access, which is what
    /// lets a test drive this against an in-memory directory.
    ///
    /// `arena` backs every string in the result, exactly as in `parse`. The file
    /// contents themselves are read into a scratch buffer and released before
    /// returning — only the parsed values survive.
    pub fn load(
        arena: Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        diags: ?*std.ArrayList(Diagnostic),
    ) Allocator.Error!Config {
        // A byte budget rather than `.unlimited`: a style file is kilobytes, and an
        // accidental `lint.zon -> /dev/zero` should not eat the arena.
        const text = dir.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Absent is the normal state, not a complaint.
            error.FileNotFound => return .default,
            else => {
                var sink: Sink = .{ .arena = arena, .out = diags };
                defer sink.publish();
                try sink.add(1, "<file>", .bad_value);
                return .default;
            },
        };
        defer arena.free(text);
        return parse(arena, text, diags);
    }

    /// Resolve a subckt master name to a builtin class name via `pdk.alias`.
    ///
    /// Binary search; returns null when unmapped. Does not consult `scan` — that is
    /// the caller's next fallback.
    pub fn aliasOf(self: Config, master: []const u8) ?[]const u8 {
        const i = std.sort.binarySearch(Pdk.Alias, self.pdk.alias, master, orderAlias) orelse return null;
        return self.pdk.alias[i].class;
    }

    fn orderAlias(needle: []const u8, a: Pdk.Alias) std.math.Order {
        return std.mem.order(u8, needle, a.master);
    }

    /// True when `master` matches any `pdk.leaf` glob and must not be flattened.
    ///
    /// Patterns support a single trailing `*`; anything more elaborate is reported at
    /// parse time and treated as a literal.
    pub fn isLeaf(self: Config, master: []const u8) bool {
        for (self.pdk.leaf) |pat| {
            if (wellFormedGlob(pat) and pat.len > 0 and pat[pat.len - 1] == '*') {
                if (std.mem.startsWith(u8, master, pat[0 .. pat.len - 1])) return true;
            } else if (std.mem.eql(u8, master, pat)) return true;
        }
        return false;
    }
};

/// The supported pattern language in full: an optional single trailing `*`. A star
/// anywhere else makes the pattern literal, so a richer glob never matches
/// approximately — leaf lists decide what gets flattened.
fn wellFormedGlob(pat: []const u8) bool {
    if (pat.len == 0) return true;
    return std.mem.indexOfScalar(u8, pat[0 .. pat.len - 1], '*') == null;
}

fn checkGlobs(leaf: []const []const u8, line: u32, sink: *Sink) Allocator.Error!void {
    for (leaf) |pat| {
        if (!wellFormedGlob(pat)) try sink.add(line, pat, .bad_glob);
    }
}

/// Overwrite only the fields `node` actually names, leaving every sibling at its
/// incoming value. Each field is parsed on its own so one bad value costs one key
/// rather than the table; an unnamed field of `T` is reported and skipped.
fn patch(
    comptime T: type,
    arena: Allocator,
    ast: std.zig.Ast,
    zoir: Zoir,
    node: Zoir.Node.Index,
    out: *T,
    sink: *Sink,
) Allocator.Error!void {
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
                const v = std.zon.parse.fromZoirNodeAlloc(f.type, arena, ast, zoir, child, null, .{
                    // Arena-backed: no partial-value cleanup to bookkeep.
                    .free_on_error = false,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ParseZon => {
                        try sink.add(lineOfNode(ast, zoir, child), key, .bad_value);
                        continue :outer;
                    },
                };
                @field(out, f.name) = v;
                continue :outer;
            }
        }
        try sink.add(lineOfNode(ast, zoir, child), key, .unknown_key);
    }
}

/// Diagnostic accumulator.
///
/// `parse` is handed only an arena, so every entry is arena-backed; `publish` then
/// hands the caller's list a view of it with `capacity == 0`, which makes the
/// caller's `deinit(their_gpa)` a no-op instead of a cross-allocator free. See the
/// note in the file header.
const Sink = struct {
    arena: Allocator,
    out: ?*std.ArrayList(Diagnostic),
    list: std.ArrayList(Diagnostic) = .empty,

    fn add(self: *Sink, line: u32, key: []const u8, kind: Diagnostic.Kind) Allocator.Error!void {
        if (self.out == null) return; // Caller does not want the report.
        try self.list.append(self.arena, .{
            .line = line,
            .key = try self.arena.dupe(u8, key), // zoir's string bytes do not outlive us
            .kind = kind,
        });
    }

    fn publish(self: *Sink) void {
        const out = self.out orelse return;
        if (self.list.items.len == 0) return;
        var items = self.list.items;
        if (out.items.len > 0) {
            // Preserve entries from an earlier call into the same list.
            const joined = self.arena.alloc(Diagnostic, out.items.len + items.len) catch return;
            @memcpy(joined[0..out.items.len], out.items);
            @memcpy(joined[out.items.len ..], items);
            items = joined;
        }
        out.* = .{ .items = items, .capacity = 0 };
    }
};

fn lineOfToken(ast: std.zig.Ast, token: std.zig.Ast.TokenIndex) u32 {
    return @intCast(ast.tokenLocation(0, token).line + 1);
}

fn lineOfNode(ast: std.zig.Ast, zoir: Zoir, node: Zoir.Node.Index) u32 {
    return lineOfToken(ast, ast.nodeMainToken(node.getAstNode(zoir)));
}

fn lineOfField(ast: std.zig.Ast, zoir: Zoir, node: Zoir.Node.Index, field: []const u8) u32 {
    switch (node.get(zoir)) {
        .struct_literal => |s| for (s.names, 0..) |n, i| {
            if (std.mem.eql(u8, n.get(zoir), field)) return lineOfNode(ast, zoir, s.vals.at(@intCast(i)));
        },
        else => {},
    }
    return lineOfNode(ast, zoir, node);
}

/// A complaint about the config document.
///
/// `key` and `detail` are borrowed from the arena or from static data. Line numbers
/// are 1-based.
pub const Diagnostic = struct {
    line: u32,
    key: []const u8,
    kind: Kind,

    pub const Kind = enum {
        unknown_key,
        bad_value,
        bad_glob,
        duplicate_key,
    };
};
