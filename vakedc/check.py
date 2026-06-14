#!/usr/bin/env python3
"""vakedc.check — 0011 type-system pipeline stages 3 (elaborate) and 4 (check).

This is the Goal-2 checker.  It is a deterministic, source-mapped function of (a
parsed .vaked file + the built-in catalog ``vaked/schema/builtins.vaked``) → a
list of :class:`Diagnostic` records.  Its IO is bounded and explicit: it reads
the builtins catalog once (``load_builtins``) and, for closed-world ref
resolution (§6.1 stage 2), reads each ``use``-imported file once to bind that
file's top-level declarations into scope (``_collect_import_decls``).  Both are
deterministic; no clocks, randomness, or network.

What it implements (docs/language/0011-type-system.md):

  * Stage 3 — *elaborate*: build a schema registry from the builtins LPG plus the
    in-file user ``schema`` / ``capability`` declarations (user decls extend or
    override the catalog by name, per 0011 §1), and a per-domain capability
    attenuation partial order (reflexive-transitive closure of the ``order``
    chains).
  * Stage 4 — *check*:
      (a) conformance — §1.1 five-clause rule (required present + well-typed via
          structural matching incl. the Path-from-String acceptance of §2.5;
          optionals; constraints; unknown fields rejected unless the schema is
          ``open``);
      (b) constraints — the CLOSED set of §3 (oneof, cmp, range, nonempty,
          matches within the bounded regex dialect, default agreement), plus
          load-time refinement well-formedness (§3.7) and capability-order
          well-formedness (§4.2);
      (c) capabilities — §4: every ``domain.grant`` reference is valid, and a
          ``mesh`` delegation edge (``routes_to``) must not escalate authority —
          the receiver's grant-set must be ``⊑`` the sender's, per domain;
      (d) generics — §5: ``catalog.from`` must target an ``index`` (and the item
          type must agree when both declare one); a ``fiber``'s ``input`` /
          ``output`` are bound and, where the data permits, checked for
          consistency.

Diagnostics carry stable 0011 codes (``E-CONFORM-*``, ``E-CONSTRAINT-*``,
``E-CAP-*``, ``E-GENERIC-*``, plus the load-time ``E-SCHEMA-*`` / ``E-CAP-ORDER-
CYCLE`` of §6.5, and ``E-REF-UNRESOLVED`` for the closed-world stage-2 resolution
of §6.1), are source-mapped from the AST/token spans, and are sorted by
``(file, byteStart, code)`` for determinism.

Spans: the LPG records provenance at the *declaration* granularity only, and the
AST exposes byte spans for decls, nodes, and refs but not for assignments or
literals.  To land a diagnostic on the exact offending construct (a field name,
a value literal, an edge), this module re-tokenizes each source file once and
locates the construct within its enclosing decl's byte range — deterministically
and with no extra IO beyond the already-read source text.
"""

from __future__ import annotations

import os
from bisect import bisect_left
from dataclasses import dataclass, field as dc_field

from . import parser as P
from .lexer import tokenize
from .parser import parse_source
from .resolve import build_graph


# --------------------------------------------------------------------------- #
# Diagnostic record
# --------------------------------------------------------------------------- #

@dataclass
class Diagnostic:
    code: str
    message: str
    file: str
    line: int
    col: int
    byteStart: int
    byteEnd: int
    decl: str                      # "<kind> <name>" of the enclosing declaration
    severity: str = "error"
    related: list = dc_field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "code": self.code,
            "severity": self.severity,
            "message": self.message,
            "file": self.file,
            "decl": self.decl,
            "span": {
                "byteStart": self.byteStart,
                "byteEnd": self.byteEnd,
                "line": self.line,
                "col": self.col,
            },
            "related": list(self.related),
        }

    def sort_key(self):
        return (self.file, self.byteStart, self.byteEnd, self.code)


# --------------------------------------------------------------------------- #
# Default builtins-catalog location
# --------------------------------------------------------------------------- #

def default_builtins_path() -> str:
    """Absolute path to the repo's ``vaked/schema/builtins.vaked``.

    Resolved relative to this package (``vakedc/`` lives at the repo root next to
    ``vaked/``), so ``python3 -m vakedc check`` works from any CWD.  If that path
    does not exist (e.g. an unusual install layout), fall back to a CWD-relative
    ``vaked/schema/builtins.vaked``.
    """
    pkg_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(pkg_dir)
    candidate = os.path.join(repo_root, "vaked", "schema", "builtins.vaked")
    if os.path.exists(candidate):
        return candidate
    return os.path.join(os.getcwd(), "vaked", "schema", "builtins.vaked")


# --------------------------------------------------------------------------- #
# Source position map — locate a construct's byte span within a decl
# --------------------------------------------------------------------------- #

class _SourceMap:
    """Token-indexed view of one source file, used to land diagnostics on the
    exact offending token (the AST/LPG only span declarations and refs)."""

    __slots__ = ("file", "tokens", "_starts")

    def __init__(self, src: str, filename: str):
        self.file = filename
        # tokenize is deterministic and pure; comments are already stripped.
        self.tokens = [t for t in tokenize(src, filename) if t.kind not in ("NEWLINE", "EOF")]
        # Tokens are emitted in source order, so byteStart is sorted: span
        # lookups bisect instead of scanning every token of the file (#29 —
        # the scan made checking quadratic in declaration size).
        self._starts = [t.byteStart for t in self.tokens]

    def _toks_in(self, byteStart: int, byteEnd: int):
        lo = bisect_left(self._starts, byteStart)
        hi = bisect_left(self._starts, byteEnd)
        return self.tokens[lo:hi]

    def field_name_span(self, decl_start, decl_end, name):
        """Span of the FIRST top-level assignment / field-name identifier ``name``
        within [decl_start, decl_end).  Used for unknown-field and missing-value
        diagnostics."""
        toks = self._toks_in(decl_start, decl_end)
        for idx, t in enumerate(toks):
            if t.kind == "IDENT" and t.value == name:
                nxt = toks[idx + 1] if idx + 1 < len(toks) else None
                # `name =` / `name ?=` / `name :` (assignment, field decl) and
                # `name {` (app-with-record / block-shaped field, e.g. an
                # unknown `backpressure { … }` inside a closed schema).
                if nxt is not None and nxt.kind == "OP" and nxt.value in ("=", "?=", ":", "{"):
                    return _span_of(t)
        return None

    def field_value_span(self, decl_start, decl_end, name):
        """Span covering the VALUE of assignment ``name = <value>`` within the
        decl range — from the first value token after the assign-op up to the end
        of that value.  Used for constraint diagnostics (land on the literal)."""
        toks = self._toks_in(decl_start, decl_end)
        for idx, t in enumerate(toks):
            if t.kind == "IDENT" and t.value == name:
                nxt = toks[idx + 1] if idx + 1 < len(toks) else None
                if nxt is not None and nxt.kind == "OP" and nxt.value in ("=", "?="):
                    val = toks[idx + 2] if idx + 2 < len(toks) else None
                    if val is not None:
                        return _span_of(val)
        # fall back to the field name
        return self.field_name_span(decl_start, decl_end, name)


def _span_of(tok):
    return (tok.byteStart, tok.byteEnd, tok.line, tok.col)


# --------------------------------------------------------------------------- #
# Schema & capability registry (Stage 3 — elaborate)
# --------------------------------------------------------------------------- #

# Scalar type names the checker matches structurally against literal forms.
_SCALARS = frozenset(("String", "Int", "Float", "Bool", "Path", "Duration", "Bytes", "Null"))

# Auxiliary (built-in) types that parallel-types.md's vocabulary table defines as
# *aliases of `String`* — a String literal matches them directly.
_STRING_ALIASES = frozenset(("Strategy", "View"))

# A type atom is a generic parameter position when it is a bare upper-case letter
# (T, I, O) or one of the named graph parameters (Node, Edge).  Per 0011 §5 a type
# parameter binds to / matches any value, so the checker accepts any value here
# (the worked examples never give the checker a second binding to contradict).
_GENERIC_PARAMS = frozenset(("Node", "Edge"))


def _is_generic_param(atom):
    return atom in _GENERIC_PARAMS or (len(atom) == 1 and atom.isalpha() and atom.isupper())

# Literal-token kind (Literal.kind / prop "lit") -> the scalar type(s) it inhabits.
# (Int◁Float widening and the Path/Duration/Bytes string-form acceptances of
# §2.1/§2.5 are handled in _value_matches_type, not here.)
_LIT_SCALAR = {
    "STRING": "String",
    "NUMBER": None,         # Int or Float, decided by the '.' rule
    "BOOL": "Bool",
    "PATH": "Path",
    "DURATION": "Duration",
    "BYTES": "Bytes",
    "NULL": "Null",
}


@dataclass
class FieldSpec:
    name: str
    type_text: str
    refinements: list           # list of refinement tuples (AST objects inside)
    presence: str               # "required" | "optional"
    has_default: bool


@dataclass
class SchemaSpec:
    name: str
    fields: "dict[str, FieldSpec]"
    open: bool
    origin_file: str
    decl_span: tuple            # (byteStart, byteEnd, line, col) of the schema decl


@dataclass
class CapabilitySpec:
    domain: str
    grants: set
    order_chains: list          # list of list[str]
    leq: dict                   # grant -> set of grants g' with g <= g' (closure)
    origin_file: str
    decl_span: tuple


