//! Runtime-registered device classes, appended after the builtin catalog.
//!
//! A host — a schematic editor, a testbench harness, a PDK adapter — has symbols whose
//! terminals are only known when it runs: project components, DUT boxes, a cell whose pin
//! anchors must match *its* grid rather than ours. Those arrive here. Instances resolve by
//! name wherever a builtin would, so `XDUT in out vdd gnd my_opamp` places `my_opamp` as a
//! device instead of being flattened or skipped.
//!
//! ## One index space, split at `builtin_count`
//!
//! `SymbolIdx` values below `catalog.builtin_count` index the comptime table; values at or
//! above index `Table.classes[i - builtin_count]`. One space, so nothing downstream of the
//! IR needs to know a class was registered at run time — the router, the metric and the
//! renderers all just call `Table.at`.
//!
//! ## Indices, once handed out, never move
//!
//! Registration is append-only. There is no removal, no compaction and no re-sorting, ever,
//! because a `Placed` produced last week may still hold a `SymbolIdx` and a long-lived
//! editor registers new symbols between parses. That constraint is what dictates the
//! storage: an `ArrayList` grown at the tail, and an arena that only ever accumulates.
//!
//! It also dictates the error on conflict. The Rust original appended a *second* entry under
//! the same name when a host re-registered changed geometry, letting name lookup resolve to
//! the newest version while old indices kept their old meaning. That is defensible but it
//! makes "how many classes named `foo` exist" unanswerable and quietly doubles the table for
//! a host that re-registers on every edit. Here a same-name registration whose geometry
//! differs is `error.GeometryChanged`: a host that genuinely revised a symbol registers it
//! under a new name, and the failure is loud at the point of the mistake instead of
//! surfacing as two frames in a drawing.
//!
//! ## Thread safety: caller-synchronized, and that is deliberate
//!
//! **`Table` has no internal lock.** `register` mutates; `at`, `indexOf` and `count` only
//! read. Concurrent reads are safe; a concurrent `register` is not, and neither is a read
//! racing a `register`.
//!
//! The Rust version put a process-global `RwLock<Vec<…>>` behind every single class lookup —
//! and class lookup happens per device per pass. That is an atomic on the hottest read path
//! in the program to guard a table that, in practice, is written once during startup. It
//! also made the registry global state, which is the thing ARCHITECTURE.md §"No hidden
//! control flow" exists to forbid: the lock was invisible at the call site and there was no
//! way to give two threads two different vocabularies.
//!
//! So the table is an explicit parameter, like `Config`, and synchronization is the caller's
//! to arrange. The realistic patterns both come out ahead: register everything before
//! spawning work (no synchronization needed at all), or hold one `Table` per thread. A host
//! that truly must register while placing wraps it in its own mutex and pays only where it
//! actually needs to.
//!
//! ## Memory
//!
//! One arena per table. Every name, terminal array and draw-op array a registration needs is
//! copied into it, so a caller's `Spec` may point at stack memory and disappear immediately
//! afterward. Nothing is ever individually freed — that is the point of append-only — and
//! `deinit` releases the whole thing in one call.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("../ids.zig");
const catalog = @import("catalog.zig");

const Pt = ids.Pt;
const SymbolIdx = ids.SymbolIdx;
const DeviceClass = catalog.DeviceClass;
const Terminal = catalog.Terminal;
const DrawOp = catalog.DrawOp;

/// What a host must supply to register a class.
///
/// Every slice is **borrowed for the duration of the call only** — `register` copies what it
/// keeps, so a caller may build a `Spec` on the stack.
pub const Spec = struct {
    /// Class name as instances will reference it. Copied, and **folded to lowercase** on the
    /// way in so it matches the interner's folded identifiers.
    name: []const u8,
    /// Terminals in the SPICE node order an `X` instance will use. Must be non-empty.
    ///
    /// Roles drive placement: control terminals (`gate`, `base`) attract driving nets,
    /// conducting ones join the spine walk. Anchor points are in the same canonical frame as
    /// the builtins — origin at the device centre, y down.
    terminals: []const Terminal,
    /// Exact symbol geometry, in canonical coordinates. An editor that already has a glyph
    /// for this symbol ships it here and gets it back verbatim in the rendered output.
    ///
    /// `null` generates the labelled box body (`catalog.box`) that the builtin flip-flops
    /// and converters use, titled with `name` upper-cased is *not* done — the title is
    /// `name` verbatim.
    draw: ?[]const DrawOp = null,
};

/// Why a registration was refused.
///
/// Every one of these is a caller mistake rather than a data condition, but they are errors
/// and not assertions because the caller is frequently *foreign* code coming through the C
/// ABI, where a panic would take down someone else's process over a bad symbol definition.
pub const RegisterError = error{
    /// `Spec.terminals` was empty. A class with no pins cannot be placed or connected.
    NoTerminals,
    /// The name is a builtin class. Shadowing one would make `nmos` mean two things
    /// depending on which table answered first.
    ShadowsBuiltin,
    /// A class of this name is already registered with different terminals. Register the
    /// revision under a new name — see the module header for why this is not a silent
    /// append.
    GeometryChanged,
    OutOfMemory,
};

