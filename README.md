# cktImg

Place-and-route engine that turns an analog circuit netlist into a readable schematic SVG (or the choice of your backend).
The layout follows the **spline-column model** of the project paper: extract every VDD→GND
conduction path (a _spine_), assign one column per spine, lift shared devices into their own
middle columns, then route nets by how far they span.

Applications:

- schematic linter with custom config
- netlist importer in schematic software (i.e. research paper -> xschem)

```
crates/
  netlist    input  — parse netlist (HSPICE, NGSpice, Spectre) to IR
  ir         core   — the intermediate representation (no layout, no constraints)
  devices    core   — device classes & symbol data
  config     core   — opinion-based knobs read from lint.toml (see docs/lint.md)
  build      core   — extract splines → assign columns → place → route
  svg        output — render placed IR to SVG
export/
  latex      — use CircuitTIKZ as the backend
  library    — Access point for creating your own backend
  python     — use this in python app
```

## Quick start

```sh
cargo visualize          # render all 18 circuits, refresh the gallery, open it in a browser
cargo test               # placement/routing invariants
```

`cargo visualize` regenerates `gallery/*.svg` + `gallery/manifest.json` and serves the gallery
on `http://localhost:8731/` (Ctrl-C to stop).

## Configuration

Spacing, search depth, and render style are **opinions**, not invariants — different teams draw
schematics differently. They live in a `lint.toml` read from the working directory at run time,
not in code. Drop one next to where you run the tool (a sample is in the repo root); every key is
optional and falls back to a built-in default. Override the path with `CKT_LINT=path/to.toml`.
Full key reference: [docs/lint.md](docs/lint.md).
