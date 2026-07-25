//! Behavioral suite for `config.zig`: defaults, `lint.zon` parsing, and the two
//! lookups (`aliasOf`, `isLeaf`) that the front end asks on every unresolved master.
//!
//! Config is the one module where the *error* behavior is the interesting part.
//! Everything here is a style knob, and the documented trade is explicit: failing to
//! draw a schematic over a typo in a style file is the wrong outcome, so an
//! unrecognized key is reported and skipped, a malformed value leaves its default and
//! is reported, and a missing file is not an error at all. Three separate ways for a
//! naive implementation to turn a cosmetic problem into a hard failure, so all three
//! are pinned.
//!
//! Also pinned:
//!
//! - **Every default value**, one assertion per field. Defaults are documented
//!   numbers that downstream tests (`tests/place.zig` in particular) hard-code
//!   against; changing one silently re-tunes the whole fixture set.
//! - **`pdk.alias` comes out sorted** — a post-condition, not a convenience. It is
//!   what makes `aliasOf` a binary search and what keeps alias iteration
//!   reproducible, which is the determinism rule applied to config data.
//! - **A mid-string `*` is `bad_glob` and matches literally.** The supported pattern
//!   language is exactly "an optional single trailing star". A parser that silently
//!   accepted a fuller glob syntax and matched approximately would be far worse than
//!   one that refuses, because PDK leaf lists decide what gets flattened.
//! - **`Config.default` borrows only static data**, so it is usable with no arena at
//!   all — which is what makes `&Config.default` a valid argument to `Pipeline.init`.
//!
//! Expected red until the corresponding function is written — a `@panic("TODO")`
//! aborts the whole binary rather than failing one test, so the first panic names the
//! next function to implement.

const std = @import("std");
const ckt = @import("cktimg");

const Allocator = std.mem.Allocator;
const testing = std.testing;

const Config = ckt.Config;
const Diagnostic = ckt.config.Diagnostic;
const Pdk = ckt.config.Pdk;

/// Collects diagnostics for one parse. Owned by the test, freed with the test's
/// allocator — deliberately *not* the arena, so a `parse` that appended into the
/// wrong allocator shows up as a leak.
const Diags = std.ArrayList(Diagnostic);

fn hasKind(diags: Diags, kind: Diagnostic.Kind) bool {
    for (diags.items) |d| if (d.kind == kind) return true;
    return false;
}

fn hasKey(diags: Diags, kind: Diagnostic.Kind, needle: []const u8) bool {
    for (diags.items) |d| {
        if (d.kind == kind and std.mem.indexOf(u8, d.key, needle) != null) return true;
    }
    return false;
}

test "every default matches the documented value" {
    const c = Config.default;

    // Layout: spacing in host grid units, plus the two search budgets.
    try testing.expectEqual(@as(i32, 8), c.layout.abut_gap);
    try testing.expectEqual(@as(i32, 12), c.layout.tap_unit);
    try testing.expectEqual(@as(i32, 8), c.layout.track_w);
    try testing.expectEqual(@as(i32, 10), c.layout.track_h);
    try testing.expectEqual(@as(i32, 16), c.layout.margin_gap);
    try testing.expectEqual(@as(i32, 24), c.layout.bus_gap);
    try testing.expectEqual(@as(u32, 10), c.layout.enum_limit);
    try testing.expectEqual(@as(u32, 16), c.layout.refine);
    try testing.expectEqual(@as(i32, 1), c.layout.grid); // 1 == no quantization
    try testing.expectEqual(false, c.layout.strict_geometry);

    // Render: consumed only by emitters, never by place-and-route.
    try testing.expectEqualStrings("black", c.render.stroke);
    try testing.expectEqualStrings("1565c0", c.render.wire); // bare hex, no leading '#'
    try testing.expectEqual(@as(f32, 1.2), c.render.sym_w);
    try testing.expectEqual(@as(f32, 1.5), c.render.wire_w);
    try testing.expectEqual(@as(i32, 24), c.render.pad);

    // Pdk: nothing configured, both fallbacks on.
    try testing.expectEqual(@as(usize, 0), c.pdk.leaf.len);
    try testing.expectEqual(@as(usize, 0), c.pdk.alias.len);
    try testing.expectEqual(true, c.pdk.scan);
    try testing.expectEqual(true, c.pdk.unknown_as_box);

    // A zero-initialized struct literal is the same thing, so `.{}` anywhere in the
    // tree agrees with `default`.
    try testing.expectEqual(c.layout, (Config{}).layout);
    try testing.expectEqual(c.render.pad, (Config{}).render.pad);
}