@dataclass
class NamespaceSpec:
    """A value-namespace head, parsed from a ``namespace <name> { … }`` block.

    ``open=True`` means any member is accepted (e.g. ``pkgs``, ``nix``); when
    ``open=False``, ``members`` is the exhaustive closed set.  Mixing ``open``
    with explicit ``member`` declarations is a load-time error (reported by
    ``_check_namespace_wellformed``)."""
    head: str                   # the namespace name (e.g. "pkgs", "eventd")
    open: bool                  # True ⇒ any member accepted
    members: set                # member names (empty if open)
    origin_file: str
    decl_span: tuple            # (byteStart, byteEnd, line, col)


def _presence_of(refinements):
    """Derive ('required'|'optional', has_default) from a field's refinements,
    per 0011 §3.3 (default = required unless `optional` or a `default` is given)."""
    has_default = any(r[0] == "default" for r in refinements)
    if any(r[0] == "optional" for r in refinements):
        return "optional", has_default
    if has_default:
        return "optional", has_default
    # explicit `required` or no presence marker → required
    return "required", has_default


def _schema_from_decl(decl, filename) -> SchemaSpec:
    fields = {}
    is_open = False
    for st in decl.body:
        if isinstance(st, P.FieldDecl):
            presence, has_default = _presence_of(st.refinements)
            fields[st.name] = FieldSpec(
                name=st.name,
                type_text=st.type.text,
                refinements=list(st.refinements),
                presence=presence,
                has_default=has_default,
            )
        elif isinstance(st, P.OpenDecl):
            is_open = True
    return SchemaSpec(
        name=decl.name, fields=fields, open=is_open,
        origin_file=filename,
        decl_span=(decl.byteStart, decl.byteEnd, decl.line, decl.col),
    )


def _capability_from_decl(decl, filename) -> CapabilitySpec:
    grants = []
    chains = []
    for st in decl.body:
        if isinstance(st, P.GrantDecl):
            grants.extend(st.names)
        elif isinstance(st, P.OrderDecl):
            chains.extend([list(c) for c in st.chains])
    return CapabilitySpec(
        domain=decl.name, grants=set(grants), order_chains=chains, leq={},
        origin_file=filename,
        decl_span=(decl.byteStart, decl.byteEnd, decl.line, decl.col),
    )


def _transitive_closure(grants, chains):
    """Reflexive-transitive closure of the `<` relation declared by the chains.

    Returns ``leq`` mapping each grant g to the set { g' : g <= g' } (g is weaker
    than or equal to g').  Returns ``None`` together with the offending pair if a
    cycle is detected (the relation is then not antisymmetric — a schema error)."""
    # direct edges a -> b for each consecutive pair a<b in a chain
    succ = {g: set() for g in grants}
    for ch in chains:
        for a, b in zip(ch, ch[1:]):
            succ.setdefault(a, set()).add(b)
            succ.setdefault(b, set())
    # Floyd-style closure over the (finite) grant set.
    nodes = set(succ.keys())
    reach = {g: set([g]) for g in nodes}   # reflexive
    for g in nodes:
        stack = list(succ.get(g, ()))
        while stack:
            x = stack.pop()
            if x not in reach[g]:
                reach[g].add(x)
                stack.extend(succ.get(x, ()))
    # a strict order forbids `a < a`: a direct self-edge is a degenerate cycle
    for a in nodes:
        if a in succ.get(a, ()):
            return None, (a, a)
    # antisymmetry: a<=b and b<=a with a!=b  ⇒ cycle
    for a in nodes:
        for b in reach[a]:
            if a != b and a in reach.get(b, ()):
                return None, (a, b)
    return reach, None


# --------------------------------------------------------------------------- #
# Registry assembly + load-time well-formedness checks
# --------------------------------------------------------------------------- #

_LEGAL_REFINEMENTS = frozenset(
    ("required", "optional", "nonempty", "default", "oneof", "cmp", "range", "matches"))


class _Registry:
    def __init__(self):
        self.schemas: "dict[str, SchemaSpec]" = {}
        self.caps: "dict[str, CapabilitySpec]" = {}
        self.namespaces: "dict[str, NamespaceSpec]" = {}   # head -> NamespaceSpec (builtins)

    def add_schema(self, spec: SchemaSpec):
        self.schemas[spec.name] = spec      # later (user) overrides earlier (builtin)

    def add_capability(self, spec: CapabilitySpec):
        self.caps[spec.domain] = spec

    def add_namespace(self, spec: NamespaceSpec):
        self.namespaces[spec.head] = spec   # later overrides earlier


def _namespace_from_decl(decl, filename) -> NamespaceSpec:
    """Build a :class:`NamespaceSpec` from a parsed ``namespace`` declaration.

    The body is either a bare ``open`` (``OpenDecl``) or a sequence of
    ``MemberDecl`` statements.  Mixing is flagged by
    ``_check_namespace_wellformed`` at load time."""
    is_open = False
    members = set()
    for st in decl.body:
        if isinstance(st, P.OpenDecl):
            is_open = True
        elif isinstance(st, P.MemberDecl):
            members.add(st.name)
    return NamespaceSpec(
        head=decl.name,
        open=is_open,
        members=members,
        origin_file=filename,
        decl_span=(decl.byteStart, decl.byteEnd, decl.line, decl.col),
    )


def _load_decls_into(registry: _Registry, items, filename):
    for it in items:
        if isinstance(it, P.Decl):
            if it.kind == "schema":
                registry.add_schema(_schema_from_decl(it, filename))
            elif it.kind == "capability":
                registry.add_capability(_capability_from_decl(it, filename))
            elif it.kind == "namespace":
                registry.add_namespace(_namespace_from_decl(it, filename))


# --------------------------------------------------------------------------- #
# Regex dialect validation (§3.5) — bounded, regular, no backrefs/lookaround
# --------------------------------------------------------------------------- #

def _regex_dialect_error(regex_literal):
    """Return an explanatory string if ``regex_literal`` (the raw `/…/` token,
    slashes included) uses a feature outside the bounded dialect of 0011 §3.5;
    otherwise None.

    Allowed: literal chars, classes [...], '.', '|', grouping (...), quantifiers
    ?, *, +, {m}, {m,n}, anchors ^ $, and backslash escapes of metacharacters.
    Forbidden: backreferences (\\1), lookaround ((?=…) (?<…) (?!…)), named/atomic
    groups and other non-linear constructs ((?P…), (?>…))."""
    body = regex_literal
    if len(body) >= 2 and body[0] == "/" and body[-1] == "/":
        body = body[1:-1]
    i = 0
    n = len(body)
    in_class = False
    while i < n:
        c = body[i]
        if c == "\\":
            if i + 1 >= n:
                return "trailing backslash"
            nxt = body[i + 1]
            if nxt.isdigit() and nxt != "0":
                return "backreference (\\%s) is not in the bounded dialect" % nxt
            i += 2
            continue
        if in_class:
            if c == "]":
                in_class = False
            i += 1
            continue
        if c == "[":
            in_class = True
            i += 1
            continue
        if c == "(":
            # grouping; reject the extension forms after '(?'
            if i + 1 < n and body[i + 1] == "?":
                kind = body[i + 2] if i + 2 < n else ""
                if kind in ("=", "!"):
                    return "lookahead ((?%s…)) is not in the bounded dialect" % kind
                if kind == "<":
                    nxt = body[i + 3] if i + 3 < n else ""
                    if nxt in ("=", "!"):
                        return "lookbehind ((?<%s…)) is not in the bounded dialect" % nxt
                    return "named group ((?<…>)) is not in the bounded dialect"
                if kind == "P":
                    return "named group ((?P…)) is not in the bounded dialect"
                if kind == ">":
                    return "atomic group ((?>…)) is not in the bounded dialect"
                if kind == ":":
                    i += 3   # non-capturing group is fine
                    continue
                return "extended group ((?%s…)) is not in the bounded dialect" % kind
            i += 1
            continue
        i += 1
    if in_class:
        return "unterminated character class '['"
    return None


# --------------------------------------------------------------------------- #
# Load-time refinement & capability well-formedness (§3.7, §4.2, §6.5)
# --------------------------------------------------------------------------- #

def _base_type(type_text):
    """Strip the outermost ``List<…>`` wrapper, returning (inner_text, is_list)."""
    t = type_text.strip()
    if t.startswith("List<") and t.endswith(">"):
        return t[len("List<"):-1].strip(), True
    return t, False


def _is_numeric_type(type_text):
    inner, _ = _base_type(type_text)
    return inner in ("Int", "Float", "Duration", "Bytes")


