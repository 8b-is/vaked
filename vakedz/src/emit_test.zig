// GENESIS_SEAL: 7c242080
//! Tests for emit.zig — canonical LPG JSON serialization.
//! Semantic spec: vakedc/emit.py `to_canonical_json` (compact separators
//! `(",", ":")`, `ensure_ascii=False`, trailing newline) + the frozen golden
//! tests/spec/golden/operator-field.graph.json, asserted BYTE-EXACT below
//! against the embedded copies of the example source and the golden bytes.
const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const emit = @import("emit.zig");
const lib = @import("lib");

fn parseAndBuild(a: std.mem.Allocator, src: []const u8, filename: []const u8) !resolve.Result {
    var l = lex.Lexer.init(a, src);
    try l.run();
    try testing.expectEqual(@as(usize, 0), l.errors.items.len);
    var p = parser.Parser.init(a, l.tokens.items);
    const items = try p.parseFile();
    return resolve.buildGraph(a, items, filename);
}

fn emitSource(a: std.mem.Allocator, src: []const u8, filename: []const u8) ![]u8 {
    var res = try parseAndBuild(a, src, filename);
    defer res.graph.deinit();
    return emit.toCanonicalJson(a, &res.graph, filename);
}

// --------------------------------------------------------------------------
// Golden parity: vaked/examples/operator-field.vaked (byte-exact embedded
// copy) must serialize to the byte-exact frozen golden
// tests/spec/golden/operator-field.graph.json (embedded below).
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