test "a zon document overrides only the keys it names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var diags: Diags = .empty;
    defer diags.deinit(testing.allocator);

    const text =
        \\.{
        \\    .layout = .{
        \\        .abut_gap = 3,
        \\        .refine = 2,
        \\        .strict_geometry = true,
        \\    },
        \\    .render = .{
        \\        .stroke = "navy",
        \\        .pad = 0,
        \\    },
        \\}
    ;

    const c = try Config.parse(arena.allocator(), text, &diags);

    // Named keys took the document's value.
    try testing.expectEqual(@as(i32, 3), c.layout.abut_gap);
    try testing.expectEqual(@as(u32, 2), c.layout.refine);
    try testing.expectEqual(true, c.layout.strict_geometry);
    try testing.expectEqualStrings("navy", c.render.stroke);
    try testing.expectEqual(@as(i32, 0), c.render.pad);

    // Everything else is untouched, including sibling fields inside the same tables.
    // A parser that rebuilt `layout` from the document rather than patching the
    // default would zero these.
    try testing.expectEqual(@as(i32, 12), c.layout.tap_unit);
    try testing.expectEqual(@as(i32, 8), c.layout.track_w);
    try testing.expectEqual(@as(i32, 10), c.layout.track_h);
    try testing.expectEqual(@as(i32, 16), c.layout.margin_gap);
    try testing.expectEqual(@as(i32, 24), c.layout.bus_gap);
    try testing.expectEqual(@as(u32, 10), c.layout.enum_limit);
    try testing.expectEqual(@as(i32, 1), c.layout.grid);
    try testing.expectEqualStrings("1565c0", c.render.wire);
    try testing.expectEqual(@as(f32, 1.2), c.render.sym_w);
    try testing.expectEqual(true, c.pdk.scan);
    try testing.expectEqual(true, c.pdk.unknown_as_box);

    // A clean document produces no complaints.
    try testing.expectEqual(@as(usize, 0), diags.items.len);

    // An empty document is legal and is exactly the defaults.
    var empty_diags: Diags = .empty;
    defer empty_diags.deinit(testing.allocator);
    const d = try Config.parse(arena.allocator(), ".{}", &empty_diags);
    try testing.expectEqual(Config.default.layout, d.layout);
    try testing.expectEqual(@as(usize, 0), empty_diags.items.len);
}

test "an unrecognized key is reported, not fatal" {
    // A config written for a newer version of the tool still loads. This is the
    // documented trade and it is the one an eager `std.zon.parse` with default options
    // gets wrong, since unknown fields are an error there by default.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var diags: Diags = .empty;
    defer diags.deinit(testing.allocator);

    const text =
        \\.{
        \\    .layout = .{
        \\        .abut_gap = 3,
        \\        .no_such_knob = 7,
        \\    },
        \\    .not_a_table = .{ .whatever = 1 },
        \\}
    ;

    const c = try Config.parse(arena.allocator(), text, &diags);

    // The recognized key on either side of the unknown one still landed — an
    // implementation that abandoned the table at the first surprise would drop it.
    try testing.expectEqual(@as(i32, 3), c.layout.abut_gap);
    try testing.expectEqual(@as(u32, 16), c.layout.refine);

    try testing.expect(diags.items.len >= 2);
    try testing.expect(hasKey(diags, .unknown_key, "no_such_knob"));
    try testing.expect(hasKey(diags, .unknown_key, "not_a_table"));
    for (diags.items) |d| try testing.expect(d.line >= 1); // 1-based, documented

    // Passing null diagnostics is legal: the caller simply does not want the report.
    const quiet = try Config.parse(arena.allocator(), text, null);
    try testing.expectEqual(@as(i32, 3), quiet.layout.abut_gap);
}

