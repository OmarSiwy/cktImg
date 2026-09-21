//! `cktimg-json` — the command line front end for the structured export.
//!
//! `json.zig` calls itself "the seam for every tool that post-processes geometry", but a
//! Python script cannot call a Zig function any more than a `.tex` document can. This
//! file is the missing edge of that graph, exactly as `tex_main.zig` is for TikZ: bytes
//! in (a SPICE deck), bytes out (the placed schematic as JSON), so a Makefile or an
//! interpreter can drive the library without linking it.
//!
//! ## Why an executable and not the C ABI
//!
//! `cktimg_run_json` already exists and is the right call for a C consumer. It is the
//! wrong shape for everyone else: a Python, Tcl or shell consumer would need an FFI
//! binding, a build step and a copy of the static library to reach a function whose
//! entire contract is "text in, text out". One binary on `$PATH` costs those consumers
//! nothing and costs this repository forty lines.
//!
//! The first such consumer is an xschem `.sch` emitter — schematic-editor formats are
//! narrow, quirky and change on someone else's schedule, which is precisely the kind of
//! knowledge that should live in a script next to the flow that needs it rather than in
//! the placement engine.
//!
//! ## Not gated on a build option
//!
//! Unlike `tex_main.zig`, this front end is always built. `root.json` is a real module
//! regardless of build options — only `root.latex` is `void` without its flag — so there
//! is no configuration in which compiling this file fails.
//!
//! ## Data flow and allocation
//!
//! ```
//! argv ──► Options
//! file ──► source bytes ──► Pipeline.run ──► Placed ──► json.writeWith ──► Writer
//! ```
//!
//! One arena for everything with the process's lifetime, plus the `Pipeline`'s own
//! arenas. Output streams straight to the destination and is never materialized — the
//! property `json.zig` was written around, and the reason this is not a thin wrapper over
//! `cktimg_run_json`, which allocates the whole document as a string.
//!
//! ## Target manifests live here, not in the library
//!
//! `--target <manifest.json>` resolves every device's class to a backend's native symbol
//! and pin order (see `docs/TARGETS.md`). The manifest is read, parsed and validated by
//! *this file* — `libcktimg` never learns the format exists. That boundary is deliberate:
//! a `cktimg_target_load()` would couple every consumer to our file format and our I/O to
//! buy them one `std.json` call they can write themselves, which is the "your file format"
//! coupling `netlist/source.zig` already refuses. Three tiers stay reachable:
//!
//!   1. `cktimg-json --target targets/xschem.json in.spice` — symbols already resolved,
//!      the caller never links the library;
//!   2. link the library, walk the C ABI, parse the manifest yourself;
//!   3. ignore manifests; `cktimg_device_class()` is the whole vocabulary.
//!
//! The manifest is *data we ship*, not code we run: `targets/*.json` is editable by the
//! person whose symbol library it describes, and `tests/targets.zig` validates every
//! shipped one against the catalog so a typo cannot silently miswire a schematic.

const std = @import("std");
const ckt = @import("cktimg");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What the command line asked for.
///
/// All slices are borrowed from the argv arena and are valid for the whole process.
pub const Options = struct {
    /// The netlist to place. Required; a pipeline user can name `/dev/stdin`.
    netlist: []const u8,
    /// Where to write. `null` means stdout, so the program composes in a shell pipeline.
    out: ?[]const u8 = null,
    /// Path to a `lint.zon`. `null` means built-in defaults.
    config: ?[]const u8 = null,
    /// Path to a target manifest. `null` means no `"target"` block, and then the document
    /// is byte-for-byte what this tool emitted before manifests existed.
    target: ?[]const u8 = null,
};

const usage =
    \\cktimg-json — place a SPICE netlist and emit the geometry as JSON
    \\
    \\Usage: cktimg-json [options] <netlist.spice> [out.json]
    \\
    \\Writes the placed schematic to <out.json>, or to stdout when no output path is
    \\given. The document carries devices (class, position, orientation, pins), nets,
    \\routed wire polylines, junction dots and labels — see src/json.zig for the schema.
    \\
    \\Options:
    \\  --config <path>   read layout settings from a lint.zon file
    \\  --target <path>   resolve device classes through a target manifest and add a
    \\                    "target" block to the document (see docs/TARGETS.md)
    \\  -h, --help        show this message
    \\
    \\Exit status is 0 on success, non-zero if the netlist is missing or unreadable, or
    \\if a --target manifest is unreadable, malformed or disagrees with the catalog.
    \\
