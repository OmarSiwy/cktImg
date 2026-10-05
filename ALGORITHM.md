# Hypergraph → schematic

This document is the specification of `src/schematic.zig` (stages 1–4),
`src/layout.zig` (stage 5) and `src/placed.zig` (the result); the wire
lengths of §5 come from the `.layout` table of a `lint.zon` file
(`config.zig`), and every symbol's shape from the caller's device library
(`library.zig`). Every case has an id, the graph pattern that triggers it,
the rule, a netlist that produces it, and the test in `tests/cases.zig` that
checks it (tests are named by case id). Circuit diagrams are deliberately
absent: the cases are stated on the graph.

## 0. Terms

**Input.** The circuit hypergraph *H*: vertices are **nets**, hyperedges are
**devices**; a device's **pins** are ordered, pin *i* lies on one net. Net 0
is ground.

**Subcircuits.** An `X` card whose `.subckt` is defined in the netlist is one
device, a **block**: the library's class named after the subcircuit, or else a
generated box with the ports on its sides. Comments inside the definition
steer it: `*@ left inp inn` (likewise `right`, `top`, `bottom`) puts those
ports on that side of the generated box, the rest going left and right in
port order; `*@ expand` draws the body instead, flattened with ngspice's
names (`r.x1.r1`, net `x1.a`; ground stays global). A block is drawn
horizontal (O-rules do not turn it).

**Output.** A grid graph *G* whose nodes are

- **device** nodes (one per drawn device, plus supernode copies, §4),
- **terminal** leaves: one per supply, sink, input or output net,
- **label** nodes: a net name hung on a pin (a lab_pin in xschem),
- **junction** nodes: a net's own branching point, with no symbol (J1, J2).

**Nets are never nodes**, junctions aside: a junction is the point where a
bar of one net meets the rest of it, drawn as the bar its copies make (§4).
A net is realised by

- **straight edges**: two pins facing each other, drawn as a straight wire,
- **joins**: layout-only bends between pieces of a net (§3),
- **labels**: a label node, a terminal leaf, or a name written on a wire
  (an *annotation*). Pieces carrying the same name are the same net.

**Sides and facing.** After stage 2 every drawn pin faces one side: left,
right, up or down. Two pins **face** each other if one faces down and the
other up (a *vertical* pair: the down-facing one is above) or one right and
the other left (a *horizontal* pair: the right-facing one is on the left).
Two sides are **perpendicular** if one is horizontal and the other vertical.

**Paths.** *P(d)*: device *d* lies on a simple path from a supply net to a sink
net. *S(d)*: *d* lies on a simple path from an input net to an output net,
through nets other than supply, sink and bias. Both are computed at once per
pass as the biconnected block containing a virtual edge supply–sink (resp.
input–output) — by Menger's theorem exactly the devices on such a path.

**Keys.** `x_key(d) = (distance from the inputs, index)`,
`y_key(d) = (distance from the supply, index)`. Keys only break ties.

**Transistor-like.** A device kind with a side pin in its vertical form
(MOS, BJT, JFET, controlled sources).

## 1. Roles

| id | pattern | rule | example | test |
|----|---------|------|---------|------|
| R1 | a net's name | `gnd vss vee agnd dgnd vssa gnda` and net 0 → sink; `vdd* vcc* avdd* dvdd* vpp` → supply; `vb* bias*` → bias; `vin* in*` → input; `vout* out* vref* vo` → output; otherwise internal | `R1 vdd vin 1k …` | R1 |
| R2 | an internal net joined to the sink by a V source | the source has `ac`, `sin`, `pulse`, `pwl`, `exp`, `sffm`, `am`, `trnoise` or `trrandom` → input; otherwise → bias | `Vs a 0 ac 1` / `Vb b 0 dc 0.5` | R2 |
| R3 | a V source from a supply, input or bias net to the sink; or a device with no drawn pin | not in the circuit: the terminal leaf stands for it there. A driver is still drawn, apart (§7) | `Vdd vdd 0 1.8` | R3 |

Roles are an editable input to stage 2 (`guessRoles` only proposes them).

## 2. Orientation

