#!/usr/bin/env python3
"""lex_hcplang.py — tokenizer for the HCP schema/IDL language (.hcplang).

Produces a token stream consumed by ebnf.py's PEG interpreter against
protocol/hcplang/grammar.ebnf.

Lexical model (from that grammar's header + RFC 0002):
* `#` line comments run to end of line and are DISCARDED.
* `//` line comments are also discarded. NOTE: `///` is NOT a comment — it is a
  doc *annotation* and is RETAINED as a token. We therefore check for `///` (and
  `//`) before `#`-style handling, longest-prefix first.
* Doc annotations: `annotation = "///" { not_newline } newline`. The whole
  `/// ...\n` line is emitted as a single DOCANN token; the grammar's
  `annotation` rule is mapped to this one token (a lexical leaf rule). The
  trailing newline is part of the token.
* `@`-tags / attributes: `@` is an OP; `@redact`, `@3`, `@relic` are `@` followed
  by an ident or int. The grammar composes these (`attribute = "@" ident ...`,
  field tag `"@" int_literal`), so we just emit the `@` and the following
  IDENT / INT as separate tokens.
* Strings: JSON-style `"..."` with escapes; emitted as one STRING token.
* Identifiers: letter { letter | digit | "_" } — note NO '-' (unlike Vaked).
* Numbers: decimal and `0x` hex integers, and floats `d.d`. We emit INT for
  integer/hex literals and FLOAT for `digits "." digits` so the grammar's
  `int_literal` / `float_literal` map cleanly.
* Whitespace (space, tab, newline) is otherwise insignificant. We still emit a
  NEWLINE token (consumed by DOCANN assembly only); the parser skips stray
  NEWLINEs everywhere (no line-bound rules in this grammar).
* Punctuation used by the grammar: `{ } ( ) < > = , : ? @ . -` (a leading '-' on
  a negative number is folded into the INT/FLOAT literal; '-' is otherwise unused).
  The arrow `->` is a single OP. `///` doc-ann and `//` comment are handled above.
"""

from __future__ import annotations

from dataclasses import dataclass


class LexError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"{msg} at line {line}, col {col}")
        self.line = line
        self.col = col


@dataclass
class Token:
    kind: str
    value: str
    line: int
    col: int

    def matches_literal(self, text: str) -> bool:
        if self.kind in ("IDENT", "OP"):
            return text == self.value
        return False


_MULTI_OPS = ["->"]
_SINGLE_OPS = set("{}()<>=,:?@.")


def _is_letter(c: str) -> bool:
    return ("a" <= c <= "z") or ("A" <= c <= "Z")


def _is_digit(c: str) -> bool:
    return "0" <= c <= "9"


def _is_hexdigit(c: str) -> bool:
    return _is_digit(c) or ("a" <= c <= "f") or ("A" <= c <= "F")


def _is_ident_start(c: str) -> bool:
    return _is_letter(c)


def _is_ident_part(c: str) -> bool:
    return _is_letter(c) or _is_digit(c) or c == "_"


