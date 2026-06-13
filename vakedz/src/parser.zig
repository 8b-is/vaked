//! Parser — hand-written recursive descent over the Vaked v0.3 grammar, PEG
//! ordered (first-match-wins), faithful to vakedc/parser.py. Produces an AST of
//! arena-allocated nodes consumed by graph.zig.
//!
//! Soft keywords (`field`, `grant`, `order`, `open`) introduce a statement only
//! in their full shape and self-disambiguate via lookahead, so every v0.2
//! program still parses unchanged (grammar §8).

const std = @import("std");
const lex = @import("lexer.zig");
const Token = lex.Token;
const Kind = lex.Kind;

pub const KINDS = [_][]const u8{
    "runtime",     "engine",     "host",      "network", "filesystem",
    "mcp",         "ebpf",       "budget",    "observability", "runclass",
    "workflow",    "index",      "catalog",   "stream",  "fiber",
    "surface",     "mesh",       "device",    "mediaPipeline", "parallel",
    "schema",      "capability", "service",   "secret",  "hostResource",
    "ingress",     "container",  "memory",
};

pub fn isKind(s: []const u8) bool {
    for (KINDS) |k| {
        if (std.mem.eql(u8, k, s)) return true;
    }
    return false;
}

pub const LitKind = enum { string, number, bool, path, duration, bytes, null };

pub const Ref = struct {
    parts: []const []const u8,
    byte_start: usize,
    byte_end: usize,
    line: usize,
    col: usize,

    pub fn dotted(self: Ref, a: std.mem.Allocator) ![]const u8 {
        return std.mem.join(a, ".", self.parts);
    }
};

pub const Literal = struct { kind: LitKind, value: []const u8 };

pub const App = struct {
    ref: Ref,
    args: ?[]const Expr,
    record: ?[]const RecordEntry,
};

pub const Expr = union(enum) {
    literal: Literal,
    list: []const Expr,
    record: []const RecordEntry,
    app: App,
};

pub const RecordEntry = union(enum) {
    assign: Assignment,
    inherit: []const []const u8,
};

pub const Assignment = struct { target: []const u8, op: []const u8, value: *const Expr };

pub const Refinement = union(enum) {
    required,
    optional,
    nonempty,
    default: *const Expr,
    oneof: []const Expr,
    cmp: struct { op: []const u8, num: []const u8 },
    range: struct { lo: []const u8, hi: []const u8 },
    matches: []const u8,
};

pub const FieldDecl = struct { name: []const u8, type_text: []const u8, refinements: []const Refinement };

pub const Param = struct { name: []const u8, type_text: []const u8, default: ?*const Expr };
pub const Signature = struct { params: []const Param, ret: ?[]const u8 };
pub const Annotation = struct { name: []const u8, args: ?[]const Expr };

pub const NodeDecl = struct {
    name: []const u8,
    body: []const Stmt,
    byte_start: usize,
    byte_end: usize,
    line: usize,
    col: usize,
};

pub const Edge = struct { refs: []const Ref, label: ?[]const u8 };

pub const Stmt = union(enum) {
    field: FieldDecl,
    open,
    grant: []const []const u8,
    order: []const []const []const u8,
    assign: Assignment,
    inherit: []const []const u8,
    edge: Edge,
    node: *const NodeDecl,
    decl: *const Decl,
    app: App,
};

pub const Decl = struct {
    kind: []const u8,
    name: []const u8,
    annotations: []const Annotation,
    signature: ?Signature,
    body: []const Stmt,
    byte_start: usize,
    byte_end: usize,
    line: usize,
    col: usize,
};

pub const Item = union(enum) {
    decl: *const Decl,
    import: []const u8, // path
};

pub const ParseError = struct { msg: []const u8, line: usize, col: usize };

