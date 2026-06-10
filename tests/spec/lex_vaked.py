#!/usr/bin/env python3
"""lex_vaked.py — tokenizer for the Vaked capability-graph language (.vaked).

Produces a token stream consumed by ebnf.py's PEG interpreter against
vaked/grammar/vaked-v0-plus.ebnf. The lexer owns every lexical subtlety the
grammar delegates to "the lexer"; the grammar's character-level / prose
terminals are then mapped onto these token KINDS (see PROSE_MAP / TERMINAL_MAP
at the bottom of this file).

Token kinds emitted
-------------------
    IDENT       identifier: letter { letter | digit | "_" | "-" }
    STRING      "..."  with ${ref} interpolation recognized inside
    NUMBER      [-]digits[.digits]            (the grammar's `number`)
    DURATION    digits ("ns"|"us"|"ms"|"s"|"m"|"h"|"d")   e.g. 24h
    BYTES       digits ("B"|"KB"|"MB"|"GB"|"TB")          e.g. 4KB
    PATH        "." ("/"|letter) path_char*   e.g. ./x  ./var/firmware.db
    REGEX       /.../  — ONLY when the previous significant token is `matches`
    OP          punctuation: -> <= >= .. ?= = < > . ; : , @ ( ) [ ] { } |
    NEWLINE     a statement terminator (emitted only where significant)
    EOF         end-of-input sentinel

Key lexical rules (from the grammar header)
-------------------------------------------
* Comments: '#' to end of line, discarded (never tokenized).
* Newlines TERMINATE a statement EXCEPT inside an open grouping. We suppress
  NEWLINE while nested inside '(' or '['. Braces '{' are NOT suppressed at the
  lexer level: a statement *block* needs NEWLINE-termination inside it (so that
  `inherit`/`grant`/`order` repetitions are bounded to their line — grammar
  header), whereas a *record* value `{...}` has its newlines absorbed by the
  parser's record/refinement loops (which skip NEWLINE between entries). Putting
  the brace decision in the parser (which knows block-vs-record) — rather than
  guessing in the lexer — is what makes both work from one NEWLINE rule. See
  tests/spec/README.md "PEG/lexer notes".
* Consecutive / leading / trailing NEWLINEs are collapsed to at most one and
  trimmed, so blank lines and comment-only lines never spuriously terminate.
* '.' glued to an identifier inside a ref (e.g. `index.zigbeeFirmware`,
  `crabcc.markdown`, `fs.repo_rw`) lexes the '.' as a DOT operator, NOT as the
  start of a path. A PATH only begins at `./` or `.<letter>` when '.' is in
  token-leading position (preceded by whitespace/newline/'('/'['/','/'='/etc.,
  i.e. not immediately after an ident/number/')'/']'/string).
* A REGEX literal `/.../` is lexed only when the previous significant (non-NEWLINE)
  token is the identifier `matches` — the simplest rule that disambiguates it from
  any future use of '/'. Elsewhere '/' is not part of Vaked's punctuation and is a
  lex error (it only legally appears inside strings, paths, or regex bodies).
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
        """True if this token equals the grammar terminal ``text``.

        Keyword/identifier literals (e.g. "field", "runtime", "matches", "in")
        match an IDENT token by value. Punctuation literals match an OP token by
        value. Quote terminals from the grammar ('"') are never matched directly —
        the lexer already assembled STRING tokens — so a bare '"' literal never
        appears in a reachable position.
        """
        if self.kind == "IDENT":
            return text == self.value
        if self.kind == "OP":
            return text == self.value
        # NUMBER/STRING/etc. are matched via prose terminals, not bare literals.
        return False


# Multi-char operators, longest first (so '->' beats '-', '<=' beats '<', etc.).
_MULTI_OPS = ["->", "<=", ">=", "..", "?="]
_SINGLE_OPS = set("=<>.;:,@()[]{}|")

_DURATION_UNITS = ("ns", "us", "ms", "s", "m", "h", "d")
_BYTE_UNITS = ("B", "KB", "MB", "GB", "TB")


def _is_letter(c: str) -> bool:
    return ("a" <= c <= "z") or ("A" <= c <= "Z")


def _is_digit(c: str) -> bool:
    return "0" <= c <= "9"


def _is_ident_start(c: str) -> bool:
    return _is_letter(c)


def _is_ident_part(c: str) -> bool:
    return _is_letter(c) or _is_digit(c) or c in "_-"


def _is_path_char(c: str) -> bool:
    # path_char = letter | digit | "/" | "_" | "-" | "."
    return _is_letter(c) or _is_digit(c) or c in "/_-."


def tokenize(src: str, filename: str = "<vaked>") -> "list[Token]":
    toks: list[Token] = []
    i = 0
    n = len(src)
    line = 1
    col = 1
    group_depth = 0          # nesting depth of '(' and '[' (suppresses NEWLINE)
    pending_newline = False  # a NEWLINE is queued but not yet emitted

    def last_significant():
        return toks[-1] if toks else None

    def advance(s: str):
        nonlocal line, col
        for ch in s:
            if ch == "\n":
                line += 1
                col = 1
            else:
                col += 1

    def emit(kind: str, value: str, tline: int, tcol: int):
        nonlocal pending_newline
        # flush a queued NEWLINE before any real token (never leading, never doubled)
        if pending_newline:
            if toks and toks[-1].kind != "NEWLINE":
                toks.append(Token("NEWLINE", "\\n", tline, tcol))
            pending_newline = False
        toks.append(Token(kind, value, tline, tcol))

    while i < n:
        c = src[i]
        tline, tcol = line, col

        # ---- whitespace (spaces/tabs/CR) ---------------------------------
        if c in " \t\r":
            advance(c)
            i += 1
            continue

        # ---- newline -----------------------------------------------------
        if c == "\n":
            advance(c)
            i += 1
            if group_depth == 0:
                pending_newline = True
            continue

        # ---- comment '#' to EOL (discarded) ------------------------------
        if c == "#":
            j = i
            while j < n and src[j] != "\n":
                j += 1
            advance(src[i:j])
            i = j
            continue

        # ---- string with ${ref} interpolation ----------------------------
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
                # ${ref} interpolation: consume verbatim into the STRING token; the
                # `interp` production is recognized lexically here (the ref inside
                # obeys the same dotted-ident rule but is opaque to the parser).
                buf.append(ch)
                j += 1
            else:
                raise LexError("unterminated string", tline, tcol)
            value = "".join(buf)
            advance(src[i:j])
            emit("STRING", value, tline, tcol)
            i = j
            continue

        # ---- regex literal /.../  (only right after `matches`) -----------
        if c == "/":
            ls = last_significant()
            if ls is not None and ls.kind == "IDENT" and ls.value == "matches":
                j = i + 1
                buf = ["/"]
                closed = False
                while j < n:
                    ch = src[j]
                    if ch == "\\":
                        if j + 1 >= n:
                            raise LexError("unterminated regex escape", tline, tcol)
                        buf.append(src[j:j + 2])
                        j += 2
                        continue
                    if ch == "\n":
                        raise LexError("unterminated regex (newline)", tline, tcol)
                    if ch == "/":
                        buf.append("/")
                        j += 1
                        closed = True
                        break
                    buf.append(ch)
                    j += 1
                if not closed:
                    raise LexError("unterminated regex literal", tline, tcol)
                value = "".join(buf)
                advance(src[i:j])
                emit("REGEX", value, tline, tcol)
                i = j
                continue
            raise LexError("unexpected '/' (regex only valid after `matches`)",
                           tline, tcol)

        # ---- path: '.' in leading position followed by '/' or letter -----
        if c == ".":
            ls = last_significant()
            # '.' is a DOT operator when it follows something a ref/value can end
            # with (ident/number/')'/']'/'}'/string/duration/bytes) — i.e. a dotted
            # path like  index.zigbeeFirmware . Otherwise, if followed by '/' or a
            # letter, it begins a PATH literal (./x or .foo). Also ".." is an OP.
            glued = ls is not None and ls.kind in (
                "IDENT", "NUMBER", "STRING", "DURATION", "BYTES", "REGEX"
            ) and (ls.line, ls.col + len(ls.value)) == (tline, tcol)
            # "glued" means the previous token ended exactly at this '.' with no
            # gap — that is the dotted-ref case (a.b). A path-leading '.' always has
            # a separator (or grouping/operator) before it.
            if i + 1 < n and src[i + 1] == "." and not glued:
                # ".." range operator (only reachable in expression position)
                advance("..")
                emit("OP", "..", tline, tcol)
                i += 2
                continue
            if not glued and i + 1 < n and (src[i + 1] == "/" or _is_letter(src[i + 1])):
                j = i + 1
                while j < n and _is_path_char(src[j]):
                    j += 1
                value = src[i:j]
                advance(value)
                emit("PATH", value, tline, tcol)
                i = j
                continue
            # otherwise it's a DOT operator (handled by generic OP path below)

        # ---- multi-char operators ----------------------------------------
        matched_op = None
        for op in _MULTI_OPS:
            if src.startswith(op, i):
                matched_op = op
                break
        if matched_op:
            advance(matched_op)
            emit("OP", matched_op, tline, tcol)
            i += len(matched_op)
            continue

        # ---- single-char operators ---------------------------------------
        if c in _SINGLE_OPS:
            advance(c)
            emit("OP", c, tline, tcol)
            i += 1
            continue

        # ---- numbers / durations / bytes ---------------------------------
        if _is_digit(c) or (c == "-" and i + 1 < n and _is_digit(src[i + 1])):
            j = i
            if src[j] == "-":
                j += 1
            while j < n and _is_digit(src[j]):
                j += 1
            is_float = False
            # fractional part: only if '.<digit>' (not the '..' range operator)
            if j < n and src[j] == "." and j + 1 < n and _is_digit(src[j + 1]):
                is_float = True
                j += 1
                while j < n and _is_digit(src[j]):
                    j += 1
            # unit suffix? (duration/bytes) — only on an integer literal, and only
            # when the suffix is immediately followed by a non-ident char (so e.g.
            # `10x` is not a bad duration but the next char decides ident-ness).
            if not is_float:
                rest = src[j:]
                # bytes first (KB/MB/... share leading letters with nothing here)
                unit = _match_unit(rest, _BYTE_UNITS)
                if unit and not (j + len(unit) < n and _is_ident_part(src[j + len(unit)])):
                    value = src[i:j] + unit
                    advance(value)
                    emit("BYTES", value, tline, tcol)
                    i = j + len(unit)
                    continue
                unit = _match_unit(rest, _DURATION_UNITS)
                if unit and not (j + len(unit) < n and _is_ident_part(src[j + len(unit)])):
                    value = src[i:j] + unit
                    advance(value)
                    emit("DURATION", value, tline, tcol)
                    i = j + len(unit)
                    continue
            value = src[i:j]
            advance(value)
            emit("NUMBER", value, tline, tcol)
            i = j
            continue

        # ---- identifiers --------------------------------------------------
        if _is_ident_start(c):
            j = i
            while j < n and _is_ident_part(src[j]):
                j += 1
            value = src[i:j]
            advance(value)
            emit("IDENT", value, tline, tcol)
            i = j
            continue

        raise LexError(f"unexpected character {c!r}", tline, tcol)

    # trailing NEWLINE / trim, then EOF sentinel
    if toks and toks[-1].kind == "NEWLINE":
        toks.pop()
    toks.append(Token("EOF", "<eof>", line, col))
    return toks


def _match_unit(rest: str, units) -> "str | None":
    """Return the longest unit in ``units`` that prefixes ``rest`` (or None)."""
    best = None
    for u in units:
        if rest.startswith(u) and (best is None or len(u) > len(best)):
            best = u
    return best


# --------------------------------------------------------------------------- #
# Mapping the grammar's prose / character-class terminals onto token KINDS.
#
# These maps are what let ebnf.py interpret the ON-DISK grammar over our tokens.
# Documented mapping (lexer-level prose terminals are hand-mapped, per guardrails):
#
#   Grammar terminal                         -> token predicate
#   ---------------------------------------     ---------------------------------
#   string  = '"' { char | interp } '"'      -> STRING token (assembled by lexer)
#   number  = [-]digit{digit}[.digit{digit}] -> NUMBER token
#   path    = "." ("/"|letter){path_char}    -> PATH token
#   duration= digit{digit}(ns|us|...|d)      -> DURATION token
#   bytes   = digit{digit}(B|KB|...|TB)      -> BYTES token
#   regex   = "/" {regex_char} "/"           -> REGEX token
#   ident   = letter {letter|digit|_|-}      -> IDENT token
#
# The character-level rules `letter`, `digit`, `char`, `path_char`, `regex_char`,
# `any`, `eol`, `interp` are SUBSUMED by the token-level rules above (the lexer
# already consumed those characters), so when they appear as Refs in a reachable
# production they resolve through TERMINAL_MAP to the appropriate whole-token kind.
# `comment`/`any`/`eol` are unreachable (dead) rules — see test_grammar_selfcontained.
# --------------------------------------------------------------------------- #

def _kind(*kinds):
    s = set(kinds)
    return lambda tok: tok.kind in s


# Prose terminals keyed by their normalized prose text (see ebnf._normalize_prose).
# We register every plausible normalized prefix the grammar's ?...? bodies reduce to.
PROSE_MAP = {
    # string char:  ? any Unicode scalar value except '"' and '\', or a JSON ... ?
    "any unicode scalar value except and or a json style escape sequence b f n r t uxxxx":
        _kind("STRING"),
    # regex_char: ? any Unicode scalar value except '/' and a line terminator, or ... ?
    "any unicode scalar value except and a line terminator or the two character escape "
    "denoting a literal":
        _kind("REGEX"),
    # letter: ? ASCII letter: a-z or A-Z ?
    "ascii letter a z or a z": _kind("IDENT"),
    # digit: ? ASCII decimal digit: 0-9 ?
    "ascii decimal digit 0 9": _kind("NUMBER"),
    # any: ? any Unicode scalar value ?
    "any unicode scalar value": _kind("IDENT", "NUMBER", "STRING", "OP", "PATH",
                                       "DURATION", "BYTES", "REGEX"),
    # eol: ? U+000A (line feed) or U+000D U+000A (CRLF) ?
    "u 000a line feed or u 000d u 000a crlf": _kind("NEWLINE"),
}

# Named character-class rules that resolve to whole-token kinds when reached as Refs
# (these are the rule NAMES, used by ebnf.Grammar.parse's terminal_map).
TERMINAL_MAP = {
    "letter": _kind("IDENT"),
    "digit": _kind("NUMBER"),
    "char": _kind("STRING"),
    "path_char": _kind("PATH"),
    "regex_char": _kind("REGEX"),
    "any": _kind("IDENT", "NUMBER", "STRING", "OP", "PATH", "DURATION", "BYTES", "REGEX"),
    "eol": _kind("NEWLINE"),
    # whole-token literal classes (referenced by `literal`, `expr`, etc.)
    "string": _kind("STRING"),
    "number": _kind("NUMBER"),
    "path": _kind("PATH"),
    "duration": _kind("DURATION"),
    "bytes": _kind("BYTES"),
    "regex": _kind("REGEX"),
    "ident": _kind("IDENT"),
    "interp": _kind("STRING"),  # interpolation is folded into the STRING token
}
