# DEV_GUIDE.md — Vaked Language, Compiler & MLIR Layer

A companion to `CONTRIBUTING.md` and `CLAUDE.md` focused on the **language
definition, compiler pipeline, and MLIR pass layer**. If you're working on
grammar, vakedc, the type checker, lowering, or the MLIR passes, this is
your starting point.

---

## 1. Quick Start — Get Running

```bash
# From the repo root (any machine with Python 3.12+):
python3 -m vakedc parse   vaked/examples/operator-field.vaked --print
python3 -m vakedc check   vaked/examples/operator-field.vaked --json
python3 -m vakedc lower   vaked/examples/operator-field.vaked --out /tmp/out
python3 -m vakedc passes  vaked/examples/operator-field.vaked --json
```

Stdlib only — no install, no build. The Zig front-end (`vakedz`) is a
separate binary built with `zig build`.

### Full dev shell (Nix)

```bash
nix develop .   # gives: zig, erlang, elixir, rust, mlir-tblgen, d2
```

---

## 2. Repo Map — Language & Compiler Scope

These are the directories and files you'll touch most.

```
vaked/                      # The language itself
  grammar/
    vaked-v0-plus.ebnf      # EBNF grammar (307 lines) — THE spec
  schema/
    builtins.vaked          # Built-in type catalog (schemas, capabilities)
  examples/                 # Executable specifications
    operator-field.vaked    # Canonical "full stack" example
    agentfield-swe.vaked    # SWE agent workflow example
    membrane/               # Network/filesystem membrane examples
    primitives/             # Individual primitive examples
    lowering/               # Lowering output fixtures

vakedc/                     # Python prototype front-end
  lexer.py                  # NFC-normalizing tokenizer (Stage 1)
  parser.py                 # PEG-ordered recursive descent (Stage 2)
  resolve.py                # LPG builder + symbol resolution (Stage 2)
  graph.py                  # Labeled Property Graph model
  check.py                  # Type checker (Stages 3–4, 0011)
  lower.py                  # Multi-target lowering (0012)
  emit.py                   # Canonical JSON & SQLite serialization
  lsp.py                    # LSP 3.17 server (for vaked-ide)
  __main__.py               # CLI: parse | check | lower | passes | lsp
  passes/                   # ★ MLIR-mirror pass pipeline (Stage-0 Python)
    __init__.py             # Pipeline orchestrator + data types
    pass01_topology.py      # Pass 1: cycle + depth + bound (0021)
    pass02_wal.py           # Pass 2: WAL frame injection (0022)
    pass03_aot_index.py     # Pass 3: supervisor index gen (0023)
  mlir/                     # ★ Stage-1 MLIR dialect definitions
    VakedDialect.td         # vaked dialect ops & types (247 lines)
    HcpDialect.td           # hcp dialect ops & types (235 lines)
    VakedDialect.cpp        # C++ dialect registration + verifiers
    HcpDialect.cpp          # C++ dialect registration
    CMakeLists.txt          # CMake build: TableGen → dialect library
    run_tests.sh            # Test: mlir-tblgen + Stage-0 corpus

vakedz/                     # Zig production front-end (v0.1.0, Zig 0.16)
  src/
    lexer.zig, parser.zig, check.zig, lower.zig, cache.zig, graph.zig, json.zig
  test/                     # Unit tests + crossverify.sh

tests/
  spec/                     # Spec conformance tests (grammar, type system)
  corpus/
    0024-differential/      # Differential test corpus for MLIR passes
      fixtures/             # 6 topology classes: single/linear/diamond/cycle/bound
      run_corpus.py         # Harness: lower → byte-compare + passes → depth/WAL check

docs/language/              # Design series (the normative specs)
  0001-manifesto.md … 0018-compiler.md
  0019-mlir-vaked-dialect.md … 0024-mlir-lowering-staged-adoption.md
  reviews/                  # Publication reviews of key specs
  references/               # External reference notes
```

**Key convention:** Grammar (EBNF) is *the* specification. The parser in
`vakedc/parser.py` implements the EBNF. If they disagree, the EBNF wins.

---

## 3. Language Layer — Grammar, Schemas, Examples

### The grammar is the spec

