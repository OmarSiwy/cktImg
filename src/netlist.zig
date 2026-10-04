//! ngspice netlist → bipartite hypergraph of devices + list of analyses.
//!
//! No tokenizer/parser split. A SPICE netlist is line-oriented and flat:
//! every card is one logical line, its kind is known from the first byte,
//! and the output is appended to arrays, never built into a tree. So:
//!
//!     bytes ─lowercase─▶ logical lines ─split─▶ fields ─switch(first byte)─▶ arrays
//!
//! Fields are slices into one lowercased copy of the source; nothing else is
//! copied. The file is walked three times, once per concern, because each
//! pass needs everything the previous one found:
//!
//!   1. `.model` names          (to count Q/M/D pins, which can vary)
//!   2. devices → nets, pins    (the hypergraph)
//!   3. analyses                (reference nets and devices by name)
//!
//! Re-scanning bytes is far cheaper than storing an intermediate token
//! stream that only exists to be read back.
//!
//! Supported cards: R C L K V I E G F H B D Q J Z M S W T O U X, and every
//! analysis in `analysis.zig`. Rejected with an error rather than silently
//! mis-parsed: A/N/P/Y devices, E/G/F/H `poly(n)`, `.include`/`.lib`, `.hb`.
//! `.control` blocks are skipped; other dot-commands (`.options`, `.ic`,
//! `.param`, ...) are ignored.
//!
//! ## Subcircuits
//!
//! A `.subckt` is a **block**: an `X` instance of it is one device of kind
//! `subckt`, its pins the instance's nets, and what is inside stays hidden.
//! Comment directives in the definition's body change that:
//!
//!     .subckt opamp inp inn out vdd vss
//!     *@ expand           draw its devices instead of a block
//!     *@ left inp inn     the block's shape: which ports sit on which side,
//!     *@ right out        in order (top to bottom, left to right)
//!     *@ top vdd
//!     *@ bottom vss
//!     ...
//!     .ends
//!
//! An expanded instance is flattened as ngspice names it: device `r1` of `x1`
//! becomes `r.x1.r1`, internal net `a` becomes `x1.a`, the ports map to the
//! instance's nets, and ground (`0`, `gnd`) stays global. Instances inside an
//! expanded body expand or stay blocks by their own definitions.
//!
//! An `X` whose master the deck never defines is not an error. A PDK
//! primitive is read as the device it names (`sky130_fd_pr__nfet_01v8` is a
//! MOS, `…res…`/`…cap…` a resistor or capacitor; see `pdkPrimitive`); any
//! other master is a block with ports `p1`..`pN`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const csr = @import("csr.zig");
const analysis = @import("analysis.zig");

pub const VertexId = csr.VertexId;
pub const EdgeId = csr.EdgeId;
pub const Analysis = analysis.Analysis;

/// Net "0" (alias "gnd") is always vertex 0, so a solver can drop it from
/// the matrix without a lookup.
pub const ground: VertexId = @enumFromInt(0);

pub const DeviceKind = enum(u8) {
    resistor, // R
    capacitor, // C
    inductor, // L
    coupling, // K  (mutual inductance; references two L's, no pins)
    vsource, // V
    isource, // I
    vcvs, // E
    vccs, // G
    cccs, // F  (references a controlling V source)
    ccvs, // H  (references a controlling V source)
    behavioral, // B
    diode, // D
    bjt, // Q
    jfet, // J
    mesfet, // Z
    mosfet, // M
    vswitch, // S
    cswitch, // W  (references a controlling V source)
    tline, // T
    ltra, // O
    urc, // U
    subckt, // X  (a block: `Netlist.defs[Device.def]`)
};

/// A `.subckt` definition.
pub const Subckt = struct {
    name: []const u8,
    ports: []const []const u8,
    /// Per port, the side a `*@ left/right/top/bottom` directive put it on.
    sides: []const ?PortSide,
    /// Per port, its place in the directives (ports on one side are drawn in
    /// that order); ports no directive names come after, in port order.
    order: []const u16,
    /// `*@ expand`: flatten instances instead of drawing a block.
    expand: bool,
    /// The body's text (lowercase), header and `.ends` excluded.
    body: []const u8,
};

pub const PortSide = enum { left, right, top, bottom };

/// `Device.def` of a device that is not a subcircuit block.
pub const no_def: u32 = std.math.maxInt(u32);

/// How deep expanded instances may nest (a self-instantiating subcircuit
/// would recurse forever).
pub const max_depth = 32;

/// A range into `Netlist.tokens`.
pub const Span = struct { start: u32, len: u32 };

pub const Net = struct {
    name: []const u8,
};

pub const Device = struct {
    kind: DeviceKind,
    name: []const u8,
    /// Every field after the pins: model name, value, `key = value` pairs,
    /// source functions. `(`, `)` and `=` are kept as their own tokens so
    /// device code can parse these later without re-reading the file.
    params: Span,
    /// The first param as a SPICE number (`1k`, `10uF`), or NaN.
    value: f64,
    /// For a `subckt` block, its definition in `Netlist.defs`.
    def: u32 = no_def,
};

pub const Circuit = csr.BipartiteHypergraph(Net, Device);

pub const Error = error{
    MissingField,
    UnexpectedToken,
    InvalidNumber,
    UnknownCard,
    UnsupportedDevice,
    PortCountMismatch,
    SubcircuitTooDeep,
    UnsupportedPoly,
    UnsupportedInclude,
    UnsupportedAnalysis,
    DuplicateDevice,
    UnknownNode,
    UnknownDevice,
    NotASource,
} || Circuit.Error;

/// Where parsing stopped. Fill-in only; never allocates, so it stays valid
/// after the error unwinds.
pub const Diagnostic = struct {
    /// Index into the `sources` (or `paths`) slice.
    source: u32 = 0,
    /// 1-based line where the offending card starts.
    line: u32 = 0,
    token_buf: [48]u8 = undefined,
    token_len: u8 = 0,

    /// First field of the offending card, in its original case.
    pub fn token(self: *const Diagnostic) []const u8 {
        return self.token_buf[0..self.token_len];
    }
};

// ===========================================================================
// Output
// ===========================================================================

