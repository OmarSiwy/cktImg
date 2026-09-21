# Target manifests

A **target manifest** maps cktImg's device class vocabulary onto one backend's native
symbols and pin order. It is JSON data, it lives in `targets/`, and it is the answer to
the one question every backend author has had to answer by hand: *what do I draw for a
`nmos`, and in what order do its pins come out?*

This document is normative. `src/json_main.zig` is its only implementation and
`tests/targets.zig` is what keeps the two from drifting.

## The library does not read these files

`libcktimg` has no manifest loader, no `cktimg_target_load()`, and no knowledge that this
format exists. That is deliberate, not an omission.

A loader inside the library would buy a caller exactly one `std.json` call they can write
themselves, and charge them for it three times over: retention (the library would hold a
mapping table the caller already owns), coupling (their symbol library would only be
reachable through our file format and our file I/O), and flow control (our idea of when
and how a file gets read). `src/netlist/source.zig` already refuses that trade for include
files — it takes a caller-supplied `Loader` rather than touching `std.fs` — and manifests
get the same treatment.

What you get instead is three integration tiers, each reachable without the one above it:

| Tier | What you do | What you link |
|------|-------------|---------------|
| 1 | `cktimg-json --target targets/xschem.json in.spice` | nothing — read the JSON |
| 2 | walk the C ABI, parse the manifest yourself | `libcktimg` |
| 3 | ignore manifests; `cktimg_device_class()` is the vocabulary | `libcktimg` |

Tier 1 is the cheap step most people want. Tier 2 exists because a backend with its own
geometry pass should not have to route its symbol lookup through our process. Tier 3
exists because a manifest is a convenience, not a requirement: the class names and
terminal names are library surface and always have been.

## The vocabulary being mapped

The keys of `classes` are cktImg's builtin device classes — `src/devices/catalog.zig`,
96 of them as of version 1 — and the strings inside `pins` are that class's **terminal
names, exactly as the catalog spells them**. Both are checked; neither is guessed at.

Three facts about the catalog that surprise people writing their first manifest:

- **MOSFETs have three terminals, not four.** `nmos` is `d`, `g`, `s`. There is no bulk
  pin. A manifest that writes `["d", "g", "s", "b"]` is rejected.
- **Terminal order is SPICE node order, not drawing order.** An `opamp` is `in+`, `out`,
  `in-`, because that is the order its nodes appear on the card. Most editors list inputs
  first, which is exactly the kind of reordering `pins` exists for.
- **Class names are lowercase and are matched byte-exactly.** `NMOS` is not `nmos`.

`cktimg-json <deck>` with no `--target` prints the classes and terminals a given deck
actually uses, which is the fastest way to find out what you need to map.

## Schema

```json
{
  "target": "xschem",
  "version": 1,
  "units": { "scale": 1.0, "y_down": true },
  "style": { "library": "devices", "text_size": 0.3 },
  "unmapped": { "mode": "box", "sym": "devices/generic.sym" },
  "classes": {
    "nmos":  { "sym": "devices/nmos4.sym" },
    "opamp": { "sym": "devices/opamp.sym", "pins": ["in+", "in-", "out"] },
    "res":   { "sym": "devices/res.sym", "style": { "spice_prefix": "R" } }
  }
}
```

### Top level

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `target` | string | yes | The backend's own name for itself. Echoed into the output. |
| `version` | integer | yes | Schema version. Must be `1`; a higher one is refused rather than guessed at. |
| `units` | any | no | Passed through verbatim. See below. |
| `style` | any | no | Passed through verbatim — target-wide payload. |
| `unmapped` | object | yes | What happens to a catalog class this file omits. |
| `classes` | object | yes | Class name → mapping. May be empty. |

`units` and `style` are **not interpreted**. `cktimg-json` copies them into the output and
never acts on them — in particular it does **not** apply `units.scale` to any coordinate.
The document's geometry stays in cktImg's canonical integer grid, because rescaling here
would replace a deterministic integer document with float formatting, and the backend that
knows its own grid can multiply far more cheaply than it can un-round. `y_down` is
similarly a statement, not a request: cktImg's y axis always points down.

Pass through whatever you need. A web renderer puts strokes and a sprite href in `style`;
an editor puts a catalog id in it. The schema deliberately carries a small common core
plus an opaque bag, rather than becoming the union of every backend's wishes — and it is
not a template engine: nothing in `style` is ever expanded, substituted or evaluated.

### `unmapped`

```json
"unmapped": { "mode": "box", "sym": "devices/generic.sym", "style": { … } }
```

| `mode` | Effect |
|--------|--------|
| `"box"` | Emit the device with `sym` (and `style`, if given) and the catalog's own pin order. |
| `"skip"` | Leave the device out of the `"target"` block. It is still in `"devices"`. |
| `"error"` | Refuse: `cktimg-json` names the class and exits non-zero, writing nothing. |

`mode` is `"box"` ⇒ `sym` is required: there is no default symbol to fall back on, and
inventing one would put a wrong glyph in someone's schematic silently.

`unmapped` itself is required even for a manifest that covers all 96 classes. A file that
covers everything today is a file that will not cover everything after the next class is
added, and the policy for that day should be a decision, not a default.

