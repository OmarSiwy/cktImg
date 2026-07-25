//! Card classification: one tokenized statement in, one `Card` out.
//!
//! This is where SPICE's letter-prefix grammar is decoded. A statement's first character
//! decides its element type (`R`/`C`/`L` passive, `V`/`I` source, `M`/`Q`/`J`/`Z`
//! transistor, `E`/`G`/`F`/`H`/`B` controlled or behavioral source, `S`/`W` switch,
//! `T`/`O` transmission line, `P` port, `A` XSPICE block, `X` subckt instance), a leading
//! `.` makes it a control card, and the Spectre form is recognized by a `(` in slot 1.
//!
//! **No device data is defined here.** Terminal counts and symbol identities come from the
//! `devices.host.Table` this module is handed, which answers for the comptime catalog and
//! for runtime host classes both — that table is the single source of truth and this file
//! only spells names at it. The two local tables are *spelling* maps:
//! `alias` translates foreign primitive names (`resistor` → `res`, `vcvs` → `cvsource`)
//! onto builtin class names, and `xspice` maps XSPICE digital models onto builtin symbols
//! together with the port permutation each needs. Both are translation, not a second
//! device vocabulary.
//!
//! ## A card holds spans and one scratch buffer, not strings
//!
//! `Card` is returned by value and owns nothing. Node names are `TokIdx` — the one list
//! whose length is unbounded (a subckt instance may have thirty ports), where 4 bytes per
//! entry beats the 16 a `[]const u8` costs. The refdes, master and value are byte slices
//! instead, because the refdes and master are single tokens (so a slice is free) and the
//! value is *synthesized*: `W=1u/L=0.1u` for a transistor, a space-joined tail for a
//! source, a PDK flavour for a scanned foundry model. Those cannot be a span into the
//! source because they do not appear in it.
//!
//! Both the node list and the value text live in buffers owned by the `Classifier` and
//! reused across calls. That is the whole reason `Classifier` is a struct rather than a
//! free function: it makes classification allocation-free after the first few cards,
//! where the Rust original allocated a `Vec<String>` of nodes plus a `String` value for
//! every line of the deck. The cost is a stated lifetime — a `Card` is valid only until
//! the next `classify` on the same classifier — which every caller already satisfies,
//! because a card is consumed the moment it is produced.
//!
//! ## Node dropping is intentional
//!
//! A four-node `M` card's bulk terminal has no pin on the symbol and is dropped, which is
//! the same drop a PDK leaf instance makes. This is not lossy in a *drawing*: a substrate
//! tie drawn as a wire is noise on every schematic that has ever been drawn by hand. The
//! model token is found by scanning the trailing tokens **right to left**, because on
//! `M1 d g s vss nmos` the bulk node sits between the source and the model and may be
//! named after a rail — a left-to-right scan would resolve `vss` as the class.
//!
//! ## Reasons are the `ir.Note.Reason` enum, and it is narrower than the prose
//!
//! `ir.Note.Reason` has twelve members and the Rust original had about twenty distinct
//! message strings. The mapping is fixed here so the same condition always reports the
//! same way:
//!
//! | condition | reason |
//! |---|---|
//! | `.model` card | `model_card` (ignored) |
//! | `.param` / `parameters` | `param_card` (ignored, and consumed by the scope) |
//! | `.option` / `.options` | `option_card` (ignored) |
//! | any other dot card, Spectre control statement | `analysis_card` (ignored) |
//! | `K` inductor coupling | `analysis_card` (ignored — a relationship, not a device) |
//! | unsupported element letter, `U`/`Y`, too few nodes, malformed card | `unknown_class` |
//! | transistor model that is not a builtin, XSPICE model with no symbol | `unknown_class` |
//! | `X` master that is neither builtin, PDK leaf, nor a defined subckt | `undefined_subckt` |
//!
//! `comment` is never emitted: comments are removed by the tokenizer and reporting each
//! one would bury the notes that matter under the deck's own header banner.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const ir = @import("../ir.zig");
const strings = @import("../strings.zig");
const cfg_mod = @import("../config.zig");
const token = @import("token.zig");
const catalog = @import("../devices/catalog.zig");
const host = @import("../devices/host.zig");

const SymbolIdx = ids.SymbolIdx;
const StrId = ids.StrId;
const Interner = strings.Interner;
const Config = cfg_mod.Config;
const Tokens = token.Tokens;
const TokIdx = token.TokIdx;
const LineIdx = token.LineIdx;
const Lang = token.Lang;
const Reason = ir.Note.Reason;

/// What a statement turned out to be.
pub const Kind = enum(u8) {
    /// A builtin device, ready to emit.
    elem,
    /// A subckt instantiation, to be flattened.
    inst,
    /// A definition boundary (`.subckt` / `.ends`). Query `boundary` for the detail.
    boundary,
    /// A parameter definition (`.param` / `parameters`). Consumed by the scope, not
    /// emitted, and reported as ignored at top level.
    param_def,
    /// Dropped by design; `reason` says which kind.
    ignored,
    /// Wanted to represent it and could not; `reason` says why.
    skipped,
};

/// A `k=v` override or default, with the value left as an unevaluated span.
///
/// The key is interned (folded, so `W=` and `w=` are one parameter); the value is a span
/// into the source arena because it is an *expression* that may only be evaluable later,
/// in a scope that does not exist yet at classification time.
pub const Arg = struct {
    key: StrId,
    /// Span of the value expression in the source arena. Zero length for `k=`.
    off: u32,
    len: u32,
};

