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

## Device orientation

A MOSFET's gate can point left or right. The rule:

- **Default:** gate points right, toward the next spine.
- **Exception:** if the gate's net comes from a spine on the *left* (an
  earlier spine), the gate points left toward it.

So orientation is decided by looking at the gate net's source.

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

**N > 2:** no new column. Pick the first branch as the **anchor spine** and
keep the shared device on it, **as part of the spine itself**, at its
conduction position in that spine (for a tail source that's the ground end —
the bottom — but the rule is conduction order, not "always bottom"). The
remaining branches (spine 2, 3, …) reach it via the fan bus.

```
Spine 1 (anchor)  |  Spine 2  |  Spine 3  |  Spine 4
  ...                                          
[shared device]   ←── fan bus ──┴──────────┘
```

This is deterministic by construction — symmetric (mirrored) placement around
the shared device is *not* attempted; the anchor is always the first branch.

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

This is the only option, and it has two forced fallbacks to (3):

- **Crossing overlap.** A spine1→spine3 path and a spine2→spine4 path will
  clearly overlap → fall back to (3).
  *But* spine1→spine4 with spine2→spine3 *nests* cleanly. Know this ahead
  of time: **order non-immediate connections smallest-window-first.** A wide
  span (1→4) can sit near the top and block a narrow one, but never the reverse.
- **Blocked exit.** If you can't go up *or* down when exiting the spine
  (collision), fall back to (3).

> **Spacing depends on this:** the gap between spines (and between devices)
> must leave room for a stub to run a vertical line up/down — otherwise there's
> no path out. Precompute the required spacing for the chosen route.

**3. Net label fallback.**
Drop a net label and move on.

### Components between spines (bypass cap / resistor)

For passive (or treated-as-passive) devices bridging two spines — e.g. the
RC in an op-amp compensation path:

- These spines are assumed to be **immediate neighbors** (works either way,
  but expected to hold).
- Treat the bridging devices as their **own spine**: stacked in a column,
  but each device laid **horizontally** (no power-in/power-out, so vertical
  stacking doesn't apply). Active ones use nets for their power in/out, since
  routing horizontal devices vertically is hard.
- They sit purely in the signal path, not the power→ground path, so they act
  as an **intermediate spine** of horizontal devices stacked vertically.
- All [non-immediate routing](#between-non-immediate-spines) rules apply on
  top of this (minus cross-spine movement).

Example (op-amp): first-stage output feeds a parallel R∥C. Split the wire at
the R/C input pin axis. Design these devices to the **same width** so their
output pins are vertically aligned too (in case they recombine). They have two
aligned axes instead of one.

### Device inside a feedback loop

A feedback loop may contain a **device**, not just a wire — the Miller cap is
the canonical case (it sits *in* the backward path between two internal nodes).

- **Immediate neighbor:** it's the [bridging-component case](#components-between-spines-bypass-cap--resistor)
  above — give it its own intermediate spine.
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
optimal_len = N − (devices it connects to within the spine)
```

A wire of `optimal_len` satisfies the spine's wiring-length need. Precompute
this per net so every spine is optimally wired. **If `optimal_len = 0`, the
devices abut.**

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

- Every routed wire and stub is collision-checked against device boxes **and**
  other wires via real rectangle intersection (`Rect::intersects`), not a
  bbox-only vertical-stacking check.
- Each column reserves **per-side riser room** for the staples exiting it, on
  the side they actually exit (front/back, decided pre-route).
- Inter-column channel width is the **sum of reserved riser room + crossing
  wires** for that gap — computed from the actual routes, not a fixed base.

---

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
| Push-pull / Class-AB output | Shared output node, high fan-out, complementary pair. |

### D. Multi-stage / long feedback (channel + column-span)

| Case | Stresses |
|---|---|
| Two-stage Miller amp | Miller cap = device split into the backward feedback run; only this net is a margin wire. Input stage (rails + gate-ties + forward Vout) stays local — clean, no margin clutter. |
| Gain-boosted cascode | Nested local feedback loops, deep μ. |
| Stacked bias string | Many taps off one spine → fan-out room, varied horizontal spans, heavy channel load. |

### Routing primitives to nail directly

1. **Mid-stack tap** — connect to a non-endpoint y on a spine (cascode gate). Z/wrap territory.
2. **Net cross-over** — two nets must cross → perpendicular crossing / junction-dot semantics (OTA mirror load).
3. **Shared node → N spines** — branching conduction; "spine = a line" breaks. N=2 gets a shared column; N>2 anchors to the first branch (see [Shared devices](#shared-devices)).
4. **Long backward feedback** — Miller/two-stage; tracks across many channels → overflow → label.
5. **High fan-out net** — bias/output; needs exit room + channel width.
6. **Matched/symmetric pair** — diff pair, mirror; out of scope, but must degrade gracefully, not crash.
7. **Bridge between two internal nodes** — Miller cap; device split into the [feedback loop](#device-inside-a-feedback-loop) at the run's center.

### Known gaps

- **Symmetry:** matched structures want mirror placement, deferred. N>2 fan
  branches anchor to the first branch rather than placing symmetrically around
  the shared device — deterministic, but not mirror-consistent.
- **Channel overflow:** only the two-stage Miller loads a channel hard. It's the
  overflow→label test.
