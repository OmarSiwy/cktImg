# cktimg

Imports a SPICE netlist into Schemify schematics (D26, amended 2026-10-11). The layout is
[cktImg](https://github.com/OmarSiwy/cktImg)'s (`extern/cktimg`, a git submodule): supplies
at the top, grounds at the bottom, signal left to right, sources that drive a supply or an
input drawn apart on the left between their terminal symbols, and a net name wherever a
wire would cross the circuit. This plugin maps every device onto a `core` cell (or a
generated one), tells cktImg the pin geometry of those cells, and writes cktImg's placement
as Schemify records. Each `.subckt` becomes a `.shcomp`, a top level (devices, sources,
analyses, `.control` blocks) becomes a `.shbench`. The files netlist to the same circuit:
the tests check every fixture through `elab`, the netlister and `tools/spicecmp`.

![Two-stage op-amp, imported](../../docs/screenshots/cktimg/two_stage_opamp.png)

## Usage

Add the plugin to the project manifest and grant it file access:

```
plugin cktimg path plugins/cktimg
  grant read_project
  grant write_project
```

Then use **File ▸ Import SPICE netlist…** or `Ctrl+Shift+I`. A panel asks for a
project-relative path (`.sp`, `.cir` or `.spice`); press Enter to import. The command also takes
the path as its argument (`cktimg.import n2s/opamp.sp`).

The files are written next to the netlist: `<subckt>.shcomp` for each subckt, `<file>.shbench`
for the top level (`<file>_2` when a subckt has the same name), and the generated leaf cells
described below. The log reports cells, devices, wires, labels, how many nets are fully wired,
and every line it kept as code or changed.

| Capability | Why |
|---|---|
| `read_project` | read the netlist; check whether output names exist |
| `write_project` | write the new cells |

The plugin never overwrites. If any output cell already exists, nothing is written and the log
names the files in the way. Generated leaves (`spice_*.shprim`, stubs) that already exist are kept,
since earlier imports into the same directory share them.

## What becomes what

| SPICE | Schemify |
|---|---|
| `R C L V I E G F H S W T`, `M` with literal `w`/`l`, `D`/`Q` with `area=` | instance of `core:res`, `core:nmos4`, … (pins in SPICE order, values as overrides) |
| any other card, e.g. `D1 a k dmod` (the core diode always prints `area=`), `J`, `B`, behavioural `E`/`G`, 4-node `Q` | instance of a generated leaf `spice_<kind>.shprim` whose template `{name} {pins} {args}` re-emits the card verbatim |
| `X` of a subckt in the file | instance of `./<subckt>`; call parameters become overrides |
| `X` of an undefined subckt (PDK device, external DUT) | instance of a stub leaf named after it, `X…` card re-emitted |
| `.subckt` ports, params, in-body `.param` | `pin` + `port` records; `param` records (kind `string`), re-declared in the netlist by a `.param` line inside the definition; a repeated parameter keeps its later value |
| `.global` | labels with `global true` |
| top-level dot cards, `K`, `.control … .endc`, unsupported letters | the bench's `code netlist spice` block, verbatim |
| dot cards inside a subckt (`.model`, `.save`, …) | a `spice_code` instance inside the component, so they stay in its scope |

## How the layout is made

cktImg knows no devices; the plugin registers one class per symbol family (`res`, `nmos`,
`cvsource`, …, and `b<n>` for each generated box), with terminals at the Schemify pin
positions turned a quarter (cktImg's canonical frame has the principal pins on the x axis,
Schemify's cells are upright like xschem's). One pin-to-pin length is 60, so cktImg's
integer grid is xschem units and every wire ends exactly on a pin. Each cell is handed to
cktImg as a deck of its own: one card per device, under the cell's own net names, so
cktImg's name rules (`vdd*` up, `gnd`/`vss*` down, `in*` left, `out*` right) see what the
designer wrote. Back from cktImg:

- an instance's orientation is cktImg's composed with the family's quarter turn; every pin
  is asserted to land where cktImg put it;
- wires are its polylines, one segment per record, overlaps cut at every end;
- its net labels, supply/ground/port symbols and a MOSFET's bulk (drawn on the symbol,
  never wired) become `label` records, the first on a subckt port's net the `port`;