`vaked/grammar/vaked-v0-plus.ebnf` defines 29 declaration kinds. To add a
new language construct:

```
1. Write the EBNF production       → vaked/grammar/
2. Add a schema for it             → vaked/schema/builtins.vaked
3. Write an example                 → vaked/examples/
4. Update the parser                 → vakedc/parser.py (if the grammar changed)
5. Update the type checker           → vakedc/check.py (if new constraints)
6. Update the lowerer                → vakedc/lower.py (if new artifacts)
7. Add pass logic (if workflow-like) → vakedc/passes/
8. Add spec tests                    → tests/spec/
```

### Declaration kinds (EBNF)

```ebnf
kind = "runtime" | "engine" | "host" | "network" | "filesystem"
     | "mcp" | "ebpf" | "index" | "catalog" | "stream"
     | "fiber" | "surface" | "mesh" | "device" | "mediaPipeline"
     | "parallel" | "workflow" | "memory" | "budget" | "runclass"
     | "observability"
```

Each kind maps to a schema in `builtins.vaked`. If a kind has no schema,
the checker treats it as semi-opaque (rejects unknown fields but does not
enforce type constraints on known ones).

### Examples as executable specs

Every `.vaked` file under `vaked/examples/` is tested by spec tests and the
differential corpus. To add an example:

```bash
# Create the example
echo 'runtime my { … }' > vaked/examples/my-feature.vaked

# Verify it parses, checks, and lowers
python3 -m vakedc check  vaked/examples/my-feature.vaked
python3 -m vakedc lower  vaked/examples/my-feature.vaked --out /tmp/verify
```

### The builtins catalog

`vaked/schema/builtins.vaked` defines schemas for every declaration kind,
capability domain hierarchy, and type aliases. It is loaded by the checker
before processing user code. Changes here affect every `.vaked` file.

---

## 4. Compiler Pipeline

```
.vaked source
  │
  ▼ [Stage 1 — Lex]          lexer.py
  tokens
  ▼ [Stage 2 — Parse]        parser.py + resolve.py
  Labeled Property Graph
  ▼ [Stage 3 — Elaborate]    check.py (schema registry, capability order)
  Elaborated LPG
  ▼ [Stage 4 — Check]        check.py (conformance, constraints, caps, generics)
  Validated LPG + diagnostics
  ▼ [Stage 5 — Lower]        lower.py
  Artifacts (flake.nix, gen/*, provenance.json)
  │
  ▼ [Pass Pipeline — MLIR-mirror]
  Pass 1 (topology) → Pass 2 (WAL) → Pass 3 (AOT index)
  gen/workflow/<name>.json
```

### Running specific stages

```bash
python3 -m vakedc parse   file.vaked --print          # Stage 1-2: just parse
python3 -m vakedc check   file.vaked                   # Stage 1-4: parse+check
python3 -m vakedc lower   file.vaked --out /tmp/out    # Stage 1-5: full pipeline
python3 -m vakedc passes  file.vaked --json             # Stage 1-4 + pass pipeline
```

---

## 5. MLIR Layer — Pass Pipeline

### Stage 0 (Python, working)

The `vakedc/passes/` package implements a reference pass pipeline that
mirrors the planned MLIR dialect passes. Three passes run in order:

| Pass | Spec | What it does | Output |
|------|------|-------------|--------|
| 1 — TopologyAnalysis | 0021 | DFS cycle detection, critical-path depth, maxDepth bound | Diagnostics (E-WORKFLOW-CYCLE, E-WORKFLOW-DEPTH) |
| 2 — WALInjection | 0022 | Inject WAL frames per dependency edge | wal_frames on WorkflowIR |
| 3 — AOTIndexGeneration | 0023 | Emit supervisor index JSON | gen/workflow/<name>.json |

```bash
# Run passes on a file
python3 -m vakedc passes vaked/examples/my-workflow.vaked --json

# Run the differential test corpus
python3 tests/corpus/0024-differential/run_corpus.py

# Expected output: 10/10 fixtures PASS
#   lower+determinism: 4 fixtures
#   passes (depth/WAL/artifact): 4 fixtures
#   reject (cycle/depth): 2 fixtures
```

### Adding a new pass