def _check_schema_wellformed(spec: SchemaSpec, smap_for, diags):
    """0011 §3.7 / §6.4a — load-time well-formedness of a schema's refinements.
    Errors are reported against the schema declaration's source."""
    smap = smap_for(spec.origin_file)
    ds, de, dl, dc = spec.decl_span
    for fname, f in spec.fields.items():
        seen_presence = set()
        for r in f.refinements:
            kind = r[0]
            span = None
            if smap is not None:
                span = smap.field_name_span(ds, de, fname) or (ds, de, dl, dc)
            else:
                span = (ds, de, dl, dc)
            if kind in ("required", "optional"):
                seen_presence.add(kind)
            if kind == "matches":
                if _base_type(f.type_text)[0] not in ("String", "Path"):
                    _emit(diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, spec,
                          "`matches` applies only to String or Path; field "
                          f"`{fname}` is `{f.type_text}`")
                else:
                    err = _regex_dialect_error(r[1])
                    if err is not None:
                        _emit(diags, "E-SCHEMA-BAD-REGEX", spec.origin_file, span, spec,
                              f"field `{fname}`: {err}")
            elif kind == "oneof":
                ll = r[1]
                items = getattr(ll, "items", [])
                if len(items) < 1:
                    _emit(diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, spec,
                          f"field `{fname}`: `oneof` needs at least one element")
                for lit in items:
                    if not _literal_matches_type(lit, f.type_text):
                        _emit(diags, "E-SCHEMA-BAD-ONEOF", spec.origin_file, span, spec,
                              f"field `{fname}`: `oneof` element "
                              f"{_render_literal(lit)} does not match type "
                              f"`{f.type_text}`")
            elif kind in ("cmp", "range"):
                if not _is_numeric_type(f.type_text):
                    _emit(diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, spec,
                          f"field `{fname}`: numeric refinement on non-numeric "
                          f"type `{f.type_text}`")
                if kind == "range":
                    lo = _num(r[1])
                    hi = _num(r[2])
                    if lo is not None and hi is not None and lo > hi:
                        _emit(diags, "E-SCHEMA-BAD-RANGE", spec.origin_file, span, spec,
                              f"field `{fname}`: range lower bound {r[1]} exceeds "
                              f"upper bound {r[2]}")
            elif kind == "default":
                lit = r[1]
                # default must satisfy the field type; no refs allowed.
                if isinstance(lit, P.App):
                    _emit(diags, "E-SCHEMA-BAD-DEFAULT", spec.origin_file, span, spec,
                          f"field `{fname}`: `default` must be a literal, not a ref")
                elif isinstance(lit, P.Literal) and not _literal_matches_type(lit, f.type_text):
                    _emit(diags, "E-SCHEMA-BAD-DEFAULT", spec.origin_file, span, spec,
                          f"field `{fname}`: default {_render_literal(lit)} does not "
                          f"match type `{f.type_text}`")
        if "required" in seen_presence and ("optional" in seen_presence or f.has_default):
            span = (smap.field_name_span(ds, de, fname) if smap else None) or (ds, de, dl, dc)
            _emit(diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, spec,
                  f"field `{fname}`: `required` cannot be combined with "
                  f"`optional`/`default`")


def _check_namespace_wellformed(spec: NamespaceSpec, smap_for, diags):
    """RFC 0017 load-time well-formedness: a namespace body must be open XOR closed.

    Mixing ``open`` with explicit ``member`` declarations is an error: once a
    namespace is open, enumerating members is contradictory (the members would be
    subsumed, and the intent is unclear).  Reported as ``E-SCHEMA-REFINEMENT``
    (reuse; a load-time structural error on a declaration body)."""
    if spec.open and spec.members:
        smap = smap_for(spec.origin_file)
        ds, de, dl, dc = spec.decl_span
        span = (ds, de, dl, dc)
        _emit(diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, spec,
              f"namespace `{spec.head}`: body mixes `open` with `member` declarations; "
              f"use `open` alone (any member) or `member <name>` alone (closed set)")


def _check_capability_wellformed(spec: CapabilitySpec, smap_for, diags):
    """0011 §4.2 — dangling grants, exactly-one-order (structural), acyclicity."""
    smap = smap_for(spec.origin_file)
    ds, de, dl, dc = spec.decl_span
    span = (ds, de, dl, dc)
    # 1. every grant named in order must be declared
    named = set()
    for ch in spec.order_chains:
        named.update(ch)
    dangling = sorted(named - spec.grants)
    for g in dangling:
        gs = (smap.field_name_span(ds, de, g) if smap else None) or span
        _emit(diags, "E-CAP-ORDER-DANGLING", spec.origin_file, gs, spec,
              f"capability `{spec.domain}`: order names grant `{g}` which is not "
              f"declared by a `grant` statement")
    # 2/3. acyclicity (antisymmetry) of the closure
    leq, cyc = _transitive_closure(spec.grants, spec.order_chains)
    if cyc is not None:
        a, b = cyc
        _emit(diags, "E-CAP-ORDER-CYCLE", spec.origin_file, span, spec,
              f"capability `{spec.domain}`: order is cyclic (`{a}` and `{b}` are "
              f"mutually ≤) — the relation must be a partial order")
        spec.leq = {g: set([g]) for g in spec.grants}
    else:
        spec.leq = leq


# --------------------------------------------------------------------------- #
# Literal / value helpers
# --------------------------------------------------------------------------- #

def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _render_literal(lit):
    if isinstance(lit, P.Literal):
        if lit.kind == "STRING":
            return '"%s"' % lit.value
        return str(lit.value)
    return repr(lit)


def _literal_matches_type(lit, type_text):
    """Does an AST :class:`Literal` match a (possibly composite) type textually?
    Implements the scalar arm of §2.4 incl. Int◁Float and the string-forms of
    §2.1/§2.5 for Path/Duration/Bytes."""
    inner, is_list = _base_type(type_text)
    if is_list:
        return False   # a scalar literal never matches a List type
    arms = [a.strip() for a in inner.split("|")]
    return any(_literal_matches_scalar(lit, a) for a in arms)


def _literal_matches_scalar(lit, type_atom):
    if not isinstance(lit, P.Literal):
        return False
    k = lit.kind
    if _is_generic_param(type_atom):
        # a type parameter matches any value (§5 unification, unconstrained here).
        return True
    if type_atom in _STRING_ALIASES:
        # Strategy / View are String aliases (parallel-types.md vocabulary table).
        return k == "STRING"
    if type_atom not in _SCALARS:
        # Non-scalar (domain/aux/generic) atom: a bare literal cannot be shown to
        # match a ref-shaped type, EXCEPT the String→Path positional acceptance
        # is handled where Path is the atom (below).  Be conservative: literals
        # only match scalar atoms.
        return False
    if type_atom == "Null":
        return k == "NULL"
    if type_atom == "String":
        return k == "STRING"
    if type_atom == "Bool":
        return k == "BOOL"
    if type_atom == "Int":
        return k == "NUMBER" and "." not in str(lit.value)
    if type_atom == "Float":
        # Int◁Float widening: an Int literal matches Float (§2.4).
        return k == "NUMBER"
    if type_atom == "Path":
        # path literal, or a String used positionally as a path (§2.5).
        return k in ("PATH", "STRING")
    if type_atom == "Duration":
        return k in ("DURATION", "STRING")
    if type_atom == "Bytes":
        return k in ("BYTES", "STRING")
    return False


# value-prop forms (as produced by resolve._value_to_props):
#   literal : {"lit": <kind>, "value": ...}
#   ref/app : {"ref": <dotted>, "args"?: [...], "record"?: [...]}
#   list    : [ <value-prop>, ... ]
#   record  : {"record": [ {"assign":..} | {"inherit":..}, ... ]}

def _value_matches_type(vprop, type_text, registry):
    """Structural match (§2.4) of a value PROP against a type, *as strong as 0011
    states and no stronger*.

    Scalars match by literal form (incl. Int◁Float and the Path/Duration/Bytes
    string-forms).  ``List<T>`` requires a list whose elements each match ``T``.
    Unions match if any arm matches.  A *ref* (``{"ref": …}`` with no call args /
    record) matches any non-scalar (domain/auxiliary/generic) type — its referent
    is an external/built-in value whose type the checker cannot disprove (§2.3),
    which keeps the 15 worked examples valid without inventing checks 0011 does
    not mandate.  A call/record value matches a non-scalar type structurally."""
    inner, is_list = _base_type(type_text)
    if is_list:
        if not isinstance(vprop, list):
            return False
        return all(_value_matches_type(e, inner, registry) for e in vprop)
    arms = [a.strip() for a in _split_union(inner)]
    return any(_value_matches_atom(vprop, a, registry) for a in arms)


def _split_union(text):
    """Split a union type on top-level '|' (not inside '<...>')."""
    parts = []
    depth = 0
    cur = []
    for ch in text:
        if ch == "<":
            depth += 1
            cur.append(ch)
        elif ch == ">":
            depth -= 1
            cur.append(ch)
        elif ch == "|" and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


def _value_matches_atom(vprop, atom, registry):
    atom = atom.strip()
    atom_base, atom_is_list = _base_type(atom)
    if atom_is_list:
        return _value_matches_type(vprop, atom, registry)
    # a generic type parameter matches any value (§5).
    if _is_generic_param(atom_base):
        return True
    # literal value
    if isinstance(vprop, dict) and "lit" in vprop:
        return _litprop_matches_scalar(vprop, atom_base)
    # list value only matches a List atom (handled above) — here atom is scalar
    if isinstance(vprop, list):
        return False
    # ref / app / record value
    if isinstance(vprop, dict):
        if atom_base in _SCALARS or atom_base in _STRING_ALIASES:
            # a non-literal value cannot match a scalar / String-alias atom
            return False
        # non-scalar atom (domain/aux type, generic param, or a user schema name)
        if atom_base in registry.schemas and "record" in vprop and "ref" not in vprop:
            # a structural record value checked against a named schema
            return _record_conforms(vprop, registry.schemas[atom_base], registry)
        return True
    return False


def _litprop_matches_scalar(vprop, atom):
    kind = (vprop.get("lit") or "").upper()
    value = vprop.get("value")
    fake = P.Literal(kind if kind else "NULL", value)
    return _literal_matches_scalar(fake, atom)


def _record_conforms(vprop, schema: SchemaSpec, registry):
    """Best-effort structural conformance of a record VALUE (nested policy/stage
    blocks) to a named schema.  Returns True/False; nested-record diagnostics are
    intentionally light (the top-level conformance pass owns user-facing errors)."""
    entries = vprop.get("record", [])
    present = {}
    for e in entries:
        if isinstance(e, dict) and "assign" in e:
            present[e["assign"]] = e["value"]
    # required present + typed
    for fname, f in schema.fields.items():
        if f.presence == "required" and fname not in present:
            return False
    if not schema.open:
        for k in present:
            if k not in schema.fields:
                return False
    for k, v in present.items():
        f = schema.fields.get(k)
        if f is not None and not _value_matches_type(v, f.type_text, registry):
            return False
    return True


