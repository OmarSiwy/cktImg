# Layout Algorithm

## Core idea

A **spine** is a single conduction path from VDD to GND, passing over every
device in the order they're connected. A circuit decomposes into *N* spines.

Each spine gets its own **column**, and its devices are stacked vertically in
that column. Layout is then two problems: placing devices inside a spine, and
wiring between spines. Two spines may share devices — see [Shared devices](#shared-devices).

**Power rails.** VDD and GND span all spines as **rails** (preferred at the
top and bottom of the layout), drawn once — never routed as per-net wires or
staples. If a rail can't be drawn cleanly, it falls back to **lab pins**.

Most of the hard information is **precomputed during netlist reading** rather
than discovered as routing conflicts later. The sections below note what gets
precomputed.

---

## Precompute (what's resolved when)

Each quantity is resolved at the **earliest tier it belongs to** and carried
forward — never rediscovered as a routing conflict. Three tiers, by what the
quantity depends on:

**Tier A — topology-invariant.** Pure functions of the netlist graph; identical
for every column order. Computed **once at netlist read**, in the `Ctx` query
layer (not the IR — the IR stays constraint-free), and reused across every
candidate order:

| Quantity | How |
|---|---|
| net degree | `degree(net) = |pins on net|` |
| conducting pins | `conducting_pins(dev)` = the device's terminals that carry current (drain/source, not gate). Stored as a **CSR** — one flat pin array + per-device offsets — so a lookup returns a slice, never a fresh allocation. |
| shared device | `branch_count(dev) = #splines through dev`; `dev` is shared ⇔ `branch_count ≥ 2` (drives N=2 own-column / N>2 anchor). Invariant because the spline *set* is fixed — only its order is searched. |
| net class, pin→device, ground-distance | as today |

**Tier B — order-dependent, route-invariant.** Unknown until a column order is
chosen, then fixed without drawing a wire. Computed **once per candidate order**,
before routing: column assignment, orientation (gate points left iff its gate net
has a pin in a column `< this device's`), net case (within-spine / immediate /
span ≥ 2), smallest-window staple order, track packing, and `optimal_len` (see
[Wire length](#wire-length-spacing-between-devices)).

**Tier C — geometric.** Depends on chosen y-positions and actual paths;
*measured* after placement, not guessed: real `Rect::intersects` collision,
crossing counts, junction dots.

The split is the safety argument. A is computed once and cannot drift; B is one
deterministic pass per order with no feedback loop; C is the only place real
geometry is consulted — and even there, channel width is a **conservative forward
reservation**, not a measurement of the final route: for a gap, reserve one track
of room per net *classified* to cross it (a count available pre-route, see
[Wire length](#wire-length-spacing-between-devices)). A route therefore always has
somewhere to go — no unwire-then-rewire anywhere.

---

## Device orientation

A MOSFET's gate can point left or right. The rule:

- **Default:** gate points right, toward the next spine.
- **Exception:** if the gate's net comes from a spine on the *left* (an
  earlier spine), the gate points left toward it.

So orientation is decided by looking at the gate net's source.

---

## Intra-spine device reordering

Two series devices in a spine may be **swappable** without changing the
circuit: same type, same W/L, and connected drain→source (or
source→drain) in series. The placer detects these pairs by pattern-matching
device parameters in the IR and tries both orders inside the existing
column-order search.

The win is rare but near-zero cost: swapping may align a gate tap with a
neighbor spine's pin, saving a crossing or staple. Detection is Tier A
(topology-invariant); the swap itself is a list reverse on two elements,
evaluated by the same lex key.

---

## Wiring

### Connection classification

Not every inter-spine connection routes the same way. Classify first:

- **Power rails (VDD/GND)** — drawn as rails (or lab pins), never staples.
- **Adjacent gate-ties** (diff-pair load, mirror) — immediate-neighbor
  horizontal wire ([subcase B](#between-immediate-neighbor-spines)).
- **Forward inter-stage signal** (e.g. stage-1 Vout → stage-2 gate) — local
  horizontal wire at the output node's y, between adjacent spines.
- **Backward feedback** (e.g. Miller cap) — the *only* connection that earns a
  long route in the top margin.

The top margin carries **backward feedback only**. If rails, gate-ties, or
forward signals land in the margin, that's a misclassification — not a
dense-but-correct result. A clean diff-pair input stage has **no** margin wires.

The engine derives each net's electrical direction from terminal roles and
columns (`net_is_backward`: a net is backward feedback when a conduction pin —
an output — sits in a column to the *right* of a gate it drives). The geometric
case (within-spine / immediate / span ≥ 2) still decides the *route*; direction
is a **check on top of it**: a span-≥2 net that lands in the margin but is *not*
backward feedback is reported loudly as a margin misclassification, so the
"backward feedback only" invariant is observed, not merely asserted. (The route
itself is not yet re-derived from direction — a long forward signal that the
column order failed to keep adjacent still draws as a margin staple, but it no
longer does so silently.)

### Within a spine (intra-spine)

The only intra-spine wiring is a **feedback loop** — e.g. a diode-connected
MOSFET or BJT. Handling is trivial: route a Manhattan wire that doesn't overlap
the device. No fallbacks.

```
| <pin>---------|
|               |
| <device> <pin>|
```

### Shared devices

A device shared by *N* branches is placed by branch count.

**N = 2 (special case):** the shared device gets its **own column** between the
two branches:

```
Spine 1 (col 1)  |  Shared devices (col 2)  |  Spine 2 (col 3)
```

Connect Spine 1 (bottom) → shared (top) and Spine 2 (bottom) → shared (top)
with Manhattan wiring, no fallback. (First-stage op-amp is the motivating case.)

**N > 2:** no new column. Pick the **optimal anchor spine** — the branch
whose column minimizes `sum(|anchor_col - branch_col|)` over all branches —
and keep the shared device on it, **as part of the spine itself**, at its
conduction position in that spine (for a tail source that's the ground end —
the bottom — but the rule is conduction order, not "always bottom"). The
remaining branches reach it via the fan bus.

```
Spine 1  |  Spine 2 (anchor)  |  Spine 3  |  Spine 4
                ...                                          
          [shared device]  ←── fan bus ──┴──────────┘
```

This is deterministic by construction — symmetric (mirrored) placement around
the shared device is *not* attempted; the anchor is the span-minimizing
branch (Tier A: depends only on column assignments, computed once per
candidate order).

### Between immediate-neighbor spines

Each spine is first built independently. To wire two neighbors, ask: *can we
shift one spine (whichever doesn't disturb others) so the connection is a
single horizontal line, no bends?*

The answer is **yes whenever the spine is unlocked** — and processing spines
sequentially keeps them unlocked, with one exception below.

**Non-immediate connections free up movement.** If spine 1 connects directly
to spine 3 (skipping 2), that locks spine 3. But the spine1→spine3 wire is
*not enclosed*, so spine 3 can still slide up/down to satisfy spine 2's
horizontal-line request — spine 1 stays satisfied either way. No blockers.

> **Precompute it:** satisfy all immediate connections first, then the
> non-immediate ones — one pass, no unwire-then-rewire.

### Between non-immediate spines

The deepest case. Three strategies, in priority order, with **loud, printed
fallbacks** so the user knows what happened.

**1. Direct horizontal routing.**
If an uncongested horizontal path exists from any point on the net to the
target (which may be a pin *or* a net — sweep all path combinations), use it.
Otherwise fall back to (2).

**2. Manhattan (rectangular) path.**
A rectangular route, not a polygon:

```
stub → vertical → (left|right) → (up|down) → (left|right) → (down|up) → stub → vertical
```

(The route may attach to a spine before *or* after the target — that's why
this runs last: entry and destination spines are the most congested.)

This is the only option. Two conditions threaten it; in practice the column-order
search resolves both, so a label (3) is a genuine last resort, not the common path:

- **Crossing overlap.** A spine1→spine3 path and a spine2→spine4 path overlap;
  spine1→spine4 with spine2→spine3 *nests* cleanly. Handled two ways at once:
  **order non-immediate connections smallest-window-first** (a wide 1→4 span sits
  in an outer margin track and never blocks a narrow one inside it), and the
  remaining real crossings are **counted on the drawn geometry** (`num_crossings`)
  and **minimised by the order search** — overlapping staples stack on distinct
  margin tracks rather than forcing a label.
- **Blocked exit.** A vertical riser that would run through a device body is a
  real collision: it is **counted via `Rect::intersects` against every device box**
  (`num_body_hits`, second in the selection key) so the search prefers an order
  whose risers route clear. A residual collision that no order avoids (e.g. a
  single-spline circuit with no alternative order) is **reported loudly**, not
  drawn silently.

> **Spacing depends on this:** the gap between spines (and between devices)
> must leave room for a stub to run a vertical line up/down — otherwise there's
> no path out. Precompute the required spacing for the chosen route.

**3. Net label fallback.**
Drop a net label and move on.

### Bridge devices (two-terminal non-spline components)

A non-spline device with exactly two conducting terminals whose nets both
resolve to existing columns is a **bridge**. Detection is purely topological —
it applies to passive devices (resistors, capacitors) AND active ones (a
MOSFET whose drain and source connect to known nets). The gate of a MOSFET is
a control pin and does not participate in the bridge test, but it still
influences routing and orientation once the device is placed.

Bridge placement depends on which columns the two nets resolve to:

**Cross-column bridge (a ≠ b).** The device connects two different spines.
It gets its own column inserted between them, at position `max(a, b)`:

- `|a − b| = 1` → `Component` column (immediate-neighbor bridge, e.g. the RC
  in an op-amp compensation path).
- `|a − b| ≥ 2` → `Feedback` column (non-immediate bridge, positioned in the
  backward-route margin band).

Passive bridge devices are laid **horizontally** (no power-in/power-out, so
vertical stacking doesn't apply). Active bridge devices (MOSFETs) are
**oriented vertically** using the same gate-direction rule as spline devices.

Example (op-amp): first-stage output feeds a parallel R∥C. Split the wire at
the R/C input pin axis. Design these devices to the **same width** so their
output pins are vertically aligned too (in case they recombine). They have two
aligned axes instead of one.

**Same-spline satellite (a = b).** The device bridges two nets that both live
on the *same* spline column — a load component hanging off an output node
(push-pull R∥C), or a local-feedback amplifier (gain-boosted cascode's `Ma`).

Satellites are stacked in a single `Component` column inserted **after** the
parent spline column (position `a + 1`), not before it. Multiple satellites on
the same spline share one column. The resulting nets span exactly two adjacent
columns (parent spline and satellite), so they classify as
`ImmediateNeighbor` and route as short horizontal wires.

```
Spline col (m1, m2)  |  Satellite col (R1, C1)    — push-pull
Spline col (m3, m2, m1)  |  Satellite col (Ma)    — gain-boosted cascode
```

### Device inside a feedback loop

A feedback loop may contain a **device**, not just a wire — the Miller cap is
the canonical case (it sits *in* the backward path between two internal nodes),
and the gain-boosted cascode's `Ma` (an active MOSFET sensing one internal
node and driving another) is a second. Both are detected by the bridge test
above: two conducting terminals connecting to known column nets.

- **Cross-column:** the [bridge case](#bridge-devices-two-terminal-non-spline-components)
  above — give it its own intermediate column.
- **Same-spline:** the [satellite case](#bridge-devices-two-terminal-non-spline-components)
  — place it in a column after the parent spline.
- **Non-immediate:** place the device at the **center of the feedback's
  horizontal run** (in the backward-route band) and **split the feedback wire**
  there: endpoint → device → endpoint, two segments with lengths recomputed
  around the device. Collision-box spacing still applies.

---

## Wire length (spacing between devices)

How long is the wire between two vertical components in a spine?

The deciding factor is **how many connections the net has.** A net is connected
to the device above, the device below, and *possibly* a device further down in
the same spine (via gate / feedback). So:

```
optimal_len = N − (pins in the same column) − 1
```

The `−1` subtracts the direct conduction link between the two stacked neighbors
— that connection IS the stacking, not an external tap that needs room. A wire
of `optimal_len` satisfies the spine's wiring-length need. Precompute this per
net so every spine is optimally wired. **If `optimal_len = 0`, the devices
abut.**

**Extra spacing for non-immediate connections.** When two non-immediate spines
connect, a stub must emit a clean vertical line straight up/down through the
gap. So:

- Every device gets a **collision box** around it.
- The space *between* boxes must be precomputed to fit that stub.
- Routes may exit a spine from the **front** (mandatory for spine 1) or the
  **back** (allowed for intermediate spines, mandatory for the last spine),
  and enter the destination from front or back. Decide the exit/entry side
  **pre-route** so the right area has enough room.

**Collision is checked strictly — no approximation.** Spacing is *not* a base
allowance (no single `CH_BASE`-style constant standing in for clearance):

- Every routed wire is collision-checked on the **drawn geometry**, not a
  bbox-only vertical-stacking check: against device boxes via real rectangle
  intersection (`Rect::intersects` → `num_body_hits`), and against other wires
  via real segment crossing (`num_crossings`). Both are real faults in the
  selection key, so the order search routes away from them.
- Each staple endpoint **exits on a side** (front = left, back = right), chosen
  pre-route from the pin's position on its body — a pin on the body's right edge
  exits back, left edge exits front, an on-axis pin exits toward the run (spine 0
  front, last spine back). The riser then descends in the **adjacent channel**,
  never on the spine axis, so it clears the spine's own stacked bodies. Lanes are
  reserved **per (column, side)**, one wire gauge each, and the channel width is
  the sum of those reserved lanes (below). A residual crossing of a *horizontal*
  device (a rail symbol or a margin-resident feedback device) is metered and
  reported (above), not hidden.
- Inter-column channel width is the **sum of reserved riser room + crossing
  wires** for that gap — computed from the classified routes, not a fixed base:

  ```
  channel(gap) = track_w × max(1, wires(gap))
  ```

  where `wires(gap)` = the immediate-neighbor wires plus the spanning staples
  (and their endpoint risers) reserved in that gap, and `track_w` is **one wire
  gauge**. The `max(1, …)` floor is that single gauge — the physical minimum for
  a stub to run a vertical line — *not* a clearance constant: an empty gap
  reserves exactly one wire's width and nothing more. There is no `CH_BASE`.

---

## Selection and determinism

Spine extraction fixes the *set* of columns but not their left-to-right order.
The placer **enumerates column orders** and evaluates each in one pass, then keeps
the best by a **lexicographic integer key** (never a weighted cost):

```
key = (num_labels, num_body_hits, num_crossings, num_staples,
       total_span, margin_tracks, netid_seq)
```

Lower is better, compared left-to-right: avoid a dropped-to-label net first, then
a wire through a device body, then wire-vs-wire crossings, then staple count and
span, then margin tracks; `netid_seq` is a final deterministic tie-break so the
output is byte-reproducible. Enumeration is full (all `n!` orders) up to
`enum_limit` splines (default 10 → 3 628 800, sub-second on modern hardware);
beyond that the placer uses a **greedy nearest-neighbor heuristic**: start from
each spine in turn, always place the spine with the most connections to
already-placed spines next, evaluate each starting order with the same lex key,
and keep the best. Same evaluation function, same key comparison — no special
case, just a smaller search space. The first three key terms are the live collision
budget — `num_body_hits` and `num_crossings` are measured on the **drawn
geometry**, so the search routes away from real overlaps, not modelled ones.

## Other structural cases

- **Rail-less circuit.** A conductor touching no power/ground rail (a pass
  transistor / transmission gate) yields no spline; it becomes a **signal-series
  column** and the circuit places with no rails at all.
- **Junction dots.** A connection dot is emitted only where **≥3 same-net wire
  arms meet** at a point (a segment endpoint = 1 arm, a segment passing through
  the interior = 2, a device pin = 1). Two arms is a corner or a wire reaching a
  pin — no dot. Different-net wires never share a net's arm count, so a pure
  crossover gets **no dot** and correctly reads as *not connected*.

## Test cases

These exercise the routing primitives. Built bottom-up in difficulty.

### A. Single spine (vertical slice / sanity)

| Case | Stresses |
|---|---|
| Diode-connected device | Pendant leaf, fixed stub. Trivial — the floor. |
| Common-source amp | One spine, 2 inter-spine taps (gate in, drain out). Basic slice. |
| CS + current-source load | 2-device spine, load gate = bias (label-vs-spine decision). |
| Cascode (telescopic) | Tall spine + mid-stack gate tap → wire to a non-endpoint y. |
| Source-degenerated device | Passive in the conduction chain, extra series node. |

### B. Two-spine / cross-coupled (cycles, μ > 0)

| Case | Stresses |
|---|---|
| Simple current mirror | Cross-spine gate net (tap each gate at matched y), ref-diode cycle. Wants pair adjacent. |
| Cascode current mirror | 2 cross-gate nets at different y → channel load in one gap. |
| Wilson mirror | μ > 1 feedback, gate net spanning branches. |
| Cross-coupled pair (latch core) | Mutual gate↔drain across two spines — hardest cycle, two backward edges. |

### C. Shared-node / branching conduction

| Case | Stresses |
|---|---|
| Differential pair | Shared tail node joins two spines at one point; symmetry (out of scope — must not break). |
| Tail current source | One drain feeds N spines = branching conduction — spine isn't a line. |
| 5T OTA (diff pair + mirror load) | Integration test: shared tail + mirror cycle + side-to-side mirror cross-over, all at once. |
| Push-pull / Class-AB output | Same-spline satellite: load R∥C bridges two nets on one spline → satellite column after the spline. |

### D. Multi-stage / long feedback (channel + column-span)

| Case | Stresses |
|---|---|
| Two-stage Miller amp | Miller cap = device split into the backward feedback run; only this net is a margin wire. Input stage (rails + gate-ties + forward Vout) stays local — clean, no margin clutter. |
| Gain-boosted cascode | Active satellite: feedback MOSFET (`Ma`) bridges two nets on the main spline; detected as a same-spline bridge, oriented vertically. |
| Stacked bias string | Many taps off one spine → fan-out room, varied horizontal spans, heavy channel load. |

### Routing primitives to nail directly

1. **Mid-stack tap** — connect to a non-endpoint y on a spine (cascode gate). Z/wrap territory.
2. **Net cross-over** — two nets must cross → perpendicular crossing / junction-dot semantics (OTA mirror load).
3. **Shared node → N spines** — branching conduction; "spine = a line" breaks. N=2 gets a shared column; N>2 anchors to the first branch (see [Shared devices](#shared-devices)).
4. **Long backward feedback** — Miller/two-stage; tracks across many channels → overflow → label.
5. **High fan-out net** — bias/output; needs exit room + channel width.
6. **Matched/symmetric pair** — diff pair, mirror; out of scope, but must degrade gracefully, not crash.
7. **Bridge between two internal nodes** — Miller cap (passive) or gain-boost amp (active); detected by the two-terminal bridge test and placed as cross-column or same-spline satellite.

### Known gaps

- **Symmetry:** matched structures want mirror placement, deferred. N>2 fan
  branches anchor to the first branch rather than placing symmetrically around
  the shared device — deterministic, but not mirror-consistent.
- **Channel overflow:** only the two-stage Miller loads a channel hard. It's the
  overflow→label test.
