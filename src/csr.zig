//! Data-oriented bipartite hypergraph.
//!
//! A hypergraph H = (V, E) is stored as its bipartite incidence graph:
//! one side holds vertices, the other holds hyperedges, and an incidence
//! (e, v) says "vertex v is a member of hyperedge e".
//!
//! For circuits: vertices are nets, hyperedges are devices, and an edge's
//! member list is its *pin list*. Order is meaningful (position = terminal
//! role, e.g. d/g/s/b) and repeats are allowed (bulk tied to source), so
//! member lists are stored exactly as given, never sorted or de-duplicated.
//!
//! Layout decisions (see the notes at the bottom of the file):
//!   * Topology and payload are split. Topology is two CSR arrays (hot);
//!     user payload lives in `MultiArrayList`s (SoA, touched only on demand).
//!   * Every reference is a typed `u32` index, never a pointer.
//!   * Both directions are materialised (edge -> vertices, vertex -> edges),
//!     so every bulk operation is a *pull*/gather: linear reads, no scatter,
//!     no write conflicts, trivially parallelisable.
//!   * Two-phase lifecycle: an append-only `Builder`, then an immutable
//!     `Graph`. The frozen graph has no dirty flags or branches for
//!     "not yet built" state (existence-based processing).
//!
//! Tested with Zig 0.16 (`zig test csr.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Typed indices. Distinct enum types stop you from indexing the vertex side
// with an edge id, at zero runtime cost (4 bytes each, half a pointer).
// ---------------------------------------------------------------------------

pub const VertexId = enum(u32) {
    _,
    pub inline fn from(i: usize) VertexId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
    pub inline fn index(self: VertexId) u32 {
        return @intFromEnum(self);
    }
};

pub const EdgeId = enum(u32) {
    _,
    pub inline fn from(i: usize) EdgeId {
        return @enumFromInt(@as(u32, @intCast(i)));
    }
    pub inline fn index(self: EdgeId) u32 {
        return @intFromEnum(self);
    }
};

pub const unreachable_dist = std.math.maxInt(u32);

/// SoA storage for a payload type. `MultiArrayList` needs at least one field,
/// so payload-free graphs (`void` or `struct {}`) get a zero-byte counter
/// with the same method surface.
fn PayloadStore(comptime T: type) type {
    const empty_payload = T == void or
        (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".fields.len == 0);
    if (!empty_payload) return std.MultiArrayList(T);
    return struct {
        const Self = @This();
        len: usize = 0,
        pub const empty: Self = .{};
        pub fn deinit(self: *Self, _: Allocator) void {
            self.* = undefined;
        }
        pub fn ensureTotalCapacity(_: *Self, _: Allocator, _: usize) Allocator.Error!void {}
        pub fn ensureUnusedCapacity(_: *Self, _: Allocator, _: usize) Allocator.Error!void {}
        pub fn append(self: *Self, _: Allocator, _: T) Allocator.Error!void {
            self.len += 1;
        }
        pub fn appendAssumeCapacity(self: *Self, _: T) void {
            self.len += 1;
        }
    };
}

// ---------------------------------------------------------------------------
// CSR: one side's adjacency as two flat arrays.
//   row r's neighbours are cols[offsets[r] .. offsets[r+1]]
// The edge->vertex and vertex->edge directions are the same type with the
// roles swapped, so the dual hypergraph is literally "swap the two CSRs".
// ---------------------------------------------------------------------------

pub fn Csr(comptime Row: type, comptime Col: type) type {
    return struct {
        const Self = @This();

        offsets: []u32, // len = rowCount() + 1, offsets[0] == 0
        cols: []Col, // len = offsets[rowCount()]

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.offsets);
            gpa.free(self.cols);
            self.* = undefined;
        }

        pub inline fn rowCount(self: Self) usize {
            return self.offsets.len - 1;
        }

        pub inline fn rowAt(self: Self, r: usize) []const Col {
            return self.cols[self.offsets[r]..self.offsets[r + 1]];
        }

        pub inline fn row(self: Self, r: Row) []const Col {
            return self.rowAt(r.index());
        }

        pub inline fn rowLen(self: Self, r: Row) u32 {
            const i = r.index();
            return self.offsets[i + 1] - self.offsets[i];
        }

        /// Counting-sort transpose, O(rows + cols + nnz), no hashing and no
        /// scratch allocation. Because rows are visited in order, every output
        /// row comes out sorted ascending.
        pub fn transpose(self: Self, gpa: Allocator, col_count: usize) !Csr(Col, Row) {
            const offsets = try gpa.alloc(u32, col_count + 1);
            errdefer gpa.free(offsets);
            const cols = try gpa.alloc(Row, self.cols.len);
            errdefer gpa.free(cols);

            // 1. Histogram: offsets[c] = number of entries in column c.
            @memset(offsets, 0);
            for (self.cols) |c| offsets[c.index()] += 1;

            // 2. Exclusive prefix sum: offsets[c] = start of column c.
            var running: u32 = 0;
            for (offsets) |*o| {
                const count = o.*;
                o.* = running;
                running += count;
            }

            // 3. Scatter, using offsets[c] as a write cursor. Afterwards
            //    offsets[c] == end of c == start of c+1 ...
            for (0..self.rowCount()) |r| {
                for (self.rowAt(r)) |c| {
                    const slot = &offsets[c.index()];
                    cols[slot.*] = Row.from(r);
                    slot.* += 1;
                }
            }

            // 4. ... so shift right by one to restore the starts.
            std.mem.copyBackwards(u32, offsets[1..], offsets[0..col_count]);
            offsets[0] = 0;

            return .{ .offsets = offsets, .cols = cols };
        }
    };
}

