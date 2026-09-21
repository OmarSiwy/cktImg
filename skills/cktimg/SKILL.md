---
name: cktimg
description: Draw a SPICE netlist as a schematic with cktImg. Use when the user has a .spice/.cir/.net netlist to lay out, render or lint; writes or debugs a lint.zon; authors a target manifest for xschem, schemify or a web renderer; or links libcktimg through its C ABI or Zig API.
---

cktImg places and routes an analog netlist. Its product is **geometry** — placed symbols, routed polylines, junction dots, labels — and it ships no SVG emitter. Anything that draws pixels is either a bundled front end or code you write against that geometry.

Layout convention: VDD at the top, GND at the bottom, signal left to right.

## Pick a tier

Each tier is the one below it with the choices already made. No tier requires the one above it, so **start at tier 0 and step down only when it cannot answer the question**.

| Tier | Reach for it when | You call |
|---|---|---|
| 0 | You want a file — JSON geometry or a LaTeX figure | `cktimg-json`, `cktimg-tex` |
| 1 | Your program draws its own output, in its own format | `libcktimg.a` + `include/cktimg.h` |
| 2 | You place many schematics, or want the parsed netlist without paying for layout | the Zig module |

Tier 0 covers most work and needs no build step against the library. A backend for a schematic editor is tier 0 plus a target manifest — the mapping from cktImg's class names to that editor's symbols is **data you write**, not code you link. See `reference/targets.md`.

## Every tier reads lint.zon

The config file is **ZON** (`std.zon.parse`), not TOML and not JSON, and the name is `lint.zon` by convention only.

**There is no search path.** Both CLIs take `--config <path>`; run without it and you get built-in defaults no matter what sits in the working directory. A `lint.zon` that appears to be ignored is almost always a missing `--config`.

An unrecognized key is **reported, not fatal** — that key keeps its default and the rest of the file loads, so a config written for a newer version still works. `.layout.strict_geometry` is a retired key: it is now `.rules.symbol_geometry`, and a file still using the old spelling loads with a diagnostic naming it.

The router's cost weights are deliberately **not** configurable. They are compile-time constants because they encode what a schematic *means* rather than how far apart things sit; retuning them yields a differently-*reasoned* drawing, not a differently-spaced one. Spacing is what `.layout` is for.

Every key, default and unit: `reference/lint-zon.md`. Read it before writing or editing a `lint.zon`.

## Linting

`--lint` on either CLI runs the rule table from the same `--config` file — there is no second configuration channel.

| Exit | Meaning |
|---|---|
| 0 | Output written; no finding at `err` severity |
| 1 | Bad command line, netlist, config or manifest. Nothing written |
| 2 | At least one `err` finding. **Output still written in full** |

2 is separate from 1 so a CI job can tell "this schematic is wrong" from "the tool could not run". `warn` findings are reported and never fail. Rules, defaults and severities: `reference/lint-zon.md`.

## The output is byte-reproducible

Integer grid throughout, no floating point in place-and-route, and no hash map is ever iterated. The same netlist under the same config produces the same bytes on any machine. Diff the output directly in CI; it needs no tolerance and no normalisation pass.

## Geometry conventions

Integer coordinates, y increasing **downward**. A symbol's origin is its centre. Every device class is exactly 40 units wide so columns pitch uniformly, while height varies. A multi-terminal class puts its two principal terminals on the conduction axis at (-20, 0) and (+20, 0); auxiliary terminals sit off that axis.

## Reference

- `reference/lint-zon.md` — the config file in full: four tables, every key, the rule severities
- `reference/targets.md` — writing a target manifest for a backend
- `reference/c-abi.md` — tier 1, and the ownership rule that matters
- `reference/zig-api.md` — tier 2, and the allocator model

In a checkout of cktImg itself, `docs/LINT.md`, `docs/TARGETS.md` and `docs/ARCHITECTURE.md` are the normative sources and go deeper on *why* each default is what it is.

## Before handing over a config or a manifest

Run it. Both failure modes here are silent: a mistyped config key leaves a default in place while looking applied, and a wrong pin order in a manifest miswires a schematic that still renders.

- A `lint.zon` is done when `cktimg-json --config <file> <deck> >/dev/null` reports **zero** `unrecognized key` diagnostics — every key you wrote resolved.
- A target manifest is done when `cktimg-json --target <file> <deck>` exits 0; the validator rejects any class not in the catalog and any pin list that is not a permutation of that class's terminals.
- A claim about a flag or an exit code is done when `--help` from the installed binary agrees with it. The table above was written against the flags in this repo; the binary in front of you is the authority.
