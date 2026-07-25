//! File loading and `.include` / `.lib` expansion into **one** byte arena.
//!
//! What moves through here: raw netlist text, possibly spread over a root file and a
//! tree of includes, and what comes out is a single contiguous `[]u8` plus a small
//! side table that can answer "which file and line did byte N come from".
//!
//! ## One buffer, spans forever after
//!
//! Every stage after this one — the tokenizer, the classifier, the diagnostics — holds
//! `(off, len)` pairs into this single buffer. That is only sound if the buffer never
//! moves and never gets rebuilt, which is why expansion appends into one growing
//! `ArrayList(u8)` and the result is handed out as a stable slice. The Rust original
//! built a `String` per include, concatenated them into a second `String`, and then
//! discarded position information entirely (its diagnostics carry a line number and a
//! *copy* of the offending text). Keeping one buffer costs the same bytes the final
//! concatenation cost anyway and buys every downstream error a real span.
//!
//! ## The side table is segments, not files
//!
//! The naive table is one entry per file. That does not work: splicing `b.sp` into the
//! middle of `a.sp` means `a.sp` contributes bytes both *before* and *after* `b.sp`, so
//! a file owns a set of disjoint ranges, not one. The table is therefore a list of
//! **segments** — `{ start, name, line0 }`, sorted by `start` because they are appended
//! in output order — and `locate` binary-searches it, then counts newlines from the
//! segment start. Counting is O(segment length), which is fine: it runs once per
//! diagnostic that somebody actually formats, never in the parse loop.
//!
//! `line0` (the 1-based line number *within its file* where the segment begins) is what
//! makes a reported line number match what the user sees in their editor. Without it a
//! note about `a.sp` would carry the line number of the concatenation.
//!
//! ## Section markers do not survive
//!
//! `.lib <file> <section>` splices only the named `.lib <section> … .endl` block, and
//! `.endl` / `.lib <section>` marker lines are dropped rather than passed through, so no
//! later stage needs to know libraries exist. A `.lib` line with fewer than two operands
//! is a bare marker and is dropped the same way — it names no file to read.
//!
//! ## Every failure is a note, never an error
//!
//! A missing include, a cycle, a runaway nesting depth, an absent section: all of them
//! append an `ir.Note` and continue with the rest of the deck. The only hard failure is
//! an unreadable *root*, because there is then nothing at all to parse. Refusing to draw
//! a schematic because one model library is missing is the wrong trade — the user wants
//! to see what did resolve.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ir = @import("../ir.zig");
const strings = @import("../strings.zig");
const ids = @import("../ids.zig");

const Interner = strings.Interner;
const StrId = ids.StrId;
const Note = ir.Note;

/// Hard cap on `.include` nesting.
///
/// A deck that legitimately nests deeper than this does not exist; hitting the cap
/// means a cycle the visited-set missed (two paths spelling the same file differently,
/// for instance). Reported as `include_not_found` against the offending line, since the
/// user-visible effect is identical: that file's contents are absent.
pub const max_include_depth: u8 = 50;

/// Reads one resolved path to text, or reports absence.
///
/// A function pointer plus a context word rather than `anytype`, because there are two
/// real implementations — the filesystem, and the in-memory map the tests use — and the
/// expansion recursion would otherwise have to be generic over both. Eight bytes of
/// indirection per include is not a cost worth structuring around.
pub const Loader = struct {
    /// Opaque state belonging to the implementation. Never dereferenced here.
    ctx: *const anyopaque,
    /// Returns the file's bytes, or null when the path cannot be read for any reason.
    ///
    /// The returned buffer is **owned by the caller of `read`** (that is, by this
    /// module), which frees it once its contents have been appended and expanded. An
    /// implementation must therefore not hand back a borrowed view of its own storage
    /// unless it duplicates it first.
    readFn: *const fn (ctx: *const anyopaque, gpa: Allocator, path: []const u8) Allocator.Error!?[]u8,

    /// Invoke the loader. Caller owns the returned bytes and frees them with `gpa`.
    ///
    /// Null means "not readable" and is a reportable data condition, not an error. Only
    /// `OutOfMemory` propagates.
    pub fn read(self: Loader, gpa: Allocator, path: []const u8) Allocator.Error!?[]u8 {
        return self.readFn(self.ctx, gpa, path);
    }
};

