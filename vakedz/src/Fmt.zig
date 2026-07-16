const std = @import("std");
const parser = @import("parser.zig");
const Item = parser.Item;
const Decl = parser.Decl;
const NodeDecl = parser.NodeDecl;
const Stmt = parser.Stmt;
const Expr = parser.Expr;
const Refinement = parser.Refinement;
const App = parser.App;
const Annotation = parser.Annotation;
const Edge = parser.Edge;
const RecordEntry = parser.RecordEntry;
const Assignment = parser.Assignment;

const Writer = std.ArrayList(u8);
const Allocator = std.mem.Allocator;

const FmtError = error{OutOfMemory};

fn needsQuoting(s: []const u8) bool {
    for (s) |c| {
        if (c == ' ' or c == '"' or c == '\\' or c == '\n' or c == '\t') return true;
    }
    return s.len == 0;
}

fn writeQuoted(a: Allocator, s: []const u8, out: *Writer) FmtError!void {
    if (!needsQuoting(s)) {
        try out.appendSlice(a, s);
        return;
    }
    try writeAlwaysQuoted(a, s, out);
}

fn writeAlwaysQuoted(a: Allocator, s: []const u8, out: *Writer) FmtError!void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
}

pub fn formatFile(a: Allocator, items: []const Item, out: *Writer) FmtError!void {
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(a, "\n\n");
        switch (item) {
            .import => |imp| {
                try formatComments(a, imp.comments, 0, out);
                try out.appendSlice(a, "use \"");
                try out.appendSlice(a, imp.path);
                try out.appendSlice(a, "\"");
            },
            .decl => |d| try formatDecl(a, d, 0, out),
            .comments => |cs| {
                for (cs, 0..) |c, j| {
                    if (j > 0) try out.append(a, '\n');
                    try out.appendSlice(a, c);
                }
            },
        }
    }
    if (items.len > 0) try out.append(a, '\n');
}

fn formatComments(a: Allocator, comments: []const []const u8, indent: usize, out: *Writer) FmtError!void {
    for (comments) |c| {
        try writeIndent(a, indent, out);
        try out.appendSlice(a, c);
        try out.append(a, '\n');
    }
}

fn formatDecl(a: Allocator, d: *const Decl, indent: usize, out: *Writer) FmtError!void {
    try formatComments(a, d.comments, indent, out);
    for (d.annotations) |ann| {
        try formatAnnotation(a, ann, indent, out);
        try out.append(a, '\n');
    }
    try writeIndent(a, indent, out);
    try out.appendSlice(a, d.kind);
    try out.append(a, ' ');
    if (d.name_quoted) {
        try writeAlwaysQuoted(a, d.name, out);
    } else {
        try out.appendSlice(a, d.name);
    }
    if (d.signature) |sig| try formatSignature(a, sig, out);
    try out.appendSlice(a, " {\n");
    try formatBody(a, d.body, indent + 2, out);
    try writeIndent(a, indent, out);
    try out.append(a, '}');
}

fn formatNodeDecl(a: Allocator, n: *const NodeDecl, indent: usize, out: *Writer) FmtError!void {
    try formatComments(a, n.comments, indent, out);
    try writeIndent(a, indent, out);
    try out.appendSlice(a, "node ");
    if (n.name_quoted) {
        try writeAlwaysQuoted(a, n.name, out);
    } else {
        try out.appendSlice(a, n.name);
    }
    try out.appendSlice(a, " {\n");
    try formatBody(a, n.body, indent + 2, out);
    try writeIndent(a, indent, out);
    try out.append(a, '}');
}

fn formatSignature(a: Allocator, sig: parser.Signature, out: *Writer) !void {
    try out.append(a, '(');
    for (sig.params, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, p.name);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, p.type_text);
        if (p.default) |def| {
            try out.appendSlice(a, " = ");
            try formatExpr(a, def.*, 0, out);
        }
    }
    try out.append(a, ')');
    if (sig.ret) |ret| {
        try out.appendSlice(a, " -> ");
        try out.appendSlice(a, ret);
    }
}

fn formatBody(a: Allocator, stmts: []const Stmt, indent: usize, out: *Writer) FmtError!void {
    for (stmts, 0..) |s, i| {
        if (i > 0) try out.append(a, '\n');
        try formatStmt(a, s, indent, out);
    }
    if (stmts.len > 0) try out.append(a, '\n');
}

