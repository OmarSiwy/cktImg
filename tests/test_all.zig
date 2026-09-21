//! The single test entry point. `zig build test` compiles this file and nothing else,
//! so every suite must be reachable from here or it silently does not run.
//!
//! ## The suites follow the pipeline
//!
//! Listed below in dependency order, which is also the order a failure is worth reading
//! in: a broken interner shows up as a routing failure six suites later, so the first
//! suite to go red is usually the one to fix.
//!
//!   1. `ids` / `strings` / `csr`             -> tests/foundation.zig
//!   2. `netlist` + `ir`                      -> tests/netlist.zig
//!   3. `devices` catalog                     -> tests/devices.zig
//!   4. `config`                              -> tests/config.zig
//!   5. `lint`                                -> tests/lint.zig
//!   6. `place/*`                             -> tests/place.zig
//!   7. `route/*` + `metric`                  -> tests/route.zig
//!   8. `geom` / `json` / `latex` / `abi`     -> tests/exports.zig
//!   9. target manifests                      -> tests/targets.zig
//!
//! `tests/pipeline.zig` covers `root.zig` — the five lifetimes, `Scratch`, and the
//! `parse`/`layout` split — which depends on every stage and so is listed last to run
//! but is not a stage itself.
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
    _ = @import("lint.zig");
    _ = @import("place.zig");
    _ = @import("route.zig");
    _ = @import("exports.zig");
    _ = @import("pipeline.zig");
    _ = @import("targets.zig");
}
