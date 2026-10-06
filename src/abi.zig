//! The C ABI (`include/cktimg.h`): a view over `Placed`, not a copy. Names
//! and wire points are handed out as pointers into the result's own arrays.
//!
//! What changed from cktImg's, and why (docs/API.md): classes are added to
//! a library the caller owns, in one call per class, instead of through a
//! process-global begin/pin/register builder; placement is told which
//! library and settings to use; roles gave way to terminal flags.
//!
//! A null handle or an out-of-range index is safe everywhere: null, 0 or
//! false, never a trap — this is a trust boundary.

const std = @import("std");
const library = @import("library.zig");
const placed_mod = @import("placed.zig");
const config = @import("config.zig");
const netlist = @import("netlist.zig");
const geom = @import("geom.zig");
const lint = @import("lint.zig");
const json = @import("json.zig");
const root = @import("root.zig");

const Pt = library.Pt;
const Library = library.Library;
const Placed = placed_mod.Placed;
// wasm is single-threaded, where SmpAllocator does not build.
const gpa = if (@import("builtin").cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.smp_allocator;

pub const CktimgLib = Library;

pub const CktimgSch = struct {
    placed: Placed,
    lib: *const Library,
    /// Settings the drawing was placed with (its lint rules, for `cktimg_lint`).
    cfg_arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    /// Config complaints, one per line; "" when clean.
    report: [:0]u8,
    /// Name anchors, computed on first ask (each dodges the ones before).
    anchors: ?[]Pt = null,
};

pub const CktimgTerminal = extern struct {
    name: ?[*:0]const u8,
    x: i32,
    y: i32,
    flags: u8,
};

pub const CktimgOp = extern struct {
    kind: u8,
    xy: ?[*]const i32,
    count: usize,
    r: i32,
    text: ?[*:0]const u8,
    size: u8,
};

const term_hidden: u8 = 1;
const term_ground_ref: u8 = 2;

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

pub export fn cktimg_lib_new() ?*CktimgLib {
    const lib = gpa.create(Library) catch return null;
    lib.* = .init(gpa);
    return lib;
}

pub export fn cktimg_lib_free(lib: ?*CktimgLib) void {
    const l = lib orelse return;
    l.deinit();
    gpa.destroy(l);
}

pub export fn cktimg_lib_set_unit(lib: ?*CktimgLib, unit: i32) bool {
    const l = lib orelse return false;
    if (unit <= 0) return false;
    l.unit = unit;
    return true;
}

pub export fn cktimg_lib_count(lib: ?*const CktimgLib) usize {
    const l = lib orelse return 0;
    return l.count();
}

/// One class, in one call. Returns its index, or SIZE_MAX.
pub export fn cktimg_lib_add(
    lib: ?*CktimgLib,
    name: ?[*:0]const u8,
    role: u8,
    terms: ?[*]const CktimgTerminal,
    n_terms: usize,
    ops: ?[*]const CktimgOp,
    n_ops: usize,
) usize {
    const fail = std.math.maxInt(usize);
    const l = lib orelse return fail;
    const n = name orelse return fail;
    if (role > @intFromEnum(library.Role.output_port)) return fail;
    const ts = terms orelse return fail;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t = a.alloc(library.Terminal, n_terms) catch return fail;
    for (ts[0..n_terms], t) |src, *dst| dst.* = .{
        .name = std.mem.span(src.name orelse return fail),
        .at = .{ .x = src.x, .y = src.y },
        .hidden = src.flags & term_hidden != 0,
        .ground_ref = src.flags & term_ground_ref != 0,
    };
    var draw: std.ArrayList(library.DrawOp) = .empty;
    if (n_ops > 0) {
        const os = ops orelse return fail;
        for (os[0..n_ops]) |op| {
            const xy = op.xy orelse return fail;
            const pt = struct {
                fn f(v: [*]const i32, k: usize) Pt {
                    return .{ .x = v[2 * k], .y = v[2 * k + 1] };
                }
            }.f;
            const d: library.DrawOp = switch (op.kind) {
                0 => .{ .line = .{ .a = pt(xy, 0), .b = pt(xy, 1) } },
                1 => blk: {
                    if (op.count < 2) return fail;
                    const ps = a.alloc(Pt, op.count) catch return fail;
                    for (ps, 0..) |*q, k| q.* = pt(xy, k);
                    break :blk .{ .polyline = ps };
                },
                2 => .{ .circle = .{ .c = pt(xy, 0), .r = op.r } },
                3 => .{ .text = .{ .at = pt(xy, 0), .s = std.mem.span(op.text orelse return fail), .size = op.size } },
                else => return fail,
            };
            draw.append(a, d) catch return fail;
        }
    }
    const id = l.register(.{ .name = std.mem.span(n), .role = @enumFromInt(role), .terminals = t, .draw = draw.items }) catch return fail;
    return id.i();
}

/// Registers every class of a symbol file. `*out_report` (optional,
/// caller-owned) lists what was refused.
pub export fn cktimg_lib_load_zon(lib: ?*CktimgLib, text: ?[*:0]const u8, out_report: ?*?[*:0]u8) bool {
    if (out_report) |r| r.* = null;
    const l = lib orelse return false;
    const t = text orelse return false;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: std.ArrayList(library.ZonDiagnostic) = .empty;
    l.loadZon(arena.allocator(), std.mem.span(t), &diags) catch return false;
    if (out_report) |r| {
        var w: std.Io.Writer.Allocating = .init(gpa);
        for (diags.items) |d| w.writer.print("{s}: {s}\n", .{ d.class, @errorName(d.err) }) catch return false;
        r.* = (w.toOwnedSliceSentinel(0) catch return false).ptr;
    }
    return diags.items.len == 0;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Places `src` with `lib`'s classes and the settings in `zon` (NULL: the
/// defaults). NULL on a netlist the parser rejects, with the reason in
/// `*out_report`. `lib` must outlive the handle.
pub export fn cktimg_parse_place(lib: ?*CktimgLib, src: ?[*:0]const u8, zon: ?[*:0]const u8, out_report: ?*?[*:0]u8) ?*CktimgSch {
    if (out_report) |r| r.* = null;
    const l = lib orelse return null;
    const s = src orelse return null;
    const sch = gpa.create(CktimgSch) catch return null;
    sch.cfg_arena = .init(gpa);
    var ok = false;
    defer if (!ok) {
        sch.cfg_arena.deinit();
        gpa.destroy(sch);
    };
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    sch.cfg = .default;
    if (zon) |z| {
        var diags: std.ArrayList(config.Diagnostic) = .empty;
        sch.cfg = config.Config.parse(sch.cfg_arena.allocator(), std.mem.span(z), &diags) catch return null;
        for (diags.items) |d| report.writer.print("config:{d}: {s} '{s}'\n", .{ d.line, @tagName(d.kind), d.key }) catch return null;
    }
    var diag: netlist.Diagnostic = .{};
    sch.placed = root.place(gpa, &sch.cfg, l, &.{std.mem.span(s)}, &diag) catch |err| {
        if (out_report) |r| {
            var w: std.Io.Writer.Allocating = .init(gpa);
            w.writer.print("line {d}: {s} near '{s}'\n", .{ diag.line, @errorName(err), diag.token() }) catch return null;
            r.* = (w.toOwnedSliceSentinel(0) catch return null).ptr;
        }
        return null;
    };
    sch.lib = l;
    sch.anchors = null;
    sch.report = report.toOwnedSliceSentinel(0) catch {
        sch.placed.deinit();
        return null;
    };
    if (out_report) |r| r.* = (gpa.dupeSentinel(u8, sch.report, 0) catch null) orelse null;
    ok = true;
    return sch;
}

pub export fn cktimg_sch_free(sch: ?*CktimgSch) void {
    const s = sch orelse return;
    s.placed.deinit();
    s.cfg_arena.deinit();
    gpa.free(s.report);
    if (s.anchors) |a| gpa.free(a);
    gpa.destroy(s);
}

pub export fn cktimg_string_free(s: ?[*:0]u8) void {
    const p = s orelse return;
    gpa.free(std.mem.span(p));
}

pub export fn cktimg_report(sch: ?*const CktimgSch) ?[*:0]const u8 {
    const s = sch orelse return null;
    return s.report.ptr;
}

/// The JSON document into the caller's buffer; returns the length it needs
/// (without the NUL) whatever `cap` is.
pub export fn cktimg_json(sch: ?*const CktimgSch, buf: ?[*]u8, cap: usize) usize {
    const s = sch orelse return 0;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    json.write(&s.placed, s.lib, &discard.writer) catch return 0;
    const need: usize = @intCast(discard.fullCount());
    if (buf) |b| if (cap > 0) {
        var fw: std.Io.Writer = .fixed(b[0 .. cap - 1]);
        json.write(&s.placed, s.lib, &fw) catch {};
        b[fw.end] = 0;
    };
    return need;
}

/// Place and render to JSON in one call. Caller-owned; NULL on failure
/// (the reason in `*out_report`).
pub export fn cktimg_run_json(lib: ?*CktimgLib, src: ?[*:0]const u8, zon: ?[*:0]const u8, out_report: ?*?[*:0]u8) ?[*:0]u8 {
    const sch = cktimg_parse_place(lib, src, zon, out_report) orelse return null;
    defer cktimg_sch_free(sch);
    var w: std.Io.Writer.Allocating = .init(gpa);
    json.write(&sch.placed, sch.lib, &w.writer) catch {
        w.deinit();
        return null;
    };
    return (w.toOwnedSliceSentinel(0) catch return null).ptr;
}

// ---------------------------------------------------------------------------
// Devices and pins
// ---------------------------------------------------------------------------

fn dev(sch: ?*const CktimgSch, d: usize) ?*const CktimgSch {
    const s = sch orelse return null;
    return if (d < s.placed.deviceCount()) s else null;
}

fn put(p: Pt, x: ?*i32, y: ?*i32) void {
    if (x) |v| v.* = p.x;
    if (y) |v| v.* = p.y;
}

pub export fn cktimg_device_count(sch: ?*const CktimgSch) usize {
    const s = sch orelse return 0;
    return s.placed.deviceCount();
}
pub export fn cktimg_device_name(sch: ?*const CktimgSch, d: usize) ?[*:0]const u8 {
    const s = dev(sch, d) orelse return null;
    return s.placed.dev_name[d].ptr;
}
pub export fn cktimg_device_class(sch: ?*const CktimgSch, d: usize) ?[*:0]const u8 {
    const s = dev(sch, d) orelse return null;
    return @ptrCast(s.lib.at(s.placed.dev_class[d]).name.ptr);
}
pub export fn cktimg_device_value(sch: ?*const CktimgSch, d: usize) ?[*:0]const u8 {
    const s = dev(sch, d) orelse return null;
    return s.placed.dev_value[d].ptr;
}
pub export fn cktimg_device_role(sch: ?*const CktimgSch, d: usize) u8 {
    const s = dev(sch, d) orelse return 0;
    return @intFromEnum(s.lib.at(s.placed.dev_class[d]).role);
}
pub export fn cktimg_device_rot(sch: ?*const CktimgSch, d: usize) u8 {
    const s = dev(sch, d) orelse return 0;
    return s.placed.dev_orient[d].rot;
}
pub export fn cktimg_device_mirror(sch: ?*const CktimgSch, d: usize) bool {
    const s = dev(sch, d) orelse return false;
    return s.placed.dev_orient[d].mirror;
}
pub export fn cktimg_device_pos(sch: ?*const CktimgSch, d: usize, x: ?*i32, y: ?*i32) bool {
    const s = dev(sch, d) orelse return false;
    put(s.placed.dev_pos[d], x, y);
    return true;
}
pub export fn cktimg_device_refdes_anchor(sch: ?*CktimgSch, d: usize, x: ?*i32, y: ?*i32) bool {
    const s = sch orelse return false;
    if (d >= s.placed.deviceCount()) return false;
    if (s.anchors == null) s.anchors = geom.refdesAnchors(gpa, &s.placed, s.lib) catch return false;
    put(s.anchors.?[d], x, y);
    return true;
}
pub export fn cktimg_device_pin_count(sch: ?*const CktimgSch, d: usize) usize {
    const s = dev(sch, d) orelse return 0;
    const lo, const hi = s.placed.pinRange(d);
    return hi - lo;
}
fn pinOf(sch: ?*const CktimgSch, d: usize, p: usize) ?u32 {
    const s = dev(sch, d) orelse return null;
    const lo, const hi = s.placed.pinRange(d);
    return if (p < hi - lo) lo + @as(u32, @intCast(p)) else null;
}
pub export fn cktimg_pin_term(sch: ?*const CktimgSch, d: usize, p: usize) ?[*:0]const u8 {
    _ = pinOf(sch, d, p) orelse return null;
    const s = sch.?;
    const class = s.lib.at(s.placed.dev_class[d]);
    return if (p < class.terminals.len) @ptrCast(class.terminals[p].name.ptr) else "";
}
pub export fn cktimg_pin_net(sch: ?*const CktimgSch, d: usize, p: usize) ?[*:0]const u8 {
    const pin = pinOf(sch, d, p) orelse return null;
    const n = sch.?.placed.pin_net[pin];
    return if (n == placed_mod.no_net) null else sch.?.placed.net_name[n].ptr;
}
pub export fn cktimg_pin_xy(sch: ?*const CktimgSch, d: usize, p: usize, x: ?*i32, y: ?*i32) bool {
    const pin = pinOf(sch, d, p) orelse return false;
    put(sch.?.placed.pin_xy[pin], x, y);
    return true;
}

// ---------------------------------------------------------------------------
// Nets, wires, dots, labels, crosses
// ---------------------------------------------------------------------------

pub export fn cktimg_net_count(sch: ?*const CktimgSch) usize {
    const s = sch orelse return 0;
    return s.placed.netCount();
}
pub export fn cktimg_net_name(sch: ?*const CktimgSch, n: usize) ?[*:0]const u8 {
    const s = sch orelse return null;
    return if (n < s.placed.netCount()) s.placed.net_name[n].ptr else null;
}
pub export fn cktimg_wire_count(sch: ?*const CktimgSch) usize {
    return cktimg_net_count(sch);
}
pub export fn cktimg_wire_net(sch: ?*const CktimgSch, w: usize) ?[*:0]const u8 {
    return cktimg_net_name(sch, w);
}
pub export fn cktimg_wire_segment_count(sch: ?*const CktimgSch, w: usize) usize {
    const s = sch orelse return 0;
    if (w >= s.placed.netCount()) return 0;
    return s.placed.net_seg[w + 1] - s.placed.net_seg[w];
}
pub export fn cktimg_wire_segment_points(sch: ?*const CktimgSch, w: usize, k: usize, xy: ?*?[*]const i32) usize {
    if (xy) |o| o.* = null;
    if (k >= cktimg_wire_segment_count(sch, w)) return 0;
    const p = &sch.?.placed;
    const seg = p.net_seg[w] + k;
    const pts = p.wire_pts[p.seg_pt[seg]..p.seg_pt[seg + 1]];
    if (xy) |o| o.* = @ptrCast(pts.ptr);
    return pts.len;
}
pub export fn cktimg_junction_count(sch: ?*const CktimgSch) usize {
    const s = sch orelse return 0;
    return s.placed.junctions.len;
}
pub export fn cktimg_junction(sch: ?*const CktimgSch, j: usize, x: ?*i32, y: ?*i32) bool {
    const s = sch orelse return false;
    if (j >= s.placed.junctions.len) return false;
    put(s.placed.junctions[j], x, y);
    return true;
}
pub export fn cktimg_label_count(sch: ?*const CktimgSch) usize {
    const s = sch orelse return 0;
    return s.placed.labels.len;
}
pub export fn cktimg_label_net(sch: ?*const CktimgSch, l: usize) ?[*:0]const u8 {
    const s = sch orelse return null;
    if (l >= s.placed.labels.len) return null;
    return s.placed.net_name[s.placed.labels[l].net].ptr;
}
pub export fn cktimg_label_xy(sch: ?*const CktimgSch, l: usize, x: ?*i32, y: ?*i32) bool {
    const s = sch orelse return false;
    if (l >= s.placed.labels.len) return false;
    put(s.placed.labels[l].at, x, y);
    return true;
}
/// Which way the label's text runs from its point: 0 left, 1 right, 2 up,
/// 3 down; 255 on a miss.
pub export fn cktimg_label_side(sch: ?*const CktimgSch, l: usize) u8 {
    const s = sch orelse return 255;
    if (l >= s.placed.labels.len) return 255;
    return @intFromEnum(s.placed.labels[l].side);
}
pub export fn cktimg_noconnect_count(sch: ?*const CktimgSch) usize {
    const s = sch orelse return 0;
    return s.placed.no_connects.len;
}
pub export fn cktimg_noconnect(sch: ?*const CktimgSch, k: usize, x: ?*i32, y: ?*i32) bool {
    const s = sch orelse return false;
    if (k >= s.placed.no_connects.len) return false;
    put(s.placed.no_connects[k], x, y);
    return true;
}

// ---------------------------------------------------------------------------
// Bounds and symbol strokes, placed
// ---------------------------------------------------------------------------

fn putRect(r: library.Rect, x0: ?*i32, y0: ?*i32, x1: ?*i32, y1: ?*i32) void {
    put(r.min, x0, y0);
    put(r.max, x1, y1);
}
pub export fn cktimg_bounds(sch: ?*const CktimgSch, x0: ?*i32, y0: ?*i32, x1: ?*i32, y1: ?*i32) bool {
    const s = sch orelse return false;
    const r = s.placed.bounds(s.lib) orelse return false;
    putRect(r, x0, y0, x1, y1);
    return true;
}
pub export fn cktimg_device_bounds(sch: ?*const CktimgSch, d: usize, x0: ?*i32, y0: ?*i32, x1: ?*i32, y1: ?*i32) bool {
    const s = dev(sch, d) orelse return false;
    putRect(s.placed.deviceRect(s.lib, d), x0, y0, x1, y1);
    return true;
}
fn opOf(sch: ?*const CktimgSch, d: usize, o: usize) ?library.DrawOp {
    const s = dev(sch, d) orelse return null;
    const ops = s.lib.at(s.placed.dev_class[d]).draw;
    return if (o < ops.len) ops[o] else null;
}
pub export fn cktimg_device_op_count(sch: ?*const CktimgSch, d: usize) usize {
    const s = dev(sch, d) orelse return 0;
    return s.lib.at(s.placed.dev_class[d]).draw.len;
}
pub export fn cktimg_device_op_kind(sch: ?*const CktimgSch, d: usize, o: usize) u8 {
    const op = opOf(sch, d, o) orelse return 255;
    return @intFromEnum(std.meta.activeTag(op));
}
pub export fn cktimg_device_op_points(sch: ?*const CktimgSch, d: usize, o: usize, xy: ?[*]i32, cap: usize) usize {
    const op = opOf(sch, d, o) orelse return 0;
    const s = sch.?;
    const pts: []const Pt = switch (op) {
        .line => |l| &.{ l.a, l.b },
        .polyline => |ps| ps,
        else => return 0,
    };
    if (xy) |out| for (pts[0..@min(pts.len, cap)], 0..) |q, k| {
        const p = geom.placePoint(s.placed.dev_orient[d], s.placed.dev_pos[d], q);
        out[2 * k] = p.x;
        out[2 * k + 1] = p.y;
    };
    return pts.len;
}
pub export fn cktimg_device_op_circle(sch: ?*const CktimgSch, d: usize, o: usize, cx: ?*i32, cy: ?*i32, r: ?*i32) bool {
    const op = opOf(sch, d, o) orelse return false;
    const c = switch (op) {
        .circle => |c| c,
        else => return false,
    };
    const s = sch.?;
    put(geom.placePoint(s.placed.dev_orient[d], s.placed.dev_pos[d], c.c), cx, cy);
    if (r) |v| v.* = c.r;
    return true;
}
pub export fn cktimg_device_op_text(sch: ?*const CktimgSch, d: usize, o: usize, x: ?*i32, y: ?*i32, size: ?*u8) ?[*:0]const u8 {
    const op = opOf(sch, d, o) orelse return null;
    const t = switch (op) {
        .text => |t| t,
        else => return null,
    };
    const s = sch.?;
    put(geom.placePoint(s.placed.dev_orient[d], s.placed.dev_pos[d], t.at), x, y);
    if (size) |v| v.* = t.size;
    return @ptrCast(t.s.ptr);
}

// ---------------------------------------------------------------------------
// Lint
// ---------------------------------------------------------------------------

/// The lint report for the handle's `.rules`, one finding per line, into the
/// caller's buffer; returns the length it needs. `*errors` (optional) gets
/// the number of findings at "err".
pub export fn cktimg_lint(sch: ?*const CktimgSch, buf: ?[*]u8, cap: usize, errors: ?*usize) usize {
    if (errors) |e| e.* = 0;
    const s = sch orelse return 0;
    const findings = lint.check(gpa, &s.placed, s.lib, s.cfg.rules) catch return 0;
    defer gpa.free(findings);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    for (findings) |f| lint.format(f, &s.placed, &discard.writer) catch return 0;
    if (errors) |e| for (findings) |f| {
        e.* += @intFromBool(f.severity == .err);
    };
    if (buf) |b| if (cap > 0) {
        var fw: std.Io.Writer = .fixed(b[0 .. cap - 1]);
        for (findings) |f| lint.format(f, &s.placed, &fw) catch break;
        b[fw.end] = 0;
    };
    return @intCast(discard.fullCount());
}