pub const Netlist = struct {
    /// Owns the lowercased source text, token pool, name maps and analyses.
    arena: std.heap.ArenaAllocator,
    /// First line of the first source, original case.
    title: []const u8,
    /// Nets are vertices, devices are hyperedges; `members(e)` is the pin
    /// list in terminal order.
    graph: Circuit.Graph,
    /// In file order.
    analyses: []const Analysis,
    /// Pool that every `Device.params` span points into.
    tokens: []const []const u8,
    net_ids: std.StringHashMapUnmanaged(VertexId),
    device_ids: std.StringHashMapUnmanaged(EdgeId),
    /// `.model` name → type, lowercase.
    models: std.StringHashMapUnmanaged([]const u8),
    /// Every `.subckt` definition, in file order.
    defs: []const Subckt,

    /// The definition a `subckt` block device instantiates.
    pub fn defOf(self: *const Netlist, e: EdgeId) ?*const Subckt {
        const d = self.graph.edges.items(.def)[e.index()];
        return if (d == no_def) null else &self.defs[d];
    }

    pub fn deinit(self: *Netlist, gpa: Allocator) void {
        self.graph.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn params(self: *const Netlist, e: EdgeId) []const []const u8 {
        const s = self.graph.edges.items(.params)[e.index()];
        return self.tokens[s.start..][0..s.len];
    }

    /// The model type of a Q/M/J/Z/D device (`nmos`, `pmos`, `npn`, …): from
    /// its `.model` card, else the model name itself when it names a type
    /// (`M1 d g s b nmos`). Null for a device with no model.
    pub fn modelType(self: *const Netlist, e: EdgeId) ?[]const u8 {
        const k = self.graph.edges.items(.kind)[e.index()];
        switch (k) {
            .bjt, .mosfet, .jfet, .mesfet, .diode => {},
            else => return null,
        }
        for (self.params(e)) |tok| {
            if (self.models.get(tok)) |ty| return if (ty.len > 0) ty else tok;
        }
        const first = self.params(e);
        return if (first.len > 0) first[0] else null;
    }

    /// Names are stored lowercase (SPICE is case-insensitive).
    pub fn net(self: *const Netlist, lowercase_name: []const u8) ?VertexId {
        return self.net_ids.get(lowercase_name);
    }

    pub fn device(self: *const Netlist, lowercase_name: []const u8) ?EdgeId {
        return self.device_ids.get(lowercase_name);
    }
};

// ===========================================================================
// Entry points. `parse` does no I/O; `load` reads files and calls it.
// ===========================================================================

/// `sources[0]` is the main netlist; its first line is the title. Later
/// sources are read as if appended (no title line), e.g. model files.
/// The caller keeps ownership of `sources`; everything needed is copied.
pub fn parse(gpa: Allocator, sources: []const []const u8, diag: ?*Diagnostic) Error!Netlist {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    // One bulk transform up front: every later comparison is plain `eql`.
    const texts = try arena.alloc([]const u8, sources.len);
    for (sources, texts) |src, *dst| dst.* = std.ascii.lowerString(try arena.alloc(u8, src.len), src);

    var title: []const u8 = "";
    if (sources.len > 0) {
        const first = sources[0][0 .. std.mem.indexOfScalar(u8, sources[0], '\n') orelse sources[0].len];
        title = try arena.dupe(u8, std.mem.trimEnd(u8, first, "\r"));
    }

    var fields: std.ArrayList([]const u8) = .empty; // scratch, reused per card
    defer fields.deinit(gpa);

    var p: Pass = .{ .gpa = gpa, .arena = arena, .sources = sources, .texts = texts, .fields = &fields, .diag = diag };

    try p.collectModels();

    var graph = try p.buildGraph();
    errdefer graph.deinit(gpa);

    const analyses = try p.collectAnalyses(graph.edges.items(.kind));

    return .{
        .arena = arena_state,
        .title = title,
        .graph = graph,
        .analyses = analyses,
        .tokens = p.tokens.items,
        .net_ids = p.net_ids,
        .device_ids = p.device_ids,
        .models = p.models,
        .defs = p.defs.items,
    };
}

/// Reads `paths` relative to `dir` and parses them as `parse` would.
/// On a file error, `diag.source` names the file.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    paths: []const []const u8,
    diag: ?*Diagnostic,
) (Error || std.Io.Dir.ReadFileAllocError)!Netlist {
    const bufs = try gpa.alloc([]const u8, paths.len);
    defer gpa.free(bufs);
    var n: usize = 0;
    defer for (bufs[0..n]) |b| gpa.free(b);

    for (paths, 0..) |path, i| {
        bufs[i] = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| {
            if (diag) |d| d.* = .{ .source = @intCast(i) };
            return err;
        };
        n += 1;
    }
    return parse(gpa, bufs, diag);
}

// ===========================================================================
// Passes
// ===========================================================================

/// The device kind of an undefined `X` master that names a PDK primitive
/// (`sky130_fd_pr__nfet_01v8`, `cap_mim_m3_1`, `res_high_po`): one of its
/// `_`-separated words is `nfet`/`pfet`/`nmos`/`pmos` (four nodes), `res`
/// or `cap` (two or three: the third is the body). Null for anything else.
// ponytail: a fixed word list; make it a lint.zon key when a PDK spells its cells otherwise.
fn pdkPrimitive(master: []const u8, nodes: usize) ?DeviceKind {
    var it = std.mem.tokenizeScalar(u8, master, '_');
    while (it.next()) |w| {
        if (nodes == 4 and (eql(w, "nfet") or eql(w, "pfet") or eql(w, "nmos") or eql(w, "pmos"))) return .mosfet;
        if (nodes == 2 or nodes == 3) {
            if (eql(w, "res")) return .resistor;
            if (eql(w, "cap")) return .capacitor;
        }
    }
    return null;
}