def tokenize(src: str, filename: str = "<hcplang>") -> "list[Token]":
    toks: list[Token] = []
    i = 0
    n = len(src)
    line = 1
    col = 1

    def advance(s: str):
        nonlocal line, col
        for ch in s:
            if ch == "\n":
                line += 1
                col = 1
            else:
                col += 1

    while i < n:
        c = src[i]
        tline, tcol = line, col

        # ---- whitespace --------------------------------------------------
        if c in " \t\r":
            advance(c)
            i += 1
            continue
        if c == "\n":
            advance(c)
            i += 1
            # NEWLINE tokens are insignificant to the parser (it skips them); they
            # exist so DOCANN assembly can include the terminating newline. We do
            # NOT emit them as separate tokens here — DOCANN already swallowed its
            # own newline below, and other newlines are simply dropped.
            continue

        # ---- doc annotation `///...` (RETAINED) and `//` comment ----------
        if c == "/" and src.startswith("///", i):
            j = i + 3
            while j < n and src[j] != "\n":
                j += 1
            # include the terminating newline (annotation = "///" {not_newline} newline)
            end = j + 1 if j < n else j
            value = src[i:end]
            advance(value)
            toks.append(Token("DOCANN", value, tline, tcol))
            i = end
            continue
        if c == "/" and src.startswith("//", i):
            j = i + 2
            while j < n and src[j] != "\n":
                j += 1
            advance(src[i:j])
            i = j
            continue

        # ---- '#' line comment (discarded) --------------------------------
        if c == "#":
            j = i
            while j < n and src[j] != "\n":
                j += 1
            advance(src[i:j])
            i = j
            continue

        # ---- string ------------------------------------------------------
        if c == '"':
            j = i + 1
            buf = ['"']
            while j < n:
                ch = src[j]
                if ch == "\\":
                    if j + 1 >= n:
                        raise LexError("unterminated escape in string", tline, tcol)
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if ch == '"':
                    buf.append('"')
                    j += 1
                    break
                if ch == "\n":
                    raise LexError("unterminated string (newline)", tline, tcol)
                buf.append(ch)
                j += 1
            else:
                raise LexError("unterminated string", tline, tcol)
            value = "".join(buf)
            advance(src[i:j])
            toks.append(Token("STRING", value, tline, tcol))
            i = j
            continue

        # ---- multi-char operators ('->') ---------------------------------
        matched = None
        for op in _MULTI_OPS:
            if src.startswith(op, i):
                matched = op
                break
        if matched:
            advance(matched)
            toks.append(Token("OP", matched, tline, tcol))
            i += len(matched)
            continue

        # ---- single-char operators ---------------------------------------
        if c in _SINGLE_OPS:
            advance(c)
            toks.append(Token("OP", c, tline, tcol))
            i += 1
            continue

        # ---- numbers (hex / int / float, optional leading '-') -----------
        if _is_digit(c) or (c == "-" and i + 1 < n and _is_digit(src[i + 1])):
            j = i
            if src[j] == "-":
                j += 1
            if src.startswith("0x", j) or src.startswith("0X", j):
                j += 2
                start = j
                while j < n and _is_hexdigit(src[j]):
                    j += 1
                if j == start:
                    raise LexError("malformed hex literal", tline, tcol)
                value = src[i:j]
                advance(value)
                toks.append(Token("INT", value, tline, tcol))
                i = j
                continue
            while j < n and _is_digit(src[j]):
                j += 1
            is_float = False
            if j < n and src[j] == "." and j + 1 < n and _is_digit(src[j + 1]):
                is_float = True
                j += 1
                while j < n and _is_digit(src[j]):
                    j += 1
            value = src[i:j]
            advance(value)
            toks.append(Token("FLOAT" if is_float else "INT", value, tline, tcol))
            i = j
            continue

        # ---- identifiers --------------------------------------------------
        if _is_ident_start(c):
            j = i
            while j < n and _is_ident_part(src[j]):
                j += 1
            value = src[i:j]
            advance(value)
            toks.append(Token("IDENT", value, tline, tcol))
            i = j
            continue

        raise LexError(f"unexpected character {c!r}", tline, tcol)

    toks.append(Token("EOF", "<eof>", line, col))
    return toks


# --------------------------------------------------------------------------- #
# Grammar terminal mapping (documented lexer/grammar boundary).
#
#   Grammar terminal                  -> token predicate
#   --------------------------------     -----------------------------------
#   string        = '"' {string_char} '"'  -> STRING token
#   int_literal   = [-]d{d} | 0x h{h}       -> INT token
#   float_literal = [-]d{d} "." d{d}        -> FLOAT token
#   ident         = letter{letter|digit|_}  -> IDENT token
#   annotation    = "///" {not_newline} nl  -> DOCANN token (assembled by lexer)
#
# The char-level rules letter/digit/hexdigit/string_char/not_newline/newline are
# subsumed by the whole-token rules above (the lexer consumed those chars). When
# referenced as Refs in a reachable production they resolve via TERMINAL_MAP.
# `string_char` is the only dead rule in this grammar (see test_grammar_selfcontained).
# --------------------------------------------------------------------------- #

def _kind(*kinds):
    s = set(kinds)
    return lambda tok: tok.kind in s


# This grammar uses no ``? prose ?`` terminals in reachable structural rules
# (its char classes are written as `"a" | "..." | "z"` enumerations and as the two
# ?prose? lexical rules `newline` / `not_newline`, both subsumed by tokens).
PROSE_MAP = {
    # newline = ? U+000A line feed ?
    "u 000a line feed": _kind("DOCANN"),  # only reached inside annotation (a token)
    # not_newline = ? any Unicode scalar value except newline ?
    "any unicode scalar value except newline": _kind("DOCANN"),
}

TERMINAL_MAP = {
    "string": _kind("STRING"),
    "int_literal": _kind("INT"),
    "float_literal": _kind("FLOAT"),
    "ident": _kind("IDENT"),
    "annotation": _kind("DOCANN"),
    # char-class leaves (subsumed; map to their whole-token kind if ever reached)
    "letter": _kind("IDENT"),
    "digit": _kind("INT"),
    "hexdigit": _kind("INT"),
    "string_char": _kind("STRING"),
    "newline": _kind("DOCANN"),
    "not_newline": _kind("DOCANN"),
}

# Rule names realized as single tokens (matched atomically, not expanded).
TERMINAL_RULES = {
    "string", "int_literal", "float_literal", "ident", "annotation",
    "letter", "digit", "hexdigit", "string_char", "newline", "not_newline",
}
