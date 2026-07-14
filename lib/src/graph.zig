// GENESIS_SEAL: 7c242080
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

    pub fn addNode(self: *Graph, node: GraphNode) !void {
        try self.nodes.put(node.id, node);
    }

    pub fn getNode(self: *const Graph, id: []const u8) ?GraphNode {
        return self.nodes.get(id);
    }

    pub fn hasNode(self: *const Graph, id: []const u8) bool {
        return self.nodes.contains(id);
    }

    pub fn addEdge(self: *Graph, edge: GraphEdge) !void {
        try self.edges.append(self.allocator, edge);
    }
};

pub fn nodeId(filename: []const u8, chain: []const []const u8) []const u8 {
    const stem = blk: {
        if (std.mem.endsWith(u8, filename, ".vaked")) {
            break :blk filename[0 .. filename.len - ".vaked".len];
        }
        break :blk filename;
    };

    const alloc = std.heap.page_allocator;

    if (chain.len == 0) {
        return std.fmt.allocPrint(alloc, "{s}#", .{stem}) catch @panic("nodeId OOM");
    }

    var total: usize = stem.len + 1;
    for (chain, 0..) |c, i| {
        total += c.len;
        if (i < chain.len - 1) total += 1;
    }

    const buf = alloc.alloc(u8, total) catch @panic("nodeId OOM");
    var pos: usize = 0;

    @memcpy(buf[pos .. pos + stem.len], stem);
    pos += stem.len;
    buf[pos] = '#';
    pos += 1;

    for (chain, 0..) |c, i| {
        @memcpy(buf[pos .. pos + c.len], c);
        pos += c.len;
        if (i < chain.len - 1) {
            buf[pos] = '/';
            pos += 1;
        }
    }

    return buf;
}