/// One contiguous run of output bytes that came from one file.
///
/// 12 bytes. Segments are appended in output order, so the column is sorted by `start`
/// by construction and needs no sort before binary search — an invariant `assertValid`
/// checks rather than a fact the reader has to trust.
pub const Segment = struct {
    /// Offset of this run's first byte in `Source.bytes`.
    start: u32,
    /// Interned file name, as written in the `.include` (not canonicalized).
    name: StrId,
    /// 1-based line number, within `name`, of the line at `start`.
    line0: u32,
};

/// Where one byte of the arena came from.
///
/// Produced on demand for diagnostics; nothing in the parse path builds one.
pub const Loc = struct {
    file: StrId,
    /// 1-based, counted within `file`.
    line: u32,
    /// 1-based byte column. Not a codepoint or grapheme count — netlist identifiers are
    /// ASCII and a byte column is what an editor's "go to column" wants for them.
    col: u32,
};

/// The expanded deck: one byte arena plus the segment table that explains it.
///
/// Deinit-complete. `bytes` is the buffer every later `(off, len)` refers to, so a
/// `Source` must outlive every `Tokens`, `Card` and `Note` derived from it.
pub const Source = struct {
    /// All source text, includes spliced in place, every line newline-terminated.
    ///
    /// Owned. Kept as an `ArrayList` rather than a plain slice because expansion grows
    /// it incrementally and the final `toOwnedSlice` would be a pointless second copy
    /// of a buffer nobody else will resize.
    bytes: std.ArrayList(u8) = .empty,
    /// Segment table, sorted ascending by `start`. See the module header.
    segs: std.MultiArrayList(Segment) = .empty,

    pub const empty: Source = .{};

    /// Release the arena and the segment table.
    ///
    /// Invalidates every span into this source, including the `off` field of every
    /// `Note` produced against it. Safe on `.empty`.
    pub fn deinit(self: *Source, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.segs.deinit(gpa);
        self.* = .empty;
    }

    /// The whole expanded deck.
    ///
    /// Borrowed from `bytes`; valid until `deinit` and invalidated by any further
    /// expansion into the same `Source`. This is the slice the tokenizer scans.
    pub fn text(self: Source) []const u8 {
        return self.bytes.items;
    }

    /// A single `Source` holding `t` verbatim, with no include resolution.
    ///
    /// The entry point for in-memory decks and for every test that is not about
    /// includes. `t` is **copied** into the arena, so the caller may free it
    /// immediately; the copy is what lets spans stay valid for the document's lifetime.
    /// One segment is recorded, named `memory_file_name`, starting at line 1.
    ///
    /// A deck not ending in a newline gets one appended, so that every stage may assume
    /// lines are terminated rather than special-casing the last one.
    ///
    /// Caller owns the result. Errors: `OutOfMemory`.
    pub fn fromText(gpa: Allocator, interner: *Interner, t: []const u8) Allocator.Error!Source {
        var self: Source = .empty;
        errdefer self.deinit(gpa);
        const name = try interner.intern(gpa, memory_file_name);
        try self.segs.append(gpa, .{ .start = 0, .name = name, .line0 = 1 });
        try self.bytes.appendSlice(gpa, t);
        if (t.len == 0 or t[t.len - 1] != '\n') try self.bytes.append(gpa, '\n');
        return self;
    }

    /// Name recorded for a deck that came from memory rather than a file.
    pub const memory_file_name = "<memory>";

    /// Expand `root_text` (attributed to `root_name`) and every include it reaches.
    ///
    /// `loader` resolves each include path; paths are resolved **relative to the file
    /// that names them**, which is the SPICE convention and the only one that lets a
    /// model library include its own siblings. An absolute path is used as written.
    /// Quotes (`"` or `'`) around the path are stripped.
    ///
    /// Recognized spellings, all case-insensitive: `.include`, `.inc`, `include`
    /// (Spectre) take one operand; `.lib` / `lib` take *two* (file, then section) and
    /// splice only that section; `.endl` / `endl` are dropped. Everything else is copied
    /// through unchanged, including `.lib` with a single operand — that form labels a
    /// section rather than pulling one, and there is no file to read.
    ///
    /// `notes` accumulates one entry per failure: `include_not_found` for an unreadable
    /// file, an absent section, or exceeding `max_include_depth`; `include_cycle` when a
    /// path already on the open stack is re-entered. Each note's span covers the
    /// offending directive line **in the output arena** when that line was already
    /// emitted, and is `(0, 0)` for the depth cap, which is attributable to no single
    /// line. Notes are appended in source order, which is what makes a report
    /// reproducible.
    ///
    /// The cycle guard is the *open* include stack, not the set of everything ever
    /// visited: including one file twice from two places is legal and common (a shared
    /// header), and treating it as a cycle would silently drop the second copy.
    ///
    /// Caller owns the returned `Source` and the notes appended to `notes`. On
    /// `OutOfMemory` the partially built source is released before returning, so no
    /// caller has to clean up a half-expanded arena.
    ///
    /// Complexity: linear in total input bytes. Each file is scanned once per time it is
    /// spliced.
    pub fn expand(
        gpa: Allocator,
        interner: *Interner,
        root_name: []const u8,
        root_text: []const u8,
        loader: Loader,
        notes: *std.ArrayList(Note),
    ) Allocator.Error!Source {
        var self: Source = .empty;
        errdefer self.deinit(gpa);
        // The *open* include stack, one owned path copy per level. Freeing here rather
        // than at each `splice` return keeps the unwind on `OutOfMemory` unconditional.
        var open: std.ArrayList([]u8) = .empty;
        defer {
            for (open.items) |p| gpa.free(p);
            open.deinit(gpa);
        }
        try expandInto(gpa, interner, &self, .{
            .name = root_name,
            .text = root_text,
            .base = ".",
            .depth = 0,
        }, loader, notes, &open);
        return self;
    }

    /// One level of the expansion recursion. Grouped into a struct so the recursive call
    /// does not carry nine positional parameters.
    const Level = struct {
        /// File name as written in the directive; interned verbatim for diagnostics.
        name: []const u8,
        /// This file's contents (already section-extracted when it came from `.lib`).
        text: []const u8,
        /// Directory every include in `text` resolves against.
        base: []const u8,
        depth: u8,
    };

    fn expandInto(
        gpa: Allocator,
        interner: *Interner,
        self: *Source,
        lv: Level,
        loader: Loader,
        notes: *std.ArrayList(Note),
        open: *std.ArrayList([]u8),
    ) Allocator.Error!void {
        if (lv.depth > max_include_depth) {
            // Attributable to no single line: the cap is a property of the chain.
            try notes.append(gpa, .{ .off = 0, .len = 0, .reason = .include_not_found });
            return;
        }
        const name_id = try interner.intern(gpa, lv.name);

        // A segment is pushed lazily, immediately before the first byte of a run is
        // written, so an empty run never lands in the table and `start` stays strictly
        // ascending without a dedup pass.
        var need_seg = true;
        var line_no: u32 = 1;
        var pos: usize = 0;
        while (pos < lv.text.len) : (line_no += 1) {
            const nl = std.mem.indexOfScalarPos(u8, lv.text, pos, '\n') orelse lv.text.len;
            const raw = lv.text[pos..nl];
            pos = if (nl < lv.text.len) nl + 1 else lv.text.len;

            var it = std.mem.tokenizeAny(u8, raw, " \t\r");
            const head = it.next() orelse "";
            const spliced = if (isKeyword(head, &.{ ".include", ".inc", "include" })) blk: {
                const f = it.next() orelse break :blk false;
                try splice(gpa, interner, self, lv, unquote(f), null, loader, notes, open);
                break :blk true;
            } else if (isKeyword(head, &.{ ".lib", "lib" })) blk: {
                // Two operands pull a section; the one-operand form is a bare label and
                // names no file, so it is dropped rather than kept.
                const f = it.next() orelse break :blk true;
                const sec = it.next() orelse break :blk true;
                try splice(gpa, interner, self, lv, unquote(f), unquote(sec), loader, notes, open);
                break :blk true;
            } else if (isKeyword(head, &.{ ".endl", "endl" }))
                true // section markers never survive
            else
                false;

            if (spliced) {
                need_seg = true;
                continue;
            }
            if (need_seg) {
                try self.segs.append(gpa, .{
                    .start = @intCast(self.bytes.items.len),
                    .name = name_id,
                    .line0 = line_no,
                });
                need_seg = false;
            }
            try self.bytes.ensureUnusedCapacity(gpa, raw.len + 1);
            self.bytes.appendSliceAssumeCapacity(raw);
            self.bytes.appendAssumeCapacity('\n');
        }
    }

    fn splice(
        gpa: Allocator,
        interner: *Interner,
        self: *Source,
        lv: Level,
        file: []const u8,
        section: ?[]const u8,
        loader: Loader,
        notes: *std.ArrayList(Note),
        open: *std.ArrayList([]u8),
    ) Allocator.Error!void {
        // The span of a directive line is unrecoverable — the line is consumed, never
        // emitted — so a note points at the seam where its contents would have gone.
        const seam: u32 = @intCast(self.bytes.items.len);
        var path_buf: [4096]u8 = undefined;
        const path = resolvePath(&path_buf, lv.base, file) orelse {
            try notes.append(gpa, .{ .off = seam, .len = 0, .reason = .include_not_found });
            return;
        };
        for (open.items) |p| {
            if (std.mem.eql(u8, p, path)) {
                try notes.append(gpa, .{ .off = seam, .len = 0, .reason = .include_cycle });
                return;
            }
        }
        const raw = try loader.read(gpa, path) orelse {
            try notes.append(gpa, .{ .off = seam, .len = 0, .reason = .include_not_found });
            return;
        };
        defer gpa.free(raw);

        const content = if (section) |sec| Source.extractSection(raw, sec) orelse {
            try notes.append(gpa, .{ .off = seam, .len = 0, .reason = .include_not_found });
            return;
        } else raw;

        const child_base = dirName(path);
        // `path` aliases `path_buf`, which dies with this frame; the stack entry must own
        // its bytes because the recursion below compares against it at every depth.
        const owned = try gpa.dupe(u8, path);
        {
            errdefer gpa.free(owned);
            try open.append(gpa, owned);
        }
        defer {
            gpa.free(open.pop().?);
        }

        try expandInto(gpa, interner, self, .{
            .name = file,
            .text = content,
            .base = child_base,
            .depth = lv.depth + 1,
        }, loader, notes, open);
    }

    /// Read `path` from `dir` and expand it against the real filesystem.
    ///
    /// The convenience wrapper over `expand` with a filesystem loader. Includes resolve
    /// relative to the directory of the file naming them, so a deck moved wholesale
    /// still resolves.
    ///
    /// Errors: `error.RootUnreadable` when `path` itself cannot be read — the one fatal
    /// IO condition, because there is no deck at all. Every other IO failure becomes a
    /// note. `OutOfMemory` propagates.
    ///
    /// Caller owns the result.
    pub fn load(
        gpa: Allocator,
        interner: *Interner,
        dir: std.fs.Dir,
        path: []const u8,
        notes: *std.ArrayList(Note),
    ) LoadError!Source {
        _ = .{ gpa, interner, dir, path, notes };
        @panic("TODO");
    }

    pub const LoadError = Allocator.Error || error{RootUnreadable};

    /// Map an arena offset back to its origin.
    ///
    /// Binary search over `segs` for the containing segment, then a newline count from
    /// that segment's start. Asserts `off <= bytes.items.len`; an offset past the end is
    /// a bug in whatever produced the span, not a data condition. `off` exactly at the
    /// end maps to the last line, so a span covering the final card still locates.
    ///
    /// Allocation-free. O(log segments + segment length) and called only when a
    /// diagnostic is formatted.
    pub fn locate(self: Source, off: u32) Loc {
        std.debug.assert(off <= self.bytes.items.len);
        const starts = self.segs.items(.start);
        std.debug.assert(starts.len > 0);

        // Last segment whose start is <= off. `starts` is ascending by construction.
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= off) lo = mid else hi = mid;
        }
        const seg_start = starts[lo];
        const bytes = self.bytes.items;

        var line = self.segs.items(.line0)[lo];
        var line_start = seg_start;
        var i = seg_start;
        while (i < off) : (i += 1) {
            if (bytes[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{
            .file = self.segs.items(.name)[lo],
            .line = line,
            .col = off - line_start + 1,
        };
    }

    /// The whole physical line containing `off`, without its newline.
    ///
    /// Borrowed from `bytes`; valid until `deinit`. Intended for a caret-style
    /// diagnostic that wants the offending line as context. Note that a *logical* card
    /// may span several physical lines through continuations — use the span on the
    /// `Line` record for the full statement.
    pub fn lineText(self: Source, off: u32) []const u8 {
        const bytes = self.bytes.items;
        std.debug.assert(off <= bytes.len);
        const start = if (std.mem.lastIndexOfScalar(u8, bytes[0..off], '\n')) |p| p + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse bytes.len;
        return bytes[start..end];
    }

    /// Number of segments. One for a deck with no includes.
    pub fn segmentCount(self: Source) usize {
        return self.segs.len;
    }

    /// Extract the lines of one `.lib <section> … .endl` block from a library file.
    ///
    /// Returns a **borrowed** view into `lib_text` when the block is contiguous, and
    /// null when the section is absent. Matching is case-insensitive, per SPICE
    /// convention, and quotes around the section name are stripped.
    ///
    /// An opener is exactly two tokens (`.lib tt`); the three-token form is an include
    /// directive appearing inside a library and must not be mistaken for a label. A
    /// section that appears more than once yields only the first block — the alternative
    /// is a copy to concatenate them, and no real corner file does this.
    ///
    /// Exposed rather than kept private because it is the one piece of include handling
    /// with interesting behavior that is testable without any IO at all.
    pub fn extractSection(lib_text: []const u8, section: []const u8) ?[]const u8 {
        const want = unquote(section);
        var start: ?usize = null;
        var pos: usize = 0;
        while (pos < lib_text.len) {
            const nl = std.mem.indexOfScalarPos(u8, lib_text, pos, '\n') orelse lib_text.len;
            const line_start = pos;
            const raw = lib_text[pos..nl];
            pos = if (nl < lib_text.len) nl + 1 else lib_text.len;

            var it = std.mem.tokenizeAny(u8, raw, " \t\r");
            const head = it.next() orelse continue;
            if (isKeyword(head, &.{ ".lib", "lib" })) {
                const label = it.next();
                // Exactly two tokens is a label; three is an include directive that
                // happens to live inside a library file.
                if (label != null and it.next() == null) {
                    if (start != null) return lib_text[start.?..line_start];
                    if (std.ascii.eqlIgnoreCase(unquote(label.?), want)) start = pos;
                    continue;
                }
                continue;
            }
            if (start != null and isKeyword(head, &.{ ".endl", "endl" })) {
                return lib_text[start.?..line_start];
            }
        }
        if (start) |s| return lib_text[s..];
        return null;
    }

    /// Check the structural invariants: `segs` non-empty whenever `bytes` is, `start`
    /// strictly ascending, first `start` zero, every `start` within `bytes`, and every
    /// `line0` at least 1.
    ///
    /// Panics on violation. These are producer bugs; a malformed segment table turns
    /// every later diagnostic into a lie, which is worse than a crash here.
    pub fn assertValid(self: Source) void {
        if (self.bytes.items.len == 0) return;
        std.debug.assert(self.segs.len > 0);
        const starts = self.segs.items(.start);
        std.debug.assert(starts[0] == 0);
        for (starts[1..], starts[0 .. starts.len - 1]) |hi, lo| std.debug.assert(hi > lo);
        for (starts) |s| std.debug.assert(s < self.bytes.items.len);
        for (self.segs.items(.line0)) |l| std.debug.assert(l >= 1);
    }
};

/// Strip one layer of matching or unmatched `"` / `'` from a path or section name.
///
/// Returns a subslice of `s`; borrowed, allocates nothing. Mirrors SPICE's tolerance for
/// quoted paths without pretending to implement shell quoting — an embedded quote is
/// left alone.
pub fn unquote(s: []const u8) []const u8 {
    var out = s;
    if (out.len > 0 and (out[0] == '"' or out[0] == '\'')) out = out[1..];
    if (out.len > 0 and (out[out.len - 1] == '"' or out[out.len - 1] == '\'')) out = out[0 .. out.len - 1];
    return out;
}

/// True when `head` matches any of `kws`, ASCII-case-insensitively.
///
/// A tiny helper rather than a `StaticStringMap`: three-entry lists compared once per
/// physical line, where a map lookup would hash more bytes than the compare touches.
fn isKeyword(head: []const u8, kws: []const []const u8) bool {
    for (kws) |k| {
        if (std.ascii.eqlIgnoreCase(head, k)) return true;
    }
    return false;
}

/// Join `base` (a directory) and `rel` into `buf`, or return `rel` when it is absolute.
///
/// Writes into a caller-supplied buffer rather than allocating, because include
/// resolution happens once per directive and the result is consumed immediately. Returns
/// null when the joined path would exceed `buf` — reported as `include_not_found`, since
/// a path that long is unopenable anyway.
///
/// Borrowed: the result aliases either `buf` or `rel`.
pub fn resolvePath(buf: []u8, base: []const u8, rel: []const u8) ?[]const u8 {
    if (rel.len > 0 and rel[0] == '/') return rel;
    if (base.len == 0) return rel;
    const need = base.len + 1 + rel.len;
    if (need > buf.len) return null;
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '/';
    @memcpy(buf[base.len + 1 ..][0..rel.len], rel);
    return buf[0..need];
}

/// The directory part of `path`, or `"."` when it has none.
///
/// Borrowed from `path`. Used to give each spliced file its own include base.
pub fn dirName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    if (i == 0) return "/";
    return path[0..i];
}
