//! cktImg — schematic place-and-route from a SPICE netlist.
//!
//! Public API, the allocator plumbing the pipeline's phase structure depends on, and
//! the C ABI surface.
//!
//! ## The transformation
//!
//! ```
//! bytes (SPICE text)
//!   -> tokens      spans into one source arena
//!   -> Ir          SoA: devices, pins, nets, string pool
//!   -> placement   columns, y-offsets, x-offsets
//!   -> routes      minimum-cost trees on a Hanan lattice
//!   -> bytes       SVG / TikZ / JSON / C-ABI views
//! ```
//!
//! ## Five lifetimes, five allocators
//!
//! Allocation strategy is the load-bearing performance decision here, so it is part
//! of the public type rather than an implementation detail:
//!
//! | Lifetime            | Field     | Holds |
//! |---------------------|-----------|-------|
//! | program             | (static)  | builtin symbol catalog, routing cost weights |
//! | document            | `doc`     | source bytes, string pool, IR |
//! | one candidate order | `search`  | columns, offsets, lattice, route polylines |
//! | whole run, reused   | `scratch` | Dijkstra distance/parent/heap buffers |
//! | result              | `out`     | the winning `Physical`, rendered bytes |
//!
//! `search` is the one that matters. Phase B evaluates up to `refine` candidate
//! orders; each builds a lattice, routes every net, measures the result and throws
//! all of it away. Resetting an arena with `.retain_capacity` between candidates
//! means the second candidate onward allocates zero pages, where a general-purpose
//! allocator would pay malloc and free for the lattice, the occupancy arrays and
//! every route polyline, sixteen times over.
//!
//! `scratch` is separate from `search` precisely because it must *survive* those
//! resets: it is sized once to the largest lattice and reused for every net of every
//! candidate.
//!
//! ## Three API granularities
//!
//! `place` is the convenience form — pass an allocator and a netlist, get a `Placed`
//! you own. `Pipeline` is the fine-grained form for callers who process many
//! schematics and want no allocation after warm-up. The C ABI in `abi.zig` is the
//! third, for foreign consumers; it is a *view* over the same structures, not a
//! parallel implementation. All three share one code path.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ids = @import("ids.zig");
pub const csr = @import("csr.zig");
pub const strings = @import("strings.zig");
pub const config = @import("config.zig");
pub const ir = @import("ir.zig");

pub const netlist = struct {
    pub const source = @import("netlist/source.zig");
    pub const token = @import("netlist/token.zig");
    pub const card = @import("netlist/card.zig");
    pub const expr = @import("netlist/expr.zig");
    pub const flatten = @import("netlist/flatten.zig");
};

pub const devices = struct {
    pub const catalog = @import("devices/catalog.zig");
    pub const host = @import("devices/host.zig");
};

pub const placement = struct {
    pub const ctx = @import("place/ctx.zig");
    pub const spline = @import("place/spline.zig");
    pub const column = @import("place/column.zig");
    pub const orient = @import("place/orient.zig");
    pub const stack = @import("place/stack.zig");
    pub const order = @import("place/order.zig");
};

pub const route = struct {
    pub const lattice = @import("route/lattice.zig");
    pub const dijkstra = @import("route/dijkstra.zig");
    pub const tree = @import("route/tree.zig");
};

pub const metric = @import("metric.zig");

/// Symbol transform, bounding boxes, refdes anchor placement, group frames.
///
/// This is library surface, not renderer surface. Any consumer that draws — the
/// bundled gallery, a LaTeX exporter, a third-party C adapter — needs the same
/// answers to "where does this symbol's stroke go" and "where does this label fit
/// without colliding". Computing them once here, and exposing them through the C ABI,
/// is what makes a foreign renderer possible at all.
pub const geom = @import("geom.zig");

/// Structured data export. Library surface for the same reason as `geom`: a C
/// consumer that would otherwise walk forty accessors can take one document instead.
pub const json = @import("json.zig");

/// TikZ/LaTeX emitter — a shipped product feature, compiled only when the
/// `latex_renderer` build option is set.
///
/// This is the one format emitter that lives in the library rather than in
/// `examples/`, because paper figures are something a *user* asks for: they should
/// come from the library they already link against, not from a sample they have to
/// vendor and maintain. Gating it keeps consumers who only want geometry from
/// carrying the emitter and its escaping tables.
///
/// When the option is off this is `void`, so referencing `latex.write` is a compile
/// error naming the missing option rather than a link failure.
pub const latex = if (build_options.latex_renderer) @import("latex.zig") else void;

const build_options = @import("build_options");

/// The C ABI. Forced into the compilation below so that its `export fn`s land in the
/// static library whether or not any Zig caller references them.
pub const abi = @import("abi.zig");

// A foreign consumer links against the library and never calls into Zig directly, so
// nothing in `abi` is reachable from Zig code. Without this, semantic analysis never
// reaches the `export fn`s and the entire C surface is absent from `libcktimg.a`.
// This one line is what makes the static library usable from C at all.
comptime {
    _ = abi;
}

