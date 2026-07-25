# cktImg — Zig architecture

Target: Zig 0.16.0. Source of truth for behavior: `docs/ALGORITHM.md` (Rust tree) plus
the pseudocode artifacts produced by the clean-room pass described in
[Migration pipeline](#migration-pipeline).

This document decides three things: how the data is laid out, how the code is organized
around that layout, and how the port is sequenced and verified.

---

## 1. What the program is

One transformation, in five stages:

```
bytes (SPICE text)
  -> tokens          (spans into one source arena)
  -> IR              (SoA: devices, pins, nets, string pool)
  -> placement       (columns, y-offsets, x-offsets)
  -> routes          (min-cost trees on a Hanan lattice)
  -> bytes           (SVG / TikZ / JSON / C-ABI views)
```

Every stage is bytes-in / bytes-out over flat arrays. Nothing in the pipeline needs a
pointer graph, and nothing needs to iterate a hash map. Both of those are *rules*, not
preferences — see [Determinism](#7-determinism-is-structural).

## 2. Module layout

Rust needed nine crates because that is Cargo's unit of publication. Zig has no such
constraint, so this is **one module** with files grouped by pipeline stage. Flat beats a
crate graph: no circular-dependency contortions, no re-export aliasing, and the whole
compilation unit is visible to `comptime`.

```
src/
  root.zig          public API, the five allocators (§3), C-ABI force-link
  ids.zig           index enums, sentinels
  strings.zig       byte arena + span table + interner
  csr.zig           generic CSR builder (counting sort)
  netlist/
    source.zig      file loading, .include expansion into one arena
    token.zig       zero-copy tokenizer (spans, not Strings)
    card.zig        SPICE card classification
    expr.zig        .param scope + {expr} evaluation
    flatten.zig     .subckt hierarchy flattening
  ir.zig            SoA schematic: devices / pins / nets / groups
  devices/
    catalog.zig     comptime class tables (builtin)
    host.zig        runtime-registered classes
  config.zig        lint.toml knobs
  place/
    ctx.zig         Tier-A precompute (CSR, net class, conducting pins)
    spline.zig      spline extraction (ground-distance walk)
    column.zig      column assignment + kinds
    order.zig       two-phase order search
    stack.zig       y-stacking, row profiles, alignment, x-placement
    orient.zig      device orientation
  route/
    lattice.zig     Hanan grid construction, blocking, occupancy
    dijkstra.zig    direction-aware search
    tree.zig        multi-terminal tree growth, label fallback
  metric.zig        selection key measurement
  geom.zig          symbol transform, bounds, refdes anchors, group frames
  json.zig          structured data export
  abi.zig           C ABI (zero-copy over the IR)

examples/
  self-hosted/src/  svg.zig, gallery.zig, main.zig   — the dev gallery
  latex/src/        tikz.zig, main.zig               — the paper exporter
```

`place/` and `route/` are the only directories where the clean-room barrier is strictly
enforced. Everything else is data or formatting — see [tiers](#migration-pipeline).

### Format emitters are not library surface

The library's product is **geometry**: placed symbols, routed polylines, junctions,
labels, plus the transform and collision helpers in `geom.zig` needed to draw them.
SVG and TikZ emitters live under `examples/`, built on the same public API and C ABI
that a third-party consumer gets.

This is a correctness property rather than tidiness. The bundled gallery renderer has
no privileged access to internals, so if it can draw a schematic then an external
adapter can too — the C ABI is exercised by our own primary consumer on every build.
Promoting an emitter into the library would let the two paths diverge silently, and
the first symptom would be a bug report from someone whose adapter cannot reproduce
our gallery.

What *does* stay in the library is anything an emitter cannot correctly recompute on
its own: the mirror-then-rotate transform order, body extents, refdes anchor
collision avoidance, group frame boxes, and JSON export. Those are answers, not
formats — duplicating them per emitter is how two renderers of the same schematic
start disagreeing.

## 3. Lifetimes decide the allocators

Five lifetimes, five allocators. This is the largest structural win over the Rust tree,
which routes per-candidate-order work through the global allocator.

| Lifetime | Allocator | Holds |
|---|---|---|
| program | comptime / `static` | builtin device catalog, cost constants |
| document | `doc: ArenaAllocator` | source bytes, string pool, IR (devices/pins/nets), config |
| per candidate order | `search: ArenaAllocator`, **reset each order** | column assignment, y/x offsets, lattice arrays, route polylines |
| whole run, reused | `scratch: []u8` fixed buffer | Dijkstra `dist`/`prev`/heap, sized once to the largest lattice |
| result | `out: ArenaAllocator` | winning `Physical`, rendered bytes |

The search arena is the point. Phase B evaluates up to `refine` (default 16) orders; each
builds a lattice, routes every net, measures, and throws it all away.
`arena.reset(.retain_capacity)` between orders means the second order onward allocates zero
pages. The Rust version pays malloc/free for the lattice, occupancy vectors, and every
route polyline, 16 times over.

Scratch is separate from search because Dijkstra buffers must survive an arena reset —
they are sized once (to `max_nodes * 2`) and reused across every net of every order.

The public API mirrors this: `place(gpa, src) -> Placed` allocates a `doc`+`out` pair and
frees the rest; the fine-grained `placeInto(ctx: *Pipeline, src)` lets a caller supply all
five and drive N schematics with no allocation after warm-up.

## 4. The IR

Already SoA in Rust; port the layout, tighten the encodings.

```zig
pub const DeviceIdx = enum(u32) { _ };
pub const PinIdx    = enum(u32) { _ };
pub const SymbolIdx = enum(u32) { _ };
pub const StrId     = enum(u32) { _ };
pub const NetIdx    = enum(u32) { none = 0, _ };  // 1-based; 0 is "floating"
```

`NetIdx.none = 0` rather than `?NetIdx`. Zig does **not** niche-optimize an optional
non-exhaustive enum, so `?NetIdx` is 8 bytes; a sentinel keeps the pin→net column at
4 bytes per pin, which is the hottest column in the program.

```zig
pub const Ir = struct {
    // devices: SoA columns, CSR into pins
    dev_name:   []StrId,
    dev_symbol: []SymbolIdx,
    dev_value:  []StrId,
    dev_orient: []Orient,      // packed struct(u8): rot: u2, mirror: bool
    dev_pin0:   []u32,         // len = n_dev + 1, sentinel-terminated

    pin_net:    []NetIdx,      // the hot column
    net_name:   []StrId,

    // hierarchy record, annotation only — cold
    group_path:   []StrId,
    group_master: []StrId,
};
```

The hot/cold split is already implicit: `dev_name`, `dev_value` and `group_*` are touched
once at render and never during place-and-route. Keeping them as separate columns rather
than fields of a device struct means the P&R passes never pull a name into cache.

Placement results are their own SoA block with nested CSR (net → segment → point), built
directly into the `out` arena:

```zig
pub const Physical = struct {
    pos:       []Pt,     // by DeviceIdx
    pin_xy:    []Pt,     // by PinIdx
    net_seg:   []u32,    // CSR: NetIdx -> segments
    seg_pt:    []u32,    // CSR: segment -> points
    wire_pts:  []Pt,
    junctions: []Pt,
    labels:    []Label,
};
```

`Pt` is `struct { x: i32, y: i32 }`. The grid is integer throughout — no floats anywhere in
place-and-route, so every geometric comparison is exact and the output is byte-reproducible
by construction rather than by epsilon discipline.

### Adjacency is CSR, always

`csr.zig` exposes one generic builder used for every many-to-many relation:

```zig
pub fn Csr(comptime Key: type, comptime Val: type) type { ... }
// build: counting pass -> prefix sum -> placement pass. Two passes, no per-key list.
// slice(key) -> []const Val
```

Relations built with it: net→pins, device→conducting-pins, net→segments, column→devices,
spline→devices. In Rust several of these are `Vec<Vec<_>>` or a `HashMap<Vec<usize>, _>`;
all of them collapse to one offsets array plus one values array. A lookup returns a slice
and allocates nothing.

## 5. Netlist front end: spans, not strings

The Rust tokenizer allocates a `String` per token and lowercases each one. It is the most
allocation-heavy layer in the codebase, and it discards position information (errors carry
a line number, not a span).

Zig design:

1. **One source arena.** Every file — the root plus every `.include` / `.lib` expansion —
   is appended into one growing byte arena. A side table
   `files: []struct { start: u32, name: StrId }` maps any global offset back to
   `(file, line, col)` on demand, for diagnostics only. This replaces Rust's
   build-a-giant-`String` expansion pass with the same single buffer it was already
   producing, minus the intermediate copies.

2. **Tokens are spans.** `MultiArrayList(Token)` with columns `{ off: u32, len: u32, kind: Kind }`,
   `Kind` a `packed struct(u8)` distinguishing word / number / punct / continuation. No
   allocation per token, and no lowercasing pass — **case folding happens once, at intern
   time**, since the only consumer that cares about case-insensitivity is name lookup.

3. **Errors carry spans.** A diagnostic is `{ off: u32, len: u32, reason: Reason }` where
   `Reason` is an enum, not a string. 12 bytes, no allocation. Message text is a `switch`
   over `Reason` produced only when someone formats the report. Rust stores the reassembled
   line text for every ignored card, which is pure waste in the common case where nobody
   reads the report.

4. **Param scope is a stack, not a cloned map.** `.subckt` nesting (max depth 64) becomes a
   single `MultiArrayList(Binding){ name: StrId, value: f64 }` plus a `[64]u32` array of
   frame boundaries. Lookup walks frames innermost-out — at most 64 short linear scans over
   contiguous memory, which at these sizes beats a `HashMap<String, f64>` cloned per
   instantiation on both allocation and cache behavior.

5. **Interned strings are NUL-terminated.** The interner appends a `0` after every string;
   the span length excludes it. Costs one byte per distinct name and lets `abi.zig` hand C a
   `[*:0]const u8` straight out of the pool with **no copy** — see §9.

## 6. Router: flat arrays, reused search state

The lattice is a Hanan grid: `xs: []i32` and `ys: []i32` (sorted, deduped, drawn from pin
coordinates, column axes, lane axes, body edges, bus rows and margin rows). Node index is
`iy * nx + ix`. Everything below is one flat allocation out of the `search` arena.

```zig
nodes   = nx * ny
h_edges = (nx - 1) * ny        // horizontal edge (ix,iy) -> (ix+1,iy)
v_edges = nx * (ny - 1)
```

| Array | Type | Per element | Purpose |
|---|---|---|---|
| `h_blk`, `v_blk` | `[]DeviceIdx` (sentinel) | 4 B | device body blocking this edge |
| `h_occ`, `v_occ` | `[]NetIdx` (sentinel) | 4 B | net already drawn on this edge |
| `node_pin` | `[]PinIdx` (sentinel) | 4 B | pin sitting on this node |
| `node_net` | `[]NetIdx` (sentinel) | 4 B | net with a wire vertex here |

Rust stores per-edge *lists* of blocking device IDs. One `u32` suffices: an edge blocked by
two bodies is still blocked, and the own-net exemption test only needs to know whether the
blocker is the device owning the route's pin. **Verify this on the fixture set** — if a
route ever needs "blocked by A *or* B, exempt for A", the array widens to a `u64` pair
before it goes back to being a list.

### Search state, reused

```zig
dist:     []u32,   // len = nodes * 2  (direction-aware: last move H or V)
dist_gen: []u32,   // generation stamp, same length
prev:     []u32,
heap:     []HeapEntry,   // 4-ary heap, reused
```

Two decisions:

- **Generation stamping instead of clearing.** Each net's search bumps a counter; `dist[i]`
  is live only if `dist_gen[i] == gen`. Clearing a 200k-node lattice per net costs
  1.6 MB of `memset` × nets × orders in the Rust design; here it costs one integer
  increment.
- **4-ary heap in a reused buffer**, not a fresh heap allocation per call. Weights are small
  integers (1 / 10 / 80 / 900 / 3000), so a bucket queue (Dial's) would be O(1) per
  operation — but bucket count scales with the largest single-edge increment
  (`W_BEND + W_CROSS + W_OFF × longest_span`), which needs a sizing analysis this port does
  not need yet. `// ponytail: 4-ary heap; swap to a bucket queue if profiling puts the heap in the top three.`

### Costs are comptime constants

```zig
pub const W = struct {
    pub const base   = 10;
    pub const bus    = 1;
    pub const off    = 80;
    pub const margin = 80;
    pub const bend   = 900;
    pub const cross  = 3000;
};
```

These are not config knobs — `ALGORITHM.md` is explicit that they encode what a schematic
*means*. Keeping them `comptime` (rather than in `Config`) lets the relaxation loop
constant-fold, and makes "these are not tunable" a compile-time fact instead of a comment.

### Tree growth

A net with k terminals grows as: seed at one terminal, then repeatedly run the
direction-aware Dijkstra with **every node already in the tree as a zero-cost source**,
stop at the nearest unconnected terminal, fold the path in. Multi-source is what makes
trunks, buses and T-junctions emerge rather than being special-cased. Implementation: seed
the heap with all tree nodes at distance 0 before each expansion. No separate "bus" code
path exists, by design.

## 7. Determinism is structural

Output must be byte-reproducible. Three rules enforce it:

1. **Never iterate a hash map.** Where Rust uses `HashMap<Vec<usize>, Vec<DeviceIdx>>`
   (series-device grouping) or `HashMap<u32, usize>` (shared-device anchors), the Zig port
   sorts a key array and either binary-searches or builds a CSR by counting sort. A hash map
   may be used for *membership* (interner dedup) but never as an iteration source.
2. **Integers only.** No float in place-and-route; every tie breaks on integer comparison.
3. **The selection key is a struct with a total order**, compared field by field:

```zig
pub const Key = struct {
    labels: u32, pin_hits: u32, geom_shorts: u32, body_hits: u32, overlaps: u32,
    crossings: u32, staples: u32, total_span: u32, forward_margin: u32,
    margin_tracks: u32, netid_seq: u64,
    pub fn lessThan(a: Key, b: Key) bool { ... }  // field order IS the priority order
};
```

Never a weighted sum. The declaration order is the documented priority order from
`ALGORITHM.md`; reordering the struct is therefore a behavior change, which is the intent.

## 8. Order search allocates nothing

Phase A streams every column order (and every free intra-spine swap) through a cheap proxy
and keeps the best `refine`:

```zig
const Proxy = struct { total_signal_span: u32, backward_nets: u32 };
var best: [max_refine]Candidate = undefined;   // fixed, on the stack
var perm: [max_splines]u8 = undefined;         // Heap's algorithm, in place
```

Permutation generation is Heap's algorithm over a stack array; the top-K is insertion into
a fixed array. Zero heap allocation in a loop that may run 10! times. Phase B then evaluates
only the survivors, each in a fresh `search` arena reset.

`enum_limit` (default 10) and `refine` (default 16) stay `Config` fields — they are resource
bounds, not opinions. The factorial enumeration is a known gap, carried over unchanged; do
not "fix" it during the port.

## 9. Renderers and the C ABI

**Renderers take a writer.** `render(ir, strings, cfg, w: *std.Io.Writer) !void` for each of
SVG / TikZ / JSON. Rust's `String` + `writeln!` per element becomes one buffered writer; a
caller wanting a string passes an `ArrayList` writer, a caller writing a file passes the
file. No `Backend` trait or vtable — the three emitters are separate functions, and the
*only* thing shared is `render/walk.zig`, which holds the symbol-transform math (orientation
apply, bounds accumulation, refdes anchoring, group boxes). Share the geometry, not an
interface with three implementations.

**The C ABI is a view, not a copy.** Rust's `CktimgSch` rebuilds the entire schematic as a
parallel structure of `CString`s and nested `Vec`s — 968 lines and a full duplicate in
memory. Because interned strings are NUL-terminated (§5) and `Physical` is already CSR, the
Zig handle is `*Placed` itself:

```zig
export fn cktimg_device_name(h: ?*const Placed, d: usize) ?[*:0]const u8;
export fn cktimg_wire_segment_points(h: ?*const Placed, w: usize, s: usize,
                                     out: *[*]const i32) usize;  // zero-copy
```

Ownership rules stay exactly as `cktimg.h` documents them: strings and point arrays are
**borrowed** from the handle and valid until `cktimg_sch_free`; only `cktimg_string_free`
results are caller-owned. Null handles and out-of-range indices return null/0/false rather
than trapping — that is a trust boundary and stays fully checked.

**Config is threaded, not global.** Rust's `OnceLock` + `cfg()` becomes a `*const Config`
field on the pipeline context. One extra parameter through `place/` and `render/`; in
exchange, tests vary knobs without process-global state and two schematics can be placed
concurrently.

---

## Migration pipeline

The clean-room discipline applies, but **not uniformly** — the barrier earns its cost where
the code is accumulated judgement and wastes it where the code is a data table. Three tiers:

### Tier 1 — clean-room, barrier strictly enforced (~3,500 LOC)

`place/*`, `route/*`, `metric.zig`.

This is where re-deriving from a specification is worth the effort, for two reasons.
`ALGORITHM.md` is *already* most of the spec — 564 lines of stated intent, costs, and
measured trade-offs — so the Describer is filling gaps rather than starting cold. And the
Rust here carries residue of a design that changed underneath it (the "Known gaps" section
names four); writing the spec is the chance to notice which residue is load-bearing and
which is scar tissue.

Describer writes `pseudocode/place/<fn>.md`, `pseudocode/route/<fn>.md`. The Implementer
sees only those files and this document — do not let it open the Rust tree.

### Tier 2 — spec first, barrier soft (~2,500 LOC)

`netlist/*`, `ir.zig`, `config.zig`.

Behavior needs a written spec — SPICE dialect quirks, the bulk-node drop, XSPICE card
mapping, `.lib` section extraction, expression SI suffixes, the ignored-vs-skipped
distinction — because those are *requirements* that will otherwise be silently dropped. But
the layout is being deliberately restructured (§5), so there is nothing to gain by hiding
the original: the Zig will not resemble it regardless. Write the behavior spec, consult the
Rust for dialect edge cases, restructure freely.

### Tier 3 — mechanical, no barrier (~2,000 LOC)

`devices/catalog.zig`, `render/*`, `abi.zig`.

96 device classes × terminals × draw primitives is *data*. A barrier here means retyping
1,034 lines of coordinates from prose, which manufactures transcription errors rather than
preventing them. Machine-convert instead: emit the Rust `CLASSES` table as JSON from a
one-off binary, generate `catalog.zig` from it, and diff the two renderings of the same
fixture to confirm the conversion. Renderers and the ABI are format-following code with an
externally fixed contract (`cktimg.h`, TikZ syntax); transliterate them.

Set up the ledger across all three tiers so nothing is silently dropped:

```bash
python ~/.claude/skills/clean-room-pseudocode-pipeline/scripts/coverage_ledger.py \
  init --root ../crates --out ledger.json
python ~/.claude/skills/clean-room-pseudocode-pipeline/scripts/coverage_ledger.py \
  status --ledger ledger.json
```

Add a `tier` field per unit before starting Phase 1.

### Sequence

Dependency order, each step independently verifiable:

1. `ids` / `strings` / `csr` — pure data structures, unit-tested in isolation.
2. `netlist` + `ir` → **verify:** dump IR as JSON, byte-compare against the Rust IR dump
   for all 21 fixtures. The front end is done when this is clean.
3. `devices` catalog (generated) → **verify:** render each builtin symbol, diff SVG.
4. `config`.
5. `place/ctx` + `spline` + `column` → **verify:** column-assignment dump per fixture.
6. `place/stack` + `orient` + `order` → **verify:** device positions per fixture.
7. `route` + `metric` → **verify:** full golden JSON, byte-identical.
8. `render` + `abi` → **verify:** golden SVG/TikZ, plus the existing C ABI smoke test.

### Verification is golden output, not diffed source

The 21 fixture circuits produce golden JSON from the Rust implementation. Those are
*outputs* — comparing against them does not breach the barrier, and it is the only check
that meaningfully catches router drift, since a router can be individually correct at every
function and still produce a different drawing.

Byte-identical is the target and is achievable: integer grid, no hash-map iteration,
explicit tie-breaks. Where the Zig deliberately diverges (the inserted-column gap, if the
spec pass decides to fix it), that fixture's golden file is regenerated **and the reason
recorded in the ledger** — a divergence without a written reason is a bug.

Per-stage golden comparison at steps 2, 5, 6 and 7 is what keeps a mismatch localizable. A
single end-to-end diff on a 10k-LOC port tells you only that something is wrong.
