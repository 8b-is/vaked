# vakedc — the Vaked front-end (prototype)

`vakedc` is the first executable Vaked front-end: a **lexer + parser** that turns a
`.vaked` source file into a **Labeled Property Graph** (LPG) — the typed-semantic-
graph substrate that [`docs/language/0011-type-system.md`](../docs/language/0011-type-system.md)'s
checker and [`docs/language/0012-lowering.md`](../docs/language/0012-lowering.md)'s
lowering operate on — with **byte-exact provenance** attached at node instantiation.
It implements 0011 pipeline **stages 1–2** (parse + resolve). Schema/constraint/POLA
checking (stages 3–4) and lowering are the next increments. Python 3, **stdlib only**.

## Usage

```bash
python3 -m vakedc parse <file.vaked> [--json PATH] [--sqlite PATH] [--print]
```

With no output flags, writes `.vaked/graph.json` (canonical JSON) and `.vaked/graph.db`
(SQLite) relative to the CWD. `--print` writes canonical JSON to stdout. Exit code is
`1` on an NFC/lex/parse error, with a source-mapped `file:line:col — expected …, got …`
message on stderr. As a library: `vakedc.parse_file(path) -> Graph`.

## Architecture (one line each)

- **`lexer.py`** — mode-switching tokenizer; tokens carry `{byteStart, byteEnd, line, col}`; NEWLINE suppressed inside open `(`/`[`; string `${ref}` interpolation; regex mode only after `matches`; durations/bytes/paths/numbers; `#` comments. NFC gate (rejects non-NFC source); `PINNED_UNICODE = "15.1.0"` (runtime mismatch ⇒ one stderr warning).
- **`parser.py`** — hand-written recursive descent, PEG-ordered per grammar v0.3 **exactly**; soft-keyword dispatch (`field`/`grant`/`order` before assignment, `open` after); newline-terminated statements; `VakedSyntaxError`.
- **`graph.py`** — the LPG: `Node {id, kind, name, labels[], props{}, provenance{file, decl, span}}`, `Edge {from, to, label, props{}}`; stable path-derived ids `<filename>#<outer>/<inner>`.
- **`resolve.py`** — lexically-scoped symbol table; ref worklist resolved at end-of-parse (forward refs); edge labels `contains`/`imports`/`depends_on`/`requires_capability`/`routes_to`/`member_of`; unresolvable heads → one `external` stub node per distinct dotted path.
- **`emit.py`** — `to_canonical_json` (byte-identical across runs) and `to_sqlite` + `canonical_dump` (deterministic ordered SELECT).
- **`__main__.py`** — the `parse` CLI.

## Span convention

Per 0012 §6.2: a decl's `byteStart` is the offset of its **leading keyword**, `byteEnd`
is **exclusive** (one past the closing `}`), and `line`/`col` are 1-based at `byteStart`.

## Verification

Exercised by `tests/spec/test_vakedc.py` (registered in `tests/spec/run_all.py`):
differential oracle vs the from-EBNF recognizer (all 15 examples + the v0.2-compat
probes), a byte-for-byte golden snapshot (`tests/spec/golden/operator-field.graph.json`),
cross-artifact provenance against `vaked/examples/lowering/provenance.json`, and a
determinism check (JSON + SQLite).

## Design record

[`docs/superpowers/specs/2026-06-10-vakedc-parser-prototype-design.md`](../docs/superpowers/specs/2026-06-10-vakedc-parser-prototype-design.md)
is normative for this prototype.