;

/// Parse argv, place the netlist, emit the document.
///
/// Exit status: 0 when the document was written, 1 when the command line was malformed or
/// the netlist could not be read. A netlist the front end only partly understands is
/// *not* a failure — it still places, and the ignored/skipped counts go to stderr as a
/// note, because partial geometry is more useful than a refusal (same policy as
/// `Pipeline.run` and `cktimg-tex`).
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(io, argv) orelse return;

    const cwd: std.Io.Dir = .cwd();

    // Read before placing: a missing file is by far the most common failure and it should
    // be named with its path. 4 MiB is well past any hand-written deck.
    const raw = cwd.readFileAlloc(io, opts.netlist, arena, .limited(1 << 22)) catch |err| {
        std.log.err("cannot read netlist '{s}': {t}", .{ opts.netlist, err });
        std.process.exit(1);
    };

    // A *named* config that is absent is an error: the user asked for those settings, and
    // silently placing with defaults would look like the file was honoured.
    const cfg = if (opts.config) |path| blk: {
        const text = cwd.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
            std.log.err("cannot read config '{s}': {t}", .{ path, err });
            std.process.exit(1);
        };
        break :blk try ckt.Config.parse(arena, text, null);
    } else ckt.Config.default;

    // Parsed before placing, for the same reason the netlist is read first: a manifest
    // typo should be reported in milliseconds, not after a place-and-route.
    const target: ?Target = if (opts.target) |path| blk: {
        const text = cwd.readFileAlloc(io, path, arena, .limited(1 << 22)) catch |err| {
            std.log.err("cannot read target manifest '{s}': {t}", .{ path, err });
            std.process.exit(1);
        };
        break :blk switch (try Target.parse(arena, path, text)) {
            .ok => |t| t,
            .err => |msg| {
                std.log.err("{s}", .{msg});
                std.process.exit(1);
            },
        };
    } else null;

    const src = try withRails(arena, raw);

    var pipeline: ckt.Pipeline = .init(gpa, &cfg);
    defer pipeline.deinit();
    const placed, const report = try pipeline.run(src);

    // An empty host table, for the reason `cktimg-tex` gives: `Pipeline.run` owns the
    // table it builds internally and never hands it out, so every `SymbolIdx` that
    // reaches here resolves out of the comptime catalog. `writeWith` rather than `write`
    // because it degrades by lookup rather than by assert if that ever stops holding.
    var table: ckt.devices.host.Table = .init(gpa);
    defer table.deinit();

    // Every class this schematic uses must be resolvable *before* a byte is written, so an
    // `"unmapped": {"mode": "error"}` manifest fails without leaving a truncated file
    // behind.
    if (target) |t| if (t.missingClass(placed)) |name| {
        std.log.err(
            "{s}: no mapping for class \"{s}\", and \"unmapped\" is \"error\"",
            .{ t.path, name },
        );
        std.process.exit(1);
    };

    var buf: [64 * 1024]u8 = undefined;
    const dest: std.Io.File = if (opts.out) |path|
        cwd.createFile(io, path, .{}) catch |err| {
            std.log.err("cannot create '{s}': {t}", .{ path, err });
            std.process.exit(1);
        }
    else
        .stdout();
    var dest_w = dest.writerStreaming(io, &buf);

    if (target) |t| {
        // The one case that cannot stream: the `"target"` member is appended *inside* the
        // document object, so the closing brace `json.writeWith` already emitted has to be
        // taken back. Paid only when `--target` is given — without it the streaming call
        // below is untouched, which is what makes the default output byte-identical by
        // construction rather than by comparison.
        var doc: Writer.Allocating = .init(arena);
        try ckt.json.writeWith(placed, &table, &cfg, &doc.writer);
        const bytes = doc.written();
        if (!std.mem.endsWith(u8, bytes, "\n}")) {
            std.log.err("internal: json document does not end with a closing brace", .{});
            std.process.exit(1);
        }
        try dest_w.interface.writeAll(bytes[0 .. bytes.len - 2]);
        try dest_w.interface.writeAll(",\n");
        try t.writeBlock(placed, &dest_w.interface);
        try dest_w.interface.writeAll("\n}");
    } else {
        try ckt.json.writeWith(placed, &table, &cfg, &dest_w.interface);
    }
    try dest_w.interface.flush();
    // Closed here rather than by `defer` so that stdout — which this process does not own
    // — is left alone.
    if (opts.out != null) dest.close(io);

    if (report.ignored.len > 0 or report.skipped.len > 0) {
        std.log.warn("{s}: {d} card(s) ignored, {d} skipped", .{
            opts.netlist,
            report.ignored.len,
            report.skipped.len,
        });
    }
}

