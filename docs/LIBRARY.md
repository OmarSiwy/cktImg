# `cktimg` — the Rust library

SPICE/netlist text in, schematic out. The pipeline is `parse → place → render`,
and the render step is **pluggable**: a backend is just a function
`Fn(&Ir, &Strings) -> String`. JSON is built in; write your own to dump
xschem `.sch`, KiCad, SVG, or anything else.

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
// SPICE text → JSON string + a parse report (ignored/skipped lines).
let (json, report) = cktimg::run(spice, cktimg::backend::json);
if !report.is_clean() {
    eprintln!("{}", report.summary());
}
std::fs::write("ota.json", json).unwrap();
```

Built-in backend, `fn(&Ir, &Strings) -> String`:

| Backend | Output |
|---|---|
| `cktimg::backend::json` | Resolved schematic as JSON (names + coords + wires) |

- Rail nets (`vdd`/`vcc` power, `gnd`/`vss`/`0` ground) get their rail devices auto-inserted when the netlist names them but draws none — the placer anchors on rails, plain SPICE doesn't carry them.

For native TikZ/PGF output (`pdflatex` draws it — no converter), use the
`cktimg-latex` crate: `cktimg_latex::tikz(spice)`.

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
string pool. Everything the built-in backends see, you see.

## What's in the IR

The JSON backend is the easiest map of what's available — devices (name, class,
value, rotation/mirror, position), their pins (terminal name, net, xy), the net
list, the routed `wires` (trunk + stub polylines per net), and junction dots. The
raw types live in the re-exported `cktimg::ir` crate (`devices`, `pins`, `nets`,
`physical`); the JSON view is a denormalized, resolved projection of them.

## Re-exports

`cktimg` re-exports `netlist`, `ir`, `devices`, `config`, and `build` so you can
drop to a lower level (custom parse, inspect `Schematic<Placed>`, etc.) without
adding more dependencies.