/// One classified statement.
///
/// Returned by value; owns nothing. `nodes` and `value` borrow the classifier's scratch
/// buffers and are **valid only until the next call** on that classifier. `name` and
/// `master` borrow the source arena and last as long as it does.
pub const Card = struct {
    kind: Kind,
    /// Span of the whole statement, for a `Note`. Always set, whatever the kind.
    off: u32,
    len: u32,
    /// Refdes as written, case preserved. Empty for a non-element statement.
    name: []const u8,
    /// `.elem` only: the resolved symbol.
    symbol: SymbolIdx,
    /// `.inst` only: master name as written.
    master: []const u8,
    /// `.elem` only: value label with `{…}` expressions still unresolved, because they
    /// need a parameter scope this stage has no access to. Borrowed from the classifier.
    value: []const u8,
    /// Node tokens in **symbol slot order**, already permuted for XSPICE and already
    /// truncated to the symbol's terminal count. Borrowed from the classifier.
    nodes: []const TokIdx,
    /// **Every** `k=v` token on the card, in source order, whatever the kind.
    ///
    /// Uniform rather than per-element-type: a subckt instance's overrides, a
    /// transistor's `w=`/`l=`, and a resistor's `tc1=` are all collected the same way.
    /// Collecting them unconditionally costs one pass over tokens that were already being
    /// walked, and it removes a per-letter rule about which cards carry parameters — the
    /// Rust original gathered them only where it happened to need them, which is why
    /// `w=1u` on a resistor was invisible there.
    ///
    /// Duplicate keys are kept in order; the last one wins, which is what a scope's
    /// append-and-reverse-scan lookup gives for free. Borrowed from the classifier.
    args: []const Arg,
    /// Meaningful when `kind` is `.ignored` or `.skipped`.
    reason: Reason,
};

/// A `.subckt` / `subckt` … `.ends` / `ends` boundary.
///
/// Recognized without consulting the definition table, because splitting bodies out of
/// the line stream happens before any class resolution: the splitter needs to know where
/// a body starts and ends, and nothing more.
pub const Boundary = union(enum) {
    begin: Begin,
    end,

    pub const Begin = struct {
        /// Master name, interned folded — this is the key definitions are looked up by.
        name: StrId,
        /// Formal ports in declaration order. Bare tokens only: `k=v` tokens are
        /// parameters and parentheses are punctuation. Borrowed from the classifier.
        ports: []const TokIdx,
        /// Default parameter values from the definition line. Borrowed from the
        /// classifier.
        params: []const Arg,
    };
};

/// Model name → declared type, from `.model` cards.
///
/// A foundry deck names the model, never the type: `M1 d g s b nmos_1v8` only resolves
/// because `.model nmos_1v8 nmos(…)` said what `nmos_1v8` is. Both columns are interned
/// (folded), and the table is **sorted by the `name` StrId** so lookup is a binary
/// search.
///
/// Sorting by StrId rather than by bytes is deliberate and is still deterministic: equal
/// strings intern to equal ids, ids are assigned in first-intern order, and first-intern
/// order is a function of the input. It avoids a string compare per probe, and it avoids
/// the hash map whose iteration order the determinism rule forbids.
pub const Models = struct {
    name: []StrId,
    ty: []StrId,

    pub const empty: Models = .{ .name = &.{}, .ty = &.{} };

    /// Release both columns.
    pub fn deinit(self: *Models, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.ty);
        self.* = .empty;
    }

    /// Declared type of `model`, or null when no `.model` card named it.
    pub fn typeOf(self: Models, model: StrId) ?StrId {
        const i = std.sort.binarySearch(StrId, self.name, model, orderStrId) orelse return null;
        return self.ty[i];
    }

    fn orderStrId(needle: StrId, a: StrId) std.math.Order {
        return std.math.order(@intFromEnum(needle), @intFromEnum(a));
    }

    /// One `.model` card's two interned columns, before the sort splits them apart.
    const Pair = struct {
        name: StrId,
        ty: StrId,

        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return @intFromEnum(a.name) < @intFromEnum(b.name);
        }
    };

    /// Scan every statement for `.model` cards and build the table.
    ///
    /// Run over the **whole** deck before subckt bodies are split out, because a
    /// `.model` inside a definition resolves transistors anywhere in the deck — SPICE
    /// gives models global scope regardless of where they are written.
    ///
    /// The type token may arrive with its parameter list glued on (`nmos(level=1`), so
    /// the type is the leading run of alphanumerics and underscores. A card with fewer
    /// than three tokens, or an empty type, is skipped silently — it is a malformed
    /// `.model`, which is an analysis concern this reader has no opinion about.
    ///
    /// A duplicate model name keeps the **first** definition, matching the usual
    /// simulator behavior of warning and ignoring the redefinition.
    ///
    /// Interns into `interner`, so the pool grows by one entry per distinct model name
    /// and type. Caller owns the result and must `deinit` it. Errors: `OutOfMemory`; on
    /// failure nothing leaks and the interner is left usable.
    ///
    /// Complexity: one pass plus one sort, O(n log n) in `.model` card count.
    pub fn collect(
        gpa: Allocator,
        interner: *Interner,
        toks: Tokens,
    ) Allocator.Error!Models {
        var list: std.ArrayList(Pair) = .empty;
        defer list.deinit(gpa);

        var i: usize = 0;
        while (i < toks.lineCount()) : (i += 1) {
            const l = LineIdx.at(i);
            if (!toks.headIs(l, ".model")) continue;
            const t1 = toks.tok(l, 1) orelse continue;
            const t2 = toks.tok(l, 2) orelse continue;
            // The type token may arrive with its parameter list glued on: `nmos(level=1`.
            const raw = toks.text(t2);
            var n: usize = 0;
            while (n < raw.len and (std.ascii.isAlphanumeric(raw[n]) or raw[n] == '_')) n += 1;
            if (n == 0) continue;

            const name = try interner.internFold(gpa, toks.text(t1));
            // A redefinition is warned about and ignored by every simulator; keep the first.
            // ponytail: linear dup scan over a table with a handful of entries.
            for (list.items) |p| {
                if (p.name == name) break;
            } else {
                const ty = try interner.internFold(gpa, raw[0..n]);
                try list.append(gpa, .{ .name = name, .ty = ty });
            }
        }

        std.mem.sort(Pair, list.items, {}, Pair.lessThan);
        const names = try gpa.alloc(StrId, list.items.len);
        errdefer gpa.free(names);
        const tys = try gpa.alloc(StrId, list.items.len);
        for (list.items, names, tys) |p, *nm, *ty| {
            nm.* = p.name;
            ty.* = p.ty;
        }
        return .{ .name = names, .ty = tys };
    }
};