// Re-exports of the types callers actually name.
pub const Ir = ir.Ir;
pub const Physical = ir.Physical;
pub const Placed = ir.Placed;
pub const Report = ir.Report;
pub const Config = config.Config;
pub const Strings = strings.Strings;
const Orient = ids.Orient;

/// Reusable pipeline state: the five allocators plus the config.
///
/// Deinit-complete. Constructing one reserves nothing; capacity accumulates as the
/// first schematic is processed and is then reused. Not thread-safe — give each
/// thread its own, which is the reason config is a field here rather than a global.
pub const Pipeline = struct {
    /// Backing allocator for the three arenas and for `scratch`.
    gpa: Allocator,
    /// Lives as long as the schematic: source bytes, string pool, IR columns.
    doc: std.heap.ArenaAllocator,
    /// Reset between candidate orders. Never holds anything that must outlive one
    /// candidate — putting a result here is the one mistake this design can make,
    /// and the candidate-evaluation loop is the only code permitted to reset it.
    search: std.heap.ArenaAllocator,
    /// Survives `search` resets. Sized once to the largest lattice seen and reused
    /// for every net of every candidate.
    scratch: Scratch,
    /// Holds the winning geometry and any rendered bytes.
    out: std.heap.ArenaAllocator,
    /// Borrowed. Must outlive the pipeline.
    cfg: *const Config,

    /// Create a pipeline over `gpa`, borrowing `cfg`.
    ///
    /// Allocates nothing eagerly. `cfg` is not copied, so it must outlive the
    /// returned value; `&Config.default` is always valid for this.
    pub fn init(gpa: Allocator, cfg: *const Config) Pipeline {
        // `ArenaAllocator.init` reserves no page and `Scratch.empty` owns nothing, so
        // this constructor genuinely cannot fail — which is why it returns no error.
        return .{
            .gpa = gpa,
            .doc = .init(gpa),
            .search = .init(gpa),
            .scratch = .empty,
            .out = .init(gpa),
            .cfg = cfg,
        };
    }

    /// Release all three arenas and the scratch buffers.
    ///
    /// Invalidates every `Placed` and every rendered slice produced from this
    /// pipeline — they live in `out`. Callers that need a result to outlive the
    /// pipeline must use `place`, which transfers ownership instead.
    pub fn deinit(self: *Pipeline) void {
        self.doc.deinit();
        self.search.deinit();
        self.scratch.deinit(self.gpa);
        self.out.deinit();
    }

    /// Place `src`, leaving the result in `out`.
    ///
    /// Returns a borrowed view: the `Placed` and every array in it live in the
    /// pipeline's arenas and are invalidated by the next `run` or by `deinit`. This
    /// is the form to use when rendering immediately and discarding.
    ///
    /// Errors: `OutOfMemory`. A netlist that cannot be represented does not error —
    /// it produces a `Report` with entries plus whatever schematic was recoverable,
    /// because a partial drawing is more useful than a refusal.
    ///
    /// Post-condition: `doc` holds the IR and pool, `out` holds the geometry, and
    /// `search` has been reset to retain capacity.
    pub fn run(self: *Pipeline, src: []const u8) Allocator.Error!struct { Placed, Report } {
        const doc = self.doc.allocator();

        // --- document lifetime: source, pool, IR, and every Tier-A derivation ---
        //
        // The host class table is per-document too: the `SymbolIdx` values in the IR
        // are meaningless without it, and it must not outlive the IR that names it.
        const table = try doc.create(devices.host.Table);
        table.* = .init(doc);

        const built = try netlist.flatten.fromText(doc, self.cfg, table, src);
        const ir_p = try doc.create(Ir);
        ir_p.* = built.ir;

        const c = try placement.ctx.Ctx.build(doc, ir_p, table);
        var splines = try placement.spline.extract(doc, c);
        // `Ranker.init` asserts the spline count fits its fixed buffers. Clamping is
        // this caller's job, and dropping the tail is the honest reading: the extra
        // splines still place, they just do not take part in the order search.
        // ponytail: truncate; raise `max_splines` if a real deck ever exceeds it.
        if (splines.keyCount() > placement.order.max_splines) {
            const cut = placement.order.max_splines;
            splines = .{
                .offsets = splines.offsets[0 .. cut + 1],
                .values = splines.values[0..splines.offsets[cut]],
            };
        }
        const branch = try c.branchCounts(doc, splines);
        const ranker = try placement.order.Ranker.init(doc, c, splines, self.cfg);

        // --- Phase A: rank orders through the routing-free proxy ---
        var shortlist: [placement.order.max_refine]placement.order.Candidate = undefined;
        const want = @max(1, @min(self.cfg.layout.refine, placement.order.max_refine));
        var n_cand = placement.order.phaseA(&ranker, self.cfg, shortlist[0..want]);
        if (n_cand == 0) {
            // No splines: the empty order is still a legitimate drawing, every device
            // landing in an inserted column.
            shortlist[0] = .{};
            n_cand = 1;
        }

        // --- Phase B: place, route and measure each survivor in the search arena ---
        var best: usize = 0;
        var best_key: metric.Key = .worst;
        for (shortlist[0..n_cand], 0..) |cand, i| {
            _ = self.search.reset(.retain_capacity);
            // Losers are measured but never kept: their geometry dies with the reset,
            // so nothing is packed and `out` stays the size of one drawing.
            const key = (try self.evalOrder(c, ir_p, &ranker, splines, branch, cand, null)).key;
            if (key.order(best_key) == .lt) {
                best_key = key;
                best = i;
            }
        }

        // The winner is re-evaluated rather than copied, because its arrays lived in
        // the arena the next candidate reset. Evaluation is deterministic, so this is
        // a copy in every sense but the mechanism, and it costs one candidate's work
        // instead of an `out` arena sized to the whole shortlist.
        _ = self.search.reset(.retain_capacity);
        const win = try self.evalOrder(
            c,
            ir_p,
            &ranker,
            splines,
            branch,
            shortlist[best],
            self.out.allocator(),
        );
        _ = self.search.reset(.retain_capacity);

        return .{
            .{ .ir = ir_p.*, .physical = win.phys, .strings = built.strings },
            built.report,
        };
    }

    /// Place, route and measure one candidate order.
    ///
    /// Every intermediate — columns, orientations, the stack, the lattice, the routed
    /// polylines — comes out of the `search` arena and is invalidated by the next
    /// reset. `keep`, when non-null, is where the finished `Physical` is allocated
    /// instead; pass the `out` arena for the winner and null for a candidate that is
    /// only being scored.
    ///
    /// Writes the candidate's orientation into `ir.dev_orient`, so the last call wins
    /// — which is why the winner is evaluated last.
    ///
    /// Errors: `OutOfMemory` only.
    fn evalOrder(
        self: *Pipeline,
        c: placement.ctx.Ctx,
        ir_p: *Ir,
        ranker: *const placement.order.Ranker,
        splines: placement.ctx.SplineSet,
        branch: []const u16,
        cand: placement.order.Candidate,
        keep: ?Allocator,
    ) Allocator.Error!struct { key: metric.Key, phys: Physical } {
        const s = self.search.allocator();
        const cfg = self.cfg;
        const lay = cfg.layout;
        const grid = lay.grid;
        const nd = c.deviceCount();

        // A swap bit flips two electrically interchangeable neighbours inside one
        // spline. Only the values array changes, so the copy is one dupe.
        var sp = splines;
        if (cand.swap_mask != 0) {
            sp = .{ .offsets = splines.offsets, .values = try s.dupe(ids.DeviceIdx, splines.values) };
            for (ranker.swaps, 0..) |sw, k| {
                if (cand.swap_mask & (@as(u8, 1) << @intCast(k)) == 0) continue;
                const run_ = sp.sliceMut(sw.spline);
                if (sw.at + 1 < run_.len) std.mem.swap(ids.DeviceIdx, &run_[sw.at], &run_[sw.at + 1]);
            }
        }

        var ord: [placement.order.max_splines]u32 = undefined;
        for (cand.slice(), 0..) |v, k| ord[k] = v;

        const cols = try placement.column.assign(s, c, sp, ord[0..cand.len], branch);
        const orient = try placement.orient.compute(s, c, cols);
        @memcpy(ir_p.dev_orient, orient);
        const infos = try placement.column.classifyNets(s, c, cols, branch);
        const st = try placement.stack.run(s, c, cols, infos, orient, cfg);

        // --- device positions ---
        const pos = try s.alloc(ids.Pt, nd);
        @memset(pos, .{ .x = 0, .y = 0 });
        for (0..cols.count()) |ci| {
            const col = placement.column.ColumnIdx.at(ci);
            const extra: i32 = if (cols.kind[ci] == .shared)
                sharedShift(c, cols, st, orient, infos, cols.devices(col), lay)
            else
                0;
            for (cols.devices(col)) |d| {
                pos[d.i()] = .{ .x = st.col_x[ci], .y = st.absY(cols, d) + extra };
            }
        }

        // --- canvas extent and the two bus rows ---
        var ctop: i32 = std.math.maxInt(i32);
        var cbot: i32 = std.math.minInt(i32);
        for (0..cols.count()) |ci| {
            const col = placement.column.ColumnIdx.at(ci);
            if (!cols.inField(col)) continue;
            for (cols.devices(col)) |d| {
                const lo, const hi = ir_p.pinRange(d);
                for (lo..hi) |pi| {
                    const y = pos[d.i()].y + placement.stack.orientedTerm(c, orient, ids.PinIdx.at(pi)).y;
                    ctop = @min(ctop, y);
                    cbot = @max(cbot, y);
                }
            }
        }
        if (ctop > cbot) {
            ctop = 0;
            cbot = 0;
        }
        const power_bus = ctop - lay.bus_gap;
        const gnd_bus = cbot + lay.bus_gap;
        const top_margin = power_bus - lay.margin_gap;

        try self.placeFeedback(c, cols, st, orient, top_margin, pos);
        placeRails(c, cols, st, power_bus, gnd_bus, grid, pos);

        // --- pin coordinates ---
        const pin_xy = try s.alloc(ids.Pt, c.pinCount());
        for (0..nd) |di| {
            const d = ids.DeviceIdx.at(di);
            const lo, const hi = ir_p.pinRange(d);
            for (lo..hi) |pi| {
                pin_xy[pi] = pos[di].add(placement.stack.orientedTerm(c, orient, ids.PinIdx.at(pi)));
            }
        }

        // --- one lattice, one router, every net ---
        var bodies: std.ArrayList(route.lattice.Body) = .empty;
        var sites: std.ArrayList(route.lattice.Site) = .empty;
        for (0..nd) |di| {
            const d = ids.DeviceIdx.at(di);
            const rail = c.isRail(d);
            if (!rail) {
                try bodies.append(s, .{
                    .dev = d,
                    .rect = geom.placedRect(c.classOf(d), orient[di], pos[di]),
                });
            }
            const lo, const hi = ir_p.pinRange(d);
            for (lo..hi) |pi| {
                try sites.append(s, .{
                    .pin = ids.PinIdx.at(pi),
                    .dev = d,
                    .net = ir_p.pin_net[pi],
                    .at = pin_xy[pi],
                    .obstacle = !rail,
                });
            }
        }
        var lat = try route.lattice.Lattice.build(s, .{
            .col_x = st.col_x,
            .lane_x = st.lane_x.values,
            .bodies = bodies.items,
            .sites = sites.items,
            .power_bus = power_bus,
            .gnd_bus = gnd_bus,
            .top_margin = top_margin,
            .bot_margin = gnd_bus + lay.margin_gap,
            .grid = grid,
            .track_h = lay.track_h,
        });
        try self.scratch.ensure(self.gpa, lat.nodeCount());

        const jobs = try s.alloc(route.tree.Job, infos.count());
        for (jobs, 0..) |*j, xi| {
            const x = placement.column.InfoIdx.at(xi);
            const net = infos.net[xi];
            const mem = c.members(net);
            const terms = try s.alloc(ids.Pt, mem.len);
            var labels: std.ArrayList(ids.Pt) = .empty;
            for (mem, 0..) |p, k| {
                terms[k] = pin_xy[p.i()];
                if (!c.isRail(c.devOf(p))) try labels.append(s, pin_xy[p.i()]);
            }
            const lo, const hi = infos.span(x);
            j.* = .{
                .net = net,
                .kind = switch (c.classOfNet(net)) {
                    .power => .power,
                    .ground => .ground,
                    .signal => .signal,
                },
                .terminals = terms,
                .span = @intCast(hi.i() - lo.i()),
                .label_at = labels.items,
            };
        }
        route.tree.sortJobs(jobs);
        var wires: route.tree.Wires = .empty;
        try route.tree.routeAll(s, &lat, &self.scratch, jobs, &wires);

        // A rail that reaches no column has no bus to run along; it gets a lab pin at
        // its first terminal rather than a wire to nowhere.
        for (0..c.netCount()) |ni| {
            const net = ids.NetIdx.at(ni);
            if (!c.isRailNet(net)) continue;
            const mem = c.members(net);
            if (mem.len == 0) continue;
            var spans = false;
            for (mem) |p| {
                if (cols.column_of[c.devOf(p).i()] != .none) spans = true;
            }
            if (!spans) try wires.label(s, net, pin_xy[mem[0].i()]);
        }

        // --- measurement ---
        const alloc_out = keep orelse s;
        var phys: Physical = .empty;
        phys.pos = try alloc_out.dupe(ids.Pt, pos);
        phys.pin_xy = try alloc_out.dupe(ids.Pt, pin_xy);
        try wires.pack(alloc_out, c.netCount(), &phys);
        phys.junctions = try metric.junctions(alloc_out, ir_p.pin_net, phys);

        const counts = metric.countCrossingsAndOverlaps(phys);
        const margin = marginUse(phys, infos, c, top_margin);
        var staples: u32 = 0;
        var total_span: u32 = 0;
        for (0..infos.count()) |xi| {
            if (infos.case[xi] != .span_ge2) continue;
            if (c.isRailNet(infos.net[xi])) continue;
            const lo, const hi = infos.span(placement.column.InfoIdx.at(xi));
            staples += 1;
            total_span += @intCast(hi.i() - lo.i());
        }

        const key: metric.Key = .{
            .labels = @intCast(phys.labels.len),
            .pin_hits = if (lay.strict_geometry) countPinHits(c, phys) else 0,
            .geom_shorts = if (lay.strict_geometry) countGeomShorts(phys) else 0,
            .body_hits = countBodyHits(c, cols, orient, pos, phys),
            .overlaps = counts.overlaps,
            .crossings = counts.crossings,
            .staples = staples,
            .total_span = total_span,
            .forward_margin = margin.forward,
            .margin_tracks = margin.tracks,
            .netid_seq = metric.netIdSeq(infos.net),
        };
        return .{ .key = key, .phys = phys };
    }

    /// Feedback columns are margin-resident: centred over the columns they bridge, on
    /// the first backward-route row. Mutates `pos`.
    fn placeFeedback(
        self: *Pipeline,
        c: placement.ctx.Ctx,
        cols: placement.column.Columns,
        st: placement.stack.Stacked,
        orient: []const Orient,
        band: i32,
        pos: []ids.Pt,
    ) Allocator.Error!void {
        const s = self.search.allocator();
        const grid = self.cfg.layout.grid;

        var at: std.ArrayList(FeedbackAt) = .empty;
        for (0..cols.count()) |ci| {
            const col = placement.column.ColumnIdx.at(ci);
            if (cols.inField(col)) continue;
            const devs = cols.devices(col);
            if (devs.len == 0) continue;
            const d = devs[0];
            var sum: i64 = 0;
            var n: i64 = 0;
            for (c.conductingPins(d)) |p| {
                const net = c.netOf(p);
                if (net == .none) continue;
                for (c.members(net)) |q| {
                    const qc = cols.column_of[c.devOf(q).i()];
                    if (qc == .none or qc == col) continue;
                    sum += st.col_x[qc.i()];
                    n += 1;
                    break;
                }
            }
            const cx: i32 = if (n == 0) 0 else route.lattice.snapNear(@intCast(@divTrunc(sum, n)), grid);
            try at.append(s, .{ .x = cx, .d = d });
        }
        std.mem.sort(FeedbackAt, at.items, {}, FeedbackAt.lessThan);

        // The band is one row, so in strict mode two feedback devices given the same
        // centre would put different-net pins on the same point — a hard short on a
        // geometric-connectivity host. Spread them left to right instead.
        var next_free: i32 = std.math.minInt(i32);
        for (at.items) |e| {
            var x = e.x;
            if (self.cfg.layout.strict_geometry) {
                const r = placement.stack.orientedBox(c, orient, e.d);
                if (next_free != std.math.minInt(i32)) {
                    x = @max(x, route.lattice.snapCeil(next_free - r.min.x, grid));
                }
                next_free = x + r.max.x + self.cfg.layout.track_w;
            }
            pos[e.d.i()] = .{ .x = x, .y = band };
        }
    }

    /// Reset every arena, keeping capacity, ready for the next schematic.
    ///
    /// This is what makes repeat use allocation-free. Invalidates everything
    /// previously returned by `run`.
    pub fn reset(self: *Pipeline) void {
        // `.retain_capacity` is the whole point: the pages stay mapped, so the second
        // schematic reuses them instead of asking the OS again. `scratch` is untouched
        // — it is the one buffer sized to the largest lattice and meant to survive.
        _ = self.doc.reset(.retain_capacity);
        _ = self.search.reset(.retain_capacity);
        _ = self.out.reset(.retain_capacity);
    }
};