const Pass = struct {
    gpa: Allocator,
    arena: Allocator,
    sources: []const []const u8, // original case, for diagnostics only
    texts: []const []const u8, // lowercased copies, same byte offsets
    fields: *std.ArrayList([]const u8),
    diag: ?*Diagnostic,

    /// `.model` name → its type (`nmos`, `pnp`, …; empty when not given).
    models: std.StringHashMapUnmanaged([]const u8) = .empty,
    defs: std.ArrayList(Subckt) = .empty,
    def_ids: std.StringHashMapUnmanaged(u32) = .empty,
    net_ids: std.StringHashMapUnmanaged(VertexId) = .empty,
    device_ids: std.StringHashMapUnmanaged(EdgeId) = .empty,
    tokens: std.ArrayList([]const u8) = .empty,

    /// Records where a card failed. Because `texts[i]` is a byte-for-byte
    /// lowercase copy of `sources[i]`, the same offset finds the original.
    fn fail(self: *Pass, err: Error, si: usize, cards: *const Cards, head: []const u8) Error {
        if (self.diag) |d| {
            d.* = .{ .source = @intCast(si), .line = cards.card_line };
            const off = @intFromPtr(head.ptr) - @intFromPtr(self.texts[si].ptr);
            const orig = self.sources[si][off..][0..head.len];
            d.token_len = @intCast(@min(orig.len, d.token_buf.len));
            @memcpy(d.token_buf[0..d.token_len], orig[0..d.token_len]);
        }
        return err;
    }

    // -- pass 1 ------------------------------------------------------------

    fn collectModels(self: *Pass) Error!void {
        for (self.texts, 0..) |text, si| try self.collectSubckts(text, si == 0);
        for (self.texts, 0..) |text, si| {
            var cards = Cards.init(text, si == 0);
            while (try cards.next(self.gpa, self.fields)) |f| {
                if (!isDot(f)) continue;
                const cmd = f[0];
                if (eql(cmd, ".include") or eql(cmd, ".inc") or eql(cmd, ".lib"))
                    return self.fail(error.UnsupportedInclude, si, &cards, cmd);
                if (eql(cmd, ".model")) {
                    if (f.len < 2) return self.fail(error.MissingField, si, &cards, cmd);
                    // `.model name type (params)`; the type may be glued to a `(`.
                    const ty = if (f.len >= 3) f[2] else "";
                    try self.models.put(self.arena, f[1], ty[0 .. std.mem.indexOfScalar(u8, ty, '(') orelse ty.len]);
                }
            }
        }
    }

    /// Every top-level `.subckt … .ends` block of `text`: header, body and
    /// `*@` directives. (A definition nested in another's body stays part of
    /// that body.)
    fn collectSubckts(self: *Pass, text: []const u8, has_title: bool) Error!void {
        var c = Cards.init(text, has_title);
        while (c.pos < text.len) {
            const start = c.pos;
            const raw = c.nextLine() orelse break;
            const line = Cards.content(raw) orelse continue;
            const head_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            if (!eql(line[0..head_end], ".subckt")) continue;
            _ = start;
            var header: std.ArrayList([]const u8) = .empty;
            try tokenize(self.arena, &header, line);
            while (c.continuation()) |more| try tokenize(self.arena, &header, more);
            const f = header.items;
            if (f.len < 2) return error.MissingField;
            // Ports run until the parameters (`params:` or `k=v`).
            var ports: std.ArrayList([]const u8) = .empty;
            for (f[2..], 2..) |t, i| {
                if (eql(t, "params:") or eql(t, "=") or (i + 1 < f.len and eql(f[i + 1], "="))) break;
                try ports.append(self.arena, t);
            }
            const sides = try self.arena.alloc(?PortSide, ports.items.len);
            @memset(sides, null);
            const order = try self.arena.alloc(u16, ports.items.len);
            for (order, 0..) |*o, k| o.* = @intCast(1000 + k);
            var def: Subckt = .{ .name = f[1], .ports = ports.items, .sides = sides, .order = order, .expand = false, .body = "" };
            var placed: u16 = 0;
            const body_start = c.pos;
            var body_end = text.len;
            var depth: usize = 1;
            while (c.pos < text.len) {
                const at = c.pos;
                const r = c.nextLine() orelse break;
                const t = std.mem.trimStart(u8, r, " \t");
                if (depth == 1 and std.mem.startsWith(u8, t, "*@")) {
                    try directive(&def, t[2..], &placed);
                    continue;
                }
                const l = Cards.content(r) orelse continue;
                const e = std.mem.indexOfAny(u8, l, " \t") orelse l.len;
                if (eql(l[0..e], ".subckt")) depth += 1;
                if (eql(l[0..e], ".ends")) {
                    depth -= 1;
                    if (depth == 0) {
                        body_end = at;
                        break;
                    }
                }
            }
            def.body = text[body_start..body_end];
            const gop = try self.def_ids.getOrPut(self.arena, def.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(self.defs.items.len);
                try self.defs.append(self.arena, def);
            }
        }
    }

    // -- pass 2 ------------------------------------------------------------

    fn buildGraph(self: *Pass) Error!Circuit.Graph {
        var b = try Circuit.Builder.init(self.gpa);
        errdefer b.deinit(self.gpa);

        // Ground first, so it is always vertex 0.
        _ = try b.addVertex(self.gpa, .{ .name = "0" });
        try self.net_ids.put(self.arena, "0", ground);
        try self.net_ids.put(self.arena, "gnd", ground);

        var pins: std.ArrayList(VertexId) = .empty; // scratch
        defer pins.deinit(self.gpa);

        for (self.texts, 0..) |text, si| {
            var cards = Cards.init(text, si == 0);
            while (try cards.next(self.gpa, self.fields)) |f| {
                if (isDot(f)) continue;
                self.addDevice(&b, &pins, f, null) catch |err| return self.fail(err, si, &cards, f[0]);
            }
        }
        return b.finish(self.gpa);
    }

    /// The instance an expanded body's cards are read in: its path and how
    /// its ports map to the caller's nets.
    const Frame = struct {
        /// `x1`, `x1.x2`, …
        path: []const u8,
        formals: []const []const u8,
        actuals: []const []const u8,
        depth: usize,

        fn net(fr: *const Frame, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
            if (eql(name, "0") or eql(name, "gnd")) return name;
            for (fr.formals, fr.actuals) |f, a| if (eql(f, name)) return a;
            return std.fmt.allocPrint(arena, "{s}.{s}", .{ fr.path, name });
        }
        fn device(fr: *const Frame, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
            return std.fmt.allocPrint(arena, "{c}.{s}.{s}", .{ name[0], fr.path, name });
        }
    };

    fn addDevice(self: *Pass, b: *Circuit.Builder, pins: *std.ArrayList(VertexId), f: []const []const u8, frame: ?*const Frame) Error!void {
        const letter = f[0][0];
        if (letter == 'x') return self.addInstance(b, pins, f, frame);
        const name = if (frame) |fr| try fr.device(self.arena, f[0]) else f[0];
        const rule = switch (letter) {
            'a'...'z' => card_rules[letter - 'a'],
            else => null,
        } orelse return switch (letter) {
            'a', 'n', 'p', 'y' => error.UnsupportedDevice,
            else => error.UnknownCard,
        };

        const pin_count = try self.pinCount(rule, f);
        if (f.len < 1 + pin_count) return error.MissingField;

        pins.clearRetainingCapacity();
        for (f[1..][0..pin_count]) |node_name| {
            if (isPunct(node_name)) return error.UnexpectedToken;
            const n = if (frame) |fr| try fr.net(self.arena, node_name) else node_name;
            try pins.append(self.gpa, try self.internNet(b, n));
        }

        const rest = f[1 + pin_count ..];
        const span: Span = .{ .start = @intCast(self.tokens.items.len), .len = @intCast(rest.len) };
        try self.tokens.appendSlice(self.arena, rest);

        const gop = try self.device_ids.getOrPut(self.arena, name);
        if (gop.found_existing) return error.DuplicateDevice;
        errdefer _ = self.device_ids.remove(name);

        gop.value_ptr.* = try b.addEdge(self.gpa, .{
            .kind = rule.kind,
            .name = name,
            .params = span,
            .value = if (rest.len > 0) parseValue(rest[0]) catch std.math.nan(f64) else std.math.nan(f64),
        }, pins.items);
    }

    /// `X<name> <nets…> <subckt> [params]`: a block device, or the body
    /// read again under a frame (`*@ expand`).
    fn addInstance(self: *Pass, b: *Circuit.Builder, pins: *std.ArrayList(VertexId), f: []const []const u8, frame: ?*const Frame) Error!void {
        // The subcircuit is the last word that is not a parameter.
        var at: usize = f.len;
        var i: usize = f.len;
        while (i > 1) {
            i -= 1;
            if (eql(f[i], "=") or eql(f[i], "params:")) continue;
            if (i + 1 < f.len and eql(f[i + 1], "=")) continue;
            if (i > 0 and eql(f[i - 1], "=")) continue;
            at = i;
            break;
        }
        if (at == f.len or at < 1) return error.MissingField;
        const actual = f[1..at];
        for (actual) |n| if (isPunct(n)) return error.UnexpectedToken;
        // A master with no definition: a PDK primitive by its name, else a
        // box with ports p1..pN, defined here so later instances share it.
        const prim = pdkPrimitive(f[at], actual.len);
        const def_id = self.def_ids.get(f[at]) orelse if (prim != null) no_def else try self.defineOpaque(f[at], actual.len);
        const kind: DeviceKind = if (def_id == no_def) prim.? else .subckt;
        if (kind == .subckt and actual.len != self.defs.items[def_id].ports.len) return error.PortCountMismatch;

        // The caller's nets, as the caller names them.
        const nets = try self.arena.alloc([]const u8, actual.len);
        for (actual, nets) |n, *o| o.* = if (frame) |fr| try fr.net(self.arena, n) else try self.arena.dupe(u8, n);
        const xname = if (frame) |fr| try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ fr.path, f[0] }) else try self.arena.dupe(u8, f[0]);

        if (kind == .subckt and self.defs.items[def_id].expand) {
            const def = self.defs.items[def_id];
            const depth = if (frame) |fr| fr.depth + 1 else 1;
            if (depth > max_depth) return error.SubcircuitTooDeep;
            const child: Frame = .{ .path = xname, .formals = def.ports, .actuals = nets, .depth = depth };
            // The body's cards need scratch of their own: the caller's is in use.
            var fields: std.ArrayList([]const u8) = .empty;
            defer fields.deinit(self.gpa);
            var cards = Cards.init(def.body, false);
            while (try cards.next(self.gpa, &fields)) |g| {
                if (isDot(g)) continue;
                try self.addDevice(b, pins, g, &child);
            }
            return;
        }

        pins.clearRetainingCapacity();
        for (nets) |n| try pins.append(self.gpa, try self.internNet(b, n));
        const rest = f[at..];
        const span: Span = .{ .start = @intCast(self.tokens.items.len), .len = @intCast(rest.len) };
        for (rest) |t| try self.tokens.append(self.arena, try self.arena.dupe(u8, t));
        const name = if (frame) |fr| try fr.device(self.arena, f[0]) else f[0];
        const gop = try self.device_ids.getOrPut(self.arena, name);
        if (gop.found_existing) return error.DuplicateDevice;
        errdefer _ = self.device_ids.remove(name);
        gop.value_ptr.* = try b.addEdge(self.gpa, .{
            .kind = kind,
            .name = name,
            .params = span,
            .value = std.math.nan(f64),
            .def = def_id,
        }, pins.items);
    }

    /// A definition for a master the deck never defines (a cell from a
    /// library it does not include): ports `p1`..`pN`, no directives.
    fn defineOpaque(self: *Pass, master: []const u8, n: usize) Error!u32 {
        const ports = try self.arena.alloc([]const u8, n);
        for (ports, 1..) |*p, k| p.* = try std.fmt.allocPrint(self.arena, "p{d}", .{k});
        const sides = try self.arena.alloc(?PortSide, n);
        @memset(sides, null);
        const order = try self.arena.alloc(u16, n);
        for (order, 0..) |*o, k| o.* = @intCast(1000 + k);
        const id: u32 = @intCast(self.defs.items.len);
        try self.defs.append(self.arena, .{ .name = try self.arena.dupe(u8, master), .ports = ports, .sides = sides, .order = order, .expand = false, .body = "" });
        try self.def_ids.put(self.arena, self.defs.items[id].name, id);
        return id;
    }

    fn pinCount(self: *Pass, rule: CardRule, f: []const []const u8) Error!u8 {
        switch (rule.pins) {
            .fixed => |n| return n,
            // Q/M/D: extra optional terminals (substrate, thermal, SOI body)
            // sit before the model name. Only count past the minimum when a
            // known `.model` name proves where the terminals end; otherwise
            // `m1 d g s b nch w=1u` with `nch` in a library would grow a pin.
            .until_model => |r| {
                var p: usize = r.min;
                while (p <= r.max and 1 + p < f.len) : (p += 1) {
                    if (self.models.contains(f[1 + p])) return @intCast(p);
                }
                return r.min;
            },
            // E/G: `e1 out 0 in 0 gain` has 4 pins; `e1 out 0 value={...}`
            // (and vol/cur/table/laplace) has 2.
            .controlled => {
                if (f.len < 4) return 2;
                const k = f[3];
                if (eql(k, "poly")) return error.UnsupportedPoly;
                for (behavioral_keywords) |kw| if (eql(k, kw)) return 2;
                return 4;
            },
        }
    }

    fn internNet(self: *Pass, b: *Circuit.Builder, name: []const u8) Error!VertexId {
        const gop = try self.net_ids.getOrPut(self.arena, name);
        if (!gop.found_existing) {
            errdefer _ = self.net_ids.remove(name);
            gop.value_ptr.* = try b.addVertex(self.gpa, .{ .name = name });
        }
        return gop.value_ptr.*;
    }

    // -- pass 3 ------------------------------------------------------------

    fn collectAnalyses(self: *Pass, kinds: []const DeviceKind) Error![]const Analysis {
        var list: std.ArrayList(Analysis) = .empty;
        const resolve: Resolver = .{ .nets = &self.net_ids, .devices = &self.device_ids, .kinds = kinds };

        for (self.texts, 0..) |text, si| {
            var cards = Cards.init(text, si == 0);
            while (try cards.next(self.gpa, self.fields)) |f| {
                if (!isDot(f)) continue;
                const cmd = std.meta.stringToEnum(Directive, f[0][1..]) orelse continue;
                const a = parseAnalysis(cmd, f, resolve, self.arena) catch |err|
                    return self.fail(err, si, &cards, f[0]);
                try list.append(self.arena, a);
            }
        }
        return list.items;
    }
};