fn formatStmt(a: Allocator, s: Stmt, indent: usize, out: *Writer) FmtError!void {
    switch (s) {
        .field => |f| try formatFieldDecl(a, f, indent, out),
        .grant => |g| try formatGrantDecl(a, g, indent, out),
        .order => |o| try formatOrderDecl(a, o, indent, out),
        .member => |m| {
            try writeIndent(a, indent, out);
            try out.appendSlice(a, "member ");
            try out.appendSlice(a, m.name);
        },
        .assign => |asgn| try formatAssignment(a, asgn, indent, out),
        .open => {
            try writeIndent(a, indent, out);
            try out.appendSlice(a, "open");
        },
        .inherit => |names| {
            try writeIndent(a, indent, out);
            try out.appendSlice(a, "inherit");
            for (names) |n| {
                try out.append(a, ' ');
                try out.appendSlice(a, n);
            }
        },
        .edge => |e| try formatEdge(a, e, indent, out),
        .node => |n| try formatNodeDecl(a, n, indent, out),
        .decl => |d| try formatDecl(a, d, indent, out),
        .app => |ap| {
            try writeIndent(a, indent, out);
            try formatRef(a, ap.ref, out);
            if (ap.args) |args| {
                try out.append(a, '(');
                for (args, 0..) |arg, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try formatExpr(a, arg, indent, out);
                }
                try out.append(a, ')');
            }
            if (ap.record) |entries| {
                try out.append(a, ' ');
                try formatRecord(a, entries, indent, out);
            }
        },
        .comment => |c| {
            try writeIndent(a, indent, out);
            try out.appendSlice(a, c);
        },
        .blank => {},
    }
}

// Records: the grammar separates record entries by newlines (no commas), so any
// record with more than one entry must be emitted as a multiline block for the
// output to re-parse. A single short entry stays inline: `{ key = val }`.
fn formatRecord(a: Allocator, entries: []const RecordEntry, indent: usize, out: *Writer) FmtError!void {
    if (entries.len == 0) {
        try out.appendSlice(a, "{}");
        return;
    }
    if (entries.len == 1) {
        var trial: Writer = .empty;
        defer trial.deinit(a);
        try trial.appendSlice(a, "{ ");
        try formatRecordEntry(a, entries[0], indent, &trial);
        try trial.appendSlice(a, " }");
        if (std.mem.indexOfScalar(u8, trial.items, '\n') == null) {
            try out.appendSlice(a, trial.items);
            return;
        }
    }
    try out.appendSlice(a, "{\n");
    for (entries) |entry| {
        try writeIndent(a, indent + 2, out);
        try formatRecordEntry(a, entry, indent + 2, out);
        try out.append(a, '\n');
    }
    try writeIndent(a, indent, out);
    try out.append(a, '}');
}

fn formatRecordEntry(a: Allocator, entry: RecordEntry, indent: usize, out: *Writer) FmtError!void {
    switch (entry) {
        .assign => |asgn| {
            try out.appendSlice(a, asgn.target);
            try out.append(a, ' ');
            try out.appendSlice(a, asgn.op);
            try out.append(a, ' ');
            try formatExpr(a, asgn.value.*, indent, out);
        },
        .inherit => |names| {
            try out.appendSlice(a, "inherit");
            for (names) |n| {
                try out.append(a, ' ');
                try out.appendSlice(a, n);
            }
        },
    }
}

fn formatFieldDecl(a: Allocator, f: parser.FieldDecl, indent: usize, out: *Writer) !void {
    try writeIndent(a, indent, out);
    try out.appendSlice(a, "field ");
    try out.appendSlice(a, f.name);
    try out.appendSlice(a, " : ");
    try out.appendSlice(a, f.type_text);
    if (f.refinements.len > 0) {
        try out.appendSlice(a, " {");
        for (f.refinements) |r| {
            try out.append(a, ' ');
            try formatRefinement(a, r, out);
        }
        try out.appendSlice(a, " }");
    }
}

