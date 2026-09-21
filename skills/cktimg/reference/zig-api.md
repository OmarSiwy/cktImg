# Tier 2 — the Zig API

```zig
const ckt = @import("cktimg");
```

Three granularities over one code path. The coarse forms are implemented in terms of the fine ones, so stepping down changes what you control, never what you get.

## Coarse: one call

```zig
var placed, var report = try ckt.place(gpa, &ckt.Config.default, src);
defer placed.deinit(gpa);
defer report.deinit(gpa);
```

You own the result. Right for a one-shot tool.

## Middle: a reusable pipeline

```zig
var p: ckt.Pipeline = .init(gpa, &cfg);
defer p.deinit();

for (decks) |src| {
    const placed, _ = try p.run(src);
    try render(placed);
    p.reset();   // results are borrowed from the pipeline and die here
}
```

Capacity accumulates on the first deck and is reused, so from the second onward this allocates nothing. `run` results are **borrowed** from the pipeline and are invalidated by `reset`.

`rerun` pins the previously winning column order; `patch` additionally transplants unchanged wires from a prior result. Both re-parse their input.

## Fine: your memory, your timing

```zig
var mem: ckt.Pipeline.Memory = .init(gpa);
try mem.scratch.ensure(gpa, 8192);        // pre-size so deck one is free too

var p: ckt.Pipeline = .initIn(mem, &cfg);
// ... place many decks ...
var back = p.take();                      // the arenas come back to you
back.deinit();
```

`initIn` buys two things `init` does not: choosing which allocator backs each lifetime, and pre-sizing `scratch` so the *first* deck allocates nothing either. Zero-allocation steady state is already true of `init` + `run` + `reset`.

### Splitting parse from layout

```zig
const doc = try p.parse(src);              // no placement, no routing
const placed = try p.layout(doc, .{});
```

`run` is exactly these two. Separating them lets you:

- **Lint or inspect a netlist without paying for layout.** `doc.ir` and `doc.report` are complete after `parse`; nothing has been placed and no lattice exists.
- **Lay one netlist out repeatedly** under different configs — assign `p.cfg` between `layout` calls. `cfg` is a borrowed field, so this is the knob.
- **Move the halves apart in time or across threads.** Give each thread its own `Pipeline`; config is a field precisely so there is no shared global.

`layout` takes a `Carry` naming what survives from a previous result — `.{}` for a fresh layout, `.{ .order = true }` to pin the winning order, `.{ .order = true, .wires = &prev }` to also transplant wires. These are what `rerun` and `patch` pass, and going through `layout` is how you get them **without re-parsing**.

## The five lifetimes

Allocation strategy is part of the public type, not an implementation detail.

| Lifetime | Field | Holds |
|---|---|---|
| program | static | builtin catalog, routing cost weights |
| document | `doc` | source bytes, string pool, IR |
| one candidate order | `search` | columns, offsets, lattice, route polylines |
| whole run, reused | `scratch` | Dijkstra distance/parent/heap buffers |
| result | `out` | the winning geometry |

`search` is the one that matters: the search evaluates up to `refine` candidate orders, each building a lattice, routing every net, measuring, and discarding all of it. Resetting that arena between candidates is why the second candidate onward allocates zero pages.

`scratch` is separate precisely because it must **survive** those resets — sized once to the largest lattice and reused for every net of every candidate.

## Linting

```zig
const findings = try ckt.lint.check(arena, placed, null, cfg.rules);
```

Immediate mode: it takes the data as parameters and returns findings. There is no rule registry to keep in sync and nothing to register. A rule set to `.off` does not run, so it costs nothing.

The third parameter is a `?*const host.Table` resolving symbol indices to classes — pass `null` for a builtin-only schematic, or your table if you registered classes at run time. Pass the `out` arena and the findings die with the drawing; pass a gpa and free the one slice. Calling it again with a different `Rules` gives an independent answer, because nothing is retained between calls.

## Config

`ckt.Config.default` borrows only static data and is safe to share across threads. `Config.parse` and `Config.load` take an arena that backs every string in the result, so the whole config dies in one call. `load` returns defaults for a missing file rather than failing — absence is the normal case, not a complaint.

See `lint-zon.md` for the keys.

## What stays library surface

`ckt.geom` answers what an emitter cannot correctly recompute on its own: the mirror-then-rotate transform order, body extents, refdes anchor collision avoidance, group frame boxes, and the dot radii that `obstacleRects` reserves room for. Share the geometry rather than reimplementing it — that is what keeps two renderers of one schematic from disagreeing.

Format emitters are deliberately **not** library surface, with one exception: the TikZ emitter, behind `-Dlatex_renderer=true`, because paper figures are something a user asks the library for. The SVG gallery under `examples/self-hosted/` is written against the same public API a third-party gets, so anything it can draw, your backend can draw.