// ---------------------------------------------------------------------------
// The hypergraph, generic over per-vertex and per-edge payload structs.
// Payloads are stored SoA, so e.g. an algorithm that only needs `weight`
// never pulls `name` or `label` into cache. Use `struct {}` for no payload.
// ---------------------------------------------------------------------------

pub fn BipartiteHypergraph(comptime VertexData: type, comptime EdgeData: type) type {
    return struct {
        pub const EdgeMajor = Csr(EdgeId, VertexId); // pins: edge -> members
        pub const VertexMajor = Csr(VertexId, EdgeId); // vertex -> incident edges

        pub const Error = error{ InvalidVertex, TooManyVertices, TooManyEdges, TooManyIncidences } || Allocator.Error;

        // -------------------------------------------------------------------
        // Builder: append-only. Because each hyperedge is added with its full
        // member list, the edge-major CSR is built for free as we go; only the
        // vertex-major direction needs work at `finish()`.
        // -------------------------------------------------------------------
        pub const Builder = struct {
            vertices: PayloadStore(VertexData) = .empty,
            edges: PayloadStore(EdgeData) = .empty,
            edge_offsets: std.ArrayList(u32) = .empty,
            edge_members: std.ArrayList(VertexId) = .empty,

            pub fn init(gpa: Allocator) Allocator.Error!Builder {
                var b: Builder = .{};
                try b.edge_offsets.append(gpa, 0);
                return b;
            }

            pub fn deinit(self: *Builder, gpa: Allocator) void {
                self.vertices.deinit(gpa);
                self.edges.deinit(gpa);
                self.edge_offsets.deinit(gpa);
                self.edge_members.deinit(gpa);
                self.* = undefined;
            }

            /// Pre-size everything once when counts are known up front.
            pub fn ensureTotalCapacity(
                self: *Builder,
                gpa: Allocator,
                vertex_count: usize,
                edge_count: usize,
                incidence_count: usize,
            ) Allocator.Error!void {
                try self.vertices.ensureTotalCapacity(gpa, vertex_count);
                try self.edges.ensureTotalCapacity(gpa, edge_count);
                try self.edge_offsets.ensureTotalCapacity(gpa, edge_count + 1);
                try self.edge_members.ensureTotalCapacity(gpa, incidence_count);
            }

            pub fn vertexCount(self: Builder) u32 {
                return @intCast(self.vertices.len);
            }

            pub fn edgeCount(self: Builder) u32 {
                return @intCast(self.edges.len);
            }

            pub fn addVertex(self: *Builder, gpa: Allocator, data: VertexData) Error!VertexId {
                if (self.vertices.len >= std.math.maxInt(u32)) return error.TooManyVertices;
                const id = VertexId.from(self.vertices.len);
                try self.vertices.append(gpa, data);
                return id;
            }

            /// Adds a hyperedge. Members are stored in the given order, repeats
            /// included. All-or-nothing: on error the builder is unchanged.
            pub fn addEdge(
                self: *Builder,
                gpa: Allocator,
                data: EdgeData,
                members: []const VertexId,
            ) Error!EdgeId {
                const vcount = self.vertices.len;
                for (members) |v| if (v.index() >= vcount) return error.InvalidVertex;
                if (self.edges.len >= std.math.maxInt(u32)) return error.TooManyEdges;
                const start = self.edge_members.items.len;
                if (start + members.len > std.math.maxInt(u32)) return error.TooManyIncidences;

                // Reserve first, then commit with *AssumeCapacity so no
                // partial state can be left behind by an allocation failure.
                try self.edge_members.ensureUnusedCapacity(gpa, members.len);
                try self.edge_offsets.ensureUnusedCapacity(gpa, 1);
                try self.edges.ensureUnusedCapacity(gpa, 1);

                self.edge_members.appendSliceAssumeCapacity(members);

                const id = EdgeId.from(self.edges.len);
                self.edges.appendAssumeCapacity(data);
                self.edge_offsets.appendAssumeCapacity(@intCast(self.edge_members.items.len));
                return id;
            }

            /// Consumes the builder and produces the immutable graph.
            pub fn finish(self: *Builder, gpa: Allocator) Allocator.Error!Graph {
                const edge_offsets = try self.edge_offsets.toOwnedSlice(gpa);
                errdefer gpa.free(edge_offsets);
                const edge_members = try self.edge_members.toOwnedSlice(gpa);
                errdefer gpa.free(edge_members);

                const by_edge: EdgeMajor = .{ .offsets = edge_offsets, .cols = edge_members };
                const by_vertex = try by_edge.transpose(gpa, self.vertices.len);

                const g: Graph = .{
                    .vertices = self.vertices,
                    .edges = self.edges,
                    .by_edge = by_edge,
                    .by_vertex = by_vertex,
                };
                self.* = undefined;
                return g;
            }
        };

        // -------------------------------------------------------------------
        // Frozen graph.
        // -------------------------------------------------------------------
        pub const Graph = struct {
            // Cold-ish: payload, SoA.
            vertices: PayloadStore(VertexData),
            edges: PayloadStore(EdgeData),
            // Hot: topology, both directions.
            by_edge: EdgeMajor,
            by_vertex: VertexMajor,

            pub fn deinit(self: *Graph, gpa: Allocator) void {
                self.vertices.deinit(gpa);
                self.edges.deinit(gpa);
                self.by_edge.deinit(gpa);
                self.by_vertex.deinit(gpa);
                self.* = undefined;
            }

            pub inline fn vertexCount(self: Graph) u32 {
                return @intCast(self.by_vertex.rowCount());
            }
            pub inline fn edgeCount(self: Graph) u32 {
                return @intCast(self.by_edge.rowCount());
            }
            pub inline fn incidenceCount(self: Graph) u32 {
                return @intCast(self.by_edge.cols.len);
            }

            /// Member vertices (pins) of hyperedge `e`, in the order given.
            pub inline fn members(self: Graph, e: EdgeId) []const VertexId {
                return self.by_edge.row(e);
            }
            /// Hyperedges touching vertex `v`, sorted by id. An edge appears
            /// once per pin it has on `v`.
            pub inline fn incident(self: Graph, v: VertexId) []const EdgeId {
                return self.by_vertex.row(v);
            }
            pub inline fn edgeSize(self: Graph, e: EdgeId) u32 {
                return self.by_edge.rowLen(e);
            }
            pub inline fn vertexDegree(self: Graph, v: VertexId) u32 {
                return self.by_vertex.rowLen(v);
            }

            /// Binary search in the vertex-major row (always sorted).
            pub fn contains(self: Graph, e: EdgeId, v: VertexId) bool {
                return std.sort.binarySearch(EdgeId, self.incident(v), e, orderEdge) != null;
            }

            // ---------------- Batch transforms ----------------

            /// out[v] = number of pins on v. Pure adjacent-difference.
            pub fn vertexDegrees(self: Graph, out: []u32) void {
                adjacentDiff(self.by_vertex.offsets, out);
            }

            /// out[e] = |e|.
            pub fn edgeSizes(self: Graph, out: []u32) void {
                adjacentDiff(self.by_edge.offsets, out);
            }

            /// edge_out[e] = sum of vertex_in[v] for v in e      (Hᵀ·x)
            /// Gather from edge-major CSR: sequential reads of the index
            /// array, sequential writes to `edge_out`.
            pub fn gatherToEdges(self: Graph, comptime T: type, vertex_in: []const T, edge_out: []T) void {
                gather(T, EdgeMajor, self.by_edge, vertex_in, edge_out);
            }

            /// vertex_out[v] = sum of edge_in[e] for e ∋ v       (H·y)
            pub fn gatherToVertices(self: Graph, comptime T: type, edge_in: []const T, vertex_out: []T) void {
                gather(T, VertexMajor, self.by_vertex, edge_in, vertex_out);
            }

            // ---------------- Traversal ----------------

            /// Multi-source BFS alternating V -> E -> V. `dist[v]` is the
            /// number of hyperedges crossed (unreachable_dist if none).
            /// Frontiers are flat arrays (existence-based: being in the
            /// frontier *is* the state), visited sets are bitsets.
            pub fn bfs(self: Graph, gpa: Allocator, sources: []const VertexId, dist: []u32) Allocator.Error!void {
                std.debug.assert(dist.len == self.vertexCount());
                @memset(dist, unreachable_dist);

                var edge_seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, self.edgeCount());
                defer edge_seen.deinit(gpa);

                var frontier: std.ArrayList(VertexId) = .empty;
                defer frontier.deinit(gpa);
                var next: std.ArrayList(VertexId) = .empty;
                defer next.deinit(gpa);

                for (sources) |s| {
                    if (dist[s.index()] != 0) {
                        dist[s.index()] = 0;
                        try frontier.append(gpa, s);
                    }
                }

                var depth: u32 = 0;
                while (frontier.items.len != 0) : (depth += 1) {
                    next.clearRetainingCapacity();
                    for (frontier.items) |v| {
                        for (self.incident(v)) |e| {
                            if (edge_seen.isSet(e.index())) continue;
                            edge_seen.set(e.index());
                            for (self.members(e)) |u| {
                                if (dist[u.index()] != unreachable_dist) continue;
                                dist[u.index()] = depth + 1;
                                try next.append(gpa, u);
                            }
                        }
                    }
                    std.mem.swap(std.ArrayList(VertexId), &frontier, &next);
                }
            }

            pub const Components = struct {
                labels: []u32, // per vertex, compact 0..count-1
                count: u32,
                pub fn deinit(self: *Components, gpa: Allocator) void {
                    gpa.free(self.labels);
                    self.* = undefined;
                }
            };

            /// Connected components of the vertex side. One linear pass over
            /// the edge-major index array with a flat u32 union-find.
            /// Isolated vertices get their own component.
            pub fn components(self: Graph, gpa: Allocator) Allocator.Error!Components {
                const n = self.vertexCount();
                const parent = try gpa.alloc(u32, n);
                errdefer gpa.free(parent);
                for (parent, 0..) |*p, i| p.* = @intCast(i);

                for (0..self.edgeCount()) |e| {
                    const row = self.by_edge.rowAt(e);
                    if (row.len < 2) continue;
                    const first = row[0].index();
                    for (row[1..]) |v| unite(parent, first, v.index());
                }

                // Pass 1: flatten so parent[i] is i's root.
                for (0..n) |i| parent[i] = find(parent, @intCast(i));

                // Pass 2: compact labels in place. A root is always <= its
                // members (unite keeps the smaller index as root), so when we
                // reach i its root has already been relabelled, and parent[i]
                // itself hasn't been overwritten yet.
                var count: u32 = 0;
                for (0..n) |i| {
                    const r = parent[i];
                    if (r == i) {
                        parent[i] = count;
                        count += 1;
                    } else {
                        parent[i] = parent[r]; // r < i, already relabelled
                    }
                }
                return .{ .labels = parent, .count = count };
            }

            /// Reusable scratch for 2-section neighbour queries. A generation
            /// stamp replaces a hash set: "seen" is `stamps[v] == stamp`, and
            /// clearing is O(1) (bump the stamp).
            pub const NeighborScratch = struct {
                stamps: []u32,
                stamp: u32 = 0,

                pub fn init(gpa: Allocator, vertex_count: usize) Allocator.Error!NeighborScratch {
                    const s = try gpa.alloc(u32, vertex_count);
                    @memset(s, 0);
                    return .{ .stamps = s };
                }
                pub fn deinit(self: *NeighborScratch, gpa: Allocator) void {
                    gpa.free(self.stamps);
                    self.* = undefined;
                }
                fn next(self: *NeighborScratch) u32 {
                    self.stamp +%= 1;
                    if (self.stamp == 0) { // wrapped: reset once every 2^32 queries
                        @memset(self.stamps, 0);
                        self.stamp = 1;
                    }
                    return self.stamp;
                }
            };

            /// Appends every vertex sharing at least one hyperedge with `v`
            /// (excluding `v`) to `out`, in discovery order.
            pub fn neighbors(
                self: Graph,
                gpa: Allocator,
                v: VertexId,
                scratch: *NeighborScratch,
                out: *std.ArrayList(VertexId),
            ) Allocator.Error!void {
                const stamp = scratch.next();
                scratch.stamps[v.index()] = stamp;
                for (self.incident(v)) |e| {
                    for (self.members(e)) |u| {
                        if (scratch.stamps[u.index()] == stamp) continue;
                        scratch.stamps[u.index()] = stamp;
                        try out.append(gpa, u);
                    }
                }
            }

            /// Bytes used by topology (excludes payload).
            pub fn topologyBytes(self: Graph) usize {
                return (self.by_edge.offsets.len + self.by_vertex.offsets.len) * @sizeOf(u32) +
                    self.by_edge.cols.len * @sizeOf(VertexId) +
                    self.by_vertex.cols.len * @sizeOf(EdgeId);
            }
        };
    };
}

