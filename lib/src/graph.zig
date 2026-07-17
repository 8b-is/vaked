// GENESIS_SEAL: 7c242080
//! Labeled Property Graph (LPG) containers — the semantic-graph model shared
//! by the resolver and later pipeline stages (mirrors vakedc/graph.py).
//!
//! Ownership: `Graph` does NOT own any string or props storage reachable from
//! its nodes and edges. Callers keep `id`/`kind`/`name`/`labels`/`props`
//! slices alive for the graph's lifetime (arena-style: allocate them from an
//! arena that outlives the graph). `deinit` frees only container storage.
const std = @import("std");
const span = @import("span.zig");
const json = @import("json.zig");

pub const GraphNode = struct {
    id: []const u8,
    kind: []const u8,
    name: []const u8,
    labels: []const []const u8,
    props: json.Value,
    provenance: ?span.Provenance,
};

pub const GraphEdge = struct {
    source: []const u8,
    target: []const u8,
    label: []const u8,
    props: json.Value,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(GraphNode),
    edges: std.ArrayListUnmanaged(GraphEdge),

    pub fn init(allocator: std.mem.Allocator) Graph {
        return Graph{
            .allocator = allocator,
            .nodes = std.StringHashMap(GraphNode).init(allocator),
            .edges = .empty,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit();
        self.edges.deinit(self.allocator);
    }

    /// Insert `node`, keyed by `node.id`. Duplicate ids are NOT overwritten:
    /// the first insertion wins (vakedc keep-first semantics) and `false` is
    /// returned so the caller can surface a diagnostic. Returns `true` when
    /// the node was actually inserted. The graph does not copy `node`'s
    /// strings — the caller keeps them alive (see module doc).
    pub fn addNode(self: *Graph, node: GraphNode) error{OutOfMemory}!bool {
        const gop = try self.nodes.getOrPut(node.id);
        if (gop.found_existing) return false;
        gop.value_ptr.* = node;
        return true;
    }

    pub fn getNode(self: *const Graph, id: []const u8) ?GraphNode {
        return self.nodes.get(id);
    }

    pub fn hasNode(self: *const Graph, id: []const u8) bool {
        return self.nodes.contains(id);
    }

    /// Append `edge`. Edges are a plain list: duplicates are allowed and
    /// insertion order is preserved (matches vakedc's `Graph.add_edge`).
    pub fn addEdge(self: *Graph, edge: GraphEdge) error{OutOfMemory}!void {
        try self.edges.append(self.allocator, edge);
    }
};

/// Stable, path-derived node id: `<filename>#<seg>/<seg>/...`.
///
/// `filename` is used verbatim — the caller passes the file's basename with
/// its extension intact, exactly like vakedc's `graph.node_id` (e.g.
/// `operator-field.vaked#operator-field`; an empty chain yields
/// `operator-field.vaked#`, the file node's id). Caller owns the returned
/// slice.
pub fn nodeId(
    allocator: std.mem.Allocator,
    filename: []const u8,
    chain: []const []const u8,
) error{OutOfMemory}![]u8 {
    var total: usize = filename.len + 1;
    for (chain, 0..) |c, i| {
        total += c.len;
        if (i > 0) total += 1;
    }

    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    var pos: usize = 0;

    @memcpy(buf[pos .. pos + filename.len], filename);
    pos += filename.len;
    buf[pos] = '#';
    pos += 1;

    for (chain, 0..) |c, i| {
        if (i > 0) {
            buf[pos] = '/';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + c.len], c);
        pos += c.len;
    }

    return buf;
}
