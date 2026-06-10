# vakedc — the Vaked front-end (prototype)

`vakedc` is the first executable Vaked front-end: a **lexer + parser** that turns a
`.vaked` source file into a **Labeled Property Graph** (LPG) — the typed-semantic-
graph substrate that [`docs/language/0011-type-system.md`](../docs/language/0011-type-system.md)'s
checker and [`docs/language/0012-lowering.md`](../docs/language/0012-lowering.md)'s
lowering operate on — with **byte-exact provenance** attached at node instantiation.
It implements 0011 pipeline **stages 1–4** (parse + resolve + elaborate + check):
the `parse` subcommand emits the LPG; the `check` subcommand runs the Goal-2 type
system (conformance, the closed constraint set, capability attenuation/POLA, and
generics consistency). Lowering (Goal 3) is the next increment. Python 3, **stdlib
only**.

## Usage

```bash
python3 -m vakedc parse <file.vaked> [--json PATH] [--sqlite PATH] [--print]
python3 -m vakedc check <file.vaked> [--json] [--builtins PATH]
```

`parse`: with no output flags, writes `.vaked/graph.json` (canonical JSON) and
`.vaked/graph.db` (SQLite) relative to the CWD; `--print` writes canonical JSON to
stdout. Exit `1` on an NFC/lex/parse error with a source-mapped
`file:line:col — expected …, got …` message on stderr.

`check`: type-checks the file against the built-in catalog
([`vaked/schema/builtins.vaked`](../vaked/schema/builtins.vaked)) and prints
diagnostics — human-readable `file:line:col: error: CODE: message [decl]` to
stderr by default, or canonical JSON (`{ "diagnostics": [ … ] }`, stable key
order, trailing newline) to stdout with `--json`. `--builtins PATH` overrides the
catalog; the default is resolved relative to the package, so `check` works from
any CWD (e.g. the repo root). **Exit codes:** `0` clean, `1` diagnostics present,
`2` usage / read / parse error. Diagnostic codes are 0011's `E-CONFORM-*`,
`E-CONSTRAINT-*`, `E-CAP-*`, `E-GENERIC-*`, plus the load-time `E-SCHEMA-*` /
`E-CAP-ORDER-*`; diagnostics are sorted by `(file, byteStart, byteEnd, code)`.

As a library: `vakedc.parse_file(path) -> Graph` and
`vakedc.check_file(path) -> list[Diagnostic]` (or `vakedc.check_source(src, name)`).

## Architecture (one line each)

- **`lexer.py`** — mode-switching tokenizer; tokens carry `{byteStart, byteEnd, line, col}`; NEWLINE suppressed inside open `(`/`[`; string `${ref}` interpolation; regex mode only after `matches`; durations/bytes/paths/numbers; `#` comments. NFC gate (rejects non-NFC source); `PINNED_UNICODE = "15.1.0"` (runtime mismatch ⇒ one stderr warning).
- **`parser.py`** — hand-written recursive descent, PEG-ordered per grammar v0.3 **exactly**; soft-keyword dispatch (`field`/`grant`/`order` before assignment, `open` after); newline-terminated statements; `VakedSyntaxError`.
- **`graph.py`** — the LPG: `Node {id, kind, name, labels[], props{}, provenance{file, decl, span}}`, `Edge {from, to, label, props{}}`; stable path-derived ids `<filename>#<outer>/<inner>`.
- **`resolve.py`** — lexically-scoped symbol table; ref worklist resolved at end-of-parse (forward refs); edge labels `contains`/`imports`/`depends_on`/`requires_capability`/`routes_to`/`member_of`; unresolvable heads → one `external` stub node per distinct dotted path.
- **`emit.py`** — `to_canonical_json` (byte-identical across runs) and `to_sqlite` + `canonical_dump` (deterministic ordered SELECT).
- **`check.py`** — 0011 stages 3–4. *Elaborate*: build a schema/capability registry from the built-in catalog LPG + the in-file user `schema`/`capability` decls (user decls override the catalog by name), and a per-domain attenuation partial order (reflexive-transitive closure of the `order` chains). *Check*: conformance (§1.1 five-clause rule incl. the Path-from-String acceptance), the closed constraint set (§3, incl. bounded-regex-dialect validation), capability validity + delegation-only-attenuates (§4.4), and generics consistency (§5). Pure: the only IO is reading the catalog. Emits sorted, source-mapped `Diagnostic`s.
- **`__main__.py`** — the `parse` and `check` CLIs.

The built-in catalog is **dogfooded** as Vaked source:
[`vaked/schema/builtins.vaked`](../vaked/schema/builtins.vaked) (v0.3 `schema` /
`capability` syntax) encodes the normative prose catalog
[`vaked/schema/parallel-types.md`](../vaked/schema/parallel-types.md); vakedc parses
it with its own parser and reads the registry from the resulting LPG.

## Span convention

Per 0012 §6.2: a decl's `byteStart` is the offset of its **leading keyword**, `byteEnd`
is **exclusive** (one past the closing `}`), and `line`/`col` are 1-based at `byteStart`.
Because the LPG records provenance at decl granularity (and the AST spans decls /
nodes / refs but not assignments / literals), the checker re-tokenizes each source
file once to land a diagnostic on the exact offending field name, value literal, or
delegation edge — deterministically, with no IO beyond the already-read source.

## Verification

`tests/spec/test_vakedc.py` (parser/LPG) and `tests/spec/test_vakedc_check.py`
(checker), both registered in `tests/spec/run_all.py`. The parser tests run a
differential oracle vs the from-EBNF recognizer (all 15 examples + the v0.2-compat
probes), a byte-for-byte LPG golden snapshot, cross-artifact provenance, and a
determinism check. The checker tests verify: the catalog parses + self-checks
clean; catalog↔`parallel-types.md` coverage (every kind/domain named in the md
exists in the builtins graph); `conformant.vaked` → 0 diagnostics; `rejected.vaked`
→ exactly its three documented codes with a byte-for-byte `--json` golden snapshot
(`tests/spec/golden/rejected.diagnostics.json`); all 15 examples clean; and
diagnostics determinism.

## Design record

[`docs/superpowers/specs/2026-06-10-vakedc-parser-prototype-design.md`](../docs/superpowers/specs/2026-06-10-vakedc-parser-prototype-design.md)
(parser) and
[`docs/superpowers/specs/2026-06-10-vakedc-checker-design.md`](../docs/superpowers/specs/2026-06-10-vakedc-checker-design.md)
(checker) are normative for this prototype.

## Checker — known deferrals & pinned decisions (review findings, 2026-06-10)

- **§4.3 use-check deferred.** `used(p) ⊑ granted(p)` requires the catalog to
  annotate which fields *contribute uses* (0011: "as the catalog specifies");
  `parallel-types.md` / `builtins.vaked` carry no use-contribution metadata yet,
  so only the §4.4 attenuation/delegation check runs. Implementing use-gathering
  is the next checker increment once the catalog grows `uses` annotations.
- **`mediaPipeline` stage-record conformance deferred.** `stageResize`/
  `stageEncode` exist in the catalog but stages are not yet wired into nested
  conformance (the md marks them "[from examples]" and `mediaPipeline` is
  `open`).
- **User override REPLACES the builtin (pinned decision).** An in-file
  `schema <kind>` / `capability <domain>` fully replaces the builtin of the same
  name (last-wins by name), not a merge. 0011 should eventually state this
  explicitly; until then this README is the reference.