// ---------------------------------------------------------------------------
// Target manifests.
//
// Everything below is front-end code and deliberately stays here: see the module header
// for why the library never learns this format. `docs/TARGETS.md` is the normative spec;
// this is its only implementation, and `tests/targets.zig` is what keeps the two honest.
// ---------------------------------------------------------------------------

/// One class's mapping: the target's symbol plus the order it wants the pins in.
pub const ClassMap = struct {
    /// Whatever the target calls the symbol — a `.sym` path, a `#fragment`, an id. Opaque
    /// to this tool; it is copied into the output and never interpreted.
    sym: []const u8,
    /// Catalog pin slot for each target pin slot. **Empty means the identity order**, which
    /// is both the common case and the only sane answer for a fallback box, so it is not
    /// materialized. Validated to be a permutation at parse time — a typo here silently
    /// miswires a schematic, which is the worst failure this tool has.
    order: []const u8 = &.{},
    /// Per-class payload, passed through verbatim. This is where CSS classes, stable ids
    /// and anything else target-specific lives, so the schema does not have to become the
    /// union of every backend's wishes.
    style: ?std.json.Value = null,
};

/// What to do with a catalog class the manifest does not mention.
pub const Unmapped = union(enum) {
    /// Emit it with a stand-in symbol and the catalog's own pin order.
    box: ClassMap,
    /// Leave it out of the `"target"` block entirely. It is still in `"devices"`.
    skip,
    /// Refuse to emit the document at all.
    fail,
};