# --------------------------------------------------------------------------- #
# Constraint application (§3) on a bound field value
# --------------------------------------------------------------------------- #

def _check_field_constraints(vprop, fspec: FieldSpec, decl, smap, file, diags, decl_span):
    """Apply each refinement on ``fspec`` to the bound value ``vprop`` (§3)."""
    ds, de, dl, dc = decl_span
    vspan = (smap.field_value_span(ds, de, fspec.name) if smap else None) or decl_span

    for r in fspec.refinements:
        kind = r[0]
        if kind == "nonempty":
            if _is_empty(vprop):
                _emit(diags, "E-CONSTRAINT-NONEMPTY", file, vspan, decl,
                      f"field `{fspec.name}` is `nonempty` but the value is empty")
        elif kind == "oneof":
            allowed = [(x.kind, x.value) for x in getattr(r[1], "items", [])]
            if isinstance(vprop, dict) and "lit" in vprop:
                k = (vprop.get("lit") or "").upper()
                if not _litprop_in_oneof(vprop, allowed):
                    _emit(diags, "E-CONSTRAINT-ONEOF", file, vspan, decl,
                          f"field `{fspec.name}`: value {_render_vprop(vprop)} is "
                          f"not one of {_render_oneof(allowed)}")
        elif kind == "cmp":
            _check_cmp(vprop, r[1], r[2], fspec, decl, file, diags, vspan)
        elif kind == "range":
            _check_range(vprop, r[1], r[2], fspec, decl, file, diags, vspan)
        # required/optional/default/matches handled in conformance / load-time


def _check_cmp(vprop, op, bound_s, fspec, decl, file, diags, vspan):
    v = _vprop_number(vprop)
    b = _num(bound_s)
    if v is None or b is None:
        return
    ok = {">=": v >= b, "<=": v <= b, ">": v > b, "<": v < b}.get(op, True)
    if not ok:
        _emit(diags, "E-CONSTRAINT-RANGE", file, vspan, decl,
              f"field `{fspec.name}`: value {_fmtnum(v)} violates `{op} {bound_s}`")


def _check_range(vprop, lo_s, hi_s, fspec, decl, file, diags, vspan):
    v = _vprop_number(vprop)
    lo = _num(lo_s)
    hi = _num(hi_s)
    if v is None or lo is None or hi is None:
        return
    if not (lo <= v <= hi):
        _emit(diags, "E-CONSTRAINT-RANGE", file, vspan, decl,
              f"field `{fspec.name}`: value {_fmtnum(v)} is outside "
              f"`in {lo_s} .. {hi_s}`")


def _check_matches(vprop, regex_literal, fspec, decl, file, diags, vspan):
    """Apply a `matches /re/` refinement to a String/Path value (§3.5).  The
    dialect was validated at load; here we run the (linear-time) full match."""
    if not (isinstance(vprop, dict) and "lit" in vprop):
        return   # only literal String/Path values are matchable
    k = (vprop.get("lit") or "").upper()
    if k not in ("STRING", "PATH"):
        return
    value = vprop.get("value")
    if value is None:
        return
    import re as _re
    body = regex_literal
    if len(body) >= 2 and body[0] == "/" and body[-1] == "/":
        body = body[1:-1]
    # implicit full-anchor via fullmatch (§3.5); author-supplied ^/$ anchors
    # are harmless (fullmatch renders them redundant, not erroneous).
    pat = body
    try:
        rx = _re.compile(pat)
    except _re.error:
        return   # malformed regex already reported at load as E-SCHEMA-BAD-REGEX
    if rx.fullmatch(value) is None:
        _emit(diags, "E-CONSTRAINT-MATCHES", file, vspan, decl,
              f"field `{fspec.name}`: value {_render_vprop(vprop)} does not match "
              f"/{body}/")


def _is_empty(vprop):
    if isinstance(vprop, list):
        return len(vprop) == 0
    if isinstance(vprop, dict) and "lit" in vprop:
        v = vprop.get("value")
        return v == "" or v is None
    return False


def _litprop_in_oneof(vprop, allowed):
    k = (vprop.get("lit") or "").upper()
    val = vprop.get("value")
    for (ak, av) in allowed:
        if ak == k and str(av) == str(val):
            return True
        # numeric tolerance: Int literal vs Int oneof element
        if ak == "NUMBER" and k == "NUMBER" and _num(av) == _num(val):
            return True
    return False


def _vprop_number(vprop):
    if isinstance(vprop, dict) and "lit" in vprop and (vprop.get("lit") or "").lower() == "number":
        return _num(vprop.get("value"))
    return None


def _fmtnum(v):
    if v == int(v):
        return str(int(v))
    return str(v)


def _render_vprop(vprop):
    if isinstance(vprop, dict) and "lit" in vprop:
        if (vprop.get("lit") or "").upper() == "STRING":
            return '"%s"' % vprop.get("value")
        return str(vprop.get("value"))
    if isinstance(vprop, dict) and "ref" in vprop:
        return vprop["ref"]
    return repr(vprop)


def _render_oneof(allowed):
    parts = []
    for (k, v) in allowed:
        parts.append('"%s"' % v if k == "STRING" else str(v))
    return "[" + ", ".join(parts) + "]"


# --------------------------------------------------------------------------- #
# Diagnostic emit helper
# --------------------------------------------------------------------------- #

def _emit(diags, code, file, span, decl_or_spec, message, related=None):
    bs, be, ln, col = span
    decl_str = _decl_label(decl_or_spec)
    diags.append(Diagnostic(
        code=code, message=message, file=file,
        byteStart=bs, byteEnd=be, line=ln, col=col,
        decl=decl_str, related=related or [],
    ))


def _decl_label(d):
    if isinstance(d, P.Decl):
        return f"{d.kind} {d.name}"
    if isinstance(d, SchemaSpec):
        return f"schema {d.name}"
    if isinstance(d, CapabilitySpec):
        return f"capability {d.domain}"
    if isinstance(d, NamespaceSpec):
        return f"namespace {d.head}"
    if isinstance(d, str):
        return d
    return ""


# --------------------------------------------------------------------------- #
# Conformance over a single declaration (§1.1)
# --------------------------------------------------------------------------- #

# Statement targets that the resolver lifts to edges but which ARE field bindings
# we still want to conformance-check as fields.
def _decl_field_bindings(decl):
    """Top-level field bindings of a decl: ``Assignment`` and ``App``-with-record
    statements whose ref names a field (e.g. ``policy { … }``).  Returns a dict
    fieldname -> value-prop, plus the set of binding names in source order."""
    from .resolve import _value_to_props
    bindings = {}
    order = []
    for st in decl.body:
        if isinstance(st, P.Assignment):
            bindings[st.target] = _value_to_props(st.value)
            order.append(st.target)
        elif isinstance(st, P.App) and st.record is not None and st.args is None \
                and len(st.ref.parts) == 1:
            # a named config block in field position, e.g. `policy { … }`
            name = st.ref.parts[0]
            bindings[name] = {"record": [_entry_to_props_safe(e) for e in st.record]}
            order.append(name)
    return bindings, order


def _entry_to_props_safe(e):
    from .resolve import _value_to_props
    if isinstance(e, P.Assignment):
        return {"assign": e.target, "op": e.op, "value": _value_to_props(e.value)}
    if isinstance(e, P.InheritStmt):
        return {"inherit": list(e.names)}
    return {"unknown": repr(e)}


# nested-record field schema for known structural sub-blocks (§ catalog):
_NESTED_SCHEMA = {
    ("fiber", "policy"): "fiberPolicy",
}

# Kinds whose conformance schema is named differently from the kind, because a
# top-level `schema <kind>` would collide with a same-named `capability <kind>`
# in the kind-agnostic LPG (E-DECL-NAME-COLLISION).  `network` is both a kind
# (an egress membrane) and a capability domain; its membrane schema lives under
# `networkMembrane` (mirrors the `mem`/`memory` naming dodge in builtins.vaked).
_KIND_SCHEMA = {
    "network": "networkMembrane",
}


def _conform_decl(decl, schema: SchemaSpec, registry, smap, file, diags):
    decl_span = (decl.byteStart, decl.byteEnd, decl.line, decl.col)
    ds, de, dl, dc = decl_span
    bindings, order = _decl_field_bindings(decl)

    # Clause 1 — required fields present.
    for fname, f in schema.fields.items():
        if f.presence == "required" and fname not in bindings:
            _emit(diags, "E-CONFORM-MISSING-FIELD", file, decl_span, decl,
                  f"required field `{fname}` of schema `{schema.name}` is missing")

    # Clause 5 — unknown fields (closed schemas only).
    if not schema.open:
        for fname in order:
            if fname not in schema.fields:
                span = (smap.field_name_span(ds, de, fname) if smap else None) or decl_span
                _emit(diags, "E-CONFORM-UNKNOWN-FIELD", file, span, decl,
                      f"`{fname}` is not a declared field of closed schema "
                      f"`{schema.name}`")

    # Clauses 2 & 4 — field well-typedness + constraints, for bound fields.
    for fname, vprop in bindings.items():
        f = schema.fields.get(fname)
        if f is None:
            continue   # unknown (open schema) or already reported
        # nested structural sub-block (e.g. fiber policy) -> its own schema
        nested = _NESTED_SCHEMA.get((decl.kind, fname))
        if nested is not None and nested in registry.schemas and isinstance(vprop, dict) \
                and "record" in vprop:
            _conform_nested_record(vprop, registry.schemas[nested], registry, smap,
                                   file, diags, decl, fname, decl_span)
            continue
        if not _value_matches_type(vprop, f.type_text, registry):
            span = (smap.field_value_span(ds, de, fname) if smap else None) or decl_span
            _emit(diags, "E-CONFORM-TYPE", file, span, decl,
                  f"field `{fname}` of schema `{schema.name}` expects "
                  f"`{f.type_text}` but got {_render_vprop(vprop)}")
        # constraints (oneof / cmp / range / nonempty) on the value
        _check_field_constraints(vprop, f, decl, smap, file, diags, decl_span)
        # matches (regex) — applies to scalar string/path values
        for r in f.refinements:
            if r[0] == "matches":
                vspan = (smap.field_value_span(ds, de, fname) if smap else None) or decl_span
                _check_matches(vprop, r[1], f, decl, file, diags, vspan)


