# Code conventions

Target: **Zig 0.16.0**. These are the rules every file in `src/` and `tests/` follows.

## Stub phase

The tree is currently signatures plus documentation. Every function body is:

```zig
pub fn f(gpa: Allocator, n: u32) ![]u32 {
    _ = .{ gpa, n };
    @panic("TODO");
}
```

Unused function parameters are a **compile error** in Zig, so the `_ = .{ ... };`
discard is mandatory, not decoration. Discard every parameter including `self`.

Implementation order is driven by the panics: run `zig build test`, and the first
panic names the next function to write. A panic aborts the whole test binary rather
than failing one test, so work bottom-up through the dependency order in
ARCHITECTURE.md §Sequence.

## Documentation is the specification

The doc comment above each declaration is what an implementer works from, so it
carries behavior, not restatement of the signature.

**File header (`//!`)** — what data moves through this file, and *why the layout is
what it is*. If a choice was made against an obvious alternative (SoA over AoS,
sentinel over optional, CSR over list-of-lists), the header says which alternative
and what it would have cost. A header that only names the file's contents is not
pulling its weight.

**Declaration comment (`///`)** — cover, in prose rather than a rigid template, only
what applies:

- what the function is for, in one line
- what each non-obvious parameter means, its valid range, and its units
- what is returned and what it means
- **ownership**: `Caller owns the returned …` on every transfer; `Borrowed from …;
  valid until …` on every view. This is the single most important line for a reader.
- side effects and mutation of anything reachable
- errors: every failure mode and what triggers it
- edge cases: empty input, zero, absent values, boundary indices
- pre/post-conditions and invariants the function preserves
- complexity, when the design deliberately avoids a costlier approach

Say what is *asserted* versus what is *handled*. A programming error asserts; a data
condition is handled. Mixing the two is how a clear failure becomes a mystery.

## Data-oriented rules

1. **SoA by default.** Parallel arrays per field. Switch to a record only when every
   pass touches every field together.
2. **Hot/cold split.** Fields read by place-and-route go in the hot columns; fields
   read only at render go in separate ones. Never interleave.
3. **Indices, never pointers.** `u32` in a distinct `enum(u32)` per index space, so
   arithmetic on it is a compile error and one index space cannot be passed where
   another belongs.
4. **Smallest integer that fits.** `u16` under 65536, `u8` under 256. Never default to
   `usize` for stored data — only for subscripts at the point of use.
5. **CSR for every many-to-many relation.** `csr.zig` has the builder; do not
   open-code offsets, and never build a `[][]T`.
6. **Sentinels over optionals in hot arrays.** Zig does not niche-optimize an optional
   over a non-exhaustive enum, so `?NetIdx` is 8 bytes where a reserved value is 4.
   Use an optional freely in return values and cold data — this rule is about stored
   columns only.
7. **Never iterate a hash map.** Output must be byte-reproducible. A map may answer
   membership questions; iteration order must come from a sorted array or a counting
   sort. This is not a style preference — it is the determinism guarantee.
8. **No hidden control flow.** No global state, no lazy singleton, no allocation the
   call site cannot see. `Config` is threaded as a parameter for exactly this reason.
9. **Integers only in geometry.** No float anywhere in place-and-route.

## Memory rules

Ranked; take the highest rung that fits.

1. **Do not allocate.** Fixed-size stack arrays for bounded work — permutation
   buffers, the top-K candidate list, case-folding scratch.
2. **Arena per phase.** The five arenas are fields on `Pipeline`; match the
   allocation to the lifetime that already exists. Do not introduce a sixth.
3. **Owned memory, under discipline.** One owner per allocation. Pair the disposal
   with the allocation at the site — `defer` when the owner stays, `errdefer` when
   ownership will move on success. Every owned value alive across a `try` needs an
   `errdefer` until ownership transfers; this is the leak that actually happens.

Type rules:

- If any field can own memory, the type has `deinit(self, gpa)` and it releases
  **every** owning field. Partial deinit is one leak per instance.
- Containers own one level. Owned elements are freed in a loop before the container's
  own `deinit`.
- Free with the allocator that allocated. Take it as a `deinit` parameter, matching
  std's `list.deinit(gpa)` convention.
- No conditional ownership. `if (cond) free(p)` is unreviewable — restructure so each
  path has unconditional obligations.
- A borrowed slice field is named or commented as such and is never freed. An
  unannotated `[]const u8` in a struct is a question the reader should not have to
  ask.

Verb conventions follow std: `dupe` / `toOwnedSlice` / `create` transfer ownership;
plain slices, `get*` and `slice*` return views.

## Verified 0.16 std API

Do not guess these; they changed in 0.16.

| Need | API |
|---|---|
| growable list | `std.ArrayList(T)`, init `.empty`, methods take `gpa`: `append(gpa, x)`, `deinit(gpa)`, `toOwnedSlice(gpa)` |
| SoA list | `std.MultiArrayList(T)`, init `.empty`, `append(gpa, x)`, `items(.field)`, `slice()`, `deinit(gpa)` |
| output | `*std.Io.Writer` — `writeAll`, `writeByte`, `print(fmt, args)`; errors are `std.Io.Writer.Error` |
| build a string | `std.Io.Writer.Allocating` → `.writer`, then `toOwnedSlice()` |
| write into a buffer | `std.Io.Writer.fixed(buf)` |
| arena | `std.heap.ArenaAllocator`, `.init(gpa)`, `.allocator()`, `.reset(.retain_capacity)`, `.deinit()` |
| comptime string map | `std.StaticStringMap(V).initComptime(.{ .{ "k", v }, … })` |
| sort | `std.mem.sort(T, slice, ctx, lessThan)`, `std.sort.pdq`, `std.sort.binarySearch`, `std.sort.lowerBound` |
| hash map (membership only) | `std.StringHashMapUnmanaged(V)`, `std.AutoHashMapUnmanaged(K, V)`, init `.empty` |
| config parsing | `std.zon.parse` — `lint.zon`, no third-party TOML dependency |
| bit set | `std.DynamicBitSetUnmanaged`, `std.StaticBitSet(n)` |

## Tests

Live in `tests/*.zig`, imported through `@import("cktimg")`, and are registered in
`tests/test_all.zig`. In-source `test` blocks are for invariants of a single
declaration; behavioral suites go in `tests/`.

- **Fully implemented, never stubbed.** They are the specification's executable form
  and are expected to be red until the corresponding function is written.
- **`std.testing.allocator` always.** It fails a test on a leaked byte, which is the
  cheapest leak gate available.
- **Error paths get `std.testing.checkAllAllocationFailures`.** It fails each
  allocation point in turn and is the only way the `errdefer`s actually execute.
- Assert the *documented contract*, including the parts a naive implementation would
  get away with: CSR stability, sentinel encodings, struct sizes where the doc claims
  a size, byte-for-byte reproducibility across two runs, ownership (that a `deinit`
  releases everything).
- Name a test after the property it pins, not the function it calls:
  `"net pins are stable in ascending pin order"`.