test "a malformed value leaves the default and is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var diags: Diags = .empty;
    defer diags.deinit(testing.allocator);

    const text =
        \\.{
        \\    .layout = .{
        \\        .abut_gap = "eight",
        \\        .strict_geometry = 3,
        \\        .tap_unit = 20,
        \\    },
        \\    .render = .{ .pad = "wide" },
        \\}
    ;

    const c = try Config.parse(arena.allocator(), text, &diags);

    // The two malformed keys keep their defaults, exactly.
    try testing.expectEqual(@as(i32, 8), c.layout.abut_gap);
    try testing.expectEqual(false, c.layout.strict_geometry);
    try testing.expectEqual(@as(i32, 24), c.render.pad);

    // The well-formed key alongside them still applies: one bad value poisons one
    // key, not the document.
    try testing.expectEqual(@as(i32, 20), c.layout.tap_unit);

    try testing.expect(diags.items.len >= 3);
    try testing.expect(hasKey(diags, .bad_value, "abut_gap"));
    try testing.expect(hasKey(diags, .bad_value, "strict_geometry"));
    try testing.expect(hasKey(diags, .bad_value, "pad"));
}

test "aliases end up sorted by master name" {
    // A post-condition, not a nicety: `aliasOf` binary-searches this array, and
    // iterating it must be reproducible. The document deliberately lists them out of
    // order, with one pair adjacent under a prefix relation.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var diags: Diags = .empty;
    defer diags.deinit(testing.allocator);

    const text =
        \\.{
        \\    .pdk = .{
        \\        .alias = .{
        \\            .{ .master = "zzz_cell", .class = "nmos" },
        \\            .{ .master = "aaa_cell", .class = "pmos" },
        \\            .{ .master = "mid_cell", .class = "res" },
        \\            .{ .master = "mid", .class = "cap" },
        \\        },
        \\    },
        \\}
    ;

    const c = try Config.parse(arena.allocator(), text, &diags);

    try testing.expectEqual(@as(usize, 4), c.pdk.alias.len);
    try testing.expectEqualStrings("aaa_cell", c.pdk.alias[0].master);
    try testing.expectEqualStrings("mid", c.pdk.alias[1].master);
    try testing.expectEqualStrings("mid_cell", c.pdk.alias[2].master);
    try testing.expectEqualStrings("zzz_cell", c.pdk.alias[3].master);

    // Values travelled with their keys through the sort.
    try testing.expectEqualStrings("pmos", c.pdk.alias[0].class);
    try testing.expectEqualStrings("cap", c.pdk.alias[1].class);
    try testing.expectEqualStrings("res", c.pdk.alias[2].class);
    try testing.expectEqualStrings("nmos", c.pdk.alias[3].class);

    // Sorted by the comparator the type publishes, over the whole array.
    for (c.pdk.alias[1..], 0..) |a, i| {
        try testing.expect(!Pdk.Alias.lessThan({}, a, c.pdk.alias[i]));
    }
}