def _conform_nested_record(vprop, schema, registry, smap, file, diags, owner_decl, owner_field, decl_span):
    """Conformance of a nested record value (e.g. a fiber `policy { … }`) against
    its structural schema.  Diagnostics attribute to the owning decl/field."""
    entries = {e["assign"]: e["value"] for e in vprop.get("record", [])
               if isinstance(e, dict) and "assign" in e}
    ds, de, dl, dc = decl_span
    for fname, f in schema.fields.items():
        if f.presence == "required" and fname not in entries:
            _emit(diags, "E-CONFORM-MISSING-FIELD", file, decl_span, owner_decl,
                  f"required field `{fname}` of nested schema `{schema.name}` "
                  f"(in `{owner_field}`) is missing")
    if not schema.open:
        for fname in entries:
            if fname not in schema.fields:
                span = (smap.field_name_span(ds, de, fname) if smap else None) or decl_span
                _emit(diags, "E-CONFORM-UNKNOWN-FIELD", file, span, owner_decl,
                      f"`{fname}` is not a declared field of nested schema "
                      f"`{schema.name}` (in `{owner_field}`)")
    for fname, v in entries.items():
        f = schema.fields.get(fname)
        if f is None:
            continue
        if not _value_matches_type(v, f.type_text, registry):
            span = (smap.field_value_span(ds, de, fname) if smap else None) or decl_span
            _emit(diags, "E-CONFORM-TYPE", file, span, owner_decl,
                  f"field `{fname}` of nested schema `{schema.name}` expects "
                  f"`{f.type_text}` but got {_render_vprop(v)}")
        _check_field_constraints(v, f, owner_decl, smap, file, diags, decl_span)


# --------------------------------------------------------------------------- #
# Mesh node conformance + capability checks (§4)
# --------------------------------------------------------------------------- #

def _node_bindings(node_decl):
    from .resolve import _value_to_props
    bindings = {}
    order = []
    for st in node_decl.body:
        if isinstance(st, P.Assignment):
            bindings[st.target] = _value_to_props(st.value)
            order.append(st.target)
    return bindings, order


def _grant_ref_parts(vprop):
    """If a value-prop is a bare `domain.grant` ref, return (domain, grant)."""
    if isinstance(vprop, dict) and "ref" in vprop and "args" not in vprop and "record" not in vprop:
        parts = vprop["ref"].split(".")
        if len(parts) == 2:
            return parts[0], parts[1]
    return None


def _gather_node_grants(node_bindings):
    """Return list of (domain, grant) from a node's `capabilities` list value."""
    out = []
    caps = node_bindings.get("capabilities")
    if isinstance(caps, list):
        for e in caps:
            dg = _grant_ref_parts(e)
            if dg is not None:
                out.append(dg)
    return out


def _check_capability_refs(domain, grant, registry, file, span, decl, diags):
    cap = registry.caps.get(domain)
    if cap is None:
        _emit(diags, "E-CAP-UNKNOWN-DOMAIN", file, span, decl,
              f"unknown capability domain `{domain}` in `{domain}.{grant}`")
        return False
    if grant not in cap.grants:
        _emit(diags, "E-CAP-UNKNOWN-GRANT", file, span, decl,
              f"`{grant}` is not a declared grant of capability domain `{domain}`")
        return False
    return True


def _leq(cap: CapabilitySpec, a, b):
    """Is grant a <= grant b in this domain's attenuation order?"""
    return b in cap.leq.get(a, set([a]))


# --------------------------------------------------------------------------- #
# Generics (§5)
# --------------------------------------------------------------------------- #

def _check_generics(decl, registry, by_name_kind, smap, file, diags):
    decl_span = (decl.byteStart, decl.byteEnd, decl.line, decl.col)
    ds, de, dl, dc = decl_span
    bindings, _ = _decl_field_bindings(decl)

    if decl.kind == "catalog":
        # `from` must reference an `index` (§5.1: from : Index<T>).
        frm = bindings.get("from")
        dg = _ref_dotted(frm)
        if dg is not None:
            target_kind = _resolve_kind(dg, by_name_kind)
            if target_kind is not None and target_kind != "index":
                span = (smap.field_value_span(ds, de, "from") if smap else None) or decl_span
                _emit(diags, "E-GENERIC-INCONSISTENT", file, span, decl,
                      f"catalog `from` must target an `index` (Index<T>); "
                      f"`{dg}` is a `{target_kind}`")
            # item-type agreement: if the catalog declares its own `schema` item
            # type and the index declares one too, they must match.
            cat_item = _item_schema_of(bindings)
            idx_decl = by_name_kind.get(("index", _last(dg)))
            if cat_item is not None and idx_decl is not None:
                idx_bindings, _ = _decl_field_bindings(idx_decl)
                idx_item = _item_schema_of(idx_bindings)
                if idx_item is not None and idx_item != cat_item:
                    span = (smap.field_value_span(ds, de, "from") if smap else None) or decl_span
                    _emit(diags, "E-GENERIC-INCONSISTENT", file, span, decl,
                          f"catalog item type `{cat_item}` disagrees with index "
                          f"`{_last(dg)}` item type `{idx_item}`")

    if decl.kind == "fiber":
        # input/output are bound (I/O); where input references a stream and the
        # fiber also names an item schema, no further ground type is available in
        # the examples to contradict — so we only verify the references resolve to
        # a plausible kind (no false positives).  A mismatching `input` that
        # points at a non-stream/non-index source is left to conformance.
        pass


def _ref_dotted(vprop):
    if isinstance(vprop, dict) and "ref" in vprop and "args" not in vprop and "record" not in vprop:
        return vprop["ref"]
    return None


def _last(dotted):
    return dotted.split(".")[-1]


def _resolve_kind(dotted, by_name_kind):
    """If a dotted ref `<kind>.<name>` or bare `<name>` names an in-file decl,
    return that decl's kind; else None (external/built-in)."""
    parts = dotted.split(".")
    if len(parts) == 2 and parts[0] in P._KIND_SET:
        if (parts[0], parts[1]) in by_name_kind:
            return parts[0]
        return None
    if len(parts) == 1:
        for (k, nm) in by_name_kind:
            if nm == parts[0]:
                return k
    return None


def _item_schema_of(bindings):
    """The item-schema name a catalog/index declares via `schema = schema.X`."""
    s = bindings.get("schema")
    d = _ref_dotted(s)
    if d is not None:
        return _last(d)
    return None


# --------------------------------------------------------------------------- #
# Top-level: build registry, run all checks
# --------------------------------------------------------------------------- #

def load_builtins(builtins_path=None):
    """Parse the built-in catalog into (items, source, filename).  This is the
    checker's ONLY IO."""
    path = builtins_path or default_builtins_path()
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    items = parse_source(src, path)
    return items, src, path


def _collect_import_decls(items, filename, base_dir):
    """Resolve each ``use "<path>"`` import (one level, relative to ``base_dir``
    or the file's own directory) and return the ``(kind, name)`` set its
    top-level declarations bind into this file's scope (0011 §6.1 stage 2).

    This is the checker's only IO beyond the builtins catalog.  Unreadable
    imports are skipped (their names simply stay unbound); cycles are bounded by
    the one-level depth — `use` brings only the imported file's own top-level
    names into scope, not transitive ones."""
    base = base_dir if base_dir is not None else os.path.dirname(filename)
    out = set()
    for it in items:
        if isinstance(it, P.Import):
            path = os.path.normpath(os.path.join(base, it.path))
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    isrc = fh.read()
            except OSError:
                continue
            for sub in parse_source(isrc, path):
                if isinstance(sub, P.Decl):
                    out.add((sub.kind, sub.name))
    return out


def check_file(path, builtins_path=None, builtins_cache=None):
    """Read a ``.vaked`` file and return its sorted list of :class:`Diagnostic`."""
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    return check_source(src, path, builtins_path=builtins_path,
                        builtins_cache=builtins_cache,
                        base_dir=os.path.dirname(os.path.abspath(path)))


