//! The C ABI: a **view** over a placed schematic, not a copy of one.
//!
//! `include/cktimg.h` is the C-side contract and this file is its only implementation.
//! Function names, argument order and return conventions are preserved from the Rust
//! original so an existing consumer relinks and keeps working.
//!
//! ## What the Rust paid, and why this file is a fifth of the size
//!
//! The Rust ABI's handle (`CktimgSch`) was a *rebuild*. Parsing produced a
//! `json::Schematic` — every name a fresh `String`, every polyline a
//! `Vec<Vec<[i32;2]>>` — and then `CktimgSch::from_json` walked that and rebuilt it
//! again, re-encoding every `String` as a `CString` so that an accessor could hand C a
//! pointer it did not have to free. Three representations of one schematic alive at
//! once, one allocation per device name, class name, value, terminal name and net name,
//! all so that `cktimg_device_name` could be a pointer return. 968 lines of code whose
//! entire job was making the data addressable from C.
//!
//! Two decisions upstream delete that work:
//!
//! 1. **Interned strings are NUL-terminated** (`strings.zig`, ARCHITECTURE.md §5). The
//!    pool appends a `0` after every distinct name and excludes it from the span, so
//!    `Strings.getZ` returns a `[*:0]const u8` pointing straight into the pool. One
//!    byte per *distinct* name, paid once at intern time, replaces one `CString` per
//!    *occurrence*.
//! 2. **`Physical` is already CSR.** Wire points live in one flat `[]Pt` and a `Pt` is
//!    two `i32` with no padding, so a segment's points *are* the flat
//!    `x0,y0,x1,y1,…` array C asked for. `cktimg_wire_segment_points` returns a pointer
//!    into `wire_pts` and a count; nothing is reshaped.
//!
//! So the handle is the placed schematic itself. `Sch.placed` is the first field, which
//! makes `*Sch` and `*const Placed` the same address, and every accessor below is a
//! bounds check plus a load. No shadow table exists to go stale, and the memory a C
//! renderer walks is the memory the router wrote.
//!
//! ## Ownership, stated once
//!
//! - Every `const char *` and every `const int32_t *` an accessor returns is
//!   **BORROWED from the handle** and valid until `cktimg_sch_free`. Passing one to
//!   `free(3)` or to `cktimg_string_free` is undefined behaviour.
//! - The only caller-owned strings are the ones `cktimg_run_json`,
//!   `cktimg_run_json_with_report` and `cktimg_parse_place_with_report` hand back.
//!   Those, and only those, go to `cktimg_string_free`.
//! - `cktimg_json` writes into a buffer the *caller* owns; nothing is transferred.
//!
//! The handle's arena owns exactly what the handle allocated — the source copy, the
//! report text, the lazily built refdes anchors, and (on the parse path) the IR and
//! geometry columns themselves. `wrap` borrows instead: a Zig host that already has a
//! `Placed` keeps owning it, the arena stays empty, and `cktimg_sch_free` still frees
//! precisely the arena. There is no conditional free anywhere in this file, which is
//! the property that makes the teardown reviewable.
//!
//! ## Trust boundary: fully checked, never trapping
//!
//! Everything crossing this boundary is untrusted. A null handle, an out-of-range
//! index, a null out-parameter and a null string all have defined, documented answers —
//! `null` / `0` / `false` — and none of them panics. A foreign process must not die
//! because it walked one index too far, so the assertions that are correct *inside* the
//! library become checks *at* the library edge. This is the one place in the codebase
//! where a programming error is handled rather than asserted, and it is deliberate.
//!
//! ## Two globals, and why they are permitted here
//!
//! `Config` is threaded and `host.Table` is an explicit parameter everywhere else in
//! the program, precisely to avoid hidden state. The C signatures fix that: the header
//! promises `cktimg_class_begin(const char *)` with no context argument, so the class
//! registry and the in-progress class builder are process-wide, guarded by one mutex,
//! exactly as the Rust `OnceLock`/`Mutex` pair was. They are confined to this file, and
//! `table()` exposes the registry so a Zig host can use the same vocabulary without
//! going through C.
//!
//! ## Divergence: wire index is net index
//!
//! The Rust `wires` list was *filtered* to nets carrying geometry, so `w` was an index
//! into a rebuilt vector. A view cannot filter without materializing exactly the shadow
//! index this file exists to avoid, so here `cktimg_wire_count() == cktimg_net_count()`
//! and an unrouted net reports `cktimg_wire_segment_count() == 0`. A consumer looping
//! `for (w = 0; w < wire_count; w++)` and drawing segments is unaffected — it iterates
//! a few more times and draws nothing extra — and `cktimg_wire_net(w)` still names the
//! net. The alternative was an O(nets) scan inside every accessor, which turns a
//! renderer's loop quadratic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const ids = @import("ids.zig");
const irm = @import("ir.zig");
const strings = @import("strings.zig");
const catalog = @import("devices/catalog.zig");
const host = @import("devices/host.zig");
const geom = @import("geom.zig");
const json = @import("json.zig");
const config = @import("config.zig");

const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;
const DeviceIdx = ids.DeviceIdx;
const NetIdx = ids.NetIdx;
const SymbolIdx = ids.SymbolIdx;
const Placed = irm.Placed;
const Report = irm.Report;
const Config = config.Config;
const DrawOp = catalog.DrawOp;
const Terminal = catalog.Terminal;

// ---------------------------------------------------------------------------
// The handle
// ---------------------------------------------------------------------------