Each drawn device gets an orientation, vertical or horizontal, from which
every pin's side follows, then flips and mirrors.

Sides come from the device's **class** in the caller's library (the class
named for its kind: `res`, `nmos`, … — `library.className`). A pin faces the
side its terminal's anchor lies on, seen from the class origin (the larger of
|x| and |y| decides). The horizontal form is the class as drawn; the vertical
form is it turned a quarter left, so a MOSFET drawn with its drain right, gate
up and source left stands with its drain up, gate left and source down. A
card pin with no terminal (a MOS bulk on a three-terminal symbol), a pin past
the 64th, and a terminal flagged `hidden`, is not drawn and does not count
for paths; one
flagged `ground_ref` is not drawn when its net is ground (O0). The flips
combine with the form into one placement: a mirror, then quarter turns
(`Orient`).

| id | pattern | rule | example | test |
|----|---------|------|---------|------|
| O0 | MOS bulk, BJT substrate; a controlled source's out− on the sink | the pin counts for paths but is not drawn (the op-amp symbol has no reference pin) | `M1 d g s b nch`, `E1 out 0 in fb 1e5` | O0 |
| O1 | *P(d)* and not *S(d)* | vertical | `R1 vdd 0 1k` | O1 |
| O2 | *S(d)* and not *P(d)* | horizontal | series R of an RC low-pass | O2 |
| O3 | *P(d)* and *S(d)*, transistor-like | vertical | the transistor of a CS stage | O3 |
| O4 | *P(d)* and *S(d)*, no side pin | horizontal | `Rf x out` with `R1 vdd x`, `Rl out 0`, `M1 x in 0 0` | O4 |
| O5 | neither | vertical | shunt C of an RC low-pass | O5 |
| O6 | vertical device | flip so the pin nearest the supply faces up (tie: nearest the sink faces down) | PMOS source up | O6 |
| O7 | horizontal device | flip so the pin nearest the input faces left (tie: nearest the output faces right) | `R1 out in 1k` | O7 |
| O8 | an internal net holding the side pins of exactly two vertical devices that are **not stacked** (no net where one's down pin meets the other's up pin) | the device with the smaller `x_key` faces right, the other left | current mirror gates; *not* an inverter's two gates (`Mp2 b a …`, `Mn2 b a …`) | O8 ×2 |
| O9 | an internal net holding the up/down pins of exactly two vertical devices whose side pins go to two different input nets | inputs face outwards (smaller `x_key` left); the pair's halves are recorded: an input leaf faces the gates it drives, an output taken from the left half sits on the left | differential pair | O9 |

O9 is applied before O8; a device fixed by one is not flipped by the other.

## 3. Wiring a net

Each drawn pin, and each terminal leaf's single pin, belongs to one net. A
leaf's pin faces: supply down, sink up, input right (left when every pin it
drives faces right, O9), output left (right when taken from the left half,
O9). Every net *n* with at least two pins is wired in this order; each step
only joins **pieces** (sets of pins already connected) that are still
separate. A junction's pins are one point: they start in one piece.

**Step J — junctions (J1, J2).** Before anything else, a group of two or more
pins of *n* facing the same side *f* may get a junction on side *f* of them:
a fan pin facing back at the group, wired to each of its pins (S2 turns it
into a bar), and a back pin facing *f*, which meets the rest of the net.

- J1: the only pin facing the group is an input or output leaf, and the net
  has no pair of facing pins on the other axis (whose wire the group could
  tap, W3). The leaf is wired to the back pin: it sticks out from the bar
  instead of being split into the bar itself. Rails (supply, sink) never get
  one; a rail over several loads is S2's.
- J2: no pin faces the group, and the group's devices stand in one stack
  along the axis across *f* (each linked to the rest by `stacked`, O8): the
  two gates of an inverter. Devices side by side do not qualify (W9).

**Step A — facing groups (W1, W2).** For each axis, the pins facing down meet
the pins facing up (right meet left), leaving out pins Step J wired. The side
with fewer pins provides the **hubs** (down/right on a tie). Each hub in
`key` order takes its best free partner — transistor-like first, then by key
— never a pin of its own device, and never a pin whose device a straight
edge along the other axis already joins to the hub's (two such edges cannot
both stay straight, L2; that pin is left for a bend, W7). Each pair becomes a
straight edge. Partners left over are **unpaired** and belong to the first
hub.

