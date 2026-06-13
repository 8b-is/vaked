#!/usr/bin/env python3
"""vakedc.parser — hand-written recursive-descent parser, PEG-ordered per the
v0.3 grammar (vaked/grammar/vaked-v0-plus.ebnf), EXACTLY (no extensions).

The grammar is a PEG: ``x | y`` is ordered choice (first match wins), ``{ x }``
and ``[ x ]`` are greedy. This parser mirrors that with explicit backtracking
(save/restore the token cursor) so its accept/reject verdict matches the from-
EBNF recognizer token-for-token.

NEWLINE discipline (grammar header + tests/spec parse_support):
  * NEWLINE TERMINATES a statement/entry; it is insignificant between
    statements/entries and is skipped (``_skip_nl``).
  * Inside the line-bound repetitions — ``inherit`` / ``grant`` ``{ ident }``
    and ``order`` chains — a NEWLINE BOUNDS the repetition, so those loops do
    NOT skip NEWLINE; they stop at it.
  * ``;`` in an ``order_decl`` continues the chain list across a newline.
  * Newlines are insignificant inside open ``(``/``[`` — the lexer already
    suppressed them there, so none appear in argument lists / list literals.

Soft-keyword dispatch (grammar §8), in ``stmt`` order:
  field_decl / grant_decl / order_decl  (BEFORE assignment) — each self-
  disambiguates on its required second token; ``open`` AFTER assignment, so
  ``open = expr`` is an assignment and a bare ``open`` is ``open_decl``.

Produces declaration structures (decl/import/node/edge) carrying exact source
spans; the graph builder turns these into LPG nodes/edges.
"""

from __future__ import annotations

from .lexer import Token, tokenize, VakedLexError

# The 29 declaration kinds (grammar `kind`, v0.4).  (`input` removed in #48 — its
# niche is covered by `index` (build-time corpus) and `stream` (runtime flow).)
KINDS = (
    "runtime", "engine", "host",
    "network", "filesystem", "mcp", "ebpf",
    "budget", "observability", "runclass", "workflow",
    "index", "catalog", "stream", "fiber",
    "surface", "mesh", "device", "mediaPipeline",
    "parallel", "schema", "capability",
    # NixOS-deployment cohort (#1-#6): service/secret/hostResource/ingress/container.
    "service", "secret", "hostResource", "ingress", "container",
    # MemPalace-shaped runtime memory (#24, 0014).
    "memory",
    # Value-namespace roster (#8, RFC 0017, v0.4).
    "namespace",
)
_KIND_SET = frozenset(KINDS)

_REFINEMENT_WORDS = frozenset(
    ("required", "optional", "nonempty", "default", "oneof", "in", "matches")
)
_CMP_OPS = ("<=", ">=", "<", ">")


class VakedSyntaxError(Exception):
    """Syntax error: ``file:line:col — expected …, got …``."""

    def __init__(self, file: str, line: int, col: int, expected: str, got: str):
        super().__init__(f"{file}:{line}:{col} — expected {expected}, got {got}")
        self.file = file
        self.line = line
        self.col = col
        self.expected = expected
        self.got = got


# --------------------------------------------------------------------------- #
# AST node shapes (lightweight dicts-as-objects via dataclasses)
# --------------------------------------------------------------------------- #

class Node:
    """Base AST node."""
    __slots__ = ()


class Decl(Node):
    __slots__ = ("kind", "name", "annotations", "signature", "body",
                 "byteStart", "byteEnd", "line", "col")

    def __init__(self, kind, name, annotations, signature, body,
                 byteStart, byteEnd, line, col):
        self.kind = kind
        self.name = name
        self.annotations = annotations
        self.signature = signature
        self.body = body          # list of statements
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.line = line
        self.col = col


class Import(Node):
    __slots__ = ("path", "byteStart", "byteEnd", "line", "col")

    def __init__(self, path, byteStart, byteEnd, line, col):
        self.path = path          # the string token value (with quotes stripped)
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.line = line
        self.col = col


