//! What every test needs from outside the library: a symbol set.

const std = @import("std");
const np = @import("NetlistParser");

pub const symbols = @embedFile("symbols.zon");

/// The standard symbol set (`symbols.zon`), on the heap so that schematics
/// can point at it while their owner moves.
pub fn library(gpa: std.mem.Allocator) !*np.Library {
    const lib = try gpa.create(np.Library);
    errdefer gpa.destroy(lib);
    lib.* = .init(gpa);
    errdefer lib.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: std.ArrayList(np.library.ZonDiagnostic) = .empty;
    try lib.loadZon(arena.allocator(), symbols, &diags);
    for (diags.items) |d| std.debug.print("symbols.zon: {s}: {s}\n", .{ d.class, @errorName(d.err) });
    if (diags.items.len > 0) return error.BadSymbols;
    return lib;
}

pub fn freeLibrary(gpa: std.mem.Allocator, lib: *np.Library) void {
    lib.deinit();
    gpa.destroy(lib);
}