def check_source(src, filename, builtins_path=None, builtins_cache=None,
                 base_dir=None):
    """Check Vaked ``src`` and return a sorted list of :class:`Diagnostic`.

    ``builtins_cache`` may be a pre-parsed ``(items, src, filename)`` tuple from
    :func:`load_builtins` to avoid re-reading the catalog (keeps the function
    pure when the caller supplies the catalog).  ``base_dir`` is the directory
    `use` imports are resolved against (defaults to the file's own directory)."""
    if builtins_cache is None:
        builtins_cache = load_builtins(builtins_path)
    b_items, b_src, b_file = builtins_cache

    # Stage 3 — elaborate: assemble the schema/capability registry.
    registry = _Registry()
    _load_decls_into(registry, b_items, b_file)          # built-ins first

    items = parse_source(src, filename)
    _load_decls_into(registry, items, filename)          # user decls override

    # Stage 2 — bind `use` imports' top-level decls into this file's scope.
    imported_decls = _collect_import_decls(items, filename, base_dir)

    # Source maps for span resolution (built-ins + the file under check).
    smaps = {b_file: _SourceMap(b_src, b_file), filename: _SourceMap(src, filename)}

    def smap_for(f):
        return smaps.get(f)

    diags = []

    # Stage 4a — load-time well-formedness of EVERY schema, capability, and
    # namespace in scope (built-in + user).  Per 0011 §6.4a these are reported
    # against the decl.
    for spec in sorted(registry.schemas.values(), key=lambda s: (s.origin_file, s.name)):
        _check_schema_wellformed(spec, smap_for, diags)
    for spec in sorted(registry.caps.values(), key=lambda c: (c.origin_file, c.domain)):
        _check_capability_wellformed(spec, smap_for, diags)
    for spec in sorted(registry.namespaces.values(), key=lambda n: (n.origin_file, n.head)):
        _check_namespace_wellformed(spec, smap_for, diags)

    # Index in-file decls by (kind, name) for generics resolution.
    by_name_kind = {}
    for it in items:
        if isinstance(it, P.Decl):
            by_name_kind[(it.kind, it.name)] = it

    smap = smaps[filename]

    # Stage 4 (pre-walk) — top-level name collisions (#25).  LPG node ids are
    # path-derived and kind-agnostic, so two top-level decls sharing a name
    # collapse to one node (keep-first) and the later one silently vanishes from
    # the graph.  The checker sees both (it walks `items`, not the deduped
    # graph), so it is the right place to make the collision an explicit error
    # before `lower` runs on a lossy graph.
    _check_name_collisions(items, filename, smap, diags)

    # Stage 4b/4c/4d — walk every in-file declaration.  Top-level decls are
    # sibling-scope for top-level workflows (agent-target validation, #27).
    top_meshes = _mesh_node_index(items)
    top_kinds = _decl_kind_index(items)
    for it in items:
        if isinstance(it, P.Decl):
            _check_decl_tree(it, registry, by_name_kind, smap, filename, diags,
                             top_meshes, top_kinds)
            # Stage 2 (closed-world ref resolution) for each top-level runtime.
            if it.kind == "runtime":
                _check_ref_resolution(it, filename, diags, imported_decls, registry)

    diags.sort(key=lambda d: d.sort_key())
    return diags


# --------------------------------------------------------------------------- #
# Closed-world reference resolution (#7 — 0011 §6.1 stage 2)
# --------------------------------------------------------------------------- #
# 0011 §6.1 stage 2 mandates: every ref resolves to a declaration or a built-in;
# an unresolved ref is an error.  The sound, roster-free slice we enforce today:
# inside a `runtime {}` block (a closed world), a data-flow ref written in the
# `<kind>.<name>` addressing form (e.g. `input = stream.foo`) MUST name an
# in-runtime declaration of that kind.  There is no built-in `stream.X`/`index.X`
# /`fiber.X` — those kinds exist only as in-file decls — so a kind-qualified ref
# that resolves to nothing in the runtime is unambiguously dangling.
#
# Deliberately NOT enforced here (tracked as follow-ups on #7):
#   * bare-name refs (`engine = zigimg`, `fibers = [f]`) — entangled with
#     `use`-import binding, which the resolver does not yet implement;
#   * `<namespace>.<member>` refs whose head is not a kind keyword
#     (`pkgs.umami`, `web.analytics`, `artifacts.x`, `<daemon>.<channel>`) —
#     need a built-in value-namespace + daemon roster that does not exist yet
#     (the deferred "branch B").
# Bare top-level fragment decls (no enclosing runtime) are illustrative and not
# a closed world, so they are not enforced at all.

def _collect_runtime_decls(runtime_decl):
    """The set of ``(kind, name)`` declared anywhere within a runtime subtree."""
    found = set()

    def rec(decl):
        for st in decl.body:
            if isinstance(st, P.Decl):
                found.add((st.kind, st.name))
                rec(st)
    rec(runtime_decl)
    return found


# Data-flow fields whose bare refs name another declaration, plus the
# `parallel.fibers` member list — the ref-bearing positions closed-world
# resolution enforces.  (`_DEPENDS_FIELDS` is the resolver's data-flow set:
# engine/input/output/from/source.)
def _ref_fields():
    from .resolve import _DEPENDS_FIELDS
    # budget/runclass are resolution-enforced but are NOT data-flow edges
    # (adding them to _DEPENDS_FIELDS would mint wrong depends_on edges).
    return _DEPENDS_FIELDS | {"fibers", "budget", "runclass"}


def _walk_depends_refs(decl, out):
    """Collect ``(ref, field_name, owner_decl)`` for every bare ref appearing in a
    ref-bearing field within ``decl``'s subtree."""
    from .resolve import _refs_in_value
    fields = _ref_fields()
    for st in decl.body:
        if isinstance(st, P.Assignment) and st.target in fields:
            for r in _refs_in_value(st.value):
                out.append((r, st.target, decl))
        if isinstance(st, P.Decl):
            _walk_depends_refs(st, out)


# 3-part accessor refs (`<kind>.<name>.<field>`) that name a sibling decl and
# read one of its exposed values.  These appear INSIDE config-block records
# (`options { … = secret.X.path }`) and value lists (`environmentFiles =
# [secret.X.path]`), which the data-flow walk deliberately does not descend into
# — so they need their own collector.  (head, accessor-field) -> the kind the
# middle segment must name.
_ACCESSOR_REFS = {("secret", "path"): "secret", ("hostResource", "dsn"): "hostResource"}


def _walk_accessor_refs(decl, out):
    """Collect every 3-part accessor ref (``secret.X.path`` / ``hostResource.X.dsn``)
    anywhere in ``decl``'s subtree — including inside config-block records and
    value lists the data-flow walk does not reach."""
    def scan(value):
        if isinstance(value, P.App):
            if value.args is None and value.record is None and len(value.ref.parts) == 3:
                out.append(value.ref)
            if value.record is not None:
                for e in value.record:
                    if isinstance(e, P.Assignment):
                        scan(e.value)
            if value.args is not None:
                for a in value.args:
                    scan(a)
        elif isinstance(value, P.ListLit):
            for x in value.items:
                scan(x)
        elif isinstance(value, P.RecordLit):
            for e in value.entries:
                if isinstance(e, P.Assignment):
                    scan(e.value)
    for st in decl.body:
        if isinstance(st, P.Assignment):
            scan(st.value)
        elif isinstance(st, P.App):          # bare config block, e.g. options { … }
            scan(st)
        elif isinstance(st, P.Decl):
            _walk_accessor_refs(st, out)


def _collect_runtime_namespaces(runtime_decl):
    """Return a dict head -> NamespaceSpec for every ``namespace`` block declared
    directly inside the runtime (decision D3, RFC 0017: runtime-scoped authority).

    Only DIRECT children of the runtime are collected (namespace blocks nested
    inside fibers/meshes etc. are not supported in v1 and would be a checker error
    reported by ``_check_decl_tree`` when conformance runs against the ``fiber``
    schema's closed field set).

    The returned specs are built inline (not from the global registry) because they
    are scope-local: two runtimes in the same file can declare different namespace
    members for the same head."""
    local_ns = {}
    for st in runtime_decl.body:
        if isinstance(st, P.Decl) and st.kind == "namespace":
            is_open = any(isinstance(x, P.OpenDecl) for x in st.body)
            members = {x.name for x in st.body if isinstance(x, P.MemberDecl)}
            local_ns[st.name] = NamespaceSpec(
                head=st.name, open=is_open, members=members,
                origin_file="<runtime>", decl_span=(st.byteStart, st.byteEnd, st.line, st.col),
            )
    return local_ns


