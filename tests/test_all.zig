//! The single test entry point. `zig build test` compiles this file and nothing else,
//! so every suite must be reachable from here or it silently does not run.
//!
//! ## Why a panic, not a failure
//!
//! During the stub phase every unimplemented function body is `@panic("TODO")`. A Zig
//! panic **aborts the process** — it does not fail one test and continue. Under a bare
//! `zig test` that ends the run outright; under `zig build test` the runner isolates
//! each case and reports it as a *crash* rather than a failure, so a run reads "29
//! pass, 191 crash" and every crash is a stack trace whose top frame is a stub. Either
//! way there is no assertion diff to read and nothing to trace back — which is not a
//! limitation to work around, it is the intended workflow:
//!
//! > **The first panic names the next function to write.**
//!
//! Run `zig build test`, read the top frame, implement that function, run again. The
//! frontier moves forward each time. Fighting this — wrapping suites in conditionals,
//! commenting out imports, stubbing a function to return a plausible value so its test
//! "passes" — turns a precise "here is the next thing" signal back into a vague
//! progress bar.
//!
//! The corollary is that suites must be implemented in **dependency order**, because a
//! panic deep in the front end masks every test that would have run after it. That
//! order is ARCHITECTURE.md §Sequence:
//!
//!   1. `ids` / `strings` / `csr`       -> tests/foundation.zig
//!   2. `netlist` + `ir`                -> tests/netlist.zig
//!   3. `devices` catalog               -> tests/devices.zig
//!   4. `config`                        -> tests/config.zig
//!   5. `place/ctx`, `spline`, `column` -> tests/place.zig
//!   6. `place/stack`, `orient`, `order`      (same file)
//!   7. `route` + `metric`              -> tests/route.zig
//!   8. `render` + `abi`                -> tests/exports.zig
//!
//! `tests/pipeline.zig` covers `root.zig` — the five allocators and `Scratch` — which
//! has no dependency on the stages and can be driven at any point; the `Scratch` half
//! in particular is green well before the front end parses anything.
//!
//! ## What is registered here
//!
//! Both kinds of test. `_ = @import("cktimg")` pulls in the **in-source** `test`
//! blocks, which cover single-declaration invariants (`ids.zig`'s size and transform
//! tests are the model). The `tests/*.zig` imports pull in the **behavioral** suites,
//! which cover contracts spanning several declarations. Neither substitutes for the
//! other, and dropping the library import is an easy way to lose half the coverage
//! without noticing.

const std = @import("std");

test {
    // In-source unit tests: everything reachable from the library root.
    _ = @import("cktimg");

    // Behavioral suites, listed in the implementation order above.
    _ = @import("foundation.zig");
    _ = @import("netlist.zig");
    _ = @import("devices.zig");
    _ = @import("config.zig");
    _ = @import("place.zig");
    _ = @import("route.zig");
    _ = @import("exports.zig");
    _ = @import("pipeline.zig");
}
