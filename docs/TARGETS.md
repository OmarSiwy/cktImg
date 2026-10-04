# Target manifests

`cktimg-json --target manifest.json deck.spice` adds a `"target"` block to
the document: for each device, the backend's symbol and the order it wants
the pins in. The manifest is JSON the backend's author writes; the library
never reads it (`tools/json.zig` does).

```json
{
  "target": "xschem",
  "version": 1,
  "units": { "scale": 2.0 },
  "style": { "anything": "passed through" },
  "unmapped": { "mode": "box", "sym": "devices/generic.sym" },
  "classes": {
    "nmos":  { "sym": "devices/nmos4.sym", "style": { "model": "nfet_01v8" } },
    "res":   { "sym": "devices/res.sym", "pins": ["b", "a"] },
    "opamp": { "sym": "my_lib/opamp.sym" }
  }
}
```

| key | required | meaning |
|---|---|---|
| `target` | yes | the backend's name, echoed as `target.name` |
| `version` | yes | `1` |
| `units`, `style` | no | copied through untouched; nothing is rescaled |
| `unmapped.mode` | yes | a class with no entry: `box` (use `unmapped.sym`/`style`), `skip` (leave it out of the block), `error` (refuse) |
| `classes` | yes | key → `{ "sym": string, "pins"?: [terminal names], "style"?: any }` |

## Which key a device uses

A device's class is looked up by name (`nmos`, `res`, `vdd`, `gnd`,
`ipin`, … — the names in the symbol set, `tests/symbols.zon`). A
subcircuit instance's class is `block:<subckt>`; its key may be the class
name or the **subcircuit name** alone, so `"opamp"` above maps every
`X… opamp` instance. That works for a subcircuit the deck defines (pins:
its `.subckt` ports, in order) and for one it does not (pins `p1`..`pN`).

## `pins`

Absent: the symbol's own terminal order. Present: a permutation of the
class's terminal names, slot *j* naming the terminal that is the target's
*j*-th pin. A wrong length, an unknown name or a repeat refuses the run,
because a wrong permutation draws a schematic wired differently from its
netlist. Subcircuit entries are checked against the instance's ports when
the deck is placed.

## Output

```json
"target": {
  "name": "xschem", "version": 1, "units": { "scale": 2.0 },
  "devices": [
    { "device": 0, "name": "x1", "class": "block:opamp", "sym": "my_lib/opamp.sym", "pins": [0, 1, 2, 3, 4] }
  ]
}
```

`device` indexes the document's `devices`; `pins` indexes that device's
`pins`, already in the target's order. With `skip`, unmapped devices have no
entry. Nothing is written if the manifest is malformed or a mapping fails.
