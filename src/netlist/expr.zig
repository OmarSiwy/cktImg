//! `.param` scope and `{expr}` evaluation for device value labels.
//!
//! Two things live here: a parameter scope, and a small arithmetic evaluator over it
//! (`+ - * /`, unary sign, parentheses, SPICE SI-suffixed numbers, identifiers). Both
//! exist for exactly one purpose — turning a value *label* like `{2*rval}` into the text
//! `2000`. **Topology never depends on this.** No pin, net or device count is a function
//! of an expression, which is why an unevaluable expression is not an error: the raw text
//! stays in the label and the schematic is otherwise identical.
//!
//! ## The scope is a stack, not a cloned map
//!
//! Flattening instantiates a subckt by pushing a child scope containing the globals, then
//! the definition's defaults, then the call-site overrides. The obvious implementation is
//! `HashMap<String, f64>` cloned per instantiation — which is what the Rust original does,
//! and it means one allocation-heavy full copy of every parameter in scope for every
//! instance in the deck, on a structure whose typical size is under ten entries.
//!
//! Here it is one `MultiArrayList(Binding)` plus a `[max_depth]u32` of frame boundaries.
//! Pushing a frame records the current length; popping truncates back to it. Nothing is
//! copied, nothing is allocated per frame, and the whole scope is two contiguous arrays.
//!
//! Lookup is a **reverse linear scan of the binding array**. That is innermost-out by
//! construction — the newest binding for a name is the last one written, so scanning
//! backwards finds the innermost shadow first without consulting the frame table at all.
//! The frame table exists purely to make `pop` O(1). At these sizes a reverse scan over
//! contiguous `StrId`s beats a hash lookup on both instruction count and cache behavior,
//! and it needs no allocation, no hashing, and no map to iterate — which the determinism
//! rule forbids anyway.
//!
//! Names are `StrId`, so a comparison is an integer compare and case-insensitivity is
//! already handled: everything went through `internFold`.
//!
//! ## Numbers are SPICE numbers
//!
//! A literal is a float followed by an optional SI suffix, and the suffix rules have two
//! traps that a naive implementation gets wrong. `meg` and `mil` must be tested **before**
//! the single letter `m`, or `1meg` silently becomes 0.001 — a six-order-of-magnitude
//! error in a label. And a bare `e` is a unit letter, not an exponent, unless a digit
//! (optionally after a sign) follows it, so `1e` is 1 and `1e3` is 1000.
//!
//! Trailing unit letters after the suffix are ignored: `1kohm` is 1000. This is
//! permissive on purpose — a value label is human text and rejecting `1kohm` would lose
//! the whole label over a unit nobody asked us to validate.
//!
//! ## Everything here writes to a writer
//!
//! `resolveBraces` takes a `*std.Io.Writer` rather than returning a string, so the
//! resolved label lands directly in the caller's buffer — usually the string interner's
//! staging area — with no intermediate allocation. A label that contains no `{` is copied
//! through byte for byte.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const strings = @import("../strings.zig");

const StrId = ids.StrId;
const Interner = strings.Interner;

/// One parameter binding.
///
/// `f64` because SPICE parameters are physical quantities spanning femto to tera, and this
/// is the one place in the program where a float is correct — it never reaches geometry.
pub const Binding = struct {
    name: StrId,
    value: f64,
};