// ---------------------------------------------------------------------------
// Free helpers (kept out of the generic so they're instantiated once).
// ---------------------------------------------------------------------------

fn orderEdge(key: EdgeId, item: EdgeId) std.math.Order {
    return std.math.order(key.index(), item.index());
}

fn adjacentDiff(offsets: []const u32, out: []u32) void {
    std.debug.assert(out.len + 1 == offsets.len);
    for (out, offsets[0 .. offsets.len - 1], offsets[1..]) |*o, a, b| o.* = b - a;
}

fn gather(comptime T: type, comptime C: type, csr: C, in: []const T, out: []T) void {
    std.debug.assert(out.len == csr.rowCount());
    for (out, 0..) |*o, r| {
        var acc: T = 0;
        for (csr.rowAt(r)) |c| acc += in[c.index()];
        o.* = acc;
    }
}

fn find(parent: []u32, x0: u32) u32 {
    var x = x0;
    while (parent[x] != x) {
        parent[x] = parent[parent[x]]; // path halving
        x = parent[x];
    }
    return x;
}

fn unite(parent: []u32, a: u32, b: u32) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra == rb) return;
    // Smaller index becomes root: deterministic, and lets `components`
    // relabel in a single ascending pass.
    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
}

// ===========================================================================
// Tests  (zig test csr.zig)
// ===========================================================================

