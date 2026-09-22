//! The development gallery, on the public API and the tests' symbol set:
//!
//!   zig build gallery -- --svgs dir                 every textbook circuit as dir/<name>.svg (and .cir)
//!   zig build gallery -- --gallery out.html         every textbook circuit in one page
//!   zig build gallery -- [--config lint.zon] in.cir out.svg

const std = @import("std");
const np = @import("NetlistParser");
const textbook = @import("textbook.zig");
const support = @import("support.zig");
const svg = @import("svg.zig");

const Drawn = struct { svg: []u8, stats: np.schematic.Stats };

/// The stages, so the layout's counts can be printed beside the picture.
fn draw(gpa: std.mem.Allocator, lib: *np.Library, cfg: *const np.Config, sources: []const []const u8, diag: ?*np.netlist.Diagnostic, caption: bool) !Drawn {
    var nl = try np.netlist.parse(gpa, sources, diag);
    defer nl.deinit(gpa);
    const roles = try np.guessRoles(gpa, &nl);
    defer gpa.free(roles);
    var s = try np.Schematic.build(gpa, &nl, roles, lib);
    defer s.deinit();
    try np.layout(gpa, &s, cfg);
    var p = try np.Placed.init(gpa, &s, &nl);
    defer p.deinit();
    return .{ .svg = try svg.alloc(gpa, &p, lib, .{ .caption = if (caption) nl.title else "" }), .stats = s.stats };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cwd = std.Io.Dir.cwd();
    const lib = try support.library(gpa);
    defer support.freeLibrary(gpa, lib);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--gallery")) {
        const out = if (args.len >= 3) args[2] else "gallery.html";
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll(head);
        try w.writeAll("<h2 class=\"part\">Acceptance set</h2><p class=\"lede\">Each drawing is compared with the book's figure below it.</p>\n");
        for (textbook.all) |c| try section(gpa, lib, w, c);
        try w.writeAll("<h2 class=\"part\">Beyond the set</h2><p class=\"lede\">Textbook circuits that exercise particular rules; ALGORITHM.md lists what is still open.</p>\n");
        for (textbook.beyond) |c| try section(gpa, lib, w, c);
        try w.writeAll("</main></body></html>\n");
        try cwd.writeFile(io, .{ .sub_path = out, .data = aw.written() });
        std.debug.print("wrote {s}\n", .{out});
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--svgs")) {
        var dir = try cwd.createDirPathOpen(io, args[2], .{});
        defer dir.close(io);
        for (textbook.all ++ textbook.beyond) |c| {
            const d = try draw(gpa, lib, &.default, &.{c.spice}, null, true);
            defer gpa.free(d.svg);
            var name_buf: [64]u8 = undefined;
            try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "{s}.svg", .{c.name}), .data = d.svg });
            // The netlist beside it, for tools/xschem/roundtrip.py.
            try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "{s}.cir", .{c.name}), .data = c.spice });
            const t = d.stats;
            std.debug.print("{s:<22} labels {d} bent {d} conflicts {d} crossings {d} overlaps {d}\n", .{ c.name, t.labeled_nets, t.bent, t.conflicts, t.crossings, t.overlaps });
        }
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--dump")) {
        const text = try cwd.readFileAlloc(io, args[2], gpa, .unlimited);
        defer gpa.free(text);
        return dump(gpa, lib, text);
    }
    var rest = args[1..];
    var cfg: np.Config = .default;
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--config")) {
        var diags: std.ArrayList(np.config.Diagnostic) = .empty;
        cfg = try np.Config.load(init.arena.allocator(), io, cwd, rest[1], &diags);
        for (diags.items) |d| std.debug.print("{s}:{d}: {s} '{s}'\n", .{ rest[1], d.line, @tagName(d.kind), d.key });
        rest = rest[2..];
    }
    if (rest.len < 2) {
        std.debug.print("usage: gallery [--config lint.zon] in.cir out.svg\n       gallery --gallery [out.html]\n       gallery --svgs <dir>\n", .{});
        return;
    }
    const text = try cwd.readFileAlloc(io, rest[0], gpa, .unlimited);
    defer gpa.free(text);
    var diag: np.netlist.Diagnostic = .{};
    const d = draw(gpa, lib, &cfg, &.{text}, &diag, true) catch |err| {
        std.debug.print("{s}:{d}: {s} near '{s}'\n", .{ rest[0], diag.line, @errorName(err), diag.token() });
        return err;
    };
    defer gpa.free(d.svg);
    try cwd.writeFile(io, .{ .sub_path = rest[1], .data = d.svg });
    const t = d.stats;
    std.debug.print("{d} {d} {d} {d}\n", .{ t.labeled_nets, t.bent, t.crossings, t.overlaps });
}

