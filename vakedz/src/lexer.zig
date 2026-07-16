// GENESIS_SEAL: 7c242080
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
    comment,
    eof,
};

pub const Token = struct {
    kind: Kind,
    value: []const u8,
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

const multi_ops = [_][]const u8{ "->", "<=", ">=", "..", "?=" };
const single_ops = "=<>.;:,@()[]{}|";
const duration_units = [_][]const u8{ "ns", "us", "ms", "s", "m", "h", "d" };
const byte_units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentPart(c: u8) bool {
    return isLetter(c) or isDigit(c) or c == '_' or c == '-';
}

fn isPathChar(c: u8) bool {
    return isLetter(c) or isDigit(c) or c == '/' or c == '_' or c == '-' or c == '.';
}

fn isSingleOp(c: u8) bool {
    for (single_ops) |o| {
        if (c == o) return true;
    }
    return false;
}

fn isValueKind(k: Kind) bool {
    return k == .ident or k == .number or k == .string or k == .duration or k == .bytes or k == .regex;
}

fn matchUnit(src: []const u8, comptime units: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (units) |u| {
        if (src.len >= u.len and std.mem.eql(u8, src[0..u.len], u)) {
            if (best == null or u.len > best.?.len) best = u;
        }
    }
    return best;
}

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: std.ArrayList(Token),
    errors: std.ArrayList(LexError),
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,
    group_depth: usize = 0,
    pending_newline: bool = false,
    pending_nl_byte: usize = 0,
    pending_nl_line: usize = 1,
    pending_nl_col: usize = 1,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return Lexer{
            .allocator = allocator,
            .source = source,
            .tokens = .empty,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    fn advance(self: *Lexer, s: []const u8) void {
        for (s) |c| {
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }
    }

    fn emit(self: *Lexer, kind: Kind, value: []const u8, byte_start: usize, byte_end: usize, tline: usize, tcol: usize) !void {
        if (self.pending_newline) {
            if (self.tokens.items.len > 0 and self.tokens.items[self.tokens.items.len - 1].kind != .newline) {
                try self.tokens.append(self.allocator, Token{
                    .kind = .newline,
                    .value = "\\n",
                    .byte_start = self.pending_nl_byte,
                    .byte_end = self.pending_nl_byte,
                    .line = self.pending_nl_line,
                    .col = self.pending_nl_col,
                });
            }
            self.pending_newline = false;
        }
        try self.tokens.append(self.allocator, Token{
            .kind = kind,
            .value = value,
            .byte_start = byte_start,
            .byte_end = byte_end,
            .line = tline,
            .col = tcol,
        });
    }

    fn lastSignificant(self: *Lexer) ?Token {
        if (self.tokens.items.len == 0) return null;
        return self.tokens.items[self.tokens.items.len - 1];
    }

    pub fn run(self: *Lexer) !void {
        const src = self.source;
        const n = src.len;

        while (self.pos < n) {
            const c = src[self.pos];
            const tline = self.line;
            const tcol = self.col;
            const ci = self.pos;

            if (c == ' ' or c == '\t' or c == '\r') {
                self.advance(src[ci .. ci + 1]);
                self.pos += 1;
                continue;
            }

            if (c == '\n') {
                if (self.group_depth == 0 and !self.pending_newline) {
                    self.pending_newline = true;
                    self.pending_nl_byte = ci;
                    self.pending_nl_line = self.line;
                    self.pending_nl_col = self.col;
                }
                self.advance(src[ci .. ci + 1]);
                self.pos += 1;
                continue;
            }

            if (c == '#') {
                var j = self.pos;
                while (j < n and src[j] != '\n') : (j += 1) {}
                const comment_text = src[self.pos..j];
                self.advance(comment_text);
                try self.emit(.comment, comment_text, ci, j, tline, tcol);
                self.pos = j;
                continue;
            }

            if (c == '"') {
                var j = self.pos + 1;
                var closed = false;
                while (j < n) {
                    const ch = src[j];
                    if (ch == '\\') {
                        if (j + 1 >= n) {
                            try self.errors.append(self.allocator, LexError{ .msg = "unterminated escape in string", .line = tline, .col = tcol });
                            return;
                        }
                        j += 2;
                        continue;
                    }
                    if (ch == '"') {
                        j += 1;
                        closed = true;
                        break;
                    }
                    if (ch == '\n') {
                        try self.errors.append(self.allocator, LexError{ .msg = "unterminated string", .line = tline, .col = tcol });
                        return;
                    }
                    j += 1;
                }
                if (!closed) {
                    try self.errors.append(self.allocator, LexError{ .msg = "unterminated string", .line = tline, .col = tcol });
                    return;
                }
                const value = src[ci..j];
                self.advance(value);
                try self.emit(.string, value, ci, j, tline, tcol);
                self.pos = j;
                continue;
            }

            if (c == '/') {
                const ls = self.lastSignificant();
                if (ls != null and ls.?.kind == .ident and std.mem.eql(u8, ls.?.value, "matches")) {
                    var j = self.pos + 1;
                    var closed = false;
                    while (j < n) {
                        const ch = src[j];
                        if (ch == '\\') {
                            if (j + 1 >= n) {
                                try self.errors.append(self.allocator, LexError{ .msg = "unterminated regex escape", .line = tline, .col = tcol });
                                return;
                            }
                            j += 2;
                            continue;
                        }
                        if (ch == '\n') {
                            try self.errors.append(self.allocator, LexError{ .msg = "unterminated regex", .line = tline, .col = tcol });
                            return;
                        }
                        if (ch == '/') {
                            j += 1;
                            closed = true;
                            break;
                        }
                        j += 1;
                    }
                    if (!closed) {
                        try self.errors.append(self.allocator, LexError{ .msg = "unterminated regex literal", .line = tline, .col = tcol });
                        return;
                    }
                    const value = src[ci..j];
                    self.advance(value);
                    try self.emit(.regex, value, ci, j, tline, tcol);
                    self.pos = j;
                    continue;
                }
                try self.errors.append(self.allocator, LexError{ .msg = "unexpected '/' (regex only valid after matches)", .line = tline, .col = tcol });
                return;
            }

            if (c == '.') {
                const ls = self.lastSignificant();
                const glued = ls != null and isValueKind(ls.?.kind) and ls.?.byte_end == ci;
                if (!glued and self.pos + 1 < n and src[self.pos + 1] == '.') {
                    self.advance("..");
                    try self.emit(.op, "..", ci, ci + 2, tline, tcol);
                    self.pos += 2;
                    continue;
                }
                if (!glued and self.pos + 1 < n and (src[self.pos + 1] == '/' or isLetter(src[self.pos + 1]))) {
                    var j = self.pos + 1;
                    while (j < n and isPathChar(src[j])) : (j += 1) {}
                    const value = src[ci..j];
                    self.advance(value);
                    try self.emit(.path, value, ci, j, tline, tcol);
                    self.pos = j;
                    continue;
                }
            }

            {
                var matched_op: ?[]const u8 = null;
                for (multi_ops) |op| {
                    if (self.pos + op.len <= n and std.mem.eql(u8, src[self.pos .. self.pos + op.len], op)) {
                        matched_op = op;
                        break;
                    }
                }
                if (matched_op) |mop| {
                    self.advance(mop);
                    try self.emit(.op, mop, ci, ci + mop.len, tline, tcol);
                    self.pos += mop.len;
                    continue;
                }
            }

            if (isSingleOp(c)) {
                if (c == '(' or c == '[') {
                    self.group_depth += 1;
                } else if (c == ')' or c == ']') {
                    if (self.group_depth > 0) self.group_depth -= 1;
                }
                self.advance(src[ci .. ci + 1]);
                try self.emit(.op, src[ci .. ci + 1], ci, ci + 1, tline, tcol);
                self.pos += 1;
                continue;
            }

            if (isDigit(c) or (c == '-' and self.pos + 1 < n and isDigit(src[self.pos + 1]))) {
                var j = self.pos;
                if (src[j] == '-') j += 1;
                while (j < n and isDigit(src[j])) : (j += 1) {}
                var is_float = false;
                if (j < n and src[j] == '.' and j + 1 < n and isDigit(src[j + 1])) {
                    is_float = true;
                    j += 1;
                    while (j < n and isDigit(src[j])) : (j += 1) {}
                }
                if (!is_float) {
                    const rest = src[j..];
                    if (matchUnit(rest, &byte_units)) |unit| {
                        if (j + unit.len >= n or !isIdentPart(src[j + unit.len])) {
                            const value = src[ci .. j + unit.len];
                            self.advance(value);
                            try self.emit(.bytes, value, ci, j + unit.len, tline, tcol);
                            self.pos = j + unit.len;
                            continue;
                        }
                    }
                    if (matchUnit(rest, &duration_units)) |unit| {
                        if (j + unit.len >= n or !isIdentPart(src[j + unit.len])) {
                            const value = src[ci .. j + unit.len];
                            self.advance(value);
                            try self.emit(.duration, value, ci, j + unit.len, tline, tcol);
                            self.pos = j + unit.len;
                            continue;
                        }
                    }
                }
                const value = src[ci..j];
                self.advance(value);
                try self.emit(.number, value, ci, j, tline, tcol);
                self.pos = j;
                continue;
            }

            if (isLetter(c)) {
                var j = self.pos;
                while (j < n and isIdentPart(src[j])) : (j += 1) {}
                const value = src[ci..j];
                self.advance(value);
                try self.emit(.ident, value, ci, j, tline, tcol);
                self.pos = j;
                continue;
            }

            try self.errors.append(self.allocator, LexError{ .msg = "unexpected character", .line = tline, .col = tcol });
            return;
        }

        if (self.tokens.items.len > 0 and self.tokens.items[self.tokens.items.len - 1].kind == .newline) {
            _ = self.tokens.pop();
        }
        try self.emit(.eof, "<eof>", n, n, self.line, self.col);
    }
};
