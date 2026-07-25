//! Placed geometry: symbol transform, body extents, collision, label anchors, group frames.
//!
//! This is **library surface, not renderer surface**. The library's product is geometry, and
//! the format emitters live in `examples/` on the same public API a third-party consumer
//! gets (ARCHITECTURE.md §2). What that division cannot do is let each emitter recompute the
//! answers below, because they are *answers* rather than formats: mirror-then-rotate
//! ordering, where a symbol's stroke actually lands, where a refdes fits without sitting on
//! a wire, which subckt instances placed contiguously enough to frame. Duplicate them per
//! emitter and two renderers of the same schematic begin to disagree — and the first symptom
//! is a bug report from someone whose adapter cannot reproduce our gallery.
//!
//! ## Nothing here is stored
//!
//! Every rectangle is computed from `Ir` + `Physical` + the class table on demand. A device's
//! placed box is `class.bbox()` transformed by `dev_orient[d]` and translated by `pos[d]`;
//! change the orientation and the next call returns a different box, with nothing to
//! invalidate. The alternative — a `[]Rect` column in `Physical` — would be a cache that the
//! orientation pass, the host anchor-override path and the router's own body exemptions all
//! have to remember to update. Three chances to be stale, for arithmetic that is a few
//! integer min/max over data already in cache.
//!
//! The two functions that *do* allocate (`refdesAnchors`, `groupFrames`) allocate because
//! their results are order-dependent: a label dodges the labels already placed, so the answer
//! for device 7 depends on devices 0..6 and there is no per-device pure function to call. Both
//! return one flat array the caller owns.
//!
//! ## One definition of the transform
//!
//! `ids.Orient.apply` is the only place mirror-then-rotate is encoded. Everything here
//! delegates to it, including `transformRect`, whose entire job is to apply it to two corners
//! and re-normalize — a rotation by 90° or a mirror swaps which corner is minimal, so a
//! naive `.{ .min = apply(min), .max = apply(max) }` yields an inverted rectangle that
//! `Rect.intersects` then silently reports as never colliding. That bug is the reason this
//! function exists rather than being open-coded at four call sites.
//!
//! ## Text metrics are contracts
//!
//! `char_w`, `text_h` and `descent` are what the renderers *force*, not estimates: the SVG
//! backend sets `textLength`, the TikZ backend wraps the label in a `\makebox` of exactly
//! this width, and no Computer Modern glyph at 5pt exceeds it (widest: `M` ≈ 4.58pt). The
//! collision boxes below are therefore exact, and a label the layout says is clear is clear
//! in both outputs.
//!
//! ## Integers only
//!
//! No float appears anywhere. Every comparison is exact, every tie breaks deterministically,
//! and the same input yields byte-identical output without epsilon discipline.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ids = @import("ids.zig");
const irm = @import("ir.zig");
const catalog = @import("devices/catalog.zig");
const host = @import("devices/host.zig");
const Strings = @import("strings.zig").Strings;

const Pt = ids.Pt;
const Rect = ids.Rect;
const Orient = ids.Orient;
const DeviceIdx = ids.DeviceIdx;
const PinIdx = ids.PinIdx;
const NetIdx = ids.NetIdx;
const StrId = ids.StrId;
const Ir = irm.Ir;
const Physical = irm.Physical;
const DeviceClass = catalog.DeviceClass;

// ---------------------------------------------------------------------------
// Rectangle helpers
//
// These are here rather than on `ids.Rect` because `ids.zig` is the storage layer: it
// defines what a rect *is* and the two predicates the router needs inline. Construction from
// unordered corners and inflation are layout operations, and they only ever get called from
// this file and its consumers.
// ---------------------------------------------------------------------------

/// Normalized rectangle spanning two corners in any order.
///
/// The workhorse after any transform: `a` and `b` may be diagonal in either direction.
pub fn fromCorners(a: Pt, b: Pt) Rect {
    return .{
        .min = .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) },
        .max = .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) },
    };
}

