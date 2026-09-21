# Lint rules

`src/lint.zig` is a rule table with one `Severity` per rule, and `lint.check` is one
function: hand it the data, get a slice of `Finding`, free the slice. There is no engine
to construct, no registry to populate and no context to keep in sync.

```zig
const findings = try ckt.lint.check(gpa, placed, table, cfg.rules);
defer gpa.free(findings);
```

## Running it: `--lint`

Both front ends take `--lint`. It runs the rule table over the placed schematic and
reports the findings; the severities come from the `.rules` block of the `--config` file,
so there is one configuration channel and not two.

```sh
cktimg-json --lint amplifier.spice > amplifier.json   # findings on stderr *and* in the document
cktimg-json --lint amplifier.spice > /dev/null        # review it, keep nothing
cktimg-json --lint --config team.zon amplifier.spice  # your team's severities
cktimg-tex  --lint amplifier.spice figure.tex         # findings on stderr only
```

Without `--lint` nothing runs, nothing is printed, and the output is byte-for-byte what
it has always been.

### Exit status

| Code | Meaning |
|---|---|
| `0` | Output written; no finding at `err` severity. |
| `1` | The command line, the netlist, the config or a `--target` manifest is bad. Nothing was written. |
| `2` | At least one finding at `err` severity. **The output was still written in full.** |

`2` is separate from `1` on purpose. A CI job has to tell "your schematic is wrong" from
"the tool could not run": the first is reported to the designer and the second to whoever
owns the build. Collapsing them into one non-zero code makes every tool failure look like
a review comment.

`warn` never fails. That is the entire difference between the two severities — which
rules are fatal is a decision your `lint.zon` makes, not one this tool makes for you.

```sh
cktimg-json --lint deck.spice > deck.json || exit 1   # the gate, in full
```

### Two channels, one flag

`cktimg-json --lint` writes findings **both** ways, because its two readers are different
people:

- **stderr**, one line per finding, in the line format `cktimg_report()` already uses:

  ```text
  lint err duplicate_refdes: device r1 (reference designator is not unique)
  lint warn no_ground: schematic (schematic has no ground symbol)
  ```

  Severity is the second field, so `grep '^lint err'` works without a parser.

- **the document**, as a top-level `"lint"` member beside `devices`/`nets`/`wires`:

  ```json
  "lint": [
    { "rule": "duplicate_refdes", "severity": "err", "dev": "r1", "net": null,
      "text": "reference designator is not unique" }
  ]
  ```

  `rule` and `severity` are enum tag names — stable identifiers a gate switches on, not
  prose. `dev` and `net` are names, or `null` when the rule is not about one of those.
  The array is emitted even when empty: its presence means the rules ran, which is a
  different statement from a clean schematic.

  A machine consumer reading the geometry gets the verdict in the same document, rather
  than running the tool twice and correlating two files.

`cktimg-tex --lint` writes the stderr half only. A TikZ fragment is a figure; a
`\input`-ed document has nowhere to put a findings list.

The table travels as a **value** (`lint.Rules`, a plain struct of `Severity` fields), so
two threads can lint two schematics under two different policies with no shared state.
`cfg.rules` is where it lives on a `Config`, and `.rules` is the block of `lint.zon` that
sets it:

```zon
.{
    .rules = .{
        .single_pin_net = .warn,
        .duplicate_refdes = .err,
        .no_ground = .off,
    },
}
```

Every field is optional and absent fields keep the defaults below. An unrecognized rule
name is reported through `Config.parse`'s diagnostics and is **not** fatal, so one
`lint.zon` can be shared across tool versions.

## Severity is the knob, not a boolean

| Severity | Effect |
|---|---|
| `off` | The scan does not run. Not "report and filter" — an all-`off` table makes `check` a no-op that allocates nothing. |
| `warn` | Produces findings with `severity == .warn`. |
| `err` | Produces findings with `severity == .err`. |