**Step B — unpaired pins (W3, W2).** An unpaired pin taps the first straight
edge of *n* perpendicular to it that does not end on the pin's own node, if
the net has one; otherwise it becomes one more straight edge from its hub
(the hub fans out, §4 turns it into a bar), unless W1 forbids that edge.

**Step C′ — junctions first.** A junction's back pin taps a perpendicular
straight edge of another piece, else turns a corner with a lone pin facing
perpendicular to it.

**Step C — wired pieces (W7, W6).** Two pieces that hold pins of one device
are joined by a bend around that device. A piece with a vertical straight
edge and one with a horizontal straight edge are joined by a cross — never
through a junction's fan, which meets the net only through its back pin.

**Step D — lone pins (W7, W4, W5).** For each pin with no straight edge and no
tap, in pin order, while *n* is in more than one piece: a bend to another pin
of its device in another piece (perpendicular first); else a tap onto a
straight edge of another piece perpendicular to it; else a corner with a lone
pin of another piece facing perpendicular to it.

**Step E.** Step C again. If *n* is still in more than one piece, W9.

| id | pattern (pins of one net, with their sides) | result | example netlist | test |
|----|---------|--------|---------|------|
| W1 | one pin facing down and one up (or right/left), on two devices | one straight edge; at most one between two devices across both axes | `Rd vdd out`, `M1 out in 0 0` (net out); `M0 out out in 0`, `M1 a out out 0`: m0.d–m1.g straight, m1's gate joins by a bend | W1 ×2 |
| W2 | one pin against *k* facing pins, and no straight edge of the net perpendicular to them | *k* straight edges from the hub | tail: `M1 … tail`, `M2 … tail`, `Iss tail 0`; a supply over two loads | W2 |
| W2 | several against several | matched one-to-one; a device never pairs with itself | Sallen-Key `out`: C1 and E1's output face right, E1's − and the leaf face left | W2 (matching) |
| W3 | step A left a pin unpaired and the net has a perpendicular straight edge | the pin taps that wire | two-stage `out`: M6 pairs with M7, CL taps the Cc→out line | W3 |
| W4 | a pin with no facing partner, the net has a straight edge perpendicular to it, not ending on the pin's node | tap | CS stage: the out leaf taps the Rd–M1 wire | W4 |
| W5 | two lone pins facing perpendicular ways | corner | common gate: the in leaf (right) and M1's source (down) | W5 |
| W6 | a vertical and a horizontal straight edge of the net in different pieces | cross (the horizontal wire passes through the vertical one) | two-stage `out`: M6–M7 and Cc–leaf | W6 |
| W7 | two pieces holding pins of one device | bend around the device | diode-connected transistor (OTA `x`); BJT base–collector (bandgap) | W7 |
| W8 | a bias net | not wired: every pin gets a label | `vb` in every stage with a current source | W8 |
| W9 | pieces none of W3–W7 can join (e.g. only parallel same-facing lone pins) | every unnamed piece is named (§6) | three gates on one net: `M1 d1 g 0 0`, `M2 d2 g 0 0`, `M3 d3 g 0 0` | W9 |
| W10 | a net with one pin | no wire; the pin's end gets a no-connect mark (×) | `C1 vdd nc 1p` | W10 |
| J1 | an input or output leaf is the only pin facing ≥ 2 pins, no facing pair on the other axis | a junction bar before the group; the leaf is wired to its back pin | CMOS inverter `in`; the non-inverting amp's `out` (op-amp output and Rf) | J1 ×2 |
| J2 | ≥ 2 pins facing one side on devices in one stack, nothing facing them | a junction bar before them; its back pin joins the net (Step C′) | each stage's gates in `ring_oscillator` | J2 ×2 |

## 4. Supernodes

An **attachment** of a node is a straight-edge end or a pin without straight
edges, on one side of the node.

