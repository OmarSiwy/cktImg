# Tier 1 — the C ABI

Link `libcktimg.a`, include `cktimg.h`. The handle is a view over the library's own arrays, so reading it costs nothing and copies nothing.

```c
#include "cktimg.h"

CktimgSch *sch = cktimg_parse_place(spice_text);
if (!sch) return 1;

for (size_t d = 0; d < cktimg_device_count(sch); d++) {
    int32_t x, y;
    cktimg_device_pos(sch, d, &x, &y);
    printf("%s (%s) at %d,%d rot=%u mirror=%d\n",
           cktimg_device_name(sch, d), cktimg_device_class(sch, d),
           x, y, cktimg_device_rot(sch, d), cktimg_device_mirror(sch, d));

    for (size_t o = 0; o < cktimg_device_op_count(sch, d); o++) {
        const int32_t *xy;
        size_t n = cktimg_device_op_points(sch, d, o, &xy);
        /* n pairs: xy[0],xy[1], xy[2],xy[3], ... already transformed by orientation */
    }
}

for (size_t w = 0; w < cktimg_wire_count(sch); w++)
    for (size_t s = 0; s < cktimg_wire_segment_count(sch, w); s++) {
        const int32_t *xy;
        size_t n = cktimg_wire_segment_points(sch, w, s, &xy);
    }

cktimg_sch_free(sch);
```

## Ownership — the one rule that segfaults you

Strings and point arrays handed back by accessors are **borrowed**. They point directly into the schematic and stay valid until `cktimg_sch_free`. Copy anything you need to outlive the handle; free none of them individually.

The exceptions are the few results documented as allocated — `cktimg_run_json` and friends — and those are released with `cktimg_string_free`, never with `free`.

This is zero-copy by construction rather than as an optimisation: names are NUL-terminated inside the string pool and wire points alias the layout's own arrays, so there is no second copy of the schematic that could fall out of sync with the first.

## Robustness

A null handle or an out-of-range index returns null, 0 or false. It never traps — that boundary stays fully checked, so a loop that runs one past the end gives you a null rather than a crash.

## Drawing what you get

Draw ops come out already transformed by the device's orientation, so you place them at the device position and nothing else. The transform order is mirror-then-rotate; the library applies it for you, and reimplementing it is how two renderers of the same schematic start disagreeing.

A junction dot is emitted only where three or more same-net arms meet. A plain crossover gets none and correctly reads as *not connected* — so draw exactly the dots in `cktimg_junction*` and do not infer more from the polylines.

Refdes anchors come from `cktimg_device_refdes_anchor`, which has already avoided collisions with bodies, wires and dots. Placing labels yourself puts them back on top of the geometry.

## Your own symbols

For classes the builtin catalog does not carry:

```c
cktimg_class_begin("my_widget");
cktimg_class_pin("a", CKTIMG_ROLE_PASSIVE, -20, 0);
cktimg_class_pin("b", CKTIMG_ROLE_PASSIVE,  20, 0);
cktimg_class_line(-20, 0, 20, 0);
size_t sym = cktimg_class_register();
```

Indices from `cktimg_class_register` never move, so they stay valid for the life of the process.

Match the canonical frame or placement quality degrades: origin at the centre, 40 units wide, the two principal terminals on the conduction axis at (-20, 0) and (+20, 0). That is what makes a resistor's pins line up with a MOSFET's drain and source when the placer stacks them in a column.

The terminal role is electrical, not decorative — it drives the spine walk and control-net attraction. `passive`, `drain`, `source`, `collector`, `emitter`, `anode` and `cathode` conduct; `gate`, `base` and `bulk` do not. Getting a role wrong changes the placement, not the drawing.

## When to step down to tier 2

The C ABI places a netlist and hands you the result. Reach for the Zig API when you need the parsed netlist *without* layout, want to lay one netlist out repeatedly under different configs, or are placing enough schematics that the allocator shows up in a profile.
