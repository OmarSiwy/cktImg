//! `.subckt` collection and recursive flattening: tokens in, `Ir` + `Report` out.
//!
//! Two phases, both single passes.
//!
//! **Phase 1 (`Defs.split`)** walks every statement, uses boundary detection only, and
//! slices definition bodies out of the stream. What is left is the top-level line list.
//! Definitions may nest, and a nested one is *lifted* into the flat global table rather
//! than being scoped to its parent — real decks use globally unique subckt names, and
//! honouring the nesting would mean a per-frame lookup table for a case nobody writes.
//!
//! **Phase 2 (`Flattener`)** emits the top-level lines, recursing into each instantiation.
//! Flattening is pure renaming: a definition's formal ports map **positionally** to the
//! actual nets at the call site, every other net becomes `prefix.net`, and instance names
//! become `prefix.name`. Net `0` is never scoped — it is global ground in every dialect,
//! and prefixing it would split the ground net into one island per subckt instance, which
//! is the single most destructive thing this pass could get wrong.
//!
//! ## Bodies are an index array, not a range
//!
//! A `Def` cannot hold a `(line0, count)` range into the statement table, because lifting
//! a nested definition removes lines from the middle of its parent's body — the parent's
//! lines are not contiguous. So `Defs.body` is an explicit `[]LineIdx` and each `Def`
//! holds a range into *that*. One extra indirection, in exchange for nested definitions
//! working at all.
//!
//! ## Three stacks, two different lookup rules
//!
//! Flattening maintains three parallel stacks, all frame-indexed by depth:
//!
//! - the **parameter scope** (`expr.Scope`), looked up **innermost-out**: a subckt sees
//!   its own parameters, then its caller's, then the globals.
//! - the **port map**, looked up in the **innermost frame only**. This asymmetry is
//!   load-bearing. A formal port of the *current* definition maps to an actual net; an
//!   outer definition's port name means nothing here, and walking outward would let an
//!   inner net accidentally bind to an outer port that happens to share its name. The
//!   actual nets were already resolved through the outer context before the frame was
//!   pushed, so the full path is carried down without any outward search.
//! - the **prefix**, one byte buffer with a frame stack of lengths. `xtop`, then
//!   `xtop.xa`, then `xtop.xa.xb`; popping truncates. This is why hierarchical name
//!   construction costs no allocation per level, where the Rust original built a fresh
//!   `String` per instance per level.
//!
//! ## Parameter precedence is SPICE's, not the obvious one
//!
//! A child scope is: the visible globals, then the definition's defaults **evaluated in
//! the child scope** (so one default may reference another), then the call-site overrides
//! **evaluated in the parent scope** (so `X1 a rload W=W*2` means the caller's `W`, not
//! the definition's default). Getting these two evaluation scopes the same way round is
//! the sort of thing that produces a plausible wrong number, so it is asserted by test
//! rather than left to reading.
//!
//! ## Depth is capped and reported
//!
//! `max_depth` instantiation levels. A self-instantiating subckt is a legal-looking deck
//! that would otherwise recurse until the stack dies; hitting the cap appends a
//! `subckt_too_deep` note and stops that branch. The rest of the deck still emits, because
//! a partial drawing beats a crash and beats a refusal.
//!
//! ## What ends up in the report
//!
//! `ignored` is by design and is recorded **only at depth 0**: a `.tran` inside a subckt
//! body is the same `.tran` the user already saw at top level, and reporting it once per
//! instantiation would flood the report. `skipped` is recorded at every depth, because a
//! device that failed to resolve inside an instance is a device missing from the drawing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const ir_mod = @import("../ir.zig");
const strings = @import("../strings.zig");
const cfg_mod = @import("../config.zig");
const token = @import("token.zig");
const card = @import("card.zig");
const expr = @import("expr.zig");
const source = @import("source.zig");
const host = @import("../devices/host.zig");

const StrId = ids.StrId;
const NetIdx = ids.NetIdx;
const SymbolIdx = ids.SymbolIdx;
const DeviceIdx = ids.DeviceIdx;
const Orient = ids.Orient;
const Interner = strings.Interner;
const Strings = strings.Strings;
const Config = cfg_mod.Config;
const Ir = ir_mod.Ir;
const Report = ir_mod.Report;
const Note = ir_mod.Note;
const Tokens = token.Tokens;
const TokIdx = token.TokIdx;
const LineIdx = token.LineIdx;
const Classifier = card.Classifier;
const Scope = expr.Scope;
const Source = source.Source;

/// Cap on instantiation nesting. Matches `expr.Scope.max_depth`, because the parameter
/// scope pushes one frame per level and the two limits must not disagree.
///
/// A well-formed deck nests a handful deep; reaching 64 means a definition instantiates
/// itself, transitively.
pub const max_depth: u8 = 64;

