//! Zero-copy tokenizer: source bytes in, a flat table of spans out.
//!
//! One pass over the expanded arena produces two SoA tables — a token column set and a
//! logical-line column set — and **not one byte of string data**. Every token is
//! `{ off, len, kind }`: nine bytes of columns, no heap string, no case conversion, no
//! copy. The source arena from `source.zig` is the only place characters live.
//!
//! ## What this replaces
//!
//! The Rust reader allocated a `String` per token and lowercased each one, then stored
//! the reassembled line text a second time for the report. On a 5k-line deck that is
//! tens of thousands of tiny allocations whose entire purpose is to hold bytes that were
//! already in memory, contiguous, one scan earlier. Spans cost 9 bytes and a subtraction.
//!
//! ## Case folding is not this file's job
//!
//! SPICE identifiers are case-insensitive, so *something* has to fold. Doing it here
//! would mean writing new bytes, which means allocating, which is the entire thing being
//! avoided — and it would destroy the original spelling that a diagnostic wants to quote.
//! Folding therefore happens exactly once, later, at `Interner.internFold`, where the
//! result is retained and shared. `text()` returns the identifier **as written**, and
//! `eqlFold` answers case-insensitive comparisons in place. Nothing in this file
//! lowercases anything, and a test pins that by recovering original spelling from a span.
//!
//! ## Kind is an enum, not a bitfield
//!
//! The architecture note sketched `Kind` as a `packed struct(u8)` of flags. It is an
//! `enum(u8)` instead: the categories are mutually exclusive, and a flag set would admit
//! combinations (`word` and `number` at once) that no producer emits and every consumer
//! would have to decide how to handle. Same one byte, fewer impossible states.
//!
//! There is also no `continuation` kind, because no token survives to carry it —
//! continuations are folded into the statement they belong to and the leading `+`
//! disappears. `Line.off`/`Line.len` record the full physical extent of the folded
//! statement, which is what a diagnostic actually needs.
//!
//! ## Dialect handling
//!
//! Both SPICE (ngspice/hspice, which share one *circuit* grammar once analysis cards are
//! dropped) and Spectre are read by the same loop, differing only in comment syntax and
//! which bracket characters split into their own tokens. The active dialect flips on a
//! `simulator lang=` statement and applies to the statement *after* it, since that
//! directive is itself written in the outgoing dialect.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Netlist dialect of one logical line.
///
/// ngspice and hspice both map to `.spice`: their analysis and option cards differ, and
/// those are dropped, leaving identical element grammar. `.spectre` is the
/// parenthesized-node-list form.
pub const Lang = enum(u8) {
    spice,
    spectre,
};

