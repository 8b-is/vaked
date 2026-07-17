// GENESIS_SEAL: 7c242080
//! Tests for resolve.zig — two-pass LPG construction.
//! Semantic spec: vakedc/resolve.py + the frozen golden
//! tests/spec/golden/operator-field.graph.json (structural parity asserted
//! below against the embedded example sources).
const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const lib = @import("lib");

fn parseAndBuild(a: std.mem.Allocator, src: []const u8, filename: []const u8) !resolve.Result {
    var l = lex.Lexer.init(a, src);
    try l.run();
    try testing.expectEqual(@as(usize, 0), l.errors.items.len);
    var p = parser.Parser.init(a, l.tokens.items);
    const items = try p.parseFile();
    return resolve.buildGraph(a, items, filename);
}

fn expectEdge(g: *const lib.graph.Graph, source: []const u8, target: []const u8, label: []const u8) !void {
    for (g.edges.items) |e| {
        if (std.mem.eql(u8, e.source, source) and
            std.mem.eql(u8, e.target, target) and
            std.mem.eql(u8, e.label, label)) return;
    }
    std.debug.print("missing edge: {s} => {s} [{s}]\n", .{ source, target, label });
    return error.TestExpectedEdge;
}

fn propValue(node: lib.graph.GraphNode, key: []const u8) ?lib.json.Value {
    switch (node.props) {
        .object => |entries| {
            for (entries) |e| {
                if (std.mem.eql(u8, e.key, key)) return e.value;
            }
            return null;
        },
        else => return null,
    }
}

test "single decl: decl node with labels + provenance, no file node, no edges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var res = try parseAndBuild(a, "engine zigDaemon {\n}\n", "test.vaked");
    defer res.graph.deinit();

    // no `use` import -> vakedc creates no file node
    try testing.expect(!res.graph.hasNode("test.vaked#"));
    try testing.expect(res.graph.hasNode("test.vaked#zigDaemon"));

    const n = res.graph.getNode("test.vaked#zigDaemon").?;
    try testing.expectEqualStrings("engine", n.kind);
    try testing.expectEqualStrings("zigDaemon", n.name);
    try testing.expectEqual(@as(usize, 2), n.labels.len);
    try testing.expectEqualStrings("decl", n.labels[0]);
    try testing.expectEqualStrings("engine", n.labels[1]);

    const prov = n.provenance.?;
    try testing.expectEqualStrings("test.vaked", prov.file);
    try testing.expectEqualStrings("engine zigDaemon", prov.decl);
    try testing.expectEqual(@as(usize, 0), prov.span.byte_start);
    try testing.expectEqual(@as(usize, 20), prov.span.byte_end);
    try testing.expectEqual(@as(usize, 1), prov.span.line);
    try testing.expectEqual(@as(usize, 1), prov.span.col);

    try testing.expectEqual(@as(usize, 0), res.graph.edges.items.len);
    try testing.expectEqual(@as(usize, 0), res.diagnostics.len);
}

test "import creates file node, external stub, imports edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var res = try parseAndBuild(a, "use \"./other.vaked\"\n", "main.vaked");
    defer res.graph.deinit();

    const file_node = res.graph.getNode("main.vaked#").?;
    try testing.expectEqualStrings("file", file_node.kind);
    try testing.expectEqualStrings("main.vaked", file_node.name);
    try testing.expectEqual(@as(usize, 1), file_node.labels.len);
    try testing.expectEqualStrings("file", file_node.labels[0]);

    const stub = res.graph.getNode("external:./other.vaked").?;
    try testing.expectEqualStrings("external", stub.kind);
    try testing.expectEqualStrings("./other.vaked", stub.name);
    try testing.expectEqualStrings("external", stub.labels[0]);
    const ext_flag = propValue(stub, "external").?;
    try testing.expect(ext_flag.bool);

    try testing.expectEqual(@as(usize, 1), res.graph.edges.items.len);
    try expectEdge(&res.graph, "main.vaked#", "external:./other.vaked", "imports");
}