class Assignment(Node):
    __slots__ = ("target", "op", "value")

    def __init__(self, target, op, value):
        self.target = target
        self.op = op
        self.value = value


class FieldDecl(Node):
    __slots__ = ("name", "type", "refinements")

    def __init__(self, name, type_, refinements):
        self.name = name
        self.type = type_
        self.refinements = refinements


class OpenDecl(Node):
    __slots__ = ()


class GrantDecl(Node):
    __slots__ = ("names",)

    def __init__(self, names):
        self.names = names


class MemberDecl(Node):
    """``member_decl = "member" ident`` (v0.4, RFC 0017).

    Names one closed member of the enclosing ``namespace`` block.  Analogous to
    ``grant_decl`` inside a ``capability`` block: a soft-keyword statement that
    enumerates the allowed members of the namespace head."""
    __slots__ = ("name",)

    def __init__(self, name: str):
        self.name = name


class OrderDecl(Node):
    __slots__ = ("chains",)

    def __init__(self, chains):
        self.chains = chains      # list of list[str]


class InheritStmt(Node):
    __slots__ = ("names",)

    def __init__(self, names):
        self.names = names


class NodeDecl(Node):
    __slots__ = ("name", "body", "byteStart", "byteEnd", "line", "col")

    def __init__(self, name, body, byteStart, byteEnd, line, col):
        self.name = name
        self.body = body
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.line = line
        self.col = col


class Edge(Node):
    __slots__ = ("refs", "label")

    def __init__(self, refs, label):
        self.refs = refs          # list of Ref (>= 2)
        self.label = label        # optional string value or None


class App(Node):
    __slots__ = ("ref", "args", "record")

    def __init__(self, ref, args, record):
        self.ref = ref            # Ref
        self.args = args          # list[expr] or None (no parens)
        self.record = record      # list[Assignment|InheritStmt] or None


class Ref(Node):
    __slots__ = ("parts", "byteStart", "byteEnd", "line", "col")

    def __init__(self, parts, byteStart, byteEnd, line, col):
        self.parts = parts        # list[str] dotted path
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.line = line
        self.col = col

    @property
    def head(self) -> str:
        return self.parts[0]

    @property
    def dotted(self) -> str:
        return ".".join(self.parts)


class Literal(Node):
    __slots__ = ("kind", "value")     # kind: STRING/NUMBER/BOOL/PATH/DURATION/BYTES/NULL

    def __init__(self, kind, value):
        self.kind = kind
        self.value = value


class ListLit(Node):
    __slots__ = ("items",)

    def __init__(self, items):
        self.items = items


class RecordLit(Node):
    __slots__ = ("entries",)

    def __init__(self, entries):
        self.entries = entries    # list[Assignment|InheritStmt]


class TypeRef(Node):
    """A parsed type (stored, not checked)."""
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text


# --------------------------------------------------------------------------- #
# Parser
# --------------------------------------------------------------------------- #