const testing = std.testing;

// Example payloads: SoA means `weight` and `name` live in separate arrays.
const Author = struct { weight: f32, name: []const u8 };
const Paper = struct { year: u16 };
const Coauthorship = BipartiteHypergraph(Author, Paper);

fn vx(i: u32) VertexId {
    return @enumFromInt(i);
}
fn ex(i: u32) EdgeId {
    return @enumFromInt(i);
}

/// 0..5 connected via three papers, 6 connected to 7, 8 isolated.
///   p0 = {2,0,1}   p1 = {3,2}   p2 = {3,4,5}   p3 = {7,6}
fn buildSample(gpa: Allocator) !Coauthorship.Graph {
    var b = try Coauthorship.Builder.init(gpa);
    errdefer b.deinit(gpa);
    try b.ensureTotalCapacity(gpa, 9, 4, 10);
    for (0..9) |i| _ = try b.addVertex(gpa, .{ .weight = @floatFromInt(i), .name = "a" });
    _ = try b.addEdge(gpa, .{ .year = 2020 }, &.{ vx(2), vx(0), vx(1) });
    _ = try b.addEdge(gpa, .{ .year = 2021 }, &.{ vx(3), vx(2) });
    _ = try b.addEdge(gpa, .{ .year = 2022 }, &.{ vx(3), vx(4), vx(5) });
    _ = try b.addEdge(gpa, .{ .year = 2023 }, &.{ vx(7), vx(6) });
    return b.finish(gpa);
}