pub const Parser = struct {
    a: std.mem.Allocator,
    toks: []const Token,
    i: usize = 0,
    err: ?ParseError = null,

    pub fn init(a: std.mem.Allocator, toks: []const Token) Parser {
        return .{ .a = a, .toks = toks };
    }

    fn cur(self: *Parser) Token {
        return self.toks[self.i];
    }
    fn at(self: *Parser, n: usize) Token {
        const j = self.i + n;
        return self.toks[if (j < self.toks.len) j else self.toks.len - 1];
    }
    fn atEof(self: *Parser) bool {
        return self.cur().kind == .eof;
    }
    fn skipNl(self: *Parser) void {
        while (self.cur().kind == .newline) self.i += 1;
    }
    fn isOp(self: *Parser, v: []const u8) bool {
        const t = self.cur();
        return t.kind == .op and std.mem.eql(u8, t.value, v);
    }
    fn isIdent(self: *Parser, v: ?[]const u8) bool {
        const t = self.cur();
        if (t.kind != .ident) return false;
        if (v) |val| return std.mem.eql(u8, t.value, val);
        return true;
    }
    fn fail(self: *Parser, msg: []const u8) error{Parse} {
        const t = self.cur();
        self.err = .{ .msg = msg, .line = t.line, .col = t.col };
        return error.Parse;
    }
    fn expectOp(self: *Parser, v: []const u8) !Token {
        if (!self.isOp(v)) return self.fail("expected operator");
        const t = self.cur();
        self.i += 1;
        return t;
    }
    fn expectIdent(self: *Parser) !Token {
        if (self.cur().kind != .ident) return self.fail("expected identifier");
        const t = self.cur();
        self.i += 1;
        return t;
    }

    pub fn parseFile(self: *Parser) error{ Parse, OutOfMemory }![]const Item {
        var items = std.ArrayList(Item).init(self.a);
        self.skipNl();
        while (!self.atEof()) {
            try items.append(try self.item());
            self.skipNl();
        }
        return items.toOwnedSlice();
    }

    fn item(self: *Parser) !Item {
        if (self.isIdent("use")) {
            self.i += 1;
            if (self.cur().kind != .string) return self.fail("expected string after `use`");
            const raw = self.cur().value;
            self.i += 1;
            return .{ .import = try unquote(self.a, raw) };
        }
        return .{ .decl = try self.decl() };
    }

    fn decl(self: *Parser) error{ Parse, OutOfMemory }!*const Decl {
        var anns = std.ArrayList(Annotation).init(self.a);
        while (self.isOp("@")) try anns.append(try self.annotation());

        const start_tok = self.cur();
        if (start_tok.kind != .ident or !isKind(start_tok.value)) return self.fail("expected declaration kind");
        const kind = start_tok.value;
        self.i += 1;
        const decl_name = try self.name();
        var sig: ?Signature = null;
        if (self.isOp("(")) sig = try self.signature();
        const body_res = try self.block();

        const d = try self.a.create(Decl);
        d.* = .{
            .kind = kind,
            .name = decl_name,
            .annotations = try anns.toOwnedSlice(),
            .signature = sig,
            .body = body_res.stmts,
            .byte_start = start_tok.byte_start,
            .byte_end = body_res.close.byte_end,
            .line = start_tok.line,
            .col = start_tok.col,
        };
        return d;
    }

    fn name(self: *Parser) ![]const u8 {
        const t = self.cur();
        if (t.kind == .ident) {
            self.i += 1;
            return t.value;
        }
        if (t.kind == .string) {
            self.i += 1;
            return unquote(self.a, t.value);
        }
        return self.fail("expected name (identifier or string)");
    }

    fn annotation(self: *Parser) !Annotation {
        _ = try self.expectOp("@");
        const id = try self.expectIdent();
        var args: ?[]const Expr = null;
        if (self.isOp("(")) args = try self.parenArgs();
        return .{ .name = id.value, .args = args };
    }

    fn signature(self: *Parser) !Signature {
        _ = try self.expectOp("(");
        var params = std.ArrayList(Param).init(self.a);
        if (!self.isOp(")")) {
            while (true) {
                const pn = try self.expectIdent();
                _ = try self.expectOp(":");
                const ty = try self.typeText();
                var def: ?*const Expr = null;
                if (self.isOp("=")) {
                    self.i += 1;
                    def = try self.exprPtr();
                }
                try params.append(.{ .name = pn.value, .type_text = ty, .default = def });
                if (self.isOp(",")) {
                    self.i += 1;
                    continue;
                }
                break;
            }
        }
        _ = try self.expectOp(")");
        var ret: ?[]const u8 = null;
        if (self.isOp("->")) {
            self.i += 1;
            ret = try self.typeText();
        }
        return .{ .params = try params.toOwnedSlice(), .ret = ret };
    }

    const BlockResult = struct { stmts: []const Stmt, close: Token };

    fn block(self: *Parser) error{ Parse, OutOfMemory }!BlockResult {
        _ = try self.expectOp("{");
        var stmts = std.ArrayList(Stmt).init(self.a);
        self.skipNl();
        while (!self.isOp("}")) {
            if (self.atEof()) return self.fail("unterminated block");
            try stmts.append(try self.stmt());
            self.skipNl();
        }
        const close = self.cur();
        self.i += 1; // consume }
        return .{ .stmts = try stmts.toOwnedSlice(), .close = close };
    }

    fn stmt(self: *Parser) error{ Parse, OutOfMemory }!Stmt {
        // PEG-ordered, soft keywords first (grammar §stmt).
        if (self.isIdent("field") and self.laField()) return .{ .field = try self.fieldDecl() };
        if (self.isIdent("grant") and self.laGrant()) return .{ .grant = try self.grantDecl() };
        if (self.isIdent("order") and self.laOrder()) return .{ .order = try self.orderDecl() };
        if (self.cur().kind == .ident and self.laAssign()) return .{ .assign = try self.assignment() };
        if (self.isIdent("open")) {
            self.i += 1;
            return .open;
        }
        if (self.isIdent("inherit")) return .{ .inherit = try self.inheritStmt() };
        if (self.laEdge()) return .{ .edge = try self.edge() };
        if (self.isIdent("node") and self.laNode()) return .{ .node = try self.nodeDecl() };
        if (self.isOp("@") or (self.cur().kind == .ident and isKind(self.cur().value))) {
            return .{ .decl = try self.decl() };
        }
        return .{ .app = try self.app() };
    }

    // ---- lookahead predicates (grammar §8) ----
    fn laField(self: *Parser) bool {
        return self.at(1).kind == .ident and self.at(2).kind == .op and std.mem.eql(u8, self.at(2).value, ":");
    }
    fn laGrant(self: *Parser) bool {
        return self.at(1).kind == .ident;
    }
    fn laOrder(self: *Parser) bool {
        return self.at(1).kind == .ident and self.at(2).kind == .op and std.mem.eql(u8, self.at(2).value, "<");
    }
    fn laAssign(self: *Parser) bool {
        const n = self.at(1);
        return n.kind == .op and (std.mem.eql(u8, n.value, "=") or std.mem.eql(u8, n.value, "?="));
    }
    fn laNode(self: *Parser) bool {
        const n = self.at(1);
        const o = self.at(2);
        return (n.kind == .ident or n.kind == .string) and o.kind == .op and std.mem.eql(u8, o.value, "{");
    }
    fn laEdge(self: *Parser) bool {
        // ref ("." ident)* "->" ...   detect an arrow after a dotted ref.
        if (self.cur().kind != .ident) return false;
        var j = self.i + 1;
        while (j + 1 < self.toks.len and self.toks[j].kind == .op and std.mem.eql(u8, self.toks[j].value, ".") and self.toks[j + 1].kind == .ident) {
            j += 2;
        }
        return j < self.toks.len and self.toks[j].kind == .op and std.mem.eql(u8, self.toks[j].value, "->");
    }

    fn fieldDecl(self: *Parser) !FieldDecl {
        self.i += 1; // 'field'
        const fn_ = try self.expectIdent();
        _ = try self.expectOp(":");
        const ty = try self.typeText();
        var refs = std.ArrayList(Refinement).init(self.a);
        if (self.isOp("{")) {
            self.i += 1;
            self.skipNl();
            while (!self.isOp("}")) {
                if (self.atEof()) return self.fail("unterminated refinement block");
                try refs.append(try self.refinement());
                self.skipNl();
            }
            self.i += 1; // }
        }
        return .{ .name = fn_.value, .type_text = ty, .refinements = try refs.toOwnedSlice() };
    }

    fn refinement(self: *Parser) !Refinement {
        const t = self.cur();
        if (t.kind == .ident) {
            if (std.mem.eql(u8, t.value, "required")) {
                self.i += 1;
                return .required;
            }
            if (std.mem.eql(u8, t.value, "optional")) {
                self.i += 1;
                return .optional;
            }
            if (std.mem.eql(u8, t.value, "nonempty")) {
                self.i += 1;
                return .nonempty;
            }
            if (std.mem.eql(u8, t.value, "default")) {
                self.i += 1;
                _ = try self.expectOp("=");
                return .{ .default = try self.exprPtr() };
            }
            if (std.mem.eql(u8, t.value, "oneof")) {
                self.i += 1;
                return .{ .oneof = try self.list() };
            }
            if (std.mem.eql(u8, t.value, "in")) {
                self.i += 1;
                const lo = self.cur();
                if (lo.kind != .number) return self.fail("expected number in range");
                self.i += 1;
                _ = try self.expectOp("..");
                const hi = self.cur();
                if (hi.kind != .number) return self.fail("expected number in range");
                self.i += 1;
                return .{ .range = .{ .lo = lo.value, .hi = hi.value } };
            }
            if (std.mem.eql(u8, t.value, "matches")) {
                self.i += 1;
                const rx = self.cur();
                if (rx.kind != .regex) return self.fail("expected regex after matches");
                self.i += 1;
                return .{ .matches = rx.value };
            }
        }
        if (t.kind == .op and (std.mem.eql(u8, t.value, ">=") or std.mem.eql(u8, t.value, "<=") or std.mem.eql(u8, t.value, ">") or std.mem.eql(u8, t.value, "<"))) {
            self.i += 1;
            const num = self.cur();
            if (num.kind != .number) return self.fail("expected number after comparison");
            self.i += 1;
            return .{ .cmp = .{ .op = t.value, .num = num.value } };
        }
        return self.fail("unknown refinement");
    }

    fn grantDecl(self: *Parser) ![]const []const u8 {
        self.i += 1; // 'grant'
        var names = std.ArrayList([]const u8).init(self.a);
        // line-bounded: stop at NEWLINE (do not skipNl)
        while (self.cur().kind == .ident) {
            try names.append(self.cur().value);
            self.i += 1;
        }
        return names.toOwnedSlice();
    }

    fn orderDecl(self: *Parser) ![]const []const []const u8 {
        self.i += 1; // 'order'
        var chains = std.ArrayList([]const []const u8).init(self.a);
        try chains.append(try self.orderChain());
        while (true) {
            // ';' separates chains and may continue across newlines on EITHER
            // side of the ';' (grammar: "a chain list may continue across
            // newlines after the ';'").
            if (self.cur().kind == .newline and self.at(1).kind == .op and std.mem.eql(u8, self.at(1).value, ";")) {
                self.i += 2;
            } else if (self.isOp(";")) {
                self.i += 1;
            } else break;
            self.skipNl();
            try chains.append(try self.orderChain());
        }
        return chains.toOwnedSlice();
    }

    fn orderChain(self: *Parser) ![]const []const u8 {
        var names = std.ArrayList([]const u8).init(self.a);
        const first = try self.expectIdent();
        try names.append(first.value);
        while (self.isOp("<")) {
            self.i += 1;
            const id = try self.expectIdent();
            try names.append(id.value);
        }
        return names.toOwnedSlice();
    }

    fn inheritStmt(self: *Parser) ![]const []const u8 {
        self.i += 1; // 'inherit'
        var names = std.ArrayList([]const u8).init(self.a);
        while (self.cur().kind == .ident) {
            try names.append(self.cur().value);
            self.i += 1;
        }
        return names.toOwnedSlice();
    }

    fn assignment(self: *Parser) !Assignment {
        const target = try self.expectIdent();
        const op = self.cur();
        self.i += 1; // '=' or '?='
        const val = try self.exprPtr();
        return .{ .target = target.value, .op = op.value, .value = val };
    }

    fn nodeDecl(self: *Parser) !*const NodeDecl {
        const start = self.cur();
        self.i += 1; // 'node'
        const nm = try self.name();
        const body = try self.block();
        const nd = try self.a.create(NodeDecl);
        nd.* = .{ .name = nm, .body = body.stmts, .byte_start = start.byte_start, .byte_end = body.close.byte_end, .line = start.line, .col = start.col };
        return nd;
    }

    fn edge(self: *Parser) !Edge {
        var refs = std.ArrayList(Ref).init(self.a);
        try refs.append(try self.ref());
        _ = try self.expectOp("->");
        try refs.append(try self.ref());
        while (self.isOp("->")) {
            self.i += 1;
            try refs.append(try self.ref());
        }
        var label: ?[]const u8 = null;
        if (self.isOp(":")) {
            self.i += 1;
            if (self.cur().kind != .string) return self.fail("expected string edge label");
            label = try unquote(self.a, self.cur().value);
            self.i += 1;
        }
        return .{ .refs = try refs.toOwnedSlice(), .label = label };
    }

    // ---- expressions ----
    fn exprPtr(self: *Parser) !*const Expr {
        const e = try self.a.create(Expr);
        e.* = try self.expr();
        return e;
    }

    fn expr(self: *Parser) error{ Parse, OutOfMemory }!Expr {
        const t = self.cur();
        switch (t.kind) {
            .string => {
                self.i += 1;
                return .{ .literal = .{ .kind = .string, .value = try unquote(self.a, t.value) } };
            },
            .number => {
                self.i += 1;
                return .{ .literal = .{ .kind = .number, .value = t.value } };
            },
            .duration => {
                self.i += 1;
                return .{ .literal = .{ .kind = .duration, .value = t.value } };
            },
            .bytes => {
                self.i += 1;
                return .{ .literal = .{ .kind = .bytes, .value = t.value } };
            },
            .path => {
                self.i += 1;
                return .{ .literal = .{ .kind = .path, .value = t.value } };
            },
            .op => {
                if (std.mem.eql(u8, t.value, "[")) return .{ .list = try self.list() };
                if (std.mem.eql(u8, t.value, "{")) return .{ .record = try self.record() };
                return self.fail("unexpected operator in expression");
            },
            .ident => {
                if (std.mem.eql(u8, t.value, "true") or std.mem.eql(u8, t.value, "false")) {
                    self.i += 1;
                    return .{ .literal = .{ .kind = .bool, .value = t.value } };
                }
                if (std.mem.eql(u8, t.value, "null")) {
                    self.i += 1;
                    return .{ .literal = .{ .kind = .null, .value = "null" } };
                }
                return .{ .app = try self.app() };
            },
            else => return self.fail("unexpected token in expression"),
        }
    }

    fn app(self: *Parser) !App {
        const r = try self.ref();
        var args: ?[]const Expr = null;
        if (self.isOp("(")) args = try self.parenArgs();
        var rec: ?[]const RecordEntry = null;
        if (self.isOp("{")) rec = try self.record();
        return .{ .ref = r, .args = args, .record = rec };
    }

    fn parenArgs(self: *Parser) ![]const Expr {
        _ = try self.expectOp("(");
        var args = std.ArrayList(Expr).init(self.a);
        if (!self.isOp(")")) {
            while (true) {
                try args.append(try self.expr());
                if (self.isOp(",")) {
                    self.i += 1;
                    continue;
                }
                break;
            }
        }
        _ = try self.expectOp(")");
        return args.toOwnedSlice();
    }

    fn ref(self: *Parser) !Ref {
        const first = try self.expectIdent();
        var parts = std.ArrayList([]const u8).init(self.a);
        try parts.append(first.value);
        var last = first;
        while (self.isOp(".") and self.at(1).kind == .ident) {
            self.i += 1; // dot
            last = self.cur();
            try parts.append(last.value);
            self.i += 1;
        }
        return .{ .parts = try parts.toOwnedSlice(), .byte_start = first.byte_start, .byte_end = last.byte_end, .line = first.line, .col = first.col };
    }

    fn list(self: *Parser) ![]const Expr {
        _ = try self.expectOp("[");
        var items = std.ArrayList(Expr).init(self.a);
        self.skipNl();
        if (!self.isOp("]")) {
            while (true) {
                try items.append(try self.expr());
                self.skipNl();
                if (self.isOp(",")) {
                    self.i += 1;
                    self.skipNl();
                    continue;
                }
                break;
            }
        }
        _ = try self.expectOp("]");
        return items.toOwnedSlice();
    }

    fn record(self: *Parser) ![]const RecordEntry {
        _ = try self.expectOp("{");
        var entries = std.ArrayList(RecordEntry).init(self.a);
        self.skipNl();
        while (!self.isOp("}")) {
            if (self.atEof()) return self.fail("unterminated record");
            if (self.isIdent("inherit")) {
                try entries.append(.{ .inherit = try self.inheritStmt() });
            } else {
                try entries.append(.{ .assign = try self.assignment() });
            }
            self.skipNl();
        }
        _ = try self.expectOp("}");
        return entries.toOwnedSlice();
    }

    fn typeText(self: *Parser) ![]const u8 {
        // type = type_atom { "|" type_atom } ; captured as flat text.
        var out = std.ArrayList(u8).init(self.a);
        try self.typeAtom(&out);
        while (self.isOp("|")) {
            self.i += 1;
            try out.appendSlice(" | ");
            try self.typeAtom(&out);
        }
        return out.toOwnedSlice();
    }

    fn typeAtom(self: *Parser, out: *std.ArrayList(u8)) !void {
        // qualname [ "<" type {"," type} ">" ]  (function-type form not emitted
        // by the goldens; supported shallowly).
        const id = try self.expectIdent();
        try out.appendSlice(id.value);
        while (self.isOp(".") and self.at(1).kind == .ident) {
            self.i += 1;
            try out.append('.');
            try out.appendSlice(self.cur().value);
            self.i += 1;
        }
        if (self.isOp("<")) {
            self.i += 1;
            try out.append('<');
            try self.typeAtom(out);
            while (self.isOp(",")) {
                self.i += 1;
                try out.appendSlice(", ");
                try self.typeAtom(out);
            }
            _ = try self.expectOp(">");
            try out.append('>');
        }
    }
};

