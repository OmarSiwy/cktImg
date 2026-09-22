//! SPICE netlist in, placed schematic out. See docs/API.md for the usage code
//! this surface was written from, and ALGORITHM.md for the layout.
//!
//! Tiers, coarse to fine — each is the one below it with the choices made:
//!
//! | call | gives you |
//! |------|-----------|
//! | `place(gpa, cfg, lib, sources, diag)` | an owned `Placed` |
//! | `Pipeline.run` | a borrowed `Placed`, pages reused across documents |
//! | `netlist.parse` → `guessRoles` → `Schematic.build` → `layout` → `Placed.init` | every stage, each usable alone |
//!
//! The library draws nothing and knows no device: the caller's `Library`
//! says what each class looks like.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const netlist = @import("netlist.zig");
pub const analysis = @import("analysis.zig");
pub const csr = @import("csr.zig");
pub const library = @import("library.zig");
pub const config = @import("config.zig");
pub const schematic = @import("schematic.zig");
pub const layout_engine = @import("layout.zig");
pub const placed = @import("placed.zig");
pub const geom = @import("geom.zig");
pub const lint = @import("lint.zig");
/// The TikZ emitter, only with `-Dlatex_renderer=true`; `void` otherwise, so
/// a reference without the option is a compile error naming it.
pub const latex = if (build_options.latex_renderer) @import("latex.zig") else void;
const build_options = @import("build_options");
/// Plain-data JSON of a `Placed` (what `cktimg_json` writes).
pub const json = @import("json.zig");
/// The C ABI, `include/cktimg.h`. Nothing in Zig calls it, so it is forced
/// into the build here, or the static library would export nothing.
pub const abi = @import("abi.zig");
comptime {
    _ = abi;
}

pub const Library = library.Library;
pub const Class = library.Class;
pub const ClassId = library.ClassId;
pub const Pt = library.Pt;
pub const Rect = library.Rect;
pub const Orient = library.Orient;
pub const Side = library.Side;
pub const Config = config.Config;
pub const Netlist = netlist.Netlist;
pub const Schematic = schematic.Schematic;
pub const Role = schematic.Role;
pub const Placed = placed.Placed;
pub const Label = placed.Label;

/// Proposes a role per net (supply, sink, input, output, bias, internal);
/// edit the result freely before `Schematic.build`.
pub const guessRoles = schematic.guessRoles;
/// Coordinates for a built schematic.
pub const layout = layout_engine.layout;

/// What can stop a placement: a card the parser does not represent (see
/// `diag` for where), or memory.
pub const PlaceError = netlist.Error || library.RegisterError;

/// Parse, lay out and export in one call; the caller owns the result.
///
/// `sources[0]` is the netlist (its first line the title); later sources are
/// read as if appended (model files). `lib` gains a generated box class for
/// any device kind it has no class for.
pub fn place(
    gpa: Allocator,
    cfg: *const Config,
    lib: *Library,
    sources: []const []const u8,
    diag: ?*netlist.Diagnostic,
) PlaceError!Placed {
    var nl = try netlist.parse(gpa, sources, diag);
    defer nl.deinit(gpa);
    const roles = try guessRoles(gpa, &nl);
    defer gpa.free(roles);
    var s = try Schematic.build(gpa, &nl, roles, lib);
    defer s.deinit();
    try layout(gpa, &s, cfg);
    return Placed.init(gpa, &s, &nl);
}

/// `place` for many documents with one set of pages: each `run` returns a
/// borrowed `Placed`, valid until the next `run`, `reset` or `deinit`.
pub const Pipeline = struct {
    /// Stage temporaries: netlist, schematic. Reset every run.
    scratch: std.heap.ArenaAllocator,
    /// The current result.
    out: std.heap.ArenaAllocator,
    cfg: *const Config,
    lib: *Library,
    current: ?Placed = null,

    /// Borrows `cfg` and `lib`; both must outlive the pipeline.
    pub fn init(gpa: Allocator, cfg: *const Config, lib: *Library) Pipeline {
        return .{ .scratch = .init(gpa), .out = .init(gpa), .cfg = cfg, .lib = lib };
    }

    pub fn deinit(self: *Pipeline) void {
        self.scratch.deinit();
        self.out.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Pipeline, sources: []const []const u8, diag: ?*netlist.Diagnostic) PlaceError!*const Placed {
        self.reset();
        const tmp = self.scratch.allocator();
        var nl = try netlist.parse(tmp, sources, diag);
        const roles = try guessRoles(tmp, &nl);
        var s = try Schematic.build(tmp, &nl, roles, self.lib);
        try layout(tmp, &s, self.cfg);
        self.current = try Placed.init(self.out.allocator(), &s, &nl);
        _ = self.scratch.reset(.retain_capacity);
        return &self.current.?;
    }

    /// Drops the current result and keeps the pages.
    pub fn reset(self: *Pipeline) void {
        self.current = null;
        _ = self.out.reset(.retain_capacity);
        _ = self.scratch.reset(.retain_capacity);
    }
};

test {
    std.testing.refAllDecls(@This());
}
