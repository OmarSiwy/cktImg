//! `cktimg-xschem`: a SPICE netlist in, an xschem schematic (`.sch`) out.
//!
//!     cktimg-xschem [--config lint.zon] in.cir out.sch
//!
//! Places the netlist with the xschem symbol set (`symbols.zon`, xschem's own
//! pins) and writes each device as an instance of its xschem symbol
//! (`xschem.zon`), each wire as an `N` segment, supplies, grounds and ports
//! as xschem's rail and pin symbols, and every net name the layout wrote (and
//! every hidden pin, such as a MOS bulk) as a `lab_pin`. Open it in xschem,
//! or netlist it (`xschem -x -q -n -s file.sch`) to check the round trip.

const std = @import("std");
const np = @import("NetlistParser");
const files = @import("xschem_files");

const Attrs = enum { value, model, label };
const Map = struct {
    classes: []const struct { class: []const u8, sym: []const u8, attrs: Attrs },
    label: []const u8,
    noconn: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd: std.Io.Dir = .cwd();
    const args = try init.minimal.args.toSlice(arena);

    var rest = args[1..];
    var cfg: np.Config = .default;
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--config")) {
        const text = cwd.readFileAlloc(io, rest[1], arena, .limited(1 << 20)) catch |err| fatal("cannot read config '{s}': {t}", .{ rest[1], err });
        cfg = try np.Config.parse(arena, text, null);
        rest = rest[2..];
    }
    if (rest.len != 2) fatal("usage: cktimg-xschem [--config lint.zon] in.cir out.sch", .{});

    var lib = np.Library.init(gpa);
    defer lib.deinit();
    var diags: std.ArrayList(np.library.ZonDiagnostic) = .empty;
    try lib.loadZon(arena, files.symbols, &diags);
    if (diags.items.len > 0) fatal("symbols.zon: {s}: {t}", .{ diags.items[0].class, diags.items[0].err });
    const map = try std.zon.parse.fromSliceAlloc(Map, arena, files.map, null, .{ .free_on_error = false });

    const text = cwd.readFileAlloc(io, rest[0], arena, .limited(1 << 22)) catch |err| fatal("cannot read '{s}': {t}", .{ rest[0], err });
    var diag: np.netlist.Diagnostic = .{};
    var placed = np.place(gpa, &cfg, &lib, &.{text}, &diag) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => fatal("{s}:{d}: {t} near '{s}'", .{ rest[0], diag.line, err, diag.token() }),
    };
    defer placed.deinit();

    var buf: [64 * 1024]u8 = undefined;
    const out = cwd.createFile(io, rest[1], .{}) catch |err| fatal("cannot create '{s}': {t}", .{ rest[1], err });
    defer out.close(io);
    var ow = out.writerStreaming(io, &buf);
    try write(&placed, &lib, &map, &ow.interface);
    try ow.interface.flush();
}

/// The quarter turn from xschem's upright symbols to the canonical frame.
const to_canonical: np.Orient = .{ .rot = 1 };

fn write(p: *const np.Placed, lib: *const np.Library, map: *const Map, w: *std.Io.Writer) !void {
    try w.writeAll("v {xschem version=3.4.7 file_version=1.2}\nG {}\nK {}\nV {}\nS {}\nE {}\n");
    // Wires, one N per segment.
    for (0..p.netCount()) |n| {
        var it = p.segments(n);
        while (it.next()) |poly| for (poly[0 .. poly.len - 1], poly[1..]) |a, b| {
            try w.print("N {d} {d} {d} {d} {{lab={s}}}\n", .{ a.x, a.y, b.x, b.y, p.net_name[n] });
        };
    }
    var tag: u32 = 0; // names for the labels and symbols we add
    for (0..p.deviceCount()) |d| {
        const class = lib.at(p.dev_class[d]);
        const lo, const hi = p.pinRange(d);
        const entry = for (map.classes) |e| {
            if (std.mem.eql(u8, e.class, class.name)) break e;
        } else null;
        if (entry) |e| {
            // Placement, then the turn from xschem's frame into ours.
            const o = compose(p.dev_orient[d], to_canonical);
            try w.print("C {{{s}}} {d} {d} {d} {d} {{", .{ e.sym, p.dev_pos[d].x, p.dev_pos[d].y, o.rot, @intFromBool(o.mirror) });
            switch (e.attrs) {
                .label => {
                    tag += 1;
                    try w.print("name=s{d} lab={s}", .{ tag, p.net_name[p.pin_net[lo]] });
                },
                .value => try w.print("name={s} value=\"{s}\"", .{ p.dev_name[d], p.dev_value[d] }),
                .model => try modelAttrs(w, p.dev_name[d], p.dev_value[d]),
            }
            try w.writeAll("}\n");
            // A hidden pin (a MOS bulk) still has a net: name it on the pin.
            for (lo..hi, 0..) |pin, k| {
                if (k >= class.terminals.len or !class.terminals[k].hidden or p.pin_net[pin] == np.placed.no_net) continue;
                tag += 1;
                try w.print("C {{{s}}} {d} {d} 0 0 {{name=l{d} sig_type=std_logic lab={s}}}\n", .{ map.label, p.pin_xy[pin].x, p.pin_xy[pin].y, tag, p.net_name[p.pin_net[pin]] });
            }
        } else {
            // No xschem symbol for this class (a generated box, a block): its
            // pins as labels, so the nets survive.
            for (lo..hi) |pin| {
                if (p.pin_net[pin] == np.placed.no_net) continue;
                tag += 1;
                try w.print("C {{{s}}} {d} {d} 0 0 {{name=l{d} sig_type=std_logic lab={s}}}\n", .{ map.label, p.pin_xy[pin].x, p.pin_xy[pin].y, tag, p.net_name[p.pin_net[pin]] });
            }
        }
    }
    for (p.labels) |l| {
        tag += 1;
        // lab_pin's text runs left of its pin; flip it to run right.
        try w.print("C {{{s}}} {d} {d} 0 {d} {{name=l{d} sig_type=std_logic lab={s}}}\n", .{ map.label, l.at.x, l.at.y, @intFromBool(l.side == .right), tag, p.net_name[l.net] });
    }
    for (p.no_connects) |c| {
        tag += 1;
        try w.print("C {{{s}}} {d} {d} 0 0 {{name=n{d}}}\n", .{ map.noconn, c.x, c.y, tag });
    }
}

/// `a` after `b`, as one orientation.
fn compose(a: np.Orient, b: np.Orient) np.Orient {
    const probes = [_]np.Pt{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
    for (0..8) |k| {
        const o: np.Orient = .{ .rot = @intCast(k & 3), .mirror = k >= 4 };
        for (probes) |q| {
            if (!o.apply(q).eql(a.apply(b.apply(q)))) break;
        } else return o;
    }
    unreachable;
}

/// `model=<first word>` and the card's `k=v` pairs.
fn modelAttrs(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.print("name={s}", .{name});
    var it = std.mem.tokenizeScalar(u8, value, ' ');
    var first = true;
    while (it.next()) |t| {
        if (first and std.mem.indexOfScalar(u8, t, '=') == null) {
            try w.print(" model={s}", .{t});
        } else if (std.mem.indexOfScalar(u8, t, '=') != null) {
            try w.print(" {s}", .{t});
        }
        first = false;
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}