- its no-connect crosses become `noconn`; junction dots are left to Schemify.

Every net of two or more pins carries its name (on a wire it alone uses, else on a pin), as
do ports, globals and nets the code text mentions, so `.control` text that names `v(out)`
still works. Ids and bytes are deterministic, natively and in the wasm guest.

## Limits

- **Fuel.** cktImg's layout is heavy for an interpreter: about 10^8 wasmi fuel per
  millisecond of native layout time. Under the default budget of 10^8 per event, 69 of the
  80 fixtures import; larger ones (the `bus/*` decks, `sr_latch`, `phase_detector`) abort
  with `E_FUEL` and write nothing (`tests/guest.rs` lists them with their measured need, up
  to 4·10^10). A per-plugin fuel override (plugin ABI §2) or a faster cktImg
  (`docs/upstream/cktimg-performance.md`) lifts this.
- At most 200 element cards per import; cktImg draws at most 120 devices per cell and 400
  per import (native time and memory guards, measured in the same document). Bigger cells
  are drawn in rows with every pin labelled, which stays correct.
- The first line is not a title. Start a netlist with `*` or `.title`.
- `X` cards with no nodes are kept as code text and not drawn. `A`, `N`, `P`, `Y` (XSPICE
  and similar) and `K` cards are kept as code in the cell they appear in.
- Subckt parameters are `string` parameters. A literal `w`/`l` maps onto the core MOSFET;
  anything parametric goes through a `spice_*` leaf.
- A stray token on a `.subckt` line (`delay=200 ps`) is dropped with a warning.
- Node names containing `,`, `*` or `:` are renamed with `_`, since those characters mean
  bundle, repeat and range in a net expression.
- `cktimg.wasm` is ~630 KB (cktImg is ~290 KB of it, Zig's ZON parser ~110 KB that
  `docs/upstream/cktimg-optional-zon.patch` removes); `plugins/build.sh` allows it 700 KB.

## Build

`build.rs` compiles `extern/cktimg` with Zig 0.17 (`nix develop`; or set `ZIG`) for the
cargo target: `wasm32-freestanding` ReleaseSmall for the guest, the host ReleaseFast for the
native tests, everything inside `OUT_DIR`. Run `git submodule update --init` first. The
plugins workspace is separate from the root one, so the root build never needs Zig.

## Code

- `src/ffi.rs`: the safe wrapper over `include/cktimg.h`, one method per C function; the
  crate's only `unsafe`.
- `src/spice.rs` (parse), `src/recognize.rs` (core-cell mapping, overrides, generated
  symbols), `src/layout.rs` (class library, per-cell decks, cktImg's result as Schemify
  geometry), `src/emit.rs` (records, ids), `src/plugin.rs` (command, panel, I/O job).

## Tests

`cargo test --manifest-path plugins/Cargo.toml -p cktimg`:

- `tests/roundtrip.rs`: netlist → files → `doc` + `elab` + netlister → SPICE, compared with the
  input by `tools/spicecmp`, on the salvaged fixtures (`tests/fixtures/*/`), hand fixtures and,
  when `SCHEMIFY_CORPUS` points at a fetched `tests/corpus/.cache`, the xschem golden netlists
  (`--ignored`; `SCHEMIFY_CORPUS_FILTER` narrows them). It also checks that files load and
  round-trip, that no wires overlap, that every pin is wired or labelled, that output is
  deterministic and that mutated netlists never panic, and prints layout metrics.
- `tests/ffi.rs`: the wrapper against cktImg's invariants on its own symbol set (pins on their
  terminals, wire ends on their net, every net wired or named on every piece, same deck →
  same document, refusals as errors, mutated decks never panic).
- `tests/guest.rs`: the built `cktimg.wasm` (from `plugins/build.sh`) through the real host:
  contributions, the import flow, wasm output byte-identical to native, the fuel aborts,
  the no-overwrite refusal. `--ignored` prints the fuel report (`CKTIMG_FUEL_FILTER`).