// ===========================================================================
// Device card rules: first letter → kind and how many pins follow the name.
// A comptime table instead of a switch keeps all the device facts in one
// place you can read top to bottom.
// ===========================================================================

const CardRule = struct {
    kind: DeviceKind,
    pins: union(enum) {
        fixed: u8,
        until_model: struct { min: u8, max: u8 },
        controlled,
    },
};

const behavioral_keywords = [_][]const u8{ "value", "vol", "cur", "table", "laplace" };

const card_rules: [26]?CardRule = blk: {
    var t: [26]?CardRule = @splat(null);
    const R = struct {
        fn set(tab: *[26]?CardRule, c: u8, k: DeviceKind, pins: @FieldType(CardRule, "pins")) void {
            tab[c - 'a'] = .{ .kind = k, .pins = pins };
        }
    };
    R.set(&t, 'r', .resistor, .{ .fixed = 2 });
    R.set(&t, 'c', .capacitor, .{ .fixed = 2 });
    R.set(&t, 'l', .inductor, .{ .fixed = 2 });
    R.set(&t, 'k', .coupling, .{ .fixed = 0 });
    R.set(&t, 'v', .vsource, .{ .fixed = 2 });
    R.set(&t, 'i', .isource, .{ .fixed = 2 });
    R.set(&t, 'e', .vcvs, .controlled);
    R.set(&t, 'g', .vccs, .controlled);
    R.set(&t, 'f', .cccs, .{ .fixed = 2 });
    R.set(&t, 'h', .ccvs, .{ .fixed = 2 });
    R.set(&t, 'b', .behavioral, .{ .fixed = 2 });
    R.set(&t, 'd', .diode, .{ .until_model = .{ .min = 2, .max = 3 } });
    R.set(&t, 'q', .bjt, .{ .until_model = .{ .min = 3, .max = 5 } });
    R.set(&t, 'j', .jfet, .{ .fixed = 3 });
    R.set(&t, 'z', .mesfet, .{ .fixed = 3 });
    R.set(&t, 'm', .mosfet, .{ .until_model = .{ .min = 4, .max = 7 } });
    R.set(&t, 's', .vswitch, .{ .fixed = 4 });
    R.set(&t, 'w', .cswitch, .{ .fixed = 2 });
    R.set(&t, 't', .tline, .{ .fixed = 4 });
    R.set(&t, 'o', .ltra, .{ .fixed = 4 });
    R.set(&t, 'u', .urc, .{ .fixed = 3 });
    break :blk t;
};

// ===========================================================================
// Analyses
// ===========================================================================

const Directive = enum { op, dc, ac, disto, noise, pz, sens, tf, tran, pss, sp, hb };

const Resolver = struct {
    nets: *const std.StringHashMapUnmanaged(VertexId),
    devices: *const std.StringHashMapUnmanaged(EdgeId),
    kinds: []const DeviceKind,

    fn node(r: Resolver, name: []const u8) Error!VertexId {
        return r.nets.get(name) orelse error.UnknownNode;
    }

    fn deviceOf(r: Resolver, name: []const u8, allowed: []const DeviceKind) Error!EdgeId {
        const e = r.devices.get(name) orelse return error.UnknownDevice;
        if (std.mem.indexOfScalar(DeviceKind, allowed, r.kinds[e.index()]) == null) return error.NotASource;
        return e;
    }
};

