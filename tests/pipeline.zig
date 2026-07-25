//! Behavioral suite for `root.zig`: the five-allocator `Pipeline`, the reusable
//! `Scratch` buffers, and the ownership contract of `place`.
//!
//! This file exists because the allocator layout is the single largest structural
//! decision in the port (ARCHITECTURE.md §3) and every part of it is invisible to a
//! functional test. A pipeline that leaks the search arena still draws the right
//! schematic; a `Scratch` that lives *in* the search arena still routes correctly
//! until the first reset lands on a page the allocator has since reused. Both are
//! caught here or not at all.
//!
//! The properties, in order of how quietly they can break:
//!
//! - **`Scratch` survives a `search` arena reset.** That separation is the entire
//!   reason `Scratch` is a distinct type rather than three more arena allocations.
//!   The test allocates into `search`, resets it, and reads the scratch buffers back.
//! - **Generation stamping invalidates in O(1) and survives overflow.** A `newGeneration`
//!   that merely increments is correct until `gen` wraps onto a stale stamp, once per
//!   four billion searches — which is to say, in production and never in a test unless
//!   the test forces it. It is forced here.
//! - **`ensure` is monotonic.** A smaller request must be a no-op. A shrink would be
//!   invisible until a later, larger lattice indexed past the end.
//! - **`reset` retains capacity.** Measured with a counting allocator, because "the
//!   second schematic allocates nothing" is the claimed payoff of the whole design and
//!   it is trivially lost by resetting with `.free_all`.
//! - **`cfg` is borrowed, not copied.** Pinned by pointer identity, so a future
//!   `Pipeline` that snapshots the config for "safety" fails here.
//! - **`place` transfers ownership.** Its result outlives the pipeline it was built
//!   with; `testing.allocator` proves the transfer is complete rather than shared.
//!
//! Expected red until the corresponding function is written — a `@panic("TODO")`
//! aborts the whole binary rather than failing one test, so the first panic names the
//! next function to implement.

const std = @import("std");
const ckt = @import("cktimg");

const Allocator = std.mem.Allocator;
const testing = std.testing;

const Pipeline = ckt.Pipeline;
const Scratch = ckt.Scratch;
const Config = ckt.Config;

/// The smallest netlist that still produces two devices, one net between them, and a
/// ground reference — enough for a run to exercise every stage without depending on
/// any dialect feature the front end may not have yet.
const tiny_src =
    \\* tiny divider
    \\r1 in out 1k
    \\r2 out 0 1k
    \\v1 in 0 dc 1
    \\.end
    \\
;

// ===========================================================================
// A counting allocator
//
// `std.testing.allocator` reports leaks but not volume, and the claim under test is
// about volume: run two must allocate strictly less than run one. Wrapping is a dozen
// lines, so no dependency and no ceremony.
// ===========================================================================

const Counting = struct {
    child: Allocator,
    bytes: usize = 0,
    calls: usize = 0,

    fn allocator(self: *Counting) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.bytes += len;
        self.calls += 1;
        return p;
    }

    fn resize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(mem, alignment, new_len, ra)) return false;
        if (new_len > mem.len) self.bytes += new_len - mem.len;
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(mem, alignment, new_len, ra) orelse return null;
        if (new_len > mem.len) self.bytes += new_len - mem.len;
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, alignment, ra);
    }
};

// ===========================================================================
// Scratch
// ===========================================================================

test "scratch capacity never shrinks" {
    var s: Scratch = .empty;
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), s.capacity);

    try s.ensure(testing.allocator, 1000);
    try testing.expect(s.capacity >= 1000);
    const big = s.capacity;
    const dist_ptr = @intFromPtr(s.dist.ptr);

    // Monotonic: a smaller request is a no-op, not a realloc down. A shrink here is
    // invisible until a later candidate order builds a larger lattice and indexes
    // past the end of a buffer that was silently reduced.
    try s.ensure(testing.allocator, 10);
    try testing.expectEqual(big, s.capacity);
    try testing.expectEqual(dist_ptr, @intFromPtr(s.dist.ptr));

    try s.ensure(testing.allocator, big);
    try testing.expectEqual(big, s.capacity);
    try testing.expectEqual(dist_ptr, @intFromPtr(s.dist.ptr));

    // Growth is honored.
    try s.ensure(testing.allocator, big + 1);
    try testing.expect(s.capacity >= big + 1);

    // Idempotent: the same request twice changes nothing.
    const grown = s.capacity;
    try s.ensure(testing.allocator, big + 1);
    try testing.expectEqual(grown, s.capacity);
}