/// Every node, pin, edge, join and route of the layout: for debugging.
fn dump(gpa: std.mem.Allocator, lib: *np.Library, text: []const u8) !void {
    var nl = try np.netlist.parse(gpa, &.{text}, null);
    defer nl.deinit(gpa);
    const roles = try np.guessRoles(gpa, &nl);
    defer gpa.free(roles);
    var s = try np.Schematic.build(gpa, &nl, roles, lib);
    defer s.deinit();
    try np.layout(gpa, &s, &.default);
    const pr = std.debug.print;
    const none = np.schematic.none;
    for (0..s.nodes.len) |i| {
        const n = s.nodes.get(i);
        pr("node {d} {t} {s} group {d} pos {any}\n", .{ i, n.kind, if (n.kind == .device) s.device_name[n.ref] else s.net_name[n.ref], n.group, s.pos[i] });
    }
    for (0..s.pins.len) |i| {
        const q = s.pins.get(i);
        pr("pin {d} {s}.{d} net {s} side {t} home {d}\n", .{ i, if (q.device == none) "-" else s.device_name[q.device], q.index, s.net_name[q.net], q.side, q.home });
    }
    for (s.edges.items, 0..) |e, i| pr("edge {d} {t} {d}->{d} net {s} pins {d},{d}\n", .{ i, e.kind, e.a, e.b, if (e.net == none) "-" else s.net_name[e.net], e.pa, e.pb });
    for (s.joins.items, 0..) |j, i| pr("join {d} {t} net {s} p {d} q {d} active {}\n", .{ i, j.kind, s.net_name[j.net], j.p, j.q, j.active });
    for (s.routes.items) |r| pr("route {t} {d} net {s} {any}\n", .{ r.kind, r.id, s.net_name[r.net], r.pts[0..r.len] });
    for (s.labeled, 0..) |l, n| if (l) pr("labeled {s}\n", .{s.net_name[n]});
}

fn section(gpa: std.mem.Allocator, lib: *np.Library, w: *std.Io.Writer, c: textbook.Circuit) !void {
    const d = try draw(gpa, lib, &.default, &.{c.spice}, null, false);
    defer gpa.free(d.svg);
    const t = d.stats;
    try w.print("<section><h3>{s}</h3><p class=\"book\"><b>Book:</b> {s}</p>", .{ c.spice[0 .. std.mem.indexOfScalar(u8, c.spice, '\n') orelse c.spice.len], c.book });
    try w.print("<figure><div class=\"scroll\">{s}</div><figcaption>labelled nets {d} · bent edges {d} · crossings {d} · overlaps {d}</figcaption></figure></section>\n", .{ d.svg, t.labeled_nets, t.bent, t.crossings, t.overlaps });
}

const head =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    \\<title>Hypergraph → schematic: textbook circuits</title>
    \\<style>
    \\:root{box-sizing:border-box;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px);
    \\  --bg:#f4f3ef;--card:#ffffff;--ink:#1d2330;--muted:#5d6577;--line:#dcd9d0;--net:#2a62b8}
    \\@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#15171c;--card:#1f232b;--ink:#e8e9ec;--muted:#9aa1b1;--line:#343a46;--net:#7fa8e8}}
    \\:root[data-theme="dark"]{--bg:#15171c;--card:#1f232b;--ink:#e8e9ec;--muted:#9aa1b1;--line:#343a46;--net:#7fa8e8}
    \\html{scroll-padding-top:env(safe-area-inset-top,0px)}
    \\*,*::before,*::after{box-sizing:inherit}
    \\body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 "Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif}
    \\main{max-width:980px;margin:0 auto;padding:2rem 1.25rem 4rem}
    \\h1{font-size:1.9rem;margin:0 0 .4rem;font-weight:600;letter-spacing:-.01em}
    \\h2.part{font:600 1.3rem/1.3 Helvetica,Arial,sans-serif;margin:2.4rem 0 .3rem}
    \\h3{font:600 1.05rem/1.3 Helvetica,Arial,sans-serif;margin:0 0 .3rem}
    \\.lede{color:var(--muted);max-width:66ch;margin:0 0 1rem}
    \\.legend{display:flex;flex-wrap:wrap;gap:.4rem 1.4rem;font:13px/1.4 Helvetica,Arial,sans-serif;color:var(--muted);margin-bottom:1rem}
    \\.legend em{color:var(--net)}
    \\section{border-top:1px solid var(--line);padding:1.4rem 0 .6rem}
    \\.book{color:var(--muted);margin:0 0 .9rem;max-width:80ch;font-size:14px}
    \\figure{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:.6rem}
    \\figcaption{font:12px/1.4 Helvetica,Arial,sans-serif;color:var(--muted);margin:.4rem .2rem 0}
    \\.scroll{overflow-x:auto}
    \\.scroll svg{display:block;max-width:100%;height:auto;border-radius:4px}
    \\</style></head><body><main>
    \\<h1>Hypergraph → schematic, on textbook circuits</h1>
    \\<p class="lede">Every picture is generated from the SPICE netlist by the algorithm in ALGORITHM.md;
    \\nothing is hand-placed. Nets are never nodes: they are straight wires between facing pins,
    \\bends drawn by the layout, or labels.</p>
    \\<div class="legend"><span><em>italic blue</em> = a net label (xschem lab_pin): the same name is the same net</span>
    \\<span>bubble on the gate = PMOS (source toward the supply)</span><span>dot = three or more wire directions meet</span></div>
    \\
;
