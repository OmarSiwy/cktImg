# `cktimg` — Python bindings

SPICE → schematic. Render to SVG, or get the placed schematic back as a plain
Python dict to post-process. Built for the **AMSNet → SPICE → cktImg → cleanup**
loop: AMSNet turns a schematic image into a netlist, cktImg places & routes it,
and you get resolved geometry (device positions, pin coords, junctions) to clean
up with SINA before re-rendering.

## Install

From PyPI (once published):

```sh
pip install cktimg
```

The CI builds abi3 wheels for Linux/macOS/Windows + an sdist on every push
(`.github/workflows/python.yaml`); download them from the run's **Artifacts**,
or `pip install cktimg-*.whl` directly.

### Build from source

Needs the Rust toolchain and [maturin](https://www.maturin.rs/):

```sh
cd export/python
pip install maturin
maturin develop --release      # builds + installs into the active venv
# or: maturin build --release   → wheel in target/wheels/
```

## Use

```python
import cktimg

spice = open("ota.sp").read()

# 1. Straight to a schematic SVG.
svg = cktimg.render(spice)
open("ota.svg", "w").write(svg)

# 2. Placed schematic as a dict — the seam for cleanup.
sch = cktimg.schematic(spice)
```

`schematic(spice)` returns:

```python
{
  "devices": [
    {
      "name": "M1", "class": "nmos", "value": "",
      "rot": 1, "mirror": False, "pos": [40, 0],
      "pins": [
        {"term": "d", "net": "out", "xy": [40, 20]},
        {"term": "g", "net": "in",  "xy": [20, 0]},
        {"term": "s", "net": "gnd", "xy": [40, -20]},
        ...
      ],
    },
    ...
  ],
  "nets": ["vdd", "gnd", "in", "out", ...],
  "wires": [
    {"net": "out", "segments": [[[40, 6], [72, 6]], ...]},   # routed polylines
    ...
  ],
  "junctions": [[120, 40], ...],
}
```

`wires` is the routed geometry SINA most likely wants to clean up — each net's
trunk + stub polylines as you'd draw them. `junctions` are the connection dots.

`rot` is `0..=3` (×90°). Coordinates are in the schematic grid (device pitch =
40). Need the raw JSON string instead of a dict? `cktimg.schematic_json(spice)`.

## AMSNet / SINA cleanup loop

```python
import cktimg

spice = amsnet.image_to_spice("schematic.png")   # image → netlist
sch   = cktimg.schematic(spice)                   # netlist → placed geometry
sch   = sina.cleanup(sch)                          # nudge positions, fix labels, ...
# re-render however you like, or feed corrected SPICE back through cktimg.render
```

`schematic()` gives you everything the renderer sees, so SINA can adjust device
positions, relabel nets, or drop stray pins before the final SVG.

## API

| Function | Returns | Use |
|---|---|---|
| `render(spice)` | `str` (SVG) | Final schematic image |
| `schematic(spice)` | `dict` | Placed geometry for post-processing |
| `schematic_json(spice)` | `str` (JSON) | Same, unparsed |