| id | pattern | rule | example | test |
|----|---------|------|---------|------|
| S1 | a device with more than one pin on a side | the node becomes copies chained perpendicular to that side (left/right overloaded → a vertical chain, up/down → horizontal), one attachment per copy; the copies share the device's other pins | op-amp: ctrl+ and ctrl− both left | S1 |
| S2 | one pin with more than one straight edge (a hub, W2) | the same, one edge per copy; the symbol stays on the middle copy and draws the pin as a bar through the copies | tail current source under a pair; the supply rail | S2 |
| S3 | an even number *n* of attachments on the overloaded side | *n + 1* copies, the original node in the middle, the middle slot left bare; with *n* odd, *n* copies | a rail over two loads has 3 copies | S3 |
| S4 | the device's other attachments | across the chain (the side parallel to the overloaded one): centred, skipping the middle when even; along the chain: on the end copies; an end copy that becomes overloaded splits again | the tail transistor's gate sits on the left end copy, its source on the middle one | S4 |
| S5 | a rail's or junction's chain drawn bent after a layout (its attachments' key order disagrees with where their partners landed) | its copies are interchangeable: the attachments are re-dealt to them in the order of their partners' positions, and the layout runs once more. Also before L4 lets a join give way: when the chain's order shares a cycle with the join, the levels are computed once without that order and the copies re-dealt by them; the layout reruns (a bounded number of times) and only then does a join give way. A copy left with nothing attached after a wire gives way leaves its chain (spliced out, or the chain shortened) | `Vx p q`, `R1 vdd p`, `R2 q in`, `I1 vdd q`: keys put I1 first, but R1 lands left of it | S5 |

A pin with one straight edge lives on the copy where its edge ends; a hub pin
lives on the middle copy. A junction's back pin is its one attachment on the
far side, so it sits on the middle copy (S4): the stub leaves the bar's
middle.

## 5. Layout

Every node gets an integer cell (column, row). Everything is relative: rows
and columns are equivalence classes, positions are longest paths over order
constraints.

| id | pattern | rule | example | test |
|----|---------|------|---------|------|
| L1 | a straight or chain edge *a*→*b* | chains, then horizontal, then vertical edges merge the ends' rows (horizontal) or columns (vertical); order: *b* is right of / below *a* | Rd and M1 share a column; the in leaf shares M1's row | L1 |
| L2 | merging would put two nodes on one cell | the edge is not merged and is drawn with a bend | `R0 b in`, `M1 c out out vdd`, `M2 in out in 0`, `M3 in b out vdd`, `M4 out b a vdd` (the one case in 40 000 random netlists of up to eight devices since W1) | L2 |
| L3 | a join | *tap*: the wire lies on the pin's side, and the pin's node strictly between the wire's ends; *corner*: each pin lies on the other's side; *cross*: each wire passes strictly between the other's ends; *bend*: nothing | the out leaf lies right of the Rd–M1 column and strictly between their rows | L3 |
| L4 | a join constraint on a cycle of order constraints (a strongly connected component), or contradicting a merged row/column | S5 re-deals any rail or junction whose chain order is on the cycle; if the cycle remains, the join gives way (§6); on a cycle, a join running against the flow first | `Rin in n`, `R1 vdd n`, `M1 n out 0 0`, `Rx n out`: the cross on `n` needs Rx right of M1, `out` puts it left; the ring oscillator's loop-back `c` | L4 ×2 |
| L5 | a cycle made of edge constraints only | one constraint is dropped (a DFS back edge) and its edge is drawn with a bend | two shorted devices `C0 a a`, `C1 a a`: each sits above the other; also two floating resistors in parallel written in opposite pin order (`R0 b a`, `R1 a b`), which no path flips into line | L5 |
| L6 | two nodes on one cell; a wire through a node; two nets' wires on one line; a name of three or more characters running into a node | separation: order the two classes by key (nodes: columns if in one row, else rows — but a terminal or label keeps to its partner's side of the other node, so it stays beside what it is wired to; a wire on a grid line: its row/column class against the node's; a bend or bar: the node against the wire's device, rows first). A name's cell is kept free by moving the node one more column out (a gap of 2), else to another row. Repeated until nothing clashes, or until a request asks for an order already there (no order can satisfy it: a wire through a block's box), which L7 then judges. One clash or name per round; in a drawing of more than 256 nodes, or past 256 rounds, every clash and name of a round at once (at most one per row or column class), so many independent pieces take a number of rounds linear in their count, not quadratic. | two unrelated resistors; the two-stage's second stage moves right of the mirrored input; the telescopic cascode's two stacks stay level | L6 |
| L7 | after separation: two nets' wires cross, overlap, or touch, or a wire runs through a node, and the classes can't be separated | a wire involved gives way (§6); lay out again | bandgap `x`, `y`; telescopic `outn` gate taps; `M0 c in a 0`, `R1 c in`, `R2 a c` (a straight edge gives way) | L7 ×3 |
| L8 | a class with no predecessor | it sits right before its nearest successor; a terminal leaf's keys are its partner's ±1, a label's its device's ±1 | the `vb` label sits one column left of the gate it biases | L8 |
| L9 | after L7: a wire through or onto another net's point — a pin, a wire's end or bend (a netlister joining by touch, xschem, reads it as a short; L7's checks see only ends strictly inside a wire) | lay out once more from there, with three more rules: neighbouring rows and columns keep their facing pins `clearance` apart; a wire running along its own row or column through a node moves an end past it (a leaf's end, it follows its partner; else the far end); such a contact blames its wires as L7 does. Only a drawing that has one: every other drawing is laid out as before. What still touches is drawn as names (§7) | `C0 in a 1p`, `M1 out 0 c 0 nch`: the `in` and `out` wires turn their corners at one point | L9 ×2 |