/// The runtime class table: append-only storage plus the arena backing it.
///
/// Not thread-safe; see the module header. Deinit-complete — `deinit` releases the class
/// records and every string and slice they point into.
pub const Table = struct {
    /// Backs every copied name, terminal array and draw-op array. Never partially freed:
    /// append-only storage has no individual lifetimes to track, so an arena is exactly the
    /// right shape and the alternative (per-class `free` in a loop) would buy nothing.
    arena: std.heap.ArenaAllocator,
    /// Host classes in registration order. Class `i` is `SymbolIdx`
    /// `catalog.builtin_count + i`.
    classes: std.ArrayList(DeviceClass) = .empty,

    /// Create an empty table over `gpa`. Allocates nothing eagerly.
    pub fn init(gpa: Allocator) Table {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// Release the arena and the class list.
    ///
    /// Invalidates every `DeviceClass` previously returned by `at` — the slices inside one
    /// point into the arena. It does *not* invalidate `SymbolIdx` values in the numeric
    /// sense, but resolving one afterward is use-after-free; an IR outliving its table is a
    /// caller bug the type system cannot catch, so it is stated here instead.
    pub fn deinit(self: *Table) void {
        self.classes.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Number of host classes registered. Adding `catalog.builtin_count` gives the first
    /// unused `SymbolIdx`.
    pub fn count(self: Table) usize {
        return self.classes.items.len;
    }

    /// Register one class, returning its `SymbolIdx`.
    ///
    /// Copies `spec.name` (case-folded), its terminals and their names, and either the
    /// supplied `draw` ops or a generated box body, into the table's arena. `spec` may be
    /// discarded the moment this returns.
    ///
    /// **Idempotent on an exact repeat.** If a class of the same folded name is already
    /// present and its terminals match by name, role and anchor point in order, the existing
    /// index is returned and nothing is allocated. This is what lets a host re-scan its
    /// symbol library on every parse without growing the table. Note that the comparison
    /// covers terminals only, not `draw`: geometry a wire never touches cannot invalidate an
    /// index, and a host that redraws a glyph in place is doing something reasonable.
    ///
    /// Errors:
    /// - `NoTerminals` — `spec.terminals` is empty.
    /// - `ShadowsBuiltin` — `catalog.isBuiltin(folded_name)`.
    /// - `GeometryChanged` — same name, different terminals.
    /// - `OutOfMemory`.
    ///
    /// On any error the table is unchanged and no index is consumed, so a retry after
    /// freeing memory produces the same numbering. Arena memory already claimed for a failed
    /// registration is not returned to the OS (an arena cannot), but it is never referenced
    /// and is released by `deinit` — the invariant that matters is that `classes` gains no
    /// entry.
    ///
    /// Post-condition on success: `count()` is unchanged (idempotent hit) or one greater,
    /// and every previously returned index still resolves to the same class.
    ///
    /// Complexity: O(existing classes) for the name scan, which is a linear walk over a
    /// table a host registers tens of entries into. A hash index would be faster and could
    /// not be iterated for output, so it would need a sorted array beside it anyway; add one
    /// when a host registers thousands. `// ponytail: linear name scan.`
    pub fn register(self: *Table, spec: Spec) RegisterError!SymbolIdx {
        if (spec.terminals.len == 0) return error.NoTerminals;

        // `catalog.isBuiltin(folded_name)`, without needing the fold buffer first: every
        // builtin name is lowercase, so a case-insensitive match asks the same question.
        for (catalog.classes) |c| {
            if (std.ascii.eqlIgnoreCase(c.name, spec.name)) return error.ShadowsBuiltin;
        }

        // Stored names are already folded, so the same comparison finds the existing entry.
        // ponytail: linear name scan.
        for (self.classes.items, 0..) |c, i| {
            if (!std.ascii.eqlIgnoreCase(c.name, spec.name)) continue;
            if (!sameTerminals(c.terminals, spec.terminals)) return error.GeometryChanged;
            return SymbolIdx.at(catalog.builtin_count + i);
        }

        // Reserve the list slot up front: it is the only allocation outside the arena, so
        // once it succeeds nothing can leave `classes` holding a half-built class.
        try self.classes.ensureUnusedCapacity(self.arena.child_allocator, 1);

        const a = self.arena.allocator();
        // NUL-terminated like every interned string: `abi.zig` hands these straight to C
        // as `[*:0]const u8`, so the terminator is an invariant of the table, not a
        // property the ABI may re-establish with a per-call copy.
        const name = try a.allocSentinel(u8, spec.name.len, 0);
        for (spec.name, name) |src, *dst| dst.* = std.ascii.toLower(src);

        const terms = try a.alloc(Terminal, spec.terminals.len);
        for (spec.terminals, terms) |src, *dst| {
            dst.* = .{ .name = try a.dupeZ(u8, src.name), .role = src.role, .at = src.at };
        }

        const draw = if (spec.draw) |ops| try copyOps(a, ops) else try catalog.box.body(a, terms, name);

        self.classes.appendAssumeCapacity(.{
            .name = name,
            .terminals = terms,
            .draw = draw,
            .prefix = 'X',
        });
        return SymbolIdx.at(catalog.builtin_count + self.classes.items.len - 1);
    }

    /// Resolve a class name across both tables.
    ///
    /// Builtins are checked first, so a host class can never shadow one even if registration
    /// somehow let it through. Among host classes the match is unique — `register` rejects a
    /// second class under the same name.
    ///
    /// **Does not fold case**, matching `catalog.indexOf`: names arrive already folded from
    /// the interner. Returns null when unknown, which the front end turns into a `skipped`
    /// note or a generic box depending on `Config.pdk.unknown_as_box`.
    ///
    /// Allocation-free.
    pub fn indexOf(self: Table, name: []const u8) ?SymbolIdx {
        if (catalog.indexOf(name)) |i| return i;
        for (self.classes.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, name)) return SymbolIdx.at(catalog.builtin_count + i);
        }
        return null;
    }

    /// The class a `SymbolIdx` denotes, builtin or host.
    ///
    /// Returned **by value**, deliberately. A `DeviceClass` is six fields of views (~72
    /// bytes) and copying it costs nothing next to what a caller then does with it — while a
    /// pointer into `classes.items` would dangle the moment a later `register` grew the list.
    /// The slices *inside* the returned value are borrowed from static memory (builtin) or
    /// the arena (host) and stay valid until `deinit`; those never move, since the arena is
    /// append-only.
    ///
    /// Asserts the index is in range for one of the two tables. An out-of-range `SymbolIdx`
    /// means the IR and the table came from different runs, which is a programming error and
    /// not something to paper over with a fallback symbol.
    pub fn at(self: Table, idx: SymbolIdx) DeviceClass {
        if (idx.i() < catalog.builtin_count) return catalog.at(idx).*;
        const i = idx.i() - catalog.builtin_count;
        std.debug.assert(i < self.classes.items.len);
        return self.classes.items[i];
    }

    /// Replace the anchor points of an already-registered host class.
    ///
    /// For a host whose pin geometry moved — a schematic editor that rescaled a symbol —
    /// where the terminal *count, names and roles* are unchanged. Bounding boxes and routing
    /// pick the new anchors up automatically because both derive from `terminals` and
    /// nothing caches a box (see catalog.zig).
    ///
    /// This is the one mutation of an existing entry the table permits, and it is safe
    /// precisely because it does not change what the index *means*: pin 2 is still `clk`.
    /// Callers must not do it while a `Placed` built from the old anchors is still being
    /// rendered — the wires would land beside the pins.
    ///
    /// Errors: `GeometryChanged` when `anchors.len` differs from the class's terminal count;
    /// `OutOfMemory`. Asserts `idx` names a host class — anchor-overriding a *builtin* would
    /// mutate comptime data, so a host that needs different builtin geometry registers its
    /// own class instead. (The Rust tree allowed exactly that by leaking a mutable copy of
    /// the whole builtin table at startup; dropping the capability drops a process-global.)
    pub fn setAnchors(self: *Table, idx: SymbolIdx, anchors: []const Pt) RegisterError!void {
        std.debug.assert(idx.i() >= catalog.builtin_count);
        const i = idx.i() - catalog.builtin_count;
        std.debug.assert(i < self.classes.items.len);
        const class = &self.classes.items[i];
        if (anchors.len != class.terminals.len) return error.GeometryChanged;

        // A fresh array rather than a mutation in place: the stored view is `[]const
        // Terminal`, and the old array stays valid until `deinit` like everything else the
        // arena hands out. The body is deliberately left alone — Rust's override does the
        // same, and the leads are cosmetic where the anchors are load-bearing.
        const terms = try self.arena.allocator().alloc(Terminal, anchors.len);
        for (class.terminals, anchors, terms) |old, p, *dst| {
            dst.* = .{ .name = old.name, .role = old.role, .at = p };
        }
        class.terminals = terms;
    }
};

/// Deep-copy a host's draw ops into `a`: the ops themselves plus every polyline point array
/// and every text string they point at, since a `Spec` may be stack-built and discarded.
fn copyOps(a: Allocator, ops: []const DrawOp) Allocator.Error![]DrawOp {
    const out = try a.alloc(DrawOp, ops.len);
    for (ops, out) |src, *dst| {
        dst.* = switch (src) {
            .line, .circle => src,
            .polyline => |pts| .{ .polyline = try a.dupe(Pt, pts) },
            // NUL-terminated: `cktimg_device_op_text` returns this pointer to C.
            .text => |t| .{ .text = .{ .at = t.at, .s = try a.dupeZ(u8, t.s), .size = t.size } },
        };
    }
    return out;
}

/// True when `a` and `b` describe the same pin set: equal length, and equal name, role and
/// anchor at every position.
///
/// Order matters — it is the SPICE node order, so two classes with the same pins in a
/// different order are different classes.
pub fn sameTerminals(a: []const Terminal, b: []const Terminal) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.role != y.role or !x.at.eql(y.at)) return false;
        if (!std.mem.eql(u8, x.name, y.name)) return false;
    }
    return true;
}