const independent_sources = [_]DeviceKind{ .vsource, .isource };

/// Cursor over one card's fields (field 0 is the command).
const Cursor = struct {
    f: []const []const u8,
    i: usize = 1,

    fn peek(c: *const Cursor) ?[]const u8 {
        return if (c.i < c.f.len) c.f[c.i] else null;
    }
    fn word(c: *Cursor) Error![]const u8 {
        const w = c.peek() orelse return error.MissingField;
        c.i += 1;
        return w;
    }
    fn expect(c: *Cursor, lit: []const u8) Error!void {
        if (!eql(try c.word(), lit)) return error.UnexpectedToken;
    }
    fn number(c: *Cursor) Error!f64 {
        return parseValue(try c.word());
    }
    fn count(c: *Cursor) Error!u32 {
        const x = try c.number();
        if (!(x >= 0 and x <= std.math.maxInt(u32)) or x != @floor(x)) return error.InvalidNumber;
        return @intFromFloat(x);
    }
    fn peekIsNumber(c: *const Cursor) bool {
        const w = c.peek() orelse return false;
        _ = parseValue(w) catch return false;
        return true;
    }
    fn keyword(c: *Cursor, comptime E: type) Error!E {
        return std.meta.stringToEnum(E, try c.word()) orelse error.UnexpectedToken;
    }
    fn done(c: *const Cursor) Error!void {
        if (c.i != c.f.len) return error.UnexpectedToken;
    }
};

fn parseAnalysis(cmd: Directive, f: []const []const u8, r: Resolver, arena: Allocator) Error!Analysis {
    var c: Cursor = .{ .f = f };
    const a: Analysis = switch (cmd) {
        .hb => return error.UnsupportedAnalysis,

        .op => .op,

        .dc => .{ .dc = .{
            .sweep = try dcSweep(&c, r),
            .outer = if (c.peek() != null) try dcSweep(&c, r) else null,
        } },

        .ac => .{ .ac = try freqSweep(&c) },

        .disto => .{ .disto = .{
            .sweep = try freqSweep(&c),
            .f2_over_f1 = if (c.peek() != null) try c.number() else null,
        } },

        .noise => .{ .noise = .{
            .output = try voltageProbe(&c, r),
            .input = try r.deviceOf(try c.word(), &independent_sources),
            .sweep = try freqSweep(&c),
            .points_per_summary = if (c.peek() != null) try c.count() else 0,
        } },

        .pz => .{ .pz = .{
            .input_pos = try r.node(try c.word()),
            .input_neg = try r.node(try c.word()),
            .output_pos = try r.node(try c.word()),
            .output_neg = try r.node(try c.word()),
            .transfer = try c.keyword(analysis.Pz.Transfer),
            .solve = switch (try c.keyword(enum { pol, zer, pz })) {
                .pol => .poles,
                .zer => .zeros,
                .pz => .both,
            },
        } },

        .sens => blk: {
            const output = try outputVar(&c, r);
            const first_filter = c.i;
            while (c.peek()) |w| : (c.i += 1) if (eql(w, "ac") or eql(w, "dc")) break;
            const filters = try arena.dupe([]const u8, f[first_filter..c.i]);
            const mode: analysis.Sens.Mode = if (c.peek() == null) .dc else switch (try c.keyword(enum { ac, dc })) {
                .ac => .{ .ac = try freqSweep(&c) },
                .dc => .dc,
            };
            break :blk .{ .sens = .{ .output = output, .filters = filters, .mode = mode } };
        },

        .tf => .{ .tf = .{
            .output = try outputVar(&c, r),
            .input = try r.deviceOf(try c.word(), &independent_sources),
        } },

        .tran => blk: {
            const tstep = try c.number();
            const tstop = try c.number();
            const tstart = if (c.peekIsNumber()) try c.number() else 0;
            const tmax: ?f64 = if (c.peekIsNumber()) try c.number() else null;
            break :blk .{ .tran = .{
                .tstep = tstep,
                .tstop = tstop,
                .tstart = tstart,
                .tmax = tmax,
                .uic = try optionalUic(&c),
            } };
        },

        .pss => .{ .pss = .{
            .fguess = try c.number(),
            .tstab = try c.number(),
            .osc_node = try r.node(try c.word()),
            .points = try c.count(),
            .harmonics = try c.count(),
            .sc_iter = try c.count(),
            .steady_coeff = try c.number(),
            .uic = try optionalUic(&c),
        } },

        .sp => .{ .sp = .{
            .sweep = try freqSweep(&c),
            .noise = if (c.peek() != null) (try c.count()) != 0 else false,
        } },
    };
    try c.done();
    return a;
}

fn freqSweep(c: *Cursor) Error!analysis.FreqSweep {
    const scale = try c.keyword(analysis.SweepScale);
    const points = try c.count();
    if (points == 0) return error.InvalidNumber;
    return .{ .scale = scale, .points = points, .fstart = try c.number(), .fstop = try c.number() };
}

fn dcSweep(c: *Cursor, r: Resolver) Error!analysis.DcSweep {
    const name = try c.word();
    const target: analysis.DcTarget = if (eql(name, "temp"))
        .temperature
    else
        .{ .device = try r.deviceOf(name, &.{ .vsource, .isource, .resistor }) };
    const start = try c.number();
    const stop = try c.number();
    const step = try c.number();
    if (step == 0) return error.InvalidNumber;
    return .{ .target = target, .start = start, .stop = stop, .step = step };
}

/// `v ( pos [neg] )` — commas are already gone, parens are tokens.
fn voltageProbe(c: *Cursor, r: Resolver) Error!analysis.VoltageProbe {
    try c.expect("v");
    return voltageBody(c, r);
}

fn voltageBody(c: *Cursor, r: Resolver) Error!analysis.VoltageProbe {
    try c.expect("(");
    const pos = try r.node(try c.word());
    const next = try c.word();
    if (eql(next, ")")) return .{ .pos = pos, .neg = ground };
    const neg = try r.node(next);
    try c.expect(")");
    return .{ .pos = pos, .neg = neg };
}

/// `v(pos[,neg])` or `i(vsrc)`.
fn outputVar(c: *Cursor, r: Resolver) Error!analysis.Output {
    switch (try c.keyword(enum { v, i })) {
        .v => return .{ .voltage = try voltageBody(c, r) },
        .i => {
            try c.expect("(");
            const src = try r.deviceOf(try c.word(), &.{.vsource});
            try c.expect(")");
            return .{ .current = src };
        },
    }
}

fn optionalUic(c: *Cursor) Error!bool {
    if (c.peek() == null) return false;
    try c.expect("uic");
    return true;
}

/// One `*@` directive line of a definition's body.
fn directive(def: *Subckt, text: []const u8, placed: *u16) Error!void {
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    const verb = it.next() orelse return;
    if (eql(verb, "expand")) {
        def.expand = true;
        return;
    }
    const side: PortSide = if (eql(verb, "left")) .left else if (eql(verb, "right")) .right else if (eql(verb, "top")) .top else if (eql(verb, "bottom")) .bottom else return;
    while (it.next()) |port| {
        for (def.ports, 0..) |p, k| if (eql(p, port)) {
            @constCast(def.sides)[k] = side;
            @constCast(def.order)[k] = placed.*;
            placed.* += 1;
        };
    }
}

// ===========================================================================
// Scanning: physical lines → logical cards → fields
// ===========================================================================