### Geometry

Rows and columns fix the order of everything; the space between neighbouring
rows (columns) is chosen afterwards, gap by gap, as the widest thing in the
gap needs, and never less than `min_pitch`. Coordinates are in the target's
integer units; the settings are in *units*, one unit being the library's
`unit` (a two-pin symbol, pin end to pin end: 40 in the tests' symbol set),
rounded up to whole target units. Every coordinate is a whole number, so
equal lines compare equal exactly in every build mode.

A device's node is the point where its row and column lines cross: the x of
its up/down pins and the y of its left/right pins, placed. Its **reach** on a
side is how far its pins on that side stand from that point — from the class
geometry, not assumed.

| thing in the gap | needs | setting (`.layout`) | default |
|---|---|---|---|
| any two neighbouring rows or columns | the pitch | `min_pitch` | 1 |
| a straight edge between two devices, vertical | its reach + the wire + its reach | `stack` | 0.25 |
| a straight edge between two devices, horizontal | the same | `series` | 0.25 |
| a straight edge from a device to a supply or ground | the same | `rail` | 0.5 |
| a straight edge from a device to an input or output | the same | `terminal` | 0.5 |
| a straight edge from a device to a label | the same | `label` | 0.5 |
| a straight edge to a junction | the same | `junction` | 0.5 |
| a tap, or a corner, from a pin to its wire | reach + the wire | `tap` | 0.5 |
| a bend (W7) or a bent edge (L2, L5) leaving a pin | reach + the stub + room + the next symbol's half size | `bend`, `clearance` | 0.25, 0.2 |

Only straight edges between neighbouring levels constrain a gap (a longer
one is long anyway). The lengths are what the settings file changes; the
routing costs of the rules above are not settings.

## 6. Giving way, and naming

This is the answer to *when a net is a label and when it is a wire*: a net is
wired wherever the rules above can wire it, and labelled exactly where a wire
**gives way** — W8, W9, L4, L7.

**Who gives way** (L4, L7), among the wires to blame:

1. Joins before straight edges, whatever their nets: a straight edge only
   gives way once no join is to blame anywhere.
2. On a cycle (L4), a join with a constraint against the flow — one that
   needs a node that comes later by key before one that comes earlier, a
   feedback wire — before one along it.
3. The net with the highest role rank (supply and sink 0, input and output 1,
   internal and bias 2), then the fewest straight edges (a net made only of
   joins is all cross-links), then the later net.
4. Within that net, the latest wire.

Never: a rail (a terminal leaf's chain) and a label's own stub — the stub *is*
the label. A fan bar is blamed through its pin's edges.

**What goes.** A join gives way together with every other join of its net —
a net's cross-links go together — except the net's same-device bends and the
join attaching its terminal leaf, which stay unless they are the one to blame.
A straight edge gives way with the joins that meet the net on it (a tap onto
it, a cross through it): they would be drawn to where the wire was, ending in
the open, and the pin they carried is named instead.

**Naming.** After W8, W9 or a give-way, every piece of the net (pins connected
by straight edges and joins still in force) that carries no name gets one. A
name is the terminal leaf, a label node, or an annotation. A piece with a
straight edge gets an annotation on it; otherwise a label node hangs on a pin
with nothing attached (else on a pin with no straight edge), facing it.

Every round removes one wire that can never come back, so the loop ends.

## 7. The result

The library draws nothing: `Placed` says where everything went, in integer
coordinates, and a target draws it (`tests/svg.zig`, the TikZ emitter, a C
consumer).

- **Devices.** A drawn device's class sits with its origin where its node's
  grid point says, placed by its `Orient`; every card pin is at its
  terminal's placed anchor. An S1 device's symbol sits on its middle copy.
- **Wires.** Every route is a polyline of its net: straight edges, joins, S2
  bars, rail and junction chains. Where a class's pin is not on the line the
  layout routed to (the second input of an op-amp, split onto its own copy;
  a pin on an S4 end copy off the copy's line), a short lead joins the two,
  along the pin's side first — every wire ends exactly on its pin. Along
  its own side's axis a pin is routed from where the symbol has it (the
  middle copy's reach), so the layout's crossing checks see every lead.
- **Terminals.** Each terminal leaf becomes a device of the library's class
  for its role (`power_rail`, `ground_rail`, `input_port`, `output_port`),
  unnamed, its net on its one pin; with no such class, a label.
- **Junctions.** A net's polylines are split at every point where another of
  its wires meets them (a dot, a tap), so each piece ends on the junction —
  tools that connect only at ends (xschem) see the same net.
- **Drivers (R3).** Each driver stands apart, left of the circuit and in
  netlist order: its terminal net's symbol on top, the source upright (the
  pin on that net up), a ground symbol below. A simulator's schematic keeps
  its sources; the circuit keeps its terminal symbols.
- **No wire on another net's point.** A wire still running through or onto
  a point of another net after L9 — a pin, a MOS body past the symbol's
  terminals (at the device's origin, where a target that draws one puts
  it), a wire's end or bend, a label — is a label's stub or a rail, which
  never give way. It is left out, a label's stub first (its name then sits
  on the pin), and its net is read again as a netlister reads it: a piece
  left with no pin goes too, and when more than one piece is left, each
  unnamed one is named on a pin. Repeated until no wire touches; each
  round removes a wire.
- **Names.** Label nodes and annotations become labels (a point, and the side
  the text runs to); a dot marks a point where one net's wires leave in three
  or more directions; a pin alone on its net (W10) is a no-connect point.
  Where each device's name goes is `geom.refdesAnchors`: beside the symbol,
  above or below that, then the other side, clear of symbols, wires and the
  names placed before it.

## 8. What is guaranteed, and what is open

Checked by the tests:

- **Every textbook circuit** (`textbook.all`, 14 circuits) draws with no
  crossings, overlaps, bent edges or order conflicts; labels appear only for
  bias nets (W8) and the bandgap's gate line (L4; its x/y taps stay wired
  after S5 re-deals the vdd chain).
