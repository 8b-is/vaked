// GENESIS_SEAL: 7c242080
//! Tests for check.zig — 0011 conformance core (slice 1).
//! Semantic spec: vakedc/check.py; the frozen golden
//! tests/spec/golden/rejected.diagnostics.json fixes the exact codes and
//! message strings asserted below for the conformance-class diagnostics of
//! vaked/examples/types/rejected.vaked. Byte-exact span parity against the
//! real example files is owned by the differential harness
//! (tools/check-diff/run.sh); these tests use embedded sources and locate
//! expected spans by substring offset.
const std = @import("std");
const testing = std.testing;
const check = @import("check.zig");
const parser = @import("parser.zig");

/// Excerpt of vaked/schema/builtins.vaked — the schemas/capabilities the
/// tests below exercise, field-for-field identical to the real catalog
/// (which the CLI parses at runtime; the differential harness covers it).
const mini_builtins =
    \\schema runtime {
    \\  field systems : List<String> { nonempty }
    \\}
    \\
    \\schema engine {
    \\  field package  : Derivation
    \\  field optimize : String { optional
    \\                            oneof ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"] }
    \\}
    \\
    \\schema stream {
    \\  field source    : Source
    \\  field type      : TypeRef
    \\  field retention : Duration { optional }
    \\  field fps       : Int      { optional > 0 }
    \\}
    \\
    \\schema fiber {
    \\  field engine  : Engine
    \\  field input   : I
    \\  field output  : O
    \\  field policy  : Policy  { optional }
    \\  field budget  : Budget  { optional }
    \\  field runclass : RunClass { optional }
    \\  field observe : Bool    { optional default = false }
    \\}
    \\
    \\schema fiberPolicy {
    \\  field strip_metadata : Bool         { optional }
    \\  field max_pixels     : String       { optional }
    \\  field formats        : List<String> { optional nonempty }
    \\  open
    \\}
    \\
    \\schema surface {
    \\  field mode   : SurfaceMode
    \\  field fps    : Int { optional > 0 }
    \\  field input  : List<Stream<T> | Graph | Catalog<T>> { nonempty }
    \\  field views  : List<View> { nonempty }
    \\  field budget : Budget { optional }
    \\}
    \\
    \\schema mesh {
    \\}
    \\
    \\schema meshNode {
    \\  field role         : String { nonempty }
    \\  field capabilities : List<Capability> { optional nonempty }
    \\  open
    \\}
    \\
    \\schema parallel {
    \\  field fibers     : List<Fiber<I, O>> { nonempty }
    \\  field strategy   : Strategy
    \\  field supervisor : Supervisor
    \\}
    \\
    \\schema workflow {
    \\  field on       : String { optional nonempty }
    \\  field budget   : Budget { optional }
    \\  field maxDepth : Int    { optional > 0 }
    \\}
    \\
    \\schema workflowStep {
    \\  field agent   : MeshNode
    \\  field input   : I      { optional }
    \\  field output  : O      { optional }
    \\  field budget  : Budget { optional }
    \\  field retries : Int    { optional >= 0 }
    \\  field control : Bool   { optional default = false }
    \\  field effects : List<String> { optional nonempty }
    \\  open
    \\}
    \\
    \\schema secret {
    \\  field provider : String { oneof ["sops", "age", "vault"] default = "sops" }
    \\  field name     : String { nonempty }
    \\  field owner    : String { optional }
    \\  field mode     : String { optional matches /0[0-7]{3}/ }
    \\}
    \\
    \\schema trust {
    \\  field score      : Float
    \\  field half_life  : Duration      { optional }
    \\  field delegate   : TrustRef      { optional }
    \\  field taint_as   : Bool          { optional }
    \\}
    \\
    \\schema quorum {
    \\  field min        : Int             { > 0 }
    \\  field over       : List<NodeRef>   { nonempty }
    \\  field timeout    : Duration
    \\  field on_failure : FailurePolicy
    \\}
    \\
    \\schema probe {
    \\  field from      : NodeRef
    \\  field to        : NodeRef
    \\  field via       : EdgeRef
    \\  field with      : CapabilityRef { optional }
    \\  field on_result : Block         { optional }
    \\}
    \\
    \\schema catalog {
    \\  field from : Index<T>
    \\  field key  : List<String> { optional nonempty }
    \\  field emit : ArtifactTarget | List<ArtifactTarget>
    \\}
    \\
    \\schema index {
    \\  field source    : Source | List<Source> { nonempty }
    \\  field schema    : Schema<T>   { optional }
    \\  field normalize : Normalizer  { optional }
    \\  field emit      : List<ArtifactTarget> { optional nonempty }
    \\}
    \\
    \\schema networkMembrane {
    \\  field principal : String { nonempty }
    \\  field default   : String { optional oneof ["deny", "allow"] default = "deny" }
    \\  field allow     : List<EgressRule> { optional nonempty }
    \\  field observe   : Stream<T> { optional }
    \\}
    \\
    \\capability fs {
    \\  grant none repo_ro repo_rw host_ro host_rw
    \\  order none < repo_ro < repo_rw < host_rw ;
    \\        repo_ro < host_ro < host_rw
    \\}
    \\
    \\capability network {
    \\  grant none loopback lan egress
    \\  order none < loopback < lan < egress
    \\}
    \\
    \\namespace pkgs { open }
    \\
    \\namespace eventd { member log }
    \\
;

const b_file = "builtins.vaked";
const u_file = "t.vaked";

fn runCheck(a: std.mem.Allocator, src: []const u8) ![]const @import("lib").diagnostic.Diagnostic {
    const b_items = switch (try check.parseSource(a, mini_builtins, b_file)) {
        .ok => |items| items,
        .fail => return error.BuiltinsParseFailed,
    };
    switch (try check.checkSource(a, src, u_file, .{ .items = b_items, .src = mini_builtins, .file = b_file }, "", null)) {
        .ok => |diags| return diags,
        .fail => return error.CheckParseFailed,
    }
}

fn countCode(diags: anytype, code: []const u8) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, code)) n += 1;
    }
    return n;
}

