# lint.zon

Four tables, all optional, every key optional. Absent keys keep their defaults. An unrecognized key is reported and skipped; the rest of the file still loads.

Pass it with `--config <path>`. There is no search path.

```zon
.{
    .layout = .{ .abut_gap = 8, .track_w = 8, .grid = 1 },
    .render = .{ .stroke = "#2e7d32", .wire = "1565c0" },
    .pdk    = .{ .leaf = .{"sky130_fd_pr__*"}, .scan = true },
    .rules  = .{ .duplicate_refdes = .err, .no_ground = .off },
}
```

## .layout — spacing and search budget

Grid units. These change where things sit, never how the router reasons.

| Key | Default | Meaning |
|---|---|---|
| `abut_gap` | 8 | Minimum vertical gap between two abutting devices |
| `tap_unit` | 12 | Extra vertical room granted per fan-out tap on a node |
| `track_w` | 8 | Width of one wire track; a channel is a multiple of this |
| `track_h` | 10 | Vertical pitch between margin tracks |
| `margin_gap` | 16 | Device field to the first margin track |
| `bus_gap` | 24 | Device field to a VDD/GND bus row |
| `enum_limit` | 10 | Above this spline count, stop enumerating orders exhaustively |
| `refine` | 16 | How many candidate orders get fully placed, routed and measured |
| `grid` | 1 | Placement quantization; 1 means none |

`enum_limit` and `refine` are resource bounds, not aesthetics. Raising `refine` costs time and rarely changes the drawing — quality saturates early on real decks. Lower `enum_limit` if a wide circuit is slow.

`grid` is the knob a host with its own placement grid sets; everything snaps to a multiple of it.

## .render — styling

Consumed only by emitters; never reaches place-and-route.

| Key | Default | Meaning |
|---|---|---|
| `stroke` | `"black"` | Device symbol colour. Emitted verbatim, so any CSS colour works |
| `wire` | `"1565c0"` | Wire colour, **bare hex, no leading `#`** — the renderer prepends it |
| `sym_w` | 1.2 | Symbol stroke width |
| `wire_w` | 1.5 | Wire stroke width |
| `pad` | 24 | Padding around the content bounding box |

The two colour keys take different forms. `stroke` is passed through as written; `wire` is a bare hex triplet.

## .pdk — resolving subckt masters to symbols

How an unrecognized `.subckt` master becomes a drawable symbol.

| Key | Default | Meaning |
|---|---|---|
| `leaf` | `.{}` | Glob patterns naming masters to treat as primitives rather than flatten |
| `alias` | `.{}` | Explicit master-name to builtin-class pairs |
| `scan` | `true` | Scan an unresolved leaf name for a recognizable class token |
| `unknown_as_box` | `true` | Unresolved leaves become a generic box. When false they are dropped and reported as skipped |

`leaf` patterns support **one trailing `*`** and nothing else. A `*` anywhere other than the end makes the pattern literal, and that is reported at parse time — so a richer glob never silently matches approximately.

```zon
.pdk = .{
    .leaf  = .{ "sky130_fd_pr__*", "nfet_01v8" },
    .alias = .{ .{ "my_nfet", "nmos" }, .{ "my_pfet", "pmos" } },
}
```

Resolution order for a master: `alias` first, then `leaf`, then `scan`, then `unknown_as_box`. Set `unknown_as_box = false` while bringing up a PDK to make every unresolved master loud instead of drawing it as an anonymous box.

## .rules — the lint table

One severity per rule: `.off`, `.warn`, `.err`. An `.off` rule does not run at all, so it costs nothing. Only `.err` changes the exit code (to 2).

| Rule | Default | Fires when |
|---|---|---|
| `floating_pin` | `.warn` | A pin belongs to no net |
| `single_pin_net` | `.off` | A net has exactly one pin |
| `duplicate_refdes` | `.err` | Two devices share a reference designator |
| `unmapped_master` | `.warn` | A subckt master fell through to the generic box |
| `no_ground` | `.warn` | The deck contains no ground rail device |
| `symbol_geometry` | `.warn` | Two terminals of a class share an anchor, or the pin count disagrees with the class |
| `label_fallback` | `.off` | A net was dropped to a name tag instead of being routed |

Two defaults are deliberate and worth knowing before you change them:

**`single_pin_net` is `.off`** because these decks are routinely open fragments whose primary inputs and gate drives are legitimately one-pin nets. Turned on across a normal fixture set it fires on the majority of well-formed input. Turn it on for a closed, self-contained deck where a dangling net really is a mistake.

**`symbol_geometry` is `.warn`, and `.err` changes the drawing.** At `.err` the placer folds pin-collision and geometric-short counts into the selection key, so candidates that would collide lose outright. That is what a host with geometric connectivity wants — where a wire touching a pin *is* a connection — and it is a different layout, not just a different report.

### Not rules, on purpose

`bulk_unconnected` does not exist: the builtin MOSFET is three-terminal (`d`, `g`, `s`), so there is no bulk pin to check.

`wire_crossing` and `body_hit` do not exist as rules. Those counts are measured per candidate order during the search and discarded once a winner is chosen; recovering them afterwards would mean retaining measurement state on every placed schematic to serve a rule that is `.off` by default.

## Diagnostics

Every complaint carries a 1-based line number and the offending key. Unrecognized keys, unparsable values and malformed globs are all reported this way, and none of them stops the file from loading — a malformed value leaves that one key at its default.

This is the trade the format makes on purpose: failing to draw a schematic over a typo in a style file is the wrong outcome. It also means **a config that silently does nothing looks identical to one that worked**, which is why checking the diagnostics is part of finishing the job.
