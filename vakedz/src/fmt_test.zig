const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const fmt_mod = @import("Fmt.zig");

fn formatSource(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var l = lex.Lexer.init(a, src);
    try l.run();
    var p = parser_mod.Parser.init(a, l.tokens.items);
    const items = try p.parseFile();
    var out: std.ArrayList(u8) = .empty;
    try fmt_mod.formatFile(a, items, &out);
    return out.toOwnedSlice(a);
}

fn expectFormatted(a: std.mem.Allocator, input: []const u8, expected: []const u8) !void {
    const result = try formatSource(a, input);
    defer a.free(result);
    // Canonical output always ends with exactly one trailing newline.
    const expected_nl = try std.mem.concat(a, u8, &.{ expected, "\n" });
    defer a.free(expected_nl);
    try testing.expectEqualStrings(expected_nl, result);
}

fn expectIdempotent(a: std.mem.Allocator, src: []const u8) !void {
    const first = try formatSource(a, src);
    defer a.free(first);
    const second = try formatSource(a, first);
    defer a.free(second);
    try testing.expectEqualStrings(first, second);
}

test "format simple decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\engine zigDaemon {
        \\  optimize = "ReleaseSafe"
        \\}
    ,
        \\engine zigDaemon {
        \\  optimize = "ReleaseSafe"
        \\}
    );
}

test "format decl with signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\engine zigDaemon(name: String, src: Path) -> Engine {
        \\}
    ,
        \\engine zigDaemon(name: String, src: Path) -> Engine {
        \\}
    );
}

test "format annotation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\@deprecated
        \\service web {
        \\}
    ,
        \\@deprecated
        \\service web {
        \\}
    );
}

test "format use import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\use "./other.vaked"
    ,
        \\use "./other.vaked"
    );
}

test "format grant decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\capability fs {
        \\  grant none repo_ro repo_rw
        \\}
    ,
        \\capability fs {
        \\  grant none repo_ro repo_rw
        \\}
    );
}

test "format order decl single chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\capability fs {
        \\  grant none repo_ro repo_rw
        \\  order none < repo_ro < repo_rw
        \\}
    ,
        \\capability fs {
        \\  grant none repo_ro repo_rw
        \\  order none < repo_ro < repo_rw
        \\}
    );
}

test "format order decl multi chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\capability bus {
        \\  grant none cache queue admin
        \\  order none < cache < admin ;
        \\        none < queue < admin
        \\}
    ,
        \\capability bus {
        \\  grant none cache queue admin
        \\  order none < cache < admin ;
        \\        none < queue < admin
        \\}
    );
}

test "format field decl with refinements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema User {
        \\  field name : String { required nonempty }
        \\}
    ,
        \\schema User {
        \\  field name : String { required nonempty }
        \\}
    );
}

test "format field decl with cmp refinement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema User {
        \\  field age : Int { required >= 0 }
        \\}
    ,
        \\schema User {
        \\  field age : Int { required >= 0 }
        \\}
    );
}

test "format field decl with default and oneof" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema User {
        \\  field channel : String { default = "stable" oneof ["stable", "beta", "dev"] }
        \\}
    ,
        \\schema User {
        \\  field channel : String { default = "stable" oneof ["stable", "beta", "dev"] }
        \\}
    );
}

test "format union type inside generic args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema Box {
        \\  field x : List<A|B>
        \\}
    ,
        \\schema Box {
        \\  field x : List<A | B>
        \\}
    );
    // idempotency: canonical output re-formats to itself
    try expectFormatted(a,
        \\schema Box {
        \\  field x : List<A | B>
        \\}
    ,
        \\schema Box {
        \\  field x : List<A | B>
        \\}
    );
}

test "format nested union type inside generic args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema Box {
        \\  field input : List<Stream<T> | Graph | Catalog<T>> { nonempty }
        \\}
    ,
        \\schema Box {
        \\  field input : List<Stream<T> | Graph | Catalog<T>> { nonempty }
        \\}
    );
}

test "format node decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\mesh agentfield {
        \\  node codex {
        \\    role = "worker"
        \\    capabilities = [fs.repo_rw]
        \\  }
        \\}
    ,
        \\mesh agentfield {
        \\  node codex {
        \\    role = "worker"
        \\    capabilities = [fs.repo_rw]
        \\  }
        \\}
    );
}

test "format edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\mesh agentfield {
        \\  codex -> mcpBroker
        \\}
    ,
        \\mesh agentfield {
        \\  codex -> mcpBroker
        \\}
    );
}

test "format edge with label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\mesh agentfield {
        \\  codex -> mcpBroker : "audit"
        \\}
    ,
        \\mesh agentfield {
        \\  codex -> mcpBroker : "audit"
        \\}
    );
}

test "format list literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\stream telemetry {
        \\  capabilities = [fs.repo_rw, mcp.github_read]
        \\}
    ,
        \\stream telemetry {
        \\  capabilities = [fs.repo_rw, mcp.github_read]
        \\}
    );
}

