#!/usr/bin/env python3
"""parse_support.py — shared wiring that binds the on-disk grammars to the lexers.

Centralizes the (grammar, lexer, terminal-rule, line-bound) configuration so the
test modules and run_all share one definition of "parse a .vaked / .hcplang file".
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ebnf  # noqa: E402
import lex_vaked  # noqa: E402
import lex_hcplang  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VAKED_GRAMMAR = os.path.join(REPO, "vaked", "grammar", "vaked-v0-plus.ebnf")
HCP_GRAMMAR = os.path.join(REPO, "protocol", "hcplang", "grammar.ebnf")

# Vaked lexical leaf rules realized as single tokens (matched atomically).
VAKED_TERMINAL_RULES = {
    "string", "number", "path", "duration", "bytes", "regex", "ident",
    "letter", "digit", "char", "path_char", "regex_char", "any", "eol", "interp",
}
# Rules within which a NEWLINE terminates the statement (grammar whitespace rule:
# `{ ident }` repetitions in inherit/grant, and `order` chains, are line-bounded).
VAKED_LINE_BOUND = {"inherit_stmt", "grant_decl", "order_decl"}


class ParseOutcome:
    def __init__(self, ok, line=None, col=None, near=None, error=None):
        self.ok = ok
        self.line = line
        self.col = col
        self.near = near
        self.error = error  # lexer/loader exception text, if any

    def location(self):
        if self.error:
            return self.error
        return f"line {self.line}, col {self.col} near {self.near!r}"


_vaked_grammar = None
_hcp_grammar = None


def vaked_grammar():
    global _vaked_grammar
    if _vaked_grammar is None:
        _vaked_grammar = ebnf.Grammar.load(VAKED_GRAMMAR, start="file")
    return _vaked_grammar


def hcp_grammar():
    global _hcp_grammar
    if _hcp_grammar is None:
        _hcp_grammar = ebnf.Grammar.load(HCP_GRAMMAR, start="schema")
    return _hcp_grammar


def parse_vaked(src, filename="<vaked>"):
    g = vaked_grammar()
    try:
        toks = lex_vaked.tokenize(src, filename)
    except lex_vaked.LexError as e:
        return ParseOutcome(False, error=f"lex error: {e}")
    res = g.parse(toks, lex_vaked.PROSE_MAP, lex_vaked.TERMINAL_MAP,
                  terminal_rules=VAKED_TERMINAL_RULES,
                  line_bound_rules=VAKED_LINE_BOUND)
    if res.consumed_all:
        return ParseOutcome(True)
    line, col, near = res.failure_location()
    return ParseOutcome(False, line=line, col=col, near=near)


def parse_hcplang(src, filename="<hcplang>"):
    g = hcp_grammar()
    try:
        toks = lex_hcplang.tokenize(src, filename)
    except lex_hcplang.LexError as e:
        return ParseOutcome(False, error=f"lex error: {e}")
    res = g.parse(toks, lex_hcplang.PROSE_MAP, lex_hcplang.TERMINAL_MAP,
                  terminal_rules=lex_hcplang.TERMINAL_RULES,
                  line_bound_rules=set())
    if res.consumed_all:
        return ParseOutcome(True)
    line, col, near = res.failure_location()
    return ParseOutcome(False, line=line, col=col, near=near)