fn firstWithCode(diags: anytype, code: []const u8) ?@import("lib").diagnostic.Diagnostic {
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, code)) return d;
    }
    return null;
}

test "clean conformant decl: no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\stream telemetry {
        \\  source = agentGuardd.ringbuf
        \\  type = Event.Ebpf
        \\  fps = 30
        \\  retention = 24h
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "missing required fields, in schema field order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a, "stream empty {\n}\n");
    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqualStrings("E-CONFORM-MISSING-FIELD", diags[0].code);
    try testing.expectEqualStrings("required field `source` of schema `stream` is missing", diags[0].message);
    try testing.expectEqualStrings("required field `type` of schema `stream` is missing", diags[1].message);
    try testing.expectEqualStrings("stream empty", diags[0].decl);
    // span = the whole decl
    try testing.expectEqual(@as(usize, 0), diags[0].byte_start);
}

test "unknown field in closed schema: golden message, span on the field name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\stream telemetry {
        \\  source = agentGuardd.ringbuf
        \\  type = Event.Ebpf
        \\  colour = "red"
        \\}
        \\
    ;
    const diags = try runCheck(a, src);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONFORM-UNKNOWN-FIELD", diags[0].code);
    // exact message from tests/spec/golden/rejected.diagnostics.json
    try testing.expectEqualStrings("`colour` is not a declared field of closed schema `stream`", diags[0].message);
    const off = std.mem.indexOf(u8, src, "colour").?;
    try testing.expectEqual(off, diags[0].byte_start);
    try testing.expectEqual(off + "colour".len, diags[0].byte_end);
    try testing.expectEqual(@as(usize, 4), diags[0].line);
    try testing.expectEqual(@as(usize, 3), diags[0].col);
}

test "cmp constraint: golden E-CONSTRAINT-RANGE message, span on the value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\stream telemetry {
        \\  source = agentGuardd.ringbuf
        \\  type = Event.Ebpf
        \\  fps = 0
        \\}
        \\
    ;
    const diags = try runCheck(a, src);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONSTRAINT-RANGE", diags[0].code);
    // exact message from tests/spec/golden/rejected.diagnostics.json
    try testing.expectEqualStrings("field `fps`: value 0 violates `> 0`", diags[0].message);
    const off = std.mem.indexOf(u8, src, "fps = 0").? + "fps = ".len;
    try testing.expectEqual(off, diags[0].byte_start);
    try testing.expectEqual(off + 1, diags[0].byte_end);
}

test "scalar type mismatch: E-CONFORM-TYPE with rendered value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\stream s {
        \\  source = agentGuardd.ringbuf
        \\  type = Event.Ebpf
        \\  fps = "high"
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONFORM-TYPE", diags[0].code);
    try testing.expectEqualStrings("field `fps` of schema `stream` expects `Int` but got \"high\"", diags[0].message);
}

test "Int literal widens to Float (score : Float accepts 1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a, "trust t {\n  score = 1\n}\n");
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "Float literal does not narrow to Int" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\stream s {
        \\  source = x.y
        \\  type = T.U
        \\  fps = 2.5
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONFORM-TYPE", diags[0].code);
}

test "ref passes permissively for a non-scalar atom; string rejected for it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `source : Source` — a ref cannot be disproven (§2.3), a string can.
    const ok = try runCheck(a, "stream s {\n  source = pkgs.someSource\n  type = T.U\n}\n");
    try testing.expectEqual(@as(usize, 0), ok.len);
    const bad = try runCheck(a, "stream s {\n  source = \"not a ref\"\n  type = T.U\n}\n");
    try testing.expectEqual(@as(usize, 1), bad.len);
    try testing.expectEqualStrings("E-CONFORM-TYPE", bad[0].code);
}

test "oneof violation on engine optimize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a, "engine e {\n  package = pkgs.zig\n  optimize = \"Debugg\"\n}\n");
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONSTRAINT-ONEOF", diags[0].code);
    try testing.expectEqualStrings("field `optimize`: value \"Debugg\" is not one of [\"Debug\", \"ReleaseSafe\", \"ReleaseFast\", \"ReleaseSmall\"]", diags[0].message);
}

test "nonempty violation on an empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a, "runtime r {\n  systems = []\n}\n");
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONSTRAINT-NONEMPTY", diags[0].code);
    try testing.expectEqualStrings("field `systems` is `nonempty` but the value is empty", diags[0].message);
}