test "aliasOf finds a mapped master and misses an unmapped one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text =
        \\.{
        \\    .pdk = .{
        \\        .alias = .{
        \\            .{ .master = "sky130_fd_pr__nfet_01v8", .class = "nmos" },
        \\            .{ .master = "sky130_fd_pr__pfet_01v8", .class = "pmos" },
        \\            .{ .master = "aaa", .class = "res" },
        \\        },
        \\    },
        \\}
    ;
    const c = try Config.parse(arena.allocator(), text, null);

    // Hits, including the first and last elements — the two a half-open binary search
    // most often drops.
    try testing.expectEqualStrings("res", c.aliasOf("aaa").?);
    try testing.expectEqualStrings("nmos", c.aliasOf("sky130_fd_pr__nfet_01v8").?);
    try testing.expectEqualStrings("pmos", c.aliasOf("sky130_fd_pr__pfet_01v8").?);

    // Misses: before the first, between two, after the last, and prefix relations
    // either way. A search comparing only a prefix would return a class for
    // "sky130_fd_pr__nfet" and for "aaa_extra".
    try testing.expectEqual(@as(?[]const u8, null), c.aliasOf("aaa_extra"));
    try testing.expectEqual(@as(?[]const u8, null), c.aliasOf("aa"));
    try testing.expectEqual(@as(?[]const u8, null), c.aliasOf("mmm"));
    try testing.expectEqual(@as(?[]const u8, null), c.aliasOf("zzz"));
    try testing.expectEqual(@as(?[]const u8, null), c.aliasOf("sky130_fd_pr__nfet"));
    try testing.expectEqual(@as(?[]const u8, null), c.aliasOf(""));

    // An empty alias table answers null rather than indexing an empty slice.
    try testing.expectEqual(@as(?[]const u8, null), Config.default.aliasOf("anything"));
}

test "a trailing star matches a prefix and nothing shorter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var diags: Diags = .empty;
    defer diags.deinit(testing.allocator);

    // The bare "*" is deliberately absent here. It is the degenerate prefix and matches
    // everything, so including it alongside these negative assertions would make each of
    // them vacuously false. It gets its own config below.
    const text =
        \\.{
        \\    .pdk = .{
        \\        .leaf = .{ "sky130_fd_pr__*", "exact_name" },
        \\    },
        \\}
    ;
    const c = try Config.parse(arena.allocator(), text, &diags);
    try testing.expect(!hasKind(diags, .bad_glob));

    // Prefix pattern.
    try testing.expect(c.isLeaf("sky130_fd_pr__nfet_01v8"));
    try testing.expect(c.isLeaf("sky130_fd_pr__")); // the empty remainder still matches
    try testing.expect(!c.isLeaf("sky130_fd_pr_")); // one byte short of the prefix
    try testing.expect(!c.isLeaf("sky130"));
    try testing.expect(!c.isLeaf("xsky130_fd_pr__nfet")); // prefix, not substring

    // A pattern with no star is an exact match, not a prefix.
    try testing.expect(c.isLeaf("exact_name"));
    try testing.expect(!c.isLeaf("exact_name_x"));
    try testing.expect(!c.isLeaf("exact_nam"));

    // A bare "*" is the degenerate prefix and matches everything, including "".
    const star = try Config.parse(arena.allocator(),
        \\.{ .pdk = .{ .leaf = .{"*"} } }
    , &diags);
    try testing.expect(!hasKind(diags, .bad_glob));
    try testing.expect(star.isLeaf(""));
    try testing.expect(star.isLeaf("anything_at_all"));
    try testing.expect(star.isLeaf("sky130_fd_pr_"));

    // Nothing configured means nothing is a leaf.
    try testing.expect(!Config.default.isLeaf("sky130_fd_pr__nfet_01v8"));
    try testing.expect(!Config.default.isLeaf(""));
}