const Cards = struct {
    text: []const u8,
    pos: usize = 0,
    line: u32 = 0, // physical lines consumed so far
    card_line: u32 = 0, // 1-based line of the card last returned

    fn init(text: []const u8, has_title: bool) Cards {
        var c: Cards = .{ .text = text };
        if (has_title) _ = c.nextLine();
        return c;
    }

    fn nextLine(c: *Cards) ?[]const u8 {
        if (c.pos >= c.text.len) return null;
        const end = std.mem.indexOfScalarPos(u8, c.text, c.pos, '\n') orelse c.text.len;
        const line = std.mem.trimEnd(u8, c.text[c.pos..end], "\r");
        c.pos = end + 1;
        c.line += 1;
        return line;
    }

    /// Comment-stripped, left-trimmed content, or null for blank/comment lines.
    fn content(raw: []const u8) ?[]const u8 {
        const line = std.mem.trimStart(u8, stripComment(raw), " \t");
        if (line.len == 0 or line[0] == '*') return null;
        return line;
    }

    /// Next logical card's fields, or null at end of text or `.end`.
    /// `.control ... .endc` and `.subckt ... .ends` are skipped whole.
    fn next(c: *Cards, gpa: Allocator, fields: *std.ArrayList([]const u8)) Allocator.Error!?[]const []const u8 {
        while (c.nextLine()) |raw| {
            const line = content(raw) orelse continue;
            if (line[0] == '+') continue; // stray continuation: nothing to continue
            c.card_line = c.line;

            fields.clearRetainingCapacity();
            try tokenize(gpa, fields, line);
            while (c.continuation()) |more| try tokenize(gpa, fields, more);

            const f = fields.items;
            if (f.len == 0) continue;
            if (eql(f[0], ".end")) return null;
            if (eql(f[0], ".control")) {
                c.skipBlock(".control", ".endc");
                continue;
            }
            if (eql(f[0], ".subckt")) {
                c.skipBlock(".subckt", ".ends");
                continue;
            }
            return f;
        }
        return null;
    }

    /// If the next non-comment line starts with '+', consume it.
    fn continuation(c: *Cards) ?[]const u8 {
        const save_pos = c.pos;
        const save_line = c.line;
        while (c.nextLine()) |raw| {
            const line = content(raw) orelse continue;
            if (line[0] == '+') return line[1..];
            break;
        }
        c.pos = save_pos;
        c.line = save_line;
        return null;
    }

    fn skipBlock(c: *Cards, open: []const u8, close: []const u8) void {
        var depth: usize = 1;
        while (c.nextLine()) |raw| {
            const line = content(raw) orelse continue;
            const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            const head = line[0..end];
            if (eql(head, open)) depth += 1;
            if (eql(head, close)) {
                depth -= 1;
                if (depth == 0) return;
            }
        }
    }
};

/// `;`, `//`, and ` $` start end-of-line comments in ngspice.
fn stripComment(line: []const u8) []const u8 {
    for (line, 0..) |ch, i| switch (ch) {
        ';' => return line[0..i],
        '/' => if (i + 1 < line.len and line[i + 1] == '/') return line[0..i],
        '$' => if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') return line[0..i],
        else => {},
    };
    return line;
}