test "optional fields may be omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a, "engine e {\n  package = pkgs.zig\n}\n");
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "trust/quorum/probe conformance via the kind dispatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // trust: missing required `score`
    const t = try runCheck(a, "trust t {\n}\n");
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqualStrings("E-CONFORM-MISSING-FIELD", t[0].code);
    try testing.expectEqualStrings("required field `score` of schema `trust` is missing", t[0].message);
    // quorum: min = 0 violates `> 0`
    const q = try runCheck(a,
        \\quorum q {
        \\  min = 0
        \\  over = [nodeA]
        \\  timeout = 5s
        \\  on_failure = fallback.freeze
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), q.len);
    try testing.expectEqualStrings("E-CONSTRAINT-RANGE", q[0].code);
    try testing.expectEqualStrings("field `min`: value 0 violates `> 0`", q[0].message);
    // probe: missing from/to/via
    const p = try runCheck(a, "probe p {\n}\n");
    try testing.expectEqual(@as(usize, 3), p.len);
    try testing.expectEqualStrings("required field `from` of schema `probe` is missing", p[0].message);
    try testing.expectEqualStrings("required field `to` of schema `probe` is missing", p[1].message);
    try testing.expectEqualStrings("required field `via` of schema `probe` is missing", p[2].message);
}

test "matches refinement: violating and conforming mode values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try runCheck(a, "secret s {\n  name = \"tok\"\n  mode = \"0999\"\n}\n");
    try testing.expectEqual(@as(usize, 1), bad.len);
    try testing.expectEqualStrings("E-CONSTRAINT-MATCHES", bad[0].code);
    try testing.expectEqualStrings("field `mode`: value \"0999\" does not match /0[0-7]{3}/", bad[0].message);
    const ok = try runCheck(a, "secret s {\n  name = \"tok\"\n  mode = \"0755\"\n}\n");
    try testing.expectEqual(@as(usize, 0), ok.len);
}

test "mesh node body conforms against meshNode (open schema)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\mesh m {
        \\  node author {
        \\    freeform = "ok because meshNode is open"
        \\  }
        \\}
        \\
    );
    // role required and missing; the unknown field is fine (open)
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONFORM-MISSING-FIELD", diags[0].code);
    try testing.expectEqualStrings("required field `role` of schema `meshNode` is missing", diags[0].message);
    try testing.expectEqualStrings("node author", diags[0].decl);
}

test "workflow step conforms against workflowStep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\workflow w {
        \\  node plan {
        \\    retries = 3
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("required field `agent` of schema `workflowStep` is missing", diags[0].message);
    try testing.expectEqualStrings("node plan", diags[0].decl);
}

test "app-with-record in field position of a closed schema is an unknown field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\parallel workers {
        \\  fibers = [fiber.a]
        \\  strategy = "round_robin"
        \\  supervisor = otp.one_for_one
        \\  backpressure {
        \\    policy = "drop"
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONFORM-UNKNOWN-FIELD", diags[0].code);
    try testing.expectEqualStrings("`backpressure` is not a declared field of closed schema `parallel`", diags[0].message);
}

test "fiber policy block conforms against the nested fiberPolicy schema" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\fiber f {
        \\  engine = engine.z
        \\  input = stream.s
        \\  output = artifacts.out
        \\  policy {
        \\    strip_metadata = "yes"
        \\    formats = []
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 2), diags.len);
    const ty = firstWithCode(diags, "E-CONFORM-TYPE").?;
    try testing.expectEqualStrings("field `strip_metadata` of nested schema `fiberPolicy` expects `Bool` but got \"yes\"", ty.message);
    const ne = firstWithCode(diags, "E-CONSTRAINT-NONEMPTY").?;
    try testing.expectEqualStrings("field `formats` is `nonempty` but the value is empty", ne.message);
}

test "surface input: union-in-generic List accepts refs, rejects scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try runCheck(a,
        \\surface hud {
        \\  mode = raylib.overlay
        \\  input = [stream.telemetry, graph.main]
        \\  views = ["timeline"]
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 0), ok.len);
    const bad = try runCheck(a,
        \\surface hud {
        \\  mode = raylib.overlay
        \\  input = [42]
        \\  views = ["timeline"]
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), bad.len);
    try testing.expectEqualStrings("E-CONFORM-TYPE", bad[0].code);
}

test "user schema overrides builtin, range refinement enforced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\schema stream {
        \\  field fps : Int { in 1 .. 10 }
        \\}
        \\
        \\stream s {
        \\  fps = 20
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-CONSTRAINT-RANGE", diags[0].code);
    try testing.expectEqualStrings("field `fps`: value 20 is outside `in 1 .. 10`", diags[0].message);
}

test "load-time schema well-formedness diagnostics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\schema bad {
        \\  field a : Int    { matches /x+/ }
        \\  field b : String { matches /(?=x)y/ }
        \\  field c : String { oneof [1, "ok"] }
        \\  field d : Int    { in 5 .. 1 }
        \\  field e : Int    { default = ref.y }
        \\  field f : String { default = 3 }
        \\  field g : String { required optional }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), countCode(diags, "E-SCHEMA-BAD-REGEX"));
    try testing.expectEqual(@as(usize, 1), countCode(diags, "E-SCHEMA-BAD-ONEOF"));
    try testing.expectEqual(@as(usize, 1), countCode(diags, "E-SCHEMA-BAD-RANGE"));
    try testing.expectEqual(@as(usize, 2), countCode(diags, "E-SCHEMA-BAD-DEFAULT"));
    // matches-on-Int + required/optional clash
    try testing.expectEqual(@as(usize, 2), countCode(diags, "E-SCHEMA-REFINEMENT"));
    const rx = firstWithCode(diags, "E-SCHEMA-BAD-REGEX").?;
    try testing.expectEqualStrings("field `b`: lookahead ((?=…)) is not in the bounded dialect", rx.message);
    const oo = firstWithCode(diags, "E-SCHEMA-BAD-ONEOF").?;
    try testing.expectEqualStrings("field `c`: `oneof` element 1 does not match type `String`", oo.message);
}

