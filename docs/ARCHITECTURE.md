# cktImg — architecture

Target: Zig 0.16.0. This document describes how the data is laid out and how the code is
organized around that layout, and argues for each choice against the alternative it
displaced.

Companion documents: [docs/ALGORITHM.md](ALGORITHM.md) is the behavioral specification —
what a good drawing is and why each routing cost is what it is. [docs/LINT.md](LINT.md) is
the rule table. [docs/TARGETS.md](TARGETS.md) is the target-manifest schema.
[docs/CONVENTIONS.md](CONVENTIONS.md) is the code style these files follow.

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

**One module**, files grouped by pipeline stage. A crate graph would buy publication units
nobody needs and charge circular-dependency contortions, re-export aliasing, and a
`comptime` that can only see part of the program. Flat keeps the whole compilation unit
visible.

```
src/
  root.zig          public API, the five lifetimes (§3), C-ABI force-link
  ids.zig           index enums, sentinels, Pt, Orient
  strings.zig       byte arena + span table + interner
  csr.zig           generic CSR builder (counting sort)
  netlist/
    source.zig      .include / .lib expansion into one arena, via a caller Loader
    token.zig       zero-copy tokenizer (spans, not Strings)
    card.zig        SPICE card classification
    expr.zig        .param scope + {expr} evaluation
    flatten.zig     .subckt hierarchy flattening
  ir.zig            SoA schematic: devices / pins / nets / groups
  devices/
    catalog.zig     comptime class tables (builtin)
    host.zig        runtime-registered classes
  config.zig        lint.zon knobs, parsed with std.zon.parse
  lint.zig          the rule table and the one-shot `check` (docs/LINT.md)
  place/
    ctx.zig         Tier-A precompute (CSR, net class, conducting pins)
    spline.zig      spline extraction (ground-distance walk)
    column.zig      column assignment + kinds
    order.zig       two-phase order search
    stack.zig       y-stacking, row profiles, alignment, x-placement
    orient.zig      device orientation
  route/
    lattice.zig     Hanan grid construction, blocking, occupancy
    dijkstra.zig    direction-aware search, and the six cost constants
    tree.zig        multi-terminal tree growth, label fallback
  metric.zig        selection key measurement, junction dots
  geom.zig          symbol transform, bounds, refdes anchors, group frames
  json.zig          structured data export
  latex.zig         TikZ emitter, compiled only under -Dlatex_renderer
  abi.zig           C ABI (zero-copy over the IR)
  json_main.zig     cktimg-json front end (also owns the target-manifest parser)
  tex_main.zig      cktimg-tex front end (gated with latex.zig)

examples/
  self-hosted/src/  svg.zig, gallery.zig, main.zig   — the dev gallery
  latex/figure.tex                                   — a worked \cktimg document

targets/            *.json target manifests — data, not code (docs/TARGETS.md)
latex/cktimg.sty    the LaTeX package
tools/bench.zig     per-fixture timing
```

There is no `render/` directory. The transform math every drawing needs lives in
`geom.zig`, which is library surface for the reason below.

### Format emitters are not library surface

The library's product is **geometry**: placed symbols, routed polylines, junctions,
labels, plus the transform and collision helpers in `geom.zig` needed to draw them. The
SVG emitter lives under `examples/self-hosted/src/svg.zig`, built on the same public API
and C ABI a third-party consumer gets.

This is a correctness property rather than tidiness. The bundled gallery renderer has
no privileged access to internals, so if it can draw a schematic then an external
adapter can too — the C ABI is exercised by our own primary consumer on every build.
Promoting an emitter into the library would let the two paths diverge silently, and
the first symptom would be a bug report from someone whose adapter cannot reproduce
our gallery.

What *does* stay in the library is anything an emitter cannot correctly recompute on
its own: the mirror-then-rotate transform order (`ids.Orient.apply` is the only place it
is written), body extents, refdes anchor collision avoidance, group frame boxes, and JSON
export. Those are answers, not formats — duplicating them per emitter is how two
renderers of the same schematic start disagreeing.