/// Grow `r` by `by` units on all four sides.
///
/// Used to turn a zero-area wire segment or a pin dot into something a label can collide
/// with. `by` is in grid units and must be non-negative; shrinking is not a use case here
/// and a negative value would be able to invert the rectangle.
pub fn inflate(r: Rect, by: i32) Rect {
    std.debug.assert(by >= 0);
    return .{
        .min = .{ .x = r.min.x - by, .y = r.min.y - by },
        .max = .{ .x = r.max.x + by, .y = r.max.y + by },
    };
}

// ---------------------------------------------------------------------------
// Symbol transform
// ---------------------------------------------------------------------------

/// Apply an orientation to a rectangle and re-normalize it.
///
/// Delegates each corner to `ids.Orient.apply` — mirror about the vertical axis first, then
/// quarter-turns — and rebuilds the result through `fromCorners`, because a rotation or
/// mirror can make the transformed `min` corner the larger one. Every consumer that needs an
/// oriented box goes through here; none reimplements the math.
///
/// Pure, allocation-free, exact in integers (a quarter turn is a coordinate swap and a sign
/// flip, never a matrix multiply). Preserves area and, for `rot` odd, swaps width and height.
pub fn transformRect(o: Orient, r: Rect) Rect {
    return fromCorners(o.apply(r.min), o.apply(r.max));
}

/// Placed bounding box of one device, in schematic coordinates.
///
/// `class.bbox()` (canonical, `cell_width` wide, height from the geometry) oriented by `o`
/// and translated to `pos`. This is *the* device extent: the router's body blocking, the
/// label collision set, group frames and the drawing bounds all resolve to this one
/// function, so they cannot disagree about where a symbol is.
///
/// Recomputed on every call by design — see the module header. O(terminals + draw ops).
pub fn placedRect(class: DeviceClass, o: Orient, pos: Pt) Rect {
    const local = transformRect(o, class.bbox());
    return .{ .min = local.min.add(pos), .max = local.max.add(pos) };
}

/// Placed location of terminal `slot` of a device.
///
/// `slot` is the pin's position within its device's CSR range, which is also its index into
/// `class.terminals` and its SPICE node position. Asserts `slot < class.terminals.len`.
///
/// This is the definition `Physical.pin_xy` is built from; use the column when it exists
/// (one load) and this when it does not, such as while the orientation pass is still deciding
/// what `o` should be.
pub fn pinPoint(class: DeviceClass, o: Orient, pos: Pt, slot: u8) Pt {
    std.debug.assert(slot < class.terminals.len);
    return pos.add(o.apply(class.terminals[slot].at));
}

/// Placed box of device `d`, resolving its class through `table`.
///
/// The convenience form of `placedRect` for callers holding a whole schematic. `table` must
/// be the same table the IR's `SymbolIdx` values came from; it is borrowed and must outlive
/// the call.
pub fn deviceRect(ir: Ir, phys: Physical, table: *const host.Table, d: DeviceIdx) Rect {
    const i = d.i();
    return placedRect(table.at(ir.dev_symbol[i]), ir.dev_orient[i], phys.pos[i]);
}

/// Bounding box over every drawn thing: device bodies, wire vertices, junctions and label
/// points.
///
/// Returns null for an empty layout (no devices and no wires). Does **not** include render
/// padding — that is the renderer's to add from `Config.render.pad` — and does not include
/// refdes or group-frame text, because those are computed by the two functions below and a
/// caller that wants them merges their rects in. `ir.Physical.bounds` forwards here.
pub fn bounds(ir: Ir, phys: Physical, table: *const host.Table) ?Rect {
    var acc: ?Rect = null;
    const grow = struct {
        fn f(a: *?Rect, r: Rect) void {
            a.* = if (a.*) |cur| cur.merge(r) else r;
        }
    }.f;

    for (0..ir.deviceCount()) |d| grow(&acc, deviceRect(ir, phys, table, .at(d)));
    for (phys.wire_pts) |p| grow(&acc, .{ .min = p, .max = p });
    for (phys.junctions) |p| grow(&acc, .{ .min = p, .max = p });
    for (phys.labels) |l| grow(&acc, .{ .min = l.at, .max = l.at });
    return acc;
}