/// A validated target manifest: catalog class -> symbol and pin order.
///
/// Every slice is arena-owned; nothing here borrows the manifest text except through that
/// arena, which outlives the process.
pub const Target = struct {
    /// Where it came from. Carried so every later message can name the file.
    path: []const u8,
    /// The `"target"` key — the backend's own name for itself.
    name: []const u8,
    version: u32,
    /// Passed through verbatim; this tool never applies a scale. The geometry in the
    /// document stays in canonical integer grid units, because rescaling here would turn
    /// a deterministic integer document into float formatting.
    units: ?std.json.Value,
    /// Target-wide passthrough, the sibling of `ClassMap.style`.
    style: ?std.json.Value,
    unmapped: Unmapped,
    /// Indexed by `SymbolIdx`; `null` where the manifest says nothing. One slot per builtin
    /// class, so resolution is an array index rather than a hash lookup.
    classes: []const ?ClassMap,

    /// Either a usable manifest or one sentence explaining why not.
    ///
    /// A union rather than an error set because the *message* is the product: "class
    /// \"nmoss\" is not in the cktImg catalog" is actionable and `error.BadManifest` is not.
    pub const Result = union(enum) { ok: Target, err: []const u8 };

    /// How many catalog classes the manifest maps explicitly.
    pub fn mappedCount(self: Target) usize {
        var n: usize = 0;
        for (self.classes) |c| n += @intFromBool(c != null);
        return n;
    }

    /// The first class used by `placed` that the manifest does not map, when `unmapped` is
    /// `error`. `null` means the document can be emitted.
    ///
    /// Checked up front so a refusal never leaves a half-written file behind.
    pub fn missingClass(self: Target, placed: ckt.Placed) ?[]const u8 {
        if (self.unmapped != .fail) return null;
        for (0..placed.ir.deviceCount()) |d| {
            const s = placed.ir.dev_symbol[d];
            if (s.i() >= self.classes.len or self.classes[s.i()] == null) {
                return ckt.devices.catalog.at(s).name;
            }
        }
        return null;
    }

    /// Parse and validate `text`, which came from `path`.
    ///
    /// Validates far more than JSON well-formedness, because this is a trust boundary: an
    /// unknown class name, a `pins` array that is not a permutation of that class's catalog
    /// terminals, a duplicate class key, a version this build does not understand. Each is
    /// reported with the file and the offending key.
    ///
    /// Everything returned is allocated from `arena`. Errors: `OutOfMemory`; every other
    /// problem is a `.err` message.
    pub fn parse(arena: Allocator, path: []const u8, text: []const u8) Allocator.Error!Result {
        const catalog = ckt.devices.catalog;

        var scanner: std.json.Scanner = .initCompleteInput(arena, text);
        var diag: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&diag);
        const root = std.json.parseFromTokenSourceLeaky(
            std.json.Value,
            arena,
            &scanner,
            .{},
        ) catch |err| return fail(arena, "{s}:{d}:{d}: malformed JSON ({t})", .{
            path, diag.getLine(), diag.getColumn(), err,
        });

        const obj = switch (root) {
            .object => |o| o,
            else => return fail(arena, "{s}: top level must be an object", .{path}),
        };

        const name = switch (obj.get("target") orelse
            return fail(arena, "{s}: missing \"target\"", .{path})) {
            .string => |s| s,
            else => return fail(arena, "{s}: \"target\" must be a string", .{path}),
        };

        const version: u32 = switch (obj.get("version") orelse
            return fail(arena, "{s}: missing \"version\"", .{path})) {
            .integer => |v| if (v == 1) 1 else return fail(
                arena,
                "{s}: \"version\" is {d}, this build understands 1",
                .{ path, v },
            ),
            else => return fail(arena, "{s}: \"version\" must be an integer", .{path}),
        };

        const unmapped: Unmapped = switch (obj.get("unmapped") orelse
            return fail(arena, "{s}: missing \"unmapped\"", .{path})) {
            .object => |u| blk: {
                const mode = switch (u.get("mode") orelse
                    return fail(arena, "{s}: \"unmapped\" has no \"mode\"", .{path})) {
                    .string => |s| s,
                    else => return fail(arena, "{s}: \"unmapped.mode\" must be a string", .{path}),
                };
                if (std.mem.eql(u8, mode, "skip")) break :blk .skip;
                if (std.mem.eql(u8, mode, "error")) break :blk .fail;
                if (!std.mem.eql(u8, mode, "box")) return fail(
                    arena,
                    "{s}: \"unmapped.mode\" is \"{s}\", expected box, skip or error",
                    .{ path, mode },
                );
                const sym = switch (u.get("sym") orelse return fail(
                    arena,
                    "{s}: \"unmapped.mode\" is \"box\" but there is no \"sym\" to draw it with",
                    .{path},
                )) {
                    .string => |s| s,
                    else => return fail(arena, "{s}: \"unmapped.sym\" must be a string", .{path}),
                };
                if (sym.len == 0) return fail(arena, "{s}: \"unmapped.sym\" is empty", .{path});
                break :blk .{ .box = .{ .sym = sym, .style = u.get("style") } };
            },
            else => return fail(arena, "{s}: \"unmapped\" must be an object", .{path}),
        };

        const classes_obj = switch (obj.get("classes") orelse
            return fail(arena, "{s}: missing \"classes\"", .{path})) {
            .object => |o| o,
            else => return fail(arena, "{s}: \"classes\" must be an object", .{path}),
        };

        const classes = try arena.alloc(?ClassMap, catalog.builtin_count);
        @memset(classes, null);

        // Iterating the parsed object is safe for determinism (CONVENTIONS.md §7): nothing
        // is *emitted* in this order — each entry lands in `classes` at its own catalog
        // index, and the output walks that array. The order only decides which of two bad
        // entries is reported first.
        for (classes_obj.keys(), classes_obj.values()) |key, val| {
            const idx = catalog.indexOf(key) orelse return fail(
                arena,
                "{s}: class \"{s}\" is not in the cktImg catalog",
                .{ path, key },
            );
            const class = catalog.at(idx);
            const entry = switch (val) {
                .object => |o| o,
                else => return fail(arena, "{s}: class \"{s}\" must be an object", .{ path, key }),
            };
            const sym = switch (entry.get("sym") orelse
                return fail(arena, "{s}: class \"{s}\" has no \"sym\"", .{ path, key })) {
                .string => |s| s,
                else => return fail(arena, "{s}: class \"{s}\": \"sym\" must be a string", .{ path, key }),
            };
            if (sym.len == 0) return fail(arena, "{s}: class \"{s}\": \"sym\" is empty", .{ path, key });

            var order: []const u8 = &.{};
            if (entry.get("pins")) |pins| {
                order = switch (try permutation(arena, class.*, pins)) {
                    .ok => |o| o,
                    .err => |why| return fail(
                        arena,
                        "{s}: class \"{s}\": {s} (catalog terminals are {f})",
                        .{ path, key, why, TermList{ .class = class.* } },
                    ),
                };
            }

            classes[idx.i()] = .{ .sym = sym, .order = order, .style = entry.get("style") };
        }

        return .{ .ok = .{
            .path = path,
            .name = name,
            .version = version,
            .units = obj.get("units"),
            .style = obj.get("style"),
            .unmapped = unmapped,
            .classes = classes,
        } };
    }

    /// Write the `"target"` member — key included, no trailing newline — at indent level 1,
    /// so the caller can splice it into `json.zig`'s document.
    ///
    /// Per device: the resolved symbol and the pin list **already reordered**, so a backend
    /// reads it straight out and does no mapping of its own. `"device"` is the index into
    /// the document's own `devices` array, which is what makes the two joinable without
    /// matching on names.
    ///
    /// Errors: `WriteFailed`. Allocation-free.
    pub fn writeBlock(self: Target, placed: ckt.Placed, w: *Writer) Writer.Error!void {
        const catalog = ckt.devices.catalog;
        const ir = placed.ir;
        const pool = placed.strings;

        try ckt.json.writeIndent(w, 1);
        try w.writeAll("\"target\": {\n");

        try ckt.json.writeIndent(w, 2);
        try w.writeAll("\"name\": ");
        try ckt.json.writeString(w, self.name);
        try w.print(",\n", .{});

        try ckt.json.writeIndent(w, 2);
        try w.print("\"version\": {d},\n", .{self.version});

        if (self.units) |v| {
            try ckt.json.writeIndent(w, 2);
            try w.writeAll("\"units\": ");
            try writeValue(w, v);
            try w.writeAll(",\n");
        }
        if (self.style) |v| {
            try ckt.json.writeIndent(w, 2);
            try w.writeAll("\"style\": ");
            try writeValue(w, v);
            try w.writeAll(",\n");
        }

        try ckt.json.writeIndent(w, 2);
        try w.writeAll("\"devices\": [");
        var wrote_any = false;
        for (0..ir.deviceCount()) |d| {
            const s = ir.dev_symbol[d];
            const class = catalog.at(s);
            const map: ClassMap = if (s.i() < self.classes.len and self.classes[s.i()] != null)
                self.classes[s.i()].?
            else switch (self.unmapped) {
                .box => |b| b,
                // `.fail` cannot reach here: `missingClass` refused before anything opened
                // the output. Skipping is the safe residue either way.
                .skip, .fail => continue,
            };

            try w.writeAll(if (wrote_any) ",\n" else "\n");
            wrote_any = true;

            try ckt.json.writeIndent(w, 3);
            try w.writeAll("{\n");
            try ckt.json.writeIndent(w, 4);
            try w.print("\"device\": {d},\n", .{d});
            try ckt.json.writeIndent(w, 4);
            try w.writeAll("\"name\": ");
            try ckt.json.writeString(w, pool.get(ir.dev_name[d]));
            try w.writeAll(",\n");
            try ckt.json.writeIndent(w, 4);
            try w.writeAll("\"class\": ");
            try ckt.json.writeString(w, class.name);
            try w.writeAll(",\n");
            try ckt.json.writeIndent(w, 4);
            try w.writeAll("\"sym\": ");
            try ckt.json.writeString(w, map.sym);
            try w.writeAll(",\n");
            if (map.style) |v| {
                try ckt.json.writeIndent(w, 4);
                try w.writeAll("\"style\": ");
                try writeValue(w, v);
                try w.writeAll(",\n");
            }

            const lo, const hi = ir.pinRange(.at(d));
            try ckt.json.writeIndent(w, 4);
            try w.writeAll("\"pins\": [");
            const n = hi - lo;
            // The permutation is applied only when it covers exactly this device's pins.
            // A device whose card gave it a different number of nodes than its class has
            // terminals cannot be reordered by a class-level permutation, and indexing
            // outside its pin range to try would splice in the neighbouring device's nets
            // — a silent miswire, which is the one failure this whole file exists to
            // prevent. Identity is the safe residue.
            const order: []const u8 = if (map.order.len == n) map.order else &.{};
            for (0..n) |j| {
                // An empty `order` is the identity — see `ClassMap.order`.
                const slot = if (j < order.len) order[j] else j;
                try w.writeAll(if (j == 0) "\n" else ",\n");
                try ckt.json.writeIndent(w, 5);
                try w.writeAll("{ \"term\": ");
                try ckt.json.writeString(w, if (slot < class.terminals.len)
                    class.terminals[slot].name
                else
                    "");
                try w.writeAll(", \"net\": ");
                const net = ir.pin_net[lo + slot];
                if (net == .none) {
                    try w.writeAll("null");
                } else {
                    try ckt.json.writeString(w, pool.get(ir.net_name[net.i()]));
                }
                try w.writeAll(", \"xy\": ");
                try ckt.json.writePoint(w, placed.physical.pin_xy[lo + slot]);
                try w.writeAll(" }");
            }
            if (n != 0) {
                try w.writeAll("\n");
                try ckt.json.writeIndent(w, 4);
            }
            try w.writeAll("]\n");

            try ckt.json.writeIndent(w, 3);
            try w.writeAll("}");
        }
        if (wrote_any) {
            try w.writeAll("\n");
            try ckt.json.writeIndent(w, 2);
        }
        try w.writeAll("]\n");
        try ckt.json.writeIndent(w, 1);
        try w.writeAll("}");
    }
};

