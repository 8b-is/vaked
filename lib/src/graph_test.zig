// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const graph = @import("graph.zig");
const json = @import("json.zig");

test "GraphNode construction" {
    const n = graph.GraphNode{
        .id = "test#runtime",
        .kind = "runtime",
        .name = "runtime",
        .labels = &.{},
        .props = json.Value{ .object = &.{} },
        .provenance = null,
    };
    try testing.expectEqualStrings("runtime", n.kind);
}

test "Graph addNode" {
    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    const n = graph.GraphNode{
        .id = "test#runtime",
        .kind = "runtime",
        .name = "runtime",
        .labels = &.{},
        .props = json.Value{ .object = &.{} },
        .provenance = null,
    };
    try testing.expect(try g.addNode(n));
    const got = g.getNode("test#runtime");
    try testing.expect(got != null);
    try testing.expectEqualStrings("runtime", got.?.kind);
}

test "addNode keeps first on duplicate id and reports it" {
    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    try testing.expect(try g.addNode(.{
        .id = "a#dup",
        .kind = "engine",
        .name = "dup",
        .labels = &.{},
        .props = json.Value{ .object = &.{} },
        .provenance = null,
    }));
    // same id, different kind: not inserted, first node survives
    try testing.expect(!try g.addNode(.{
        .id = "a#dup",
        .kind = "stream",
        .name = "dup",
        .labels = &.{},
        .props = json.Value{ .object = &.{} },
        .provenance = null,
    }));
    try testing.expectEqualStrings("engine", g.getNode("a#dup").?.kind);
    try testing.expectEqual(@as(u32, 1), g.nodes.count());
}

test "nodeId generation" {
    // Full basename kept, extension included — vakedc node_id parity.
    const id = try graph.nodeId(testing.allocator, "test.vaked", &.{ "runtime", "fiber" });
    defer testing.allocator.free(id);
    try testing.expectEqualStrings("test.vaked#runtime/fiber", id);

    const file_id = try graph.nodeId(testing.allocator, "test.vaked", &.{});
    defer testing.allocator.free(file_id);
    try testing.expectEqualStrings("test.vaked#", file_id);
}

test "Graph addEdge and hasNode" {
    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    _ = try g.addNode(.{
        .id = "a#x",
        .kind = "fiber",
        .name = "x",
        .labels = &.{},
        .props = json.Value{ .object = &.{} },
        .provenance = null,
    });
    try testing.expect(g.hasNode("a#x"));
    try testing.expect(!g.hasNode("a#y"));
    try g.addEdge(.{
        .source = "a#",
        .target = "a#x",
        .label = "contains",
        .props = json.Value{ .object = &.{} },
    });
    try testing.expectEqual(@as(usize, 1), g.edges.items.len);
    try testing.expectEqualStrings("contains", g.edges.items[0].label);
}