`src/latex.zig` is the one emitter inside the library, and it is a deliberate exception
rather than a leak: a paper figure is something a *user* asks for, so it should come from
the library they already link against instead of a sample they vendor and maintain. It is
gated on `-Dlatex_renderer`, and when the option is off `root.latex` is `void` — a stale
reference is then a compile error naming the missing option rather than a link failure.

### Target manifests are data the library does not load

`targets/*.json` maps a cktImg device class onto one backend's native symbol name and pin
order. `cktimg-json --target <manifest>` reads it; `libcktimg` does not, and the manifest
parser lives in `src/json_main.zig` rather than in the library at all.

A loader inside the library would buy the caller exactly one `std.json` call they can
write themselves, and charge for it three times: **retention** (we would hold a mapping
table the caller already owns), **coupling** (their symbol library reachable only through
our file format and our file I/O), and **flow control** (our idea of when a file gets
read). The class names and terminal names are already library surface, through
`cktimg_device_class` and `cktimg_pin_term` — a manifest is a convenience over that
vocabulary, not a way into it.

`src/netlist/source.zig` makes the identical call one layer down. `.include` expansion
needs file contents, and rather than reaching for `std.fs` it takes a caller-supplied
`Loader` — a `ctx` pointer plus a `readFn`, two real implementations (a filesystem and
the tests' in-memory map). There is no `Source.load`; the vtable is the only door, which
is what lets the whole front end be tested with no filesystem and lets a host serve
includes from a database if it wants to.

See [docs/TARGETS.md](TARGETS.md) for the normative schema and the validation rules.

## 3. Lifetimes decide the allocators

Five lifetimes, five allocators. The obvious alternative — one general-purpose allocator
for everything — pays malloc and free for the lattice, the occupancy arrays and every
route polyline once per candidate order, which is up to `refine` times per drawing.

| Lifetime | Allocator | Holds |
|---|---|---|
| program | comptime / `static` | builtin device catalog, cost constants |
| document | `doc: ArenaAllocator` | source bytes, string pool, IR, per-document class table |
| per candidate order | `search: ArenaAllocator`, **reset each order** | column assignment, y/x offsets, lattice arrays, route polylines |
| whole run, reused | `scratch: Scratch` | Dijkstra `dist`/`dist_gen`/`prev`/heap, sized to the largest lattice |
| result | `out: ArenaAllocator` | winning `Physical`, rendered bytes |

`Config` is *not* in this table: it is a borrowed `*const Config` field on the pipeline,
owned by whoever built it. That is the same "threaded, not global" decision as §9.

The search arena is the point. Phase B evaluates up to `refine` (default 16) orders; each
builds a lattice, routes every net, measures, and throws it all away.
`arena.reset(.retain_capacity)` between orders means the second order onward allocates zero
pages.

Scratch is separate from search because Dijkstra buffers must survive an arena reset —
they are sized once (to `nodes * 2` slots) and reused across every net of every order.
`Scratch.ensure` is monotonic: it grows and never shrinks, because the next candidate
order is usually about as large as the last.

### The public API, coarse to fine

`src/root.zig`'s file header carries the tier table; it is the normative one and this
section does not restate it. Structurally:

- `place(gpa, cfg, src) -> struct { Placed, Report }` builds a pipeline, runs it, copies
  the result out, tears the pipeline down. The caller owns what comes back.
- `Pipeline.init(gpa, cfg)` + `run(src)` gives borrowed views into the pipeline's own
  arenas, plus `reset` between documents, `rerun` and `patch` for incremental layout.
- `Pipeline.initIn(mem: Memory, cfg)` + `parse(src) -> Parsed` + `layout(parsed, carry)`
  is the same machinery with nothing chosen for you. `Memory` is the five lifetimes as a
  struct; `take()` moves them back out.

`init`/`run`/`rerun`/`patch` are thin wrappers: `init` is `initIn(.init(gpa), cfg)`, and
`run` is literally `parse` then `layout(doc, .{})`. `rerun` and `patch` differ from `run`
only in the `Carry` they pass. One code path, not four.

`Memory` is a struct rather than five positional parameters because `doc` and `search`
have opposite lifetimes and transposing them is undiagnosable.

**What `initIn` does not buy.** It is not what makes repeat use allocation-free —
`init` + `run` + `reset` already does that, because `reset` is `.retain_capacity` on all
three arenas and `scratch` is untouched by it. What the fine-grained form actually buys is
narrower and worth stating exactly:

1. **Which allocator backs which lifetime.** A host with a page pool, a fixed buffer, or
   arenas recycled out of another pipeline's `take()` supplies them instead of letting the
   pipeline construct memory it knows nothing about.
2. **Pre-sizing `scratch`.** `Memory.scratch` defaults to `.empty`; calling
   `Scratch.ensure` on it before `initIn` sizes the Dijkstra buffers to the caller's
   worst-case lattice, so run *one* does not allocate them either.

Separating `parse` from `layout` buys something different again: lint or browse an IR that
was never placed, lay one `Parsed` out twice under two configs (both results stay valid —
each winner is allocated from `out`, and `out` is only released by `reset`), or run the two
halves on different threads.

## 4. The IR

```zig
pub const DeviceIdx = enum(u32) { none = maxInt(u32), _ };
pub const PinIdx    = enum(u32) { none = maxInt(u32), _ };
pub const SymbolIdx = enum(u32) { _ };
pub const StrId     = enum(u32) { _ };
pub const NetIdx    = enum(u32) { none = 0, _ };  // 1-based; 0 is "floating"
```

A sentinel rather than `?NetIdx`. Zig does **not** niche-optimize an optional over a
non-exhaustive enum, so `?NetIdx` is 8 bytes; a sentinel keeps the pin→net column at
4 bytes per pin, which is the hottest column in the program. `NetIdx` reserves 0 and is
therefore 1-based (`NetIdx.i()` subtracts); the index spaces with no natural zero reserve
`maxInt(u32)` instead.

```zig
pub const Ir = struct {
    // --- hot columns: read by every place-and-route pass ---
    dev_symbol: []SymbolIdx,
    dev_orient: []Orient,      // packed struct(u8): rot: u2, mirror: bool, _pad: u5
    dev_pin0:   []u32,         // CSR offsets, len = n_dev + 1
    pin_net:    []NetIdx,      // the hot column

    // --- cold columns: read once, at render ---
    dev_name:   []StrId,
    dev_value:  []StrId,
    net_name:   []StrId,

    // --- hierarchy record, annotation only ---
    group_path:   []StrId,
    group_master: []StrId,
};
```

The hot/cold split is explicit in the declaration order, and it is the whole reason these
are columns rather than fields of a device struct: `dev_name`, `dev_value` and `group_*`
are touched once at render and never during place-and-route, so a P&R pass never pulls a
name into cache.

Placement results are their own SoA block with nested CSR (net → segment → point), built
directly into the `out` arena:

```zig
pub const Physical = struct {
    pos:       []Pt,     // by DeviceIdx
    pin_xy:    []Pt,     // by PinIdx, parallel to Ir.pin_net
    net_seg:   []u32,    // CSR: NetIdx -> segments
    seg_pt:    []u32,    // CSR: segment -> points
    wire_pts:  []Pt,
    junctions: []Pt,
    labels:    []Label,
};
```

`Pt` is `struct { x: i32, y: i32 }`. The grid is integer throughout — no floats anywhere in
place-and-route, so every geometric comparison is exact and the output is byte-reproducible
by construction rather than by epsilon discipline. The single deliberate `f64` in the
program is `expr.Binding.value`, because a SPICE `.param` spans femto to tera; it never
reaches geometry.

### Adjacency is CSR, always

`csr.zig` exposes one generic builder used for every many-to-many relation:

```zig
pub fn Csr(comptime Key: type, comptime Val: type) type { ... }
// build: counting pass -> prefix sum -> placement pass. Two passes, no per-key list.
// slice(key) -> []const Val
```

Relations built with it: net→pins (`Ir.netPins`, `ctx.Ctx.net_pins`), device→conducting
pins (`ctx.Ctx.cond`), spline→devices (`ctx.SplineSet`), device→splines
(`order.Ranker.dev_spline`), column→devices, net-info→columns and →pins, track→lane x. The
alternatives are a `[][]T` — one heap allocation and a 16-byte header per key, scattered —
or a map keyed on a heap-allocated composite, which additionally cannot be iterated
reproducibly (§7). Both collapse to one offsets array plus one values array. A lookup
returns a slice and allocates nothing. `Physical.net_seg`/`seg_pt` is the same shape open-
coded, because it is two *nested* levels and is built by the router rather than from
counts.

## 5. Netlist front end: spans, not strings

The obvious tokenizer allocates a `String` per token, lowercases each one, and keeps only
a line number for diagnostics. It is the most allocation-heavy layer a front end can have,
and it throws away the position information errors actually need.

1. **One source arena.** Every file — the root plus every `.include` / `.lib` expansion —
   is appended into one growing byte arena, and the result is handed out as a stable
   slice, because every stage after this holds `(off, len)` pairs into it. The side table
   is `Segment { start: u32, name: StrId, line0: u32 }`, **one entry per contiguous run,
   not per file**: splicing `b.sp` into the middle of `a.sp` means `a.sp` contributes bytes
   both before and after it, so a file owns a set of disjoint ranges. `locate` binary-
   searches the segments and counts newlines from the segment start — O(segment length),
   paid once per diagnostic somebody actually formats, never in the parse loop. `line0`
   is what makes a reported line match what the user sees in their editor.

2. **Tokens are spans.** `MultiArrayList(Token)` with columns `{ off: u32, len: u32, kind }`.
   No allocation per token, and no lowercasing pass — **case folding happens once, at
   intern time** (`Interner.internFold`), since the only consumer that cares about
   case-insensitivity is name lookup. `text()` therefore returns the identifier as
   written. `Kind` is an `enum(u8)`, not a bitfield: the categories are mutually exclusive
   and a flag set would admit `word`-and-`number`-at-once, which no producer emits and
   every consumer would have to decide about. Same one byte, fewer impossible states. There
   is no `continuation` kind either — continuations are folded into their statement and the
   leading `+` disappears, with `Line.off`/`Line.len` recording the folded extent.

3. **Errors carry spans.** `ir.Note` is `{ off: u32, len: u32, reason: Reason }` where
   `Reason` is an `enum(u32)`. 12 bytes, no allocation. Message text is a `switch` over
   `Reason` produced only when someone formats the report; storing reassembled line text
   per ignored card is pure waste in the common case where nobody reads it. `Reason`'s
   declaration order is itself the by-design/limitation split (`Reason.isByDesign`).

4. **Param scope is a stack, not a cloned map.** `.subckt` nesting becomes a single
   `MultiArrayList(Binding){ name: StrId, value: f64 }` plus a `[max_depth]u32` of frame
   boundaries, `max_depth = 64` matching flatten's own cap. Push records the current
   length; pop truncates back to it — nothing copied, nothing allocated per frame. Lookup
   scans backwards, so the innermost shadow wins without consulting the frame table at all;
   the frame table exists only to make pop O(1). At these sizes that beats a
   `HashMap<String, f64>` cloned per instantiation on both allocation and cache behavior.

5. **Interned strings are NUL-terminated.** The interner appends a `0` after every string;
   the span length excludes it. Costs one byte per distinct name and lets `Strings.getZ`
   hand C a `[*:0]const u8` straight out of the pool with **no copy** — see §9.

## 6. Router: flat arrays, reused search state

The lattice is a Hanan grid: `xs: []i32` and `ys: []i32` (sorted, deduped, drawn from pin
coordinates, column axes, lane axes, body edges, bus rows and margin rows). Node index is
`iy * nx + ix`. Everything below is one flat allocation out of the `search` arena, and a
`Lattice` has **no `deinit`** — it dies with the next `search.reset(.retain_capacity)`,
along with the columns, the offsets and the candidate's polylines.

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

The alternative is a per-edge *list* of blocking device ids — a 16-byte header and a
separate allocation per blocked edge. One `u32` replaces it: an edge blocked by two bodies
is still blocked, and the only question ever asked of a blocker is whether it is the device
whose buried pin licenses this cut. The approximation loses exactly one case, an edge
blocked by A *and* B where the route owns a pin in A, which requires two symbols to
overlap; placement does not produce that, but it is a claim about the fixture set and is
checked there. If a fixture ever needs it, the column widens to a `u64` pair *before* it
goes back to being a list. `node_net` needs no such caveat and is exact: a node owned by
net A is closed to every other net, so one slot can never lose information.

### Search state, reused

```zig
dist:     []u32,   // len = nodes * 2  (direction-aware: last move H or V)
dist_gen: []u32,   // generation stamp, same length
prev:     []u32,
heap:     []HeapEntry,   // 4-ary heap, reused
```

Two decisions:

- **Generation stamping instead of clearing.** Each net's search bumps a counter; `dist[i]`
  is live only if `dist_gen[i] == gen`. Clearing instead costs a full `memset` of
  `nodes * 2 * 4` bytes per net per candidate — 1.6 MB for a 200k-node lattice, multiplied
  by every net and every order. Here it costs one integer increment, with the O(n) clear
  reached once per four billion searches when `gen` wraps.
- **4-ary heap in a reused buffer**, not a fresh allocation per call; sift-down dominates
  and a wider fan-out shortens the tree. Weights are small integers (1 / 10 / 80 / 900 /
  3000), so a bucket queue (Dial's) would be O(1) per operation — but bucket count scales
  with the largest single-edge increment, which needs a sizing analysis nothing has asked
  for yet. `// ponytail: 4-ary heap; swap to a bucket queue if profiling puts the heap in the top three.`

### Costs are comptime constants

```zig
// src/route/dijkstra.zig
pub const W = struct {
    pub const base:   u32 = 10;
    pub const bus:    u32 = 1;
    pub const off:    u32 = 80;
    pub const margin: u32 = 80;
    pub const bend:   u32 = 900;
    pub const cross:  u32 = 3000;
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

1. **Never iterate a hash map.** Series-device grouping and shared-device anchors both
   want a map keyed on something composite; both are instead a sorted key array with a
   binary search, or a CSR built by counting sort. `place/column.zig` goes further and
   keys columns by `(anchor, rank)` so an insertion never renumbers anything. A hash map
   may be used for *membership* (interner dedup) but never as an iteration source.
2. **Integers only.** No float in place-and-route; every tie breaks on integer comparison.
3. **The selection key is a struct with a total order**, compared field by field:

```zig
pub const Key = struct {
    labels: u32, pin_hits: u32, geom_shorts: u32, body_hits: u32, overlaps: u32,
    crossings: u32, staples: u32, total_span: u32, forward_margin: u32,
    margin_tracks: u32, netid_seq: u64,
    pub fn order(a: Key, b: Key) std.math.Order { ... }  // inline for over the fields
};
```

Never a weighted sum. `order` is an `inline for` over `@typeInfo(Key).@"struct".fields`,
so the declaration order *is* the priority order, literally rather than by convention —
reordering the struct reorders the priorities and nothing else moves, which is the intent.
`netid_seq` is an FNV-1a fold over the ascending, deduplicated net ids: the final
tie-break between two candidates that were equal on everything measured.

`pin_hits` and `geom_shorts` are counted only when `rules.symbol_geometry == .err`, and
are zero otherwise. That is the one place a lint severity reaches into placement, and it is
why `err` is not the default — see [docs/LINT.md](LINT.md).

## 8. Order search allocates nothing

Phase A streams every column order (and every free intra-spine swap) through a cheap proxy
and keeps the best `refine`:

```zig
pub const Proxy = struct { span: u32 = 0, backward: u32 = 0 };
var shortlist: [max_refine]Candidate = undefined;   // fixed, on the stack
var perm: [max_splines]u8 = undefined;              // Heap's algorithm, in place
```

`Proxy` has two fields and there is no third — a crossing term was measured and rejected;
`order.zig`'s header carries that argument and a test asserts the struct's shape so adding
one is a deliberate act. `Candidate` is fixed-size and trivially copyable (`order` is a
`[max_splines]u8`, not a slice, because a slice would point into the permutation buffer the
next iteration overwrites), which is what lets the shortlist be a stack array.

Permutation generation is Heap's algorithm over a stack array; the top-K is insertion into
a fixed array. Zero heap allocation in a loop that may run 10! times. Phase B then
evaluates only the survivors, each after a `search` arena reset — and the winner is
*re-evaluated* rather than copied out, because its arrays died with the next candidate's
reset. Evaluation is deterministic, so that is a copy in every sense but the mechanism,
and it costs one candidate's work instead of an `out` arena sized to the whole shortlist.

`enum_limit` (default 10) and `refine` (default 16) are `Config` fields — they are resource
bounds, not opinions. `max_splines = 16`, `max_refine = 64` and `max_swaps = 8` are the
buffer ceilings those knobs are clamped to; a deck past `max_splines` has its tail
truncated out of the search rather than failing. The factorial enumeration is the known gap
`ALGORITHM.md` names, and `enum_limit` is the guard, not the fix.

## 9. Emitters and the C ABI

**Emitters take a writer.** `json.write(placed, cfg, w: *std.Io.Writer)`,
`svg.write(placed, cfg, w)`, `latex.write(gpa, placed, table, cfg, w)` — one buffered
writer instead of building a `String` and `writeln!`-ing into it per element. A caller
wanting a string passes an `std.Io.Writer.Allocating`; a caller writing a file passes the
file. No `Backend` trait or vtable: they are separate functions, and what is shared is
`geom.zig` — the transform, bounds accumulation, refdes anchoring and group boxes. Share
the geometry, not an interface with three implementations.

**The C ABI is a view, not a copy.** The alternative is rebuilding the entire schematic as
a parallel structure of C strings and nested arrays — roughly a thousand lines and a full
duplicate in memory, with two representations to keep in sync. Because interned strings are
NUL-terminated (§5) and `Physical` is already CSR, the handle wraps the `Placed` directly:

```zig
pub const Sch = struct { placed: Placed, arena: ArenaAllocator, ... };

pub export fn cktimg_device_name(sch: ?*const Sch, d: usize) ?[*:0]const u8;
pub export fn cktimg_wire_segment_points(sch: ?*const Sch, w: usize, s: usize,
                                         xy: ?*?[*]const i32) usize;  // zero-copy
```

`Sch` adds exactly three things to the `Placed` it wraps: the arena that owns a parsed
handle's memory, the pre-formatted report text, and a lazily-built refdes anchor cache —
the last because anchor placement is *sequential* (label 7 dodges labels 0..6), so there is
no per-device pure function and recomputing per accessor would be O(devices² × obstacles)
across one render.

Ownership rules stay exactly as `include/cktimg.h` documents them: strings and point arrays
are **borrowed** from the handle and valid until `cktimg_sch_free`; only `cktimg_run_json`
and friends are caller-owned, released with `cktimg_string_free`. Null handles and
out-of-range indices return null/0/false rather than trapping — that is a trust boundary
and stays fully checked.

`abi` is force-referenced from `root.zig` in a `comptime { _ = abi; }` block. No Zig caller
reaches it, so without that line semantic analysis never reaches the `export fn`s and the
entire C surface is absent from `libcktimg.a`.

**Config is threaded, not global.** No process-wide singleton and no lazy initialization:
`*const Config` is a field on the pipeline. One extra parameter through `place/` and the
emitters; in exchange, tests vary knobs without process-global state and two schematics can
be placed concurrently on two threads. `lint.Rules` travels the same way, as a value inside
`Config`, for the same reason.
