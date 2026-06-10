#!/usr/bin/env python3
"""ebnf.py — a small EBNF loader + PEG interpreter for the Vaked monorepo specs.

This module reads the repo's own `.ebnf` grammar notation FROM DISK and interprets
it as a PEG (Parsing Expression Grammar) with ordered choice and full backtracking
over a *token* stream produced by a language-specific lexer (lex_vaked / lex_hcplang).

Why PEG / ordered-choice
------------------------
The grammar headers state: ``x | y`` is alternation, "ordered: first match wins in
ambiguous positions". That is precisely PEG semantics, so we interpret every rule as
a parsing expression and resolve ``|`` by trying alternatives left-to-right and taking
the first that succeeds (with backtracking on failure). Repetition ``{ x }`` and option
``[ x ]`` are greedy, as in a PEG.

Notation supported (matches both vaked/grammar/*.ebnf and protocol/hcplang/grammar.ebnf)
----------------------------------------------------------------------------------------
    rule = expr ;          one production, ';'-terminated
    "literal"              a verbatim terminal (double-quoted)
    'literal'              a verbatim terminal (single-quoted; e.g. the EBNF token '"')
    { x }                  zero or more repetitions
    [ x ]                  optional (zero or one)
    x | y                  ordered alternation (first match wins)
    ( x )                  grouping
    ? prose ?              a "prose terminal": opaque English describing a token class.
                           These are mapped onto concrete lexer token kinds by the
                           per-language PROSE_MAP passed to ``Grammar.parse`` (the
                           lexer-level mapping is documented in each lexer module and
                           in tests/spec/README.md).
    name                   a reference to another rule, OR — when not a defined rule —
                           a *named terminal* resolved through PROSE_MAP / TERMINAL_MAP.

Terminals vs tokens
-------------------
A grammar literal like ``"field"`` or ``":"`` is matched against a *token* emitted by
the lexer, not against raw source characters. The interpreter matches a literal by
asking the lexer's token whether it equals that literal (``Token.matches_literal``).
Prose terminals and a handful of character-class rules (letter/digit/char/...) are
matched by *kind* via PROSE_MAP. This keeps the recognizer driven by the on-disk
grammar while letting the lexer own the messy lexical details (string interpolation,
durations, regex literals, newline suppression, etc.).

The interpreter is intentionally small and dependency-free (Python 3 stdlib only).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple


# --------------------------------------------------------------------------- #
# Grammar expression AST
# --------------------------------------------------------------------------- #

class Expr:
    """Base class for parsing expressions."""
    __slots__ = ()


@dataclass
class Lit(Expr):
    """A verbatim terminal, e.g. "field" or ":" (the quotes are stripped)."""
    text: str


@dataclass
class Ref(Expr):
    """A reference to another rule, or a named terminal resolved via maps."""
    name: str


@dataclass
class Prose(Expr):
    """A ``? prose ?`` terminal, identified by its (normalized) prose key."""
    key: str
    raw: str


@dataclass
class Seq(Expr):
    items: List[Expr]


@dataclass
class Alt(Expr):
    """Ordered choice: try options left-to-right, first success wins."""
    options: List[Expr]


@dataclass
class Many(Expr):
    """``{ x }`` — zero or more (greedy)."""
    inner: Expr


@dataclass
class Opt(Expr):
    """``[ x ]`` — optional (greedy)."""
    inner: Expr


# --------------------------------------------------------------------------- #
# Grammar file loader
# --------------------------------------------------------------------------- #

def _strip_comment_lines(raw: str) -> str:
    """Drop full-line comments (optional leading whitespace then '#').

    Inline '#' after a rule is never used in these grammars (and '#' only appears
    inside RHS as the *literal* "#" in vaked's `comment` rule, which is quoted),
    so dropping only full-line '#' comments is safe.
    """
    out = []
    for line in raw.splitlines():
        if line.lstrip().startswith("#"):
            continue
        out.append(line)
    return "\n".join(out)


# Tokens of the EBNF metasyntax itself.
_METATOKEN_RE = re.compile(
    r"""
      \s+                                  # whitespace (skipped)
    | "(?:[^"\\]|\\.)*"                     # double-quoted literal
    | '(?:[^'\\]|\\.)*'                     # single-quoted literal (e.g. '"')
    | \?[^?]*\?                             # ?prose? terminal
    | [A-Za-z_][A-Za-z0-9_]*                # identifier (rule ref / named terminal)
    | [{}\[\]()|;=]                         # structural metacharacters
    """,
    re.VERBOSE,
)


def _normalize_prose(raw: str) -> str:
    """Reduce a ``? ... ?`` body to a stable key for PROSE_MAP lookup."""
    inner = raw.strip("?").strip()
    # Take the first few significant words, lowercased, punctuation removed — enough
    # to key the small fixed set of prose terminals these grammars use.
    inner = inner.lower()
    inner = re.sub(r"[^a-z0-9 ]+", " ", inner)
    inner = re.sub(r"\s+", " ", inner).strip()
    return inner


@dataclass
class Grammar:
    """A loaded grammar: ordered rule table + the source path it came from."""
    path: str
    rules: "Dict[str, Expr]" = field(default_factory=dict)
    order: List[str] = field(default_factory=list)
    start: str = ""

    # --- loading --------------------------------------------------------- #

    @classmethod
    def load(cls, path: str, start: str) -> "Grammar":
        raw = open(path, "r", encoding="utf-8").read()
        text = _strip_comment_lines(raw)
        toks = [m.group(0) for m in _METATOKEN_RE.finditer(text) if m.group(0).strip()]
        g = cls(path=path, start=start)
        i = 0
        n = len(toks)
        while i < n:
            # Expect: NAME '=' ... ';'
            name = toks[i]
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
                raise SyntaxError(f"{path}: expected rule name, got {name!r}")
            if i + 1 >= n or toks[i + 1] != "=":
                raise SyntaxError(f"{path}: expected '=' after rule {name!r}")
            # collect rhs tokens up to the terminating ';'
            j = i + 2
            rhs: List[str] = []
            while j < n and toks[j] != ";":
                rhs.append(toks[j])
                j += 1
            if j >= n:
                raise SyntaxError(f"{path}: rule {name!r} not ';'-terminated")
            expr, pos = cls._parse_alt(rhs, 0)
            if pos != len(rhs):
                raise SyntaxError(
                    f"{path}: trailing tokens in rule {name!r}: {rhs[pos:]!r}"
                )
            if name not in g.rules:
                g.order.append(name)
            g.rules[name] = expr
            i = j + 1  # skip ';'
        if start not in g.rules:
            raise SyntaxError(f"{path}: start symbol {start!r} is not defined")
        return g

    # --- RHS expression parser (recursive descent over metatokens) ------- #

    @staticmethod
    def _mk_terminal(tok: str) -> Expr:
        if tok[0] in "\"'":
            # strip the surrounding quote and unescape EBNF-style backslash escapes
            body = tok[1:-1]
            body = body.replace("\\\\", "\\").replace('\\"', '"').replace("\\'", "'")
            body = body.replace("\\/", "/")
            return Lit(body)
        if tok.startswith("?"):
            return Prose(key=_normalize_prose(tok), raw=tok)
        return Ref(tok)

    @classmethod
    def _parse_alt(cls, toks: List[str], pos: int) -> Tuple[Expr, int]:
        options = []
        expr, pos = cls._parse_seq(toks, pos)
        options.append(expr)
        while pos < len(toks) and toks[pos] == "|":
            expr, pos = cls._parse_seq(toks, pos + 1)
            options.append(expr)
        if len(options) == 1:
            return options[0], pos
        return Alt(options), pos

    @classmethod
    def _parse_seq(cls, toks: List[str], pos: int) -> Tuple[Expr, int]:
        items = []
        while pos < len(toks) and toks[pos] not in ("|", ")", "]", "}"):
            item, pos = cls._parse_unit(toks, pos)
            items.append(item)
        if len(items) == 1:
            return items[0], pos
        return Seq(items), pos

    @classmethod
    def _parse_unit(cls, toks: List[str], pos: int) -> Tuple[Expr, int]:
        tok = toks[pos]
        if tok == "(":
            inner, pos = cls._parse_alt(toks, pos + 1)
            if pos >= len(toks) or toks[pos] != ")":
                raise SyntaxError(f"unbalanced '(' near {toks[pos:pos+3]!r}")
            return inner, pos + 1
        if tok == "{":
            inner, pos = cls._parse_alt(toks, pos + 1)
            if pos >= len(toks) or toks[pos] != "}":
                raise SyntaxError(f"unbalanced '{{' near {toks[pos:pos+3]!r}")
            return Many(inner), pos + 1
        if tok == "[":
            inner, pos = cls._parse_alt(toks, pos + 1)
            if pos >= len(toks) or toks[pos] != "]":
                raise SyntaxError(f"unbalanced '[' near {toks[pos:pos+3]!r}")
            return Opt(inner), pos + 1
        return cls._mk_terminal(tok), pos + 1

    # --- analysis: referenced nonterminals & dead rules ------------------ #

    def referenced(self) -> "Dict[str, set]":
        """Map each rule -> set of OTHER defined rule names it references."""
        out: Dict[str, set] = {}
        defined = set(self.rules)
        for name, expr in self.rules.items():
            seen: set = set()
            self._collect_refs(expr, seen)
            out[name] = {r for r in seen if r in defined}
        return out

    def undefined_refs(self, terminal_names: set) -> "Dict[str, set]":
        """Map each rule -> set of Ref names that are neither a defined rule nor a
        known terminal (i.e. would be an undefined nonterminal in the grammar)."""
        out: Dict[str, set] = {}
        defined = set(self.rules)
        for name, expr in self.rules.items():
            seen: set = set()
            self._collect_refs(expr, seen)
            missing = {r for r in seen if r not in defined and r not in terminal_names}
            if missing:
                out[name] = missing
        return out

    def reachable(self) -> set:
        refs = self.referenced()
        reach = {self.start}
        stack = [self.start]
        while stack:
            cur = stack.pop()
            for r in refs.get(cur, ()):  # only defined rules are in refs values
                if r not in reach:
                    reach.add(r)
                    stack.append(r)
        return reach

    def dead_rules(self) -> set:
        return set(self.rules) - self.reachable()

    @classmethod
    def _collect_refs(cls, expr: Expr, out: set) -> None:
        if isinstance(expr, Ref):
            out.add(expr.name)
        elif isinstance(expr, (Many, Opt)):
            cls._collect_refs(expr.inner, out)
        elif isinstance(expr, Seq):
            for it in expr.items:
                cls._collect_refs(it, out)
        elif isinstance(expr, Alt):
            for it in expr.options:
                cls._collect_refs(it, out)
        # Lit / Prose: nothing

    # --- parsing a token stream ------------------------------------------ #

    def parse(self, tokens, prose_map: "Dict[str, Callable]",
              terminal_map: "Optional[Dict[str, Callable]]" = None,
              terminal_rules: "Optional[set]" = None,
              line_bound_rules: "Optional[set]" = None,
              newline_kind: str = "NEWLINE",
              sep_literals=(";",)):
        """Parse ``tokens`` against this grammar starting at ``self.start``.

        Returns a ``ParseResult``. ``tokens`` is the list produced by a lexer; each
        token must support ``.matches_literal(text) -> bool``, ``.kind``, ``.value``,
        ``.line``, ``.col``.

        ``prose_map`` maps a normalized prose key (see ``_normalize_prose``) to a
        predicate ``token -> bool``. ``terminal_map`` (optional) maps a Ref *name*
        to a predicate ``token -> bool`` (used for character-class rules the lexer
        collapses into single tokens). Any Ref that is neither a defined rule nor in
        ``terminal_map`` is a grammar error.

        ``terminal_rules`` (optional) is a set of rule names that are realized by the
        lexer as single tokens and must therefore be matched ATOMICALLY through
        ``terminal_map`` rather than expanded character-by-character — e.g. ``string``,
        ``number``, ``ident``, ``path``, ``duration``, ``bytes``, ``regex``. This is
        the documented lexer/grammar boundary: structural productions are interpreted
        straight from the on-disk grammar; only these lexical leaf rules are mapped.
        """
        interp = _Interp(self, tokens, prose_map, terminal_map or {},
                         terminal_rules or set(),
                         line_bound_rules=line_bound_rules,
                         newline_kind=newline_kind, sep_literals=sep_literals)
        ok, end = interp.run()
        return ParseResult(ok=ok, pos=end, interp=interp, tokens=tokens,
                           newline_kind=newline_kind)


@dataclass
class ParseResult:
    ok: bool
    pos: int
    interp: "_Interp"
    tokens: list
    newline_kind: str = "NEWLINE"

    @property
    def consumed_all(self) -> bool:
        # Success requires reaching the EOF sentinel, skipping any trailing
        # insignificant NEWLINE tokens between the parse end and EOF.
        if not self.ok:
            return False
        p = self.pos
        while p < len(self.tokens) and self.tokens[p].kind == self.newline_kind:
            p += 1
        return p >= len(self.tokens) - 1

    def failure_location(self):
        """Return (line, col, near_value) of the furthest token the parser reached
        before failing, which is the most useful place to point at."""
        t = self.interp.furthest_token()
        if t is None:
            return (1, 1, "<start>")
        return (t.line, t.col, t.value)


# --------------------------------------------------------------------------- #
# PEG interpreter over a token stream
# --------------------------------------------------------------------------- #

class _Interp:
    """Backtracking PEG interpreter with packrat memoization.

    Memoization (rule, pos) -> (ok, endpos) makes the recognizer linear-ish and
    immune to pathological backtracking; it does not change which strings are
    accepted (PEG is unaffected by memoization).
    """

    def __init__(self, grammar: Grammar, tokens, prose_map, terminal_map,
                 terminal_rules, line_bound_rules=None, newline_kind="NEWLINE",
                 sep_literals=(";",)):
        self.g = grammar
        self.tokens = tokens
        self.prose_map = prose_map
        self.terminal_map = terminal_map
        self.terminal_rules = terminal_rules
        # Rules within which NEWLINE is significant (it terminates a line-bounded
        # `{ ident }` / chain repetition, per the grammar's whitespace rule). While
        # active, terminal matchers do NOT skip NEWLINE. Everywhere else NEWLINE is
        # insignificant whitespace between statements/entries and is skipped.
        self.line_bound_rules = set(line_bound_rules or ())
        self.newline_kind = newline_kind
        # Explicit separators (e.g. ";") that continue a statement across a newline:
        # after matching one, trailing NEWLINEs are skipped even inside a line-bound
        # rule (so a `;`-separated `order` chain may wrap to the next line).
        self.sep_literals = set(sep_literals)
        self._line_bound_depth = 0
        self.memo: Dict[Tuple[str, int, int], Tuple[bool, int]] = {}
        self._furthest = 0  # furthest token index the parser *attempted* to match

    def furthest_token(self):
        idx = min(self._furthest, len(self.tokens) - 1)
        return self.tokens[idx] if self.tokens else None

    def run(self) -> Tuple[bool, int]:
        return self._rule(self.g.start, 0)

    # --- core dispatch --------------------------------------------------- #

    def _rule(self, name: str, pos: int) -> Tuple[bool, int]:
        line_bound = name in self.line_bound_rules
        if line_bound:
            # The NEWLINE that terminated the PREVIOUS statement precedes this rule's
            # first token; it belongs to that statement, not this one. Skip leading
            # NEWLINEs (while still outside line-bound mode) before the rule's own
            # tokens become NEWLINE-significant.
            pos = self._skip_ws(pos)
        # memo key includes line-bound depth: the same (rule,pos) can match
        # differently depending on whether NEWLINE is currently significant.
        key = (name, pos, self._line_bound_depth + (1 if line_bound else 0))
        cached = self.memo.get(key)
        if cached is not None:
            return cached
        # guard against left recursion turning into infinite loops: seed as failure.
        self.memo[key] = (False, pos)
        if line_bound:
            self._line_bound_depth += 1
        try:
            ok, end = self._eval(self.g.rules[name], pos)
        finally:
            if line_bound:
                self._line_bound_depth -= 1
        self.memo[key] = (ok, end)
        return ok, end

    def _eval(self, expr: Expr, pos: int) -> Tuple[bool, int]:
        if isinstance(expr, Lit):
            return self._match_lit(expr.text, pos)
        if isinstance(expr, Prose):
            return self._match_prose(expr, pos)
        if isinstance(expr, Ref):
            return self._match_ref(expr.name, pos)
        if isinstance(expr, Seq):
            cur = pos
            for it in expr.items:
                ok, cur = self._eval(it, cur)
                if not ok:
                    return False, pos
            return True, cur
        if isinstance(expr, Alt):
            for opt in expr.options:
                ok, end = self._eval(opt, pos)
                if ok:
                    return True, end
            return False, pos
        if isinstance(expr, Many):
            cur = pos
            while True:
                ok, nxt = self._eval(expr.inner, cur)
                if not ok or nxt == cur:  # no progress -> stop (avoids infinite loop)
                    break
                cur = nxt
            return True, cur
        if isinstance(expr, Opt):
            ok, end = self._eval(expr.inner, pos)
            return (True, end) if ok else (True, pos)
        raise TypeError(f"unknown expr node {expr!r}")

    # --- terminal matchers ----------------------------------------------- #

    def _peek(self, pos: int):
        if pos > self._furthest:
            self._furthest = pos
        if pos < len(self.tokens):
            return self.tokens[pos]
        return None

    def _skip_ws(self, pos: int) -> int:
        """Advance past NEWLINE tokens that are currently insignificant.

        NEWLINE is significant (NOT skipped) only while inside a line-bound rule —
        there it terminates the `{ ident }` / chain repetition. Otherwise NEWLINE is
        whitespace between statements/entries and is skipped before matching a
        terminal. EOF is never skipped.
        """
        if self._line_bound_depth > 0:
            return pos
        while pos < len(self.tokens) and self.tokens[pos].kind == self.newline_kind:
            pos += 1
        return pos

    def _match_lit(self, text: str, pos: int) -> Tuple[bool, int]:
        pos = self._skip_ws(pos)
        tok = self._peek(pos)
        if tok is not None and tok.matches_literal(text):
            end = pos + 1
            # An explicit separator continues a statement across newlines: after it,
            # skip trailing NEWLINEs even inside a line-bound rule (so a ';'-separated
            # `order` chain may wrap to the next line — see the v0.3 examples).
            if text in self.sep_literals:
                while end < len(self.tokens) and \
                        self.tokens[end].kind == self.newline_kind:
                    end += 1
            return True, end
        return False, pos

    def _match_prose(self, expr: Prose, pos: int) -> Tuple[bool, int]:
        pred = self.prose_map.get(expr.key)
        if pred is None:
            raise KeyError(
                f"{self.g.path}: no PROSE_MAP entry for prose terminal "
                f"{expr.raw!r} (key={expr.key!r})"
            )
        pos = self._skip_ws(pos)
        tok = self._peek(pos)
        if tok is not None and pred(tok):
            return True, pos + 1
        return False, pos

    def _match_ref(self, name: str, pos: int) -> Tuple[bool, int]:
        # Lexical leaf rules realized as single tokens are matched atomically via
        # terminal_map, even though they are defined in the grammar (the lexer
        # already consumed their characters). This is the documented boundary.
        if name in self.terminal_rules:
            pred = self.terminal_map.get(name)
            if pred is None:
                raise KeyError(
                    f"{self.g.path}: terminal rule {name!r} has no TERMINAL_MAP entry"
                )
            p = self._skip_ws(pos)
            tok = self._peek(p)
            if tok is not None and pred(tok):
                return True, p + 1
            return False, pos
        if name in self.g.rules:
            return self._rule(name, pos)
        pred = self.terminal_map.get(name)
        if pred is None:
            raise KeyError(
                f"{self.g.path}: reference {name!r} is neither a defined rule "
                f"nor a known terminal (TERMINAL_MAP)"
            )
        p = self._skip_ws(pos)
        tok = self._peek(p)
        if tok is not None and pred(tok):
            return True, p + 1
        return False, pos