/// Token index. Distinct enum so it cannot be confused with a `LineIdx` or an offset.
pub const TokIdx = enum(u32) {
    _,

    pub fn i(t: TokIdx) usize {
        return @intFromEnum(t);
    }

    pub fn at(n: usize) TokIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// Logical-line index: one per assembled statement, continuations already folded.
pub const LineIdx = enum(u32) {
    _,

    pub fn i(l: LineIdx) usize {
        return @intFromEnum(l);
    }

    pub fn at(n: usize) LineIdx {
        std.debug.assert(n < std.math.maxInt(u32));
        return @enumFromInt(@as(u32, @intCast(n)));
    }
};

/// What a token is, coarsely — enough for the classifier to branch without re-scanning
/// characters, and no more.
pub const Kind = enum(u8) {
    /// An identifier, a model name, a `k=v` assignment, a `{expr}` brace group, or
    /// anything else that is not a number and not a split bracket. The catch-all: the
    /// classifier decides meaning from position, not from kind.
    word,
    /// Starts with an ASCII digit, or with `.` followed by a digit. Deliberately *not*
    /// validated as a number here — `4k7` and `1e-3u` are both SPICE numbers, and
    /// deciding that is `expr.zig`'s job. A leading `.` followed by a letter is a dot
    /// card and stays a `word`.
    number,
    /// A single `(`, `)`, `[` or `]` that was split out of a larger run of characters.
    punct,
};

/// One token: a span into the source arena plus its coarse kind.
///
/// Stored as SoA columns, so a pass that only branches on `kind` touches one byte per
/// token instead of nine.
pub const Token = struct {
    off: u32,
    len: u32,
    kind: Kind,
};

/// One assembled statement: a token range plus the physical extent it came from.
///
/// `off`/`len` cover from the first live byte of the statement's first physical line to
/// the last live byte of its last continuation, so a note against a folded card
/// highlights the whole card. Whitespace and comment text inside that range are included
/// — trimming them would require a second span per physical line for no diagnostic gain.
pub const Line = struct {
    /// First token of this statement.
    tok0: u32,
    /// Token count. Never zero: blank statements are not emitted at all.
    ntok: u32,
    /// Offset of the statement's first live byte in the source arena.
    off: u32,
    /// Byte length of the statement's full physical extent.
    len: u32,
    /// Dialect in force when this statement began.
    lang: Lang,
};

/// The tokenized deck.
///
/// Owns both column tables and **borrows** the source bytes. `src` must outlive this
/// value; every `text()` result aliases it.
pub const Tokens = struct {
    /// Borrowed from the `Source` that produced it; never freed here. An unannotated
    /// slice field is exactly the question a reader should not have to ask, so: this one
    /// is not owned.
    src: []const u8,
    toks: std.MultiArrayList(Token) = .empty,
    lines: std.MultiArrayList(Line) = .empty,

    pub const empty: Tokens = .{ .src = &.{} };

    /// Release both column tables. Does not touch `src`.
    pub fn deinit(self: *Tokens, gpa: Allocator) void {
        self.toks.deinit(gpa);
        self.lines.deinit(gpa);
        self.* = .{ .src = self.src };
    }

    /// Number of logical statements.
    pub fn lineCount(self: Tokens) usize {
        return self.lines.len;
    }

    /// Number of tokens across the whole deck.
    pub fn tokenCount(self: Tokens) usize {
        return self.toks.len;
    }

    /// The bytes of one token, **exactly as written**.
    ///
    /// Borrowed from `src`; valid until the source is released, and never freed here.
    /// Case is preserved — see the module header. Asserts `t` is in range; an
    /// out-of-range token index means it came from a different `Tokens`.
    pub fn text(self: Tokens, t: TokIdx) []const u8 {
        std.debug.assert(t.i() < self.toks.len);
        return self.src[self.toks.items(.off)[t.i()]..][0..self.toks.items(.len)[t.i()]];
    }

    /// Kind of one token.
    pub fn kindOf(self: Tokens, t: TokIdx) Kind {
        std.debug.assert(t.i() < self.toks.len);
        return self.toks.items(.kind)[t.i()];
    }

    /// Span of one token, for building a `Note` without materializing its text.
    pub fn span(self: Tokens, t: TokIdx) struct { u32, u32 } {
        std.debug.assert(t.i() < self.toks.len);
        return .{ self.toks.items(.off)[t.i()], self.toks.items(.len)[t.i()] };
    }

    /// Half-open token range of a statement, as plain subscripts.
    ///
    /// Subscripts rather than `TokIdx` because callers iterate the range and index the
    /// columns; wrapping each step would only be unwrapped again.
    pub fn range(self: Tokens, l: LineIdx) struct { u32, u32 } {
        std.debug.assert(l.i() < self.lines.len);
        const from = self.lines.items(.tok0)[l.i()];
        return .{ from, from + self.lines.items(.ntok)[l.i()] };
    }

    /// Token count of a statement. At least 1.
    pub fn count(self: Tokens, l: LineIdx) u32 {
        std.debug.assert(l.i() < self.lines.len);
        return self.lines.items(.ntok)[l.i()];
    }

    /// The `k`-th token of statement `l`, or null when `l` has fewer than `k + 1`.
    ///
    /// Returning an optional rather than asserting: "does this card have a fourth token"
    /// is the classifier's most common question and a data condition, not a bug.
    pub fn tok(self: Tokens, l: LineIdx, k: u32) ?TokIdx {
        const from, const to = self.range(l);
        if (from + k >= to) return null;
        return TokIdx.at(from + k);
    }

    /// Text of statement `l`'s first token — the discriminant every classifier branches
    /// on. Empty slice is impossible; a statement always has at least one token.
    ///
    /// Borrowed from `src`. Case as written: compare with `headIs`, not `mem.eql`.
    pub fn head(self: Tokens, l: LineIdx) []const u8 {
        return self.text(self.tok(l, 0).?);
    }

    /// True when statement `l`'s first token equals `lit`, ASCII-case-insensitively.
    ///
    /// The comparison every dot-card check wants. Allocation-free: compares in place,
    /// folding one byte at a time, so no scratch buffer and no early exit on length
    /// beyond the obvious.
    pub fn headIs(self: Tokens, l: LineIdx, lit: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.head(l), lit);
    }

    /// True when token `t` equals `lit`, ASCII-case-insensitively. Allocation-free.
    pub fn eqlFold(self: Tokens, t: TokIdx, lit: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.text(t), lit);
    }

    /// Dialect of statement `l`.
    pub fn langOf(self: Tokens, l: LineIdx) Lang {
        std.debug.assert(l.i() < self.lines.len);
        return self.lines.items(.lang)[l.i()];
    }

    /// Physical span of statement `l`, for a `Note`.
    pub fn lineSpan(self: Tokens, l: LineIdx) struct { u32, u32 } {
        std.debug.assert(l.i() < self.lines.len);
        return .{ self.lines.items(.off)[l.i()], self.lines.items(.len)[l.i()] };
    }

    /// Write tokens `[from, to)` to `w`, single-space separated.
    ///
    /// How a device *value* is reassembled: the classifier keeps a token range and the
    /// emitter joins it, so the "value text" of a card never exists until somebody wants
    /// it, and then it exists exactly once. Writes nothing when the range is empty, and
    /// emits no leading or trailing space.
    ///
    /// Asserts `from <= to` and that `to` is within the token table.
    pub fn joinRange(self: Tokens, from: u32, to: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
        std.debug.assert(from <= to);
        std.debug.assert(to <= self.toks.len);
        var k = from;
        while (k < to) : (k += 1) {
            if (k != from) try w.writeByte(' ');
            try w.writeAll(self.text(TokIdx.at(k)));
        }
    }

    /// Check: token spans lie inside `src`, `lines` token ranges tile the token table in
    /// ascending order with no gaps or overlaps, and every statement has at least one
    /// token.
    ///
    /// Panics on violation. Tiling is load-bearing — a gap would silently drop a card.
    pub fn assertValid(self: Tokens) void {
        for (self.toks.items(.off), self.toks.items(.len)) |off, len| {
            std.debug.assert(@as(usize, off) + len <= self.src.len);
        }
        var next: u32 = 0;
        for (self.lines.items(.tok0), self.lines.items(.ntok)) |tok0, ntok| {
            std.debug.assert(ntok >= 1);
            std.debug.assert(tok0 == next); // tiling: no gap would silently drop a card
            next = tok0 + ntok;
        }
        std.debug.assert(next == self.toks.len);
    }
};

