// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");
const parser = @import("parser.zig");

fn parseSource(a: std.mem.Allocator, src: []const u8) ![]const parser.Item {
    var l = lex.Lexer.init(a, src);
    try l.run();
    var p = parser.Parser.init(a, l.tokens.items);
    return p.parseFile();
}

test "parse minimal engine decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseSource(a, "engine zigDaemon {\n  optimize = \"ReleaseSafe\"\n}");
    try testing.expectEqual(@as(usize, 1), items.len);
    const d = items[0].decl;
    try testing.expectEqualStrings("engine", d.kind);
    try testing.expectEqualStrings("zigDaemon", d.name);
    try testing.expectEqual(@as(usize, 1), d.body.len);
    switch (d.body[0]) {
        .assign => |asgn| {
            try testing.expectEqualStrings("optimize", asgn.target);
            try testing.expectEqualStrings("=", asgn.op);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse decl with signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseSource(a, "engine zigDaemon(name: String, src: Path) -> Engine {\n}");
    try testing.expectEqual(@as(usize, 1), items.len);
    const d = items[0].decl;
    try testing.expect(d.signature != null);
    try testing.expectEqual(@as(usize, 2), d.signature.?.params.len);
    try testing.expectEqualStrings("name", d.signature.?.params[0].name);
    try testing.expectEqualStrings("String", d.signature.?.params[0].type_text);
    try testing.expectEqualStrings("src", d.signature.?.params[1].name);
    try testing.expect(d.signature.?.ret != null);
    try testing.expectEqualStrings("Engine", d.signature.?.ret.?);
}

test "parse annotation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseSource(a, "@deprecated\nservice web {\n}");
    try testing.expectEqual(@as(usize, 1), items.len);
    const d = items[0].decl;
    try testing.expectEqual(@as(usize, 1), d.annotations.len);
    try testing.expectEqualStrings("deprecated", d.annotations[0].name);
}

test "parse use import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parseSource(a, "use \"./other.vaked\"");
    try testing.expectEqual(@as(usize, 1), items.len);
    switch (items[0]) {
        .import => |imp| try testing.expectEqualStrings("./other.vaked", imp.path),
        else => return error.TestUnexpectedResult,
    }
}