/// A `.err` result, formatted into `arena`.
fn fail(arena: Allocator, comptime f: []const u8, args: anytype) Allocator.Error!Target.Result {
    return .{ .err = try std.fmt.allocPrint(arena, f, args) };
}

/// Either the catalog slots a `pins` array names, in target order, or why it is not a
/// permutation.
const Permutation = union(enum) { ok: []const u8, err: []const u8 };

/// Check that `pins` is a permutation of `class`'s terminal names and return the slot order.
///
/// The whole reason manifests are validated rather than trusted. Rejects: a non-array, a
/// non-string element, the wrong length, a name the class does not have, and the same name
/// twice — the last is the one a human actually produces, by copying a line and editing
/// half of it.
fn permutation(
    arena: Allocator,
    class: ckt.devices.catalog.DeviceClass,
    pins: std.json.Value,
) Allocator.Error!Permutation {
    const arr = switch (pins) {
        .array => |a| a,
        else => return .{ .err = "\"pins\" must be an array of terminal names" },
    };
    if (arr.items.len != class.terminals.len) return .{ .err = try std.fmt.allocPrint(
        arena,
        "\"pins\" has {d} entries, the class has {d} terminals",
        .{ arr.items.len, class.terminals.len },
    ) };

    const order = try arena.alloc(u8, arr.items.len);
    var seen: u64 = 0;
    for (arr.items, 0..) |item, j| {
        const want = switch (item) {
            .string => |s| s,
            else => return .{ .err = "\"pins\" must contain only terminal names" },
        };
        const slot: u8 = for (class.terminals, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, want)) break @intCast(i);
        } else return .{ .err = try std.fmt.allocPrint(
            arena,
            "\"{s}\" is not a terminal of this class",
            .{want},
        ) };
        // 64 bits is plenty: the widest catalog class has five terminals.
        const bit = @as(u64, 1) << @intCast(slot);
        if (seen & bit != 0) return .{ .err = try std.fmt.allocPrint(
            arena,
            "\"{s}\" appears twice in \"pins\"",
            .{want},
        ) };
        seen |= bit;
        order[j] = slot;
    }
    return .{ .ok = order };
}

