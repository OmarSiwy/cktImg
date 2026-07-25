## cktImg

Place-and-route engine that turns an analog circuit netlist into the choice of your backend.
The layout emphasizes straight lines and orthogonal routing, where VDD->GND is top-down, Signal path is left->right.

Applications:

- Schematic Linter with custom team-preferences.
- Netlist importer to work with schematic editors.
- Use netlists from your design straight in Research papers.

=> Read More: https://github.com/OmarSiwy/cktImg/... [Github page website]

### Build

Zig 0.16.0. `nix develop` gets you a shell with the toolchain.

```sh
zig build                             # static library + include/cktimg.h
zig build test                        # the suite
zig build test -Dlatex_renderer=true  # also compiles and tests the TikZ emitter
zig build gallery                     # render tests/fixtures/ to zig-out/gallery
```

The LaTeX emitter is off by default. Off, `latex` is `void`, so a stale reference is a compile
error naming the missing option rather than a link failure.

### LaTeX package

`-Dlatex_renderer=true` also builds `cktimg-tex`, which reads a netlist and writes a TikZ
figure:

```sh
cktimg-tex amplifier.spice figure.tex     # a \begin{tikzpicture} fragment
cktimg-tex amplifier.spice --standalone   # ...wrapped in a compilable document
cktimg-tex --config lint.zon in.spice     # to stdout, with custom settings
```

`latex/cktimg.sty` puts that in a document directly:

```latex
\usepackage{cktimg}          % [shell] / [pregenerated] / [auto] (default)
...
\cktimg{amplifier.spice}
```

With `pdflatex -shell-escape` the figure is generated during the run. Without it — Overleaf,
most CI — run `cktimg-tex amplifier.spice amplifier.cktimg.tex` first and the package inputs
what you generated. A worked example is in `examples/latex/figure.tex`; release builds ship
the `.sty` together with `cktimg-tex` binaries for Linux, macOS and Windows.

### Configurability

There are a few configurable parameters that change the placement and routing behavior. These are read from a `lint.zon` file in the working directory, and would be customizable by different teams according to their preferences, however for correctness, some things are non-modifiable.

Below is an example config:

```zon
.{
    .layout = .{
        .abut_gap = 8,     // minimum gap between two abutting devices
        .tap_unit = 12,    // extra vertical room per fan-out tap on a node
        .track_w = 8,      // one wire track; channel width is a multiple of this
        .track_h = 10,     // vertical pitch between margin tracks
        .margin_gap = 16,  // device field to the first margin track
        .bus_gap = 24,     // device field to a VDD/GND rail
        .enum_limit = 10,  // above this spline count, stop enumerating orders exhaustively
        .refine = 16,      // how many candidate orders get fully placed, routed and measured
        .grid = 1,         // placement quantization; 1 means none
        .strict_geometry = false,
    },
    .render = .{
        .stroke = "#2e7d32", // device symbols. Emitted verbatim, so a full CSS color.
        .wire = "1565c0",    // wires. Bare hex — the renderer prepends the '#'.
        .sym_w = 1.2,
        .wire_w = 1.5,
        .pad = 24,
    },
    .pdk = .{
        .leaf = .{"sky130_fd_pr__*"},              // masters to treat as primitives, not flatten
        .alias = .{ .{ "my_nfet", "nmos" } },      // explicit master -> builtin class
        .scan = true,                              // scan unresolved names for a class token
        .unknown_as_box = true,                    // unresolved leaves become a generic box
    },
}
```

Every key is optional and absent keys keep their default. An **unrecognized key is reported,
not fatal**, so a config written for a newer version still loads — failing to draw a schematic
over a typo in a style file is the wrong trade.

**What is deliberately not configurable:** the router's cost weights. Straight-wire preference,
bend cost, crossing cost and the near-free rail bus rows are `comptime` constants, because they
encode what a schematic _means_ rather than how far apart things sit. Retuning them would give
you a differently-_reasoned_ drawing, not a differently-spaced one. See
[docs/ALGORITHM.md](docs/ALGORITHM.md), "The costs are the opinions".

### Writing your own Backend using the C-ABI

The library's product is **geometry** — placed symbols, routed polylines, junction dots, labels,
plus the transform and collision helpers needed to draw them. It ships no SVG emitter. The
bundled gallery under `examples/self-hosted/` is written against this same public surface and
gets no privileged access, so anything it can draw, your backend can draw.

Link `libcktimg.a` and include `cktimg.h`.

```c
#include "cktimg.h"

CktimgSch *sch = cktimg_parse_place(spice_text);
if (!sch) return 1;

int32_t x0, y0, x1, y1;
cktimg_bounds(sch, &x0, &y0, &x1, &y1);

for (size_t d = 0; d < cktimg_device_count(sch); d++) {
    int32_t dx, dy;
    cktimg_device_pos(sch, d, &dx, &dy);
    printf("%s (%s) at %d,%d rot=%u mirror=%d\n",
           cktimg_device_name(sch, d), cktimg_device_class(sch, d),
           dx, dy, cktimg_device_rot(sch, d), cktimg_device_mirror(sch, d));

    // Draw ops are the symbol's strokes, already transformed by orientation.
    for (size_t o = 0; o < cktimg_device_op_count(sch, d); o++) {
        const int32_t *xy;
        size_t n = cktimg_device_op_points(sch, d, o, &xy);
        /* xy is n pairs: xy[0],xy[1], xy[2],xy[3], ... */
    }
}

// Wires: one entry per net, each a list of Manhattan polylines.
for (size_t w = 0; w < cktimg_wire_count(sch); w++) {
    for (size_t s = 0; s < cktimg_wire_segment_count(sch, w); s++) {
        const int32_t *xy;
        size_t n = cktimg_wire_segment_points(sch, w, s, &xy);
    }
}

// A dot is emitted only where >=3 same-net arms meet. A plain crossover gets none,
// and correctly reads as *not connected*.
for (size_t j = 0; j < cktimg_junction_count(sch); j++) { /* ... */ }

cktimg_sch_free(sch);
```

**Ownership, the one rule that matters.** Strings and point arrays returned by accessors are
**borrowed** — they point directly into the schematic and are valid until `cktimg_sch_free`.
Never free them individually. Only results explicitly documented as allocated (currently
`cktimg_run_json` and friends) are caller-owned, and those are released with
`cktimg_string_free`.

This is zero-copy by construction, not by convenience: names are NUL-terminated inside the
string pool and wire points alias the layout's own arrays, so there is no shadow copy of the
schematic to fall out of sync.

**Robustness.** A null handle or an out-of-range index returns null/0/false. It never traps —
that is a trust boundary and stays fully checked.

Registering your own symbols, for classes the builtin catalog does not carry:

```c
cktimg_class_begin("my_widget");
cktimg_class_pin("a", CKTIMG_ROLE_PASSIVE, -20, 0);
cktimg_class_pin("b", CKTIMG_ROLE_PASSIVE,  20, 0);
cktimg_class_line(-20, 0, 20, 0);
size_t sym = cktimg_class_register();
```

Indices handed out by `cktimg_class_register` never move, so they stay valid for the life of
the process.

### Documentation

- [docs/ALGORITHM.md](docs/ALGORITHM.md) — the layout algorithm: spines, columns, the routing
  lattice, and why each cost is what it is.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — data layout, the five-arena allocation
  strategy, and module structure.
- [docs/CONVENTIONS.md](docs/CONVENTIONS.md) — code conventions.
