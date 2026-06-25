# `cktimg` — the Rust library

SPICE/netlist text in, schematic out. The pipeline is `parse → place → render`,
and the render step is **pluggable**: a backend is just a function
`Fn(&Ir, &Strings) -> String`. SVG is the default; write your own to dump
xschem `.sch`, KiCad, JSON, or anything else.

## Install

From crates.io (once published):

```toml
[dependencies]
cktimg = "0.1"
```

Or against this repo:

```toml
[dependencies]
cktimg = { git = "https://github.com/<you>/cktImg", package = "cktimg" }
```

CI builds an optimized `.crate` on every push (see `.github/workflows/library.yaml`)
— grab it from the run's **Artifacts** if you want to vendor it.

## Use

```rust
// SPICE text → SVG string + a parse report (ignored/skipped lines).
let (svg, report) = cktimg::run(spice, cktimg::backend::svg);
if !report.is_clean() {
    eprintln!("{}", report.summary());
}
std::fs::write("ota.svg", svg).unwrap();
```

Built-in backends, both `fn(&Ir, &Strings) -> String`:

| Backend | Output |
|---|---|
| `cktimg::backend::svg` | SVG document |
| `cktimg::backend::tikz` | Native TikZ/PGF (`pdflatex` draws it — no converter) |
| `cktimg::backend::json` | Resolved schematic as JSON (names + coords + wires) |

## Bring your own backend

A backend is any function with the right shape. Want xschem? Write it:

```rust
fn xschem(ir: &cktimg::Ir, s: &cktimg::Strings) -> String {
    let mut out = String::from("v {xschem version=3.4.5}\n");
    // walk ir.devices / ir.physical, resolve names via `s.get(id)`, emit `C {...}` lines
    out
}

let (sch, _) = cktimg::run(spice, xschem);
```

`run` calls your closure with the **placed** IR (`ir.physical` is `Some`) and the
string pool. Everything the SVG renderer sees, you see.

## What's in the IR

The JSON backend is the easiest map of what's available — devices (name, class,
value, rotation/mirror, position), their pins (terminal name, net, xy), the net
list, the routed `wires` (trunk + stub polylines per net), and junction dots. The
raw types live in the re-exported `cktimg::ir` crate (`devices`, `pins`, `nets`,
`physical`); the JSON view is a denormalized, resolved projection of them.

## Re-exports

`cktimg` re-exports `netlist`, `ir`, `devices`, `build`, and `svg` so you can
drop to a lower level (custom parse, inspect `Schematic<Placed>`, etc.) without
adding more dependencies.