/// What `CktimgSch *` points at.
///
/// `placed` is deliberately the **first field**: `@as(*const Placed, @ptrCast(sch))` is
/// valid, so the handle *is* the placed schematic and the accessors below are reading
/// the router's own output rather than a transcription of it.
///
/// Everything else is bookkeeping the handle needs to be self-contained across a C
/// boundary that has no allocator, no lifetime annotations and no way to hand a caller
/// two objects with different lifetimes.
pub const Sch = struct {
    /// The schematic. Borrowed when the handle came from `wrap`, allocated from
    /// `arena` when it came from `cktimg_parse_place`. Never freed field by field —
    /// see the module header on why there is no conditional ownership here.
    placed: Placed,
    /// Owns everything this handle allocated: the parse path's IR, string pool and
    /// geometry; the report text; the refdes cache. `destroy` releases it whole.
    arena: std.heap.ArenaAllocator,
    /// Pre-formatted report, in the C line format (`json.writeReportText`). Empty for
    /// a clean netlist. Lives in `arena`; `cktimg_report` hands out a borrowed pointer
    /// to it and `cktimg_parse_place_with_report` hands out an owned duplicate.
    report_text: [:0]const u8,
    /// The source bytes the report's spans index. Borrowed for a wrapped handle,
    /// arena-owned for a parsed one. Retained because a note's location is a span and
    /// resolving it to text needs the buffer it points into.
    src: []const u8,
    /// Collision-avoided refdes anchors, one per device, computed on the first call to
    /// `cktimg_device_refdes_anchor` and cached because the placement is *sequential* —
    /// label 7 dodges labels 0..6, so there is no per-device pure function to call and
    /// recomputing per accessor would be O(devices² × obstacles) across one render.
    /// Lives in `arena`. `null` means "not asked for yet", never "none exist".
    refdes: ?[]const Pt,

    /// Release the handle and everything its arena owns.
    ///
    /// Invalidates every borrowed pointer any accessor ever returned for this handle.
    /// Does **not** touch a `Placed` that was passed to `wrap` — that stayed the
    /// caller's.
    ///
    /// The arena is copied to a local before being released, because `Sch` itself is
    /// allocated out of that arena; freeing it while reading `self.arena` would be a
    /// use-after-free of the arena's own state.
    pub fn destroy(self: *Sch) void {
        // `self` lives *in* the arena, so read the arena out before releasing it.
        var arena = self.arena;
        arena.deinit();
    }
};

/// The one handle constructor. Everything the handle needs beyond `placed` is formatted
/// into a fresh arena, and `Sch` itself is allocated from that arena so teardown is a
/// single `deinit`.
fn create(gpa: Allocator, placed: Placed, src: []const u8, report: Report) Allocator.Error!*Sch {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const self = try a.create(Sch);
    var aw: Writer.Allocating = .init(a);
    json.writeReportText(report, src, &aw.writer) catch return error.OutOfMemory;
    const text = try aw.toOwnedSliceSentinel(0);

    self.* = .{
        .placed = placed,
        // Moved below: `arena.allocator()` above points at the local, which is why nothing
        // fallible may follow the move.
        .arena = undefined,
        .report_text = text,
        .src = src,
        .refdes = null,
    };
    self.arena = arena;
    return self;
}

/// Expose an existing `Placed` through the C accessors, copying nothing.
///
/// For a Zig host that has already run the pipeline — and for the test suite, which
/// must be able to exercise the ABI's contracts without depending on the SPICE front
/// end. The C entry points are `wrap` plus a parse.
///
/// `placed` and `src` are **borrowed**: the caller keeps ownership and both must
/// outlive the returned handle. `report` is read during the call and may be discarded
/// immediately after; its text is formatted into the handle's arena.
///
/// Caller owns the returned handle and releases it with `Sch.destroy` (or
/// `cktimg_sch_free`, which is the same thing). Errors: `OutOfMemory`.
pub fn wrap(
    gpa: Allocator,
    placed: Placed,
    src: []const u8,
    report: Report,
) Allocator.Error!*Sch {
    return create(gpa, placed, src, report);
}

/// The process-wide host class table the C registration functions build into.
///
/// Borrowed and valid for the life of the process; never freed, because a `SymbolIdx`
/// handed to a caller must keep its meaning and there is no C-side moment at which the
/// vocabulary is known to be dead. Exposed so a Zig host can pass the same table to
/// `geom` and `json.writeWith` that its C-registered symbols landed in.
///
/// Not thread-safe to read while another thread is inside `cktimg_class_register`; the
/// registration functions serialize among themselves, not against readers. Register
/// before placing, which is what every realistic host does anyway.
pub fn table() *const host.Table {
    return &g_table;
}

/// The registry itself. A `var` with a comptime-evaluable initializer, so there is no lazy
/// init and therefore no data race between a first reader and a first registrant; the
/// arena reserves nothing until something is registered. Never freed — see `table`.
var g_table: host.Table = .{
    .arena = std.heap.ArenaAllocator.init(c_allocator),
    .classes = .empty,
};

/// Serializes the registration functions among themselves. Readers are not covered; see
/// the module header.
///
/// `std.atomic.Mutex` is a try-lock, so `lock` spins. That is the right shape here: a
/// registration is a handful of arena copies, contention means two threads are building
/// classes at once (which the header already tells them not to do), and a blocking mutex
/// in 0.16 needs an `Io` instance the C signatures have nowhere to carry.
/// ponytail: spin lock; take an `Io` parameter if a host ever registers under real
/// contention.
var reg_lock: std.atomic.Mutex = .unlocked;

fn lockRegistry() void {
    while (!reg_lock.tryLock()) std.atomic.spinLoopHint();
}

/// The class under construction, or none.
///
/// One arena for the whole transaction: `begin` resets it, `register` consumes it, and
/// every name, point array and string the builder holds dies with that reset. The
/// alternative — freeing each piece on discard — is exactly the conditional ownership the
/// rest of this file avoids.
var b_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(c_allocator);
var b_name: ?[]const u8 = null;
var b_terms: std.ArrayList(Terminal) = .empty;
var b_draw: std.ArrayList(DrawOp) = .empty;

/// Drop the in-progress class and reclaim its storage. Caller holds `reg_lock`.
fn builderReset() void {
    b_name = null;
    b_terms = .empty;
    b_draw = .empty;
    _ = b_arena.reset(.retain_capacity);
}

/// The allocator every C entry point uses.
///
/// C has no allocator parameter, so one is fixed here. `std.heap.smp_allocator` because
/// a foreign consumer may call from any thread and a general-purpose, thread-safe
/// allocator is the only defensible default; a Zig host that cares supplies its own by
/// using `wrap` instead of `cktimg_parse_place`.
pub const c_allocator: Allocator = std.heap.smp_allocator;

// ---------------------------------------------------------------------------
// Enumerations shared with the header
// ---------------------------------------------------------------------------

/// Wire values of `CktimgRole`. Must stay numerically identical to
/// `catalog.TerminalRole`, which it mirrors member for member; the header repeats these
/// numbers and a mismatch would silently mis-role every host pin.
pub const Role = enum(u8) {
    passive = 0,
    drain = 1,
    source = 2,
    gate = 3,
    bulk = 4,
    collector = 5,
    base = 6,
    emitter = 7,
    anode = 8,
    cathode = 9,

    /// Map a wire value to a `TerminalRole`, or null when out of range.
    ///
    /// Checked rather than `@enumFromInt`, because the value came from C.
    pub fn toTerminal(r: u8) ?catalog.TerminalRole {
        return switch (r) {
            0...9 => @enumFromInt(r),
            else => null,
        };
    }
};