/// One margin-resident feedback device and the x it wants to sit at.
///
/// Sorted by `(x, device)` so that the strict-mode de-overlap pass walks them left to
/// right in an order two runs agree on.
const FeedbackAt = struct {
    x: i32,
    d: ids.DeviceIdx,

    fn lessThan(_: void, a: FeedbackAt, b: FeedbackAt) bool {
        if (a.x != b.x) return a.x < b.x;
        return a.d.i() < b.d.i();
    }
};

/// How far a `.shared` column must drop so its hub pin clears every branch pin
/// feeding it. Zero when the column holds no hub. Allocation-free.
fn sharedShift(
    c: placement.ctx.Ctx,
    cols: placement.column.Columns,
    st: placement.stack.Stacked,
    orient: []const Orient,
    infos: placement.column.NetInfos,
    devs: []const ids.DeviceIdx,
    lay: config.Layout,
) i32 {
    if (devs.len == 0) return 0;
    const d = devs[0];
    for (infos.shared_hub, 0..) |hub, xi| {
        if (hub == .none or c.devOf(hub) != d) continue;
        const hub_abs = st.absY(cols, d) + placement.stack.orientedTerm(c, orient, hub).y;
        var bmax: ?i32 = null;
        for (c.members(infos.net[xi])) |p| {
            const dev = c.devOf(p);
            if (dev == d or cols.column_of[dev.i()] == .none) continue;
            const y = st.absY(cols, dev) + placement.stack.orientedTerm(c, orient, p).y;
            bmax = if (bmax) |m| @max(m, y) else y;
        }
        const m = bmax orelse return 0;
        return route.lattice.snapCeil(@max(m + lay.abut_gap - hub_abs, 0), lay.grid);
    }
    return 0;
}