test "depends_on: forward bare ref, kind-qualified ref, external dotted ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\fiber compress {
        \\  engine = zigDaemon
        \\  input = stream.screenrec
        \\}
        \\stream screenrec {
        \\  source = agentpipe.screenrec
        \\}
        \\engine zigDaemon {
        \\}
    ;
    var res = try parseAndBuild(a, src, "app.vaked");
    defer res.graph.deinit();

    // top-level decls have no parent: no contains edges, no file node
    try testing.expect(!res.graph.hasNode("app.vaked#"));
    try testing.expectEqual(@as(u32, 4), res.graph.nodes.count());
    try testing.expectEqual(@as(usize, 3), res.graph.edges.items.len);

    // forward ref to a later sibling resolves in-file
    try expectEdge(&res.graph, "app.vaked#compress", "app.vaked#zigDaemon", "depends_on");
    // <kind>.<name> addressing of an in-file decl of that kind
    try expectEdge(&res.graph, "app.vaked#compress", "app.vaked#screenrec", "depends_on");
    // dotted head not in scope -> external stub keyed by full dotted path
    try expectEdge(&res.graph, "app.vaked#screenrec", "external:agentpipe.screenrec", "depends_on");

    // assignments are also recorded as props
    const compress = res.graph.getNode("app.vaked#compress").?;
    const engine_prop = propValue(compress, "engine").?;
    switch (engine_prop) {
        .object => |entries| {
            try testing.expectEqualStrings("ref", entries[0].key);
            try testing.expectEqualStrings("zigDaemon", entries[0].value.string);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "routes_to: mesh arrow chain with label prop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\mesh net {
        \\  a -> b -> c : "grpc"
        \\}
    ;
    var res = try parseAndBuild(a, src, "m.vaked");
    defer res.graph.deinit();

    // net + external a/b/c
    try testing.expectEqual(@as(u32, 4), res.graph.nodes.count());
    try testing.expectEqual(@as(usize, 2), res.graph.edges.items.len);
    try expectEdge(&res.graph, "external:a", "external:b", "routes_to");
    try expectEdge(&res.graph, "external:b", "external:c", "routes_to");
    for (res.graph.edges.items) |e| {
        const entries = e.props.object;
        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqualStrings("label", entries[0].key);
        try testing.expectEqualStrings("grpc", entries[0].value.string);
    }
}

test "parallel fibers become member_of edges and a fibers prop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\fiber one {
        \\}
        \\parallel group {
        \\  fibers = [one, two]
        \\}
    ;
    var res = try parseAndBuild(a, src, "p.vaked");
    defer res.graph.deinit();

    try expectEdge(&res.graph, "p.vaked#group", "p.vaked#one", "member_of");
    try expectEdge(&res.graph, "p.vaked#group", "external:two", "member_of");
    try testing.expectEqual(@as(usize, 2), res.graph.edges.items.len);

    const group = res.graph.getNode("p.vaked#group").?;
    const fibers = propValue(group, "fibers").?;
    try testing.expectEqual(@as(usize, 2), fibers.array.len);
}

test "capabilities list produces requires_capability edges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\service svc {
        \\  capabilities = [fs.read, net]
        \\}
    ;
    var res = try parseAndBuild(a, src, "c.vaked");
    defer res.graph.deinit();

    try expectEdge(&res.graph, "c.vaked#svc", "external:fs.read", "requires_capability");
    try expectEdge(&res.graph, "c.vaked#svc", "external:net", "requires_capability");
    try testing.expectEqual(@as(usize, 2), res.graph.edges.items.len);
}

test "duplicate decl id: first wins, diagnostic emitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\engine dup {
        \\}
        \\stream dup {
        \\}
    ;
    var res = try parseAndBuild(a, src, "d.vaked");
    defer res.graph.deinit();

    // keep-first: the engine survives, the stream is dropped
    try testing.expectEqualStrings("engine", res.graph.getNode("d.vaked#dup").?.kind);
    try testing.expectEqual(@as(u32, 1), res.graph.nodes.count());

    try testing.expectEqual(@as(usize, 1), res.diagnostics.len);
    const diag = res.diagnostics[0];
    try testing.expectEqualStrings("E-DECL-NAME-COLLISION", diag.code);
    try testing.expectEqual(lib.diagnostic.Severity.@"error", diag.severity);
    try testing.expectEqualStrings("stream dup", diag.decl);
}