/// Nested parameter scope over one flat binding array.
///
/// Deinit-complete. `max_depth` frames is the same cap flattening enforces on
/// instantiation nesting, so a legal deck can never exhaust it and `push` returning an
/// error is a real signal rather than a resource limit to worry about.
pub const Scope = struct {
    /// Every binding ever pushed and not yet popped, in definition order. SoA so that a
    /// lookup scan touches only the `name` column — 4 bytes per candidate instead of 16.
    binds: std.MultiArrayList(Binding) = .empty,
    /// `frames[k]` is the binding count when frame `k` was opened. Only entries below
    /// `depth` are meaningful.
    frames: [max_depth]u32 = @splat(0),
    /// Number of open frames. Frame 0 is the global scope and is always open, so a fresh
    /// `Scope` has `depth == 1`... except that `empty` has `depth == 0`; call `push` once
    /// for the global frame, which `flatten` does.
    depth: u8 = 0,

    /// Maximum nesting. Matches `flatten.max_depth`; a `[64]u32` frame table is 256 bytes
    /// and lives inline, so a scope needs no allocation until its first binding.
    pub const max_depth = 64;

    pub const empty: Scope = .{};

    /// Release the binding array. Safe on `.empty`.
    pub fn deinit(self: *Scope, gpa: Allocator) void {
        self.binds.deinit(gpa);
        self.* = .empty;
    }

    /// Open a new innermost frame.
    ///
    /// Allocation-free: it records a length, nothing more. Errors: `error.TooDeep` when
    /// `max_depth` frames are already open, which the caller reports as
    /// `subckt_too_deep` rather than treating as fatal.
    pub fn push(self: *Scope) error{TooDeep}!void {
        if (self.depth >= max_depth) return error.TooDeep;
        self.frames[self.depth] = @intCast(self.binds.len);
        self.depth += 1;
    }

    /// Discard the innermost frame and every binding made in it.
    ///
    /// Retains capacity, so the next instantiation at the same depth reuses the same
    /// memory — this is what makes flattening a deep hierarchy allocate once rather than
    /// once per level. Asserts at least one frame is open; popping an empty scope is a
    /// bug in the recursion, not a condition.
    pub fn pop(self: *Scope) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        self.binds.shrinkRetainingCapacity(self.frames[self.depth]);
    }

    /// Bind `name` to `value` in the innermost frame.
    ///
    /// Always appends; it does not search for and overwrite an existing binding. That is
    /// deliberate — appending is what makes shadowing work, and a redefinition within one
    /// frame must also take effect, which a reverse-scanning lookup gives for free. The
    /// cost is that `.param a=1 a=2 a=3` leaves three bindings in the frame; the benefit
    /// is that both shadowing rules are one code path.
    ///
    /// Asserts a frame is open. Errors: `OutOfMemory`.
    pub fn define(self: *Scope, gpa: Allocator, name: StrId, value: f64) Allocator.Error!void {
        std.debug.assert(self.depth > 0);
        try self.binds.append(gpa, .{ .name = name, .value = value });
    }

    /// Value bound to `name`, searched innermost-out, or null when unbound.
    ///
    /// A single reverse scan of the binding array; see the module header for why that is
    /// both correct and the fastest thing at these sizes. Allocation-free. O(bindings in
    /// scope), which in practice is under a dozen.
    pub fn lookup(self: Scope, name: StrId) ?f64 {
        const names = self.binds.items(.name);
        var i = names.len;
        while (i > 0) {
            i -= 1;
            if (names[i] == name) return self.binds.items(.value)[i];
        }
        return null;
    }

    /// Number of open frames.
    pub fn frameCount(self: Scope) u8 {
        return self.depth;
    }

    /// Total bindings currently live across all frames.
    pub fn bindingCount(self: Scope) usize {
        return self.binds.len;
    }

    /// Check: `depth <= max_depth`, `frames[0..depth]` non-decreasing, and
    /// `frames[depth - 1] <= binds.len`. Panics on violation.
    pub fn assertValid(self: Scope) void {
        std.debug.assert(self.depth <= max_depth);
        if (self.depth == 0) return;
        for (self.frames[1..self.depth], self.frames[0 .. self.depth - 1]) |hi, lo| {
            std.debug.assert(hi >= lo);
        }
        std.debug.assert(self.frames[self.depth - 1] <= self.binds.len);
    }
};

/// SI suffix multiplier for a SPICE number.
///
/// Only the first one to three characters of `suffix` are examined; anything after is a
/// unit and ignored, so `kohm` and `k` both give 1e3. Matching is case-insensitive.
///
/// `meg` (1e6) and `mil` (25.4e-6, a thousandth of an inch) are tested **before** the
/// single-letter table, because `m` alone is milli and getting that order wrong turns
/// `1meg` into 0.001. Single letters: `t` 1e12, `g` 1e9, `k` 1e3, `m` 1e-3, `u` 1e-6,
/// `n` 1e-9, `p` 1e-12, `f` 1e-15, `a` 1e-18.
///
/// An unrecognized suffix — including the empty one — gives 1.0, not an error: a value
/// with a unit we do not know is still a number.
pub fn siMult(suffix: []const u8) f64 {
    // `meg` and `mil` first: `m` alone is milli, and getting the order wrong turns
    // `1meg` into 0.001 — six orders of magnitude, silently, on a label.
    if (suffix.len >= 3) {
        if (std.ascii.eqlIgnoreCase(suffix[0..3], "meg")) return 1e6;
        if (std.ascii.eqlIgnoreCase(suffix[0..3], "mil")) return 25.4e-6;
    }
    if (suffix.len == 0) return 1.0;
    return switch (std.ascii.toLower(suffix[0])) {
        't' => 1e12,
        'g' => 1e9,
        'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        'a' => 1e-18,
        else => 1.0,
    };
}

