# `lint.toml` — opinion knobs

cktImg keeps load-bearing geometry (e.g. `devices::CELL_WIDTH`) as code constants, but the
choices that are *taste* — how far apart things sit, how hard the placer searches, what color a
wire is — live in `lint.toml`. This lets a team pin a house style without recompiling.

## Setup

1. Put a `lint.toml` in the directory you run cktImg from. Copy the sample from the repo root as
   a starting point.
2. Set only the keys you care about. Anything you omit uses the default below, so a file with a
   single line is valid.
3. To keep the file elsewhere, point the `CKT_LINT` environment variable at it:
   ```sh
   CKT_LINT=styles/compact.toml cargo visualize
   ```

If no file is found, every value falls back to its default and the run proceeds silently. A file
that fails to parse prints a warning and falls back to defaults. An **unknown key is an error**
(typo protection) — the loader rejects the file rather than ignoring the line.

## Keys

### `[layout]` — placement & routing

All values are integers on the placement grid.

| key          | default | effect |
| ------------ | ------- | ------ |
| `abut_gap`   | `8`     | Minimum vertical gap between stacked devices that abut (optimallen = 0). Larger = airier columns. |
| `tap_unit`   | `12`    | Extra vertical room added per fan-out tap. |
| `ch_base`    | `24`    | Base inter-column channel width; must clear a vertical device's gate stub. |
| `track_w`    | `8`     | Extra channel width added per wire crossing a gap. Raise it if dense channels look cramped. |
| `track_h`    | `10`    | Pitch between margin routing tracks. |
| `margin_gap` | `16`    | Clearance from the device field to the first margin track. |
| `bus_gap`    | `24`    | Clearance from the device field to the VDD/GND rail bus. |
| `enum_limit` | `7`     | Try **all** column orders when there are this many splines or fewer; beyond it, fall back to the deterministic id-sorted order. Cost is factorial (`7! = 5040`) — raise for better layouts on bigger circuits, lower to cap run time. |

### `[render]` — drawing style (shared by the svg and latex backends)

| key      | default    | effect |
| -------- | ---------- | ------ |
| `stroke` | `"black"`  | Device symbol color. CSS name or bare hex. (svg backend; latex symbols are always `black`.) |
| `wire`   | `"1565c0"` | Wire / pin-dot / junction color, **bare hex, no `#`**. svg prefixes `#`; latex uppercases it for `\definecolor`. |
| `sym_w`  | `1.2`      | Device symbol stroke width. |
| `wire_w` | `1.5`      | Wire stroke width. |
| `pad`    | `24`       | Padding around the schematic bounds (svg viewBox). |

## Example

A compact, high-contrast style:

```toml
[layout]
abut_gap   = 4
ch_base    = 16
enum_limit = 9   # search harder; slower on large circuits

[render]
wire   = "c62828"   # red
wire_w = 2.0
pad    = 12
```