test "every scratch buffer is exactly twice the node capacity" {
    // The post-condition from the doc comment. `dist` is direction-aware — one entry
    // per (node, last-move-was-horizontal-or-vertical) — so a buffer sized to `nodes`
    // rather than `nodes * 2` is a heap overrun on the first vertical arrival.
    var s: Scratch = .empty;
    defer s.deinit(testing.allocator);

    for ([_]usize{ 1, 2, 17, 4096 }) |n| {
        try s.ensure(testing.allocator, n);
        try testing.expect(s.capacity >= n);
        try testing.expectEqual(s.capacity * 2, s.dist.len);
        try testing.expectEqual(s.capacity * 2, s.dist_gen.len);
        try testing.expectEqual(s.capacity * 2, s.prev.len);
        try testing.expect(s.heap.len >= s.capacity);
    }

    // After a growth, stamps from the old sizing no longer describe the same nodes,
    // so the array is zeroed and `gen` restarts.
    try testing.expectEqual(@as(u32, 0), s.gen);
    for (s.dist_gen) |g| try testing.expectEqual(@as(u32, 0), g);
}

test "a new generation invalidates every entry" {
    var s: Scratch = .empty;
    defer s.deinit(testing.allocator);
    try s.ensure(testing.allocator, 64);

    s.newGeneration();
    const gen = s.gen;

    // Populate every slot as if a search had just finished.
    for (s.dist, s.dist_gen, s.prev, 0..) |*d, *g, *p, i| {
        d.* = @intCast(i * 7);
        g.* = gen;
        p.* = @intCast(i);
    }
    for (0..s.dist.len) |i| try testing.expect(s.isLive(i));

    // One increment retires all of it. The alternative — memset of nodes*2*4 bytes
    // per net per candidate order — is the cost this design exists to avoid.
    s.newGeneration();
    try testing.expect(s.gen != gen);
    for (0..s.dist.len) |i| try testing.expect(!s.isLive(i));

    // The stale payload is untouched; only the stamp decides liveness. A `newGeneration`
    // that cleared `dist` would be correct but would give back the O(1) it exists for.
    try testing.expectEqual(@as(u32, 7), s.dist[1]);

    // Re-stamping one slot brings exactly that slot back, and no neighbor.
    s.dist_gen[5] = s.gen;
    try testing.expect(s.isLive(5));
    try testing.expect(!s.isLive(4));
    try testing.expect(!s.isLive(6));
}

test "generation overflow restarts stamping without resurrecting stale entries" {
    var s: Scratch = .empty;
    defer s.deinit(testing.allocator);
    try s.ensure(testing.allocator, 32);

    // Force the wrap. Reached once per four billion searches in production, which is
    // to say never in any test that does not do this deliberately — and the failure
    // mode is a search reading another net's distances as its own.
    s.gen = std.math.maxInt(u32);
    for (s.dist_gen, 0..) |*g, i| {
        g.* = @intCast(i); // a spread of stale stamps, including 0 and 1
        s.dist[i] = 4242;
    }

    s.newGeneration();

    // Whatever the new generation is, nothing stamped under the old numbering may
    // read as live.
    for (0..s.dist.len) |i| try testing.expect(!s.isLive(i));
    try testing.expect(s.gen != std.math.maxInt(u32));

    // And the counter is usable again: normal stamping resumes.
    s.dist_gen[3] = s.gen;
    s.dist[3] = 11;
    try testing.expect(s.isLive(3));
    try testing.expectEqual(@as(u32, 11), s.dist[3]);

    s.newGeneration();
    try testing.expect(!s.isLive(3));
    s.dist_gen[3] = s.gen;
    try testing.expect(s.isLive(3));
}