test "nesting: inner decl and node block get contains edges; trivia skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\# leading file comment
        \\runtime top {
        \\  # inner comment
        \\  namespace ns {
        \\    member log
        \\  }
        \\
        \\  node worker {
        \\    replicas = 3
        \\  }
        \\}
    ;
    var res = try parseAndBuild(a, src, "r.vaked");
    defer res.graph.deinit();

    try testing.expect(res.graph.hasNode("r.vaked#top"));
    try testing.expect(res.graph.hasNode("r.vaked#top/ns"));
    try testing.expect(res.graph.hasNode("r.vaked#top/worker"));
    try testing.expectEqual(@as(u32, 3), res.graph.nodes.count());

    try expectEdge(&res.graph, "r.vaked#top", "r.vaked#top/ns", "contains");
    try expectEdge(&res.graph, "r.vaked#top", "r.vaked#top/worker", "contains");
    try testing.expectEqual(@as(usize, 2), res.graph.edges.items.len);

    // `member log` contributes nothing to the graph (vakedc parity)
    const ns = res.graph.getNode("r.vaked#top/ns").?;
    try testing.expectEqual(@as(usize, 0), ns.props.object.len);

    const worker = res.graph.getNode("r.vaked#top/worker").?;
    try testing.expectEqualStrings("node", worker.kind);
    try testing.expectEqual(@as(usize, 1), worker.labels.len);
    try testing.expectEqualStrings("node", worker.labels[0]);
    const replicas = propValue(worker, "replicas").?;
    switch (replicas) {
        .object => |entries| {
            try testing.expectEqualStrings("lit", entries[0].key);
            try testing.expectEqualStrings("number", entries[0].value.string);
            try testing.expectEqualStrings("value", entries[1].key);
            try testing.expectEqualStrings("3", entries[1].value.string);
        },
        else => return error.TestUnexpectedResult,
    }
}

// --------------------------------------------------------------------------
// Parity: vaked/examples/primitives/fiber.vaked (byte-exact embedded copy).
// Expected shape generated by the reference Python pipeline
// (vakedc.resolve.build_graph): 4 nodes, 3 edges.
// --------------------------------------------------------------------------

const fiber_src =
    \\# Minimal v0.2 example — fiber primitive
    \\# Demonstrates: engine ref-app, input/output ref-apps, policy app+record,
    \\#               bool and string literals in policy body.
    \\
    \\fiber mediaCompress {
    \\  engine = zigimg
    \\  input = stream.screenrec
    \\  output = artifacts.compressedMedia
    \\
    \\  policy {
    \\    strip_metadata = true
    \\    max_pixels = "4K"
    \\    formats = ["png", "webp"]
    \\  }
    \\}
++ "\n";

test "parity: fiber.vaked matches the Python reference graph" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var res = try parseAndBuild(a, fiber_src, "fiber.vaked");
    defer res.graph.deinit();

    try testing.expectEqual(@as(u32, 4), res.graph.nodes.count());
    try testing.expectEqual(@as(usize, 3), res.graph.edges.items.len);
    try testing.expectEqual(@as(usize, 0), res.diagnostics.len);

    const mc = res.graph.getNode("fiber.vaked#mediaCompress").?;
    try testing.expectEqualStrings("fiber", mc.kind);
    const prov = mc.provenance.?;
    try testing.expectEqual(@as(usize, 175), prov.span.byte_start);
    try testing.expectEqual(@as(usize, 374), prov.span.byte_end);
    try testing.expectEqual(@as(usize, 5), prov.span.line);
    try testing.expectEqual(@as(usize, 1), prov.span.col);

    try testing.expect(res.graph.hasNode("external:zigimg"));
    try testing.expect(res.graph.hasNode("external:stream.screenrec"));
    try testing.expect(res.graph.hasNode("external:artifacts.compressedMedia"));

    try expectEdge(&res.graph, "fiber.vaked#mediaCompress", "external:zigimg", "depends_on");
    try expectEdge(&res.graph, "fiber.vaked#mediaCompress", "external:stream.screenrec", "depends_on");
    try expectEdge(&res.graph, "fiber.vaked#mediaCompress", "external:artifacts.compressedMedia", "depends_on");

    // bare `policy { ... }` app statement stays out of props (no over-edging,
    // no prop) — vakedc parity
    try testing.expect(propValue(mc, "policy") == null);
}

