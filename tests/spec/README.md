# `tests/spec/` — Vaked spec-test harness

An executable version of the by-hand spec review: it **builds recognizers from the
EBNF grammars on disk** and verifies that every example derives, plus consistency
checks across the specs and the lowering fixtures.

* **Python 3, standard library only.** No pip dependencies, no network, deterministic.
* Run it: `python3 tests/spec/run_all.py` (from the repo root; works from anywhere).
* Exit code is non-zero if anything fails — CI gates on it.

## What each test guards

| Module | Guards |
|--------|--------|
| `test_grammar_selfcontained.py` | For **both** `.ebnf` files: every RHS nonterminal is defined, and no rule is dead (unreachable from the start symbol) except a documented allowlist. The allowlist is self-checking — listing a *live* rule as dead also fails — so it cannot rot. |
| `test_examples_parse.py` | All **15** `.vaked` examples parse against `vaked/grammar/vaked-v0-plus.ebnf`; `hcp-core.hcplang` parses against `protocol/hcplang/grammar.ebnf`. Plus inline **v0.2-compat regression probes** (see below). Each item reports PASS/FAIL with a source location. |
| `test_lowering_fixtures.py` | The `vaked/examples/lowering/` fixtures are internally consistent and consistent with `docs/language/0012-lowering.md`: provenance schema + **recomputed** spans, artifact-map lexicographic order, emitter-registry membership, Zig-config canonical key order, JSONL header, and the generated-by-Vaked headers / `flake.nix` balance + pinned-rev. |
| `test_doc_links.py` | Every **relative** markdown link in `docs/**`, `vaked/**`, `protocol/**`, `README.md`, `CLAUDE.md` resolves to an existing path (anchors stripped, external links skipped). |

The recognizers read the grammar **files** at run time (`ebnf.Grammar.load(path)`),
so the tests exercise the actual spec artifacts — not hand-copies. A grammar edit
that breaks self-containment, or an example/fixture that drifts from the spec, turns
the suite red.

## How it works (the recognizer)

### `ebnf.py` — EBNF loader + PEG interpreter

Loads the repo's EBNF notation (`rule = … ;` with `"literal"`, `'literal'`, `{ }`,
`[ ]`, `|`, `( )`, and `? prose ?` terminals) into a small expression AST, then
interprets it as a **PEG**: `|` is *ordered choice* ("first match wins", exactly as
the grammar headers state), `{ }`/`[ ]` are greedy, and alternatives backtrack on
failure. A packrat memo keeps it linear and immune to pathological backtracking.

The interpreter runs over a **token stream** produced by a language lexer, not over
raw characters. A grammar literal like `"field"` or `":"` is matched against a token
via `Token.matches_literal`. `? prose ?` terminals and the character-class leaf rules
are mapped onto token *kinds* by a per-language `PROSE_MAP` / `TERMINAL_MAP`. Lexical
**leaf rules** that the lexer realizes as a single token (`string`, `number`, `ident`,
`path`, `duration`, `bytes`, `regex`, …) are passed as `terminal_rules` and matched
atomically rather than expanded character-by-character — this is the documented
lexer/grammar boundary. Everything **structural** is interpreted straight from the
on-disk grammar.

### Lexer-level prose-terminal mapping (documented, per the guardrails)

The grammars' character-level / prose terminals are hand-mapped to lexer token kinds.
The mapping lives next to each lexer (`PROSE_MAP` / `TERMINAL_MAP` at the bottom of
`lex_vaked.py` and `lex_hcplang.py`):

* **vaked**: `string`→STRING, `number`→NUMBER, `path`→PATH, `duration`→DURATION,
  `bytes`→BYTES, `regex`→REGEX, `ident`→IDENT; the char rules
  `letter`/`digit`/`char`/`path_char`/`regex_char`/`any`/`eol`/`interp` are subsumed
  by those whole-token rules (the lexer already consumed those characters).
* **hcplang**: `string`→STRING, `int_literal`→INT, `float_literal`→FLOAT,
  `ident`→IDENT, `annotation`→DOCANN (the whole `/// …\n` line is one token);
  `letter`/`digit`/`hexdigit`/`string_char`/`newline`/`not_newline` are subsumed.

### The newline / statement-termination rule

The vaked grammar header: *a newline TERMINATES a statement EXCEPT inside an open
grouping `( ) [ ] { }`*, and this "bounds the `{ ident }` repetitions in
`inherit`/`grant` to the current line." Reconciling that with "the statement list
inside a block is newline-delimited" (a block is also `{ }`) requires care, because
**lists and records may span lines but a statement-block's statements may not**.

