// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const lexer = @import("lexer.zig");

test "tokenize simple ident" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "runtime");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(@as(usize, 2), l.tokens.items.len);
    try testing.expectEqual(lexer.Kind.ident, l.tokens.items[0].kind);
    try testing.expectEqualStrings("runtime", l.tokens.items[0].value);
    try testing.expectEqual(lexer.Kind.eof, l.tokens.items[1].kind);
}

test "tokenize string" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "\"hello\"");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(lexer.Kind.string, l.tokens.items[0].kind);
    try testing.expectEqualStrings("\"hello\"", l.tokens.items[0].value);
}

test "tokenize number and duration" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "42 100ms");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(@as(usize, 3), l.tokens.items.len);
    try testing.expectEqual(lexer.Kind.number, l.tokens.items[0].kind);
    try testing.expectEqualStrings("42", l.tokens.items[0].value);
    try testing.expectEqual(lexer.Kind.duration, l.tokens.items[1].kind);
    try testing.expectEqualStrings("100ms", l.tokens.items[1].value);
}

test "tokenize bytes literal" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "512MB");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(lexer.Kind.bytes, l.tokens.items[0].kind);
    try testing.expectEqualStrings("512MB", l.tokens.items[0].value);
}

test "tokenize path" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "./foo/bar");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(lexer.Kind.path, l.tokens.items[0].kind);
    try testing.expectEqualStrings("./foo/bar", l.tokens.items[0].value);
}

test "tokenize operators" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "-> <= ?=");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(@as(usize, 4), l.tokens.items.len);
    try testing.expectEqual(lexer.Kind.op, l.tokens.items[0].kind);
    try testing.expectEqualStrings("->", l.tokens.items[0].value);
    try testing.expectEqualStrings("<=", l.tokens.items[1].value);
    try testing.expectEqualStrings("?=", l.tokens.items[2].value);
}

test "newline suppression inside groups" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "(a\nb)");
    defer l.deinit();
    try l.run();
    var nl_count: usize = 0;
    for (l.tokens.items) |tok| {
        if (tok.kind == .newline) nl_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), nl_count);
}

test "comment discarded" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "foo # comment\nbar");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(lexer.Kind.ident, l.tokens.items[0].kind);
    try testing.expectEqualStrings("foo", l.tokens.items[0].value);
    try testing.expectEqual(lexer.Kind.newline, l.tokens.items[1].kind);
    try testing.expectEqual(lexer.Kind.ident, l.tokens.items[2].kind);
    try testing.expectEqualStrings("bar", l.tokens.items[2].value);
}

test "regex after matches" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "matches /^[a-z]+$/");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(lexer.Kind.ident, l.tokens.items[0].kind);
    try testing.expectEqualStrings("matches", l.tokens.items[0].value);
    try testing.expectEqual(lexer.Kind.regex, l.tokens.items[1].kind);
    try testing.expectEqualStrings("/^[a-z]+$/", l.tokens.items[1].value);
}

test "string interpolation verbatim" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "\"hello ${name}\"");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(lexer.Kind.string, l.tokens.items[0].kind);
    try testing.expectEqualStrings("\"hello ${name}\"", l.tokens.items[0].value);
}

test "line col tracking" {
    const allocator = testing.allocator;
    var l = lexer.Lexer.init(allocator, "foo\nbar");
    defer l.deinit();
    try l.run();
    try testing.expectEqual(@as(usize, 1), l.tokens.items[0].line);
    try testing.expectEqual(@as(usize, 1), l.tokens.items[0].col);
    try testing.expectEqual(@as(usize, 2), l.tokens.items[2].line);
    try testing.expectEqual(@as(usize, 1), l.tokens.items[2].col);
}