test "capability order: dangling grant and cycle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dangling = try runCheck(a,
        \\capability net {
        \\  grant low high
        \\  order low < mid < high
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), dangling.len);
    try testing.expectEqualStrings("E-CAP-ORDER-DANGLING", dangling[0].code);
    try testing.expectEqualStrings("capability `net`: order names grant `mid` which is not declared by a `grant` statement", dangling[0].message);
    const cyclic = try runCheck(a,
        \\capability net {
        \\  grant a b
        \\  order a < b ;
        \\        b < a
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), cyclic.len);
    try testing.expectEqualStrings("E-CAP-ORDER-CYCLE", cyclic[0].code);
}

test "namespace mixing open with members is a load-time error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a, "namespace mixed {\n  open\n  member x\n}\n");
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("E-SCHEMA-REFINEMENT", diags[0].code);
    try testing.expectEqualStrings("namespace `mixed`: body mixes `open` with `member` declarations; use `open` alone (any member) or `member <name>` alone (closed set)", diags[0].message);
}

test "collision enriched: keyword span, Python message, related first-decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\schema dup {
        \\}
        \\
        \\capability dup {
        \\  grant x
        \\}
        \\
    ;
    const diags = try runCheck(a, src);
    try testing.expectEqual(@as(usize, 1), diags.len);
    const d = diags[0];
    try testing.expectEqualStrings("E-DECL-NAME-COLLISION", d.code);
    try testing.expectEqualStrings("capability dup", d.decl);
    try testing.expectEqualStrings("`capability dup` collides with `schema dup` (a different kind, same name): top-level declarations share a kind-agnostic graph id, so the later one is silently dropped — rename one", d.message);
    // span lands on the `capability` keyword token
    const kw = std.mem.indexOf(u8, src, "capability").?;
    try testing.expectEqual(kw, d.byte_start);
    try testing.expectEqual(kw + "capability".len, d.byte_end);
    // related points back at the first declaration
    try testing.expectEqual(@as(usize, 1), d.related.len);
    try testing.expectEqualStrings("schema dup", d.related[0].decl);
    try testing.expectEqualStrings("first declared here as `schema dup`", d.related[0].message);
    try testing.expectEqual(@as(usize, 0), d.related[0].span.byte_start);
}

test "duplicate node names are NOT collision diagnostics (check.py parity)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\mesh m {
        \\  node a {
        \\    role = "x"
        \\  }
        \\  node a {
        \\    role = "y"
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E-DECL-NAME-COLLISION"));
}

test "diagnostics sorted by (file, byteStart, byteEnd, code)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\stream z {
        \\  colour = "red"
        \\}
        \\
        \\stream y {
        \\}
        \\
    );
    var i: usize = 1;
    while (i < diags.len) : (i += 1) {
        const x = diags[i - 1];
        const y = diags[i];
        const le = x.byte_start < y.byte_start or
            (x.byte_start == y.byte_start and x.byte_end < y.byte_end) or
            (x.byte_start == y.byte_start and x.byte_end == y.byte_end and
                std.mem.order(u8, x.code, y.code) != .gt);
        try testing.expect(le);
    }
}

test "regex engine: bounded-dialect semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/0[0-7]{3}/", "0755"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/0[0-7]{3}/", "0999"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/0[0-7]{3}/", "07555"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a|bc/", "bc"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/(ab)+c?/", "ababc"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/(ab)+c?/", "aab"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/\\d{2,4}/", "123"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/\\d{2,4}/", "12345"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/[a-z_][a-z0-9_]*/", "snake_case9"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/[a-z_][a-z0-9_]*/", "9nope"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/^ab$/", "ab"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a\\.b/", "a.b"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/a\\.b/", "axb"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/x*/", ""));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/[^0-9]+/", "abc"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/[^0-9]+/", "a1c"));
}

test "regex engine: lazy quantifiers accept like greedy (never literal '?')" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a+?/", "aa"));
    // regression: the trailing '?' must not match as a literal char
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/a+?/", "aa?"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a*?/", ""));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a{1,2}?/", "aa"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/a{1,2}?/", "aaa"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a{2}?/", "aa"));
}

test "regex engine: word boundaries, \\A/\\Z anchors, hex and class escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/\\bfoo\\b/", "foo"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/foo\\B/", "foo"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/\\Bfoo/", "foo"));
    // \b between word chars is not a boundary
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/fo\\bo/", "foo"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/fo\\Bo/", "foo"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/\\Afoo\\Z/", "foo"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a\\x41/", "aA"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/a\\x41/", "aB"));
    // inside a class, \b is BACKSPACE (Python semantics)
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/[\\b]/", "\x08"));
}