// ---------------------------------------------------------------------------
// Refdes label placement
// ---------------------------------------------------------------------------

/// Forced advance per character, in grid units.
pub const char_w: i32 = 5;
/// Height of a label's box above its baseline.
pub const text_h: i32 = 7;
/// Depth below the baseline, covering descenders (g, y, p, q, j).
pub const descent: i32 = 2;
/// Breathing room between the device cell and the label's near edge.
pub const label_gap: i32 = 3;

/// Width of a refdes label's collision box — the exact width both renderers draw.
///
/// `char_w` per byte plus two units of padding. Counts *bytes*: refdes names are ASCII after
/// interning, and a multi-byte name would under-measure rather than fail loudly, so the
/// front end is where non-ASCII is rejected.
pub fn refdesWidth(name: []const u8) i32 {
    return char_w * @as(i32, @intCast(name.len)) + 2;
}

/// The collision box a label occupies, given its anchor.
///
/// The anchor is the text's **left edge on the baseline** (SVG `<text>` semantics, TikZ
/// `anchor=base west`), so the box extends `text_h` above it and `descent` below. Renderers
/// draw at the anchor and add nothing.
pub fn refdesRect(anchor: Pt, name: []const u8) Rect {
    return .{
        .min = .{ .x = anchor.x, .y = anchor.y - text_h },
        .max = .{ .x = anchor.x + refdesWidth(name), .y = anchor.y + descent },
    };
}

/// A collision-free refdes anchor per device, indexed by `DeviceIdx`.
///
/// Placement is a layout decision, so it lives in the library and the emitters just draw
/// text at the returned point.
///
/// For each device in ascending `DeviceIdx` order, six candidate spots are tried in a fixed
/// preference order — right of the cell and vertically centred, then right-above,
/// right-below, then the same three on the left — against every wire segment, device body,
/// pin dot, junction, and *label already placed*. The first clear spot wins. If all six
/// collide the preferred spot is kept: a readable overlap beats a label wandering off into
/// the margin, and the placer already counts label collisions in the selection key, so the
/// right fix is a different placement rather than a worse anchor.
///
/// The sequential dependence is why this returns an array instead of being a pure per-device
/// query, and why the iteration order is `DeviceIdx` ascending and documented: it is what
/// makes the output reproducible.
///
/// `strings` supplies the device names, whose length sets each box's width. `table` resolves
/// symbol classes. Both are borrowed.
///
/// Caller owns the returned slice (length `ir.deviceCount()`) and frees it with `gpa`.
/// Errors: `OutOfMemory`. Complexity: O(devices × obstacles); obstacles are wires + bodies +
/// pins + junctions, so this is the one quadratic-ish pass in rendering and it runs once, on
/// the winning layout only. `// ponytail: linear obstacle scan; grid-bucket it if a
/// thousand-device schematic ever renders slowly.`
pub fn refdesAnchors(
    gpa: Allocator,
    ir: Ir,
    phys: Physical,
    strings: Strings,
    table: *const host.Table,
) Allocator.Error![]Pt {
    const n = ir.deviceCount();
    const anchors = try gpa.alloc(Pt, n);
    errdefer gpa.free(anchors);

    // The obstacle set grows as labels land, so it owns its storage for the whole pass.
    var obstacles: std.ArrayList(Rect) = .fromOwnedSlice(
        try obstacleRects(gpa, ir, phys, table),
    );
    defer obstacles.deinit(gpa);

    // Vertical step between the centred spot and the above/below alternates.
    const step = text_h + descent + label_gap;

    for (0..n) |d| {
        const base = phys.pos[d];
        const name = strings.get(ir.dev_name[d]);
        const w = refdesWidth(name);
        const right = base.x + catalog.cell_half + label_gap;
        const left = base.x - catalog.cell_half - label_gap - w;
        const candidates = [6]Pt{
            .{ .x = right, .y = base.y },
            .{ .x = right, .y = base.y - step },
            .{ .x = right, .y = base.y + step },
            .{ .x = left, .y = base.y },
            .{ .x = left, .y = base.y - step },
            .{ .x = left, .y = base.y + step },
        };

        var at = candidates[0];
        for (candidates) |c| {
            const r = refdesRect(c, name);
            var clear = true;
            for (obstacles.items) |o| {
                if (o.intersects(r)) {
                    clear = false;
                    break;
                }
            }
            if (clear) {
                at = c;
                break;
            }
        }
        // Later labels dodge this one too, which is what makes the pass order-dependent.
        try obstacles.append(gpa, refdesRect(at, name));
        anchors[d] = at;
    }
    return anchors;
}