/// `d, g, s` — a class's terminal names, for the tail of an error message.
const TermList = struct {
    class: ckt.devices.catalog.DeviceClass,

    pub fn format(self: TermList, w: *Writer) Writer.Error!void {
        for (self.class.terminals, 0..) |t, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(t.name);
        }
    }
};

/// Emit a passed-through manifest value on one line.
///
/// `style` and `units` are opaque on purpose (module header): re-emitting the parsed value
/// is what lets a backend invent whatever keys it needs without this file growing a case
/// for each one. Minified rather than pretty-printed because a passthrough object has no
/// business dominating the diff of a document that is mostly coordinates — and because
/// `std.json.Stringify` indents from its own root, so its idea of column zero is not this
/// document's.
fn writeValue(w: *Writer, v: std.json.Value) Writer.Error!void {
    try std.json.Stringify.value(v, .{}, w);
}

/// Parse `argv`, or print usage and return `null`.
///
/// `null` means "nothing left to do, exit 0" — that is `--help`. A malformed command line
/// exits 1 from inside, because there is no useful value to return.
///
/// The first non-option argument is the netlist, the second is the output path, and a
/// third is an error rather than being ignored.
///
/// Returned slices are borrowed from `argv`.
pub fn parseArgs(io: std.Io, argv: []const [:0]const u8) ?Options {
    var netlist: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var config: ?[]const u8 = null;
    var target: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            writeUsage(io, .stdout());
            return null;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i == argv.len) fatalUsage(io, "--config needs a path");
            config = argv[i];
        } else if (std.mem.eql(u8, a, "--target")) {
            i += 1;
            if (i == argv.len) fatalUsage(io, "--target needs a path");
            target = argv[i];
        } else if (a.len > 1 and a[0] == '-') {
            std.log.err("unknown option '{s}'", .{a});
            fatalUsage(io, "see --help");
        } else if (netlist == null) {
            netlist = a;
        } else if (out == null) {
            out = a;
        } else {
            fatalUsage(io, "too many arguments");
        }
    }

    const n = netlist orelse fatalUsage(io, "no netlist given");
    return .{ .netlist = n, .out = out, .config = config, .target = target };
}