/// Rail symbols sit on their bus row, centred over the columns their net reaches.
fn placeRails(
    c: placement.ctx.Ctx,
    cols: placement.column.Columns,
    st: placement.stack.Stacked,
    power_bus: i32,
    gnd_bus: i32,
    grid: i32,
    pos: []ids.Pt,
) void {
    for (pos, 0..) |*p, di| {
        const d = ids.DeviceIdx.at(di);
        if (!c.isRail(d)) continue;
        const lo, const hi = c.ir.pinRange(d);
        var sum: i64 = 0;
        var n: i64 = 0;
        for (lo..hi) |pi| {
            const net = c.ir.pin_net[pi];
            if (net == .none) continue;
            for (c.members(net)) |q| {
                const qc = cols.column_of[c.devOf(q).i()];
                if (qc == .none) continue;
                sum += st.col_x[qc.i()];
                n += 1;
            }
        }
        const cx: i32 = if (n == 0) 0 else route.lattice.snapNear(@intCast(@divTrunc(sum, n)), grid);
        const power = c.symbolRoleOf(d) == .power_rail;
        p.* = .{ .x = cx, .y = if (power) power_bus else gnd_bus };
    }
}

/// Which margin rows the routes used, and how many forward nets ended up there.
///
/// The margin band is for backward feedback; a forward net up there means the column
/// order failed to keep it local, which is what `Key.forward_margin` records.
fn marginUse(
    phys: Physical,
    infos: placement.column.NetInfos,
    c: placement.ctx.Ctx,
    top_margin: i32,
) struct { forward: u32, tracks: u32 } {
    // At most a handful of margin rows exist, so a linear scan beats a set — and it
    // keeps the count reproducible without sorting anything.
    var rows: [64]i32 = undefined;
    var n_rows: usize = 0;
    var forward: u32 = 0;

    for (0..infos.count()) |xi| {
        const net = infos.net[xi];
        var up = false;
        const ni = net.i();
        if (ni + 1 >= phys.net_seg.len) continue;
        for (phys.net_seg[ni]..phys.net_seg[ni + 1]) |seg| {
            const poly = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
            for (poly[1..], poly[0 .. poly.len - 1]) |b, a| {
                if (a.y != b.y or a.x == b.x or a.y > top_margin) continue;
                up = true;
                if (std.mem.indexOfScalar(i32, rows[0..n_rows], a.y) == null and n_rows < rows.len) {
                    rows[n_rows] = a.y;
                    n_rows += 1;
                }
            }
        }
        if (up and !infos.backward[xi] and !c.isRailNet(net)) forward += 1;
    }
    return .{ .forward = forward, .tracks = @intCast(n_rows) };
}