test "build: member order kept; transpose sorted" {
    const gpa = testing.allocator;
    var g = try buildSample(gpa);
    defer g.deinit(gpa);

    try testing.expectEqual(@as(u32, 9), g.vertexCount());
    try testing.expectEqual(@as(u32, 4), g.edgeCount());
    try testing.expectEqual(@as(u32, 10), g.incidenceCount());

    try testing.expectEqualSlices(VertexId, &.{ vx(2), vx(0), vx(1) }, g.members(ex(0)));
    try testing.expectEqualSlices(EdgeId, &.{ ex(0), ex(1) }, g.incident(vx(2)));
    try testing.expectEqualSlices(EdgeId, &.{ ex(1), ex(2) }, g.incident(vx(3)));
    try testing.expectEqual(@as(usize, 0), g.incident(vx(8)).len);

    try testing.expect(g.contains(ex(2), vx(4)));
    try testing.expect(!g.contains(ex(2), vx(2)));

    var deg: [9]u32 = undefined;
    g.vertexDegrees(&deg);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 2, 2, 1, 1, 1, 1, 0 }, &deg);

    // SoA payload access: only the `year` column is touched.
    const years = g.edges.items(.year);
    try testing.expectEqual(@as(u16, 2022), years[2]);
}

test "repeated pins are kept (MOSFET with bulk tied to source)" {
    const gpa = testing.allocator;
    const H = BipartiteHypergraph(void, void);
    var b = try H.Builder.init(gpa);
    errdefer b.deinit(gpa);
    const d = try b.addVertex(gpa, {});
    const g_ = try b.addVertex(gpa, {});
    const s = try b.addVertex(gpa, {});
    _ = try b.addEdge(gpa, {}, &.{ d, g_, s, s }); // d g s b, b == s
    var g = try b.finish(gpa);
    defer g.deinit(gpa);

    try testing.expectEqualSlices(VertexId, &.{ d, g_, s, s }, g.members(ex(0)));
    try testing.expectEqualSlices(EdgeId, &.{ ex(0), ex(0) }, g.incident(s));
    try testing.expectEqual(@as(u32, 2), g.vertexDegree(s));
}