/// Assemble `src` into logical lines of tokens.
///
/// One pass. The rules, in the order they apply to each physical line:
///
/// 1. **Continuation detection, before comment stripping.** A line whose first non-space
///    character is `+` continues the previous statement; so does any line following one
///    whose live part ended in `\` (Spectre); so does any line inside an open
///    `/* … */` block. This is decided first because flushing the previous statement is
///    what applies a pending `simulator lang=` switch, and the current line must be
///    stripped in the dialect that switch selected.
/// 2. **Comment stripping**, per dialect. SPICE: a `*` as the first non-space character
///    kills the line; `$` or `;` anywhere begins an inline comment and the rest is cut.
///    Spectre: a leading `*` kills the line; `//` cuts to end of line; `/* … */` is
///    removed, and an unterminated open block swallows following lines until `*/`. An
///    inline *closed* block drops the block and any text after it on that line, which is
///    a deliberate simplification — no circuit statement in the fixture set puts live
///    code after a closed block.
/// 3. **Marker removal.** A leading `+` and a trailing `\` are dropped from the body.
/// 4. **Splitting.** Whitespace splits tokens. In Spectre, `(` and `)` are additionally
///    split out as standalone `punct` tokens because a Spectre element is recognized by a
///    `(` in slot 1. In SPICE, `[` and `]` are split out for the same reason on XSPICE
///    `A` cards (`a1 [d clk] [q qb] mydff`).
/// 5. **Blank statements are dropped**, so a `Line` always has at least one token and no
///    consumer needs a bounds check before reading `head`.
///
/// A `simulator lang=spectre` / `=spice` statement both switches the dialect and is
/// emitted (the classifier reports it as ignored). The switch takes effect on the *next*
/// statement. Recognition tolerates the token splits `simulator lang=spectre`,
/// `simulator lang = spectre`, because the check is done on the concatenation of the
/// statement's tokens.
///
/// A continuation with no open statement — which happens when a block comment sat between
/// two statements — starts a fresh statement with whatever live text it has, rather than
/// dropping it.
///
/// `src` is borrowed: the result holds spans into it, and it must outlive the returned
/// `Tokens`. Caller owns the returned tables and must `deinit` them.
///
/// Errors: `OutOfMemory` only. There is no such thing as malformed input at this level —
/// every byte either becomes a token or is a comment. On failure nothing leaks.
///
/// Complexity: single pass, O(bytes). Two amortized-growth arrays, no per-token
/// allocation.
pub fn tokenize(gpa: Allocator, src: []const u8) Allocator.Error!Tokens {
    var self: Tokens = .{ .src = src };
    errdefer self.deinit(gpa);

    var lang: Lang = .spice;
    var in_block = false;
    var backslash = false;

    // The statement being accumulated. Tokens go straight into the column table, so
    // "pending" is four integers rather than a buffer: the statement's tokens are
    // contiguous because nothing else appends between its physical lines.
    var open = false;
    var tok0: u32 = 0;
    var off: u32 = 0;
    var end: u32 = 0;
    var st_lang: Lang = .spice;

    var pos: usize = 0;
    while (pos < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const raw = src[pos..nl];
        const raw_off: u32 = @intCast(pos);
        pos = if (nl < src.len) nl + 1 else src.len;

        // Continuation is decided before stripping: flushing the previous statement is
        // what applies a pending `simulator lang=`, and this line must be stripped in
        // whichever dialect that leaves active.
        const was_block = in_block;
        const trimmed_start = std.mem.trimStart(u8, raw, " \t\r");
        const is_plus = trimmed_start.len > 0 and trimmed_start[0] == '+';
        const cont = is_plus or backslash or was_block;
        if (!cont) {
            if (open) {
                if (self.toks.len > tok0) {
                    try self.lines.append(gpa, .{
                        .tok0 = tok0,
                        .ntok = @intCast(self.toks.len - tok0),
                        .off = off,
                        .len = end - off,
                        .lang = st_lang,
                    });
                    if (langSwitch(self, LineIdx.at(self.lines.len - 1))) |nl_lang| lang = nl_lang;
                }
                open = false;
            }
        }

        const live = livePart(raw, lang, &in_block);
        backslash = std.mem.endsWith(u8, std.mem.trimEnd(u8, live, " \t\r"), "\\");

        var body = if (is_plus) blk: {
            const lt = std.mem.trimStart(u8, live, " \t\r");
            break :blk if (lt.len > 0 and lt[0] == '+') lt[1..] else lt;
        } else live;
        body = std.mem.trimEnd(u8, body, " \t\r");
        if (std.mem.endsWith(u8, body, "\\")) body = body[0 .. body.len - 1];
        body = std.mem.trim(u8, body, " \t\r");

        if (body.len == 0) continue;

        const body_off: u32 = raw_off + @as(u32, @intCast(@intFromPtr(body.ptr) - @intFromPtr(raw.ptr)));
        if (!open) {
            // A continuation with no open statement (a block comment sat between two
            // statements) starts a fresh one rather than losing its live text.
            open = true;
            tok0 = @intCast(self.toks.len);
            off = body_off;
            st_lang = lang;
        }
        end = body_off + @as(u32, @intCast(body.len));
        try splitInto(gpa, &self, body, body_off, st_lang);
    }
    if (open and self.toks.len > tok0) {
        try self.lines.append(gpa, .{
            .tok0 = tok0,
            .ntok = @intCast(self.toks.len - tok0),
            .off = off,
            .len = end - off,
            .lang = st_lang,
        });
    }
    return self;
}