fn formatRefinement(a: Allocator, r: Refinement, out: *Writer) !void {
    switch (r) {
        .required => try out.appendSlice(a, "required"),
        .optional => try out.appendSlice(a, "optional"),
        .nonempty => try out.appendSlice(a, "nonempty"),
        .default => |e| {
            try out.appendSlice(a, "default = ");
            try formatExpr(a, e.*, 0, out);
        },
        .oneof => |items| {
            try out.appendSlice(a, "oneof [");
            for (items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try formatExpr(a, item, 0, out);
            }
            try out.append(a, ']');
        },
        .cmp => |c| {
            try out.appendSlice(a, c.op);
            try out.append(a, ' ');
            try out.appendSlice(a, c.num);
        },
        .range => |rng| {
            try out.appendSlice(a, "in ");
            try out.appendSlice(a, rng.lo);
            try out.appendSlice(a, " .. ");
            try out.appendSlice(a, rng.hi);
        },
        .matches => |rx| {
            try out.appendSlice(a, "matches ");
            try out.appendSlice(a, rx);
        },
    }
}

fn formatGrantDecl(a: Allocator, names: []const []const u8, indent: usize, out: *Writer) !void {
    try writeIndent(a, indent, out);
    try out.appendSlice(a, "grant");
    for (names) |n| {
        try out.append(a, ' ');
        try out.appendSlice(a, n);
    }
}

fn formatOrderDecl(a: Allocator, chains: []const []const []const u8, indent: usize, out: *Writer) !void {
    try writeIndent(a, indent, out);
    try out.appendSlice(a, "order ");
    for (chains, 0..) |chain, i| {
        if (i > 0) {
            try out.appendSlice(a, " ;\n");
            try writeIndent(a, indent + 6, out);
        }
        for (chain, 0..) |name, j| {
            if (j > 0) try out.appendSlice(a, " < ");
            try out.appendSlice(a, name);
        }
    }
}

fn formatAssignment(a: Allocator, asgn: Assignment, indent: usize, out: *Writer) !void {
    try writeIndent(a, indent, out);
    try out.appendSlice(a, asgn.target);
    try out.appendSlice(a, " ");
    try out.appendSlice(a, asgn.op);
    try out.append(a, ' ');
    try formatExpr(a, asgn.value.*, indent, out);
}

fn formatEdge(a: Allocator, e: Edge, indent: usize, out: *Writer) !void {
    try writeIndent(a, indent, out);
    for (e.refs, 0..) |r, i| {
        if (i > 0) try out.appendSlice(a, " -> ");
        try formatRef(a, r, out);
    }
    if (e.label) |label| {
        try out.appendSlice(a, " : \"");
        try out.appendSlice(a, label);
        try out.append(a, '"');
    }
}

fn formatExpr(a: Allocator, e: Expr, indent: usize, out: *Writer) FmtError!void {
    switch (e) {
        .literal => |l| {
            if (l.kind == .string) {
                try out.append(a, '"');
                for (l.value) |c| {
                    switch (c) {
                        '"' => try out.appendSlice(a, "\\\""),
                        '\\' => try out.appendSlice(a, "\\\\"),
                        '\n' => try out.appendSlice(a, "\\n"),
                        '\t' => try out.appendSlice(a, "\\t"),
                        else => try out.append(a, c),
                    }
                }
                try out.append(a, '"');
            } else {
                try out.appendSlice(a, l.value);
            }
        },
        .list => |items| {
            try out.append(a, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try formatExpr(a, item, indent, out);
            }
            try out.append(a, ']');
        },
        .record => |entries| {
            try formatRecord(a, entries, indent, out);
        },
        .app => |ap| {
            try formatRef(a, ap.ref, out);
            if (ap.args) |args| {
                try out.append(a, '(');
                for (args, 0..) |arg, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try formatExpr(a, arg, indent, out);
                }
                try out.append(a, ')');
            }
            if (ap.record) |entries| {
                try out.append(a, ' ');
                try formatRecord(a, entries, indent, out);
            }
        },
    }
}

fn formatRef(a: Allocator, r: parser.Ref, out: *Writer) !void {
    for (r.parts, 0..) |part, i| {
        if (i > 0) try out.append(a, '.');
        try out.appendSlice(a, part);
    }
}

fn formatAnnotation(a: Allocator, ann: Annotation, indent: usize, out: *Writer) !void {
    try writeIndent(a, indent, out);
    try out.append(a, '@');
    try out.appendSlice(a, ann.name);
    if (ann.args) |args| {
        try out.append(a, '(');
        for (args, 0..) |arg, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try formatExpr(a, arg, 0, out);
        }
        try out.append(a, ')');
    }
}

fn writeIndent(a: Allocator, indent: usize, out: *Writer) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try out.append(a, ' ');
    }
}