- **Deterministic**: the same netlist gives the same drawing, in every build
  mode (coordinates are exact, §5).
- **Wire lengths** follow `.layout`; changing them moves nothing to another
  row or column.
- **For random netlists** (150 in the test, 4000 in `fuzz.zig`): the layout
  ends, no two nodes share a cell, and every net is one wired piece or has all
  its pieces named.

By construction, a crossing or overlap that remains involves only wires that
never give way (rails and label stubs). In `zig build fuzz`'s sample (4000
random netlists of 2–6 R/C/MOS on seven nets, seed 12345, drawn with the
tests' symbol set) 82 end with such a crossing and 15 with an overlap; none of
the textbook circuits do. 47 have a wire on another net's point after L7:
L9 lays 32 out with none left, and in 15 one stays, drawn as names (§7). The same run supplies the smallest netlist for each
rarely triggered case (L5, L7, S5); L2 occurs once in 40 000 (W1).

Also checked (`tests/api.zig`): in every textbook drawing each pin with
company on its net lies on a wire, a label or a symbol of that net, and every
netlist device is in the result exactly once. Every net is **one piece** as a
netlister reads the result — wires meeting at their ends, a pin joining the
wire that ends on it, a label the wire it lies on, the net's labels and port
and rail symbols joined by name — in every textbook drawing, the example
decks, a StrongARM latch, a nine-port block and 1000 random netlists. And
**no wire touches another net's point** (a pin, a MOS body, a wire's end or
bend, a label) in any of them, nor in AnalogIOC's decks
(`tests/fixtures/analogioc`) or the fuzz sample.