/// Whitespace-split `body` into tokens, additionally breaking the dialect's bracket
/// characters out on their own.
///
/// The Rust reader spliced spaces around brackets and re-split the copy; here the split is
/// done in the scan, so no byte is ever rewritten and every token stays a span.
fn splitInto(gpa: Allocator, self: *Tokens, body: []const u8, base: u32, lang: Lang) Allocator.Error!void {
    const brackets: []const u8 = switch (lang) {
        .spice => "[]",
        .spectre => "()",
    };
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }
        const start = i;
        if (std.mem.indexOfScalar(u8, brackets, c) != null) {
            i += 1;
        } else {
            while (i < body.len) : (i += 1) {
                const d = body[i];
                if (d == ' ' or d == '\t' or d == '\r') break;
                if (std.mem.indexOfScalar(u8, brackets, d) != null) break;
            }
        }
        const s = body[start..i];
        try self.toks.append(gpa, .{
            .off = base + @as(u32, @intCast(start)),
            .len = @intCast(s.len),
            .kind = kindOfBytes(s),
        });
    }
}

/// The live part of one physical line under `lang`, with comments removed.
///
/// `in_block` tracks an open Spectre `/* … */` across calls: true on entry means the line
/// starts inside a block, and it is updated on exit. SPICE ignores it.
///
/// Returns a subslice of `raw` (possibly empty). Borrowed; allocates nothing. Exposed
/// because comment handling is the part of assembly with the most dialect-specific
/// behavior and pinning it directly beats inferring it from token output.
pub fn livePart(raw: []const u8, lang: Lang, in_block: *bool) []const u8 {
    switch (lang) {
        .spice => {
            const t = std.mem.trimStart(u8, raw, " \t\r");
            if (t.len > 0 and t[0] == '*') return raw[0..0];
            const cut = std.mem.indexOfAny(u8, raw, "$;") orelse raw.len;
            return raw[0..cut];
        },
        .spectre => {
            var s = raw;
            if (in_block.*) {
                const p = std.mem.indexOf(u8, s, "*/") orelse return raw[0..0];
                s = s[p + 2 ..];
                in_block.* = false;
            }
            const t = std.mem.trimStart(u8, s, " \t\r");
            if (t.len > 0 and t[0] == '*') return raw[0..0];
            const cut = std.mem.indexOf(u8, s, "//") orelse s.len;
            s = s[0..cut];
            if (std.mem.indexOf(u8, s, "/*")) |a| {
                // A closed inline block drops the block and everything after it on this
                // line; an open one swallows the following lines instead.
                if (std.mem.indexOf(u8, s[a + 2 ..], "*/") == null) in_block.* = true;
                return s[0..a];
            }
            return s;
        },
    }
}