/// Strip the surrounding quotes of a STRING lexeme and process JSON-style
/// escapes (\" \\ \/ \n \r \t \b \f). \uXXXX is passed through for ASCII paths.
pub fn unquote(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 2) return a.dupe(u8, "");
    const inner = raw[1 .. raw.len - 1];
    var out = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            switch (inner[i]) {
                '"' => try out.append('"'),
                '\\' => try out.append('\\'),
                '/' => try out.append('/'),
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                'b' => try out.append(0x08),
                'f' => try out.append(0x0c),
                else => {
                    try out.append('\\');
                    try out.append(inner[i]);
                },
            }
        } else {
            try out.append(inner[i]);
        }
    }
    return out.toOwnedSlice();
}

// ---- tests ---------------------------------------------------------------

test "parse a minimal engine decl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "engine zigDaemon(name: String, src: Path) -> Engine {\n  optimize = \"ReleaseSafe\"\n}";
    var lx = lex.Lexer.init(a, src);
    try lx.run();
    var p = Parser.init(a, lx.tokens.items);
    const items = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const d = items[0].decl;
    try std.testing.expectEqualStrings("engine", d.kind);
    try std.testing.expectEqualStrings("zigDaemon", d.name);
    try std.testing.expect(d.signature != null);
    try std.testing.expectEqual(@as(usize, 2), d.signature.?.params.len);
}