test "addEdge is all-or-nothing on invalid vertex" {
    const gpa = testing.allocator;
    var b = try Coauthorship.Builder.init(gpa);
    defer b.deinit(gpa);
    _ = try b.addVertex(gpa, .{ .weight = 1, .name = "x" });
    try testing.expectError(error.InvalidVertex, b.addEdge(gpa, .{ .year = 1 }, &.{ vx(0), vx(5) }));
    try testing.expectEqual(@as(u32, 0), b.edgeCount());
    try testing.expectEqual(@as(usize, 0), b.edge_members.items.len);
}

test "gather: Hᵀx then Hy" {
    const gpa = testing.allocator;
    var g = try buildSample(gpa);
    defer g.deinit(gpa);

    const x = g.vertices.items(.weight); // 0,1,2,...,8
    var edge_sum: [4]f32 = undefined;
    g.gatherToEdges(f32, x, &edge_sum);
    try testing.expectEqualSlices(f32, &.{ 3, 5, 12, 13 }, &edge_sum);

    var back: [9]f32 = undefined;
    g.gatherToVertices(f32, &edge_sum, &back);
    try testing.expectEqualSlices(f32, &.{ 3, 3, 8, 17, 12, 12, 13, 13, 0 }, &back);
}

test "bfs across hyperedges" {
    const gpa = testing.allocator;
    var g = try buildSample(gpa);
    defer g.deinit(gpa);

    var dist: [9]u32 = undefined;
    try g.bfs(gpa, &.{vx(0)}, &dist);
    const U = unreachable_dist;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1, 2, 3, 3, U, U, U }, &dist);
}