/// Which dialect a statement's tokens switch to, if any.
///
/// Recognizes a first token of `simulator` (case-insensitive) whose statement text
/// contains `lang=spectre` or `lang=spice` once the tokens are concatenated without
/// separators — which is what makes `lang`, `=`, `spectre` as three tokens work.
/// Returns null for anything else, including a `simulator` line with no `lang=`.
pub fn langSwitch(toks: Tokens, l: LineIdx) ?Lang {
    if (!toks.headIs(l, "simulator")) return null;
    // ponytail: the concatenation is folded into a fixed 96-byte window. `lang=spectre`
    // is 12 bytes and follows `simulator` immediately in every spelling that exists; a
    // growable buffer would need an allocator this signature deliberately does not take.
    var buf: [96]u8 = undefined;
    var n: usize = 0;
    const from, const to = toks.range(l);
    var k = from;
    while (k < to and n < buf.len) : (k += 1) {
        const s = toks.text(TokIdx.at(k));
        const take = @min(s.len, buf.len - n);
        for (buf[n..][0..take], s[0..take]) |*d, c| d.* = std.ascii.toLower(c);
        n += take;
    }
    const joined = buf[0..n];
    if (std.mem.indexOf(u8, joined, "lang=spectre") != null) return .spectre;
    if (std.mem.indexOf(u8, joined, "lang=spice") != null) return .spice;
    return null;
}

/// Classify one token's bytes. Pure; the single definition of the `Kind` boundaries so
/// that `tokenize` and any test agree by construction.
pub fn kindOfBytes(s: []const u8) Kind {
    if (s.len == 0) return .word;
    if (s.len == 1 and std.mem.indexOfScalar(u8, "()[]", s[0]) != null) return .punct;
    if (std.ascii.isDigit(s[0])) return .number;
    if (s[0] == '.' and s.len > 1 and std.ascii.isDigit(s[1])) return .number;
    return .word;
}