/// Classifier state: the read-only tables it consults, plus the scratch buffers whose
/// reuse is what makes classification allocation-free.
///
/// Deinit-complete: `deinit` releases the two scratch buffers. It does **not** release
/// `models`, `symbols`, `toks`, `subs` or `cfg` — all borrowed, all owned by the caller,
/// all required to outlive the classifier.
pub const Classifier = struct {
    /// Borrowed token tables.
    toks: *const Tokens,
    /// Borrowed symbol table, answering for builtins and host classes alike. Every class
    /// decision goes through `host.Table.indexOf` and `host.Table.at`; this module keeps no
    /// class data of its own.
    symbols: *const host.Table,
    /// Borrowed knobs; `pdk.leaf`, `pdk.alias`, `pdk.scan` and `pdk.unknown_as_box` are
    /// all consulted here.
    cfg: *const Config,
    /// Borrowed `.model` table.
    models: Models,
    /// Defined subckt names, folded and **sorted ascending by StrId** for binary search.
    /// Borrowed from the definition table. Empty during phase 1, when no definition has
    /// been closed yet, which is why boundary detection must not consult it.
    subs: []const StrId,
    /// Interner used to fold names for lookup. Mutable because a name met for the first
    /// time is interned; that growth is bounded by the deck's distinct identifier count.
    interner: *Interner,

    /// Node scratch, reused per card. Grown monotonically to the widest card in the deck.
    node_buf: std.ArrayList(TokIdx) = .empty,
    /// `k=v` scratch, reused per card.
    arg_buf: std.ArrayList(Arg) = .empty,
    /// Value-text scratch, reused per card. Holds synthesized labels (`W=1u/L=0.1u`,
    /// joined source tails, PDK flavours) with `{…}` still unresolved.
    value_buf: std.ArrayList(u8) = .empty,

    /// Release the three scratch buffers. Leaves every borrowed table alone.
    pub fn deinit(self: *Classifier, gpa: Allocator) void {
        self.node_buf.deinit(gpa);
        self.arg_buf.deinit(gpa);
        self.value_buf.deinit(gpa);
    }

    /// Classify statement `l`.
    ///
    /// Dispatches on dialect, then on the head token. The returned `Card` borrows this
    /// classifier's scratch buffers, so its `nodes` and `value` are invalidated by the
    /// next `classify`, `boundary` or `paramAssignments` call — consume the card before
    /// classifying the next line.
    ///
    /// Never fails on malformed input: a card that cannot be represented comes back with
    /// `kind == .skipped` and a reason. Errors: `OutOfMemory` only, from scratch growth
    /// or from interning a name for lookup.
    ///
    /// A statement with a head that is neither a dot card, a known element letter, nor a
    /// Spectre instance is `.skipped` with `unknown_class` rather than dropped, because
    /// silently ignoring a line that looks like a device is how a schematic quietly loses
    /// half its circuit.
    pub fn classify(self: *Classifier, gpa: Allocator, l: LineIdx) Allocator.Error!Card {
        self.node_buf.clearRetainingCapacity();
        self.arg_buf.clearRetainingCapacity();
        self.value_buf.clearRetainingCapacity();

        const off, const len = self.toks.lineSpan(l);
        const from, const to = self.toks.range(l);
        var c: Card = .{
            .kind = .skipped,
            .off = off,
            .len = len,
            .name = "",
            .symbol = SymbolIdx.at(0),
            .master = "",
            .value = "",
            .nodes = &.{},
            .args = &.{},
            .reason = .unknown_class,
        };
        try self.collectArgs(gpa, from, to);

        // The dialect directive is a statement in its own right; the tokenizer already
        // acted on it, so here it is simply dropped by design.
        if (token.langSwitch(self.toks.*, l) != null) {
            c.kind = .ignored;
            c.reason = .analysis_card;
        } else switch (self.toks.langOf(l)) {
            .spice => try self.classifySpice(gpa, l, &c),
            .spectre => try self.classifySpectre(gpa, l, &c),
        }

        c.args = self.arg_buf.items;
        c.nodes = self.node_buf.items;
        c.value = self.value_buf.items;
        return c;
    }

    /// Gather every `k=v` token in `[from, to)` into `arg_buf`, in source order.
    ///
    /// Unconditional rather than per-element-type: it is one pass over tokens already
    /// being walked, and it removes the per-letter rule that made `w=1u` on a resistor
    /// invisible in the Rust original.
    fn collectArgs(self: *Classifier, gpa: Allocator, from: u32, to: u32) Allocator.Error!void {
        var k = from;
        while (k < to) : (k += 1) {
            const t = TokIdx.at(k);
            const s = self.toks.text(t);
            const kv = splitKv(s) orelse continue;
            const t_off, _ = self.toks.span(t);
            try self.arg_buf.append(gpa, .{
                .key = try self.interner.internFold(gpa, kv[0]),
                .off = t_off + @as(u32, @intCast(kv[0].len)) + 1,
                .len = @intCast(kv[1].len),
            });
        }
    }

    /// Value of the first argument whose folded key is `key`, as a source span, or null.
    fn argValue(self: Classifier, key: []const u8) ?[]const u8 {
        for (self.arg_buf.items) |a| {
            if (std.mem.eql(u8, self.interner.get(a.key), key)) {
                return self.toks.src[a.off..][0..a.len];
            }
        }
        return null;
    }

    /// Append tokens `[from, to)` to `value_buf`, space separated.
    fn appendJoin(self: *Classifier, gpa: Allocator, from: u32, to: u32) Allocator.Error!void {
        var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &self.value_buf);
        defer self.value_buf = aw.toArrayList();
        self.toks.joinRange(from, to, &aw.writer) catch return error.OutOfMemory;
    }

    fn appendBytes(self: *Classifier, gpa: Allocator, s: []const u8) Allocator.Error!void {
        try self.value_buf.appendSlice(gpa, s);
    }

    /// Record `n` node tokens starting at `first`, in card order.
    fn takeNodes(self: *Classifier, gpa: Allocator, first: u32, n: u32) Allocator.Error!void {
        try self.node_buf.ensureUnusedCapacity(gpa, n);
        var k: u32 = 0;
        while (k < n) : (k += 1) self.node_buf.appendAssumeCapacity(TokIdx.at(first + k));
    }

    fn classifySpice(self: *Classifier, gpa: Allocator, l: LineIdx, c: *Card) Allocator.Error!void {
        const head = self.toks.head(l);
        const from, const to = self.toks.range(l);
        const ntok = to - from;

        if (head[0] == '.') {
            c.kind = .ignored;
            c.reason = if (std.ascii.eqlIgnoreCase(head, ".model"))
                .model_card
            else if (std.ascii.eqlIgnoreCase(head, ".option") or std.ascii.eqlIgnoreCase(head, ".options"))
                .option_card
            else if (std.ascii.eqlIgnoreCase(head, ".param")) blk: {
                c.kind = .param_def;
                break :blk .param_card;
            } else .analysis_card;
            return;
        }
        c.name = head;

        switch (std.ascii.toLower(head[0])) {
            // Passive two-terminals. The third token is the value for R/C/L; a diode's
            // model token is not a value and is dropped.
            'r', 'c', 'l', 'd' => {
                if (ntok < 3) return;
                const letter = std.ascii.toLower(head[0]);
                const class: []const u8 = switch (letter) {
                    'r' => "res",
                    'c' => "cap",
                    'l' => "ind",
                    else => "diode",
                };
                const sym = self.symbols.indexOf(class) orelse return;
                if (letter != 'd') {
                    var k = from + 3;
                    while (k < to) : (k += 1) {
                        const s = self.toks.text(TokIdx.at(k));
                        if (isParamTok(s)) continue;
                        try self.appendBytes(gpa, s);
                        break;
                    }
                }
                try self.takeNodes(gpa, from + 1, 2);
                c.kind = .elem;
                c.symbol = sym;
            },
            'v', 'i' => {
                if (ntok < 3) return;
                const sym = self.symbols.indexOf(
                    sourceClass(std.ascii.toLower(head[0]), self.toks.*, from + 3, to),
                ) orelse return;
                // Value is the source spec with `k=v` parameters left out.
                var first = true;
                var k = from + 3;
                while (k < to) : (k += 1) {
                    const s = self.toks.text(TokIdx.at(k));
                    if (isParamTok(s)) continue;
                    if (!first) try self.appendBytes(gpa, " ");
                    try self.appendBytes(gpa, s);
                    first = false;
                }
                try self.takeNodes(gpa, from + 1, 2);
                c.kind = .elem;
                c.symbol = sym;
            },
            // Transistors: the class comes from the model token, strictly a builtin.
            'm', 'q', 'j' => {
                const tc: u32 = 3;
                if (ntok < 1 + tc) return;
                // Right to left: on `M1 d g s vss nmos` the bulk node sits between the
                // source and the model and may be named after a rail, which must never
                // shadow the real model.
                var sym: ?SymbolIdx = null;
                var k = to;
                while (k > from + 1 + tc and sym == null) {
                    k -= 1;
                    const s = self.toks.text(TokIdx.at(k));
                    if (isParamTok(s)) continue;
                    sym = try self.resolveModelToken(gpa, s);
                }
                const class = sym orelse return; // reported as unknown_class

                // A scanned PDK model already wrote its flavour; the sizing follows it.
                const w = self.argValue("w");
                const has_flavour = self.value_buf.items.len > 0;
                if (w) |wv| {
                    if (has_flavour) try self.appendBytes(gpa, " ");
                    try self.appendBytes(gpa, "W=");
                    try self.appendBytes(gpa, wv);
                    if (self.argValue("l")) |lv| {
                        try self.appendBytes(gpa, "/L=");
                        try self.appendBytes(gpa, lv);
                    }
                }
                try self.takeNodes(gpa, from + 1, tc);
                c.kind = .elem;
                c.symbol = class;
            },
            // Controlled and behavioral sources draw their output port; the control
            // nodes and gain ride along in the value rather than becoming pins.
            'e', 'h' => try self.twoNode(gpa, c, "cvsource", from, to),
            'g', 'f' => try self.twoNode(gpa, c, "cisource", from, to),
            'b' => {
                var current = false;
                var k = from;
                while (k < to) : (k += 1) {
                    const s = self.toks.text(TokIdx.at(k));
                    if (s.len >= 2 and std.ascii.eqlIgnoreCase(s[0..2], "i=")) current = true;
                }
                try self.twoNode(gpa, c, if (current) "isource" else "vsource", from, to);
            },
            's', 'w' => try self.twoNode(gpa, c, "switch", from, to),
            'x' => try self.classifyXinst(gpa, c, from, to),
            'a' => try self.classifyAxspice(gpa, c, from, to),
            't', 'o' => try self.fixedNode(gpa, c, "tline", from, to),
            'z' => try self.fixedNode(gpa, c, "mesfet", from, to),
            'p' => try self.fixedNode(gpa, c, "iopin", from, to),
            // A relationship, not a device: no symbol exists and none should.
            'k' => {
                c.kind = .ignored;
                c.reason = .analysis_card;
            },
            else => {}, // unsupported letter, U/Y included: skipped + unknown_class
        }
    }

    fn twoNode(
        self: *Classifier,
        gpa: Allocator,
        c: *Card,
        class: []const u8,
        from: u32,
        to: u32,
    ) Allocator.Error!void {
        if (to - from < 3) return;
        const sym = self.symbols.indexOf(class) orelse return;
        try self.appendJoin(gpa, from + 3, to);
        try self.takeNodes(gpa, from + 1, 2);
        c.kind = .elem;
        c.symbol = sym;
    }

    fn fixedNode(
        self: *Classifier,
        gpa: Allocator,
        c: *Card,
        class: []const u8,
        from: u32,
        to: u32,
    ) Allocator.Error!void {
        const sym = self.symbols.indexOf(class) orelse return;
        const tc: u32 = self.symbols.at(sym).terminalCount();
        if (to - from < 1 + tc) return;
        try self.appendJoin(gpa, from + 1 + tc, to);
        try self.takeNodes(gpa, from + 1, tc);
        c.kind = .elem;
        c.symbol = sym;
    }

    fn classifyXinst(self: *Classifier, gpa: Allocator, c: *Card, from: u32, to: u32) Allocator.Error!void {
        var bare_end = from + 1;
        while (bare_end < to and !isParamTok(self.toks.text(TokIdx.at(bare_end)))) bare_end += 1;
        if (bare_end == from + 1) return; // no master name at all
        const master_tok = bare_end - 1;
        const nnodes = master_tok - (from + 1);
        const master = self.toks.text(TokIdx.at(master_tok));

        var stack: [Interner.fold_stack_max]u8 = undefined;
        const f = try fold(gpa, master, &stack);
        defer f.deinit(gpa);

        if (try self.resolveClass(gpa, f.s)) |sym| {
            const tc: u32 = self.symbols.at(sym).terminalCount();
            if (nnodes < tc) return;
            try self.takeNodes(gpa, from + 1, tc);
            c.kind = .elem;
            c.symbol = sym;
            return;
        }
        // Checked before `subs` on purpose: a model library almost always defines a
        // `.subckt` for its primitive, and flattening that draws the foundry's parasitic
        // network instead of the transistor the author wrote.
        if (self.cfg.isLeaf(f.s)) {
            const hit = try self.resolveLeaf(gpa, f.s) orelse return;
            const tc: u32 = self.symbols.at(hit[0]).terminalCount();
            if (nnodes < tc) return;
            try self.takeNodes(gpa, from + 1, tc);
            c.kind = .elem;
            c.symbol = hit[0];
            return;
        }
        if (self.interner.find(f.s)) |id| {
            if (std.sort.binarySearch(StrId, self.subs, id, Models.orderStrId) != null) {
                try self.takeNodes(gpa, from + 1, nnodes);
                c.kind = .inst;
                c.master = master;
                return;
            }
        }
        c.reason = .undefined_subckt;
    }

    fn classifyAxspice(self: *Classifier, gpa: Allocator, c: *Card, from: u32, to: u32) Allocator.Error!void {
        if (to - from < 2) return;
        const model = self.toks.text(TokIdx.at(to - 1));

        // Brackets only group ports; the flat order across all groups is what counts.
        var ports: [64]TokIdx = undefined;
        var n: usize = 0;
        var k = from + 1;
        while (k < to - 1) : (k += 1) {
            const t = TokIdx.at(k);
            if (self.toks.kindOf(t) == .punct) continue;
            if (n == ports.len) return;
            ports[n] = t;
            n += 1;
        }

        var stack: [Interner.fold_stack_max]u8 = undefined;
        const f = try fold(gpa, model, &stack);
        defer f.deinit(gpa);
        // `.model myff d_dff` names the primitive; a card may also name one directly.
        const ty = blk: {
            const id = self.interner.find(f.s) orelse break :blk f.s;
            const t = self.models.typeOf(id) orelse break :blk f.s;
            break :blk self.interner.get(t);
        };
        const x = xspiceOf(ty) orelse return;
        const sym = self.symbols.indexOf(x.class) orelse return;

        // Every slot must have a port behind it, or the drawing wires the wrong net.
        try self.node_buf.ensureUnusedCapacity(gpa, x.slots.len);
        for (x.slots) |slot| {
            if (slot >= n) {
                self.node_buf.clearRetainingCapacity();
                return;
            }
            self.node_buf.appendAssumeCapacity(ports[slot]);
        }
        c.kind = .elem;
        c.symbol = sym;
    }

    fn classifySpectre(self: *Classifier, gpa: Allocator, l: LineIdx, c: *Card) Allocator.Error!void {
        const from, const to = self.toks.range(l);
        const t1 = self.toks.tok(l, 1) orelse {
            c.kind = .ignored;
            c.reason = .analysis_card;
            return;
        };
        if (!self.toks.eqlFold(t1, "(")) {
            c.kind = .ignored;
            c.reason = .analysis_card;
            return;
        }
        c.name = self.toks.head(l);

        var rparen = from + 2;
        while (rparen < to and !self.toks.eqlFold(TokIdx.at(rparen), ")")) rparen += 1;
        if (rparen == to) return; // unclosed '('
        if (rparen + 1 >= to) return; // no master
        const nnodes = rparen - (from + 2);
        const master = self.toks.text(TokIdx.at(rparen + 1));

        var stack: [Interner.fold_stack_max]u8 = undefined;
        const f = try fold(gpa, master, &stack);
        defer f.deinit(gpa);

        if (try self.resolveClass(gpa, f.s)) |sym| {
            const tc: u32 = self.symbols.at(sym).terminalCount();
            if (nnodes < tc) return;
            try self.appendBytes(gpa, spectreValue(self.toks.*, rparen + 2, to));
            try self.takeNodes(gpa, from + 2, tc);
            c.kind = .elem;
            c.symbol = sym;
            return;
        }
        if (self.interner.find(f.s)) |id| {
            if (std.sort.binarySearch(StrId, self.subs, id, Models.orderStrId) != null) {
                try self.takeNodes(gpa, from + 2, nnodes);
                c.kind = .inst;
                c.master = master;
                return;
            }
        }
        c.reason = .undefined_subckt;
    }

    /// Resolve one candidate model token to a drawable class.
    ///
    /// `.model` declaration first, then the spelling tables, then — only for a master the
    /// deck marked a PDK leaf — the name scan, whose flavour lands in `value_buf`. A rail
    /// or port class is rejected: a placement role is never what a model name means.
    fn resolveModelToken(self: *Classifier, gpa: Allocator, t: []const u8) Allocator.Error!?SymbolIdx {
        var stack: [Interner.fold_stack_max]u8 = undefined;
        const f = try fold(gpa, t, &stack);
        defer f.deinit(gpa);

        if (self.interner.find(f.s)) |id| {
            if (self.models.typeOf(id)) |ty| {
                if (try self.resolveClass(gpa, self.interner.get(ty))) |sym| {
                    if (self.symbols.at(sym).role == .none) return sym;
                }
            }
        }
        if (try self.resolveClass(gpa, f.s)) |sym| {
            if (self.symbols.at(sym).role == .none) return sym;
            return null;
        }
        if (self.cfg.pdk.scan and self.cfg.isLeaf(f.s)) {
            if (scanMaster(self.symbols, f.s)) |hit| {
                if (self.symbols.at(hit[0]).role != .none) return null;
                var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &self.value_buf);
                defer self.value_buf = aw.toArrayList();
                writeFlavour(hit[1], &aw.writer) catch return error.OutOfMemory;
                return hit[0];
            }
        }
        return null;
    }

    /// Detect a definition boundary, dialect-aware and definition-table-free.
    ///
    /// Recognizes SPICE `.subckt name ports… params…` / `.ends`, Spectre
    /// `subckt name …` / `ends`, and Spectre `inline subckt name …`. Returns null for
    /// anything else. A `.subckt` with no name yields a `begin` whose name is
    /// `StrId.empty` and whose port list is empty rather than failing — a bare
    /// `inline subckt` appears in generated decks and must not take the parser out.
    ///
    /// `ports` and `params` borrow the classifier's scratch, with the same lifetime rule
    /// as `classify`.
    ///
    /// Errors: `OutOfMemory` from interning the master name.
    pub fn boundary(self: *Classifier, gpa: Allocator, l: LineIdx) Allocator.Error!?Boundary {
        const from, const to = self.toks.range(l);
        switch (self.toks.langOf(l)) {
            .spice => {
                if (self.toks.headIs(l, ".subckt") and to - from >= 2) {
                    return .{ .begin = try self.begin(gpa, from + 1, from + 2, to) };
                }
                if (self.toks.headIs(l, ".ends")) return .end;
                return null;
            },
            .spectre => {
                if (self.toks.headIs(l, "subckt") and to - from >= 2) {
                    return .{ .begin = try self.begin(gpa, from + 1, from + 2, to) };
                }
                if (self.toks.headIs(l, "inline")) {
                    const t1 = self.toks.tok(l, 1) orelse return null;
                    if (!self.toks.eqlFold(t1, "subckt")) return null;
                    // A bare `inline subckt` with no name appears in generated decks and
                    // must yield an empty definition rather than take the parser out.
                    const name_tok: ?u32 = if (to - from >= 3) from + 2 else null;
                    return .{ .begin = try self.begin(gpa, name_tok, @min(from + 3, to), to) };
                }
                if (self.toks.headIs(l, "ends")) return .end;
                return null;
            },
        }
    }

    /// Shared tail of every `begin` spelling: intern the master name, then split the
    /// remaining tokens into bare ports and `k=v` defaults.
    fn begin(
        self: *Classifier,
        gpa: Allocator,
        name_tok: ?u32,
        split_from: u32,
        to: u32,
    ) Allocator.Error!Boundary.Begin {
        self.node_buf.clearRetainingCapacity();
        self.arg_buf.clearRetainingCapacity();

        const name: StrId = if (name_tok) |t|
            try self.interner.internFold(gpa, self.toks.text(TokIdx.at(t)))
        else
            .empty;

        var k = split_from;
        while (k < to) : (k += 1) {
            const t = TokIdx.at(k);
            const s = self.toks.text(t);
            if (isParamTok(s)) continue;
            if (self.toks.kindOf(t) == .punct) continue;
            try self.node_buf.append(gpa, t);
        }
        try self.collectArgs(gpa, split_from, to);
        return .{ .name = name, .ports = self.node_buf.items, .params = self.arg_buf.items };
    }

    /// True when `l` is a parameter definition: SPICE `.param`, Spectre `parameters`.
    ///
    /// Kept separate from `classify` because the emitter handles these itself — they
    /// mutate the scope in source order and never become a device.
    pub fn isParamDef(self: Classifier, l: LineIdx) bool {
        return switch (self.toks.langOf(l)) {
            .spice => self.toks.headIs(l, ".param"),
            .spectre => self.toks.headIs(l, "parameters"),
        };
    }

    /// The `k=v` assignments on a parameter-definition line, everything after the
    /// keyword.
    ///
    /// Borrows the classifier's arg scratch. Order is source order, which matters: a
    /// later assignment on the same line shadows an earlier one, and `.param a=1 a=2`
    /// must end at 2.
    pub fn paramAssignments(self: *Classifier, gpa: Allocator, l: LineIdx) Allocator.Error![]const Arg {
        self.arg_buf.clearRetainingCapacity();
        const from, const to = self.toks.range(l);
        try self.collectArgs(gpa, from + 1, to);
        return self.arg_buf.items;
    }

    /// Resolve a master or model name to a builtin symbol.
    ///
    /// Precedence, highest first: the deck's `[pdk] alias` table, then the local `alias`
    /// spelling map, then the class table itself. The config wins so a house spelling
    /// (`nch` → `nmos`) beats both built-in tables, which is the whole point of having
    /// the knob.
    ///
    /// `name` is folded before lookup. Returns null when nothing maps it. Errors:
    /// `OutOfMemory` from folding a name longer than the stack fold buffer.
    pub fn resolveClass(self: *Classifier, gpa: Allocator, name: []const u8) Allocator.Error!?SymbolIdx {
        var stack: [Interner.fold_stack_max]u8 = undefined;
        const f = try fold(gpa, name, &stack);
        defer f.deinit(gpa);

        // The deck's own table wins, so a house spelling beats both built-in tables —
        // which is the entire point of having the knob.
        if (self.cfg.aliasOf(f.s)) |mapped| return self.symbols.indexOf(mapped);
        if (alias.get(f.s)) |canon| return self.symbols.indexOf(canon);
        return self.symbols.indexOf(f.s);
    }

    /// Full resolution for a master the deck marked as a PDK leaf.
    ///
    /// `resolveClass`, then (when `pdk.scan`) the name scan, then (when
    /// `pdk.unknown_as_box`) the `generic` box class carrying the master name as its
    /// value — so an unrecognized foundry device and its connectivity stay on the page
    /// instead of vanishing. Returns null only when every fallback is disabled or absent.
    ///
    /// The returned flavour text borrows the classifier's value scratch.
    pub fn resolveLeaf(
        self: *Classifier,
        gpa: Allocator,
        master: []const u8,
    ) Allocator.Error!?struct { SymbolIdx, []const u8 } {
        if (try self.resolveClass(gpa, master)) |sym| return .{ sym, "" };
        if (self.cfg.pdk.scan) {
            if (scanMaster(self.symbols, master)) |hit| {
                self.value_buf.clearRetainingCapacity();
                var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &self.value_buf);
                {
                    defer self.value_buf = aw.toArrayList();
                    writeFlavour(hit[1], &aw.writer) catch return error.OutOfMemory;
                }
                return .{ hit[0], self.value_buf.items };
            }
        }
        // An unrecognized foundry device stays on the page as a labelled box, so its
        // connectivity survives instead of vanishing.
        if (self.cfg.pdk.unknown_as_box) {
            if (self.symbols.indexOf("generic")) |sym| {
                self.value_buf.clearRetainingCapacity();
                try self.value_buf.appendSlice(gpa, master);
                return .{ sym, self.value_buf.items };
            }
        }
        return null;
    }
};