/// Read one SPICE number from the front of `s`.
///
/// Returns the value (mantissa × SI multiplier) and the number of bytes consumed,
/// including the suffix letters, or null when `s` does not begin with a digit or a `.`.
///
/// Mantissa grammar: digits, at most one `.`, and at most one exponent. An `e`/`E` starts
/// an exponent only when it is not the first character and is followed by a digit or by a
/// sign and a digit; otherwise it is treated as the beginning of the suffix. That single
/// rule is what lets `1e-3` be 0.001 while `1e` is 1.
///
/// The suffix is the whole following run of ASCII letters, all of it consumed even though
/// only the first three matter, so the caller's cursor lands past the unit.
///
/// Note the consequence for `4k7`: this reads `4k` (4000) and leaves `7`, so `eval("4k7")`
/// fails on trailing input and the label keeps its original text. That matches the Rust
/// reader and is the right outcome — `4k7` is a *label* convention, not arithmetic.
pub fn readNumber(s: []const u8) ?struct { f64, usize } {
    var i: usize = 0;
    var dot = false;
    var exp = false;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isDigit(c)) {
            i += 1;
        } else if (c == '.' and !dot and !exp) {
            dot = true;
            i += 1;
        } else if ((c == 'e' or c == 'E') and !exp and i > 0) {
            // An `e` is an exponent only when a digit unambiguously follows it;
            // otherwise it is the first letter of a unit, so `1e` is 1 and `1e3` is 1000.
            var j = i + 1;
            if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
            if (j < s.len and std.ascii.isDigit(s[j])) {
                exp = true;
                i = j; // consume e[sign]; the digit is taken on the next iteration
            } else break;
        } else break;
    }
    if (i == 0) return null;
    const mantissa = std.fmt.parseFloat(f64, s[0..i]) catch return null;

    var suf: usize = i;
    while (suf < s.len and std.ascii.isAlphabetic(s[suf])) suf += 1;
    return .{ mantissa * siMult(s[i..suf]), suf };
}

/// Evaluate one expression in `scope`.
///
/// Grammar: `additive := term (('+'|'-') term)*`, `term := factor (('*'|'/') factor)*`,
/// `factor := ('-'|'+') factor | '(' additive ')' | number | identifier`. Whitespace is
/// skipped everywhere. Identifiers are `[A-Za-z_]` followed by alphanumerics, `_` or `.`
/// — the dot is included because hierarchical parameter names appear in generated decks.
///
/// Returns null, leaving `scope` untouched, when the expression:
/// - references an identifier that is not bound (the common case, and the reason callers
///   fall back to verbatim text),
/// - contains a character outside the grammar,
/// - is empty or syntactically incomplete (`3 +`),
/// - or has trailing input after a complete expression (`4k7`, `1 2`).
///
/// Division by zero yields an infinity rather than null, because IEEE already has a
/// representation for it and a label reading `inf` tells the user more than a label
/// silently left unresolved.
///
/// Identifiers are looked up by folding into a stack buffer of
/// `Interner.fold_stack_max` bytes and calling `Interner.find`, so evaluation **never
/// grows the string pool** — an unknown parameter name must not become a permanent
/// interned string just because someone mentioned it. A name longer than the fold buffer
/// fails the eval, which is the same outcome as being unbound.
///
/// Allocation-free: the recursive descent uses the call stack, bounded by parenthesis
/// nesting in the input.
pub fn eval(s: []const u8, scope: Scope, interner: Interner) ?f64 {
    var p: Parser = .{ .s = s, .i = 0, .scope = scope, .interner = interner };
    const v = p.additive() orelse return null;
    p.skipWs();
    if (p.i != s.len) return null; // trailing input: `4k7`, `1 2`
    return v;
}