test "parse field decl with refinements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "schema User {\n  field name : String { required }\n  field age : Number { >= 0 }\n}";
    const items = try parseSource(a, src);
    const d = items[0].decl;
    try testing.expectEqualStrings("schema", d.kind);
    try testing.expectEqual(@as(usize, 2), d.body.len);
    switch (d.body[0]) {
        .field => |f| {
            try testing.expectEqualStrings("name", f.name);
            try testing.expectEqualStrings("String", f.type_text);
            try testing.expectEqual(@as(usize, 1), f.refinements.len);
            switch (f.refinements[0]) {
                .required => {},
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    switch (d.body[1]) {
        .field => |f| {
            try testing.expectEqualStrings("age", f.name);
            switch (f.refinements[0]) {
                .cmp => |c| {
                    try testing.expectEqualStrings(">=", c.op);
                    try testing.expectEqualStrings("0", c.num);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse grant and order decls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "capability fs {\n  grant none repo_ro repo_rw\n  order none < repo_ro < repo_rw\n}";
    const items = try parseSource(a, src);
    const d = items[0].decl;
    try testing.expectEqualStrings("capability", d.kind);
    try testing.expectEqual(@as(usize, 2), d.body.len);
    switch (d.body[0]) {
        .grant => |names| {
            try testing.expectEqual(@as(usize, 3), names.len);
            try testing.expectEqualStrings("none", names[0]);
            try testing.expectEqualStrings("repo_rw", names[2]);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (d.body[1]) {
        .order => |chains| {
            try testing.expectEqual(@as(usize, 1), chains.len);
            try testing.expectEqual(@as(usize, 3), chains[0].len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse member decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "namespace channels {\n  member log\n  member ringbuf\n}";
    const items = try parseSource(a, src);
    const d = items[0].decl;
    try testing.expectEqualStrings("namespace", d.kind);
    try testing.expectEqual(@as(usize, 2), d.body.len);
    switch (d.body[0]) {
        .member => |m| try testing.expectEqualStrings("log", m.name),
        else => return error.TestUnexpectedResult,
    }
    switch (d.body[1]) {
        .member => |m| try testing.expectEqualStrings("ringbuf", m.name),
        else => return error.TestUnexpectedResult,
    }
}

test "parse node and edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "mesh topology {\n  node a {\n  }\n  node b {\n  }\n  a -> b : \"link\"\n}";
    const items = try parseSource(a, src);
    const d = items[0].decl;
    try testing.expectEqual(@as(usize, 3), d.body.len);
    switch (d.body[0]) {
        .node => |n| try testing.expectEqualStrings("a", n.name),
        else => return error.TestUnexpectedResult,
    }
    switch (d.body[2]) {
        .edge => |e| {
            try testing.expectEqual(@as(usize, 2), e.refs.len);
            try testing.expect(e.label != null);
            try testing.expectEqualStrings("link", e.label.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse v0.5 kinds trust quorum probe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(parser.isKind("trust"));
    try testing.expect(parser.isKind("quorum"));
    try testing.expect(parser.isKind("probe"));
    try testing.expect(parser.isKind("dyad"));
    try testing.expect(parser.isKind("ceremony"));
    try testing.expect(parser.isKind("arbiter"));
    const items = try parseSource(a, "trust sentinel {\n}");
    try testing.expectEqualStrings("trust", items[0].decl.kind);
}

test "parse list and record exprs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "runtime main {\n  ports = [80, 443]\n  config = { debug = true }\n}";
    const items = try parseSource(a, src);
    const d = items[0].decl;
    try testing.expectEqual(@as(usize, 2), d.body.len);
    switch (d.body[0]) {
        .assign => |asgn| {
            switch (asgn.value.*) {
                .list => |lst| try testing.expectEqual(@as(usize, 2), lst.len),
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse app with args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "runtime main {\n  nix(\"pkgs.hello\")\n}";
    const items = try parseSource(a, src);
    const d = items[0].decl;
    switch (d.body[0]) {
        .app => |ap| {
            try testing.expectEqualStrings("nix", ap.ref.parts[0]);
            try testing.expect(ap.args != null);
            try testing.expectEqual(@as(usize, 1), ap.args.?.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse inherit stmt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "runtime main {\n  inherit foo bar baz\n}";
    const items = try parseSource(a, src);
    switch (items[0].decl.body[0]) {
        .inherit => |names| {
            try testing.expectEqual(@as(usize, 3), names.len);
            try testing.expectEqualStrings("foo", names[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse open decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "schema Ext {\n  open\n}";
    const items = try parseSource(a, src);
    switch (items[0].decl.body[0]) {
        .open => {},
        else => return error.TestUnexpectedResult,
    }
}

test "parse error on bad input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = parseSource(a, "not_a_kind foo {\n}");
    try testing.expectError(error.Parse, result);
}

test "parse function type in field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "schema Cb {\n  field handler : (String, Number) -> Bool\n}";
    const items = try parseSource(a, src);
    const d = items[0].decl;
    switch (d.body[0]) {
        .field => |f| {
            try testing.expectEqualStrings("handler", f.name);
            try testing.expectEqualStrings("(String, Number) -> Bool", f.type_text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse zero-arg function type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "schema Cb {\n  field thunk : () -> String\n}";
    const items = try parseSource(a, src);
    switch (items[0].decl.body[0]) {
        .field => |f| try testing.expectEqualStrings("() -> String", f.type_text),
        else => return error.TestUnexpectedResult,
    }
}

test "parse union type inside generic args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "schema Box {\n  field x : List<A | B>\n}";
    const items = try parseSource(a, src);
    switch (items[0].decl.body[0]) {
        .field => |f| try testing.expectEqualStrings("List<A | B>", f.type_text),
        else => return error.TestUnexpectedResult,
    }
}

test "parse nested union type inside generic args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "schema Box {\n  field input : List<Stream<T> | Graph | Catalog<T>> { nonempty }\n}";
    const items = try parseSource(a, src);
    switch (items[0].decl.body[0]) {
        .field => |f| {
            try testing.expectEqualStrings("input", f.name);
            try testing.expectEqualStrings("List<Stream<T> | Graph | Catalog<T>>", f.type_text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "all 36 kinds recognized" {
    const expected = [_][]const u8{
        "runtime", "engine", "host", "network", "filesystem", "mcp", "ebpf",
        "budget", "observability", "runclass", "workflow", "index", "catalog",
        "stream", "fiber", "surface", "mesh", "device", "mediaPipeline",
        "parallel", "schema", "capability", "service", "secret", "hostResource",
        "ingress", "container", "memory", "namespace", "arp_event",
        "trust", "quorum", "probe", "dyad", "ceremony", "arbiter",
    };
    for (expected) |k| {
        try testing.expect(parser.isKind(k));
    }
    try testing.expect(!parser.isKind("notakind"));
}