/// Foreign primitive spelling → builtin class name.
///
/// A translation table, not a device vocabulary: Spectre and some SPICE dialects spell
/// primitives differently from the CircuiTikZ class set the catalog uses. Only
/// unambiguous entries appear — polarity-ambiguous names (`bjt`, `mos`) are deliberately
/// absent so that a deck using them is *reported* rather than silently drawn with a
/// guessed polarity.
pub const alias = std.StaticStringMap([]const u8).initComptime(.{
    .{ "resistor", "res" },
    .{ "capacitor", "cap" },
    .{ "inductor", "ind" },
    .{ "vsource", "vsource" },
    .{ "isource", "isource" },
    .{ "diode", "diode" },
    .{ "vcvs", "cvsource" },
    .{ "vccs", "cisource" },
    .{ "cccs", "cisource" },
    .{ "ccvs", "cvsource" },
    .{ "relay", "switch" },
    .{ "switch", "switch" },
});

/// One XSPICE digital primitive: its model type, the builtin class that draws it, and the
/// permutation from XSPICE port order to symbol slot order.
///
/// The permutation is the whole reason this table exists. `d_dff` exposes
/// `data clk set reset out nout`; the `dff` symbol wants `d clk q qb`; hence `{0,1,4,5}`.
/// Combinational gates list inputs then output, while the `GATE2` slot order is
/// in1/out/in2, so the output — the last XSPICE port — lands in the middle.
pub const Xspice = struct {
    model: []const u8,
    class: []const u8,
    slots: []const u8,
};

