# Zig Front-End for Vaked (vakedc-zig) — v0.x Design Note

**Status:** v0.0.1 design + runnable subset. Code lives in
[`zig/vakedc/`](../../zig/vakedc/). Authored without a Zig toolchain in-container,
so it is **not yet compiled here**; `zig build test` (after
[`scripts/setup-zig.sh`](../../scripts/setup-zig.sh)) is the acceptance gate.

## 1. Why

The project thesis is "Vaked declares. Nix materializes. OTP supervises. **Zig
enforces.**" Today the only compiler is the Python `vakedc` reference
implementation. The
[`OPTIMIZATION_ROADMAP.md`](OPTIMIZATION_ROADMAP.md) identifies a native rewrite
as the v1.0 path to 10× throughput (no GIL, real parallelism, compact graphs).
This note starts that rewrite **front-to-back**: a lexer + parser first, because
parsing is the cheapest stage to get a runnable, testable, dogfoodable slice and
it pins the grammar in a second independent implementation (a useful
differential oracle against the Python parser).

This is deliberately **design-first and scoped**: a subset, not a full compiler.
The full type-checker + lowering port is tracked as a follow-up.

## 2. Subset grammar (what v0.x parses)

A strict subset of [`vaked/grammar/vaked-v0-plus.ebnf`](../../vaked/grammar/vaked-v0-plus.ebnf):

```
file   = { item }
item   = import | decl
import = "use" string
decl   = kind name block
block  = "{" { stmt } "}"
stmt   = decl | edge | assignment | app
edge   = [ kindkw ] ref "->" ref { "->" ref }    # e.g.  mesh a -> b
assignment = ident ("=" | "?=") expr
app    = ref [ record ]                           # e.g.  policy { role = "x" }
expr   = string | number | bool | null | list | app
list   = "[" [ expr { "," expr } ] "]"
record = "{" { assignment | app } "}"
ref    = ident { "." ident }
```

This is enough to parse [`vaked/examples/swe-swarm-loadtest.vaked`](../../vaked/examples/swe-swarm-loadtest.vaked)
end to end (1 import, 1 `runtime` decl with nested `fiber`/`parallel` decls, and
16 `mesh` edges).

## 3. EBNF → AST mapping

| EBNF production | Zig handling (`src/parser.zig`) | AST `NodeKind` |
|-----------------|----------------------------------|----------------|
| `import` | `parseImport` | `.import` |
| `decl` (kind name block) | `parseDecl` → `parseBlock` | `.decl` |
| `assignment` | `parseAssignment` | `.assignment` |
| `edge` | `parseEdge` (n endpoints as children) | `.edge` |
| `app` / `ref` | `parseApp` / `parseRef` | `.app` / `.ref` |
| `list` | `parseList` | `.list` |
| `literal` (string/number/bool/null) | `parseExpr` | `.literal` |

The lexer (`src/lexer.zig`) maps the grammar's terminals to a flat `Token` list
(`ident`, `string`, `number`, the punctuation, and the `->`/`?=` digraphs).

## 4. Where the subset deliberately diverges (and why)

These are the boundaries a reviewer should know; each is a conscious
simplification, not an accident:

1. **Newlines are not tokens.** The reference grammar is newline-terminated;
   v0.x is brace/lookahead-driven instead. This is simpler and unambiguous for
   the subset, but it means the Zig parser does not (yet) enforce the
   "one statement per line" rule. Parity item for the follow-up.
2. **`mesh a -> b` is parsed as a *tagged edge*.** In the reference grammar this
   line actually parses as a bare `mesh` ref statement followed by a separate
   `a -> b` edge (an artifact of ordered-choice + newline termination). v0.x
   folds the optional leading kind keyword into the edge as a `tag`, which is
   cleaner and accepts the same input. Documented so the difference is intended.
3. **No type layer.** `field`/`grant`/`order`/`open`, signatures, annotations,
   refinements, and the `|` type syntax are out of scope for v0.x parsing.
4. **Strings are not unescaped**; `${}` interpolation is not interpreted.
5. **Out-of-subset input is rejected** with a `file:line:col` message — the
   parser never silently accepts what it does not understand (see the negative
   test in `parser.zig`).

## 5. Build, test, validate

```bash
scripts/setup-zig.sh                 # install pinned Zig 0.13.0 (idempotent)
cd zig/vakedc
zig build test                       # lexer + parser unit tests (acceptance gate)
zig build run -- parse ../../vaked/examples/swe-swarm-loadtest.vaked
```

**Differential dogfooding** (the research-useful part): the Zig parser should
accept exactly what the Python reference accepts *within the subset*:

```bash
python3 -m vakedc parse vaked/examples/swe-swarm-loadtest.vaked        # reference
zig build run -- parse ../../vaked/examples/swe-swarm-loadtest.vaked   # this
```

A CI job can assert both succeed on every committed example that lies inside the
subset; divergence is a bug to investigate (a second parser is a cheap oracle
for grammar ambiguities).

## 6. Roadmap to parity (follow-up)

1. Newline-aware tokenizer to match the reference statement rule exactly.
2. Full `stmt` set (type-layer statements, signatures, annotations).
3. Resolve + check stages (port 0011 incrementally), then lowering (0012).
4. Wire `zig build test` + the differential oracle into CI; pin Zig via
   `.zig-version` and the flake devshell.

## 7. Open questions

- Pin Zig in `flake.nix`'s devshell so `nix develop` provides the exact
  `.zig-version` (today the setup script is the out-of-Nix path).
- AST representation: the current tagged-`Node` tree is fine for parsing; a
  checker may want a typed sum or an arena of indexed nodes for cache locality
  (ties to the OPTIMIZATION_ROADMAP memory-efficiency goals).