/// Name the problem on stderr, print the usage, exit 1.
fn fatalUsage(io: std.Io, msg: []const u8) noreturn {
    std.log.err("{s}", .{msg});
    writeUsage(io, .stderr());
    std.process.exit(1);
}

/// Print the usage text to `file`, ignoring write failures — there is nowhere left to
/// report a failure to write the error message itself.
fn writeUsage(io: std.Io, file: std.Io.File) void {
    var buf: [512]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    w.interface.writeAll(usage) catch {};
    w.interface.flush() catch {};
}

/// Append the rail devices the placer needs but a SPICE deck does not carry.
///
/// See `tex_main.withRails` for why this exists. It is duplicated here for the reason
/// given there: promoting an input fix-up into the public API would make it a supported
/// library behaviour nobody asked for. The copy is load-bearing rather than incidental —
/// omitting it would make `cktimg-json` report *different geometry* for the same deck
/// than `cktimg-tex` and the gallery draw, which is a far worse bug than the duplication.
///
/// Returns `src` unchanged when neither name occurs; otherwise a fresh buffer from
/// `arena`, owned by it.
fn withRails(arena: Allocator, src: []const u8) Allocator.Error![]const u8 {
    const has_vdd = hasToken(src, "vdd");
    const has_gnd = hasToken(src, "gnd");
    if (!has_vdd and !has_gnd) return src;
    return std.fmt.allocPrint(arena, "{s}\n{s}{s}", .{
        src,
        if (has_vdd) "XVDD vdd vdd\n" else "",
        if (has_gnd) "XGND gnd gnd\n" else "",
    });
}

/// Does `src` contain `word` as a whole whitespace-delimited token, ignoring case?
///
/// Token-wise rather than a substring search, so a model named `gndcap` does not conjure a
/// ground rail.
fn hasToken(src: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, src, " \t\r\n");
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(t, word)) return true;
    }
    return false;
}