/// XSPICE models with a clean port mapping.
///
/// Only primitives whose ports map without inventing one are listed.
/// `adc_bridge`/`dac_bridge` carry no clock port, so they would have to fabricate a
/// terminal; they stay unresolved and are reported, which is the honest answer.
pub const xspice = [_]Xspice{
    .{ .model = "d_dff", .class = "dff", .slots = &.{ 0, 1, 4, 5 } },
    .{ .model = "d_dlatch", .class = "dlatch", .slots = &.{ 0, 1, 4, 5 } },
    .{ .model = "d_jkff", .class = "jkff", .slots = &.{ 0, 1, 2, 5, 6 } },
    .{ .model = "d_srff", .class = "srff", .slots = &.{ 0, 1, 2, 5, 6 } },
    .{ .model = "d_and", .class = "andgate", .slots = &.{ 0, 2, 1 } },
    .{ .model = "d_nand", .class = "nandgate", .slots = &.{ 0, 2, 1 } },
    .{ .model = "d_or", .class = "orgate", .slots = &.{ 0, 2, 1 } },
    .{ .model = "d_nor", .class = "norgate", .slots = &.{ 0, 2, 1 } },
    .{ .model = "d_xor", .class = "xorgate", .slots = &.{ 0, 2, 1 } },
    .{ .model = "d_xnor", .class = "xnorgate", .slots = &.{ 0, 2, 1 } },
    .{ .model = "d_inverter", .class = "notgate", .slots = &.{ 0, 1 } },
    .{ .model = "d_buffer", .class = "buffergate", .slots = &.{ 0, 1 } },
    .{ .model = "d_tristate", .class = "tristate", .slots = &.{ 0, 1, 2 } },
};