const operator_field_golden =
    \\{"version":1,"source":"vaked/examples/operator-field.vaked","nodes":[{"id":"external:./engines/zig.vaked","kind":"external","name":"./engines/zig.vaked","labels":["external"],"props":{"external":true},"provenance":null},{"id":"external:agentGuardd.ringbuf","kind":"external","name":"agentGuardd.ringbuf","labels":["external"],"props":{"external":true},"provenance":null},{"id":"external:agentpipe.screenrec","kind":"external","name":"agentpipe.screenrec","labels":["external"],"props":{"external":true},"provenance":null},{"id":"external:artifacts.compressedMedia","kind":"external","name":"artifacts.compressedMedia","labels":["external"],"props":{"external":true},"provenance":null},{"id":"external:graph.agentfield","kind":"external","name":"graph.agentfield","labels":["external"],"props":{"external":true},"provenance":null},{"id":"external:graph.workflow","kind":"external","name":"graph.workflow","labels":["external"],"props":{"external":true},"provenance":null},{"id":"external:zigDaemon","kind":"external","name":"zigDaemon","labels":["external"],"props":{"external":true},"provenance":null},{"id":"operator-field.vaked#","kind":"file","name":"operator-field.vaked","labels":["file"],"props":{},"provenance":null},{"id":"operator-field.vaked#operator-field","kind":"runtime","name":"operator-field","labels":["decl","runtime"],"props":{"systems":[{"lit":"string","value":"x86_64-linux"},{"lit":"string","value":"aarch64-linux"}]},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"runtime operator-field","span":{"byteStart":27,"byteEnd":1517,"line":3,"col":1}}},{"id":"operator-field.vaked#operator-field/agentGuardd","kind":"namespace","name":"agentGuardd","labels":["decl","namespace"],"props":{},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"namespace agentGuardd","span":{"byteStart":191,"byteEnd":237,"line":7,"col":3}}},{"id":"operator-field.vaked#operator-field/agentpipe","kind":"namespace","name":"agentpipe","labels":["decl","namespace"],"props":{},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"namespace agentpipe","span":{"byteStart":240,"byteEnd":309,"line":10,"col":3}}},{"id":"operator-field.vaked#operator-field/ebpfEvents","kind":"stream","name":"ebpfEvents","labels":["decl","stream"],"props":{"retention":{"lit":"duration","value":"24h"},"source":{"ref":"agentGuardd.ringbuf"},"type":{"ref":"Event.Ebpf"}},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"stream ebpfEvents","span":{"byteStart":758,"byteEnd":856,"line":31,"col":3}}},{"id":"operator-field.vaked#operator-field/mediaCompress","kind":"fiber","name":"mediaCompress","labels":["decl","fiber"],"props":{"engine":{"ref":"zigDaemon"},"input":{"ref":"stream.screenrec"},"output":{"ref":"artifacts.compressedMedia"}},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"fiber mediaCompress","span":{"byteStart":955,"byteEnd":1175,"line":43,"col":3}}},{"id":"operator-field.vaked#operator-field/operator-runtime","kind":"parallel","name":"operator-runtime","labels":["decl","parallel"],"props":{"fibers":[{"ref":"mediaCompress"},{"ref":"operatorMap"}],"strategy":{"lit":"string","value":"supervised-dag"},"supervisor":{"ref":"otp"}},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"parallel operator-runtime","span":{"byteStart":1387,"byteEnd":1515,"line":62,"col":3}}},{"id":"operator-field.vaked#operator-field/operatorMap","kind":"surface","name":"operatorMap","labels":["decl","surface"],"props":{"fps":{"lit":"number","value":"60"},"input":[{"ref":"stream.ebpfEvents"},{"ref":"graph.workflow"},{"ref":"graph.agentfield"}],"mode":{"ref":"raylib"},"views":[{"lit":"string","value":"network-flows"},{"lit":"string","value":"workflow-dag"},{"lit":"string","value":"filesystem-diff"},{"lit":"string","value":"mesh-topology"}]},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"surface operatorMap","span":{"byteStart":1179,"byteEnd":1383,"line":55,"col":3}}},{"id":"operator-field.vaked#operator-field/screenrec","kind":"stream","name":"screenrec","labels":["decl","stream"],"props":{"fps":{"lit":"number","value":"10"},"source":{"ref":"agentpipe.screenrec"},"type":{"ref":"Media.Frame"}},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"stream screenrec","span":{"byteStart":860,"byteEnd":951,"line":37,"col":3}}},{"id":"operator-field.vaked#operator-field/zigCorpus","kind":"index","name":"zigCorpus","labels":["decl","index"],"props":{"emit":[{"ref":"catalog.jsonl"},{"ref":"catalog.sqlite"},{"ref":"nix.derivation"}],"normalize":{"ref":"crabcc.markdown"},"source":[{"args":[{"lit":"string","value":"Sobeston/zig.guide"}],"ref":"github"},{"args":[{"lit":"string","value":"C-BJ/awesome-zig"}],"ref":"github"},{"args":[{"lit":"string","value":"raylib-zig/raylib-zig"}],"ref":"github"},{"args":[{"lit":"string","value":"zigimg/zigimg"}],"ref":"github"}]},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"index zigCorpus","span":{"byteStart":313,"byteEnd":556,"line":15,"col":3}}},{"id":"operator-field.vaked#operator-field/zigbeeFirmware","kind":"index","name":"zigbeeFirmware","labels":["decl","index"],"props":{"schema":{"ref":"schema.zigbeeOta"},"source":{"args":[{"lit":"string","value":"Koenkk/zigbee-OTA"},{"lit":"string","value":"index.json"}],"ref":"raw.github"},"trust":{"record":[{"assign":"commit","op":"=","value":{"lit":"string","value":"<commit>"}},{"assign":"sha256","op":"=","value":{"lit":"string","value":"<sha256>"}}],"ref":"pinned"}},"provenance":{"file":"vaked/examples/operator-field.vaked","decl":"index zigbeeFirmware","span":{"byteStart":560,"byteEnd":754,"line":22,"col":3}}}],"edges":[{"from":"operator-field.vaked#","to":"external:./engines/zig.vaked","label":"imports","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/agentGuardd","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/agentpipe","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/ebpfEvents","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/mediaCompress","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/operator-runtime","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/operatorMap","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/screenrec","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/zigCorpus","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field","to":"operator-field.vaked#operator-field/zigbeeFirmware","label":"contains","props":{}},{"from":"operator-field.vaked#operator-field/ebpfEvents","to":"external:agentGuardd.ringbuf","label":"depends_on","props":{}},{"from":"operator-field.vaked#operator-field/mediaCompress","to":"external:artifacts.compressedMedia","label":"depends_on","props":{}},{"from":"operator-field.vaked#operator-field/mediaCompress","to":"external:zigDaemon","label":"depends_on","props":{}},{"from":"operator-field.vaked#operator-field/mediaCompress","to":"operator-field.vaked#operator-field/screenrec","label":"depends_on","props":{}},{"from":"operator-field.vaked#operator-field/operator-runtime","to":"operator-field.vaked#operator-field/mediaCompress","label":"member_of","props":{}},{"from":"operator-field.vaked#operator-field/operator-runtime","to":"operator-field.vaked#operator-field/operatorMap","label":"member_of","props":{}},{"from":"operator-field.vaked#operator-field/operatorMap","to":"external:graph.agentfield","label":"depends_on","props":{}},{"from":"operator-field.vaked#operator-field/operatorMap","to":"external:graph.workflow","label":"depends_on","props":{}},{"from":"operator-field.vaked#operator-field/operatorMap","to":"operator-field.vaked#operator-field/ebpfEvents","label":"depends_on","props":{}},{"from":"operator-field.vaked#operator-field/screenrec","to":"external:agentpipe.screenrec","label":"depends_on","props":{}}]}
