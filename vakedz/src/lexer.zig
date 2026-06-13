//! Lexer — tokenizes Vaked v0.3 source, faithful to vakedc/lexer.py.
//!
//! Tokens carry byte-exact spans (byteStart inclusive, byteEnd exclusive) plus
//! 1-based line/col, so the checker and provenance can attribute diagnostics and
//! artifacts to source. Newlines terminate statements but are suppressed inside
//! `(` `)` / `[` `]` groupings (queued + deduped, trailing stripped). Comments
//! (`#` to EOL) are discarded.
//!
//! Deferred vs. the Python reference (tracked as issues, not silent drift):
//!   - NFC normalization gate (Unicode 15.1.0) is not yet enforced; ASCII
//!     sources are unaffected.

const std = @import("std");

pub const Kind = enum {
    ident,
    string,
    number,
    duration,
    bytes,
    path,
    regex,
    op,
    newline,
    eof,
};

pub const Token = struct {
    kind: Kind,
    value: []const u8, // slice into source (lexeme)
    byte_start: usize,
    byte_end: usize,
    line: usize,
    col: usize,
};

pub const LexError = struct {
    msg: []const u8,
    line: usize,
    col: usize,
};

const MULTI_OPS = [_][]const u8{ "->", "<=", ">=", "..", "?=" };
const SINGLE_OPS = "=<>.;:,@()[]{}|";

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,
    group_depth: usize = 0,
    tokens: std.array_list.Managed(Token),
    err: ?LexError = null,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .tokens = std.array_list.Managed(Token).init(allocator) };
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit();
    }

    fn peek(self: *Lexer, ahead: usize) ?u8 {
        const i = self.pos + ahead;
        if (i >= self.src.len) return null;
        return self.src[i];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn lastSignificant(self: *Lexer) ?Token {
        var i = self.tokens.items.len;
        while (i > 0) {
            i -= 1;
            if (self.tokens.items[i].kind != .newline) return self.tokens.items[i];
        }
        return null;
    }

    fn emit(self: *Lexer, kind: Kind, start: usize, line: usize, col: usize) !void {
        // Flush a pending newline before any significant token (deduped).
        try self.tokens.append(.{
            .kind = kind,
            .value = self.src[start..self.pos],
            .byte_start = start,
            .byte_end = self.pos,
            .line = line,
            .col = col,
        });
    }

    fn fail(self: *Lexer, msg: []const u8) error{Lex} {
        self.err = .{ .msg = msg, .line = self.line, .col = self.col };
        return error.Lex;
    }

    /// Tokenize. On success the last token is `.eof`. On failure returns
    /// error.Lex and `self.err` is populated.
    pub fn run(self: *Lexer) error{ Lex, OutOfMemory }!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\r' => {
                    _ = self.advance();
                },
                '\n' => {
                    _ = self.advance();
                    if (self.group_depth == 0) {
                        const last = if (self.tokens.items.len == 0) null else self.tokens.items[self.tokens.items.len - 1];
                        if (last == null or last.?.kind != .newline) {
                            try self.tokens.append(.{
                                .kind = .newline,
                                .value = "",
                                .byte_start = self.pos - 1,
                                .byte_end = self.pos,
                                .line = self.line - 1,
                                .col = 1,
                            });
                        }
                    }
                },
                '#' => {
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') _ = self.advance();
                },
                '"' => try self.lexString(),
                '/' => try self.lexRegex(),
                else => {
                    if (isLetter(c)) {
                        try self.lexIdent();
                    } else if (isDigit(c) or (c == '-' and self.isDigitAt(1))) {
                        try self.lexNumber();
                    } else if (c == '.' and self.isPathStart()) {
                        try self.lexPath();
                    } else {
                        try self.lexOp();
                    }
                },
            }
        }
        // Strip a trailing newline, then append EOF.
        if (self.tokens.items.len > 0 and self.tokens.items[self.tokens.items.len - 1].kind == .newline) {
            _ = self.tokens.pop();
        }
        try self.tokens.append(.{ .kind = .eof, .value = "", .byte_start = self.pos, .byte_end = self.pos, .line = self.line, .col = self.col });
    }

    fn isDigitAt(self: *Lexer, ahead: usize) bool {
        const c = self.peek(ahead) orelse return false;
        return isDigit(c);
    }

    fn lexIdent(self: *Lexer) !void {
        const start = self.pos;
        const line = self.line;
        const col = self.col;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isLetter(c) or isDigit(c) or c == '_' or c == '-') {
                _ = self.advance();
            } else break;
        }
        try self.emit(.ident, start, line, col);
    }

    fn lexNumber(self: *Lexer) !void {
        const start = self.pos;
        const line = self.line;
        const col = self.col;
        if (self.src[self.pos] == '-') _ = self.advance();
        while (self.pos < self.src.len and isDigit(self.src[self.pos])) _ = self.advance();
        // Float? `.` followed by a digit (and not `..`).
        if (self.peek(0) == '.' and self.isDigitAt(1)) {
            _ = self.advance(); // dot
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) _ = self.advance();
            try self.emit(.number, start, line, col);
            return;
        }
        // Unit suffix? bytes units first (longest match), then duration units.
        if (self.matchUnit(&BYTE_UNITS)) {
            try self.emit(.bytes, start, line, col);
            return;
        }
        if (self.matchUnit(&DURATION_UNITS)) {
            try self.emit(.duration, start, line, col);
            return;
        }
        try self.emit(.number, start, line, col);
    }

    const BYTE_UNITS = [_][]const u8{ "KB", "MB", "GB", "TB", "B" };
    const DURATION_UNITS = [_][]const u8{ "ns", "us", "ms", "s", "m", "h", "d" };

    fn matchUnit(self: *Lexer, units: []const []const u8) bool {
        // Longest-first match; the unit must not be followed by an ident char.
        var best: usize = 0;
        for (units) |u| {
            if (self.pos + u.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + u.len], u)) {
                if (u.len > best) {
                    const after = self.pos + u.len;
                    const nextc: ?u8 = if (after < self.src.len) self.src[after] else null;
                    if (nextc == null or !(isLetter(nextc.?) or isDigit(nextc.?) or nextc.? == '_' or nextc.? == '-')) {
                        best = u.len;
                    }
                }
            }
        }
        if (best == 0) return false;
        var i: usize = 0;
        while (i < best) : (i += 1) _ = self.advance();
        return true;
    }

    fn lexString(self: *Lexer) !void {
        const start = self.pos;
        const line = self.line;
        const col = self.col;
        _ = self.advance(); // opening quote
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\') {
                _ = self.advance();
                if (self.pos >= self.src.len) return self.fail("unterminated escape in string");
                _ = self.advance();
                continue;
            }
            if (c == '"') {
                _ = self.advance();
                try self.emit(.string, start, line, col);
                return;
            }
            _ = self.advance();
        }
        return self.fail("unterminated string literal");
    }

    fn lexRegex(self: *Lexer) !void {
        // Only valid immediately after a `matches` ident.
        const last = self.lastSignificant();
        if (last == null or last.?.kind != .ident or !std.mem.eql(u8, last.?.value, "matches")) {
            return self.fail("unexpected '/' (regex only allowed after `matches`)");
        }
        const start = self.pos;
        const line = self.line;
        const col = self.col;
        _ = self.advance(); // opening /
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') return self.fail("unterminated regex literal");
            if (c == '\\') {
                _ = self.advance();
                if (self.pos < self.src.len) _ = self.advance();
                continue;
            }
            if (c == '/') {
                _ = self.advance();
                try self.emit(.regex, start, line, col);
                return;
            }
            _ = self.advance();
        }
        return self.fail("unterminated regex literal");
    }

    /// A `.` starts a PATH only when it is not glued to a preceding significant
    /// token (so `a.b` is a dotted ref, but a free-standing `./x` is a path) and
    /// is followed by `/` or a letter.
    fn isPathStart(self: *Lexer) bool {
        const next = self.peek(1) orelse return false;
        if (!(next == '/' or isLetter(next))) return false;
        if (self.lastSignificant()) |last| {
            if (last.byte_end == self.pos) return false; // glued ⇒ DOT operator
        }
        return true;
    }

    fn lexPath(self: *Lexer) !void {
        const start = self.pos;
        const line = self.line;
        const col = self.col;
        _ = self.advance(); // leading dot
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isLetter(c) or isDigit(c) or c == '/' or c == '_' or c == '-' or c == '.') {
                _ = self.advance();
            } else break;
        }
        try self.emit(.path, start, line, col);
    }

    fn lexOp(self: *Lexer) !void {
        const start = self.pos;
        const line = self.line;
        const col = self.col;
        for (MULTI_OPS) |op| {
            if (self.pos + op.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + op.len], op)) {
                var i: usize = 0;
                while (i < op.len) : (i += 1) _ = self.advance();
                try self.emit(.op, start, line, col);
                return;
            }
        }
        const c = self.src[self.pos];
        if (std.mem.indexOfScalar(u8, SINGLE_OPS, c) != null) {
            if (c == '(' or c == '[') self.group_depth += 1;
            if (c == ')' or c == ']') {
                if (self.group_depth > 0) self.group_depth -= 1;
            }
            _ = self.advance();
            try self.emit(.op, start, line, col);
            return;
        }
        return self.fail("unexpected character");
    }
};

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// ---- tests ---------------------------------------------------------------

fn lexAll(a: std.mem.Allocator, src: []const u8) !std.array_list.Managed(Token) {
    var lx = Lexer.init(a, src);
    errdefer lx.deinit();
    try lx.run();
    return lx.tokens;
}

test "dotted ref vs path; duration; string; ops" {
    const a = std.testing.allocator;
    var toks = try lexAll(a, "source = agentpipe.screenrec\nretention = 24h");
    defer toks.deinit();
    // ident '=' ident '.' ident NEWLINE ident '=' duration EOF
    try std.testing.expectEqual(Kind.ident, toks.items[0].kind);
    try std.testing.expectEqualStrings("source", toks.items[0].value);
    var saw_duration = false;
    for (toks.items) |t| {
        if (t.kind == .duration and std.mem.eql(u8, t.value, "24h")) saw_duration = true;
    }
    try std.testing.expect(saw_duration);
}

test "newline suppressed inside brackets" {
    const a = std.testing.allocator;
    var toks = try lexAll(a, "x = [\n1,\n2\n]");
    defer toks.deinit();
    var newlines: usize = 0;
    for (toks.items) |t| {
        if (t.kind == .newline) newlines += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), newlines);
}
