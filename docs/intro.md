# cktImg

Place-and-route engine that turns an analog circuit netlist into the output of
your choice. Layout follows the **spine-column model**: extract every VDD→GND
conduction path (a _spine_), assign one column per spine, lift shared devices
into their own middle columns, then route nets by how far they span.

See the [Gallery](GALLERY.md) for what the output looks like.

## Pick your output

| You want | Use | Docs |
|---|---|---|
| A TikZ figure in a paper | `cktimg-latex` | [LaTeX](LATEX.md) |
| Placed geometry as a Python dict | `cktimg` (PyPI-style module) | [Python](PYTHON.md) |
| JSON, or your own backend | `cktimg` (Rust crate) | [Rust library](LIBRARY.md) |

Rail nets (`vdd`/`vcc`, `gnd`/`vss`/`0`) get their rail devices auto-inserted —
feed it plain SPICE, nothing to pre-process.

## Quick start (repo)

```sh
cargo visualize   # render all test circuits, serve the gallery on :8731
cargo test        # placement/routing invariants
```

## Crate map

```
crates/
  netlist    parse netlist (HSPICE, NGSpice, Spectre) to IR
  ir         intermediate representation (no layout, no constraints)
  devices    device classes & symbol data
  config     opinion knobs read from lint.toml
  build      extract splines → assign columns → place → route
  svg        dev gallery renderer (SVG + local HTML viewer)
export/
  latex      native TikZ backend (pdflatex draws it, no converter)
  library    the facade: parse → place → render, bring-your-own backend
  python     pyo3 bindings (maturin)
```

## How it places

Straight to [Algorithm](ALGORITHM.md). Spacing, search depth, and render style
are opinions, not invariants — they live in [lint.toml](LINT.md), read from the
working directory at run time.