/// Wire values of `CktimgOpKind`: which arm of `catalog.DrawOp` an op is.
///
/// A C renderer switches on this and then calls the matching extractor, because the
/// four shapes carry genuinely different payloads and flattening them into one
/// accessor with unused coordinates is how a renderer starts drawing circles as lines.
pub const OpKind = enum(u8) {
    line = 0,
    polyline = 1,
    circle = 2,
    text = 3,
    /// Returned for an out-of-range op index or a null handle. Distinct from every
    /// real kind so a caller's `switch` has somewhere to send a miss.
    none = 255,
};

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Parse and place NUL-terminated SPICE text; returns an opaque handle or null.
///
/// Null is returned when `src` is null or the pipeline ran out of memory. A netlist the
/// front end could not fully represent is **not** a failure — it yields a handle plus a
/// non-empty report, because a partial drawing is more useful than a refusal.
///
/// Caller owns the returned handle and must release it with `cktimg_sch_free`.
///
/// Equivalent to `cktimg_parse_place_with_report(src, NULL)`.
pub export fn cktimg_parse_place(src: ?[*:0]const u8) ?*Sch {
    return cktimg_parse_place_with_report(src, null);
}

/// Parse and place into a handle's own arena.
///
/// Split from the two C entry points so the error path is one `try` chain with an
/// `errdefer` rather than four `catch return null`s that each have to remember what to
/// undo. The IR, the pool and the geometry are all allocated from the handle's arena, so
/// the handle owns them and `destroy` releases them with everything else.
fn parseInto(src: []const u8) Allocator.Error!*Sch {
    var arena = std.heap.ArenaAllocator.init(c_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // The caller's buffer is theirs; a handle that outlives it must own its own copy.
    const text = try a.dupe(u8, src);
    const placed, const report = try root.place(a, &Config.default, text);

    const self = try a.create(Sch);
    var aw: Writer.Allocating = .init(a);
    json.writeReportText(report, text, &aw.writer) catch return error.OutOfMemory;
    const report_text = try aw.toOwnedSliceSentinel(0);

    self.* = .{
        .placed = placed,
        .arena = undefined,
        .report_text = report_text,
        .src = text,
        .refdes = null,
    };
    self.arena = arena;
    return self;
}

const root = @import("root.zig");

/// As `cktimg_parse_place`, additionally writing the parse report to `*out_report`.
///
/// The report is one text line per ignored or skipped source line (see
/// `json.writeReportText`), or the empty string for a clean netlist. It is a **fresh
/// allocation the caller owns** and must release with `cktimg_string_free` — unlike
/// every other string in this API, which is borrowed. `cktimg_report` returns the same
/// text borrowed, for callers who would rather not manage it.
///
/// `out_report` may be null to skip the report. On failure the function returns null
/// and, when `out_report` is non-null, writes null through it — so a caller that checks
/// only the report pointer still sees the failure.
pub export fn cktimg_parse_place_with_report(
    src: ?[*:0]const u8,
    out_report: ?*?[*:0]u8,
) ?*Sch {
    if (out_report) |p| p.* = null;
    const text = std.mem.span(src orelse return null);
    const sch = parseInto(text) catch return null;

    if (out_report) |p| {
        // Caller-owned duplicate: the handle's own copy stays borrowed via `cktimg_report`.
        const dup = c_allocator.dupeZ(u8, sch.report_text) catch {
            sch.destroy();
            return null;
        };
        p.* = dup.ptr;
    }
    return sch;
}

/// Release a handle. Null is a no-op.
///
/// Invalidates every borrowed string and every borrowed point array previously obtained
/// from this handle. Does not free a `Placed` the handle merely wrapped.
pub export fn cktimg_sch_free(sch: ?*Sch) void {
    if (sch) |s| s.destroy();
}

/// Parse, place and render to JSON in one call.
///
/// Returns a newly allocated, NUL-terminated JSON document (schema in `json.zig`), or
/// null when `src` is null or memory ran out. Caller owns it and frees it with
/// `cktimg_string_free`; `free(3)` is undefined behaviour, since this is not a `malloc`
/// allocation.
///
/// Retained from the Rust API for consumers that want the document and nothing else.
/// A consumer that will walk the schematic anyway should use `cktimg_parse_place` and
/// `cktimg_json`, which streams into the caller's own buffer.
pub export fn cktimg_run_json(src: ?[*:0]const u8) ?[*:0]u8 {
    return cktimg_run_json_with_report(src, null);
}

/// As `cktimg_run_json`, additionally writing the parse report to `*out_report`.
///
/// Both strings are caller-owned and both go to `cktimg_string_free`. `out_report` may
/// be null. On failure returns null and writes null through `out_report`.
pub export fn cktimg_run_json_with_report(
    src: ?[*:0]const u8,
    out_report: ?*?[*:0]u8,
) ?[*:0]u8 {
    const sch = cktimg_parse_place_with_report(src, out_report) orelse return null;
    defer sch.destroy();

    var aw: Writer.Allocating = .init(c_allocator);
    defer aw.deinit();
    json.write(sch.placed, &Config.default, &aw.writer) catch return jsonFailed(out_report);
    const doc = aw.toOwnedSliceSentinel(0) catch return jsonFailed(out_report);
    return doc.ptr;
}

/// Undo the report allocation when the document itself could not be produced, so the
/// documented "returns null and writes null through `out_report`" holds on every path.
fn jsonFailed(out_report: ?*?[*:0]u8) ?[*:0]u8 {
    if (out_report) |p| {
        cktimg_string_free(p.*);
        p.* = null;
    }
    return null;
}

/// Free a string this library allocated. Null is a no-op.
///
/// Valid only for the three functions documented as returning caller-owned strings
/// (`cktimg_run_json`, `cktimg_run_json_with_report`, `cktimg_parse_place_with_report`).
/// Passing an accessor's borrowed pointer here is undefined behaviour and will corrupt
/// the handle's arena.
pub export fn cktimg_string_free(s: ?[*:0]u8) void {
    // `free` of a sentinel slice accounts for the terminator, which is what was allocated.
    if (s) |p| c_allocator.free(std.mem.span(p));
}

/// The parse report, borrowed.
///
/// Same text as `cktimg_parse_place_with_report` produces, and never null for a live
/// handle — a clean netlist reports the empty string. Null only for a null handle.
///
/// BORROWED from the handle; valid until `cktimg_sch_free`. Do not free.
pub export fn cktimg_report(sch: ?*const Sch) ?[*:0]const u8 {
    const s = sch orelse return null;
    return s.report_text.ptr;
}

/// Render the handle's schematic to JSON in the caller's buffer.
///
/// Two-call idiom: returns the number of bytes the document needs, **excluding** the
/// NUL terminator, always, regardless of `cap`. When `buf` is non-null and `cap` is
/// greater than zero, writes `min(needed, cap - 1)` bytes followed by a NUL, so the
/// buffer is always a valid C string. Returns 0 for a null handle and writes nothing.
///
/// A caller sizes with `n = cktimg_json(sch, NULL, 0)`, allocates `n + 1`, and calls
/// again. Truncation is detectable exactly when the return value is `>= cap`.
///
/// Nothing is allocated by this library on either call: the sizing pass streams into a
/// counting writer and the second pass streams into `buf`. That is the whole reason
/// this exists beside `cktimg_run_json`, which must allocate to return a pointer.
pub export fn cktimg_json(sch: ?*const Sch, buf: ?[*]u8, cap: usize) usize {
    const s = sch orelse return 0;

    // One pass serves both calls of the idiom: `dest` is empty on the sizing call and the
    // writer counts either way. A separate counting pass would emit the document twice for
    // no benefit, and a truncating `Writer.fixed` would report failure rather than length.
    const dest: []u8 = if (buf) |p| (if (cap > 0) p[0 .. cap - 1] else p[0..0]) else &.{};
    var t: Truncating = .init(dest);
    json.write(s.placed, &Config.default, &t.writer) catch unreachable;

    if (buf) |p| {
        if (cap > 0) p[@min(t.n, cap - 1)] = 0;
    }
    return t.n;
}

/// A writer that counts every byte offered and copies as many as `dest` holds.
///
/// The two-call sizing idiom needs a length even when the buffer is short, and
/// `Writer.fixed` cannot give one: it reports `WriteFailed` and stops. Twenty lines here
/// replace a second full emit pass, and `drain` is infallible, which is why `cktimg_json`
/// can honestly claim it never fails.
const Truncating = struct {
    dest: []u8,
    /// Bytes the document needs so far, counted whether or not they fit.
    n: usize,
    writer: Writer,

    fn init(dest: []u8) Truncating {
        return .{
            .dest = dest,
            .n = 0,
            // No buffer: every write lands in `drain`, which copies straight into `dest`.
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    fn take(self: *Truncating, bytes: []const u8) void {
        if (self.n < self.dest.len) {
            const k = @min(self.dest.len - self.n, bytes.len);
            @memcpy(self.dest[self.n..][0..k], bytes[0..k]);
        }
        self.n += bytes.len;
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Truncating = @alignCast(@fieldParentPtr("writer", w));
        self.take(w.buffered());
        w.end = 0;

        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.take(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| self.take(pattern);
        return written + pattern.len * splat;
    }
};

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

/// Number of devices. 0 for a null handle.
pub export fn cktimg_device_count(sch: ?*const Sch) usize {
    const s = sch orelse return 0;
    return s.placed.ir.deviceCount();
}

// ---------------------------------------------------------------------------
// Bounds-checking helpers. Every accessor's first two lines, factored so that "null
// handle or out-of-range index" is decided in one place rather than forty.
// ---------------------------------------------------------------------------

/// The handle, if `d` names a device on it.
fn device(sch: ?*const Sch, d: usize) ?*const Sch {
    const s = sch orelse return null;
    return if (d < s.placed.ir.deviceCount()) s else null;
}

/// Absolute pin subscript for pin `p` of device `d`, or null on a miss.
fn pinAt(sch: ?*const Sch, d: usize, p: usize) ?usize {
    const s = device(sch, d) orelse return null;
    const lo = s.placed.ir.dev_pin0[d];
    const hi = s.placed.ir.dev_pin0[d + 1];
    return if (p < hi - lo) lo + p else null;
}

/// The class of device `d`, or null on a miss.
fn classOf(sch: ?*const Sch, d: usize) ?catalog.DeviceClass {
    const s = device(sch, d) orelse return null;
    return table().at(s.placed.ir.dev_symbol[d]);
}

/// Draw op `o` of device `d`, or null on a miss.
fn opAt(sch: ?*const Sch, d: usize, o: usize) ?DrawOp {
    const class = classOf(sch, d) orelse return null;
    return if (o < class.draw.len) class.draw[o] else null;
}

/// A class-table string as a C pointer.
///
/// The zero-copy path for class, terminal and text-op names. Both sources maintain the
/// terminator — builtins are Zig string literals, `host.Table.register` copies with one —
/// so this asserts rather than duplicating.
fn cstr(s: []const u8) [*:0]const u8 {
    std.debug.assert(s.ptr[s.len] == 0);
    return @ptrCast(s.ptr);
}

/// Write a point through two optional out-parameters and report success.
fn outPt(p: Pt, x: ?*i32, y: ?*i32) bool {
    if (x) |q| q.* = p.x;
    if (y) |q| q.* = p.y;
    return true;
}

/// Write a rectangle through four optional out-parameters and report success.
fn outRect(r: Rect, min_x: ?*i32, min_y: ?*i32, max_x: ?*i32, max_y: ?*i32) bool {
    _ = outPt(r.min, min_x, min_y);
    return outPt(r.max, max_x, max_y);
}

/// Device reference designator, for example `"m1"`.
///
/// BORROWED — a pointer directly into the handle's string pool, valid until
/// `cktimg_sch_free`. Never freed, never copied on the way out. Null for a null handle
/// or `d >= cktimg_device_count`.
pub export fn cktimg_device_name(sch: ?*const Sch, d: usize) ?[*:0]const u8 {
    const s = device(sch, d) orelse return null;
    return s.placed.strings.getZ(s.placed.ir.dev_name[d]);
}

/// Device class name, for example `"nmos"`.
///
/// BORROWED from the class table: static `.rodata` for a builtin, the registry's arena
/// for a host class. Valid for the life of the process in both cases, but treat it as
/// handle-lifetime for simplicity. Null on a null handle or out-of-range index.
///
/// Zero-copy relies on class names carrying a NUL terminator past their length —
/// builtins are Zig string literals, and `host.Table.register` copies host names with
/// one. That invariant is asserted in debug builds rather than worked around with a
/// per-call duplicate.
pub export fn cktimg_device_class(sch: ?*const Sch, d: usize) ?[*:0]const u8 {
    const class = classOf(sch, d) orelse return null;
    return cstr(class.name);
}

/// Device value text, for example `"5k"`. May be the empty string, which is distinct
/// from null.
///
/// BORROWED from the string pool; valid until `cktimg_sch_free`. Null on a miss.
pub export fn cktimg_device_value(sch: ?*const Sch, d: usize) ?[*:0]const u8 {
    const s = device(sch, d) orelse return null;
    return s.placed.strings.getZ(s.placed.ir.dev_value[d]);
}

/// Rotation in quarter turns clockwise, 0..3 — multiply by 90 degrees.
///
/// 0 on a miss, which is indistinguishable from an unrotated device; a caller that
/// needs to tell them apart checks `cktimg_device_count` first. Mirror is applied
/// *before* rotation (`ids.Orient`), and a renderer that reverses the order draws
/// mirrored symbols in the wrong place.
pub export fn cktimg_device_rot(sch: ?*const Sch, d: usize) u8 {
    const s = device(sch, d) orelse return 0;
    return s.placed.ir.dev_orient[d].rot;
}

/// Whether the device is mirrored about the vertical axis, before rotation.
///
/// False on a miss.
pub export fn cktimg_device_mirror(sch: ?*const Sch, d: usize) bool {
    const s = device(sch, d) orelse return false;
    return s.placed.ir.dev_orient[d].mirror;
}

/// Placed device origin, in grid units, y downwards.
///
/// Writes `*x` and `*y` and returns true when the device exists; either out-pointer may
/// be null to skip that half. Returns false and writes nothing on a null handle or an
/// out-of-range index.
///
/// Unlike the Rust, a live handle always has geometry — `Placed` guarantees a
/// `Physical` — so false here means "no such device", never "not placed yet".
pub export fn cktimg_device_pos(sch: ?*const Sch, d: usize, x: ?*i32, y: ?*i32) bool {
    const s = device(sch, d) orelse return false;
    return outPt(s.placed.physical.pos[d], x, y);
}

/// Collision-avoided anchor for the device's refdes label: left edge, on the baseline.
///
/// The same point `geom.refdesAnchors` computes and the bundled renderers draw at, so a
/// foreign adapter reproduces our gallery instead of inventing its own label placement.
/// A renderer draws the text at this point and adds nothing.
///
/// Computed for **all** devices on the first call and cached in the handle, because the
/// placement is sequential — each label dodges the ones already placed — so there is no
/// per-device answer to give. Subsequent calls are a load. The cache lives in the
/// handle's arena and dies with it.
///
/// Same out-parameter convention as `cktimg_device_pos`. Returns false on a null
/// handle, an out-of-range index, or if the one-time computation ran out of memory.
pub export fn cktimg_device_refdes_anchor(sch: ?*const Sch, d: usize, x: ?*i32, y: ?*i32) bool {
    const s = device(sch, d) orelse return false;
    // The cache is the only mutable state behind a `const` handle: the answer is a pure
    // function of the placement, so filling it in changes nothing a caller can observe
    // except how long the call took.
    const self = @constCast(s);
    if (self.refdes == null) {
        self.refdes = geom.refdesAnchors(
            self.arena.allocator(),
            self.placed.ir,
            self.placed.physical,
            self.placed.strings,
            table(),
        ) catch return false;
    }
    return outPt(self.refdes.?[d], x, y);
}

// ---------------------------------------------------------------------------
// Pins
// ---------------------------------------------------------------------------

/// Number of pins on device `d`, in SPICE node order. 0 on a miss.
pub export fn cktimg_device_pin_count(sch: ?*const Sch, d: usize) usize {
    const s = device(sch, d) orelse return 0;
    return s.placed.ir.dev_pin0[d + 1] - s.placed.ir.dev_pin0[d];
}

/// Terminal name of pin `p` of device `d`, for example `"g"`.
///
/// BORROWED from the class table, with the same NUL-terminator invariant as
/// `cktimg_device_class`. Pin names are *derived* from the symbol class rather than
/// stored per instance, which is why this reads from the table and not the pool.
///
/// Null on a null handle or an out-of-range device or pin index. The empty string is
/// possible and means the class declared no name for that slot.
pub export fn cktimg_pin_term(sch: ?*const Sch, d: usize, p: usize) ?[*:0]const u8 {
    _ = pinAt(sch, d, p) orelse return null;
    const class = classOf(sch, d) orelse return null;
    // A pin past the class's terminal list has no name; the empty string is the documented
    // answer for a declared-but-unnamed slot, so it is what an over-long node list gets too.
    if (p >= class.terminals.len) return "";
    return cstr(class.terminals[p].name);
}

/// Name of the net pin `p` of device `d` connects to.
///
/// BORROWED from the string pool; valid until `cktimg_sch_free`.
///
/// Null on a miss **or** on a floating pin. Those are deliberately not distinguished:
/// the Rust behaved the same way, and a caller that needs to tell them apart checks the
/// pin count first.
pub export fn cktimg_pin_net(sch: ?*const Sch, d: usize, p: usize) ?[*:0]const u8 {
    const i = pinAt(sch, d, p) orelse return null;
    const s = sch.?;
    const net = s.placed.ir.pin_net[i];
    if (net == .none) return null;
    return s.placed.strings.getZ(s.placed.ir.net_name[net.i()]);
}

/// Absolute pin coordinates. Same out-parameter convention as `cktimg_device_pos`.
pub export fn cktimg_pin_xy(sch: ?*const Sch, d: usize, p: usize, x: ?*i32, y: ?*i32) bool {
    const i = pinAt(sch, d, p) orelse return false;
    return outPt(sch.?.placed.physical.pin_xy[i], x, y);
}

// ---------------------------------------------------------------------------
// Nets
// ---------------------------------------------------------------------------

/// Number of nets. 0 for a null handle.
pub export fn cktimg_net_count(sch: ?*const Sch) usize {
    const s = sch orelse return 0;
    return s.placed.ir.netCount();
}

/// Net name at index `n`.
///
/// `n` is 0-based here even though `NetIdx` is 1-based internally; the offset is this
/// function's business, not the caller's.
///
/// BORROWED from the string pool; valid until `cktimg_sch_free`. Null on a miss.
pub export fn cktimg_net_name(sch: ?*const Sch, n: usize) ?[*:0]const u8 {
    const s = sch orelse return null;
    if (n >= s.placed.ir.netCount()) return null;
    return s.placed.strings.getZ(s.placed.ir.net_name[n]);
}

// ---------------------------------------------------------------------------
// Wires
// ---------------------------------------------------------------------------

/// Number of wires, which equals `cktimg_net_count`.
///
/// See the module header: wire index *is* net index in this implementation, and an
/// unrouted net reports zero segments rather than being filtered out. 0 for a null
/// handle.
pub export fn cktimg_wire_count(sch: ?*const Sch) usize {
    return cktimg_net_count(sch);
}

/// Name of the net wire `w` belongs to — identical to `cktimg_net_name(sch, w)`.
///
/// BORROWED; valid until `cktimg_sch_free`. Null on a miss.
pub export fn cktimg_wire_net(sch: ?*const Sch, w: usize) ?[*:0]const u8 {
    return cktimg_net_name(sch, w);
}

/// Number of polyline segments in wire `w`. 0 on a miss, and 0 for an unrouted net.
pub export fn cktimg_wire_segment_count(sch: ?*const Sch, w: usize) usize {
    const s = sch orelse return 0;
    if (w >= s.placed.ir.netCount()) return 0;
    const seg = s.placed.physical.net_seg;
    return seg[w + 1] - seg[w];
}

/// Points of segment `s` of wire `w`, zero-copy.
///
/// Returns the point count and, when `xy` is non-null, writes through it a **BORROWED**
/// pointer to a flat `x0,y0,x1,y1,…` array of `2 * count` `int32_t`s. That pointer aims
/// directly at the router's `Physical.wire_pts`; `Pt` is two `i32` with no padding, so
/// the reinterpretation is exact and nothing is copied or reshaped. Valid until
/// `cktimg_sch_free`; never free it.
///
/// On a null handle or an out-of-range wire or segment index, returns 0 and writes null
/// through `xy` — the write happens even on a miss, so a caller may leave the variable
/// uninitialized and still get a defined value.
///
/// A real segment has at least two points; the router emits Manhattan geometry only, so
/// consecutive points always share an x or a y.
pub export fn cktimg_wire_segment_points(
    sch: ?*const Sch,
    w: usize,
    s: usize,
    xy: ?*?[*]const i32,
) usize {
    // Written before any check, so a caller may leave the variable uninitialized.
    if (xy) |p| p.* = null;
    if (s >= cktimg_wire_segment_count(sch, w)) return 0;

    const phys = sch.?.placed.physical;
    const seg = phys.net_seg[w] + s;
    const pts = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
    // `Pt` is two `i32` with no padding, so the router's array already IS the flat
    // x0,y0,x1,y1,... array C asked for. Nothing is copied or reshaped.
    if (xy) |p| p.* = @ptrCast(pts.ptr);
    return pts.len;
}

// ---------------------------------------------------------------------------
// Junctions
// ---------------------------------------------------------------------------

/// Number of junction dots — points where three or more same-net arms meet. 0 for a
/// null handle. A two-arm corner is not a junction and gets no dot.
pub export fn cktimg_junction_count(sch: ?*const Sch) usize {
    const s = sch orelse return 0;
    return s.placed.physical.junctions.len;
}

/// Coordinates of junction `j`. Same out-parameter convention as `cktimg_device_pos`.
pub export fn cktimg_junction(sch: ?*const Sch, j: usize, x: ?*i32, y: ?*i32) bool {
    const s = sch orelse return false;
    if (j >= s.placed.physical.junctions.len) return false;
    return outPt(s.placed.physical.junctions[j], x, y);
}

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------
//
// New in this port. The Rust ABI had no way to expose them, so a foreign renderer drew
// a schematic that silently omitted every net the router could not connect — the
// drawing looked complete and was wrong. A label is a real guarantee, not a shape gap:
// one is emitted only after the lattice search has proven no tree exists.

/// Number of net labels: nets that could not be routed and were dropped to name tags.
/// 0 for a null handle, and 0 is the normal case.
pub export fn cktimg_label_count(sch: ?*const Sch) usize {
    const s = sch orelse return 0;
    return s.placed.physical.labels.len;
}

/// Name of the net label `l` stands in for.
///
/// BORROWED from the string pool; valid until `cktimg_sch_free`. Null on a miss.
pub export fn cktimg_label_net(sch: ?*const Sch, l: usize) ?[*:0]const u8 {
    const s = sch orelse return null;
    if (l >= s.placed.physical.labels.len) return null;
    const net = s.placed.physical.labels[l].net;
    if (net == .none) return null;
    return s.placed.strings.getZ(s.placed.ir.net_name[net.i()]);
}

/// Anchor point of label `l` — left edge on the baseline, the same anchor semantics as
/// `cktimg_device_refdes_anchor`. Same out-parameter convention as `cktimg_device_pos`.
pub export fn cktimg_label_xy(sch: ?*const Sch, l: usize, x: ?*i32, y: ?*i32) bool {
    const s = sch orelse return false;
    if (l >= s.placed.physical.labels.len) return false;
    return outPt(s.placed.physical.labels[l].at, x, y);
}

// ---------------------------------------------------------------------------
// Drawing: bounds and per-device symbol geometry
// ---------------------------------------------------------------------------
//
// The Rust ABI exposed positions and orientations but not the symbol bodies, so a C
// consumer could place a schematic and had no way to *draw* one — it had to hard-code
// its own copy of 96 symbols and the mirror-then-rotate order, which is exactly the
// duplication ARCHITECTURE.md §2 says produces two renderers that disagree. These
// accessors hand over the same `geom` answers our own emitters use.
//
// Every point below comes back **placed**: oriented by the device's `Orient` and
// translated to its position. A caller never applies a transform and therefore never
// applies the wrong one.

/// Bounding box over every drawn thing: device bodies, wire vertices, junctions and
/// labels.
///
/// Writes the two corners through the four out-pointers, each of which may be null, and
/// returns true. Returns false and writes nothing for a null handle or an empty layout
/// (no devices and no wires).
///
/// Excludes render padding — that is the caller's to add — and excludes refdes and
/// group-frame text, which are placed by `cktimg_device_refdes_anchor` and would make
/// this box depend on a label pass a caller may not run. `min` is top-left: y increases
/// downwards.
pub export fn cktimg_bounds(
    sch: ?*const Sch,
    min_x: ?*i32,
    min_y: ?*i32,
    max_x: ?*i32,
    max_y: ?*i32,
) bool {
    const s = sch orelse return false;
    const r = geom.bounds(s.placed.ir, s.placed.physical, table()) orelse return false;
    return outRect(r, min_x, min_y, max_x, max_y);
}

/// Placed bounding box of one device's symbol. Same convention as `cktimg_bounds`;
/// false on a null handle or out-of-range index.
///
/// This is the box the router blocked against and the placer collided labels against,
/// so a renderer highlighting a device highlights exactly what the layout reserved.
pub export fn cktimg_device_bounds(
    sch: ?*const Sch,
    d: usize,
    min_x: ?*i32,
    min_y: ?*i32,
    max_x: ?*i32,
    max_y: ?*i32,
) bool {
    const s = device(sch, d) orelse return false;
    const r = geom.deviceRect(s.placed.ir, s.placed.physical, table(), .at(d));
    return outRect(r, min_x, min_y, max_x, max_y);
}

/// Number of draw primitives in device `d`'s symbol body. 0 on a miss.
///
/// Ops are in table order, which is stroke order: a renderer emitting them in sequence
/// reproduces our output exactly, including overlap.
pub export fn cktimg_device_op_count(sch: ?*const Sch, d: usize) usize {
    const class = classOf(sch, d) orelse return 0;
    return class.draw.len;
}

/// Which primitive op `o` of device `d` is, as a `CktimgOpKind`.
///
/// Returns `CKTIMG_OP_NONE` (255) on a null handle or an out-of-range device or op
/// index, so a caller's `switch` has a defined miss arm instead of mistaking a miss for
/// a line.
pub export fn cktimg_device_op_kind(sch: ?*const Sch, d: usize, o: usize) u8 {
    const op = opAt(sch, d, o) orelse return @intFromEnum(OpKind.none);
    return @intFromEnum(@as(OpKind, switch (op) {
        .line => .line,
        .polyline => .polyline,
        .circle => .circle,
        .text => .text,
    }));
}

/// Placed points of a line or polyline op, written into the caller's buffer.
///
/// Returns the point count the op has — 2 for a line, its length for a polyline — always,
/// regardless of `cap`, so the two-call sizing idiom works. When `xy` is non-null,
/// writes `min(count, cap)` points as a flat `x0,y0,x1,y1,…` array of `2 * n`
/// `int32_t`s.
///
/// Points are **transformed**: mirror-then-rotate by the device's orientation, then
/// translated by its position, via `ids.Orient.apply` — the single definition of that
/// order in the program. This is the whole point of the accessor. A caller that
/// re-applies a transform gets a doubly-rotated symbol.
///
/// The result is a copy into the caller's buffer rather than a borrowed pointer,
/// because a transformed point does not exist anywhere in memory to borrow. That is the
/// one place in this file where data is materialized, and it is bounded by the op's own
/// point count.
///
/// Returns 0 and writes nothing on a null handle, an out-of-range index, or an op that
/// is a circle or text (use the extractors below).
pub export fn cktimg_device_op_points(
    sch: ?*const Sch,
    d: usize,
    o: usize,
    xy: ?[*]i32,
    cap: usize,
) usize {
    const op = opAt(sch, d, o) orelse return 0;
    const s = sch.?;
    const orient = s.placed.ir.dev_orient[d];
    const base = s.placed.physical.pos[d];

    // A line's two endpoints need somewhere to live for the loop below; a polyline already
    // has an array. Either way the transformed points are materialized only into the
    // caller's buffer.
    var pair: [2]Pt = undefined;
    const pts: []const Pt = switch (op) {
        .line => |l| blk: {
            pair = .{ l.a, l.b };
            break :blk &pair;
        },
        .polyline => |ps| ps,
        .circle, .text => return 0,
    };

    if (xy) |out| {
        for (pts[0..@min(pts.len, cap)], 0..) |p, k| {
            const q = base.add(orient.apply(p));
            out[2 * k] = q.x;
            out[2 * k + 1] = q.y;
        }
    }
    return pts.len;
}

/// Placed centre and radius of a circle op.
///
/// The centre is transformed as in `cktimg_device_op_points`; the radius is **not** —
/// rotation and mirroring preserve it, and scaling does not exist in this coordinate
/// system. Any out-pointer may be null.
///
/// Returns false and writes nothing on a null handle, an out-of-range index, or an op
/// that is not a circle.
pub export fn cktimg_device_op_circle(
    sch: ?*const Sch,
    d: usize,
    o: usize,
    cx: ?*i32,
    cy: ?*i32,
    r: ?*i32,
) bool {
    const op = opAt(sch, d, o) orelse return false;
    const c = switch (op) {
        .circle => |c| c,
        else => return false,
    };
    const s = sch.?;
    if (r) |q| q.* = c.r;
    return outPt(s.placed.physical.pos[d].add(s.placed.ir.dev_orient[d].apply(c.c)), cx, cy);
}

/// Text of a text op — a pin label or a block title — plus its placed anchor and size.
///
/// Returns the string BORROWED from the class table (static for a builtin, the
/// registry's arena for a host class), or null on a null handle, an out-of-range index,
/// or an op that is not text. Same NUL-terminator invariant as `cktimg_device_class`.
///
/// `x`/`y` receive the glyph **centre**, transformed by the device's orientation and
/// position. `size` receives the font size in grid units. Any out-pointer may be null.
///
/// Orientation moves where symbol text sits, never how it reads: draw it upright
/// regardless of `cktimg_device_rot`, or a mirrored flip-flop renders `KLC`. The forced
/// advance is `catalog.textWidth(s, size)` and both bundled renderers pin the glyph box
/// to exactly that width, which is why the collision boxes the placer used are the
/// boxes a consumer actually draws.
pub export fn cktimg_device_op_text(
    sch: ?*const Sch,
    d: usize,
    o: usize,
    x: ?*i32,
    y: ?*i32,
    size: ?*u8,
) ?[*:0]const u8 {
    const op = opAt(sch, d, o) orelse return null;
    const t = switch (op) {
        .text => |t| t,
        else => return null,
    };
    const s = sch.?;
    if (size) |q| q.* = t.size;
    _ = outPt(s.placed.physical.pos[d].add(s.placed.ir.dev_orient[d].apply(t.at)), x, y);
    return cstr(t.s);
}

// ---------------------------------------------------------------------------
// Host symbol registration
// ---------------------------------------------------------------------------
//
// A schematic editor's project symbols are only known at run time, so they are built up
// call by call and then registered: a builder, not a struct across the ABI. No struct
// layout to keep in sync between two languages, and variable-length pin and geometry
// lists need no caller-side allocation.
//
// `begin` / `pin` / `line` / `circle` / `polyline` / `text` / `register` is ONE
// TRANSACTION on ONE process-global builder. Calls are serialized internally so two
// threads cannot corrupt the builder, but two threads interleaving *different* classes
// will interleave their pins into one class. Build a class from one thread.

/// Begin a class named `name`, discarding any unfinished one.
///
/// `name` is copied and folded to lowercase, matching the interner, so an instance
/// referencing it resolves case-insensitively like every other SPICE identifier.
///
/// Returns false when `name` is null. Discarding an unfinished class is deliberate: a
/// caller that abandoned a definition halfway should not have its leftovers merged into
/// the next one.
pub export fn cktimg_class_begin(name: ?[*:0]const u8) bool {
    const n = name orelse return false;
    lockRegistry();
    defer reg_lock.unlock();

    builderReset();
    const src = std.mem.span(n);
    const folded = b_arena.allocator().alloc(u8, src.len) catch return false;
    for (src, folded) |c, *dst| dst.* = std.ascii.toLower(c);
    b_name = folded;
    return true;
}

/// Append a terminal at `(x, y)` in the canonical device frame — origin at the device
/// centre, y downwards, bipole terminals conventionally at x = -20 and x = +20.
///
/// **Pin order is the node order** an `X` instance is read in, so
/// `XDUT in out vdd gnd my_opamp` binds `in` to the first pin registered.
///
/// `role` is a `CktimgRole` wire value; anything outside 0..9 is rejected. Roles drive
/// placement, not rendering: control terminals attract driving nets, conducting ones
/// join the spine walk. Use `CKTIMG_ROLE_PASSIVE` when in doubt.
///
/// Returns false on a null name, an unknown role, or no class in progress.
pub export fn cktimg_class_pin(name: ?[*:0]const u8, role: u8, x: i32, y: i32) bool {
    const n = name orelse return false;
    const r = Role.toTerminal(role) orelse return false;
    lockRegistry();
    defer reg_lock.unlock();
    if (b_name == null) return false;

    const a = b_arena.allocator();
    const copy = a.dupe(u8, std.mem.span(n)) catch return false;
    b_terms.append(a, .{ .name = copy, .role = r, .at = .{ .x = x, .y = y } }) catch return false;
    return true;
}

/// Append a line to the symbol body, in the canonical device frame.
///
/// Returns false when no class is in progress.
pub export fn cktimg_class_line(x0: i32, y0: i32, x1: i32, y1: i32) bool {
    return appendOp(DrawOp.ln(x0, y0, x1, y1));
}

/// Append one body op to the class in progress. Caller-facing failure modes are exactly
/// "no class begun" and "out of memory", which is why all four geometry entry points
/// share this and none of them repeats the locking.
fn appendOp(op: DrawOp) bool {
    lockRegistry();
    defer reg_lock.unlock();
    if (b_name == null) return false;
    b_draw.append(b_arena.allocator(), op) catch return false;
    return true;
}

/// Append a circle to the symbol body. Returns false when no class is in progress.
pub export fn cktimg_class_circle(cx: i32, cy: i32, r: i32) bool {
    return appendOp(DrawOp.circ(cx, cy, r));
}

/// Append a polyline from a flat `x0,y0,x1,y1,…` array of `2 * count` values.
///
/// The points are **copied** into the builder; the caller keeps ownership of `xy` and
/// may free it as soon as this returns. That copy is why the Rust had to `Box::leak`
/// here and this does not: the registry owns an arena, so a host that re-registers on
/// every edit does not leak a polyline per edit.
///
/// A closed shape repeats its first point as its last. Returns false on a null `xy`,
/// `count < 2`, or no class in progress.
pub export fn cktimg_class_polyline(xy: ?[*]const i32, count: usize) bool {
    const flat = xy orelse return false;
    if (count < 2) return false;

    lockRegistry();
    defer reg_lock.unlock();
    if (b_name == null) return false;

    const a = b_arena.allocator();
    const pts = a.alloc(Pt, count) catch return false;
    for (pts, 0..) |*p, k| p.* = .{ .x = flat[2 * k], .y = flat[2 * k + 1] };
    b_draw.append(a, .{ .polyline = pts }) catch return false;
    return true;
}

/// Append upright text centred on `(x, y)` — a pin label or a block title.
///
/// The string is copied. `size` is the font size in grid units; the forced advance is
/// `catalog.textWidth(s, size)`, and both bundled renderers pin the glyph box to that
/// width, so the class bounding box computed from this op is what a viewer actually
/// shows.
///
/// Returns false on a null `s` or no class in progress.
pub export fn cktimg_class_text(s: ?[*:0]const u8, x: i32, y: i32, size: u8) bool {
    const str = s orelse return false;
    lockRegistry();
    defer reg_lock.unlock();
    if (b_name == null) return false;

    const a = b_arena.allocator();
    const copy = a.dupe(u8, std.mem.span(str)) catch return false;
    b_draw.append(a, .{ .text = .{ .at = .{ .x = x, .y = y }, .s = copy, .size = size } }) catch
        return false;
    return true;
}

/// Register the class under construction and return its `SymbolIdx`, or `SIZE_MAX` on
/// error.
///
/// Errors, all returning `SIZE_MAX` and leaving the registry unchanged: no class begun,
/// no pins registered, a name that shadows a builtin, a name already registered with
/// *different* terminals, or out of memory. An exact repeat — same folded name, same
/// terminals in the same order — is idempotent and returns the existing index without
/// allocating, which is what lets a host re-scan its symbol library on every parse.
///
/// Supply no geometry and the symbol is drawn as the generated labelled box the builtin
/// flip-flops and converters use: outline, pin names, class name as the title. Supply
/// geometry and it is used verbatim, so the output matches the editor's own canvas.
///
/// The returned index never changes meaning: registration is append-only, with no
/// removal, no compaction and no re-sorting, because a `Placed` produced earlier may
/// still hold it.
///
/// Consumes the in-progress class either way — a failed registration does not leave a
/// builder for the next call to inherit.
pub export fn cktimg_class_register() usize {
    lockRegistry();
    defer reg_lock.unlock();
    // Consumed either way: a failed registration leaves nothing for the next call to
    // inherit, which is what keeps `begin`/`register` a transaction.
    defer builderReset();

    const name = b_name orelse return std.math.maxInt(usize);
    const idx = g_table.register(.{
        .name = name,
        .terminals = b_terms.items,
        .draw = if (b_draw.items.len == 0) null else b_draw.items,
    }) catch return std.math.maxInt(usize);
    return idx.i();
}