1. Create `vakedc/passes/pass04_*.py` with a `run(graph, workflows)` method
2. Wire it into `vakedc/passes/__init__.py` in `run_pipeline()`
3. Add expected-depth/WAL values to `PASS_EXPECTED` in `run_corpus.py`
4. Add a fixture to `tests/corpus/0024-differential/fixtures/`
5. Verify: `python3 tests/corpus/0024-differential/run_corpus.py`

### Stage 1 (MLIR C++, buildable on Linux)

The `vakedc/mlir/` directory holds TableGen dialect definitions and C++
implementations. Two build methods:

#### Method A: Reproducible Nix build (preferred)

```bash
# From repo root — fully isolated, deterministic, uses pre-built MLIR
nix build .#vaked-mlir
# Output: result/lib/libVakedMLIRDialects.a + result/include/*.inc
```

This is a proper Nix derivation (`nix/vaked-mlir.nix`). It uses the
pre-built MLIR package from nixpkgs — no LLVM source build, no network
during build, byte-identical across machines. This is the method that
reflects Vaked's own principles: reproducible and deterministic.

#### Method B: From-source build (for development)

```bash
# On dev-cx53 (Linux x86_64, builds LLVM MLIR from source):
bash tools/build-mlir-stage1.sh

# Or step by step (inside nix develop):
cd vakedc/mlir && cmake -G Ninja -B build \
  -DMLIR_DIR=$(mlir-tblgen --print-mlir-dir) && ninja
```

The build produces:
- `build/generated/VakedDialect.h.inc` / `.cpp.inc`
- `build/generated/HcpDialect.h.inc` / `.cpp.inc`
- `build/lib/libVakedMLIRDialects.a`

### Differential testing (0024)

When Stage-1 MLIR is built, the corpus harness gets a `lower_stage1()` leg:

```
For each fixture:
  A_0 = Stage-0(vakedc passes --json)   # running Python
  A_1 = Stage-1(mlir-run-pass --json)   # running C++
  compare(A_0, A_1)                     # must be observationally equivalent
```

The comparison excludes `provenance.json` paths/hashes (they differ by
host) and compares only semantic artifacts:
`gen/workflow/*.json`, `gen/eventd.json`, `flake.nix`, `gen/RUNTIME.md`.

See `docs/language/0024-mlir-lowering-staged-adoption.md §2.1`.

---

## 6. Testing — What Goes Where

| Test type | Location | How to run |
|-----------|----------|------------|
| Spec tests (grammar, types) | `tests/spec/` | `python3 -m pytest tests/spec/` |
| Differential corpus | `tests/corpus/0024-differential/` | `python3 tests/corpus/0024-differential/run_corpus.py` |
| Golden fixtures | `vaked/examples/lowering/` | Checked by spec tests |
| vakedc unit tests | Inline in modules | `python3 -m doctest vakedc/*.py` |
| vakedz unit tests | `vakedz/test/` | `cd vakedz && zig build test` |
| MLIR TableGen | `vakedc/mlir/run_tests.sh` | `bash vakedc/mlir/run_tests.sh` |
| CI (GitHub Actions) | `.github/workflows/` | Push PR — see `ci-gate.yml`, `vakedz-ci.yml`, `corpus-0024.yml` |

### Adding a test fixture for passes

```bash
# 1. Create fixture
cat > tests/corpus/0024-differential/fixtures/my-topology.vaked << 'EOF'
runtime "my-topology" {
  systems = ["x86_64-linux"]
  mesh f { node a { role = "work" capabilities = [fs.repo_ro] } }
  workflow wf {
    maxDepth = N
    node A { agent = f.a }
    ...
    A -> B
  }
}
EOF

# 2. Add expected values in run_corpus.py
#    PASS_EXPECTED.append(("my-topology.vaked", exp_depth, exp_wal))

# 3. Run
python3 tests/corpus/0024-differential/run_corpus.py
```

---

## 7. Live Coding Workflow

For rapid iteration on the compiler:

