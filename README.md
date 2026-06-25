# cktImg

Place-and-route engine that turns an analog circuit netlist into a readable schematic SVG (or the choice of your backend).
The layout follows the **spline-column model** of the project paper: extract every VDD→GND
conduction path (a _spline_), assign one column per spline, lift shared devices into their own
middle columns, then route nets by how far they span.

```
crates/
  svg-read   input  — parse SVG back to IR (optional)
  ir         core   — the intermediate representation (no layout, no constraints)
  devices    core   — device classes & symbol data
  build      core   — extract splines → assign columns → place → route
  svg        output — render placed IR to SVG
```

## Quick start

```sh
cargo visualize          # render all 18 circuits, refresh the gallery, open it in a browser
cargo test               # placement/routing invariants
```

`cargo visualize` regenerates `gallery/*.svg` + `gallery/manifest.json` and serves the gallery
on `http://localhost:8731/` (Ctrl-C to stop).

## The test suite is exhaustive over what the placer can see

The placer never sees "a differential pair" or "a Miller op-amp" — it sees only structure, and
its structural vocabulary is small and closed. Every device lands in one of **three column
kinds**, and every net falls into one of **three routing cases**:

| Column kind (`extract.rs`)            | Net case (`classify`)                  |
| ------------------------------------- | -------------------------------------- |
| `Spline` — on one VDD→GND path        | `WithinSpline` — one column            |
| `Shared` — on ≥2 paths (fan node)     | `ImmediateNeighbor` — adjacent columns |
| `SignalSeries` — on no path (Break C) | `SpanGe2` — jumps ≥2 columns           |

Everything the engine must get right is a combination of those six primitives. So the suite is
organised as **five families** (`circuits.rs`, groups A–E), each pinning down one axis of that
space — not a grab-bag of famous circuits, but minimal representatives chosen so that every
column kind and every net case appears and is stressed:

- **A · single spline** — one column. The only nets are `WithinSpline`/`ImmediateNeighbor`.
  Varies _what fills the column_: passive load, active (current-source) load, a stacked cascode,
  a series passive. _(diode-connected, common-source, CS+isource load, cascode, source-degenerated)_
- **B · two splines / cross-coupled** — two parallel columns whose gates reference each other.
  Introduces inter-column nets and gate feedback. _(current mirror, cascode mirror, Wilson, cross-coupled pair)_
- **C · shared / branching** — a device sits on ≥2 splines, forcing a `Shared` middle column
  (the tail/fan node placed _between_ its branches, not collapsed into a chain).
  _(differential pair, tail current source = one drain feeding N, 5T OTA, push-pull)_
- **D · multi-stage / feedback** — cascaded splines bridged by compensation caps that span ≥2
  columns: this is the `SpanGe2` case, the hardest to route. _(two-stage Miller, gain-boosted
  cascode, nested Miller, stacked bias string)_
- **E · splineless** — no VDD→GND path at all, so _only_ `SignalSeries` columns exist (Break C).
  _(transmission gate)_

A → E walk the column count up from one, then add sharing, then add long-span feedback, then
remove the rail entirely. There is no fourth column kind and no fourth net case for a 19th
family to exercise — which is the sense in which the eighteen are exhaustive: they cover the
placer's full structural alphabet, and each family is the smallest circuit that does so for its
axis.

## Examples

One representative per family — together they exercise all three column kinds and all three net
cases:

|                                                                                                        |                                                                                                        |
| ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| **A · single spline** (`cascode`)<br><img src="gallery/cascode.svg" width="320">                       | **B · cross-coupled** (`cross_coupled_pair`)<br><img src="gallery/cross_coupled_pair.svg" width="320"> |
| **C · shared fan node** (`differential_pair`)<br><img src="gallery/differential_pair.svg" width="320"> | **D · feedback bridge** (`two_stage_miller`)<br><img src="gallery/two_stage_miller.svg" width="320">   |
| **E · splineless** (`transmission_gate`)<br><img src="gallery/transmission_gate.svg" width="320">      | Run `cargo visualize` for all eighteen.                                                                |