test "a mid-string star is reported and matched literally" {
    // The supported pattern language is exactly "an optional single trailing star".
    // Anything richer is refused loudly, because leaf lists decide what gets
    // flattened and an approximate match there silently changes the schematic.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var diags: Diags = .empty;
    defer diags.deinit(testing.allocator);

    const text =
        \\.{
        \\    .pdk = .{
        \\        .leaf = .{ "ab*cd", "*lead", "two**", "ok_*" },
        \\    },
        \\}
    ;
    const c = try Config.parse(arena.allocator(), text, &diags);

    // Three of the four are malformed and each is named.
    try testing.expect(diags.items.len >= 3);
    try testing.expect(hasKey(diags, .bad_glob, "ab*cd"));
    try testing.expect(hasKey(diags, .bad_glob, "*lead"));
    try testing.expect(hasKey(diags, .bad_glob, "two**"));

    // Treated literally: the star is just a byte.
    try testing.expect(c.isLeaf("ab*cd"));
    try testing.expect(!c.isLeaf("abXcd"));
    try testing.expect(!c.isLeaf("abcd"));
    try testing.expect(c.isLeaf("*lead"));
    try testing.expect(!c.isLeaf("xlead"));
    try testing.expect(c.isLeaf("two**"));
    try testing.expect(!c.isLeaf("two"));
    try testing.expect(!c.isLeaf("twoAB"));

    // The one well-formed pattern in the same list still works — a bad entry does not
    // disable the rest.
    try testing.expect(c.isLeaf("ok_anything"));
    try testing.expect(!hasKey(diags, .bad_glob, "ok_*"));
}

test "a missing config file yields defaults without an error" {
    // The normal case. Most users never write a lint.zon, and `load` failing would
    // make the library refuse to draw anything out of the box.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diags: Diags = .empty;
    defer diags.deinit(testing.allocator);

    const c = try Config.load(arena.allocator(), testing.io, tmp.dir, "definitely_absent.zon", &diags);
    try testing.expectEqual(Config.default.layout, c.layout);
    try testing.expectEqual(@as(i32, 24), c.render.pad);
    try testing.expectEqual(@as(usize, 0), c.pdk.alias.len);

    // A missing file is not a complaint either — it is the expected state.
    try testing.expectEqual(@as(usize, 0), diags.items.len);

    // A present file is read and applied, so the fallback is not masking a load that
    // never works.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "lint.zon",
        .data = ".{ .layout = .{ .refine = 4 } }\n",
    });
    const present = try Config.load(arena.allocator(), testing.io, tmp.dir, "lint.zon", &diags);
    try testing.expectEqual(@as(u32, 4), present.layout.refine);
    try testing.expectEqual(@as(i32, 8), present.layout.abut_gap);

    // A malformed file yields defaults plus diagnostics, still without erroring.
    var bad_diags: Diags = .empty;
    defer bad_diags.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "broken.zon",
        .data = ".{ .layout = .{ .refine = ",
    });
    const broken = try Config.load(arena.allocator(), testing.io, tmp.dir, "broken.zon", &bad_diags);
    try testing.expectEqual(@as(u32, 16), broken.layout.refine);
    try testing.expect(bad_diags.items.len >= 1);
}

test "the default config borrows only static data" {
    // What makes `&Config.default` a valid argument to `Pipeline.init` and safe to
    // share across threads: no arena is involved, so nothing in it can dangle. The
    // assertion is that every lookup works with no allocator in scope at all, and
    // that the pointers are the same on every access rather than freshly built.
    const a = Config.default;
    const b = Config.default;

    try testing.expectEqual(@intFromPtr(a.render.stroke.ptr), @intFromPtr(b.render.stroke.ptr));
    try testing.expectEqual(@intFromPtr(a.render.wire.ptr), @intFromPtr(b.render.wire.ptr));
    try testing.expectEqual(@as(usize, 0), a.pdk.leaf.len);
    try testing.expectEqual(@as(usize, 0), a.pdk.alias.len);

    try testing.expectEqual(@as(?[]const u8, null), a.aliasOf("nmos"));
    try testing.expect(!a.isLeaf("nmos"));

    // Copying it is a plain value copy with no ownership implication — two
    // independent `Config`s, no double free, nothing to deinit.
    var copy = Config.default;
    copy.layout.refine = 1;
    try testing.expectEqual(@as(u32, 16), Config.default.layout.refine);
    try testing.expectEqual(@as(u32, 1), copy.layout.refine);
}