/// Wires driven through a device body they do not belong to.
///
/// Rails have no body, and a feedback column is margin-resident, so neither takes
/// part. A device whose own net owns the wire is exempt — that is the wire arriving
/// at its own pin, not cutting through a stranger.
fn countBodyHits(
    c: placement.ctx.Ctx,
    cols: placement.column.Columns,
    orient: []const Orient,
    pos: []const ids.Pt,
    phys: Physical,
) u32 {
    if (phys.net_seg.len == 0) return 0;
    var hits: u32 = 0;
    for (0..phys.net_seg.len - 1) |ni| {
        const net = ids.NetIdx.at(ni);
        for (phys.net_seg[ni]..phys.net_seg[ni + 1]) |seg| {
            const poly = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
            for (poly[1..], poly[0 .. poly.len - 1]) |b, a| {
                const r = geom.fromCorners(a, b);
                for (0..c.deviceCount()) |di| {
                    const d = ids.DeviceIdx.at(di);
                    if (c.isRail(d)) continue;
                    const col = cols.column_of[di];
                    if (col != .none and !cols.inField(col)) continue;
                    if (ownsPinOn(c, d, net)) continue;
                    if (r.intersects(geom.placedRect(c.classOf(d), orient[di], pos[di]))) hits += 1;
                }
            }
        }
    }
    return hits;
}