// --------------------------------------------------------------------------
// Parity: vaked/examples/operator-field.vaked (byte-exact embedded copy)
// against the frozen golden tests/spec/golden/operator-field.graph.json:
// 18 nodes, 20 edges.
// --------------------------------------------------------------------------

const operator_field_src =
    \\use "./engines/zig.vaked"
    \\
    \\runtime "operator-field" {
    \\  systems = ["x86_64-linux", "aarch64-linux"]
    \\
    \\  # Daemon-channel namespaces declared for this runtime (RFC 0017, D3: runtime-scoped).
    \\  namespace agentGuardd {
    \\    member ringbuf
    \\  }
    \\  namespace agentpipe {
    \\    member transcripts
    \\    member screenrec
    \\  }
    \\
    \\  index zigCorpus {
    \\    source = [github("Sobeston/zig.guide"), github("C-BJ/awesome-zig"), github("raylib-zig/raylib-zig"), github("zigimg/zigimg")]
    \\
    \\    normalize = crabcc.markdown
    \\    emit = [catalog.jsonl, catalog.sqlite, nix.derivation]
    \\  }
    \\
    \\  index zigbeeFirmware {
    \\    source = raw.github("Koenkk/zigbee-OTA", "index.json")
    \\    schema = schema.zigbeeOta
    \\    trust = pinned {
    \\      commit = "<commit>"
    \\      sha256 = "<sha256>"
    \\    }
    \\  }
    \\
    \\  stream ebpfEvents {
    \\    source = agentGuardd.ringbuf
    \\    type = Event.Ebpf
    \\    retention = 24h
    \\  }
    \\
    \\  stream screenrec {
    \\    source = agentpipe.screenrec
    \\    type = Media.Frame
    \\    fps = 10
    \\  }
    \\
    \\  fiber mediaCompress {
    \\    engine = zigDaemon
    \\    input = stream.screenrec
    \\    output = artifacts.compressedMedia
    \\
    \\    policy {
    \\      strip_metadata = true
    \\      max_pixels = "4K"
    \\      formats = ["png", "webp"]
    \\    }
    \\  }
    \\
    \\  surface operatorMap {
    \\    mode = raylib
    \\    fps = 60
    \\    input = [stream.ebpfEvents, graph.workflow, graph.agentfield]
    \\    views = ["network-flows", "workflow-dag", "filesystem-diff", "mesh-topology"]
    \\  }
    \\
    \\  parallel "operator-runtime" {
    \\    fibers = [mediaCompress, operatorMap]
    \\    strategy = "supervised-dag"
    \\    supervisor = otp
    \\  }
    \\}
++ "\n";

const ExpectedNode = struct { id: []const u8, kind: []const u8 };
const ExpectedEdge = struct { source: []const u8, target: []const u8, label: []const u8 };

const of_expected_nodes = [_]ExpectedNode{
    .{ .id = "external:./engines/zig.vaked", .kind = "external" },
    .{ .id = "external:agentGuardd.ringbuf", .kind = "external" },
    .{ .id = "external:agentpipe.screenrec", .kind = "external" },
    .{ .id = "external:artifacts.compressedMedia", .kind = "external" },
    .{ .id = "external:graph.agentfield", .kind = "external" },
    .{ .id = "external:graph.workflow", .kind = "external" },
    .{ .id = "external:zigDaemon", .kind = "external" },
    .{ .id = "operator-field.vaked#", .kind = "file" },
    .{ .id = "operator-field.vaked#operator-field", .kind = "runtime" },
    .{ .id = "operator-field.vaked#operator-field/agentGuardd", .kind = "namespace" },
    .{ .id = "operator-field.vaked#operator-field/agentpipe", .kind = "namespace" },
    .{ .id = "operator-field.vaked#operator-field/ebpfEvents", .kind = "stream" },
    .{ .id = "operator-field.vaked#operator-field/mediaCompress", .kind = "fiber" },
    .{ .id = "operator-field.vaked#operator-field/operator-runtime", .kind = "parallel" },
    .{ .id = "operator-field.vaked#operator-field/operatorMap", .kind = "surface" },
    .{ .id = "operator-field.vaked#operator-field/screenrec", .kind = "stream" },
    .{ .id = "operator-field.vaked#operator-field/zigCorpus", .kind = "index" },
    .{ .id = "operator-field.vaked#operator-field/zigbeeFirmware", .kind = "index" },
};