test "scratch survives a search arena reset" {
    // The reason `Scratch` is not three more arena allocations. Dijkstra buffers are
    // sized once to the largest lattice and reused for every net of every candidate
    // order, while everything else the candidate built is thrown away between orders.
    var cfg = Config.default;
    var p = Pipeline.init(testing.allocator, &cfg);
    defer p.deinit();

    try p.scratch.ensure(testing.allocator, 512);
    p.scratch.newGeneration();
    for (p.scratch.dist, p.scratch.dist_gen, 0..) |*d, *g, i| {
        d.* = @intCast(i);
        g.* = p.scratch.gen;
    }
    const gen_before = p.scratch.gen;
    const capacity_before = p.scratch.capacity;
    const dist_ptr = @intFromPtr(p.scratch.dist.ptr);

    // Allocate the sort of thing a candidate order builds — lattice axes, occupancy —
    // and then throw the whole order away.
    const search = p.search.allocator();
    const lattice = try search.alloc(u32, 4096);
    @memset(lattice, 0xAB);
    _ = p.search.reset(.retain_capacity);

    // Scratch is still readable, still the same memory, still the same generation.
    try testing.expectEqual(capacity_before, p.scratch.capacity);
    try testing.expectEqual(dist_ptr, @intFromPtr(p.scratch.dist.ptr));
    try testing.expectEqual(gen_before, p.scratch.gen);
    for (p.scratch.dist, 0..) |d, i| try testing.expectEqual(@as(u32, @intCast(i)), d);
    for (0..p.scratch.dist.len) |i| try testing.expect(p.scratch.isLive(i));

    // Repeated resets do not erode it either — sixteen candidate orders is the
    // default budget.
    for (0..16) |_| {
        _ = try p.search.allocator().alloc(u8, 1024);
        _ = p.search.reset(.retain_capacity);
    }
    try testing.expectEqual(dist_ptr, @intFromPtr(p.scratch.dist.ptr));
    for (p.scratch.dist, 0..) |d, i| try testing.expectEqual(@as(u32, @intCast(i)), d);
}

// ===========================================================================
// Pipeline
// ===========================================================================

test "constructing a pipeline allocates nothing" {
    // Documented: "Allocates nothing eagerly." Enforced by handing `init` an allocator
    // that fails on its very first request — if the constructor reserves an arena page
    // or sizes scratch up front, this cannot even be written, since `init` returns no
    // error.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var cfg = Config.default;

    var p = Pipeline.init(failing.allocator(), &cfg);
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expectEqual(@as(usize, 0), p.scratch.capacity);
    try testing.expectEqual(@as(usize, 0), p.scratch.dist.len);
    try testing.expectEqual(@as(usize, 0), p.scratch.dist_gen.len);
    try testing.expectEqual(@as(usize, 0), p.scratch.prev.len);
    try testing.expectEqual(@as(usize, 0), p.scratch.heap.len);
    try testing.expectEqual(@as(u32, 0), p.scratch.gen);
}

test "pipeline deinit releases every arena and the scratch buffers" {
    // Partial deinit is one leak per instance, and a pipeline is exactly the shape
    // that invites it: four owning fields, three of them the same type.
    // `testing.allocator` is the whole assertion.
    var cfg = Config.default;
    var p = Pipeline.init(testing.allocator, &cfg);

    _ = try p.doc.allocator().alloc(u8, 8192);
    _ = try p.search.allocator().alloc(u8, 8192);
    _ = try p.out.allocator().alloc(u8, 8192);
    try p.scratch.ensure(testing.allocator, 2048);

    p.deinit();

    // A second pipeline over the same allocator immediately afterwards would trip on
    // any byte the first one held back.
    var q = Pipeline.init(testing.allocator, &cfg);
    q.deinit();
}

