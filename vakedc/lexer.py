"""vakedc.lexer — mode-switching tokenizer for the Vaked language (.vaked).
Standalone (does NOT import tests/spec). The lexical rules here are the same ones
the from-EBNF recognizer proves correct (dotted-ref vs path, regex-only-after-
``matches``, NEWLINE suppression inside open ``(``/``[``, duration/bytes units,
``#`` comments, ``${ref}`` string interpolation), re-implemented so every token
also carries an exact byte span ``{byteStart, byteEnd, line, col}`` (1-based
line/col) — the substrate 0011's checker and 0012's lowering operate on.
NFC gate
--------
Source must be Unicode-NFC-normalized; non-NFC source is rejected with a source-
mapped :class:`VakedLexError`. The pinned Unicode version is :data:`PINNED_UNICODE`;
when the runtime's ``unicodedata.unidata_version`` differs, ONE warning is emitted
to stderr (mismatch is a warning, never an error — mirrors the .hcplang 15.1.0 pin).
Token kinds
-----------
IDENT STRING NUMBER DURATION BYTES PATH REGEX OP NEWLINE EOF
"""
from __future__ import annotations
import sys
import unicodedata
from dataclasses import dataclass
PINNED_UNICODE = "15.1.0"
_warned_unicode_mismatch = False
def _maybe_warn_unicode_version() -> None:
global _warned_unicode_mismatch
if _warned_unicode_mismatch:
return
_warned_unicode_mismatch = True
runtime = unicodedata.unidata_version
if runtime != PINNED_UNICODE:
print(
f"vakedc: warning: Unicode data version mismatch "
f"(pinned {PINNED_UNICODE}, runtime {runtime}); "
f"NFC normalization may differ for edge-case codepoints.",
file=sys.stderr,
)
class VakedLexError(Exception):
"""Lexical error carrying a source-mapped (file:line:col) message."""
def __init__(self, msg: str, file: str, line: int, col: int):
super().__init__(f"{file}:{line}:{col} — {msg}")
self.msg = msg
self.file = file
self.line = line
self.col = col
@dataclass
class Token:
kind: str
value: str
byteStart: int
byteEnd: int # exclusive
line: int # 1-based, of byteStart
col: int # 1-based, of byteStart
def matches_literal(self, text: str) -> bool:
"""True if this token equals the grammar terminal ``text``.
IDENT/OP literals match by value; quote/number/etc. are matched by kind
elsewhere in the parser, so a bare literal never matches them here.
"""
if self.kind == "IDENT" or self.kind == "OP":
return text == self.value
return False
_MULTI_OPS = ("->", "<=", ">=", "..", "?=")
_SINGLE_OPS = set("=<>.;:,@()[]{}|")
_DURATION_UNITS = ("ns", "us", "ms", "s", "m", "h", "d")
_BYTE_UNITS = ("B", "KB", "MB", "GB", "TB")
def _is_letter(c: str) -> bool:
return ("a" <= c <= "z") or ("A" <= c <= "Z")
def _is_digit(c: str) -> bool:
return "0" <= c <= "9"
def _is_ident_part(c: str) -> bool:
return _is_letter(c) or _is_digit(c) or c in "_-"
def _is_path_char(c: str) -> bool:
return _is_letter(c) or _is_digit(c) or c in "/_-."
def _match_unit(rest: str, units) -> "str | None":
best = None
for u in units:
if rest.startswith(u) and (best is None or len(u) > len(best)):
best = u
return best
def tokenize(src: str, filename: str = "<vaked>") -> "list[Token]":
"""Tokenize ``src`` into a list of :class:`Token` ending with an EOF sentinel.
Raises :class:`VakedLexError` on a lexical error or non-NFC source.
"""
_maybe_warn_unicode_version()
if not unicodedata.is_normalized("NFC", src):
nfc = unicodedata.normalize("NFC", src)
line = 1
col = 1
limit = min(len(src), len(nfc))
i = 0
while i < limit and src[i] == nfc[i]:
if src[i] == "\n":
line += 1
col = 1
else:
col += 1
i += 1
raise VakedLexError(
"source is not Unicode-NFC-normalized (normalize the file to NFC)",
filename, line, col,
)
toks: "list[Token]" = []
i = 0
n = len(src)
off = [0] * (n + 1)
acc = 0
for k in range(n):
off[k] = acc
acc += len(src[k].encode("utf-8"))
off[n] = acc
line = 1
col = 1
group_depth = 0 # nesting of '(' and '[' (suppresses NEWLINE)
pending_newline = False # a NEWLINE is queued but not yet emitted
pending_nl_pos = (0, 1, 1) # (charidx, line, col) of the queued newline site
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
def emit(kind: str, value: str, ci_start: int, ci_end: int,
tline: int, tcol: int):
nonlocal pending_newline
if pending_newline:
if toks and toks[-1].kind != "NEWLINE":
pidx, pline, pcol = pending_nl_pos
toks.append(Token("NEWLINE", "\\n", off[pidx], off[pidx],
pline, pcol))
pending_newline = False
toks.append(Token(kind, value, off[ci_start], off[ci_end], tline, tcol))
while i < n:
c = src[i]
tline, tcol = line, col
ci = i
if c in " \t\r":
advance(c)
i += 1
continue
if c == "\n":
if group_depth == 0 and not pending_newline:
pending_newline = True
pending_nl_pos = (i, line, col)
advance(c)
i += 1
continue
if c == "#":
j = i
while j < n and src[j] != "\n":
j += 1
advance(src[i:j])
i = j
continue
if c == '"':
j = i + 1
buf = ['"']
closed = False
while j < n:
ch = src[j]
if ch == "\\":
if j + 1 >= n:
raise VakedLexError("unterminated escape in string",
filename, tline, tcol)
buf.append(src[j:j + 2])
j += 2
continue
if ch == '"':
buf.append('"')
j += 1
closed = True
break
if ch == "\n":
raise VakedLexError("unterminated string (newline in string)",
filename, tline, tcol)
buf.append(ch)
j += 1
if not closed:
raise VakedLexError("unterminated string", filename, tline, tcol)
value = "".join(buf)
advance(src[i:j])
emit("STRING", value, ci, j, tline, tcol)
i = j
continue
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
raise VakedLexError("unterminated regex escape",
filename, tline, tcol)
buf.append(src[j:j + 2])
j += 2
continue
if ch == "\n":
raise VakedLexError("unterminated regex (newline)",
filename, tline, tcol)
if ch == "/":
buf.append("/")
j += 1
closed = True
break
buf.append(ch)
j += 1
if not closed:
raise VakedLexError("unterminated regex literal",
filename, tline, tcol)
value = "".join(buf)
advance(src[i:j])
emit("REGEX", value, ci, j, tline, tcol)
i = j
continue
raise VakedLexError(
"unexpected '/' (regex literal is only valid after `matches`)",
filename, tline, tcol)
if c == ".":
ls = last_significant()
glued = ls is not None and ls.kind in (
"IDENT", "NUMBER", "STRING", "DURATION", "BYTES", "REGEX"
) and ls.byteEnd == off[ci]
if i + 1 < n and src[i + 1] == "." and not glued:
advance("..")
emit("OP", "..", ci, i + 2, tline, tcol)
i += 2
continue
if not glued and i + 1 < n and (src[i + 1] == "/"
or _is_letter(src[i + 1])):
j = i + 1
while j < n and _is_path_char(src[j]):
j += 1
value = src[i:j]
advance(value)
emit("PATH", value, ci, j, tline, tcol)
i = j
continue
matched_op = None
for op in _MULTI_OPS:
if src.startswith(op, i):
matched_op = op
break
if matched_op:
advance(matched_op)
emit("OP", matched_op, ci, i + len(matched_op), tline, tcol)
i += len(matched_op)
continue
if c in _SINGLE_OPS:
if c == "(" or c == "[":
group_depth += 1
elif c == ")" or c == "]":
if group_depth > 0:
group_depth -= 1
advance(c)
emit("OP", c, ci, i + 1, tline, tcol)
i += 1
continue
if _is_digit(c) or (c == "-" and i + 1 < n and _is_digit(src[i + 1])):
j = i
if src[j] == "-":
j += 1
while j < n and _is_digit(src[j]):
j += 1
is_float = False
if j < n and src[j] == "." and j + 1 < n and _is_digit(src[j + 1]):
is_float = True
j += 1
while j < n and _is_digit(src[j]):
j += 1
if not is_float:
rest = src[j:]
unit = _match_unit(rest, _BYTE_UNITS)
if unit and not (j + len(unit) < n
and _is_ident_part(src[j + len(unit)])):
value = src[i:j] + unit
advance(value)
emit("BYTES", value, ci, j + len(unit), tline, tcol)
i = j + len(unit)
continue
unit = _match_unit(rest, _DURATION_UNITS)
if unit and not (j + len(unit) < n
and _is_ident_part(src[j + len(unit)])):
value = src[i:j] + unit
advance(value)
emit("DURATION", value, ci, j + len(unit), tline, tcol)
i = j + len(unit)
continue
value = src[i:j]
advance(value)
emit("NUMBER", value, ci, j, tline, tcol)
i = j
continue
if _is_letter(c):
j = i
while j < n and _is_ident_part(src[j]):
j += 1
value = src[i:j]
advance(value)
emit("IDENT", value, ci, j, tline, tcol)
i = j
continue
raise VakedLexError(f"unexpected character {c!r}", filename, tline, tcol)
if toks and toks[-1].kind == "NEWLINE":
toks.pop()
toks.append(Token("EOF", "<eof>", off[n], off[n], line, col))
return toks