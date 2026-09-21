# Target manifests

A manifest maps cktImg's class vocabulary onto one backend's native symbols and pin order. It is JSON **data you write**, and `libcktimg` has no loader for it — the format is resolved by `cktimg-json`, so a backend author never links anything to use one.

`docs/TARGETS.md` in the cktImg repo is normative. This is what you need to write one.

```sh
cktimg-json --target targets/xschem.json deck.spice > out.json
```

Three shipped manifests live in `targets/`: `xschem.json`, `web.json`, `schemify.json`. Copy the closest one.

## Schema

```json
{
  "target": "xschem",
  "version": 1,
  "units": { "scale": 1.0, "y_down": true },
  "style": { "library": "devices" },
  "unmapped": { "mode": "box", "sym": "devices/generic.sym" },
  "classes": {
    "nmos":  { "sym": "devices/nmos4.sym" },
    "opamp": { "sym": "devices/opamp.sym", "pins": ["in+", "in-", "out"] }
  }
}
```

| Key | Required | Meaning |
|---|---|---|
| `target` | yes | The backend's name for itself; echoed into the output |
| `version` | yes | Must be `1`. A higher value is refused rather than guessed at |
| `units` | no | Passed through verbatim, never interpreted |
| `style` | no | Passed through verbatim; target-wide payload |
| `unmapped` | yes | What happens to a catalog class this file omits |
| `classes` | yes | Class name to mapping. May be empty |

`unmapped.mode` is `"box"` (draw `unmapped.sym`), `"skip"`, or `"error"` (refuse the deck). It is required even at full coverage, because the class that is missing tomorrow deserves a decision made today rather than a default.

`units` and `style` are copied to the output untouched. In particular `units.scale` is **not** applied to any coordinate: the document stays on cktImg's integer grid, and a backend that knows its own grid multiplies far more cheaply than it can un-round. `y_down` is a statement, not a request — cktImg's y axis always points down.

## Getting the vocabulary right

The keys of `classes` are builtin class names; the strings in `pins` are that class's terminal names as the catalog spells them. Both are validated, so a typo fails loudly at run time rather than quietly miswiring a schematic.

Three facts that catch first-time manifest authors:

- **MOSFETs are three-terminal**: `nmos` is `d`, `g`, `s`. There is no bulk pin, and `["d","g","s","b"]` is rejected.
- **Terminal order is SPICE node order, not drawing order.** An `opamp` is `in+`, `out`, `in-` because that is the order its nodes appear on the card. Reordering that for a human-facing editor is exactly what `pins` is for.
- **Class names are lowercase, matched byte-exactly.** `NMOS` is not `nmos`.

`pins` is optional, and leaving it out means "catalog order". Write it only where the target genuinely reorders — spelling out identity permutations for every class is where the typo hides.

To find out what a given deck actually needs, run `cktimg-json deck.spice` with no `--target` and read the `class` and `term` fields. Only those classes need mapping.

## Reading the result

`--target` adds a `"target"` block alongside the normal document. Per device it carries the resolved symbol and, when the class reorders, `pins` as **indices into that device's own pin array**:

```json
"target": { "devices": [ { "device": 0, "sym": "devices/opamp.sym", "pins": [0, 2, 1] } ] }
```

So `pins[k]` is the index of the terminal the target wants in position `k`. Join it against `devices[device].pins` to get the net and coordinate:

```js
const dev = doc.devices[t.device];
const ordered = (t.pins ?? dev.pins.map((_, i) => i)).map(i => dev.pins[i]);
```

Indices rather than copied records: the net and coordinate then exist in exactly one place in the document and cannot disagree with themselves.

## Errors

Every failure names the file and the offending key, and exits 1 before writing anything — a refusal never leaves a truncated output file.

```
error: bad.json: class "nmos": "b" is not a terminal of this class (catalog terminals are d, g, s)
error: bad.json: class "nmoss" is not in the cktImg catalog
error: bad.json:3:1: malformed JSON (UnexpectedEndOfInput)
```