test "regex engine: unsupported escapes and bad classes skip (null, like Python re.error)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // reserved ASCII-letter escape — re.error in Python too
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/\\q/", "q"));
    // \uXXXX compiles in Python but is unsupported here → skip, never mis-check
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/\\uABCD/", "x"));
    // inverted range — re.error in Python
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/[z-a]/", "x"));
    // bare \x without two hex digits — re.error in Python
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/\\x4/", "x"));
}

test "regex engine: nested counted repetition is capped, sane nesting works" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ~10^6 compiled instructions — must refuse (BadRegex → null), not OOM
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/((a{100}){100}){100}/", "aaa"));
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/(a{2}){2}/", "aaaa"));
    try testing.expectEqual(@as(?bool, false), try check.regexFullMatch(a, "/(a{2}){2}/", "aaa"));
}

test "nested sibling collision: scopenote says 'sibling declarations'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\runtime r {
        \\  systems = ["one"]
        \\  schema dup {
        \\  }
        \\  capability dup {
        \\    grant x
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), countCode(diags, "E-DECL-NAME-COLLISION"));
    const d = firstWithCode(diags, "E-DECL-NAME-COLLISION").?;
    try testing.expectEqualStrings("`capability dup` collides with `schema dup` (a different kind, same name): sibling declarations share a kind-agnostic graph id, so the later one is silently dropped — rename one", d.message);
    try testing.expectEqual(@as(usize, 1), d.related.len);
}

test "collision inside a dropped duplicate body is filtered (check.py parity)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // resolve.zig reports TWO collisions here (the second `runtime dup` AND
    // its inner `stream s`, whose kind-agnostic chain id dup/s already
    // exists); check.py reports only the top-level one — the second
    // runtime's body is a fresh sibling scope.
    const diags = try runCheck(a,
        \\runtime dup {
        \\  systems = ["one"]
        \\  stream s {
        \\    source = a.b
        \\    type = c.d
        \\  }
        \\}
        \\
        \\runtime dup {
        \\  systems = ["one"]
        \\  stream s {
        \\    source = a.b
        \\    type = c.d
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), countCode(diags, "E-DECL-NAME-COLLISION"));
    const d = firstWithCode(diags, "E-DECL-NAME-COLLISION").?;
    try testing.expectEqualStrings("runtime dup", d.decl);
}

// --------------------------------------------------------------------------- #
// Slice 2 — capabilities / POLA / egress / ref walk / workflow / ebpf /
// generics / determinism. Message strings mirror check.py f-strings; the
// differential harness (zero allowlist) owns byte-exact parity on the corpus.
// --------------------------------------------------------------------------- #

test "regex fences: octal continuation and multiple repeat refuse (skip)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // \07 is octal BEL in Python — must skip (null), never NUL+'7'
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/\\07/", "\x007"));
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/[\\07]/", "x"));
    // bare \0 stays NUL (Python parity)
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/\\0/", "\x00"));
    // multiple repeat — re.error (or possessive) in CPython → skip
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/a**/", "aa"));
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/a++/", "aa"));
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/a{2}*/", "aaaa"));
    try testing.expectEqual(@as(?bool, null), try check.regexFullMatch(a, "/a+?*/", "aa"));
    // literal '{' that is not a quantifier still works
    try testing.expectEqual(@as(?bool, true), try check.regexFullMatch(a, "/a{x/", "a{x"));
}

test "E-CAP-UNKNOWN-DOMAIN / E-CAP-UNKNOWN-GRANT with empty decl label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\mesh m {
        \\  node w {
        \\    role = "x"
        \\    capabilities = [warp.jump, fs.fly]
        \\  }
        \\}
        \\
    );
    const ud = firstWithCode(diags, "E-CAP-UNKNOWN-DOMAIN").?;
    try testing.expectEqualStrings("unknown capability domain `warp` in `warp.jump`", ud.message);
    try testing.expectEqualStrings("", ud.decl); // check.py _decl_label(NodeDecl) → ""
    const ug = firstWithCode(diags, "E-CAP-UNKNOWN-GRANT").?;
    try testing.expectEqualStrings("`fly` is not a declared grant of capability domain `fs`", ug.message);
}

test "E-CAP-ATTENUATION on an escalating delegation edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\mesh m {
        \\  node author {
        \\    role = "a"
        \\    capabilities = [fs.repo_ro]
        \\  }
        \\  node reviewer {
        \\    role = "r"
        \\    capabilities = [fs.repo_rw]
        \\  }
        \\  author -> reviewer
        \\}
        \\
    );
    const d = firstWithCode(diags, "E-CAP-ATTENUATION").?;
    try testing.expectEqualStrings("delegation `author -> reviewer` escalates authority: receiver holds `fs.repo_rw` but sender holds fs.repo_ro (receiver's grant must be ≤ the sender's in domain `fs`)", d.message);
    try testing.expectEqualStrings("mesh m", d.decl);
}