/// Does `d` have a terminal on `net`? The own-body exemption in `countBodyHits`.
fn ownsPinOn(c: placement.ctx.Ctx, d: ids.DeviceIdx, net: ids.NetIdx) bool {
    const lo, const hi = c.ir.pinRange(d);
    for (lo..hi) |pi| {
        if (c.ir.pin_net[pi] == net) return true;
    }
    return false;
}

/// Wires touching a foreign net's pin point — a short on a geometric host.
fn countPinHits(c: placement.ctx.Ctx, phys: Physical) u32 {
    if (phys.net_seg.len == 0) return 0;
    var hits: u32 = 0;
    for (0..phys.net_seg.len - 1) |ni| {
        const net = ids.NetIdx.at(ni);
        for (phys.net_seg[ni]..phys.net_seg[ni + 1]) |seg| {
            const poly = phys.wire_pts[phys.seg_pt[seg]..phys.seg_pt[seg + 1]];
            for (poly[1..], poly[0 .. poly.len - 1]) |b, a| {
                for (c.ir.pin_net, phys.pin_xy, 0..) |pn, pp, pi| {
                    if (pn == .none or pn == net) continue;
                    // Rails render as bus symbols, not placed pins, so a wire through
                    // their point is not a short.
                    if (c.isRail(c.devOf(ids.PinIdx.at(pi)))) continue;
                    if (metric.onSegment(pp, a, b)) hits += 1;
                }
            }
        }
    }
    return hits;
}