test "format record literal in app" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\index testCorpus {
        \\  source = github("example/example-repo")
        \\}
    ,
        \\index testCorpus {
        \\  source = github("example/example-repo")
        \\}
    );
}

test "format open decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema firmwareMeta {
        \\  field sha256 : String { required }
        \\  open
        \\}
    ,
        \\schema firmwareMeta {
        \\  field sha256 : String { required }
        \\  open
        \\}
    );
}

test "format member decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\namespace agentGuardd {
        \\  member ringbuf
        \\}
    ,
        \\namespace agentGuardd {
        \\  member ringbuf
        \\}
    );
}

test "format inherit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\runtime foo {
        \\  inherit bar baz
        \\}
    ,
        \\runtime foo {
        \\  inherit bar baz
        \\}
    );
}

test "format nested blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\runtime "v0p5-demo" {
        \\  mesh testMesh {
        \\    node nodeA {
        \\      role = "producer"
        \\    }
        \\    nodeA -> nodeB : "pipeline"
        \\  }
        \\}
    ,
        \\runtime "v0p5-demo" {
        \\  mesh testMesh {
        \\    node nodeA {
        \\      role = "producer"
        \\    }
        \\    nodeA -> nodeB : "pipeline"
        \\  }
        \\}
    );
}

test "format multiple top-level decls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\capability fs {
        \\  grant none repo_ro repo_rw
        \\}
        \\
        \\capability network {
        \\  grant none read write
        \\}
    ,
        \\capability fs {
        \\  grant none repo_ro repo_rw
        \\}
        \\
        \\capability network {
        \\  grant none read write
        \\}
    );
}

test "idempotent simple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectIdempotent(a,
        \\engine zigDaemon {
        \\  optimize = "ReleaseSafe"
        \\}
    );
}

test "idempotent nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectIdempotent(a,
        \\runtime "test" {
        \\  mesh field {
        \\    node orchestrator {
        \\      role = "control"
        \\    }
        \\    orchestrator -> worker : "delegate"
        \\  }
        \\}
    );
}

test "idempotent complex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectIdempotent(a,
        \\capability storage {
        \\  grant none read append write admin
        \\  order none < read < append < write < admin
        \\}
        \\
        \\mesh deliveryField {
        \\  node planner {
        \\    role = "planner"
        \\    capabilities = [storage.write]
        \\  }
        \\  node worker {
        \\    role = "worker"
        \\    capabilities = [storage.append]
        \\  }
        \\  planner -> worker : "delegate"
        \\}
    );
}

test "exactly one trailing newline at EOF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try formatSource(a, "engine foo {\n}");
    defer a.free(result);
    try testing.expect(result.len >= 2);
    try testing.expectEqual(@as(u8, '\n'), result[result.len - 1]);
    try testing.expect(result[result.len - 2] != '\n');
}

test "empty block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\engine foo {
        \\}
    ,
        \\engine foo {
        \\}
    );
}

test "format duration and bytes literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\stream telemetry {
        \\  retention = 24h
        \\  buffer = 512MB
        \\}
    ,
        \\stream telemetry {
        \\  retention = 24h
        \\  buffer = 512MB
        \\}
    );
}

test "format dotted ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\stream telemetry {
        \\  source = agentGuardd.ringbuf
        \\}
    ,
        \\stream telemetry {
        \\  source = agentGuardd.ringbuf
        \\}
    );
}

test "format optional assign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\runtime foo {
        \\  name ?= "default"
        \\}
    ,
        \\runtime foo {
        \\  name ?= "default"
        \\}
    );
}

test "format regex refinement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema s {
        \\  field url : Path { required matches /https:\/\/.*/ }
        \\}
    ,
        \\schema s {
        \\  field url : Path { required matches /https:\/\/.*/ }
        \\}
    );
}

test "format range refinement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\schema s {
        \\  field image_type : Int { required in 0 .. 255 }
        \\}
    ,
        \\schema s {
        \\  field image_type : Int { required in 0 .. 255 }
        \\}
    );
}

test "format preserves comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\# top-level comment
        \\runtime foo {
        \\}
    ,
        \\# top-level comment
        \\runtime foo {
        \\}
    );
}

test "format preserves multiple comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\# comment 1
        \\# comment 2
        \\runtime foo {
        \\}
    ,
        \\# comment 1
        \\# comment 2
        \\runtime foo {
        \\}
    );
}

test "format preserves comment before use" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\# my imports
        \\use "./foo.vaked"
    ,
        \\# my imports
        \\use "./foo.vaked"
    );
}

// --- defect 1: multi-entry records must format as parseable multiline blocks ---

test "multi-entry record in stmt position formats as multiline block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\fiber mediaCompress {
        \\  policy {
        \\    strip_metadata = true
        \\    max_pixels = "4K"
        \\    formats = ["png", "webp"]
        \\  }
        \\}
    ,
        \\fiber mediaCompress {
        \\  policy {
        \\    strip_metadata = true
        \\    max_pixels = "4K"
        \\    formats = ["png", "webp"]
        \\  }
        \\}
    );
}