test "E-CAP-USE underpowered node and W-POLA-EXCESS overpowered node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\mesh m {
        \\  node under {
        \\    role = "u"
        \\    capabilities = [fs.repo_ro]
        \\    needs = [fs.repo_rw]
        \\  }
        \\  node over {
        \\    role = "o"
        \\    capabilities = [fs.host_rw]
        \\    needs = [fs.repo_rw]
        \\  }
        \\}
        \\
    );
    const use = firstWithCode(diags, "E-CAP-USE").?;
    try testing.expectEqualStrings("node `under` uses `fs.repo_rw` (declared in `needs`) but holds fs.repo_ro — a held grant must dominate every exercised capability (0011 §4.3)", use.message);
    try testing.expect(use.severity == .@"error");
    const excess = firstWithCode(diags, "W-POLA-EXCESS").?;
    try testing.expectEqualStrings("node `over` holds `fs.host_rw` but declares it needs only fs.repo_rw — granted more authority than its declared need (least-authority violation)", excess.message);
    try testing.expect(excess.severity == .warning);
}

test "E-CAP-USE with no grants in domain renders '(none in domain fs)'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\mesh m {
        \\  node w {
        \\    role = "x"
        \\    needs = [fs.repo_rw]
        \\  }
        \\}
        \\
    );
    const d = firstWithCode(diags, "E-CAP-USE").?;
    try testing.expectEqualStrings("node `w` uses `fs.repo_rw` (declared in `needs`) but holds (none in domain fs) — a held grant must dominate every exercised capability (0011 §4.3)", d.message);
}

test "W-CONFUSED-DEPUTY on a two-caller capability-holding sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\mesh m {
        \\  node cron {
        \\    role = "c"
        \\  }
        \\  node worker {
        \\    role = "w"
        \\  }
        \\  node proxy {
        \\    role = "p"
        \\    capabilities = [fs.repo_ro]
        \\  }
        \\  cron -> proxy
        \\  worker -> proxy
        \\}
        \\
    );
    const d = firstWithCode(diags, "W-CONFUSED-DEPUTY").?;
    try testing.expectEqualStrings("node `proxy` is a shared deputy: 2 distinct callers (`cron`, `worker`) delegate to it while it holds fs.repo_ro under its own identity (confused-deputy shape) — keep delegation inside Vaked-minted capabilities (0026 §2)", d.message);
    try testing.expect(d.severity == .warning);
}

test "W-EGRESS-UNREFINED and E-EGRESS-USE via a sibling membrane" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // top-level mesh: no membranes in scope → unrefined warning only
    const un = try runCheck(a,
        \\mesh m {
        \\  node worker {
        \\    role = "w"
        \\    capabilities = [network.egress]
        \\  }
        \\}
        \\
    );
    const w = firstWithCode(un, "W-EGRESS-UNREFINED").?;
    try testing.expectEqualStrings("node `worker` holds `network.egress` but no networkMembrane refines it — egress is unbounded (least-authority advisory; add a `network` membrane with an `allow` set)", w.message);
    try testing.expect(w.severity == .warning);
    // membrane sibling inside a runtime: loopback grant, public egress allow
    const ex = try runCheck(a,
        \\runtime r {
        \\  systems = ["x"]
        \\  mesh m {
        \\    node worker {
        \\      role = "w"
        \\      capabilities = [network.loopback]
        \\    }
        \\  }
        \\  network workerCordon {
        \\    principal = "worker"
        \\    allow = [egress("api.example.com", 443)]
        \\  }
        \\}
        \\
    );
    const e = firstWithCode(ex, "E-EGRESS-USE").?;
    try testing.expectEqualStrings("membrane `workerCordon` allows egress at level `egress` for principal `worker` which holds network.loopback — a membrane cannot authorize egress beyond the principal's granted network capability (0026)", e.message);
    // the refined principal does NOT also get the unrefined warning
    try testing.expectEqual(@as(usize, 0), countCode(ex, "W-EGRESS-UNREFINED"));
    // bad principal
    const bp = try runCheck(a,
        \\runtime r {
        \\  systems = ["x"]
        \\  mesh m {
        \\    node worker {
        \\      role = "w"
        \\    }
        \\  }
        \\  network ghostCordon {
        \\    principal = "ghost"
        \\    allow = [egress("10.0.0.8", 80)]
        \\  }
        \\}
        \\
    );
    const b = firstWithCode(bp, "E-EGRESS-USE").?;
    try testing.expectEqualStrings("membrane `ghostCordon` names principal `ghost` which is not a node in mesh `m` — a membrane cannot refine a network grant no node holds (0026)", b.message);
}

test "egress host classification: loopback / lan / egress" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // lan-only allow set against a loopback grant still exceeds
    const diags = try runCheck(a,
        \\runtime r {
        \\  systems = ["x"]
        \\  mesh m {
        \\    node w {
        \\      role = "w"
        \\      capabilities = [network.lan]
        \\    }
        \\  }
        \\  network c1 {
        \\    principal = "w"
        \\    allow = [egress("localhost", 80), egress("127.0.0.1", 81), egress("192.168.1.7", 82)]
        \\  }
        \\}
        \\
    );
    // strongest required level is lan; the node holds lan → clean
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E-EGRESS-USE"));
}