const of_expected_edges = [_]ExpectedEdge{
    .{ .source = "operator-field.vaked#", .target = "external:./engines/zig.vaked", .label = "imports" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/agentGuardd", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/agentpipe", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/ebpfEvents", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/mediaCompress", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/operator-runtime", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/operatorMap", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/screenrec", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/zigCorpus", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field", .target = "operator-field.vaked#operator-field/zigbeeFirmware", .label = "contains" },
    .{ .source = "operator-field.vaked#operator-field/ebpfEvents", .target = "external:agentGuardd.ringbuf", .label = "depends_on" },
    .{ .source = "operator-field.vaked#operator-field/mediaCompress", .target = "external:artifacts.compressedMedia", .label = "depends_on" },
    .{ .source = "operator-field.vaked#operator-field/mediaCompress", .target = "external:zigDaemon", .label = "depends_on" },
    .{ .source = "operator-field.vaked#operator-field/mediaCompress", .target = "operator-field.vaked#operator-field/screenrec", .label = "depends_on" },
    .{ .source = "operator-field.vaked#operator-field/operator-runtime", .target = "operator-field.vaked#operator-field/mediaCompress", .label = "member_of" },
    .{ .source = "operator-field.vaked#operator-field/operator-runtime", .target = "operator-field.vaked#operator-field/operatorMap", .label = "member_of" },
    .{ .source = "operator-field.vaked#operator-field/operatorMap", .target = "external:graph.agentfield", .label = "depends_on" },
    .{ .source = "operator-field.vaked#operator-field/operatorMap", .target = "external:graph.workflow", .label = "depends_on" },
    .{ .source = "operator-field.vaked#operator-field/operatorMap", .target = "operator-field.vaked#operator-field/ebpfEvents", .label = "depends_on" },
    .{ .source = "operator-field.vaked#operator-field/screenrec", .target = "external:agentpipe.screenrec", .label = "depends_on" },
};

test "parity: operator-field.vaked matches the frozen golden graph shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // guard: the embedded copy must stay byte-identical to the example file
    try testing.expectEqual(@as(usize, 1518), operator_field_src.len);

    var res = try parseAndBuild(a, operator_field_src, "operator-field.vaked");
    defer res.graph.deinit();

    try testing.expectEqual(@as(u32, 18), res.graph.nodes.count());
    try testing.expectEqual(@as(usize, 20), res.graph.edges.items.len);
    try testing.expectEqual(@as(usize, 0), res.diagnostics.len);

    for (of_expected_nodes) |exp| {
        const n = res.graph.getNode(exp.id) orelse {
            std.debug.print("missing node: {s}\n", .{exp.id});
            return error.TestExpectedNode;
        };
        try testing.expectEqualStrings(exp.kind, n.kind);
    }
    for (of_expected_edges) |exp| {
        try expectEdge(&res.graph, exp.source, exp.target, exp.label);
    }

    // spot-check provenance against the golden (byte-exact spans)
    const root = res.graph.getNode("operator-field.vaked#operator-field").?;
    try testing.expectEqualStrings("operator-field", root.name);
    const root_prov = root.provenance.?;
    try testing.expectEqualStrings("runtime operator-field", root_prov.decl);
    try testing.expectEqual(@as(usize, 27), root_prov.span.byte_start);
    try testing.expectEqual(@as(usize, 1517), root_prov.span.byte_end);
    try testing.expectEqual(@as(usize, 3), root_prov.span.line);
    try testing.expectEqual(@as(usize, 1), root_prov.span.col);

    const mc_prov = res.graph.getNode("operator-field.vaked#operator-field/mediaCompress").?.provenance.?;
    try testing.expectEqual(@as(usize, 955), mc_prov.span.byte_start);
    try testing.expectEqual(@as(usize, 1175), mc_prov.span.byte_end);
    try testing.expectEqual(@as(usize, 43), mc_prov.span.line);
    try testing.expectEqual(@as(usize, 3), mc_prov.span.col);

    // quoted-name parallel: fibers prop recorded alongside member_of edges
    const par = res.graph.getNode("operator-field.vaked#operator-field/operator-runtime").?;
    try testing.expectEqualStrings("operator-runtime", par.name);
    const fibers = propValue(par, "fibers").?;
    try testing.expectEqual(@as(usize, 2), fibers.array.len);
}