`warn` and `err` differ only in the `severity` field of the `Finding`. What a build *does*
about an error — fail, annotate, ignore — is the caller's policy, not this module's. The
one exception is `symbol_geometry`, which is explained below and is exactly why the
distinction is not free everywhere.

## The rules

### `floating_pin` — default `.warn`

A device terminal wired to no net at all (`Ir.pin_net[p] == .none`).

Only a host-built `Ir` can carry one: the netlist front end rejects a short card rather
than emitting `NetIdx.none`. It is on by default anyway, because `Ir` is public surface —
a host filling the columns itself can produce a floating pin, and the pin is then silently
dropped by `netPins` and never routed. A rule that fires on zero real netlists but catches
the one producer that can break the invariant is cheap insurance.

Located by device.

### `single_pin_net` — default `.off`

A net touched by exactly one pin: it connects nothing.

**Off by default, and the default is the interesting part.** These decks are *open
fragments*. A top-level SPICE netlist that draws well has primary inputs, bias nodes and
gate drives that are legitimately one-pin — they are the ports of the fragment, not
mistakes. At `.warn` the rule fires on **13 of the 21 gallery fixtures**, 29 findings in
total: `vin`, `vb1`, `vb2` on `cascode.spice`; `inp`, `inn`, `vb` on `ota_5t.spice`;
`i1`/`i2`/`i3`/`vb` on `tail_current_source.spice`, and so on. A default that complains
about the files that define what this tool draws well is a wrong default.

Turn it on for a **closed** design — a full chip or a block whose every port is bound —
where a one-pin net really is a typo. That is a property of the deck, which is why it is a
config decision and not a heuristic in the code.

Located by net.

### `duplicate_refdes` — default `.err`

Two devices sharing a reference designator *after flattening*.

An error by default because it is unambiguous: there is no reading of a netlist under
which two `r1`s are intended. The finding names the **second and later** device; the first
occurrence is the one that is fine, and flagging it would double every complaint.
Unnamed devices (`StrId.empty` — rails and ports carry no refdes) are skipped, since
treating them as all-identical would bury the real duplicates.

Implemented by sorting `(name, device)` pairs and walking for adjacent equal names, then
re-sorting the findings by device index. No hash map is involved, because the report has
to be byte-identical across runs (ARCHITECTURE.md §7).

Located by device.

### `unmapped_master` — default `.warn`

A `.subckt` master that no rule resolved, drawn as the generic labelled box.

This is the PDK workflow's feedback channel. A team marks a foundry prefix as
`pdk.leaf` so it is not flattened; whatever then fails `pdk.alias` and `pdk.scan` becomes a
box under `pdk.unknown_as_box`. The drawing is still correct — it just says "something goes
here" — so this is a `warn`: the deck produced a usable schematic, and the finding tells
you which symbols you still owe the mapping for.

Matched by comparing `dev_symbol` against `catalog.indexOf("generic")` by **index**, so a
host class that happens to be named "generic" is not mistaken for it.

Located by device.

### `no_ground` — default `.warn`

No ground symbol anywhere in the schematic.

Uses the same definition `place/ctx.zig` uses: a schematic is grounded because a device
whose class `role` is `.ground_rail` is in it, never because a net is *spelled* `gnd`.
A name is a convention; a symbol is a statement.

`warn` rather than `err` because a groundless fragment is a real thing people draw —
`tests/fixtures/transmission_gate.spice` is a pass gate with no supply of any kind, and it
is pinned in the test suite as producing exactly one `no_ground` finding and nothing else.
The rule working, asserted rather than excluded.

Carries neither a device nor a net: it is about the schematic as a whole.

### `symbol_geometry` — default `.warn`

A symbol whose terminals collide, or whose arity disagrees with its card. Two defects,
neither of which the placer can repair:

- **Colliding terminals.** Two pins at one anchor point put two nets on one coordinate,
  which a geometric-connectivity consumer reads as a short.
- **Arity disagreement.** The card supplied a different number of nodes than the symbol
  has terminals, so some pin has no anchor and renders at the origin.