++ "\n";

test "golden: operator-field.vaked serializes byte-exact to the frozen golden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // fixture-integrity guards: the embedded copies must stay byte-identical
    // to vaked/examples/operator-field.vaked (1518 bytes) and
    // tests/spec/golden/operator-field.graph.json (8294 bytes)
    try testing.expectEqual(@as(usize, 1518), operator_field_src.len);
    try testing.expectEqual(@as(usize, 8294), operator_field_golden.len);

    // the golden was produced by `python3 -m vakedc parse
    // vaked/examples/operator-field.vaked` — same relative path here
    const out = try emitSource(a, operator_field_src, "vaked/examples/operator-field.vaked");
    try testing.expectEqualStrings(operator_field_golden, out);
}

// --------------------------------------------------------------------------
// Unit behavior (emit.py semantics, isolated)
// --------------------------------------------------------------------------

test "empty graph: fixed top-level key order, compact separators, trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = lib.graph.Graph.init(a);
    defer g.deinit();
    const out = try emit.toCanonicalJson(a, &g, "x.vaked");
    try testing.expectEqualStrings("{\"version\":1,\"source\":\"x.vaked\",\"nodes\":[],\"edges\":[]}\n", out);
}

test "nodes are sorted by id regardless of declaration order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\engine zeta {
        \\}
        \\engine alpha {
        \\}
    ++ "\n";
    const out = try emitSource(a, src, "s.vaked");
    const zeta = std.mem.indexOf(u8, out, "s.vaked#zeta").?;
    const alpha = std.mem.indexOf(u8, out, "s.vaked#alpha").?;
    try testing.expect(alpha < zeta);
}

test "props object keys are sorted recursively (Python _canon_value)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // assignment insertion order zebra, apple — emit must sort them; the app
    // config-block value serializes {"record":[...],"ref":"cfg"} (sorted:
    // record < ref, insertion order was ref first)
    const src =
        \\engine e {
        \\  zebra = 1
        \\  apple = cfg {
        \\    b = 2
        \\  }
        \\}
    ++ "\n";
    const out = try emitSource(a, src, "s.vaked");
    const apple = std.mem.indexOf(u8, out, "\"apple\":").?;
    const zebra = std.mem.indexOf(u8, out, "\"zebra\":").?;
    try testing.expect(apple < zebra);
    try testing.expect(std.mem.indexOf(u8, out, "{\"record\":[{\"assign\":\"b\",\"op\":\"=\",\"value\":{\"lit\":\"number\",\"value\":\"2\"}}],\"ref\":\"cfg\"}") != null);
}

test "routes_to edges: (from,label,to,props-json) order with stable props tiebreak" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // same (from,label,to) twice with differing label props: the props-JSON
    // tiebreak (Python json.dumps sort_keys=True) must order "aa" before "bb"
    const src =
        \\mesh m {
        \\  x -> y : "bb"
        \\  x -> y : "aa"
        \\}
    ++ "\n";
    const out = try emitSource(a, src, "s.vaked");
    const aa = std.mem.indexOf(u8, out, "{\"label\":\"aa\"}").?;
    const bb = std.mem.indexOf(u8, out, "{\"label\":\"bb\"}").?;
    try testing.expect(aa < bb);
}

test "ensure_ascii=False parity: non-ASCII strings pass through as raw UTF-8" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\engine e {
        \\  motto = "héllo — wörld"
        \\}
    ++ "\n";
    const out = try emitSource(a, src, "s.vaked");
    try testing.expect(std.mem.indexOf(u8, out, "{\"lit\":\"string\",\"value\":\"héllo — wörld\"}") != null);
}

test "provenance span: {byteStart,byteEnd,line,col} without a file key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\engine e {
        \\}
    ++ "\n";
    const out = try emitSource(a, src, "d/s.vaked");
    // provenance.file is the path as passed; the span object has no file key
    try testing.expect(std.mem.indexOf(u8, out, "\"provenance\":{\"file\":\"d/s.vaked\",\"decl\":\"engine e\",\"span\":{\"byteStart\":0,\"byteEnd\":12,\"line\":1,\"col\":1}}") != null);
}