/// Look up an XSPICE model type. Linear scan over thirteen entries — a binary search
/// would need the table sorted for no measurable gain at this size.
pub fn xspiceOf(model: []const u8) ?Xspice {
    for (xspice) |x| {
        if (std.ascii.eqlIgnoreCase(x.model, model)) return x;
    }
    return null;
}

/// A folded name, on the stack when it fits and on the heap when it does not.
///
/// The stack case is every real identifier; the heap case exists so a pathological name
/// fails with `OutOfMemory` rather than being silently truncated into a different name.
const Folded = struct {
    s: []const u8,
    heap: ?[]u8,

    fn deinit(self: Folded, gpa: Allocator) void {
        if (self.heap) |h| gpa.free(h);
    }
};

fn fold(gpa: Allocator, name: []const u8, stack: *[Interner.fold_stack_max]u8) Allocator.Error!Folded {
    const heap: ?[]u8 = if (name.len > stack.len) try gpa.alloc(u8, name.len) else null;
    const dst = heap orelse stack[0..name.len];
    for (dst, name) |*d, ch| d.* = std.ascii.toLower(ch);
    return .{ .s = dst, .heap = heap };
}

/// True when `t` is a `k=v` assignment rather than a bare token.
///
/// The test is simply "contains `=`", matching every SPICE dialect's own lexing. A token
/// that is exactly `=` counts as an assignment with an empty key and is rejected by
/// `splitKv`.
pub fn isParamTok(t: []const u8) bool {
    return std.mem.indexOfScalar(u8, t, '=') != null;
}