def _check_ref_resolution(runtime_decl, file, diags, imported=frozenset(),
                          registry=None):
    """Closed-world resolution for one runtime.  ``imported`` is the set of
    ``(kind, name)`` bound by the file's ``use`` imports.  ``registry`` is the
    :class:`_Registry` (needed for namespace resolution — branch B, RFC 0017).

    Branch B (non-kind dotted heads: ``pkgs.x``, ``agentGuardd.ringbuf``,
    ``artifacts.plan``) is now enforced (RFC 0017, decision D2 — hard error):

    * The namespace head is looked up in the *runtime-scoped* namespace roster
      (``namespace`` blocks declared inside this runtime, decision D3).  If the
      runtime has no inline namespace block for the head, the built-in namespace
      catalog (``registry.namespaces``) is consulted as a fallback — this covers
      open-value-namespaces like ``pkgs`` / ``nix`` that are global and not
      runtime-scoped.
    * If neither source knows the head → ``E-REF-UNRESOLVED`` (unknown namespace
      head — hard error per D2).
    * If the head resolves to an open namespace → accepted (any member).
    * If the head resolves to a closed namespace and the member is not in the
      declared set → ``E-REF-UNRESOLVED`` (unknown member, hard error per D2).

    ``artifacts.*`` / ``graph.*`` (decision D1) are closed-world refs to in-
    runtime productions, not external namespaces.  They are deliberately NOT in
    the namespace roster; reaching the unknown-head arm for these is the right
    signal when they are truly dangling.  (A follow-up can add dedicated
    closed-world checking for them; for now they surface as E-REF-UNRESOLVED
    when the head is neither a known namespace nor a capability domain.)"""
    declared = _collect_runtime_decls(runtime_decl) | set(imported)
    declared_names = {nm for (_k, nm) in declared}

    # Runtime-scoped namespace blocks (decision D3).
    runtime_ns = _collect_runtime_namespaces(runtime_decl)
    # Global namespace catalog (open namespaces like pkgs/nix and the built-in
    # daemon-channel roster from builtins.vaked).
    global_ns = registry.namespaces if registry is not None else {}
    # Capability domains are handled by the capability checker; exclude them
    # from branch-B so we don't double-report.
    cap_domains = set(registry.caps.keys()) if registry is not None else set()

    refs = []
    _walk_depends_refs(runtime_decl, refs)
    for ref, field, owner in refs:
        parts = ref.parts
        span = (ref.byteStart, ref.byteEnd, ref.line, ref.col)
        if len(parts) == 2 and parts[0] in P._KIND_SET:
            # `<kind>.<name>` — must name an in-runtime/imported decl of that kind.
            if (parts[0], parts[1]) not in declared:
                _emit(diags, "E-REF-UNRESOLVED", file, span, owner,
                      f"`{field}` references `{ref.dotted}` but no "
                      f"`{parts[0]} {parts[1]}` is declared in runtime "
                      f"`{runtime_decl.name}`")
        elif len(parts) == 1:
            # bare name — must name some in-runtime/imported decl.
            if parts[0] not in declared_names:
                _emit(diags, "E-REF-UNRESOLVED", file, span, owner,
                      f"`{field}` references `{ref.dotted}` but no declaration "
                      f"named `{parts[0]}` is in scope of runtime "
                      f"`{runtime_decl.name}`")
        elif len(parts) >= 2:
            # Branch B (RFC 0017, decision D2): non-kind dotted head.
            # Capability-domain refs (e.g. `fs.repo_rw`) are validated by the
            # capability checker; skip them here to avoid double-reporting.
            head = parts[0]
            member = parts[1]
            if head in cap_domains:
                continue   # capability checker owns these
            # Decision D1 (RFC 0017): `artifacts.*` / `graph.*` are closed-world
            # refs to in-runtime productions (fiber/step output, sub-graph).  Their
            # correct resolution requires a production registry that does not exist
            # in v1 — they are deferred to a follow-up.  Pass them silently here;
            # a future closed-world pass will validate them.
            if head in ("artifacts", "graph"):
                continue   # D1: deferred production-ref resolution
            # Lookup order: runtime-scoped namespace first (D3), then global catalog.
            # A runtime that declares `namespace <head> { … }` shadows the global
            # catalog for that head (more restrictive).  If neither has it, error.
            ns = runtime_ns.get(head) or global_ns.get(head)
            if ns is None:
                _emit(diags, "E-REF-UNRESOLVED", file, span, owner,
                      f"`{field}` references `{ref.dotted}` but `{head}` is not a "
                      f"declared namespace in runtime `{runtime_decl.name}` "
                      f"(add `namespace {head} {{ … }}` or declare it in builtins)")
            elif not ns.open and member not in ns.members:
                _emit(diags, "E-REF-UNRESOLVED", file, span, owner,
                      f"`{field}` references `{ref.dotted}` but `{member}` is not a "
                      f"declared member of namespace `{head}` "
                      f"(declared members: {sorted(ns.members)!r})")

    # 3-part accessor refs (`secret.X.path`, `hostResource.X.dsn`) — the middle
    # segment must name an in-runtime/imported decl of the head kind.  These live
    # inside config-block records / lists, so they get their own walk.  Dedup by
    # span (a ref reachable from both walks is reported once).
    accessor_refs = []
    _walk_accessor_refs(runtime_decl, accessor_refs)
    seen = set()
    for ref in accessor_refs:
        parts = ref.parts
        kind = _ACCESSOR_REFS.get((parts[0], parts[2]))
        if kind is None:
            continue
        key = (ref.byteStart, ref.byteEnd)
        if key in seen:
            continue
        seen.add(key)
        if (kind, parts[1]) not in declared:
            span = (ref.byteStart, ref.byteEnd, ref.line, ref.col)
            _emit(diags, "E-REF-UNRESOLVED", file, span, runtime_decl,
                  f"`{ref.dotted}` references `{kind} {parts[1]}` but no such "
                  f"declaration is in scope of runtime `{runtime_decl.name}`")


def _check_name_collisions(items, file, smap, diags):
    """Emit ``E-DECL-NAME-COLLISION`` for sibling decls that share a name (#25).

    Node ids are ``<filename>#<name-chain>`` with no kind (``graph.node_id``) and
    ``Graph.add_node`` is keep-first, so two decls in the SAME scope with the same
    name — most commonly different kinds, e.g. ``schema memory`` + ``capability
    memory`` — produce one node and the later decl is dropped from the graph with
    no diagnostic.  We flag every decl after the first that reuses a name in its
    scope, landing on its leading keyword and pointing back at the first via
    ``related``.

    Both scope levels are checked with the same kind-agnostic node-id semantics:

      * top-level decls (``<file>#<name>``), the original #25 case and the live
        workaround (``builtins.vaked`` naming a capability domain ``mem`` to dodge
        ``schema memory``);
      * nested siblings inside a decl body (``<file>#<parent>/<name>``) — the same
        collapse one level deeper (e.g. ``schema dup`` + ``capability dup`` inside
        one ``runtime``).  The resolver mints child ids from each body's ``P.Decl``
        siblings, so two of them sharing a name collide identically.
    """
    _check_scope_collisions(items, file, smap, diags, scope_kind="top-level")


def _check_scope_collisions(siblings, file, smap, diags, scope_kind):
    """Flag duplicate names among the ``P.Decl`` siblings of one scope, then recurse
    into each decl's body (its own nested sibling scope).

    ``scope_kind`` ("top-level" or "nested") only tunes the message wording; the
    node-id collapse and keep-first drop are identical at every depth, so the same
    ``E-DECL-NAME-COLLISION`` code is emitted throughout."""
    first_seen = {}     # name -> the first P.Decl declaring it in this scope
    for it in siblings:
        if not isinstance(it, P.Decl):
            continue
        prior = first_seen.get(it.name)
        if prior is None:
            first_seen[it.name] = it
        else:
            span = _span_of_decl_kw(smap, it) or (it.byteStart, it.byteEnd, it.line, it.col)
            related = [{
                "file": file,
                "decl": f"{prior.kind} {prior.name}",
                "span": {"byteStart": prior.byteStart, "byteEnd": prior.byteEnd,
                         "line": prior.line, "col": prior.col},
                "message": f"first declared here as `{prior.kind} {prior.name}`",
            }]
            kindnote = ("a different kind" if it.kind != prior.kind
                        else "the same kind")
            scopenote = ("top-level declarations" if scope_kind == "top-level"
                         else "sibling declarations")
            _emit(diags, "E-DECL-NAME-COLLISION", file, span, it,
                  f"`{it.kind} {it.name}` collides with `{prior.kind} {prior.name}` "
                  f"({kindnote}, same name): {scopenote} share a "
                  f"kind-agnostic graph id, so the later one is silently dropped — "
                  f"rename one", related=related)
        # Recurse into this decl's body — its own nested sibling scope.
        _check_scope_collisions(it.body, file, smap, diags, scope_kind="nested")


def _span_of_decl_kw(smap, decl):
    """Span of ``decl``'s leading keyword token (the ``<kind>`` ident), so the
    collision diagnostic lands on the offending declaration rather than its whole
    body.  Falls back to the decl's recorded span when the token is not found."""
    if smap is None:
        return None
    toks = smap._toks_in(decl.byteStart, decl.byteEnd)
    for t in toks:
        if t.kind == "IDENT" and t.value == decl.kind:
            return _span_of(t)
    return None


def _mesh_node_index(stmts):
    """{mesh decl name -> set of its node names} for the meshes in ``stmts``."""
    return {
        st.name: {nd.name for nd in st.body if isinstance(nd, P.NodeDecl)}
        for st in stmts
        if isinstance(st, P.Decl) and st.kind == "mesh"
    }


def _decl_kind_index(stmts):
    """{decl name -> kind} for every declaration in ``stmts``."""
    return {st.name: st.kind for st in stmts if isinstance(st, P.Decl)}


def _check_decl_tree(decl, registry, by_name_kind, smap, file, diags,
                     sibling_meshes=None, sibling_kinds=None):
    """Check ``decl`` and recurse into nested declarations / mesh nodes.

    ``sibling_meshes`` ({mesh -> node names}) and ``sibling_kinds``
    ({decl name -> kind}) index the block the decl sits in — the in-scope
    agent roster (and its shadowing decl names) for workflow agent-target
    validation."""
    kind = decl.kind

    # Conformance for kinds that have a schema (skip the meta-kinds themselves).
    if kind not in ("schema", "capability"):
        schema = registry.schemas.get(_KIND_SCHEMA.get(kind, kind))
        if schema is not None:
            _conform_decl(decl, schema, registry, smap, file, diags)
        _check_generics(decl, registry, by_name_kind, smap, file, diags)

    # Mesh: check each node body against meshNode, validate capability refs, and
    # enforce attenuation on delegation (`->`) edges.
    if kind == "mesh":
        _check_mesh(decl, registry, smap, file, diags)

    # Workflow (#27): check each step body against workflowStep, verify the
    # step `->` edges form a DAG, enforce a declared `maxDepth` bound, and
    # validate `agent` targets against sibling meshes.
    if kind == "workflow":
        _check_workflow(decl, registry, smap, file, diags, sibling_meshes,
                        sibling_kinds)

    # Recurse into nested declarations (e.g. a runtime's index/stream/fiber/…).
    # Meshes declared in THIS body are sibling-scope for nested workflows.
    child_meshes = _mesh_node_index(decl.body)
    child_kinds = _decl_kind_index(decl.body)
    for st in decl.body:
        if isinstance(st, P.Decl):
            _check_decl_tree(st, registry, by_name_kind, smap, file, diags,
                             child_meshes, child_kinds)