test "E-REF-UNRESOLVED: kind-qualified, bare, namespace head and member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\runtime rt {
        \\  systems = ["x"]
        \\  stream s {
        \\    source = stream.missing
        \\    type = T.U
        \\  }
        \\  stream t {
        \\    source = eventd.nolog
        \\    type = T.U
        \\  }
        \\  stream u {
        \\    source = mystery.thing
        \\    type = T.U
        \\  }
        \\  fiber f {
        \\    engine = zigimg
        \\    input = stream.s
        \\    output = artifacts.out
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 4), countCode(diags, "E-REF-UNRESOLVED"));
    const msgs = [_][]const u8{
        "`source` references `stream.missing` but no `stream missing` is declared in runtime `rt`",
        "`source` references `eventd.nolog` but `nolog` is not a declared member of namespace `eventd` (declared members: ['log'])",
        "`source` references `mystery.thing` but `mystery` is not a declared namespace in runtime `rt` (add `namespace mystery { … }` or declare it in builtins)",
        "`engine` references `zigimg` but no declaration named `zigimg` is in scope of runtime `rt`",
    };
    for (msgs) |want| {
        var found = false;
        for (diags) |d| {
            if (std.mem.eql(u8, d.message, want)) found = true;
        }
        try testing.expect(found);
    }
}

test "E-REF-UNRESOLVED: runtime-scoped namespace shadows the builtin catalog" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\runtime rt {
        \\  systems = ["x"]
        \\  namespace eventd {
        \\    member other
        \\  }
        \\  stream s {
        \\    source = eventd.log
        \\    type = T.U
        \\  }
        \\}
        \\
    );
    const d = firstWithCode(diags, "E-REF-UNRESOLVED").?;
    try testing.expectEqualStrings("`source` references `eventd.log` but `log` is not a declared member of namespace `eventd` (declared members: ['other'])", d.message);
}

test "E-REF-UNRESOLVED: 3-part accessor refs, deduped by span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\runtime rt {
        \\  systems = ["x"]
        \\  container job {
        \\    image = "x/y:1"
        \\    environmentFiles = [secret.gone.path]
        \\  }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), countCode(diags, "E-REF-UNRESOLVED"));
    const d = firstWithCode(diags, "E-REF-UNRESOLVED").?;
    try testing.expectEqualStrings("`secret.gone.path` references `secret gone` but no such declaration is in scope of runtime `rt`", d.message);
    try testing.expectEqualStrings("runtime rt", d.decl);
}

test "topology kinds are deferred by the ref walk only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\runtime rt {
        \\  systems = ["x"]
        \\  probe p {
        \\    from = nodeA
        \\    to = nodeB
        \\    via = edge.main
        \\  }
        \\}
        \\
    );
    // `from = nodeA` inside a probe must NOT be resolved against the roster
    try testing.expectEqual(@as(usize, 0), countCode(diags, "E-REF-UNRESOLVED"));
}

test "use-import binds the imported file's top-level decls into scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b_items = switch (try check.parseSource(a, mini_builtins, b_file)) {
        .ok => |items| items,
        .fail => return error.BuiltinsParseFailed,
    };
    const Fixture = struct {
        fn read(_: ?*anyopaque, aa: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
            _ = aa;
            if (std.mem.eql(u8, path, "lib/common.vaked")) {
                return "engine zigimg {\n  package = pkgs.zig\n}\n";
            }
            return null;
        }
    };
    const src =
        \\use "common.vaked"
        \\
        \\runtime rt {
        \\  systems = ["x"]
        \\  stream s {
        \\    source = pkgs.src
        \\    type = T.U
        \\  }
        \\  fiber f {
        \\    engine = zigimg
        \\    input = stream.s
        \\    output = artifacts.out
        \\  }
        \\}
        \\
    ;
    const reader = check.ImportReader{ .ctx = null, .read = Fixture.read };
    switch (try check.checkSource(a, src, "lib/main.vaked", .{ .items = b_items, .src = mini_builtins, .file = b_file }, "lib", reader)) {
        .ok => |diags| try testing.expectEqual(@as(usize, 0), countCode(diags, "E-REF-UNRESOLVED")),
        .fail => return error.CheckParseFailed,
    }
}

test "workflow: cycle path, depth bound, agent targets, determinism" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cyc = try runCheck(a,
        \\mesh crew {
        \\  node boss {
        \\    role = "lead"
        \\  }
        \\}
        \\
        \\workflow w {
        \\  node a {
        \\    agent = crew.boss
        \\    control = true
        \\    effects = ["io"]
        \\  }
        \\  node b {
        \\    agent = crew.nosuch
        \\  }
        \\  a -> b
        \\  b -> a
        \\}
        \\
    );
    const c = firstWithCode(cyc, "E-WORKFLOW-CYCLE").?;
    try testing.expectEqualStrings("workflow `w` step edges must form a DAG; cycle: a -> b -> a (express revision loops as `retries` on a step, not back-edges)", c.message);
    const det = firstWithCode(cyc, "E-DETERMINISM-EFFECT").?;
    try testing.expectEqualStrings("step `a` is `control = true` (pure control-flow) but declares side-effecting effect `io`; move the side effect into a non-control step (drop `control`, or split it out)", det.message);
    const ag = firstWithCode(cyc, "E-REF-UNRESOLVED").?;
    try testing.expectEqualStrings("step `b`: `agent = crew.nosuch` references mesh `crew` but it declares no node `nosuch`", ag.message);

    const dep = try runCheck(a,
        \\mesh crew {
        \\  node boss {
        \\    role = "lead"
        \\  }
        \\}
        \\
        \\workflow deep {
        \\  maxDepth = 1
        \\  node s1 {
        \\    agent = crew.boss
        \\  }
        \\  node s2 {
        \\    agent = crew.boss
        \\  }
        \\  s1 -> s2
        \\}
        \\
    );
    const d = firstWithCode(dep, "E-WORKFLOW-DEPTH").?;
    try testing.expectEqualStrings("workflow `deep` has critical-path depth 2, exceeding the declared maxDepth = 1", d.message);
}