/// One subckt definition: formal ports, default parameters, and body lines.
///
/// All six range fields index the side arrays on `Defs`. Ranges rather than slices so the
/// record is 28 bytes of plain integers and the side arrays may still grow while
/// definitions are being collected.
pub const Def = struct {
    /// Master name, interned folded. The lookup key.
    name: StrId,
    /// Range into `Defs.ports` — formal ports in declaration order.
    port0: u32,
    nports: u32,
    /// Range into `Defs.params` — default parameter expressions.
    param0: u32,
    nparams: u32,
    /// Range into `Defs.body` — the statements of this definition, in source order, with
    /// nested definitions already removed.
    line0: u32,
    nlines: u32,
};

/// Every definition in the deck, plus the top-level line list left over.
///
/// Deinit-complete. Borrows nothing from the classifier: port token indices and parameter
/// args are *copied* out of the classifier's scratch as each definition closes, because
/// scratch is overwritten on the next line.
pub const Defs = struct {
    defs: std.MultiArrayList(Def) = .empty,
    /// Formal port tokens, grouped by definition.
    ports: std.ArrayList(TokIdx) = .empty,
    /// Default parameter expressions, grouped by definition.
    params: std.ArrayList(card.Arg) = .empty,
    /// Body statements, grouped by definition. See the module header for why this is an
    /// index array rather than a range.
    body: std.ArrayList(LineIdx) = .empty,
    /// Statements outside every definition, in source order.
    top: std.ArrayList(LineIdx) = .empty,
    /// Definition names paired with their index, sorted ascending by `name`.
    ///
    /// Two jobs: it is the binary-search index for `find`, and its `name` column *is* the
    /// `subs` slice the classifier needs to tell a subckt instance from an unknown master.
    index: std.MultiArrayList(Ref) = .empty,

    pub const Ref = struct {
        name: StrId,
        def: u32,
    };

    pub const empty: Defs = .{};

    /// Release every array. Safe on `.empty`.
    pub fn deinit(self: *Defs, gpa: Allocator) void {
        self.defs.deinit(gpa);
        self.ports.deinit(gpa);
        self.params.deinit(gpa);
        self.body.deinit(gpa);
        self.top.deinit(gpa);
        self.index.deinit(gpa);
        self.* = .empty;
    }

    /// Definition names, sorted — hand this straight to `Classifier.subs`.
    ///
    /// Borrowed; valid until `deinit` or until another definition is added.
    pub fn names(self: Defs) []const StrId {
        return self.index.items(.name);
    }

    /// Definition index for a folded master name, or null.
    ///
    /// Binary search over `index`. Sorted by `StrId` rather than by bytes: equal strings
    /// intern to equal ids, so ordering by id is a valid total order, it makes a probe an
    /// integer compare, and it keeps a hash map out of the lookup path.
    pub fn find(self: Defs, name: StrId) ?u32 {
        const i = std.sort.binarySearch(StrId, self.index.items(.name), name, orderStrId) orelse
            return null;
        return self.index.items(.def)[i];
    }

    fn orderStrId(needle: StrId, a: StrId) std.math.Order {
        return std.math.order(@intFromEnum(needle), @intFromEnum(a));
    }

    /// Formal ports of definition `d`. Borrowed; valid until `deinit`.
    pub fn portsOf(self: Defs, d: u32) []const TokIdx {
        const p0 = self.defs.items(.port0)[d];
        return self.ports.items[p0..][0..self.defs.items(.nports)[d]];
    }

    /// Default parameters of definition `d`. Borrowed; valid until `deinit`.
    pub fn paramsOf(self: Defs, d: u32) []const card.Arg {
        const p0 = self.defs.items(.param0)[d];
        return self.params.items[p0..][0..self.defs.items(.nparams)[d]];
    }

    /// Body statements of definition `d`. Borrowed; valid until `deinit`.
    pub fn bodyOf(self: Defs, d: u32) []const LineIdx {
        const l0 = self.defs.items(.line0)[d];
        return self.body.items[l0..][0..self.defs.items(.nlines)[d]];
    }

    /// Phase 1: slice definitions out of the statement stream.
    ///
    /// Walks every statement in order, maintaining a stack of open definitions. A
    /// `boundary` begin pushes a frame; an end closes the innermost frame and lifts it
    /// into the flat table. Statements land in the innermost open definition's body, or in
    /// `top` when none is open.
    ///
    /// Only `Classifier.boundary` is consulted — no classification happens here, because
    /// classification needs the very definition-name set this phase produces. That
    /// ordering is the reason boundary detection is dialect-aware but table-free.
    ///
    /// Error recovery, both reported and both non-fatal:
    /// - an `.ends` with no open definition appends `port_arity_mismatch` against that
    ///   line and is otherwise ignored;
    /// - a definition still open at end of input appends `port_arity_mismatch` and its
    ///   body is **discarded**, since an unterminated definition has swallowed the rest of
    ///   the deck and emitting it as top level would draw a circuit the user did not write.
    ///
    /// A duplicate master name keeps the **last** definition, matching simulator practice
    /// of the later `.subckt` winning, and the earlier one becomes unreachable rather than
    /// being reported — a redefinition is usually deliberate (a corner override).
    ///
    /// Caller owns the returned `Defs`. `notes` receives the diagnostics above and is
    /// owned by the caller. Errors: `OutOfMemory`; on failure the partial `Defs` is
    /// released before returning.
    ///
    /// Complexity: one pass over statements plus one sort of the name index.
    pub fn split(
        gpa: Allocator,
        cl: *Classifier,
        notes: *std.ArrayList(Note),
    ) Allocator.Error!Defs {
        var self: Defs = .empty;
        errdefer self.deinit(gpa);

        // One open definition. Its body cannot go straight into `Defs.body`: a nested
        // definition's lines would interleave with its parent's, so each frame buffers
        // its own and flushes contiguously on close.
        const Frame = struct {
            name: StrId,
            port0: u32,
            nports: u32,
            param0: u32,
            nparams: u32,
            off: u32,
            len: u32,
            body: std.ArrayList(LineIdx),
        };
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |*f| f.body.deinit(gpa);
            stack.deinit(gpa);
        }

        var i: usize = 0;
        while (i < cl.toks.lineCount()) : (i += 1) {
            const l = LineIdx.at(i);
            if (try cl.boundary(gpa, l)) |b| {
                switch (b) {
                    .begin => |beg| {
                        const port0: u32 = @intCast(self.ports.items.len);
                        try self.ports.appendSlice(gpa, beg.ports);
                        const param0: u32 = @intCast(self.params.items.len);
                        try self.params.appendSlice(gpa, beg.params);
                        const off, const len = cl.toks.lineSpan(l);
                        try stack.append(gpa, .{
                            .name = beg.name,
                            .port0 = port0,
                            .nports = @intCast(beg.ports.len),
                            .param0 = param0,
                            .nparams = @intCast(beg.params.len),
                            .off = off,
                            .len = len,
                            .body = .empty,
                        });
                    },
                    .end => {
                        if (stack.items.len == 0) {
                            const off, const len = cl.toks.lineSpan(l);
                            try notes.append(gpa, .{
                                .off = off,
                                .len = len,
                                .reason = .port_arity_mismatch,
                            });
                            continue;
                        }
                        var f = stack.pop().?;
                        defer f.body.deinit(gpa);
                        const line0: u32 = @intCast(self.body.items.len);
                        try self.body.appendSlice(gpa, f.body.items);
                        try self.defs.append(gpa, .{
                            .name = f.name,
                            .port0 = f.port0,
                            .nports = f.nports,
                            .param0 = f.param0,
                            .nparams = f.nparams,
                            .line0 = line0,
                            .nlines = @intCast(f.body.items.len),
                        });
                        // A nested definition is lifted into the flat table rather than
                        // scoped to its parent: real decks use globally unique names.
                        try self.index.append(gpa, .{
                            .name = f.name,
                            .def = @intCast(self.defs.len - 1),
                        });
                    },
                }
                continue;
            }
            if (stack.items.len > 0) {
                try stack.items[stack.items.len - 1].body.append(gpa, l);
            } else {
                try self.top.append(gpa, l);
            }
        }

        // An unterminated definition has swallowed the rest of the deck; emitting its
        // body at top level would draw a circuit the user did not write.
        for (stack.items) |f| {
            try notes.append(gpa, .{ .off = f.off, .len = f.len, .reason = .port_arity_mismatch });
        }

        self.sortIndex();
        return self;
    }

    /// Sort the name index and collapse duplicates, keeping the **last** definition —
    /// simulator practice, where a later `.subckt` overrides an earlier one, and the
    /// earlier becomes unreachable rather than being reported.
    ///
    /// Sorting by `StrId` rather than by bytes is a valid total order (equal strings
    /// intern to equal ids) and keeps a probe an integer compare.
    fn sortIndex(self: *Defs) void {
        const Ctx = struct {
            names: []const StrId,
            defs: []const u32,

            pub fn lessThan(c: @This(), a: usize, b: usize) bool {
                if (c.names[a] != c.names[b]) {
                    return @intFromEnum(c.names[a]) < @intFromEnum(c.names[b]);
                }
                return c.defs[a] < c.defs[b];
            }
        };
        self.index.sort(Ctx{ .names = self.index.items(.name), .defs = self.index.items(.def) });

        // Equal names are adjacent and ascending by definition index, so the last of each
        // run wins. Compacting in place beats a second array.
        var out: usize = 0;
        var i: usize = 0;
        const n = self.index.len;
        while (i < n) {
            var j = i + 1;
            while (j < n and self.index.items(.name)[j] == self.index.items(.name)[i]) j += 1;
            self.index.set(out, self.index.get(j - 1));
            out += 1;
            i = j;
        }
        self.index.shrinkRetainingCapacity(out);
    }
};