```bash
# Parse + print JSON graph (fastest feedback)
python3 -m vakedc parse my.vaked --print | jq '.nodes[] | {id, kind, name}'

# Check with structured diagnostics
python3 -m vakedc check my.vaked --json | jq '.diagnostics[]'

# Full lowering pipeline
python3 -m vakedc lower my.vaked --out /tmp/lower && ls -la /tmp/lower/

# Pass pipeline with structured output
python3 -m vakedc passes my.vaked --json | jq '.workflows[0]'

# Watch mode (incremental re-check on save, requires entr)
find . -name '*.py' -o -name '*.vaked' | entr -c python3 -m vakedc check my.vaked
```

---

## 8. Contribution Workflow (for language/compiler)

1. **Open an issue** — describe the gap. Labels: `language` for grammar changes,
   `design` for spec-only, `track:mlir` for pass changes.
2. **Write the spec first** — EBNF grammar update + design doc in `docs/language/`
   or `protocol/rfcs/` if it touches the wire protocol.
3. **Use the skills** — `vaked-language-author` for grammar changes,
   `hcp-rfc-author` for protocol RFCs, `caveman` for dense technical notes.
4. **Implement** — parser → checker → lowerer → passes, in that order.
5. **Test** — spec tests + corpus + golden fixtures.
6. **PR** — the CI runs `corpus-0024.yml` (10 fixtures), `vakedz-ci.yml`, and
   `ci-gate.yml` (spec tests). All must pass.

### Quick reference: when to update what

| You change... | Also update |
|-------------|------------|
| EBNF grammar | `parser.py`, `check.py` (if new constraints) |
| A schema in `builtins.vaked` | `lower.py` (if new emit fields) |
| A checker rule in `check.py` | `tests/spec/` (positive + negative cases) |
| An emitter in `lower.py` | Golden fixtures in `tests/` |
| The pass pipeline | `run_corpus.py` expected values |
| A `.td` dialect file | `mlir-tblgen` output changes (re-generate `.inc`) |

---

## 9. Design Docs Index (Language & MLIR)

| Doc | Title | Status |
|-----|-------|--------|
| 0001 | Manifesto | ✅ Accepted |
| 0002 | Primitives | ✅ Accepted |
| 0008 | Parallel, fibers, indexes, surfaces | ✅ Accepted |
| 0010 | MirageOS unikernel surface | ✅ Accepted |
| 0011 | Type system (0011) | ✅ Accepted |
| 0012 | Lowering (0012) | ✅ Accepted |
| 0013 | MLIR topology compilation | ✅ Accepted |
| 0014 | Memory primitive | ✅ Accepted |
| 0015 | Workflow primitive | ✅ Accepted |
| 0018 | Compiler architecture | ✅ Accepted |
| 0019 | vaked MLIR dialect | ✅ Accepted |
| 0020 | hcp MLIR dialect | ✅ Accepted |
| 0021 | Pass 1: topology analysis | ✅ Accepted |
| 0022 | Pass 2: WAL injection | ✅ Accepted |
| 0023 | Pass 3: AOT supervisor index | ✅ Accepted |
| 0024 | Staged MLIR adoption | ✅ Accepted |

---

## 10. Common Tasks — Cheat Sheet

```bash
# "How do I see the LPG for this file?"
python3 -m vakedc parse my.vaked --print | jq '.nodes[] | {id, kind, name, props}'

# "Does this grammar change parse correctly?"
python3 -m vakedc parse my-test.vaked

# "Add a new workflow topology fixture"
cp tests/corpus/0024-differential/fixtures/diamond.vaked \
   tests/corpus/0024-differential/fixtures/my.vaked
# edit my.vaked, then add to PASS_EXPECTED in run_corpus.py

# "Run just the pass pipeline tests"
python3 -c "
from vakedc.passes import PassPipeline as P
from vakedc import parse_source, build_graph
# ... inline test code ...
"

# "Check if my MLIR .td files are valid TableGen"
mlir-tblgen --gen-op-defs vakedc/mlir/VakedDialect.td > /dev/null && echo "valid"

# "Build the MLIR library on dev-cx53"
bash tools/build-mlir-stage1.sh
```

---

## See Also

- `CLAUDE.md` — project-wide conventions, agent fleet, CI
- `CONTRIBUTING.md` — general contribution guidelines
- `docs/language/` — all 24 language design docs
- `docs/context/PROJECT_CONTEXT.md` — high-level project overview