Only a host class can carry either, through `host.Table.register` or `setAnchors`.

**Why `warn` and not `err`, and why this one is load-bearing.** `rules.symbol_geometry ==
.err` is read by the *placer*, not just the linter. At `.err`, `Pipeline.evalOrder` sets
`strict`, which switches on the `pin_hits` and `geom_shorts` terms of `metric.Key` — and
those terms sit second and third in the selection key, above `body_hits`, `overlaps` and
`crossings`. It also makes `placeFeedback` spread margin-resident devices left to right
instead of centring them. So `err` does not merely reclassify a message: **it changes which
candidate order wins and where devices land, on every run.**

That is a defensible thing to want — a host whose downstream format merges coincident pins
wants those candidates to lose outright — but it is not something a severity knob should do
by surprise. `warn` reports the same faults and ranks nothing, which is the behavior the
retired `layout.strict_geometry` bool shipped with (`false`), and geometry faults have
always been *measured* here rather than fatal.

`layout.strict_geometry` is gone. The name survives in `config.zig` as `Layout.retired_key`
so that a document still setting it is reported as an unrecognized key by the same path as
any other stale key — an old config still loads, and the diagnostic names the key rather
than the file quietly meaning something other than it says.

Located by device.

### `label_fallback` — default `.off`

A net that routing proved undrawable and dropped to a name tag.

Off by default because it is a **documented outcome**, not a defect: ALGORITHM.md ranks
the label fallback as the last of three strategies for a non-immediate connection, and
`metric.Key.labels` is the *first* field of the selection key, so the order search already
minimises it harder than anything else. By the time you see one, the placer has tried
every candidate order it was given. Turn it on when you want the drawing to be
wire-complete or not at all.

This rule is a **read**, not a measurement: it walks `Physical.labels`, which routing wrote
down when it gave up. That property is the design rule for this whole file — see below.

Located by net.

## Determinism

Findings come out in **rule-declaration order**, and within a rule in ascending index
order. Nothing iterates a hash map; `duplicate_refdes` sorts. Two runs over the same input
produce byte-identical reports. This is the same guarantee the layout itself carries
(ARCHITECTURE.md §7) and it exists for the same reason: a report you can diff.

## What is deliberately not a rule

The design rule for this file is that **every rule is answerable from the IR columns, the
class table, or geometry that is already stored** — never from a fresh measurement pass.
Two categories fail that test, and one fails a simpler one.

### `bulk_unconnected` — there is no bulk pin

The catalog's MOSFET is **three-terminal**: `catalog.mos` is `d`, `g`, `s`, and every
MOSFET class (`nmos`, `pmos`, `nfet`, `pfet`, `njfet`, …) shares it. `card.zig` drops the
bulk node of a four-node `M` card on the way in, and the `bulk` tag in
`catalog.TerminalRole` is used by no class at all. There is no pin in the IR for the rule
to read. (This is also why `docs/TARGETS.md` rejects a manifest writing `["d","g","s","b"]`.)

### `wire_crossing` and `body_hit` — the numbers exist but are not retained

`metric.Key` already counts both, exactly and on the drawn geometry — `crossings`,
`overlaps`, `body_hits`, `pin_hits`, `geom_shorts`. But a `Key` is computed **per candidate
order** and discarded: losers die with the `search` arena reset, and the winner's key is
used to pick it and then dropped. `Placed` carries geometry, not measurements.

Surfacing them as rules costs one of two things, and both are worse than not having the
rule:

- **Retain measurement state on `Placed`.** That widens the result type, and therefore the
  C ABI and the JSON document, with numbers whose only consumer is the linter — and makes
  `Placed` a thing that can be *stale* relative to its own geometry, which today it cannot.
- **Re-derive them in `check`.** A second O(n²) sweep over every wire pair, to restate a
  number the placer already computed and already optimised against.

A `lint.zon` naming `wire_crossing` therefore loads and reports it as an unknown key; a
test pins that. If these ever become rules it will be because retention paid for itself
somewhere else first.