**Layout work** (`Stats.rounds`, the level assignments of all passes) grows
with the drawing: ten blocks on a shared output and rails take 343 rounds
for 73 nodes, forty take 3222 for 283 (`L6 many blocks on shared nets…`).

Open cases (`textbook.beyond`):

- **A loop-back net becomes a label** — the ring oscillator's `c` runs from
  the last stage back to the first, against the flow; it gives way (L4) and
  is named at both ends. The book routes it around the stages.
- **A piece a longer route could reach becomes a label** — Sallen-Key's C1 is
  labelled `out` rather than routed around to the output node. This is the
  rule working as specified: labels, not routing.
- **Crossings between rails and label stubs** cannot give way (above).
- **A symbol with two inputs a pitch apart gets leads.** The op-amp's inputs
  land on copies at least `min_pitch` apart; when the symbol puts them
  closer (or the pitch grows), short leads join the two (§7).
- **An op-amp off the signal path stands upright** (O5), as in the bandgap.
  Keeping it horizontal there broke the bandgap's layout; turning a block's
  inputs to its top and bottom is legible, not textbook.

## 9. Test index

| case | test in `cases.zig` |
|------|---------------------|
| R1–R3 | `R1 roles by net name`, `R2 a net driven from ground…`, `R3 drivers of terminal nets are not drawn`; in `tests/api.zig`, `placed: a driver stands apart…` |
| O0–O9 | `O0 hidden pins…` … `O9 differential pair…`, and `O8 not for stacked devices…` |
| W1–W10 | `W1 pair…` … `W10 a dangling pin gets no wire`, `W2 several against several…`, `W1 two devices share at most one straight wire` |
| J1, J2 | `J1 an input or output that would fan out…`, `J1 not for rails…`, `J2 same-facing pins of one stack…`, `J2 not for devices side by side` |
| S1–S5 | `S1 several pins on one side…` … `S4 other pins…`, `S5 a rail's copies follow…` |
| L1–L9 | `L1 straight edges share…` … `L8 leaves and labels sit beside…`; L7 has three: a join crossing, a net keeping its terminal, a straight edge; `L4 a cycle breaks at its feedback wire`; `L6 many blocks on shared nets…` (layout work); `L9 a wire left on another net's point…`, `L9 a contact no layout avoids…` |
| Geometry | `geometry: wire lengths come from the settings…`, `geometry: every coordinate is a whole number of the target's units`, `geometry: a bend keeps clearance…` |
| suite | `textbook: every circuit draws…`, `textbook: layout is deterministic`, `random netlists: terminate…` |
| result | `tests/api.zig`: the tiers agree, `Placed` is well-formed and loses no device, every net is one piece (`expectConnected`), no wire on another net's point (`support.shorts`), leads, generated boxes; `tests/abi_test.c`: the C ABI |

Run with `zig build test` (the library's own tests, `tests/cases.zig`, `tests/api.zig` and the C program `tests/abi_test.c`); `zig build fuzz` runs the random sample.