### A class entry

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `sym` | non-empty string | yes | Whatever the target calls the symbol. Opaque: a `.sym` path, a `#fragment`, an id. |
| `pins` | array of strings | no | The target's pin order. **Absent means the catalog's own order.** |
| `style` | any | no | Passed through verbatim. |

`pins` is a **permutation of that class's catalog terminal names** — it reorders pins, it
never renames or invents them. Slot *j* of the array is the target's *j*-th pin, and names
the catalog terminal that goes there.

Omit `pins` whenever the target's order is the catalog's order, which is most of the time.
Writing out an identity permutation is noise, and noise is where the typo hides.

## Validation

`pins` is checked, not trusted. A wrong permutation produces a schematic that parses,
renders, looks plausible and is **wired differently from the netlist it came from** — the
worst failure this tool has, because nothing downstream would catch it.

`cktimg-json --target` refuses the run, naming the file and the offending key, when:

- the file is unreadable, or is not well-formed JSON (reported with line and column);
- `version` is not `1`;
- `unmapped` is missing, or its `mode` is not one of the three, or `"box"` has no `sym`;
- a key of `classes` is not a cktImg class;
- the same class is mapped twice;
- `sym` is missing or empty;
- `pins` is not an array of strings, is the wrong length, names a terminal the class does
  not have, or repeats one.

```
$ cktimg-json --target bad.json in.spice
error: bad.json: class "nmos": "b" is not a terminal of this class (catalog terminals are d, g, s)
$ echo $?
1
```

Coverage is *not* an error by itself: a class the manifest omits is governed by
`unmapped`. That is what lets a manifest map the forty classes a target actually ships
symbols for and box the rest.

## Output

`--target` adds one member to the document `cktimg-json` already emits. **Without
`--target` the output is byte-for-byte unchanged**, which is a property of the code path,
not of a comparison: `json.writeOpen` emits the document one brace short and the manifest
branch contributes a member before `json.writeClose` finishes it, so the no-manifest path
is literally the two calls `json.writeWith` already makes. The block is streamed like
everything else — the document is never materialized to splice into.

```json
{
  "devices": [ … ], "nets": [ … ], "wires": [ … ],
  "junctions": [ … ], "labels": [ … ],

  "target": {
    "name": "xschem",
    "version": 1,
    "units": {"scale":1,"y_down":true},
    "style": {"library":"devices","text_size":0.3},
    "devices": [
      {
        "device": 0,
        "name": "m1",
        "class": "opamp",
        "sym": "devices/opamp.sym",
        "pins": [0, 2, 1]
      }
    ]
  }
}
```

- `device` is the index into the document's own top-level `devices` array, so the two are
  joinable without matching on names.
- `pins` is the pin order as **indices into that device's own `devices[device].pins`
  array**, already permuted. `[0, 2, 1]` means "my first pin is the document's first, my
  second is its third, my third is its second". Walk it in order and the schematic is
  wired correctly; there is no mapping left for the backend to do.

  ```js
  const slots = doc.devices[t.device].pins;
  for (const i of t.pins) emitPin(slots[i].term, slots[i].net, slots[i].xy);
  ```

  Indices rather than repeated `term`/`net`/`xy` objects, for two reasons. It roughly
  halves the document for a multi-pin device — the pin table is the bulkiest thing in it
  — and, more importantly, a copy of data can *disagree* with the original while a
  permutation cannot. Every fact about a pin is stated once, in `devices[].pins`, and
  this block says only what order to read them in. That is also all the manifest
  actually specifies: `pins` in the manifest is a permutation, never a rename.

  The indices are always exactly the slots `0 .. devices[device].pins.length - 1`, each
  once. A device whose card gave it a different number of nodes than its class has
  terminals is emitted in the identity order rather than reordered, because a class-level
  permutation cannot describe it and guessing would miswire it.
- `units`, `style` (target-wide) and a class's `style` appear verbatim, minified onto one
  line so a passthrough object does not dominate the diff of a document that is otherwise
  coordinates.
- Entries appear in document order. With `"mode": "skip"` an unmapped device has no entry
  at all, so `target.devices` may be shorter than `devices`.

## Shipped manifests

| File | Classes mapped | Omitted classes | Notes |
|------|----------------|-----------------|-------|
| `targets/xschem.json` | 73 of 96 | `"box"` → `devices/generic.sym` | `.sym` paths and xschem's inputs-first pin order for op-amps and gates. |
| `targets/web.json` | 96 of 96 | `"error"` | `#fragment` hrefs into an SVG sprite sheet, plus a CSS class per device family. |
| `targets/schemify.json` | 96 of 96 | `"error"` | `ckt.<class>` ids, plus the class's catalog ordinal as a stable numeric id. |

The `.sym` paths in `targets/xschem.json` are the stock `devices/` library names and are
**installation-dependent** — check them against your `XSCHEM_LIBRARY_PATH`. That is the
point of shipping the mapping as data: editing a path is editing a JSON file, not
patching a table inside three different backends.

`targets/schemify.json`'s `style.id` is the class's index in `catalog.classes`, which is a
documented contract: classes are only ever appended, never reordered or removed.