/// Split `k=v` at the first `=`.
///
/// Returns null when there is no `=` or when the key would be empty. Both halves are
/// subslices of `t`; borrowed, no allocation, and the key is **not** folded here — the
/// caller folds when it interns.
pub fn splitKv(t: []const u8) ?struct { []const u8, []const u8 } {
    const i = std.mem.indexOfScalar(u8, t, '=') orelse return null;
    if (i == 0) return null;
    return .{ t[0..i], t[i + 1 ..] };
}

/// Class name for a `V` or `I` card, from the tokens after its two nodes.
///
/// A token starting with `sin` (case-insensitive) means a sinusoidal source; a standalone
/// `ac` token means an AC source; anything else is plain DC. Voltage sources have all
/// three variants (`vsourcesin`, `vsourceac`, `vsource`); current sources have two
/// (`isourceac`, `isource`), since the catalog has no sinusoidal current symbol.
///
/// `letter` is the card's first character, folded to lowercase by the caller. Returns a
/// static name; no allocation.
pub fn sourceClass(letter: u8, toks: Tokens, from: u32, to: u32) []const u8 {
    var has_ac = false;
    var sine = false;
    var k = from;
    while (k < to) : (k += 1) {
        const s = toks.text(TokIdx.at(k));
        if (std.ascii.eqlIgnoreCase(s, "ac")) has_ac = true;
        if (s.len >= 3 and std.ascii.eqlIgnoreCase(s[0..3], "sin")) sine = true;
    }
    if (letter == 'v') {
        if (sine) return "vsourcesin";
        if (has_ac) return "vsourceac";
        return "vsource";
    }
    // The catalog has no sinusoidal current symbol, so a current source has two forms.
    return if (has_ac) "isourceac" else "isource";
}