How the harness models it (exactly, not approximately):

* The **lexer** suppresses `NEWLINE` only inside `(` and `[` nesting (unambiguously
  value context). It emits `NEWLINE` tokens otherwise — including inside `{ }`.
* The **parser** treats `NEWLINE` as insignificant whitespace between statements /
  record entries and skips it before matching a terminal — *except* inside the three
  **line-bound rules** `inherit_stmt`, `grant_decl`, `order_decl`, where `NEWLINE` is
  significant and **terminates** the `{ ident }` / chain repetition (so `grant`
  cannot swallow the next statement's leading keyword, and a chain ends at its line).
* An explicit separator `;` *continues* a statement across a newline: after matching
  `;` the parser skips trailing `NEWLINE`s, so a `;`-separated `order` chain may wrap
  onto the next line (as in `capability-attenuation.vaked` / `conformant.vaked`).

Putting the block-vs-value decision in the parser (which knows which production it is
in) — rather than guessing in the lexer — is what lets one `NEWLINE` rule serve both
multi-line records *and* line-bounded `grant`/`order`.

### Soft-keyword handling (v0.3)

`field` / `grant` / `order` are tried **before** `assignment`; each self-disambiguates
on its required second token, so `order = 3` / `grant = "x"` / `field = 1` fall through
to `assignment`. `open` is the one bare single-keyword form, so `open_decl` is ordered
**after** `assignment`: `open = true` parses as an assignment, a bare `open` as an
`open_decl`. PEG ordered choice + backtracking reproduces this directly from the
grammar's `stmt` rule order; the regression probes in `test_examples_parse.py` pin it.

### Other vaked lexer notes

* `#` comments run to end of line and are discarded.
* Strings recognize `${ref}` interpolation inline (folded into the STRING token).
* A `.` *glued* to a preceding ident/value lexes as a DOT (dotted ref `a.b`); a `.`
  in token-leading position followed by `/` or a letter begins a PATH (`./x`).
* A regex literal `/…/` is lexed **only** when the previous significant token is the
  identifier `matches` (the simplest rule that disambiguates `/`).

### hcplang lexer notes

* `#` and `//` are comments (discarded); `///` is **not** a comment — it is a doc
  *annotation* retained as a single DOCANN token (per that grammar's `annotation`
  rule, which ends at the newline). Checked longest-prefix-first.
* Attributes / tags: `@` is an OP; `@redact` / `@3` / `@relic` are `@` then an
  IDENT / INT (the grammar composes them). Attributes appear both leading and
  trailing; the schema name is a `qualified_ident` (`hcp.core`).
* Identifiers are `letter { letter | digit | "_" }` — **no `-`** (unlike vaked).

## Policy

**New examples and grammar changes must keep `run_all.py` green.**

* Add a `.vaked` example → it must parse (and bump `EXPECTED_VAKED_COUNT` in
  `test_examples_parse.py` if the example set grows).
* Change a grammar → keep it self-contained (no undefined nonterminals; no new dead
  rules outside the allowlist) and keep every example parsing.
* Touch a lowering fixture or a spec cross-reference → keep the fixtures consistent
  with `0012-lowering.md` and keep markdown links resolving.

If you believe a test is wrong because the **grammar** is wrong (not the recognizer),
stop and report it — do not patch grammars or examples just to make the suite pass.
The recognizers genuinely interpret the on-disk `.ebnf`; only the lexer-level prose
terminals are hand-mapped (documented above).

## Known oracle limitations (review findings, 2026-06-10)

- **The from-EBNF recognizer is newline-over-permissive** vs the grammar header:
  `ebnf.py`'s `_skip_ws` skips NEWLINE before every terminal outside the three
  line-bound rules, so it accepts intra-statement newlines (`field\n x : Int`,
  `a -> b\n -> c`) that the grammar — and `vakedc`, which is the stricter,
  faithful implementation — reject. All observed divergences are one-sided
  (recognizer accepts / vakedc rejects); the differential test therefore proves
  agreement on its probe set, not full equivalence. Tightening the recognizer
  is tracked as a future improvement.
- **Non-NFC input is out of differential scope by design**: `vakedc` rejects
  non-NFC source at the lexer gate (pinned Unicode 15.1.0); the recognizer has
  no such gate. Differential probes are NFC-only.