/// Wire vertices of one net landing on another net's wire — a T-junction short.
fn countGeomShorts(phys: Physical) u32 {
    if (phys.net_seg.len == 0) return 0;
    var hits: u32 = 0;
    const nets = phys.net_seg.len - 1;
    for (0..nets) |ai| {
        for (phys.net_seg[ai]..phys.net_seg[ai + 1]) |as| {
            for (phys.wire_pts[phys.seg_pt[as]..phys.seg_pt[as + 1]]) |v| {
                for (0..nets) |bi| {
                    if (bi == ai) continue;
                    for (phys.net_seg[bi]..phys.net_seg[bi + 1]) |bs| {
                        const pb = phys.wire_pts[phys.seg_pt[bs]..phys.seg_pt[bs + 1]];
                        for (pb[1..], pb[0 .. pb.len - 1]) |b1, b0| {
                            if (metric.onSegment(v, b0, b1)) hits += 1;
                        }
                    }
                }
            }
        }
    }
    return hits;
}

/// Search buffers that must survive a `search` arena reset.
///
/// Sized to a node count and grown monotonically — never shrunk, because the next
/// candidate order is usually about as large as the last.
///
/// ## Generation stamping instead of clearing
///
/// `dist` is only meaningful where `dist_gen[i] == gen`. Each net's search bumps
/// `gen`, which costs one integer increment; clearing the array instead would cost a
/// full `memset` of `nodes * 2 * 4` bytes per net per candidate order — for a 200k
/// node lattice, 1.6 MB of pointless writes multiplied by every net and every
/// candidate.
pub const Scratch = struct {
    /// Best known cost per (node, incoming direction). Length `capacity * 2`.
    dist: []u32,
    /// Generation stamp parallel to `dist`. An entry is live iff it equals `gen`.
    dist_gen: []u32,
    /// Parent link for path reconstruction, parallel to `dist`.
    prev: []u32,
    /// Reused priority queue storage.
    heap: []HeapEntry,
    /// Nodes the current sizing covers.
    capacity: usize,
    /// Current search generation. Incremented per net.
    gen: u32,

    pub const empty: Scratch = .{
        .dist = &.{},
        .dist_gen = &.{},
        .prev = &.{},
        .heap = &.{},
        .capacity = 0,
        .gen = 0,
    };

    /// One pending node in the priority queue.
    ///
    /// 8 bytes, so a 4-ary heap keeps entries dense and the sift loops tight. Cost
    /// first so a comparison is a single 32-bit compare.
    pub const HeapEntry = struct {
        cost: u32,
        /// Encoded `(node, direction)`, matching the `dist` indexing.
        node_dir: u32,
    };

    /// Ensure room for `nodes` lattice nodes, growing if needed.
    ///
    /// Idempotent and monotonic: calling it with a smaller count is a no-op. On
    /// growth, `dist_gen` is zeroed and `gen` reset to 0, since stamps from the old
    /// sizing no longer correspond to the same nodes.
    ///
    /// Post-condition: `dist.len == dist_gen.len == prev.len == capacity * 2`.
    pub fn ensure(self: *Scratch, gpa: Allocator, nodes: usize) Allocator.Error!void {
        if (nodes <= self.capacity) return;

        const slots = nodes * 2;
        const dist = try gpa.alloc(u32, slots);
        errdefer gpa.free(dist);
        const dist_gen = try gpa.alloc(u32, slots);
        errdefer gpa.free(dist_gen);
        const prev = try gpa.alloc(u32, slots);
        errdefer gpa.free(prev);
        const heap = try gpa.alloc(HeapEntry, @import("route/dijkstra.zig").heapCapacityFor(
            @intCast(nodes),
        ));

        // Only now that every allocation succeeded is the old sizing unreachable.
        gpa.free(self.dist);
        gpa.free(self.dist_gen);
        gpa.free(self.prev);
        gpa.free(self.heap);

        // Stamps from the old sizing describe different nodes, so both the array and
        // the counter restart.
        @memset(dist_gen, 0);
        self.* = .{
            .dist = dist,
            .dist_gen = dist_gen,
            .prev = prev,
            .heap = heap,
            .capacity = nodes,
            .gen = 0,
        };
    }

    /// Begin a new search, invalidating every `dist` entry in constant time.
    ///
    /// Handles generation overflow by clearing the stamp array and restarting at 1 —
    /// the one case where the O(n) clear is unavoidable, reached once per four
    /// billion searches.
    pub fn newGeneration(self: *Scratch) void {
        if (self.gen == std.math.maxInt(u32)) {
            @memset(self.dist_gen, 0);
            self.gen = 1;
        } else {
            self.gen += 1;
        }
    }

    /// True when `dist[slot]` belongs to the current search.
    pub fn isLive(self: Scratch, slot: usize) bool {
        return slot < self.dist_gen.len and self.dist_gen[slot] == self.gen;
    }

    pub fn deinit(self: *Scratch, gpa: Allocator) void {
        gpa.free(self.dist);
        gpa.free(self.dist_gen);
        gpa.free(self.prev);
        gpa.free(self.heap);
        self.* = .empty;
    }
};