/// Resolve a foundry master by finding a class name inside it.
///
/// `sky130_fd_pr__nfet_01v8_lvt` → (`nfet`, tail `_01v8_lvt`). Modern foundry decks name
/// every device after what it is, which is what makes this work at all and what lets it
/// replace a per-PDK translation file.
///
/// The **longest** class name occurring in `master` wins, so `nfet` beats `fet` and
/// `thermistorntc` beats `res`; a shorter match would classify half a foundry deck as
/// resistors. Ties — impossible for distinct names of equal length matching the same
/// position, but possible across positions — break on the lower `SymbolIdx`, which keeps
/// the answer a function of table order rather than of scan order.
///
/// Only `SymbolRole.none` classes are candidates: a rail or a port is a placement role,
/// never what a device name means.
///
/// Every class in `symbols` is enumerated, builtins then host classes, so a host-registered
/// primitive is scannable exactly like a builtin. One pass keeping the best match rather
/// than a length-sorted candidate table — a sort would need building and storing, for a
/// function called once per unresolved master.
///
/// Returns the matched symbol and the **tail** after the class token, borrowed from
/// `master`. The tail is what distinguishes a device from its siblings; `writeFlavour`
/// turns it into the label. What precedes the class token is the process prefix, identical
/// across the whole deck and worth nothing on a drawing.
///
/// Allocation-free. O(classes × master length) and called once per unresolved master.
pub fn scanMaster(symbols: *const host.Table, master: []const u8) ?struct { SymbolIdx, []const u8 } {
    var best_sym: SymbolIdx = .at(0);
    var best_at: usize = 0;
    var best_len: usize = 0;
    const total = catalog.builtin_count + symbols.count();
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const idx = SymbolIdx.at(i);
        const cls = symbols.at(idx);
        // A rail or a port is a placement role, never what a device name means.
        if (cls.role != .none) continue;
        const at = std.mem.indexOf(u8, master, cls.name) orelse continue;
        // Strictly longer, so a tie keeps the lower `SymbolIdx` and the answer is a
        // function of table order rather than of scan order.
        if (cls.name.len <= best_len) continue;
        best_sym = idx;
        best_at = at;
        best_len = cls.name.len;
    }
    if (best_len == 0) return null;
    return .{ best_sym, master[best_at + best_len ..] };
}

/// Write a scanned master's tail as a device label: `_`- and `.`-separated words joined by
/// single spaces, empty words dropped.
///
/// `_01v8_lvt` becomes `01v8 lvt`. Writer-based so the result lands straight in the
/// classifier's value buffer with no intermediate string. Writes nothing for an empty or
/// all-separator tail.
pub fn writeFlavour(tail: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var it = std.mem.tokenizeAny(u8, tail, "_.");
    var first = true;
    while (it.next()) |word| {
        if (!first) try w.writeByte(' ');
        try w.writeAll(word);
        first = false;
    }
}

/// Spectre passive value: the value of the first `r=`, `c=`, `l=`, `dc=` or `value=`
/// parameter among tokens `[from, to)`.
///
/// Returns a subslice of the source arena, or an empty slice when none is present. Brace
/// expressions are preserved for emit-time resolution.
pub fn spectreValue(toks: Tokens, from: u32, to: u32) []const u8 {
    var k = from;
    while (k < to) : (k += 1) {
        const s = toks.text(TokIdx.at(k));
        const kv = splitKv(s) orelse continue;
        for ([_][]const u8{ "r", "c", "l", "dc", "value" }) |key| {
            if (std.ascii.eqlIgnoreCase(kv[0], key)) return kv[1];
        }
    }
    return "";
}
