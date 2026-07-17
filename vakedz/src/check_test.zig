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
    \\capability fs {
    \\  grant none repo_ro repo_rw host_ro host_rw
    \\  order none < repo_ro < repo_rw < host_rw ;
    \\        repo_ro < host_ro < host_rw
    \\}
    \\
    \\namespace pkgs { open }
    \\
;

const b_file = "builtins.vaked";
const u_file = "t.vaked";

fn runCheck(a: std.mem.Allocator, src: []const u8) ![]const @import("lib").diagnostic.Diagnostic {
    const b_items = switch (try check.parseSource(a, mini_builtins, b_file)) {
        .ok => |items| items,
        .fail => return error.BuiltinsParseFailed,
    };
    switch (try check.checkSource(a, src, u_file, .{ .items = b_items, .src = mini_builtins, .file = b_file })) {
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