test "connected components" {
    const gpa = testing.allocator;
    var g = try buildSample(gpa);
    defer g.deinit(gpa);

    var cc = try g.components(gpa);
    defer cc.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), cc.count);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 0, 0, 1, 1, 2 }, cc.labels);
}

test "2-section neighbours with stamp scratch" {
    const gpa = testing.allocator;
    var g = try buildSample(gpa);
    defer g.deinit(gpa);

    var scratch = try Coauthorship.Graph.NeighborScratch.init(gpa, g.vertexCount());
    defer scratch.deinit(gpa);
    var out: std.ArrayList(VertexId) = .empty;
    defer out.deinit(gpa);

    try g.neighbors(gpa, vx(2), &scratch, &out);
    try testing.expectEqualSlices(VertexId, &.{ vx(0), vx(1), vx(3) }, out.items);

    out.clearRetainingCapacity(); // scratch reused, no clearing cost
    try g.neighbors(gpa, vx(3), &scratch, &out);
    try testing.expectEqualSlices(VertexId, &.{ vx(2), vx(4), vx(5) }, out.items);
}

test "no payload: void" {
    const gpa = testing.allocator;
    const H = BipartiteHypergraph(void, void);
    var b = try H.Builder.init(gpa);
    errdefer b.deinit(gpa);
    const a = try b.addVertex(gpa, {});
    const c = try b.addVertex(gpa, {});
    _ = try b.addEdge(gpa, {}, &.{ a, c });
    var g = try b.finish(gpa);
    defer g.deinit(gpa);
    try testing.expectEqual(@as(u32, 2), g.edgeSize(ex(0)));
}

test "randomised: both CSR directions agree" {
    const gpa = testing.allocator;
    const H = BipartiteHypergraph(struct {}, struct {});
    var prng = std.Random.DefaultPrng.init(0xB1_4A_27);
    const rand = prng.random();

    const nv = 500;
    const ne = 800;
    var b = try H.Builder.init(gpa);
    errdefer b.deinit(gpa);
    for (0..nv) |_| _ = try b.addVertex(gpa, .{});
    var buf: [16]VertexId = undefined;
    for (0..ne) |_| {
        const k = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..k]) |*m| m.* = VertexId.from(rand.uintLessThan(u32, nv));
        _ = try b.addEdge(gpa, .{}, buf[0..k]);
    }
    var g = try b.finish(gpa);
    defer g.deinit(gpa);

    // Pin counts match in both directions, and vertex-major rows are sorted.
    var total: usize = 0;
    for (0..g.vertexCount()) |vi| {
        const v = VertexId.from(vi);
        const row = g.by_vertex.rowAt(vi);
        for (row, 0..) |ed, j| {
            if (j > 0) try testing.expect(row[j - 1].index() <= ed.index());
            const pins_here = std.mem.count(VertexId, g.members(ed), &.{v});
            const listed = std.mem.count(EdgeId, row, &.{ed});
            try testing.expectEqual(pins_here, listed);
        }
        total += row.len;
    }
    try testing.expectEqual(@as(usize, g.incidenceCount()), total);
}

// ---------------------------------------------------------------------------
// Design notes
//
// Memory: topology costs 4·(|V|+1) + 4·(|E|+1) + 8·nnz bytes, with zero
// per-node headers or pointers. An adjacency-list-of-pointers design would
// pay a heap allocation per node plus 8 bytes per reference.
//
// Why store both directions? Scatter (for each e, for each v in e,
// out[v] += ...) produces random writes and needs atomics once parallel.
// Keeping the transpose turns every propagation into a gather: each output
// slot is written exactly once by one reader of a contiguous row.
//
// Mutation: the frozen graph is deliberately immutable. For workloads with
// heavy edits, batch changes into a new Builder and `finish()` again; the
// transpose is a linear counting sort, so rebuilds are cheap.
//
// Dual hypergraph: swap `by_edge` and `by_vertex` (and the payload types).
// `Csr` is shared by both sides for exactly this reason.
// ---------------------------------------------------------------------------