test "reset retains capacity so the second run allocates less than the first" {
    // The claimed payoff of the whole allocator design: after warm-up, driving N
    // schematics costs no further pages. Measured rather than asserted in prose.
    var counting: Counting = .{ .child = testing.allocator };
    var cfg = Config.default;

    var p = Pipeline.init(counting.allocator(), &cfg);
    defer p.deinit();

    _ = try p.run(tiny_src);
    const first_bytes = counting.bytes;
    const first_calls = counting.calls;
    try testing.expect(first_bytes > 0);

    p.reset();

    _ = try p.run(tiny_src);
    const second_bytes = counting.bytes - first_bytes;
    const second_calls = counting.calls - first_calls;

    try testing.expect(second_bytes < first_bytes);
    try testing.expect(second_calls < first_calls);

    // By the third identical run the arenas should be fully warm.
    p.reset();
    const before_third = counting.bytes;
    _ = try p.run(tiny_src);
    try testing.expect(counting.bytes - before_third <= second_bytes);
}

test "reset returns the pipeline to a reusable state" {
    // `run` returns a *borrowed* view into the pipeline's arenas, so a second run
    // necessarily invalidates the first result. That cannot be asserted directly
    // without reading freed memory, so what is pinned instead is the reset contract
    // the invalidation follows from: reset is idempotent, safe before any run, and
    // leaves scratch capacity alone.
    var cfg = Config.default;
    var p = Pipeline.init(testing.allocator, &cfg);
    defer p.deinit();

    p.reset(); // safe with nothing to reset
    p.reset();

    try p.scratch.ensure(testing.allocator, 256);
    const capacity = p.scratch.capacity;

    _ = try p.run(tiny_src);
    p.reset();
    p.reset();

    // Scratch is sized to the largest lattice seen and is deliberately *not* released
    // by reset — it is the one buffer meant to survive.
    try testing.expect(p.scratch.capacity >= capacity);

    // And the pipeline is genuinely reusable afterwards.
    _ = try p.run(tiny_src);
}

test "config is borrowed so a later mutation is visible through the pipeline" {
    // Pointer identity, not value equality: a `Pipeline` that snapshotted the config
    // "for safety" would pass a value comparison and fail here, which is the point.
    // Config is threaded rather than global precisely so tests can vary knobs.
    var cfg = Config.default;
    var p = Pipeline.init(testing.allocator, &cfg);
    defer p.deinit();

    try testing.expectEqual(@as(*const Config, &cfg), p.cfg);

    cfg.layout.refine = 3;
    cfg.layout.enum_limit = 4;
    cfg.layout.grid = 10;
    try testing.expectEqual(@as(u32, 3), p.cfg.layout.refine);
    try testing.expectEqual(@as(u32, 4), p.cfg.layout.enum_limit);
    try testing.expectEqual(@as(i32, 10), p.cfg.layout.grid);

    // `&Config.default` is documented as always valid for this parameter.
    var q = Pipeline.init(testing.allocator, &Config.default);
    defer q.deinit();
    try testing.expectEqual(@as(u32, 16), q.cfg.layout.refine);
}

test "place transfers ownership so the result outlives the pipeline" {
    // `Pipeline.run` hands back a borrowed view; `place` copies out of the internal
    // arenas and tears them down, so the caller's value is still readable here — after
    // every arena that produced it is gone. `testing.allocator` proves the transfer is
    // complete rather than shared: a `Placed` still pointing into a freed arena, or a
    // `deinit` that misses a column, fails this test.
    var placed, var report = try ckt.place(testing.allocator, &Config.default, tiny_src);
    defer placed.deinit(testing.allocator);
    defer report.deinit(testing.allocator);

    // Readable after the internal pipeline is gone — the whole claim.
    const n_dev = placed.ir.deviceCount();
    try testing.expect(n_dev > 0);
    try testing.expectEqual(n_dev + 1, placed.ir.dev_pin0.len);
    try testing.expectEqual(n_dev, placed.physical.pos.len);
    try testing.expectEqual(placed.ir.pinCount(), placed.physical.pin_xy.len);
    placed.ir.assertValid();
    placed.physical.assertValid(placed.ir);

    // The string pool came with it, so names resolve without holding anything else.
    for (placed.ir.dev_name) |id| try testing.expect(placed.strings.get(id).len > 0);
}