/// One formal-port-to-actual-net binding for the current instantiation level.
pub const PortBind = struct {
    /// Formal port name as written in the definition, interned folded.
    formal: StrId,
    /// Fully resolved actual net name, interned — already carrying the outer prefix.
    actual: StrId,
};

/// Phase 2 state: the emitting recursion's three stacks plus the IR columns being built.
///
/// Deinit-complete, and the deinit releases the half-built IR columns too, so an
/// `OutOfMemory` partway through a deep hierarchy leaks nothing.
///
/// Borrowed and required to outlive it: `cl`, `defs`, `interner`, `toks`, `cfg`.
pub const Flattener = struct {
    gpa: Allocator,
    cl: *Classifier,
    defs: *const Defs,
    interner: *Interner,
    toks: *const Tokens,
    cfg: *const Config,

    /// Parameter scope. Frame 0 is the globals, opened by `init`.
    scope: Scope = .empty,

    /// Port bindings for every open level. Looked up in the innermost frame only — see
    /// the module header.
    ports: std.MultiArrayList(PortBind) = .empty,
    /// `port_frames[k]` is the binding count when level `k` was pushed.
    port_frames: [max_depth]u32 = @splat(0),

    /// Current dotted instance path with no trailing dot: `""` at top level, `xtop.xa`
    /// inside two levels of instantiation.
    prefix: std.ArrayList(u8) = .empty,
    /// `prefix_frames[k]` is `prefix.items.len` when level `k` was pushed, so popping is a
    /// truncation.
    prefix_frames: [max_depth]u32 = @splat(0),
    /// Current instantiation depth: 0 at top level.
    depth: u8 = 0,

    /// Reused buffer for building one qualified name or one resolved value label before it
    /// is interned. One buffer, one name at a time — a qualified name is consumed
    /// immediately by `internFold`.
    scratch: std.ArrayList(u8) = .empty,

    // --- IR columns under construction ---

    dev_symbol: std.ArrayList(SymbolIdx) = .empty,
    dev_orient: std.ArrayList(Orient) = .empty,
    /// CSR offsets; `init` seeds it with the leading 0 so it always has `n + 1` entries.
    dev_pin0: std.ArrayList(u32) = .empty,
    pin_net: std.ArrayList(NetIdx) = .empty,
    dev_name: std.ArrayList(StrId) = .empty,
    dev_value: std.ArrayList(StrId) = .empty,
    net_name: std.ArrayList(StrId) = .empty,
    group_path: std.ArrayList(StrId) = .empty,
    group_master: std.ArrayList(StrId) = .empty,

    /// Net name → index. **Membership only**: this map is never iterated. Net order comes
    /// from `net_name`, which is first-mention order and therefore reproducible.
    nets: std.AutoHashMapUnmanaged(StrId, NetIdx) = .empty,

    ignored: std.ArrayList(Note) = .empty,
    skipped: std.ArrayList(Note) = .empty,

    /// Create a flattener with the global parameter frame and the CSR seed in place.
    ///
    /// Allocates only the two seed entries. Errors: `OutOfMemory`.
    pub fn init(
        gpa: Allocator,
        cl: *Classifier,
        defs: *const Defs,
        interner: *Interner,
        toks: *const Tokens,
        cfg: *const Config,
    ) Allocator.Error!Flattener {
        var self: Flattener = .{
            .gpa = gpa,
            .cl = cl,
            .defs = defs,
            .interner = interner,
            .toks = toks,
            .cfg = cfg,
        };
        errdefer self.deinit();
        self.scope.push() catch unreachable; // frame 0 of 64 always fits
        try self.dev_pin0.append(gpa, 0); // CSR seed: n + 1 entries, always
        return self;
    }

    /// Release every buffer, including the partially built IR columns.
    ///
    /// Call this on the error path. After a successful `finish` the columns have been
    /// transferred out and this releases only what remains, so calling both is correct and
    /// is the intended pattern.
    pub fn deinit(self: *Flattener) void {
        const gpa = self.gpa;
        self.scope.deinit(gpa);
        self.ports.deinit(gpa);
        self.prefix.deinit(gpa);
        self.scratch.deinit(gpa);
        self.dev_symbol.deinit(gpa);
        self.dev_orient.deinit(gpa);
        self.dev_pin0.deinit(gpa);
        self.pin_net.deinit(gpa);
        self.dev_name.deinit(gpa);
        self.dev_value.deinit(gpa);
        self.net_name.deinit(gpa);
        self.group_path.deinit(gpa);
        self.group_master.deinit(gpa);
        self.nets.deinit(gpa);
        self.ignored.deinit(gpa);
        self.skipped.deinit(gpa);
    }

    /// Emit a list of statements at the current depth, recursing into instantiations.
    ///
    /// The core recursion. Per statement:
    /// - a parameter definition updates the innermost scope frame in source order and is
    ///   consumed (reported as `param_card` ignored only at depth 0);
    /// - an element becomes a device: its refdes and every node name are qualified, its
    ///   `{…}` value is resolved against the current scope;
    /// - an instantiation records a group, pushes all three stacks, emits the definition
    ///   body, and pops;
    /// - an ignored card is noted only at depth 0; a skipped card is noted at every depth.
    ///
    /// Errors: `OutOfMemory` only. Every data problem becomes a note.
    pub fn emit(self: *Flattener, lines: []const LineIdx) Allocator.Error!void {
        for (lines) |l| {
            if (self.cl.isParamDef(l)) {
                // Assignments take effect in source order, so `.param a=1 a=2` ends at 2.
                const args = try self.cl.paramAssignments(self.gpa, l);
                for (args) |a| {
                    const text = self.toks.src[a.off..][0..a.len];
                    if (expr.eval(text, self.scope, self.interner.*)) |v| {
                        try self.scope.define(self.gpa, a.key, v);
                    }
                }
                const off, const len = self.toks.lineSpan(l);
                try self.note(.param_card, off, len);
                continue;
            }
            const c = try self.cl.classify(self.gpa, l);
            switch (c.kind) {
                .elem => try self.emitElem(c),
                .inst => try self.emitInst(c, l),
                // Phase 1 consumed every boundary, and `isParamDef` caught every
                // parameter line; both arms are here so a future kind cannot be dropped.
                .boundary, .param_def => {},
                .ignored, .skipped => try self.note(c.reason, c.off, c.len),
            }
        }
    }

    /// Emit one classified element as a device with its pins.
    ///
    /// Appends one entry to every device column, one `dev_pin0` offset, and one `pin_net`
    /// entry per node. Node count always equals the symbol's terminal count — the
    /// classifier truncates and rejects short cards — so `pin_net` never receives
    /// `NetIdx.none` from this path. A floating pin can only come from a host-registered
    /// symbol, never from a netlist card.
    ///
    /// The value label is resolved through `expr.resolveBraces` against the current scope
    /// and interned **verbatim** (not folded): a value is display text, and folding it
    /// would print `1MEG` as `1meg`.
    ///
    /// Post-condition: `dev_pin0` keeps `device_count + 1` entries.
    pub fn emitElem(self: *Flattener, c: card.Card) Allocator.Error!void {
        const name = try self.qualifyName(c.name);

        // A value is display text, so it is interned verbatim: folding it would print
        // `1MEG` as `1meg`.
        self.scratch.clearRetainingCapacity();
        {
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.scratch);
            defer self.scratch = aw.toArrayList();
            expr.resolveBraces(c.value, self.scope, self.interner.*, &aw.writer) catch
                return error.OutOfMemory;
        }
        const value = try self.interner.intern(self.gpa, self.scratch.items);

        try self.pin_net.ensureUnusedCapacity(self.gpa, c.nodes.len);
        for (c.nodes) |t| {
            const net = try self.netOf(try self.qualifyNet(self.toks.text(t)));
            self.pin_net.appendAssumeCapacity(net);
        }
        try self.dev_symbol.append(self.gpa, c.symbol);
        try self.dev_orient.append(self.gpa, .r0);
        try self.dev_name.append(self.gpa, name);
        try self.dev_value.append(self.gpa, value);
        try self.dev_pin0.append(self.gpa, @intCast(self.pin_net.items.len));
    }

    /// Flatten one subckt instantiation.
    ///
    /// Order of operations, each step depending on the last:
    /// 1. depth check — at `max_depth`, append `subckt_too_deep` and return;
    /// 2. definition lookup — absent, append `undefined_subckt` and return (the classifier
    ///    only produces an `.inst` for a name in `subs`, so this is a belt-and-braces path
    ///    reachable when a definition is unterminated);
    /// 3. arity check — actual node count must equal formal port count exactly, or append
    ///    `port_arity_mismatch` and return. Not truncated and not padded: a positional
    ///    mapping with the wrong count wires every net to the wrong pin, which draws a
    ///    plausible and completely wrong schematic;
    /// 4. resolve each actual net through the *current* context, so an inner port wired to
    ///    an outer-scoped net carries the full path down;
    /// 5. record the group (`prefix`, master) **before** dissolving the boundary, so a
    ///    renderer can still draw it as one annotated block;
    /// 6. push the prefix, the port frame and the scope frame; build the child scope
    ///    (globals, then defaults in the child scope, then call-site args in the parent
    ///    scope); emit the body; pop all three.
    ///
    /// The pops are paired with the pushes on every path, including the error paths, which
    /// is why steps 1 to 4 all return *before* anything is pushed.
    pub fn emitInst(self: *Flattener, c: card.Card, l: LineIdx) Allocator.Error!void {
        const off, const len = self.toks.lineSpan(l);
        if (self.depth >= max_depth) return self.note(.subckt_too_deep, off, len);

        const master = try self.interner.internFold(self.gpa, c.master);
        // Belt and braces: the classifier only emits `.inst` for a name in `subs`, so
        // this is reachable only when a definition was left unterminated.
        const d = self.defs.find(master) orelse return self.note(.undefined_subckt, off, len);

        const formals = self.defs.portsOf(d);
        // Not truncated and not padded: a positional mapping with the wrong count wires
        // every net to the wrong pin, which draws a plausible and completely wrong
        // schematic.
        if (c.nodes.len != formals.len) return self.note(.port_arity_mismatch, off, len);

        // Resolved through the *current* context, so an inner port wired to an
        // outer-scoped net carries the full path down. Buffered because the port frame
        // must not be visible to its own resolution.
        // ponytail: one small list per instantiation, bounded by nesting depth.
        var actual: std.ArrayList(StrId) = .empty;
        defer actual.deinit(self.gpa);
        try actual.ensureUnusedCapacity(self.gpa, c.nodes.len);
        for (c.nodes) |t| {
            actual.appendAssumeCapacity(try self.qualifyNet(self.toks.text(t)));
        }

        // The instance name qualified in the *outer* context is both the group path and
        // the new prefix. Recorded before the boundary dissolves, so a renderer can still
        // draw the block.
        const path = try self.qualifyName(c.name);
        try self.group_path.append(self.gpa, path);
        try self.group_master.append(self.gpa, master);

        // Call-site overrides are evaluated in the parent scope: `X1 a rload W=W*2`
        // means the caller's `W`, not the definition's default. Snapshot the values
        // before the child frame opens.
        const args = self.defs.paramsOf(d);
        var overrides: std.ArrayList(expr.Binding) = .empty;
        defer overrides.deinit(self.gpa);
        {
            const call_args = c.args;
            try overrides.ensureUnusedCapacity(self.gpa, call_args.len);
            for (call_args) |a| {
                const text = self.toks.src[a.off..][0..a.len];
                if (expr.eval(text, self.scope, self.interner.*)) |v| {
                    overrides.appendAssumeCapacity(.{ .name = a.key, .value = v });
                }
            }
        }

        self.scope.push() catch return self.note(.subckt_too_deep, off, len);
        defer self.scope.pop();

        self.port_frames[self.depth] = @intCast(self.ports.len);
        self.prefix_frames[self.depth] = @intCast(self.prefix.items.len);
        defer {
            self.ports.shrinkRetainingCapacity(self.port_frames[self.depth]);
            self.prefix.shrinkRetainingCapacity(self.prefix_frames[self.depth]);
        }

        try self.ports.ensureUnusedCapacity(self.gpa, formals.len);
        for (formals, actual.items) |f, a| {
            self.ports.appendAssumeCapacity(.{
                .formal = try self.interner.internFold(self.gpa, self.toks.text(f)),
                .actual = a,
            });
        }
        if (self.prefix.items.len > 0) try self.prefix.append(self.gpa, '.');
        try self.prefix.appendSlice(self.gpa, c.name);

        // Defaults are evaluated in the child scope, so one may reference another.
        for (args) |a| {
            const text = self.toks.src[a.off..][0..a.len];
            if (expr.eval(text, self.scope, self.interner.*)) |v| {
                try self.scope.define(self.gpa, a.key, v);
            }
        }
        for (overrides.items) |o| try self.scope.define(self.gpa, o.name, o.value);

        self.depth += 1;
        defer self.depth -= 1;
        try self.emit(self.defs.bodyOf(d));
    }

    /// Qualify a net name for the current level and intern it.
    ///
    /// Three cases, in order: a formal port of the current definition resolves to its
    /// bound actual net; the literal `0` stays `0` at every depth, because it is global
    /// ground; anything else becomes `prefix.name`. At depth 0 the name is returned
    /// unqualified.
    ///
    /// Folded on intern, so `VDD` and `vdd` are the same net. Errors: `OutOfMemory`.
    pub fn qualifyNet(self: *Flattener, name: []const u8) Allocator.Error!StrId {
        const id = try self.interner.internFold(self.gpa, name);
        if (self.portBinding(id)) |actual| return actual;
        // Global ground in every dialect. Prefixing it would split the ground net into
        // one island per instance, which is the most destructive thing this pass could
        // get wrong.
        if (std.mem.eql(u8, name, "0")) return id;
        if (self.depth == 0) return id;
        return self.qualified(name);
    }

    /// Qualify a device or instance name: `prefix.name`, or `name` at depth 0.
    ///
    /// Folded on intern. Unlike a net name, there is no exemption — a device called `0`
    /// still gets prefixed, because device names are not electrically shared.
    pub fn qualifyName(self: *Flattener, name: []const u8) Allocator.Error!StrId {
        if (self.depth == 0) return self.interner.internFold(self.gpa, name);
        return self.qualified(name);
    }

    /// `prefix.name`, built in the reused scratch buffer and interned folded.
    fn qualified(self: *Flattener, name: []const u8) Allocator.Error!StrId {
        self.scratch.clearRetainingCapacity();
        try self.scratch.ensureUnusedCapacity(self.gpa, self.prefix.items.len + 1 + name.len);
        self.scratch.appendSliceAssumeCapacity(self.prefix.items);
        self.scratch.appendAssumeCapacity('.');
        self.scratch.appendSliceAssumeCapacity(name);
        return self.interner.internFold(self.gpa, self.scratch.items);
    }

    /// Index of the net called `name`, creating it on first mention.
    ///
    /// First-mention order is the net numbering, which makes `NetIdx` assignment a
    /// function of the input text alone. The hash map answers membership; the order comes
    /// from `net_name`. Returns a 1-based `NetIdx`, never `.none`.
    pub fn netOf(self: *Flattener, name: StrId) Allocator.Error!NetIdx {
        // The map answers membership only; the numbering comes from `net_name`, which is
        // first-mention order and therefore a function of the input text alone.
        const g = try self.nets.getOrPut(self.gpa, name);
        if (g.found_existing) return g.value_ptr.*;
        const idx = NetIdx.at(self.net_name.items.len);
        self.net_name.append(self.gpa, name) catch |e| {
            _ = self.nets.remove(name);
            return e;
        };
        g.value_ptr.* = idx;
        return idx;
    }

    /// Look up a formal port in the **innermost frame only**, returning its actual net.
    ///
    /// Null when `name` is not a port of the current definition, or when at depth 0. The
    /// deliberate contrast with `Scope.lookup`, which walks outward — see the module
    /// header.
    pub fn portBinding(self: Flattener, name: StrId) ?StrId {
        if (self.depth == 0) return null;
        // Innermost frame only: an outer definition's port name means nothing here, and
        // walking outward would let an inner net bind to a same-named outer port.
        const formals = self.ports.items(.formal);
        var i = formals.len;
        const stop = self.port_frames[self.depth - 1];
        while (i > stop) {
            i -= 1;
            if (formals[i] == name) return self.ports.items(.actual)[i];
        }
        return null;
    }

    /// Append a note, choosing the list from the reason's own classification.
    ///
    /// `Note.Reason.isByDesign` decides `ignored` versus `skipped`, so the split is a
    /// property of the reason rather than of each call site — which is what keeps the two
    /// categories from drifting apart as reasons are added.
    ///
    /// An ignored note is dropped when `depth > 0`; a skipped note is always recorded. See
    /// the module header.
    pub fn note(self: *Flattener, reason: Note.Reason, off: u32, len: u32) Allocator.Error!void {
        if (reason.isByDesign()) {
            // A `.tran` inside a body is the same card the user already saw at top level.
            if (self.depth > 0) return;
            return self.ignored.append(self.gpa, .{ .off = off, .len = len, .reason = reason });
        }
        // A device that failed to resolve inside an instance is a device missing from
        // the drawing, so a skip is recorded at every depth.
        return self.skipped.append(self.gpa, .{ .off = off, .len = len, .reason = reason });
    }

    /// Transfer the IR columns and the report out.
    ///
    /// Caller owns the returned `Ir` and `Report`. `self` keeps its scratch buffers and
    /// must still be `deinit`ed; the columns are left empty so a second `finish` cannot
    /// double-transfer.
    ///
    /// Runs `Ir.assertValid` before returning: a malformed IR reaching the router turns a
    /// clear front-end bug into a mysterious drawing.
    pub fn finish(self: *Flattener) Allocator.Error!struct { Ir, Report } {
        const gpa = self.gpa;
        var out: Ir = .empty;
        errdefer out.deinit(gpa);
        out.dev_symbol = try self.dev_symbol.toOwnedSlice(gpa);
        out.dev_orient = try self.dev_orient.toOwnedSlice(gpa);
        out.dev_pin0 = try self.dev_pin0.toOwnedSlice(gpa);
        out.pin_net = try self.pin_net.toOwnedSlice(gpa);
        out.dev_name = try self.dev_name.toOwnedSlice(gpa);
        out.dev_value = try self.dev_value.toOwnedSlice(gpa);
        out.net_name = try self.net_name.toOwnedSlice(gpa);
        out.group_path = try self.group_path.toOwnedSlice(gpa);
        out.group_master = try self.group_master.toOwnedSlice(gpa);

        var rep: Report = .empty;
        errdefer rep.deinit(gpa);
        rep.ignored = try self.ignored.toOwnedSlice(gpa);
        rep.skipped = try self.skipped.toOwnedSlice(gpa);

        out.assertValid();
        return .{ out, rep };
    }
};