/// Parse and place `src`, transferring ownership of the result to the caller.
///
/// The convenience entry point. Internally builds a `Pipeline`, runs it, copies the
/// result out of the pipeline's arenas into `gpa`, and tears the pipeline down — so
/// unlike `Pipeline.run`, the returned value outlives the call.
///
/// Caller owns the returned `Placed` and `Report` and must `deinit` both with `gpa`.
///
/// Errors: `OutOfMemory`. Unrepresentable netlist content is reported, not raised.
pub fn place(gpa: Allocator, cfg: *const Config, src: []const u8) Allocator.Error!struct { Placed, Report } {
    var p = Pipeline.init(gpa, cfg);
    defer p.deinit();
    const view, const rep = try p.run(src);

    // Every column is copied out individually because `Placed.deinit` frees each one
    // with `gpa`; a single block copy would be one allocation and nine frees.
    var placed: Placed = .{ .ir = .empty, .physical = .empty, .strings = .empty };
    errdefer placed.deinit(gpa);
    placed.ir.dev_symbol = try gpa.dupe(ids.SymbolIdx, view.ir.dev_symbol);
    placed.ir.dev_orient = try gpa.dupe(Orient, view.ir.dev_orient);
    placed.ir.dev_pin0 = try gpa.dupe(u32, view.ir.dev_pin0);
    placed.ir.pin_net = try gpa.dupe(ids.NetIdx, view.ir.pin_net);
    placed.ir.dev_name = try gpa.dupe(ids.StrId, view.ir.dev_name);
    placed.ir.dev_value = try gpa.dupe(ids.StrId, view.ir.dev_value);
    placed.ir.net_name = try gpa.dupe(ids.StrId, view.ir.net_name);
    placed.ir.group_path = try gpa.dupe(ids.StrId, view.ir.group_path);
    placed.ir.group_master = try gpa.dupe(ids.StrId, view.ir.group_master);

    placed.physical.pos = try gpa.dupe(ids.Pt, view.physical.pos);
    placed.physical.pin_xy = try gpa.dupe(ids.Pt, view.physical.pin_xy);
    placed.physical.net_seg = try gpa.dupe(u32, view.physical.net_seg);
    placed.physical.seg_pt = try gpa.dupe(u32, view.physical.seg_pt);
    placed.physical.wire_pts = try gpa.dupe(ids.Pt, view.physical.wire_pts);
    placed.physical.junctions = try gpa.dupe(ids.Pt, view.physical.junctions);
    placed.physical.labels = try gpa.dupe(ir.Label, view.physical.labels);

    placed.strings.bytes = try gpa.dupe(u8, view.strings.bytes);
    placed.strings.spans = try gpa.dupe(strings.Span, view.strings.spans);

    var report: Report = .empty;
    errdefer report.deinit(gpa);
    report.ignored = try gpa.dupe(ir.Note, rep.ignored);
    report.skipped = try gpa.dupe(ir.Note, rep.skipped);

    return .{ placed, report };
}

/// Parse, place and emit in one call.
///
/// `w` receives the emitted document, so a caller writing to a file never
/// materializes the whole thing in memory. `emitFn` is any function matching the
/// signature — `json.write` from this library, or an emitter the caller supplies. The
/// library ships no format emitter beyond JSON; see the module header.
///
/// Caller owns the returned `Report`.
pub fn run(
    gpa: Allocator,
    cfg: *const Config,
    src: []const u8,
    w: *std.Io.Writer,
    comptime emitFn: fn (Placed, *const Config, *std.Io.Writer) anyerror!void,
) anyerror!Report {
    var placed, var report = try place(gpa, cfg, src);
    defer placed.deinit(gpa);
    errdefer report.deinit(gpa);
    try emitFn(placed, cfg, w);
    return report;
}

test {
    std.testing.refAllDecls(@This());
}