/// Everything a label must not sit on, as strict-overlap rectangles.
///
/// Wire polyline edges (each inflated by 1 for stroke width), device bodies, pin dots
/// (inflated 2) and junction dots (inflated 3). Order is wires, then bodies, then pins, then
/// junctions — fixed so that a caller appending its own obstacles gets reproducible results.
///
/// Exposed because a host renderer that adds its own annotations needs the same set to dodge.
/// Caller owns the returned slice and frees it with `gpa`. Errors: `OutOfMemory`.
pub fn obstacleRects(
    gpa: Allocator,
    ir: Ir,
    phys: Physical,
    table: *const host.Table,
) Allocator.Error![]Rect {
    var out: std.ArrayList(Rect) = .empty;
    errdefer out.deinit(gpa);

    // Wire polyline edges, each as a degenerate rect grown to stroke width.
    for (0..ir.netCount()) |net| {
        for (phys.net_seg[net]..phys.net_seg[net + 1]) |seg| {
            const pts = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
            if (pts.len < 2) continue;
            for (pts[1..], pts[0 .. pts.len - 1]) |b, a| {
                try out.append(gpa, inflate(fromCorners(a, b), 1));
            }
        }
    }
    for (0..ir.deviceCount()) |d| try out.append(gpa, deviceRect(ir, phys, table, .at(d)));
    for (phys.pin_xy) |p| try out.append(gpa, inflate(.{ .min = p, .max = p }, 2));
    for (phys.junctions) |p| try out.append(gpa, inflate(.{ .min = p, .max = p }, 3));

    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Group frames
// ---------------------------------------------------------------------------

/// Clearance between a group frame and the member geometry it encloses.
pub const group_pad: i32 = 10;
/// Baseline drop of a frame's label below the frame's top edge.
///
/// The label sits *inside* its own frame, in the padding band. Outside, nested labels would
/// pile up on each other, and there is nothing out there but empty margin to put them in.
pub const group_label_h: i32 = 8;

/// A frame to draw around the devices one flattened subckt instance contributed.
///
/// Carries `path` and `master` as `StrId` rather than a formatted string. The Rust original
/// built `"{path} : {master}"` per frame, which allocates a string the renderer immediately
/// re-escapes; here the emitter formats it however its syntax needs, and this struct stays
/// 28 bytes of plain data with nothing to free.
pub const GroupBox = struct {
    /// The frame rectangle, already padded.
    rect: Rect,
    /// Dotted instance path (`xu1`, `xtop.xa`). Interned; resolve through `Strings`.
    path: StrId,
    /// Subckt master name for the label.
    master: StrId,
    /// Where to draw the label: left edge, baseline. Collision-avoided against the other
    /// frames' labels, so an emitter draws at the point and adds nothing — the same division
    /// of labour as `refdesAnchors`.
    label_at: Pt,
    /// Instance nesting depth; 0 is top level, and it equals the number of `.` in `path`.
    /// Nested groups nest geometrically too, since an inner path extends its outer one.
    depth: u16,

    /// Width of this frame's label box, for `"<path> : <master>"` at `char_w` per byte.
    pub fn labelWidth(self: GroupBox, strings: Strings) i32 {
        // `" : "` is the separator both emitters format between the two names.
        const n = strings.get(self.path).len + 3 + strings.get(self.master).len;
        return char_w * @as(i32, @intCast(n));
    }
};

/// Is the device named `name` inside the instance at `path`?
///
/// Dotted-prefix test on whole path components: `xu1` owns `xu1.m0` but **not** `xu1b.m0`,
/// which is why this checks for the `.` separator rather than calling `startsWith`. A device
/// whose name equals `path` exactly is not inside it — a group's members are strictly below
/// it.
///
/// Pure, allocation-free.
pub fn inGroup(name: []const u8, path: []const u8) bool {
    return name.len > path.len and
        std.mem.startsWith(u8, name, path) and
        name[path.len] == '.';
}

/// Frames for every flattened instance that placed contiguously, outermost first.
///
/// Flattening dissolves hierarchy so the placer sees one flat device list, which is what
/// makes placement tractable — but it also erases the structure a reader uses to decompose a
/// schematic. `Ir.group_path` keeps the boundary; this turns it into a rectangle.
///
/// A frame is emitted only when it is *true*, which costs four filters:
///
/// 1. **At least two members.** A one-device instance is a device, not a group worth framing.
/// 2. **Claims no outsider.** The padded rect must not contain the *origin* of any
///    non-member. Clipping a neighbour's bounding box is untidy but a reader still sees that
///    device sitting outside; a neighbour's centre inside the frame is what would be read as
///    membership. The placer has no group affinity, so nothing guarantees an instance lands
///    contiguously — when it does not, the honest output is no frame rather than one that
///    silently annexes a stranger.
/// 3. **No duplicate member set.** A pass-through wrapper — a definition holding nothing but
///    one instance — has exactly its child's devices, so both frames would land on the same
///    rectangle and both labels on the same spot. The outer one is kept: it is the name the
///    reader met a level up.
/// 4. **Overlap only by nesting.** Two frames that cross without one being an ancestor of the
///    other read as a Venn diagram, which is never what a hierarchy meant. The inner one is
///    dropped.
///
/// Label anchors are then assigned in output order, stepping down inside the frame (up to 8
/// times, `group_label_h` each) until clear of the labels already placed — a nested frame
/// often shares its parent's top-left corner because the same device bounds both.
///
/// Result is sorted by `depth` ascending, so an emitter drawing in order puts nested frames
/// on top of their parents.
///
/// Returns an empty slice for a flat netlist: no hierarchy, nothing to annotate. Requires a
/// placed `Physical`. Caller owns the returned slice and frees it with `gpa`; nothing inside
/// it is separately owned. Errors: `OutOfMemory`. Complexity O(groups × devices + groups²).
pub fn groupFrames(
    gpa: Allocator,
    ir: Ir,
    phys: Physical,
    strings: Strings,
    table: *const host.Table,
) Allocator.Error![]GroupBox {
    var out: std.ArrayList(GroupBox) = .empty;
    errdefer out.deinit(gpa);

    const ndev = ir.deviceCount();
    const ngrp = ir.groupCount();
    if (ngrp == 0 or ndev == 0) return out.toOwnedSlice(gpa);

    // Filters 1 and 2: enough members, and no outsider's origin inside the padded rect.
    // `members` is carried because the duplicate test below is a count comparison.
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(gpa);
    try cands.ensureTotalCapacity(gpa, ngrp);

    for (0..ngrp) |g| {
        const path = strings.get(ir.group_path[g]);
        var r: Rect = undefined;
        var members: u32 = 0;
        for (0..ndev) |d| {
            if (!inGroup(strings.get(ir.dev_name[d]), path)) continue;
            const body = deviceRect(ir, phys, table, .at(d));
            r = if (members == 0) body else r.merge(body);
            members += 1;
        }
        if (members < 2) continue; // a one-device instance is a device
        r = inflate(r, group_pad);

        var claims_outsider = false;
        for (0..ndev) |d| {
            if (inGroup(strings.get(ir.dev_name[d]), path)) continue;
            if (r.contains(phys.pos[d])) {
                claims_outsider = true;
                break;
            }
        }
        if (claims_outsider) continue;

        cands.appendAssumeCapacity(.{
            .rect = r,
            .path = ir.group_path[g],
            .master = ir.group_master[g],
            .depth = @intCast(std.mem.count(u8, path, ".")),
            .members = members,
        });
    }

    // Outermost first. Stable, so same-depth frames keep their `group_path` order — that
    // is where the reproducibility of the whole result comes from.
    std.mem.sort(Cand, cands.items, {}, Cand.byDepth);

    // Filter 3: a pass-through wrapper has exactly its child's member set. Two paths with
    // the same non-empty member set must be ancestor and descendant (every member's name
    // carries both as dotted prefixes), so equal counts plus ancestry is an exact test and
    // needs no per-group member array. Depth order means the ancestor is already kept.
    {
        var w: usize = 0;
        for (cands.items) |c| {
            var dup = false;
            for (cands.items[0..w]) |k| {
                if (k.members == c.members and
                    inGroup(strings.get(c.path), strings.get(k.path)))
                {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            cands.items[w] = c;
            w += 1;
        }
        cands.shrinkRetainingCapacity(w);
    }

    // Filter 4: crossing frames read as a Venn diagram. Drop the inner one.
    const keep = try gpa.alloc(bool, cands.items.len);
    defer gpa.free(keep);
    @memset(keep, true);
    for (cands.items, 0..) |a, i| {
        for (cands.items[i + 1 ..], i + 1..) |b, j| {
            const pa = strings.get(a.path);
            const pb = strings.get(b.path);
            const nested = inGroup(pb, pa) or inGroup(pa, pb);
            if (!nested and a.rect.intersects(b.rect)) keep[j] = false;
        }
    }

    try out.ensureTotalCapacity(gpa, cands.items.len);
    for (cands.items, keep) |c, k| {
        if (!k) continue;
        out.appendAssumeCapacity(.{
            .rect = c.rect,
            .path = c.path,
            .master = c.master,
            .label_at = .{ .x = c.rect.min.x + 3, .y = c.rect.min.y + group_label_h },
            .depth = c.depth,
        });
    }

    // Label anchors, in output order. A nested frame often shares its parent's top-left
    // corner because the same device bounds both, so step down inside the frame until
    // clear of the labels already placed.
    for (out.items, 0..) |*g, i| {
        const w = g.labelWidth(strings);
        var at = g.label_at;
        for (0..8) |_| {
            var clash = false;
            for (out.items[0..i]) |prior| {
                const pw = prior.labelWidth(strings);
                if (@abs(prior.label_at.y - at.y) < group_label_h and
                    at.x < prior.label_at.x + pw and prior.label_at.x < at.x + w)
                {
                    clash = true;
                    break;
                }
            }
            if (!clash) break;
            at.y += group_label_h;
        }
        g.label_at = at;
    }

    return out.toOwnedSlice(gpa);
}

/// A surviving group before its label is anchored. Local to `groupFrames`: `members` is
/// only needed by the duplicate filter and has no business in the public `GroupBox`.
const Cand = struct {
    rect: Rect,
    path: StrId,
    master: StrId,
    depth: u16,
    members: u32,

    fn byDepth(_: void, a: Cand, b: Cand) bool {
        return a.depth < b.depth;
    }
};