def _check_mesh(mesh_decl, registry, smap, file, diags):
    mesh_schema = registry.schemas.get("meshNode")
    node_grants = {}        # node name -> list[(domain, grant)]
    node_decls = {}
    ds, de, dl, dc = (mesh_decl.byteStart, mesh_decl.byteEnd, mesh_decl.line, mesh_decl.col)

    for st in mesh_decl.body:
        if isinstance(st, P.NodeDecl):
            node_decls[st.name] = st
            bindings, order = _node_bindings(st)
            nspan = (st.byteStart, st.byteEnd, st.line, st.col)
            # conform the node body against meshNode
            if mesh_schema is not None:
                _conform_node(st, mesh_schema, registry, smap, file, diags, nspan)
            # validate + collect capability grants
            grants = []
            caps = bindings.get("capabilities")
            if isinstance(caps, list):
                for e in caps:
                    dg = _grant_ref_parts(e)
                    if dg is None:
                        continue
                    dom, gr = dg
                    cspan = (smap.field_value_span(st.byteStart, st.byteEnd, "capabilities")
                             if smap else None) or nspan
                    if _check_capability_refs(dom, gr, registry, file, cspan, st, diags):
                        grants.append((dom, gr))
            node_grants[st.name] = grants

    # Attenuation on delegation edges (§4.4): for each `a -> b`, every grant the
    # receiver holds must be ≤ some grant the sender holds in the same domain.
    for st in mesh_decl.body:
        if isinstance(st, P.Edge):
            refs = st.refs
            for a_ref, b_ref in zip(refs, refs[1:]):
                sender = a_ref.parts[0] if len(a_ref.parts) == 1 else None
                receiver = b_ref.parts[0] if len(b_ref.parts) == 1 else None
                if sender not in node_grants or receiver not in node_grants:
                    continue   # an endpoint is external / unknown ⇒ no grant-set
                _check_edge_attenuation(
                    sender, receiver, node_grants[sender], node_grants[receiver],
                    a_ref, b_ref, registry, file, mesh_decl, diags)


def _check_workflow(wf_decl, registry, smap, file, diags, sibling_meshes=None,
                    sibling_kinds=None):
    """#27 / 0015: a `workflow` is a typed agent-step DAG.

    Mesh edges are capability *delegations* (attenuation, §4.4); workflow edges
    are step *ordering*. So: conform each `node` step body against the
    `workflowStep` schema, require the `->` edges among declared steps to form
    a DAG (E-WORKFLOW-CYCLE), and — when the record declares `maxDepth` — bound
    the longest step chain, counted in steps (E-WORKFLOW-DEPTH). Edges with an
    endpoint that is not a declared step are external and skipped, exactly like
    mesh edge handling. A step's `agent = <mesh>.<node>` ref whose head names a
    *sibling* mesh must name one of that mesh's nodes, and a head naming a
    sibling decl of any OTHER kind (which shadows external namespaces) cannot
    be an agent at all (both E-REF-UNRESOLVED); truly unknown heads stay
    unvalidated until the value-namespace roster (#8). Deterministic: steps in
    declaration order; at most one cycle diagnostic (the first cycle reached
    in that order)."""
    step_schema = registry.schemas.get("workflowStep")
    sibling_meshes = sibling_meshes or {}
    sibling_kinds = sibling_kinds or {}
    dspan = (wf_decl.byteStart, wf_decl.byteEnd, wf_decl.line, wf_decl.col)

    steps = []                      # declaration order
    for st in wf_decl.body:
        if isinstance(st, P.NodeDecl):
            steps.append(st.name)
            nspan = (st.byteStart, st.byteEnd, st.line, st.col)
            if step_schema is not None:
                _conform_node(st, step_schema, registry, smap, file, diags, nspan)
            bindings, _order = _node_bindings(st)
            ag = _grant_ref_parts(bindings.get("agent"))
            if ag is not None:
                head, member = ag
                bad = None
                if head in sibling_meshes:
                    if member not in sibling_meshes[head]:
                        bad = (f"step `{st.name}`: `agent = {head}.{member}` "
                               f"references mesh `{head}` but it declares no "
                               f"node `{member}`")
                elif head in sibling_kinds:
                    bad = (f"step `{st.name}`: `agent = {head}.{member}` "
                           f"references `{sibling_kinds[head]} {head}`, which "
                           f"is not a mesh — an agent must be a mesh node")
                if bad is not None:
                    span = (smap.field_value_span(st.byteStart, st.byteEnd,
                                                  "agent")
                            if smap else None) or nspan
                    _emit(diags, "E-REF-UNRESOLVED", file, span, wf_decl, bad)
    step_set = set(steps)

    succ = {s: [] for s in steps}
    for st in wf_decl.body:
        if isinstance(st, P.Edge):
            for a_ref, b_ref in zip(st.refs, st.refs[1:]):
                a = a_ref.parts[0] if len(a_ref.parts) == 1 else None
                b = b_ref.parts[0] if len(b_ref.parts) == 1 else None
                if a in step_set and b in step_set:
                    succ[a].append(b)

    # Cycle detection — iterative DFS with an explicit colour map.
    WHITE, GREY, BLACK = 0, 1, 2
    colour = {s: WHITE for s in steps}
    cycle = None
    for root in steps:
        if cycle is not None or colour[root] != WHITE:
            continue
        stack = [(root, iter(succ[root]))]
        colour[root] = GREY
        path = [root]
        while stack and cycle is None:
            node, it = stack[-1]
            advanced = False
            for nxt in it:
                if colour[nxt] == GREY:
                    cycle = path[path.index(nxt):] + [nxt]
                    break
                if colour[nxt] == WHITE:
                    colour[nxt] = GREY
                    path.append(nxt)
                    stack.append((nxt, iter(succ[nxt])))
                    advanced = True
                    break
            if not advanced and cycle is None:
                colour[node] = BLACK
                path.pop()
                stack.pop()
    if cycle is not None:
        _emit(diags, "E-WORKFLOW-CYCLE", file, dspan, wf_decl,
              f"workflow `{wf_decl.name}` step edges must form a DAG; cycle: "
              f"{' -> '.join(cycle)} (express revision loops as `retries` on a "
              f"step, not back-edges)")
        return   # depth is undefined on a cyclic graph

    # Longest chain, counted in steps (memoized over the verified DAG).
    depth_of = {}

    def _depth(s):
        if s not in depth_of:
            depth_of[s] = 1 + max((_depth(n) for n in succ[s]), default=0)
        return depth_of[s]

    depth = max((_depth(s) for s in steps), default=0)

    bindings, _order = _node_bindings(wf_decl)
    md = bindings.get("maxDepth")
    if isinstance(md, dict) and md.get("lit") == "number":
        try:
            bound = int(str(md["value"]))
        except ValueError:
            # Non-integer literal (`maxDepth = 2.5`): the Int constraint owns
            # the type error; the depth bound is simply not enforceable.
            bound = None
        if bound is not None and depth > bound:
            span = (smap.field_value_span(wf_decl.byteStart, wf_decl.byteEnd,
                                          "maxDepth") if smap else None) or dspan
            _emit(diags, "E-WORKFLOW-DEPTH", file, span, wf_decl,
                  f"workflow `{wf_decl.name}` has critical-path depth {depth}, "
                  f"exceeding the declared maxDepth = {bound}")


def _conform_node(node_decl, schema, registry, smap, file, diags, nspan):
    bindings, order = _node_bindings(node_decl)
    ns, ne, nl, nc = nspan
    for fname, f in schema.fields.items():
        if f.presence == "required" and fname not in bindings:
            _emit(diags, "E-CONFORM-MISSING-FIELD", file, nspan, f"node {node_decl.name}",
                  f"required field `{fname}` of schema `{schema.name}` is missing")
    if not schema.open:
        for fname in order:
            if fname not in schema.fields:
                span = (smap.field_name_span(ns, ne, fname) if smap else None) or nspan
                _emit(diags, "E-CONFORM-UNKNOWN-FIELD", file, span, f"node {node_decl.name}",
                      f"`{fname}` is not a declared field of closed schema "
                      f"`{schema.name}`")
    for fname, vprop in bindings.items():
        f = schema.fields.get(fname)
        if f is None:
            continue
        if not _value_matches_type(vprop, f.type_text, registry):
            span = (smap.field_value_span(ns, ne, fname) if smap else None) or nspan
            _emit(diags, "E-CONFORM-TYPE", file, span, f"node {node_decl.name}",
                  f"field `{fname}` of schema `{schema.name}` expects "
                  f"`{f.type_text}` but got {_render_vprop(vprop)}")
        _check_field_constraints(vprop, f, f"node {node_decl.name}", smap, file, diags, nspan)


def _check_edge_attenuation(sender, receiver, s_grants, r_grants, a_ref, b_ref,
                            registry, file, mesh_decl, diags):
    # span: the edge, from the sender ref start to the receiver ref end.
    edge_span = (a_ref.byteStart, b_ref.byteEnd, a_ref.line, a_ref.col)
    s_by_dom = {}
    for (dom, gr) in s_grants:
        s_by_dom.setdefault(dom, []).append(gr)
    for (dom, gr) in r_grants:
        cap = registry.caps.get(dom)
        if cap is None:
            continue   # unknown domain already reported
        sender_grants = s_by_dom.get(dom, [])
        # receiver grant gr must be <= some sender grant in this domain
        ok = any(_leq(cap, gr, sg) for sg in sender_grants)
        if not ok:
            held = ", ".join("%s.%s" % (dom, g) for g in sender_grants) or "(none)"
            _emit(diags, "E-CAP-ATTENUATION", file, edge_span, mesh_decl,
                  f"delegation `{sender} -> {receiver}` escalates authority: "
                  f"receiver holds `{dom}.{gr}` but sender holds {held} "
                  f"(receiver's grant must be ≤ the sender's in domain `{dom}`)")