test "workflow agent head naming a non-mesh sibling decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\engine crew {
        \\  package = pkgs.zig
        \\}
        \\
        \\workflow w {
        \\  node a {
        \\    agent = crew.boss
        \\  }
        \\}
        \\
    );
    const d = firstWithCode(diags, "E-REF-UNRESOLVED").?;
    try testing.expectEqualStrings("step `a`: `agent = crew.boss` references `engine crew`, which is not a mesh — an agent must be a mesh node", d.message);
}

test "ebpf: unknown hook, bad intent, enforce-on-observe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const uh = try runCheck(a, "ebpf g {\n  hook = \"sk_lookup\"\n  intent = \"observe\"\n}\n");
    const d1 = firstWithCode(uh, "E-EBPF-UNKNOWN-HOOK").?;
    try testing.expectEqualStrings("ebpf `g`: unknown hook `sk_lookup`; expected one of ['cgroup_connect', 'cgroup_skb', 'kprobe', 'kretprobe', 'lsm', 'override_return', 'perf', 'send_signal', 'tc', 'tracepoint', 'xdp']", d1.message);
    const bi = try runCheck(a, "ebpf g {\n  hook = \"lsm\"\n  intent = \"prevent\"\n}\n");
    const d2 = firstWithCode(bi, "E-EBPF-BAD-INTENT").?;
    try testing.expectEqualStrings("ebpf `g`: intent must be \"observe\" or \"enforce\", got `prevent`", d2.message);
    const eo = try runCheck(a, "ebpf g {\n  hook = \"kprobe\"\n  intent = \"enforce\"\n}\n");
    const d3 = firstWithCode(eo, "E-EBPF-ENFORCE-ON-OBSERVE").?;
    try testing.expectEqualStrings("ebpf `g` declares `intent = \"enforce\"` on observe-only hook `kprobe`; kprobe cannot change system behaviour. Use a verdict-capable hook (lsm, cgroup_connect/cgroup_skb, xdp/tc, override_return, send_signal) to enforce, or set `intent = \"observe\"`.", d3.message);
}

test "E-GENERIC-INCONSISTENT: catalog from-kind and item-type disagreement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wrong_kind = try runCheck(a,
        \\stream events {
        \\  source = a.b
        \\  type = T.U
        \\}
        \\
        \\catalog c {
        \\  from = stream.events
        \\  emit = artifacts.plan
        \\}
        \\
    );
    const d1 = firstWithCode(wrong_kind, "E-GENERIC-INCONSISTENT").?;
    try testing.expectEqualStrings("catalog `from` must target an `index` (Index<T>); `stream.events` is a `stream`", d1.message);

    const item = try runCheck(a,
        \\index corpus {
        \\  source = pkgs.docs
        \\  schema = schema.docA
        \\}
        \\
        \\catalog c {
        \\  from = index.corpus
        \\  schema = schema.docB
        \\  emit = artifacts.plan
        \\}
        \\
    );
    const d2 = firstWithCode(item, "E-GENERIC-INCONSISTENT").?;
    try testing.expectEqualStrings("catalog item type `docB` disagrees with index `corpus` item type `docA`", d2.message);
    // `schema` is not a declared catalog field (closed) — Python reports it
    try testing.expectEqual(@as(usize, 1), countCode(item, "E-CONFORM-UNKNOWN-FIELD"));
}

test "python-repr rendering of list and record values in E-CONFORM-TYPE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a,
        \\stream s {
        \\  source = a.b
        \\  type = T.U
        \\  fps = [1, "two"]
        \\  retention = { a = 1 }
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 2), countCode(diags, "E-CONFORM-TYPE"));
    var found_list = false;
    var found_record = false;
    for (diags) |d| {
        if (std.mem.eql(u8, d.message, "field `fps` of schema `stream` expects `Int` but got [{'lit': 'number', 'value': '1'}, {'lit': 'string', 'value': 'two'}]")) found_list = true;
        if (std.mem.eql(u8, d.message, "field `retention` of schema `stream` expects `Duration` but got {'record': [{'assign': 'a', 'op': '=', 'value': {'lit': 'number', 'value': '1'}}]}")) found_record = true;
    }
    try testing.expect(found_list);
    try testing.expect(found_record);
}

test "JSON serialization matches the golden field shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try runCheck(a, "runtime r {\n  systems = []\n}\n");
    const out = try check.diagnosticsToJson(a, diags);
    try testing.expectEqualStrings(
        "{\"diagnostics\":[{\"code\":\"E-CONSTRAINT-NONEMPTY\",\"decl\":\"runtime r\"," ++
            "\"file\":\"t.vaked\",\"message\":\"field `systems` is `nonempty` but the value is empty\"," ++
            "\"related\":[],\"severity\":\"error\"," ++
            "\"span\":{\"byteEnd\":25,\"byteStart\":24,\"col\":13,\"line\":2}}]}\n",
        out,
    );
}
