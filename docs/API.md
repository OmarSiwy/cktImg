# API

SPICE text in, a placed schematic out: devices at integer points with an
orientation, every pin's point, wires as polylines per net, junction dots,
net labels and no-connect marks. The library draws nothing and knows no
device: the application (a *target*) says what each device class looks like,
and reads the result to write its own format — SVG, TikZ, an xschem `.sch`.

The boundaries follow cktImg's (`place`, `Pipeline`, `Config`/`lint.zon`,
`Placed`, lint, LaTeX, a zero-copy C handle), cleaned up where they coupled
the caller to hidden state.

## The usage code this API was written from

(The Zig module is `NetlistParser`; the snippets name it
`const cktimg = @import("NetlistParser");`.)

### 1. Say what the devices look like

The library ships no symbols. A target registers classes — terminals with
anchor points in the canonical frame (origin at the device centre, y down,
principal terminals on the x axis at ±20) and the strokes of the body:

```zig
var lib = cktimg.Library.init(gpa);
defer lib.deinit();
_ = try lib.register(.{
    .name = "res",
    .terminals = &.{ .{ .name = "a", .at = .{ .x = -20, .y = 0 } }, .{ .name = "b", .at = .{ .x = 20, .y = 0 } } },
    .draw = &.{ .ln(-20, 0, -10, 0), .ln(10, 0, 20, 0), .{ .polyline = &zigzag } },
});
_ = try lib.register(.{ .name = "vdd", .role = .power_rail, .terminals = &.{.{ .name = "p", .at = .zero }}, .draw = &bar });
```

or load a whole symbol file (`tests/symbols.zon` is the set the tests use):

```zig
try lib.loadZon(arena, symbols_text, &diags);
```