/// Whitespace and commas separate fields. `(`, `)`, `=` are single-char
/// fields. `{...}` and quoted strings are kept whole (they hold expressions
/// with spaces).
fn tokenize(gpa: Allocator, out: *std.ArrayList([]const u8), line: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        switch (ch) {
            ' ', '\t', ',', '\r' => i += 1,
            '(', ')', '=' => {
                try out.append(gpa, line[i .. i + 1]);
                i += 1;
            },
            '{' => {
                var depth: usize = 0;
                var j = i;
                while (j < line.len) : (j += 1) {
                    if (line[j] == '{') depth += 1;
                    if (line[j] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                const end = @min(j + 1, line.len);
                try out.append(gpa, line[i..end]);
                i = end;
            },
            '\'', '"' => {
                const close = std.mem.indexOfScalarPos(u8, line, i + 1, ch) orelse line.len - 1;
                try out.append(gpa, line[i .. close + 1]);
                i = close + 1;
            },
            else => {
                var j = i;
                while (j < line.len and !isDelimiter(line[j])) j += 1;
                try out.append(gpa, line[i..j]);
                i = j;
            },
        }
    }
}

fn isDelimiter(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', ',', '\r', '(', ')', '=', '{', '\'', '"' => true,
        else => false,
    };
}

fn isPunct(tok: []const u8) bool {
    return tok.len == 1 and (tok[0] == '(' or tok[0] == ')' or tok[0] == '=');
}

fn isDot(f: []const []const u8) bool {
    return f[0][0] == '.';
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ===========================================================================
// SPICE numbers
// ===========================================================================

/// `1k`, `4.7u`, `10meg`, `2.5e-3`, `100nF`, `3mil`. After the number, an
/// optional scale factor (t g meg k mil m u n p f, case-insensitive), then
/// any letters are ignored as units, like ngspice does.
pub fn parseValue(tok: []const u8) error{InvalidNumber}!f64 {
    var i: usize = 0;
    if (i < tok.len and (tok[i] == '+' or tok[i] == '-')) i += 1;
    var digits: usize = 0;
    while (i < tok.len and std.ascii.isDigit(tok[i])) : (i += 1) digits += 1;
    if (i < tok.len and tok[i] == '.') {
        i += 1;
        while (i < tok.len and std.ascii.isDigit(tok[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return error.InvalidNumber;

    // Exponent only if digits follow; otherwise 'e' is a unit letter.
    if (i < tok.len and (tok[i] == 'e' or tok[i] == 'E')) {
        var j = i + 1;
        if (j < tok.len and (tok[j] == '+' or tok[j] == '-')) j += 1;
        if (j < tok.len and std.ascii.isDigit(tok[j])) {
            while (j < tok.len and std.ascii.isDigit(tok[j])) j += 1;
            i = j;
        }
    }

    const mantissa = std.fmt.parseFloat(f64, tok[0..i]) catch return error.InvalidNumber;
    return mantissa * scaleFactor(tok[i..]);
}

fn scaleFactor(suffix: []const u8) f64 {
    if (std.ascii.startsWithIgnoreCase(suffix, "meg")) return 1e6;
    if (std.ascii.startsWithIgnoreCase(suffix, "mil")) return 25.4e-6;
    if (suffix.len == 0) return 1;
    return switch (std.ascii.toLower(suffix[0])) {
        't' => 1e12,
        'g' => 1e9,
        'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        else => 1,
    };
}

// ===========================================================================
// Tests  (zig test netlist.zig)
// ===========================================================================

const testing = std.testing;

const inverter =
    \\CMOS Inverter Testbench
    \\* models
    \\.model NCH nmos level=1
    \\.model PCH pmos level=1
    \\.model QN npn
    \\
    \\Vdd vdd 0 DC 1.8
    \\Vin in 0 dc 0 ac 1 sin(0.9 0.9 1Meg)
    \\M1 out in 0 0 nch W=1u L=180n
    \\M2 out in vdd vdd pch w=2u
    \\* a comment between a card and its continuation
    \\+ l=180n
    \\R1 out load 1k ; end-of-line comment
    \\C1 load GND 10fF
    \\Q1 c in 0 qn
    \\Q2 c in 0 sub qn
    \\Rc c vdd 10k
    \\Rs sub 0 1meg
    \\E1 amp 0 out load 10
    \\B1 bout 0 v={v(out)*2}
    \\
    \\.subckt skipped a b
    \\R99 a b 1
    \\.ends
    \\
    \\.control
    \\tran 1n 10u
    \\.endc
    \\
    \\.options reltol=1e-4
    \\.op
    \\.dc vin 0 1.8 10m temp -40 125 5
    \\.ac dec 10 1 1g
    \\.tran 10p 10n 0 5p uic
    \\.noise v(load) vin dec 10 1k 1g 5
    \\.tf v(out, load) vin
    \\.sens v(out) r1 c1 ac lin 5 1k 10k
    \\.sens i(vdd)
    \\.pz in 0 out 0 vol pz
    \\.disto oct 4 1k 1meg 0.9
    \\.pss 1meg 5u out 1024 10 50 1e-3
    \\.sp lin 10 1meg 1g 1
    \\.end
    \\R1000 never parsed 1
;

fn names(nl: *const Netlist, ids: []const VertexId, buf: [][]const u8) []const []const u8 {
    const all = nl.graph.vertices.items(.name);
    for (ids, 0..) |id, k| buf[k] = all[id.index()];
    return buf[0..ids.len];
}

test "devices: pins in terminal order, nets interned, ground is vertex 0" {
    const gpa = testing.allocator;
    var nl = try parse(gpa, &.{inverter}, null);
    defer nl.deinit(gpa);

    try testing.expectEqualStrings("CMOS Inverter Testbench", nl.title);
    try testing.expectEqual(@as(u32, 12), nl.graph.edgeCount()); // R99, R1000 excluded
    try testing.expectEqual(ground, nl.net("gnd").?);

    var buf: [8][]const u8 = undefined;
    const m2 = nl.device("m2").?;
    // Continuation line joined; bulk tied to source kept as a repeated pin.
    try testing.expectEqualDeep(&[_][]const u8{ "out", "in", "vdd", "vdd" }, names(&nl, nl.graph.members(m2), &buf));
    try testing.expectEqualDeep(&[_][]const u8{ "pch", "w", "=", "2u", "l", "=", "180n" }, nl.params(m2));

    // Q pin count decided by where the known model name sits.
    try testing.expectEqual(@as(u32, 3), nl.graph.edgeSize(nl.device("q1").?));
    try testing.expectEqual(@as(u32, 4), nl.graph.edgeSize(nl.device("q2").?));

    // E: linear form has 4 pins; B: 2 pins, expression kept whole.
    try testing.expectEqual(@as(u32, 4), nl.graph.edgeSize(nl.device("e1").?));
    try testing.expectEqualDeep(&[_][]const u8{ "v", "=", "{v(out)*2}" }, nl.params(nl.device("b1").?));

    // Values and SoA access: only the `value` column is touched here.
    const values = nl.graph.edges.items(.value);
    try testing.expectApproxEqRel(1e3, values[nl.device("r1").?.index()], 1e-12);
    try testing.expectApproxEqRel(10e-15, values[nl.device("c1").?.index()], 1e-12);
    try testing.expect(std.math.isNan(values[nl.device("vdd").?.index()])); // "dc"

    // C1 goes to ground via the gnd alias.
    try testing.expectEqual(ground, nl.graph.members(nl.device("c1").?)[1]);
    try testing.expect(nl.device("r99") == null);
}

test "analyses: every kind, resolved to ids" {
    const gpa = testing.allocator;
    var nl = try parse(gpa, &.{inverter}, null);
    defer nl.deinit(gpa);

    const a = nl.analyses;
    try testing.expectEqual(@as(usize, 12), a.len);
    const Kind = analysis.Kind;
    const expected = [_]Kind{ .op, .dc, .ac, .tran, .noise, .tf, .sens, .sens, .pz, .disto, .pss, .sp };
    for (expected, a) |k, got| try testing.expectEqual(k, std.meta.activeTag(got));

    const vin = nl.device("vin").?;
    const dc = a[1].dc;
    try testing.expectEqual(vin, dc.sweep.target.device);
    try testing.expectApproxEqRel(10e-3, dc.sweep.step, 1e-12);
    try testing.expectEqual(analysis.DcTarget.temperature, dc.outer.?.target);

    try testing.expectEqual(analysis.SweepScale.dec, a[2].ac.scale);
    try testing.expectApproxEqRel(1e9, a[2].ac.fstop, 1e-12);

    const tran = a[3].tran;
    try testing.expect(tran.uic);
    try testing.expectApproxEqRel(5e-12, tran.tmax.?, 1e-12);

    const noise = a[4].noise;
    try testing.expectEqual(nl.net("load").?, noise.output.pos);
    try testing.expectEqual(ground, noise.output.neg);
    try testing.expectEqual(vin, noise.input);
    try testing.expectEqual(@as(u32, 5), noise.points_per_summary);

    const tf = a[5].tf;
    try testing.expectEqual(nl.net("load").?, tf.output.voltage.neg);

    const sens = a[6].sens;
    try testing.expectEqualDeep(&[_][]const u8{ "r1", "c1" }, sens.filters);
    try testing.expectEqual(@as(u32, 5), sens.mode.ac.points);
    try testing.expectEqual(nl.device("vdd").?, a[7].sens.output.current);
    try testing.expectEqual(analysis.Sens.Mode.dc, a[7].sens.mode);

    try testing.expectEqual(analysis.Pz.Solve.both, a[8].pz.solve);
    try testing.expectApproxEqRel(0.9, a[9].disto.f2_over_f1.?, 1e-12);
    try testing.expectEqual(@as(u32, 1024), a[10].pss.points);
    try testing.expect(a[11].sp.noise);
}

test "errors carry source, line and original-case token" {
    const gpa = testing.allocator;
    var d: Diagnostic = .{};

    try testing.expectError(error.UnknownNode, parse(gpa, &.{"t\nR1 a 0 1\n.tran 1n 1u\n.noise v(Nowhere) x dec 1 1 2\n"}, &d));
    try testing.expectEqual(@as(u32, 4), d.line);
    try testing.expectEqualStrings(".noise", d.token());

    try testing.expectError(error.NotASource, parse(gpa, &.{"t\nR1 a 0 1\n.tf v(a) R1\n"}, &d));
    try testing.expectError(error.UnsupportedDevice, parse(gpa, &.{ "t\nR1 a 0 1\n", "YAmp a b opamp\n" }, &d));
    try testing.expectEqual(@as(u32, 1), d.source);
    try testing.expectEqual(@as(u32, 1), d.line); // second source has no title line
    try testing.expectEqualStrings("YAmp", d.token());

    try testing.expectError(error.DuplicateDevice, parse(gpa, &.{"t\nR1 a 0 1\nr1 b 0 2\n"}, &d));
    try testing.expectError(error.UnsupportedPoly, parse(gpa, &.{"t\nE1 a 0 poly(1) b 0 0 1\n"}, &d));
    try testing.expectError(error.UnsupportedInclude, parse(gpa, &.{"t\n.include models.lib\n"}, &d));
    try testing.expectError(error.InvalidNumber, parse(gpa, &.{"t\nV1 a 0 1\n.dc v1 0 1 0\n"}, &d));
    try testing.expectError(error.UnexpectedToken, parse(gpa, &.{"t\n.tran 1n 1u junk\n"}, &d));
    try testing.expectError(error.UnsupportedAnalysis, parse(gpa, &.{"t\n.hb 1g 3 out\n"}, &d));
}

test "unknown model keeps the minimum pin count" {
    const gpa = testing.allocator;
    var nl = try parse(gpa, &.{"t\nM1 d g s b libmodel w=1u\n"}, null);
    defer nl.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), nl.graph.edgeSize(nl.device("m1").?));
}

test "parseValue" {
    const cases = [_]struct { []const u8, f64 }{
        .{ "1k", 1e3 },    .{ "1meg", 1e6 },      .{ "1MEG", 1e6 },     .{ "1m", 1e-3 },
        .{ "10uF", 1e-5 }, .{ "2.5e-3", 2.5e-3 }, .{ "3mil", 76.2e-6 }, .{ ".5", 0.5 },
        .{ "-3n", -3e-9 }, .{ "5V", 5 },          .{ "1e3k", 1e6 },     .{ "4.7K", 4.7e3 },
    };
    for (cases) |c| try testing.expectApproxEqRel(c[1], try parseValue(c[0]), 1e-12);
    try testing.expectError(error.InvalidNumber, parseValue("abc"));
    try testing.expectError(error.InvalidNumber, parseValue("."));
}

test "load from files through std.Io" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "top.cir", .data = "top\nV1 in 0 1\nR1 in out 1k\n.op\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "load.cir", .data = "C1 out 0 1p\n.ac dec 5 1 1k\n" });

    var nl = try load(gpa, io, tmp.dir, &.{ "top.cir", "load.cir" }, null);
    defer nl.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), nl.graph.edgeCount());
    try testing.expectEqual(@as(usize, 2), nl.analyses.len);

    var d: Diagnostic = .{};
    try testing.expectError(error.FileNotFound, load(gpa, io, tmp.dir, &.{ "top.cir", "missing.cir" }, &d));
    try testing.expectEqual(@as(u32, 1), d.source);
}

test "model type: from the .model card, else the model name" {
    const gpa = testing.allocator;
    var nl = try parse(gpa, &.{
        \\t
        \\.model nch nmos level=1
        \\.model qp pnp
        \\M1 d g s s nch
        \\M2 d g s s pmos
        \\Q1 c b e qp
        \\R1 a b 1k
    }, null);
    defer nl.deinit(gpa);
    try testing.expectEqualStrings("nmos", nl.modelType(nl.device("m1").?).?);
    try testing.expectEqualStrings("pmos", nl.modelType(nl.device("m2").?).?);
    try testing.expectEqualStrings("pnp", nl.modelType(nl.device("q1").?).?);
    try testing.expect(nl.modelType(nl.device("r1").?) == null);
}

test "subckt: an instance is a block with the definition's ports and shape" {
    const gpa = testing.allocator;
    var nl = try parse(gpa, &.{
        \\t
        \\.subckt opamp inp inn out vdd vss
        \\*@ left inn inp
        \\*@ top vdd
        \\E1 out 0 inp inn 1e5
        \\.ends opamp
        \\X1 a b c vdd 0 opamp gain=2
        \\R1 c 0 1k
    }, null);
    defer nl.deinit(gpa);
    try testing.expectEqual(1, nl.defs.len);
    const x = nl.device("x1").?;
    try testing.expectEqual(DeviceKind.subckt, nl.graph.edges.items(.kind)[x.index()]);
    const def = nl.defOf(x).?;
    try testing.expectEqualStrings("opamp", def.name);
    try testing.expect(!def.expand);
    try testing.expectEqual(PortSide.left, def.sides[0].?);
    try testing.expectEqual(PortSide.top, def.sides[3].?);
    try testing.expect(def.sides[2] == null);
    try testing.expect(def.order[1] < def.order[0]); // inn listed before inp
    var buf: [5][]const u8 = undefined;
    try testing.expectEqualDeep(&[_][]const u8{ "a", "b", "c", "vdd", "0" }, names(&nl, nl.graph.members(x), &buf));
    try testing.expectEqualStrings("opamp", nl.params(x)[0]);
    // What is inside stays hidden.
    try testing.expect(nl.device("e1") == null and nl.device("e.x1.e1") == null);
}

test "subckt: *@ expand flattens, with ngspice's names; ground stays global" {
    const gpa = testing.allocator;
    var nl = try parse(gpa, &.{
        \\t
        \\.subckt div top mid
        \\*@ expand
        \\R1 top mid 1k
        \\R2 mid inner 1k
        \\R3 inner 0 1k
        \\.ends
        \\.subckt pair a b
        \\*@ expand
        \\XA a b div
        \\XB b a div
        \\.ends
        \\V1 in 0 1
        \\X1 in out pair
    }, null);
    defer nl.deinit(gpa);
    // Nested: x1 expands, and its xa and xb expand in turn.
    const r = nl.device("r.x1.xa.r2").?;
    var buf: [2][]const u8 = undefined;
    try testing.expectEqualDeep(&[_][]const u8{ "out", "x1.xa.inner" }, names(&nl, nl.graph.members(r), &buf));
    try testing.expectEqual(ground, nl.graph.members(nl.device("r.x1.xb.r3").?)[1]);
    try testing.expectEqual(7, nl.graph.edgeCount()); // v1 and six resistors
}

test "subckt: errors name the instance" {
    const gpa = testing.allocator;
    var d: Diagnostic = .{};
    try testing.expectError(error.PortCountMismatch, parse(gpa, &.{"t\n.subckt s a b\nR1 a b 1\n.ends\nX1 n1 s\n"}, &d));
    try testing.expectEqual(5, d.line);
    try testing.expectError(error.SubcircuitTooDeep, parse(gpa, &.{"t\n.subckt s a\n*@ expand\nX1 a s\n.ends\nX1 n s\n"}, &d));
}

test "subckt: an undefined master is a PDK primitive by name, else a box with ports p1..pN" {
    const gpa = testing.allocator;
    var nl = try parse(gpa, &.{
        \\t
        \\XM1 out in 0 0 sky130_fd_pr__nfet_01v8 W=1 L=0.15
        \\XM2 out in vdd vdd sky130_fd_pr__pfet_01v8 W=2 L=0.15
        \\XR1 out mid 0 sky130_fd_pr__res_high_po_0p35 L=10
        \\XC1 mid 0 sky130_fd_pr__cap_mim_m3_1 W=10 L=10
        \\XU1 in mid out stdcell
        \\XU2 a b c stdcell
    }, null);
    defer nl.deinit(gpa);
    const kinds = nl.graph.edges.items(.kind);
    try testing.expectEqual(DeviceKind.mosfet, kinds[nl.device("xm1").?.index()]);
    try testing.expectEqual(DeviceKind.mosfet, kinds[nl.device("xm2").?.index()]);
    try testing.expectEqualStrings("sky130_fd_pr__pfet_01v8", nl.modelType(nl.device("xm2").?).?);
    try testing.expectEqual(DeviceKind.resistor, kinds[nl.device("xr1").?.index()]);
    try testing.expectEqual(3, nl.graph.edgeSize(nl.device("xr1").?)); // the body is kept
    try testing.expectEqual(DeviceKind.capacitor, kinds[nl.device("xc1").?.index()]);
    // Not a primitive: one definition, generic ports, shared by both instances.
    const xu1 = nl.device("xu1").?;
    try testing.expectEqual(DeviceKind.subckt, kinds[xu1.index()]);
    try testing.expectEqual(1, nl.defs.len);
    try testing.expectEqualStrings("stdcell", nl.defOf(xu1).?.name);
    try testing.expectEqualDeep(&[_][]const u8{ "p1", "p2", "p3" }, nl.defOf(xu1).?.ports);
    try testing.expectEqual(nl.defOf(xu1), nl.defOf(nl.device("xu2").?));
    try testing.expectError(error.PortCountMismatch, parse(gpa, &.{"t\nXU1 a b c cell\nXU2 a b cell\n"}, null));
}