/// A fully parsed deck: the source it came from, the schematic, the string pool, and what
/// was dropped.
///
/// Deinit-complete and self-contained: the `Source` is kept because every `Note` in the
/// report is a span into it, so a caller that wants to format the report needs both and
/// separating them only invites a mismatched pair.
pub const Built = struct {
    source: Source,
    ir: Ir,
    strings: Strings,
    report: Report,

    /// Release all four. Invalidates every note span and every `StrId`.
    pub fn deinit(self: *Built, gpa: Allocator) void {
        self.source.deinit(gpa);
        self.ir.deinit(gpa);
        self.strings.deinit(gpa);
        self.report.deinit(gpa);
    }
};

/// Parse `text` into a schematic. The front end, in one call.
///
/// `.include` and `.lib` are **not** resolved — they are reported as ignored, matching the
/// no-IO entry point. Use `Source.expand` or `Source.load` first, then `fromSource`, to
/// follow them.
///
/// `symbols` is the table every class decision routes through — builtins plus whatever the
/// host registered — and `cfg` supplies the `[pdk]` knobs. Both are borrowed. `cfg` need
/// only outlive the call, but `symbols` must outlive the **result**: the `SymbolIdx` values
/// in the returned IR are meaningless without it.
///
/// Caller owns the returned `Built`. Errors: `OutOfMemory` only — a netlist that cannot be
/// represented produces notes plus whatever schematic was recoverable, because a partial
/// drawing is more useful than a refusal.
pub fn fromText(
    gpa: Allocator,
    cfg: *const Config,
    symbols: *const host.Table,
    text: []const u8,
) Allocator.Error!Built {
    var interner = try Interner.init(gpa);
    // `fromSource` takes ownership of both on every path, so the only gap needing an
    // unwind here is the construction of the source itself.
    const src = Source.fromText(gpa, &interner, text) catch |e| {
        interner.deinit(gpa);
        return e;
    };
    return fromSource(gpa, cfg, symbols, src, &interner, &.{});
}