test "multi-entry record output re-parses (round-trip)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectIdempotent(a,
        \\fiber mediaCompress {
        \\  policy {
        \\    strip_metadata = true
        \\    max_pixels = "4K"
        \\    formats = ["png", "webp"]
        \\  }
        \\}
    );
}

test "single-entry record stays inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\runtime main {
        \\  config = { debug = true }
        \\}
    ,
        \\runtime main {
        \\  config = { debug = true }
        \\}
    );
}

test "multi-entry record value formats multiline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a, "runtime main {\n  config = { debug = true retries = 3 }\n}",
        \\runtime main {
        \\  config = {
        \\    debug = true
        \\    retries = 3
        \\  }
        \\}
    );
}

test "app with args and multi-entry record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\index i {
        \\  source = github("x") {
        \\    a = 1
        \\    b = 2
        \\  }
        \\}
    ,
        \\index i {
        \\  source = github("x") {
        \\    a = 1
        \\    b = 2
        \\  }
        \\}
    );
}

// --- defect 2: comments inside blocks must be preserved ---

test "comments inside blocks are preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\runtime foo {
        \\  # section
        \\  a = 1
        \\}
    ,
        \\runtime foo {
        \\  # section
        \\  a = 1
        \\}
    );
}

test "inline trailing comment moves to own line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a, "runtime foo {\n  a = 1 # note\n}",
        \\runtime foo {
        \\  a = 1
        \\  # note
        \\}
    );
}

test "comment before closing brace preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\runtime foo {
        \\  a = 1
        \\  # done
        \\}
    ,
        \\runtime foo {
        \\  a = 1
        \\  # done
        \\}
    );
}

test "comments in nested block preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\mesh m {
        \\  node a {
        \\    # inner note
        \\    role = "worker"
        \\  }
        \\}
    ,
        \\mesh m {
        \\  node a {
        \\    # inner note
        \\    role = "worker"
        \\  }
        \\}
    );
}

test "trailing comments at EOF preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a, "runtime foo {\n}\n\n# trailing note\n# more",
        \\runtime foo {
        \\}
        \\
        \\# trailing note
        \\# more
    );
}

test "comment block separated by blank line stays separated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\# header comment
        \\
        \\runtime foo {
        \\}
    ,
        \\# header comment
        \\
        \\runtime foo {
        \\}
    );
}

// --- defect 3: blank lines between logical groups / top-level decls ---

test "blank lines between logical groups in block preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a,
        \\mesh agentfield {
        \\  node codex {
        \\    role = "worker"
        \\  }
        \\
        \\  node redteam {
        \\    role = "reviewer"
        \\  }
        \\
        \\  codex -> redteam
        \\}
    ,
        \\mesh agentfield {
        \\  node codex {
        \\    role = "worker"
        \\  }
        \\
        \\  node redteam {
        \\    role = "reviewer"
        \\  }
        \\
        \\  codex -> redteam
        \\}
    );
}

test "multiple blank lines in block collapse to one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFormatted(a, "runtime foo {\n  a = 1\n\n\n\n  b = 2\n}",
        \\runtime foo {
        \\  a = 1
        \\
        \\  b = 2
        \\}
    );
}

test "exactly one blank line between top-level decls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected =
        \\capability a {
        \\}
        \\
        \\capability b {
        \\}
    ;
    // no blank line in input -> exactly one inserted
    try expectFormatted(a, "capability a {\n}\ncapability b {\n}", expected);
    // many blank lines in input -> collapsed to exactly one
    try expectFormatted(a, "capability a {\n}\n\n\n\ncapability b {\n}", expected);
}

// --- escaping: edge labels, use paths, string values (round-trip safety) ---

test "edge label with quotes and backslashes round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "mesh m {\n  codex -> broker : \"say \\\"hi\\\" \\\\ done\"\n}";
    try expectFormatted(a, src, src);
    try expectIdempotent(a, src);
}

test "use path with quotes and backslashes round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "use \"we\\\"ird\\\\path.vaked\"";
    try expectFormatted(a, src, src);
    try expectIdempotent(a, src);
}

test "string value with quotes and backslashes round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "engine e {\n  name = \"a\\\"b\\\\c\"\n}";
    try expectFormatted(a, src, src);
    try expectIdempotent(a, src);
}

test "control-character escapes in string values round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // \r, \b, \f are decoded by the parser and must be re-encoded on output
    const src = "engine e {\n  name = \"a\\rb\\bc\\fd\"\n}";
    try expectFormatted(a, src, src);
    try expectIdempotent(a, src);
}

test "idempotent with comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectIdempotent(a,
        \\# header
        \\
        \\mesh m {
        \\  # group one
        \\  node a {
        \\    role = "x" # inline
        \\  }
        \\
        \\  a -> b
        \\}
    );
}