Which class a device gets is decided by name: `res`, `cap`, `ind`,
`vsource`, `isource`, `cvsource` (E), `cisource` (G), `ccvs` (H), `cccs` (F),
`bsource`, `diode`, `npn`, `pnp`, `njfet`, `pjfet`, `mesfet`, `nmos`, `pmos`
(from the `.model` type), `switch`, `tline`, `urc` (the vocabulary is
`library.className`; cktImg's names where it has one). Rails and ports are found by role:
`power_rail`, `ground_rail`, `input_port`, `output_port`. A device whose class
is not registered is drawn as a generated box and reported by lint
(`unmapped_master`).

A terminal flagged `.hidden` (a MOS bulk) counts for paths but gets no wire; one
flagged `.ground_ref` (an op-amp's reference) gets none when it is on ground.

### 2. Place — the one call

```zig
var diag: cktimg.netlist.Diagnostic = .{};
var placed = try cktimg.place(gpa, &cfg, &lib, &.{spice_text}, &diag);
defer placed.deinit();

for (0..placed.deviceCount()) |d| {
    const class = lib.at(placed.dev_class[d]);
    const at = placed.dev_pos[d];
    const o = placed.dev_orient[d];            // mirror, then quarter turns clockwise
    for (class.draw) |op| drawOp(o.apply(...) ...);
}
for (0..placed.netCount()) |n| {
    var it = placed.segments(n);
    while (it.next()) |poly| drawPolyline(poly);
}
for (placed.junctions) |p| dot(p);
for (placed.labels) |l| text(l.at, l.side, placed.net_name[l.net]);
for (placed.no_connects) |p| cross(p);
```

`Placed` is plain data: no accessor is needed to read it, and every column is
a slice. Devices come in netlist order, then the rail and port symbols the
layout added (one per terminal symbol it drew: no name, their net on their
one pin). A source that drives a supply, input or bias net from ground (R3)
is not wired into the circuit — terminal symbols stand for it there — but it
is still in `Placed`: drawn apart, left of the circuit, between its own
terminal symbol and a ground symbol.

### 3. The stages, when one call is too coarse

`place` is exactly these, back to back; each can be called alone:

```zig
var nl = try cktimg.netlist.parse(gpa, &.{spice_text}, &diag);   // or netlist.load(gpa, io, dir, paths, &diag)
defer nl.deinit(gpa);
const roles = try cktimg.guessRoles(gpa, &nl);                    // edit freely: which nets are supply, input, …
defer gpa.free(roles);
var s = try cktimg.Schematic.build(gpa, &nl, roles, &lib);        // topology: orientation, wiring, supernodes
defer s.deinit();
try cktimg.layout(gpa, &s, &cfg);                                  // coordinates
var placed = try cktimg.Placed.init(gpa, &s, &nl);                 // plain geometry out
```

The schematic between `build` and `layout` is the topology before any
coordinate exists — an editor with its own placer stops there.

### 4. Many documents, one set of pages

```zig
var p = cktimg.Pipeline.init(gpa, &cfg, &lib);
defer p.deinit();
for (decks) |deck| {
    const placed = try p.run(&.{deck}, &diag);   // borrowed: valid until the next run or reset
    try emit(placed);
    p.reset();                                    // keeps the capacity
}
```

### 5. Settings

```zig
var diags: std.ArrayList(cktimg.config.Diagnostic) = .empty;
const cfg = try cktimg.Config.load(arena, io, dir, "lint.zon", &diags);   // missing file: defaults
```

`.layout` holds the wire lengths (ALGORITHM.md §5), `.rules` the lint
severities, `.render` the TikZ colours and widths. Unknown keys are reported,
never fatal.

### 6. Lint

```zig
const findings = try cktimg.lint.check(gpa, &placed, &lib, cfg.rules);
defer gpa.free(findings);
```

Plain data in, a slice out; `Rules.off` with one field set runs one rule.

### 7. LaTeX (`-Dlatex_renderer=true`)

```zig
try cktimg.latex.write(gpa, &placed, &lib, &cfg, w);     // a tikzpicture
```

The picture is CircuiTikZ: bipoles (`R`, `C`, `L`, `V`, `I`, `D`, controlled
sources) along their wires, transistors and the op-amp as nodes turned and
mirrored to the placed orientation, rails and ports as `vdd`/`ground`/`ocirc`;
any other class falls back to its strokes.

`cktimg-tex [--config lint.zon] [--symbols file.zon] [--lint] [--standalone] in.cir [out.tex]`
and `latex/cktimg.sty` put it in a document.

### 8. From C

```c
CktimgLib *lib = cktimg_lib_new();
CktimgTerminal res_t[] = { {"a", -20, 0, 0}, {"b", 20, 0, 0} };
int32_t zig[] = { -10,0, -8,6, -4,-6, 0,6, 4,-6, 8,6, 10,0 };
int32_t l1[] = { -20,0, -10,0 }, l2[] = { 10,0, 20,0 };
CktimgOp res_d[] = { { CKTIMG_OP_LINE, l1, 2 }, { CKTIMG_OP_LINE, l2, 2 }, { CKTIMG_OP_POLYLINE, zig, 7 } };
cktimg_lib_add(lib, "res", CKTIMG_ROLE_NONE, res_t, 2, res_d, 3);

char *report = NULL;
CktimgSch *sch = cktimg_parse_place(lib, spice_text, NULL /* lint.zon text */, &report);
for (size_t d = 0; d < cktimg_device_count(sch); d++) { ... cktimg_device_pos(sch, d, &x, &y) ... }
cktimg_sch_free(sch);
cktimg_lib_free(lib);
```

Same accessors as cktImg's (devices, pins, nets, wires, junctions, labels,
bounds, placed draw ops, JSON into your buffer), plus device roles, label
sides, no-connects, `cktimg_lib_load_zon` and `cktimg_lint`. `tests/abi_test.c`
is a C program that uses all of it and runs under `zig build test`. What
changed, and why:

| cktImg | here | why |
|---|---|---|
| `cktimg_class_begin/pin/line/…/register` on one process-global builder | `cktimg_lib_add(lib, name, role, terms, n, ops, n)` on a library you own | a global builder is hidden state with an unnamed lock: two threads interleave pins, and no two callers can have two vocabularies |
| `cktimg_parse_place(src)` | `cktimg_parse_place(lib, src, zon, &report)` | the library knows no devices, so it must be told which; settings were unreachable from C |
| `CktimgRole` (drain, gate, …) | terminal flags (`HIDDEN`, `GROUND_REF`) | the layout reads sides from anchor geometry; roles were placement hints for cktImg's spine walk |
| a bad netlist still returns a handle | returns NULL and the error in `report` | the parser rejects what it cannot represent rather than drawing part of it |

## Dropped

cktImg's `rerun`, `patch`, `Pipeline.Carry`, `Scratch` and the `.layout` keys
of its search (`refine`, `enum_limit`, `track_w`, …) belonged to its column
search and router; this layout is deterministic and has neither. JSON output
(`json.write`) is kept for the C ABI's `cktimg_json` and for `cktimg-json`,
the command line tool (`tools/json.zig`; target manifests in
`docs/TARGETS.md`).