class Parser:
    def __init__(self, tokens, filename="<vaked>"):
        self.toks = tokens
        self.file = filename
        self.i = 0
        self.n = len(tokens)

    # --- cursor helpers -------------------------------------------------- #

    def _cur(self) -> Token:
        return self.toks[self.i]

    def _skip_nl(self):
        while self.toks[self.i].kind == "NEWLINE":
            self.i += 1

    def _at_eof(self) -> bool:
        return self.toks[self.i].kind == "EOF"

    def _is_op(self, val, tok=None) -> bool:
        t = tok or self.toks[self.i]
        return t.kind == "OP" and t.value == val

    def _is_ident(self, val=None, tok=None) -> bool:
        t = tok or self.toks[self.i]
        if t.kind != "IDENT":
            return False
        return val is None or t.value == val

    def _err(self, expected: str):
        t = self.toks[self.i]
        got = f"{t.kind} {t.value!r}" if t.kind != "EOF" else "end of input"
        raise VakedSyntaxError(self.file, t.line, t.col, expected, got)

    def _expect_op(self, val) -> Token:
        self._skip_nl()
        t = self.toks[self.i]
        if self._is_op(val, t):
            self.i += 1
            return t
        self._err(f"{val!r}")

    def _expect_ident(self) -> Token:
        self._skip_nl()
        t = self.toks[self.i]
        if t.kind == "IDENT":
            self.i += 1
            return t
        self._err("an identifier")

    # --- entry point ----------------------------------------------------- #

    def parse_file(self):
        """file = { item } ; item = decl | import."""
        items = []
        self._skip_nl()
        while not self._at_eof():
            items.append(self._item())
            self._skip_nl()
        return items

    def _item(self):
        self._skip_nl()
        t = self.toks[self.i]
        if self._is_ident("use", t):
            return self._import()
        return self._decl()

    def _import(self):
        """import = "use" string."""
        kw = self.toks[self.i]            # 'use'
        self.i += 1
        self._skip_nl_inline()
        t = self.toks[self.i]
        if t.kind != "STRING":
            self._err("a string after `use`")
        self.i += 1
        path = _strip_string(t.value)
        return Import(path, kw.byteStart, t.byteEnd, kw.line, kw.col)

    def _skip_nl_inline(self):
        # Within a single statement spaces/tabs are insignificant; a NEWLINE would
        # terminate it. `use` and a following string sit on one line, but be lenient
        # to NEWLINE only if the grammar would (it would not). Keep strict: no skip.
        pass

    # --- declarations ---------------------------------------------------- #

    def _decl(self):
        """decl = { annotation } kind name [ signature ] block."""
        self._skip_nl()
        annotations = []
        while self._is_op("@"):
            annotations.append(self._annotation())
            self._skip_nl()
        t = self.toks[self.i]
        if not (t.kind == "IDENT" and t.value in _KIND_SET):
            self._err("a declaration kind keyword")
        kind = t.value
        kw = t
        self.i += 1
        name = self._name()
        signature = None
        # signature begins with '(' on the same logical position
        if self._is_op("("):
            signature = self._signature()
        body = self._block()           # returns (statements, close_token)
        stmts, close = body
        return Decl(kind, name, annotations, signature, stmts,
                    kw.byteStart, close.byteEnd, kw.line, kw.col)

    def _name(self):
        """name = ident | string."""
        self._skip_nl()
        t = self.toks[self.i]
        if t.kind == "IDENT":
            self.i += 1
            return t.value
        if t.kind == "STRING":
            self.i += 1
            return _strip_string(t.value)
        self._err("a declaration name (identifier or string)")

    def _annotation(self):
        """annotation = "@" ident [ "(" [ arg { "," arg } ] ")" ]."""
        self._expect_op("@")
        name = self._expect_ident().value
        args = None
        if self._is_op("("):
            args = self._paren_args()
        return ("@", name, args)

    def _signature(self):
        """signature = "(" [ param { "," param } ] ")" [ "->" type ]."""
        self._expect_op("(")
        params = []
        # newlines insignificant inside '(' (lexer suppressed), but be robust.
        if not self._is_op(")"):
            params.append(self._param())
            while self._is_op(","):
                self.i += 1
                params.append(self._param())
        self._expect_op(")")
        ret = None
        if self._is_op("->"):
            self.i += 1
            ret = self._type()
        return (params, ret)

    def _param(self):
        """param = ident ":" type [ "=" expr ]."""
        name = self._expect_ident().value
        self._expect_op(":")
        ty = self._type()
        default = None
        if self._is_op("="):
            self.i += 1
            default = self._expr()
        return (name, ty, default)

    # --- blocks & statements --------------------------------------------- #

    def _block(self):
        """block = "{" { stmt } "}" ; returns (statements, close_token)."""
        self._skip_nl()
        self._expect_op("{")
        stmts = []
        self._skip_nl()
        while not self._is_op("}"):
            if self._at_eof():
                self._err("'}' to close block")
            stmts.append(self._stmt())
            self._skip_nl()
        close = self.toks[self.i]
        self.i += 1                       # consume '}'
        return stmts, close

    def _stmt(self):
        """stmt = field_decl | grant_decl | order_decl | member_decl | assignment
                | open_decl | inherit_stmt | edge | node_decl | decl | app   (ORDERED)."""
        self._skip_nl()
        t = self.toks[self.i]

        # field_decl / grant_decl / order_decl / member_decl — BEFORE assignment.
        if self._is_ident("field", t) and self._lookahead_field():
            return self._field_decl()
        if self._is_ident("grant", t) and self._lookahead_grant():
            return self._grant_decl()
        if self._is_ident("order", t) and self._lookahead_order():
            return self._order_decl()
        # member_decl (v0.4) — soft keyword `member` followed by ident (not assign-op).
        if self._is_ident("member", t) and self._lookahead_member():
            return self._member_decl()

        # assignment = ident assign_op expr
        if t.kind == "IDENT" and self._lookahead_assign():
            return self._assignment()

        # open_decl — AFTER assignment (bare `open`, not `open =`).
        if self._is_ident("open", t):
            self.i += 1
            return OpenDecl()

        # inherit_stmt = "inherit" ident { ident }
        if self._is_ident("inherit", t):
            return self._inherit_stmt()

        # edge = ref "->" ref { "->" ref } [ ":" string ]   (try before node/decl)
        edge = self._try_edge()
        if edge is not None:
            return edge

        # node_decl = "node" name block
        if self._is_ident("node", t) and self._lookahead_node():
            return self._node_decl()

        # decl = { annotation } kind name [ signature ] block
        if self._is_op("@") or (t.kind == "IDENT" and t.value in _KIND_SET
                                and self._lookahead_decl()):
            return self._decl()

        # app = ref [ "(" ... ")" ] [ record ]
        if t.kind == "IDENT":
            return self._app()

        self._err("a statement")

    # --- lookahead predicates (mirror PEG ordered choice disambiguation) -- #

    def _peek_after_ident_chain(self, start):
        """Given index `start` at an IDENT, skip a dotted ref (ident { . ident })
        WITHOUT consuming; return index just past it."""
        j = start
        if self.toks[j].kind != "IDENT":
            return start
        j += 1
        while self._is_op(".", self.toks[j]) and self.toks[j + 1].kind == "IDENT":
            j += 2
        return j

    def _lookahead_field(self):
        # `field` ident ":"
        j = self.i + 1
        if self.toks[j].kind != "IDENT":
            return False
        return self._is_op(":", self.toks[j + 1])

    def _lookahead_grant(self):
        # `grant` ident   (at least one ident follows)
        return self.toks[self.i + 1].kind == "IDENT"

    def _lookahead_order(self):
        # `order` ident "<"   (order_chain needs '<' as its second token)
        j = self.i + 1
        if self.toks[j].kind != "IDENT":
            return False
        return self._is_op("<", self.toks[j + 1])

    def _lookahead_member(self):
        # `member` ident   — but NOT `member = expr` (that is an assignment).
        # Mirrors _lookahead_grant: the next token must be an ident, not an op.
        nxt = self.toks[self.i + 1]
        return nxt.kind == "IDENT"

    def _lookahead_assign(self):
        # ident assign_op   (assignment target is a BARE ident, not dotted)
        return self.toks[self.i + 1].kind == "OP" and \
            self.toks[self.i + 1].value in ("=", "?=")

    def _lookahead_node(self):
        # `node` name "{"  — distinguish from a bare ref `node` / edge `node ->`.
        j = self.i + 1
        nt = self.toks[j]
        if nt.kind == "IDENT" or nt.kind == "STRING":
            return self._is_op("{", self.toks[j + 1])
        return False

    def _lookahead_decl(self):
        # kind name [signature] "{"  — name is ident|string, then '(' or '{'.
        j = self.i + 1
        nt = self.toks[j]
        if not (nt.kind == "IDENT" or nt.kind == "STRING"):
            return False
        k = j + 1
        return self._is_op("{", self.toks[k]) or self._is_op("(", self.toks[k])

    # --- statement forms ------------------------------------------------- #

    def _field_decl(self):
        """field_decl = "field" ident ":" type [ "{" { refinement } "}" ]."""
        self.i += 1                       # 'field'
        name = self._expect_ident().value
        self._expect_op(":")
        ty = self._type()
        refinements = []
        if self._is_op("{"):
            self.i += 1
            self._skip_nl()
            while not self._is_op("}"):
                if self._at_eof():
                    self._err("'}' to close refinement list")
                refinements.append(self._refinement())
                self._skip_nl()
            self.i += 1                   # '}'
        return FieldDecl(name, ty, refinements)

    def _refinement(self):
        """refinement = required | optional | nonempty | default "=" expr
                       | oneof list | cmp_ref | range_ref | matches regex."""
        self._skip_nl()
        t = self.toks[self.i]
        if self._is_ident("required", t) or self._is_ident("optional", t) \
                or self._is_ident("nonempty", t):
            self.i += 1
            return (t.value,)
        if self._is_ident("default", t):
            self.i += 1
            self._expect_op("=")
            return ("default", self._expr())
        if self._is_ident("oneof", t):
            self.i += 1
            return ("oneof", self._list())
        if self._is_ident("matches", t):
            self.i += 1
            self._skip_nl()
            r = self.toks[self.i]
            if r.kind != "REGEX":
                self._err("a /regex/ literal after `matches`")
            self.i += 1
            return ("matches", r.value)
        # cmp_ref = ( ">=" | "<=" | ">" | "<" ) number
        for op in _CMP_OPS:
            if self._is_op(op, t):
                self.i += 1
                num = self._expect_number()
                return ("cmp", op, num)
        # range_ref = "in" number ".." number
        if self._is_ident("in", t):
            self.i += 1
            lo = self._expect_number()
            self._expect_op("..")
            hi = self._expect_number()
            return ("range", lo, hi)
        self._err("a refinement (required/optional/nonempty/default/oneof/"
                  "comparison/in/matches)")

    def _expect_number(self):
        self._skip_nl()
        t = self.toks[self.i]
        if t.kind != "NUMBER":
            self._err("a number")
        self.i += 1
        return t.value

    def _grant_decl(self):
        """grant_decl = "grant" ident { ident } ; line-bounded { ident }."""
        self.i += 1                       # 'grant'
        names = [self._expect_ident().value]
        # { ident } is line-bounded: a NEWLINE ends it (do NOT skip NEWLINE here).
        while self.toks[self.i].kind == "IDENT":
            names.append(self.toks[self.i].value)
            self.i += 1
        return GrantDecl(names)

    def _member_decl(self):
        """member_decl = "member" ident  (v0.4, RFC 0017).

        Names one closed member of the enclosing ``namespace`` block.  Soft-
        keyword: only reached when ``_lookahead_member`` passes (the next token
        is an ident, ruling out ``member = expr`` which falls to ``_assignment``)."""
        self.i += 1                       # 'member'
        name = self._expect_ident().value
        return MemberDecl(name)

    def _order_decl(self):
        """order_decl = "order" order_chain { ";" order_chain } ;
        chain is line-bounded but ';' continues across a newline."""
        self.i += 1                       # 'order'
        chains = [self._order_chain()]
        while True:
            # ';' may continue across a newline; first see if a ';' is reachable.
            save = self.i
            # do not skip NEWLINE to find ';' (a chain is line-bounded), but the
            # recognizer treats ';' itself as a separator that absorbs the NEWLINE
            # *after* it. So: a ';' must appear before any NEWLINE on this line.
            if self._is_op(";", self.toks[self.i]):
                self.i += 1
                self._skip_nl()           # ';' absorbs trailing newlines
                chains.append(self._order_chain())
                continue
            self.i = save
            break
        return OrderDecl(chains)

    def _order_chain(self):
        """order_chain = ident "<" ident { "<" ident } ; line-bounded."""
        # NEWLINE is significant here; do not skip it within the chain.
        t = self.toks[self.i]
        if t.kind != "IDENT":
            self._err("an identifier to start an order chain")
        names = [t.value]
        self.i += 1
        if not self._is_op("<", self.toks[self.i]):
            self._err("'<' in an order chain")
        while self._is_op("<", self.toks[self.i]):
            self.i += 1
            n = self.toks[self.i]
            if n.kind != "IDENT":
                self._err("an identifier after '<' in an order chain")
            names.append(n.value)
            self.i += 1
        return names

    def _inherit_stmt(self):
        """inherit_stmt = "inherit" ident { ident } ; line-bounded { ident }."""
        self.i += 1                       # 'inherit'
        names = [self._expect_ident().value]
        while self.toks[self.i].kind == "IDENT":
            names.append(self.toks[self.i].value)
            self.i += 1
        return InheritStmt(names)

    def _assignment(self):
        """assignment = ident assign_op expr."""
        target = self.toks[self.i].value
        self.i += 1
        op = self.toks[self.i].value      # '=' or '?='
        self.i += 1
        value = self._expr()
        return Assignment(target, op, value)

    def _node_decl(self):
        """node_decl = "node" name block."""
        kw = self.toks[self.i]            # 'node'
        self.i += 1
        name = self._name()
        stmts, close = self._block()
        return NodeDecl(name, stmts, kw.byteStart, close.byteEnd, kw.line, kw.col)

    def _try_edge(self):
        """edge = ref "->" ref { "->" ref } [ ":" string ].

        Try to parse an edge; if the ref is not followed by '->', backtrack.
        """
        save = self.i
        if self.toks[self.i].kind != "IDENT":
            return None
        first = self._ref()
        if not self._is_op("->"):
            self.i = save
            return None
        refs = [first]
        while self._is_op("->"):
            self.i += 1
            refs.append(self._ref())
        label = None
        if self._is_op(":"):
            self.i += 1
            self._skip_nl()
            t = self.toks[self.i]
            if t.kind != "STRING":
                self._err("a string label after ':' in an edge")
            self.i += 1
            label = _strip_string(t.value)
        return Edge(refs, label)

    # --- expressions ----------------------------------------------------- #

    def _expr(self):
        """expr = literal | list | record | app."""
        self._skip_nl()
        t = self.toks[self.i]
        if t.kind in ("STRING", "NUMBER", "PATH", "DURATION", "BYTES"):
            self.i += 1
            return _make_literal(t)
        if self._is_ident("true", t) or self._is_ident("false", t):
            self.i += 1
            return Literal("BOOL", t.value)
        if self._is_ident("null", t):
            self.i += 1
            return Literal("NULL", "null")
        if self._is_op("["):
            return self._list()
        if self._is_op("{"):
            return self._record()
        if t.kind == "IDENT":
            return self._app()
        self._err("an expression")

    def _app(self):
        """app = ref [ "(" [ arg { "," arg } ] ")" ] [ record ]."""
        ref = self._ref()
        args = None
        if self._is_op("("):
            args = self._paren_args()
        record = None
        if self._is_op("{"):
            record = self._record().entries
        return App(ref, args, record)

    def _paren_args(self):
        """"(" [ arg { "," arg } ] ")"  — newlines insignificant inside (lexer)."""
        self._expect_op("(")
        args = []
        if not self._is_op(")"):
            args.append(self._expr())
            while self._is_op(","):
                self.i += 1
                args.append(self._expr())
        self._expect_op(")")
        return args

    def _ref(self):
        """ref = ident { "." ident }."""
        self._skip_nl()
        t = self.toks[self.i]
        if t.kind != "IDENT":
            self._err("a reference (identifier)")
        parts = [t.value]
        start = t
        end = t
        self.i += 1
        while self._is_op(".") and self.toks[self.i + 1].kind == "IDENT":
            self.i += 1                   # '.'
            nt = self.toks[self.i]
            parts.append(nt.value)
            end = nt
            self.i += 1
        return Ref(parts, start.byteStart, end.byteEnd, start.line, start.col)

    def _list(self):
        """list = "[" [ expr { "," expr } ] "]"  — newlines insignificant inside."""
        self._expect_op("[")
        items = []
        if not self._is_op("]"):
            items.append(self._expr())
            while self._is_op(","):
                self.i += 1
                # tolerate a trailing comma before ']' (PEG `[ expr { , expr } ]`
                # would reject it, so keep strict): require an expr.
                items.append(self._expr())
        self._expect_op("]")
        return ListLit(items)

    def _record(self):
        """record = "{" { assignment | inherit_stmt } "}"."""
        self._expect_op("{")
        entries = []
        self._skip_nl()
        while not self._is_op("}"):
            if self._at_eof():
                self._err("'}' to close record")
            t = self.toks[self.i]
            if self._is_ident("inherit", t):
                entries.append(self._inherit_stmt())
            elif t.kind == "IDENT" and self._lookahead_assign():
                entries.append(self._assignment())
            else:
                self._err("an assignment or `inherit` in a record")
            self._skip_nl()
        self.i += 1                       # '}'
        return RecordLit(entries)

    # --- types ----------------------------------------------------------- #

    def _type(self):
        """type = type_atom { "|" type_atom } ; stored as flat text."""
        parts = [self._type_atom()]
        while self._is_op("|"):
            self.i += 1
            parts.append(self._type_atom())
        return TypeRef(" | ".join(parts))

    def _type_atom(self):
        """type_atom = qualname [ "<" type { "," type } ">" ]
                     | "(" [ type { "," type } ] ")" "->" type."""
        self._skip_nl()
        if self._is_op("("):
            self.i += 1
            inner = []
            if not self._is_op(")"):
                inner.append(self._type().text)
                while self._is_op(","):
                    self.i += 1
                    inner.append(self._type().text)
            self._expect_op(")")
            self._expect_op("->")
            ret = self._type().text
            return "(" + ", ".join(inner) + ") -> " + ret
        # qualname
        name = self._qualname()
        if self._is_op("<"):
            self.i += 1
            args = [self._type().text]
            while self._is_op(","):
                self.i += 1
                args.append(self._type().text)
            self._expect_op(">")
            return name + "<" + ", ".join(args) + ">"
        return name

    def _qualname(self):
        """qualname = ident { "." ident }."""
        t = self._expect_ident()
        parts = [t.value]
        while self._is_op(".") and self.toks[self.i + 1].kind == "IDENT":
            self.i += 1
            parts.append(self.toks[self.i].value)
            self.i += 1
        return ".".join(parts)


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

def _strip_string(tokval: str) -> str:
    """Strip the surrounding double quotes from a STRING token value."""
    if len(tokval) >= 2 and tokval[0] == '"' and tokval[-1] == '"':
        return tokval[1:-1]
    return tokval


def _make_literal(t: Token) -> Literal:
    if t.kind == "STRING":
        return Literal("STRING", _strip_string(t.value))
    return Literal(t.kind, t.value)


def parse(tokens, filename="<vaked>"):
    """Parse a token list into a list of top-level items (decls/imports)."""
    p = Parser(tokens, filename)
    items = p.parse_file()
    return items


def parse_source(src: str, filename="<vaked>"):
    """Tokenize then parse ``src``; raises VakedLexError / VakedSyntaxError."""
    toks = tokenize(src, filename)
    return parse(toks, filename)
