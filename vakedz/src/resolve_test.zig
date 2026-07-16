// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const lib = @import("lib");

fn parseAndBuild(a: std.mem.Allocator, src: []const u8, path: []const u8) !lib.graph.Graph {
    var l = lex.Lexer.init(a, src);
    try l.run();
    var p = parser.Parser.init(a, l.tokens.items);
    const items = try p.parseFile();
    return resolve.buildGraph(a, items, path);
}

test "resolve single decl produces file and decl node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parseAndBuild(a, "engine zigDaemon {\n}\n", "test.vaked");
    defer g.deinit();

    try testing.expect(g.hasNode("test#"));
    try testing.expect(g.hasNode("test#zigDaemon"));

    const file_node = g.getNode("test#").?;
    try testing.expectEqualStrings("file", file_node.kind);

    const decl_node = g.getNode("test#zigDaemon").?;
    try testing.expectEqualStrings("engine", decl_node.kind);
    try testing.expectEqualStrings("zigDaemon", decl_node.name);

    try testing.expectEqual(@as(usize, 1), g.edges.items.len);
    try testing.expectEqualStrings("contains", g.edges.items[0].label);
}

test "resolve edge creates deferred edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\runtime main {
        \\  input = zigDaemon
        \\}
        \\engine zigDaemon {
        \\}
    ;
    var g = try parseAndBuild(a, src, "app.vaked");
    defer g.deinit();

    try testing.expect(g.hasNode("app#"));
    try testing.expect(g.hasNode("app#main"));
    try testing.expect(g.hasNode("app#zigDaemon"));

    var found_depends = false;
    for (g.edges.items) |e| {
        if (std.mem.eql(u8, e.label, "depends_on")) {
            found_depends = true;
            try testing.expectEqualStrings("app#main", e.source);
            try testing.expectEqualStrings("app#zigDaemon", e.target);
        }
    }
    try testing.expect(found_depends);
}

test "resolve import creates external node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parseAndBuild(a, "use \"./other.vaked\"\n", "main.vaked");
    defer g.deinit();

    try testing.expect(g.hasNode("main#"));
    var found_imports = false;
    for (g.edges.items) |e| {
        if (std.mem.eql(u8, e.label, "imports")) {
            found_imports = true;
        }
    }
    try testing.expect(found_imports);
}

test "resolve member creates member_of edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "namespace channels {\n  member log\n}";
    var g = try parseAndBuild(a, src, "ns.vaked");
    defer g.deinit();

    try testing.expect(g.hasNode("ns#channels"));
    try testing.expect(g.hasNode("ns#channels/log"));

    var found_member = false;
    for (g.edges.items) |e| {
        if (std.mem.eql(u8, e.label, "member_of")) {
            found_member = true;
            try testing.expectEqualStrings("ns#channels/log", e.source);
            try testing.expectEqualStrings("ns#channels", e.target);
        }
    }
    try testing.expect(found_member);
}
