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
    try g.addNode(n);
    const got = g.getNode("test#runtime");
    try testing.expect(got != null);
    try testing.expectEqualStrings("runtime", got.?.kind);
}

test "nodeId generation" {
    const id = graph.nodeId("test.vaked", &.{ "runtime", "fiber" });
    try testing.expectEqualStrings("test#runtime/fiber", id);
}