/// Recursive-descent evaluator over the raw expression text.
///
/// No token vector: the grammar is small enough that the scan and the parse are the same
/// walk, which keeps the whole evaluation allocation-free and on the call stack.
const Parser = struct {
    s: []const u8,
    i: usize,
    scope: Scope,
    interner: Interner,

    fn skipWs(self: *Parser) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
    }

    fn eatOp(self: *Parser, c: u8) bool {
        self.skipWs();
        if (self.i < self.s.len and self.s[self.i] == c) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn additive(self: *Parser) ?f64 {
        var v = self.term() orelse return null;
        while (true) {
            if (self.eatOp('+')) {
                v += self.term() orelse return null;
            } else if (self.eatOp('-')) {
                v -= self.term() orelse return null;
            } else return v;
        }
    }

    fn term(self: *Parser) ?f64 {
        var v = self.factor() orelse return null;
        while (true) {
            if (self.eatOp('*')) {
                v *= self.factor() orelse return null;
            } else if (self.eatOp('/')) {
                // Division by zero yields an infinity on purpose: a label reading `inf`
                // says more than one silently left unresolved.
                v /= self.factor() orelse return null;
            } else return v;
        }
    }

    fn factor(self: *Parser) ?f64 {
        if (self.eatOp('-')) return -(self.factor() orelse return null);
        if (self.eatOp('+')) return self.factor();
        if (self.eatOp('(')) {
            const v = self.additive() orelse return null;
            if (!self.eatOp(')')) return null;
            return v;
        }
        self.skipWs();
        if (self.i >= self.s.len) return null;
        const c = self.s[self.i];
        if (std.ascii.isDigit(c) or c == '.') {
            const v, const n = readNumber(self.s[self.i..]) orelse return null;
            self.i += n;
            return v;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = self.i;
            while (self.i < self.s.len) : (self.i += 1) {
                const d = self.s[self.i];
                if (!(std.ascii.isAlphanumeric(d) or d == '_' or d == '.')) break;
            }
            const name = self.s[start..self.i];
            // Folded into a stack buffer and *found*, never interned: an unknown
            // parameter must not become a permanent pool entry because someone named it.
            if (name.len > Interner.fold_stack_max) return null;
            var buf: [Interner.fold_stack_max]u8 = undefined;
            for (buf[0..name.len], name) |*d, x| d.* = std.ascii.toLower(x);
            const id = self.interner.find(buf[0..name.len]) orelse return null;
            return self.scope.lookup(id);
        }
        return null; // a character outside the grammar
    }
};

/// Write `value` to `w` with every `{expr}` replaced by its evaluated number.
///
/// A brace group whose contents do not evaluate is emitted **verbatim, braces included**,
/// so a partially parametric label degrades gracefully instead of losing the parts that
/// did resolve: `W={w} L={unknown}` becomes `W=2e-06 L={unknown}`. Text outside braces
/// passes through byte for byte, and a value with no `{` at all is a straight copy.
///
/// An unbalanced `{` emits the remainder of the string as-is, including the brace. Nested
/// braces are not supported — the first `}` closes the group — because no SPICE dialect
/// nests them and treating `{` as significant inside a group would break labels that
/// contain one literally.
///
/// Errors: whatever `w` returns. Allocates nothing.
pub fn resolveBraces(
    value: []const u8,
    scope: Scope,
    interner: Interner,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var rest = value;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try w.writeAll(rest[0..open]);
        const after = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after, '}') orelse {
            try w.writeAll(rest[open..]); // unbalanced: the remainder goes out as-is
            return;
        };
        const inner = after[0..close];
        if (eval(inner, scope, interner)) |v| {
            try writeNumber(v, w);
        } else {
            try w.writeByte('{');
            try w.writeAll(inner);
            try w.writeByte('}');
        }
        rest = after[close + 1 ..];
    }
    try w.writeAll(rest);
}

/// Write `v` as a compact label number.
///
/// Shortest round-trip decimal, so 2000.0 prints `2000` and not `2000.0` or `2e3`. Both
/// zeroes print as `0`: `-0.0` would otherwise render as `-0`, which looks like a bug on a
/// drawing. Non-finite values print as `inf` / `-inf` / `nan`.
///
/// This is the one float-to-text conversion in the program, and it is here rather than in
/// a renderer because every renderer must agree — two emitters formatting the same value
/// differently is how golden-output comparison starts failing for no reason.
pub fn writeNumber(v: f64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // `v == 0` also catches -0.0, which would otherwise render as `-0` on a drawing.
    if (v == 0.0) return w.writeAll("0");
    return w.print("{d}", .{v});
}