/// Parse an already-expanded `Source`.
///
/// Takes ownership of `src` and of `interner`: `src` is moved into the result, and
/// `interner` is finished into `Built.strings`, after which the caller must neither use
/// nor `deinit` it. This is the entry point for a deck whose includes were resolved
/// separately, which is also the only way the preprocessor's own notes can be carried
/// through — `pre` is prepended to the report in source order.
///
/// `pre` is copied, so the caller may release its list immediately.
///
/// Caller owns the returned `Built`. Errors: `OutOfMemory`. On failure `src` and
/// `interner` are released, so the caller never has to unwind a partial move.
pub fn fromSource(
    gpa: Allocator,
    cfg: *const Config,
    symbols: *const host.Table,
    src: Source,
    interner: *Interner,
    pre: []const Note,
) Allocator.Error!Built {
    var owned_src = src;
    errdefer owned_src.deinit(gpa);
    errdefer interner.deinit(gpa);

    var toks = try token.tokenize(gpa, owned_src.text());
    defer toks.deinit(gpa);

    // `.model` gives models global scope regardless of where they are written, so the
    // scan runs over the whole deck before subckt bodies are split out.
    var models = try card.Models.collect(gpa, interner, toks);
    defer models.deinit(gpa);

    var cl: Classifier = .{
        .toks = &toks,
        .symbols = symbols,
        .cfg = cfg,
        .models = models,
        .subs = &.{}, // phase 1 closes no definition, so boundary detection is table-free
        .interner = interner,
    };
    defer cl.deinit(gpa);

    var notes: std.ArrayList(Note) = .empty;
    defer notes.deinit(gpa);
    try notes.appendSlice(gpa, pre);

    var defs = try Defs.split(gpa, &cl, &notes);
    defer defs.deinit(gpa);
    cl.subs = defs.names();

    var fl = try Flattener.init(gpa, &cl, &defs, interner, &toks, cfg);
    defer fl.deinit();
    // Preprocessor and phase-1 diagnostics come first, in source order.
    for (notes.items) |n| try fl.note(n.reason, n.off, n.len);
    try fl.emit(defs.top.items);

    const out_ir, const report = try fl.finish();
    var owned_ir = out_ir;
    errdefer owned_ir.deinit(gpa);
    var owned_report = report;
    errdefer owned_report.deinit(gpa);

    const pool = try interner.finish(gpa);
    return .{
        .source = owned_src,
        .ir = owned_ir,
        .strings = pool,
        .report = owned_report,
    };
}
