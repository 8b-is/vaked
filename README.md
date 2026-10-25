# vaked

**A flake-native capability-graph language.** You write a declarative `.vaked`
file describing a system's capabilities — its meshes, streams, engines,
runtimes, capability grants — and the compiler turns it into a typed semantic
graph, checks it against a closed, deterministic type system, then lowers the
graph into real artifacts: `flake.nix`/NixOS modules, Zig daemon configs, eBPF
policy manifests, OTel config, CrabCC indexes, and generated docs.

> Vaked declares. Nix materializes. OTP supervises. Zig enforces. eBPF testifies.

This README is meant to be read top to bottom as documentation, not just a
landing page — it covers the grammar, the type system, the pipeline, and has
worked examples with real compiler output (not illustrative pseudo-output;
every code block below is copy-pasted from actually running `bin/vaked`
against the files in this repo).

## Table of contents

- [Why](#why)
- [Install](#install)
- [30-second tour](#30-second-tour)
- [The pipeline: parse → check → lower](#the-pipeline-parse--check--lower)
- [Language tour](#language-tour)
  - [Declarations](#declarations)
  - [Capabilities and attenuation](#capabilities-and-attenuation)
  - [Mesh: nodes and edges](#mesh-nodes-and-edges)
  - [Namespaces](#namespaces)
  - [A worked failure: what `check` catches](#a-worked-failure-what-check-catches)
  - [A full runtime example](#a-full-runtime-example)
- [The type system](#the-type-system)
- [Lowering](#lowering)
- [CLI reference](#cli-reference)
- [Two implementations: vakedc and vakedz](#two-implementations-vakedc-and-vakedz)
- [Repo layout](#repo-layout)
- [Testing](#testing)
- [Design docs](#design-docs)
- [Status / known limitations](#status--known-limitations)
- [License](#license)

## Why

Flakes, NixOS modules, daemon configs, eBPF policies, and OTel config for one
"system" (a fleet of agents, a mesh of services, a media pipeline) usually
live as five hand-synced artifacts in five different syntaxes, each capturing
a partial, drifting view of the same intent. Vaked is the single declarative
source of truth: one `.vaked` file, one typed graph, N generated artifacts —
each byte-identical for a given input, each traceable back to the declaration
that produced it via `provenance.json`.

The type system's centerpiece is a **capability attenuation check**: every
edge in a mesh (`author -> reviewer`) is checked so a receiver can never end
up with *more* authority than the sender granted, per capability domain. This
is POLA (principle of least authority) enforced at compile time, not by
convention.

## Install

No dependencies beyond a Python 3.9+ stdlib for the reference compiler
(`vakedc`); the Zig port (`vakedz`) needs Zig 0.16+.

```sh
git clone https://github.com/8b-is/vaked
cd vaked
export PATH="$PWD/bin:$PATH"
vaked env
```

Or via Nix:

```sh
nix develop            # drops you into a shell with bin/vaked on PATH
nix build .#vakedz      # builds the Zig port
```

## 30-second tour

```sh
$ vaked check vaked/examples/primitives/mesh.vaked
vakedc: mesh.vaked — no diagnostics
✓ check 177ms

$ vaked check vaked/examples/types/rejected.vaked
vaked/examples/types/rejected.vaked:32:3: error: E-CAP-ATTENUATION: delegation `author -> reviewer` escalates authority: receiver holds `fs.repo_rw` but sender holds fs.repo_ro (receiver's grant must be ≤ the sender's in domain `fs`) [mesh reviewField]
vaked/examples/types/rejected.vaked:41:9: error: E-CONSTRAINT-RANGE: field `fps`: value 0 violates `> 0` [stream telemetry]
vaked/examples/types/rejected.vaked:45:3: error: E-CONFORM-UNKNOWN-FIELD: `colour` is not a declared field of closed schema `stream` [stream telemetry]
✗ check 117ms (exit 1)
```

Three distinct diagnostic classes in one run: a capability-attenuation
violation, a constraint-range violation, and an unknown-field violation
against a *closed* schema. All three are structural — no test suite, no
runtime assertion, caught before anything is generated.

## The pipeline: parse → check → lower

```
  .vaked source
       │
       ▼
   ┌───────┐   lexer + grammar (vaked/grammar/vaked-v0-plus.ebnf, v0.3, 29 kinds)
   │ parse │   → Labeled Property Graph (LPG): nodes, edges, records
   └───┬───┘
       ▼
   ┌───────┐   resolve refs → elaborate → check against closed schema +
   │ check │   capability taxonomy + attenuation partial order (docs/language/0011)
   └───┬───┘   total + deterministic: same input ⇒ same diagnostics, always
       ▼
   ┌───────┐   pure, total, hermetic function of (validated graph + pinned
   │ lower │   inputs) → gen/ artifacts + flake.nix/NixOS spine (docs/language/0012)
   └───┬───┘   same graph ⇒ byte-identical output; provenance recorded per-artifact
       ▼
  flake.nix · NixOS modules · Zig daemon configs · eBPF manifests ·
  OTel config · CrabCC indexes · docs
```

Every stage is exposed as its own CLI command (`parse`, `check`, `lower`), and
`all` runs the full pipeline with per-stage timing. `check` refuses to run
`lower` if there are outstanding diagnostics — you cannot generate artifacts
from a graph that doesn't type-check.

## Language tour

### Declarations

A `.vaked` file is a sequence of top-level **kind** declarations. There are
29 kinds in the current grammar (v0.3), including:

```text
runtime  system   engine   host      network   filesystem   mcp
ebpf     budget   observability   runclass   workflow   index
catalog  stream   fiber    surface   mesh      device    mediaPipeline
parallel service  secret   hostResource   ingress   container   memory
namespace  capability
```

Every declaration follows one uniform shape (the `app` rule): a dotted
reference, an optional `(args)` call, and an optional `{ record }` body — so a
bare reference, a function call, and a config block are all one grammar
production, not three:

```text
ref [ "(" args ")" ] [ record ]
```

### Capabilities and attenuation

A `capability` block declares a domain, its grant levels, and the partial
order between them:

```vaked
capability fs {
  grant none repo_ro repo_rw host_ro host_rw
  order none < repo_ro < repo_rw < host_rw ;
        repo_ro < host_ro < host_rw
}
```

Any `mesh` edge between two nodes is checked against this order: the
receiving node's grant in a domain must be `<=` the sending node's grant in
that same domain. This is what caught the violation in the 30-second tour
above.

### Mesh: nodes and edges

```vaked
mesh agentfield {
  node codex {
    role = "worker"
    capabilities = [fs.repo_rw, mcp.github_read]
  }

  node redteam {
    role = "reviewer"
    capabilities = [fs.repo_ro, network.none]
  }

  codex -> mcpBroker
  redteam -> eventd
  mcpBroker -> eventd : "audit"
}
```

`node` declarations and `->` edges are first-class grammar (the same `mesh`
production underlies any graph-shaped kind), and an edge can carry a label
(`: "audit"`) for provenance/documentation.

### Namespaces

`namespace` (v0.4, RFC 0017) names a value-namespace head — a daemon channel
set, an external service, or an open namespace like `pkgs` — and either opens
it (`open`, any member accepted) or closes it to an enumerated `member` set:

```vaked
namespace agentGuardd {
  member ringbuf
}
namespace agentpipe {
  member transcripts
  member screenrec
}
```

Every dotted reference elsewhere in the file (`agentGuardd.ringbuf`) is
checked against the in-scope namespace roster — referencing an undeclared
member is a compile error (`E-CONFORM-UNKNOWN-FIELD`-class diagnostic), not a
runtime surprise.

### A worked failure: what `check` catches

[`vaked/examples/types/rejected.vaked`](vaked/examples/types/rejected.vaked)
is a companion fixture to
[`vaked/examples/types/conformant.vaked`](vaked/examples/types/conformant.vaked)
— same shapes, deliberately broken in three independent ways:

```vaked
mesh reviewField {
  node author    { role = "author";   capabilities = [fs.repo_ro] }
  node reviewer  { role = "reviewer"; capabilities = [fs.repo_rw] }
  author -> reviewer : "handoff"    # reviewer ends up with MORE authority than author
}

stream telemetry {
  source = agentGuardd.ringbuf
  type   = Event.Ebpf
  fps    = 0        # violates the schema constraint `fps > 0`
  colour = "grey"   # `stream` is a CLOSED schema; `colour` isn't a declared field
}
```

Running `vaked check` on it produces exactly the three diagnostics shown in
the [30-second tour](#30-second-tour), each with a precise line:column, an
error code (`E-CAP-ATTENUATION`, `E-CONSTRAINT-RANGE`,
`E-CONFORM-UNKNOWN-FIELD`), and the offending decl. `vaked check --json`
gives the same information machine-readable, for CI/agent consumption.

### A full runtime example

[`vaked/examples/operator-field.vaked`](vaked/examples/operator-field.vaked)
is the flagship worked example threaded through the design docs
(`docs/language/0012-lowering.md`) — a `runtime` combining namespaces,
indexes over external sources, streams, a `fiber` (a media-compression job
running on a Zig engine), a `surface` (a live operator dashboard), and a
`parallel` block supervising it all:

```vaked
use "./engines/zig.vaked"

runtime "operator-field" {
  systems = ["x86_64-linux", "aarch64-linux"]

  namespace agentGuardd { member ringbuf }
  namespace agentpipe   { member transcripts; member screenrec }

  index zigCorpus {
    source    = [github("Sobeston/zig.guide"), github("C-BJ/awesome-zig")]
    normalize = crabcc.markdown
    emit      = [catalog.jsonl, catalog.sqlite, nix.derivation]
  }

  stream screenrec {
    source = agentpipe.screenrec
    type   = Media.Frame
    fps    = 10
  }

  fiber mediaCompress {
    engine = zigDaemon
    input  = stream.screenrec
    output = artifacts.compressedMedia
    policy { strip_metadata = true; max_pixels = "4K"; formats = ["png", "webp"] }
  }

  surface operatorMap {
    mode  = raylib
    fps   = 60
    input = [stream.ebpfEvents, graph.workflow, graph.agentfield]
    views = ["network-flows", "workflow-dag", "filesystem-diff", "mesh-topology"]
  }

  parallel "operator-runtime" {
    fibers     = [mediaCompress, operatorMap]
    strategy   = "supervised-dag"
    supervisor = otp
  }
}
```

```sh
$ vaked check vaked/examples/operator-field.vaked
vakedc: operator-field.vaked — no diagnostics
✓ check 124ms
```

`docs/language/0012-lowering.md` §5 specifies, field-by-field, the exact
artifacts this graph lowers to: a `gen/zig/mediaCompress.json` engine config,
a `gen/catalog/zigCorpus.jsonl` index catalog (line 1 is a `_generated`
header, every subsequent line valid JSON), and a `gen/RUNTIME.md` +
`flake.nix` pair (the Nix spine, pinned to a 40-hex `nixpkgs` revision — no
moving branch refs) — each carrying a generated-by-Vaked header and each
provenance-tracked back to the declaration span that produced it.

## The type system

Specified normatively in
[`docs/language/0011-type-system.md`](docs/language/0011-type-system.md).
The short version:

- **Structural typing** with per-kind schema contracts (`vaked/schema/`) —
  a `stream` has exactly the fields `source`, `type`, `retention`, `fps`
  and no others.
- **Closed** constraint sets — a schema doesn't merely *validate* the fields
  you gave it, it rejects fields it doesn't know about
  (`E-CONFORM-UNKNOWN-FIELD`).
- **A typed capability taxonomy** with an attenuation **partial order**
  per domain, checked at every mesh edge (`E-CAP-ATTENUATION`) — this is
  POLA enforced structurally, at type-check time.
- **Bounded generics** for parameterized decls (`engine
  zigDaemon(name: String, src: Path) -> Engine`).
- **Total and deterministic**: parse → resolve → elaborate → check always
  terminates, and the same input always produces the same diagnostics —
  no flaky checker.

## Lowering

Specified normatively in
[`docs/language/0012-lowering.md`](docs/language/0012-lowering.md). Lowering
is a **pure, total, hermetic** function of (validated graph, pinned inputs):
no network or IO happens during lowering itself (fetching/building is the
*Nix build's* job, pinned via `flake.lock` from a declared
`trust = pinned { commit = "…"; sha256 = "…" }`). One emitter per declared
`emit` target; every artifact is provenance-tracked
(`.vaked/provenance.json`: `sourceFile`, `decl`, `span`, `emitter`,
`inputsHash` per artifact) and carries a generated-by-Vaked header.

## CLI reference

```
$ vaked help
vaked — Vaked compiler CLI  (agent-optimized)

PIPELINE COMMANDS
  parse   <file>        Parse .vaked → LPG  (.vaked/graph.json + .db)
  check   <file>        Type-check (0011 type system, stages 3–4)
  lower   <file>        Full pipeline → artifacts  (refuses on any diagnostic)
  all     <file>        parse → check → lower with per-stage timing
  lint    <file>        check --json; exits 0/1/2  (agent-safe alias)
  bench   <file>        Benchmark N runs — JSON timing stats to stdout
  audit   <file>        Full pipeline + JSONL record to stdout and audit log
  verify  <file>        Standalone verify: provenance hash + audit chain

INSPECTION COMMANDS
  grammar               Print grammar path; --ebnf dumps full EBNF text
  schema  [kind]        Dump builtins catalog; filter by kind keyword
  examples              List .vaked examples; --run <name> runs one via 'all'
  env                    Print toolchain paths, versions, repo rev

FLAGS
  --json          Machine-readable JSON to stdout
  -q, --quiet     Suppress step headers; errors only
  --out DIR       Lowering / docs output dir
  --verify        After lower/all: verify provenance source hash
```

Run `vaked help` for the full reference (lifecycle, runtime, and doc
commands — install/upgrade, gateway/webhook/mcp servers, man page, docs
site).

Exit codes: `0` clean, `1` diagnostic/semantic error, `2` usage/parse/IO
error — stable across every pipeline command, so `vaked lint` is safe to
gate CI on directly.

## Two implementations: vakedc and vakedz

- **`vakedc`** ([`vakedc/`](vakedc/)) — the original Python prototype
  front-end: parse → check → lower, stdlib-only, no dependencies. This is
  the reference implementation and what `bin/vaked` drives today.
- **`vakedz`** ([`vakedz/`](vakedz/)) — a Zig port of the same pipeline,
  built for speed and cache-native incremental builds, sharing a common
  [`lib/`](lib/) package (`span`, `diagnostic`, `json`, `cache`, `graph`)
  with the eventual daemon runtime. Mid-port: `zig build test` runs the
  full lib + vakedz test suite against every change.

```sh
zig build          # builds the vakedz binary → zig-out/bin/vakedz
zig build test     # lib tests + vakedz tests
zig build check    # zig fmt --check across build.zig / lib / vakedz
```

## Repo layout

```
vaked/
├── grammar/                 EBNF grammar (vaked-v0-plus.ebnf, v0.3, 29 kinds)
├── schema/                  built-in per-kind schema + capability catalog
├── examples/                worked .vaked programs (primitives, types, v0.5, …)
└── designs/                 larger design-level .vaked programs

vakedc/                      reference compiler (Python, stdlib-only)
├── lexer.py  parser.py      parse
├── resolve.py  check.py     check (ref resolution, type/capability checking)
├── lower.py  emit.py        lower (artifact emission)
├── graph.py                 the Labeled Property Graph (LPG)
├── passes/                  MLIR-mirror pass pipeline (topology → WAL → AOT)
└── mlir/                    TableGen dialect defs for the MLIR backend

vakedz/                      Zig port of the same pipeline (mid-port)
lib/                         shared Zig package vakedz builds on

docs/
├── language/                normative RFCs, 0001…0028 + THREAT_MODEL, RELATED_WORK
├── compiler/                optimization roadmap
└── context/                 compiler dev guide

tests/
├── spec/                    grammar/lexer/parser/lowering test suite
└── corpus/                  differential test fixtures

bin/vaked                    CLI entrypoint
```

## Testing

```sh
PYTHONPATH=. python3 tests/spec/run_all.py          # full Python test suite
PYTHONPATH=. python3 tests/spec/run_all.py --tier smoke     # grammar + examples + doc links, <60s
zig build test                                        # Zig lib + vakedz tests
```

Scale-tested to 100k workers @ 273ms average, deterministic (1M projected) —
see [`vaked/examples/swe-swarm-100k-workers-scalability.vaked`](vaked/examples/swe-swarm-100k-workers-scalability.vaked).

Worked example: [`vaked/examples/wip-catalog/`](vaked/examples/wip-catalog/)
draws the 8b-is work-in-progress catalog (223 rows, nine lanes) as a mesh where
`named < verified` is a *capability order*. Naming a research substrate is not
evidence that it was verified, so the compiler — not the prose — decides which
lane may claim a verified bound. It checks clean, and it is also the smallest
honest demonstration of `W-CONFUSED-DEPUTY`: the first draft had nine lanes
writing through one shared ledger, which is the routing/adjudication collapse in
graph form. See
[`WIP-CATALOG.md`](vaked/examples/wip-catalog/WIP-CATALOG.md).

## Design docs

New language constructs always go grammar-first (EBNF + example) before code.
The normative design track lives in [`docs/language/`](docs/language/):

- [`0001-language-manifesto.md`](docs/language/0001-language-manifesto.md) — why Vaked exists
- [`0011-type-system.md`](docs/language/0011-type-system.md) — the type system (Goal 2)
- [`0012-lowering.md`](docs/language/0012-lowering.md) — lowering semantics (Goal 3)
- [`0017-namespace-roster.md`](docs/language/0017-namespace-roster.md) — the `namespace` kind
- [`0019`–`0024`](docs/language/) — the MLIR-mirror pass pipeline (topology analysis, WAL injection, AOT supervisor index, staged adoption)
- [`0026`–`0028`](docs/language/) — capability reachability, POLA formalization, network-membrane POLA
- [`THREAT_MODEL.md`](docs/language/THREAT_MODEL.md), [`RELATED_WORK.md`](docs/language/RELATED_WORK.md) — see also `docs/language/README.md` for the full index

## Status / known limitations

- `parse` and `check` are implemented and exercised by the full example
  corpus and differential test suite — the diagnostics shown in this README
  are real compiler output, not illustrative.
- `lower` is normatively specified (`0012-lowering.md`) with hand-authored,
  test-verified fixture output for the canonical `operator-field.vaked`
  example, but emitter coverage for arbitrary programs is still landing —
  `vaked lower` on many example files currently produces an empty
  `provenance.json` rather than full artifacts. Track progress in
  `docs/language/0012-lowering.md` and `docs/compiler/OPTIMIZATION_ROADMAP.md`.
- `vakedz` (the Zig port) is mid-port: `lib/` and the core pipeline build and
  test cleanly, but it does not yet have full parity with `vakedc`.
- A handful of `docs/language/*.md` RFCs link to sibling subsystems
  (`protocol/`, `superpowers/`, `runtime/`) that lived in the monorepo this
  language was extracted from and aren't included here; `tests/spec/test_doc_links.py`
  flags these as unresolved until the links are rewritten or those docs are ported.

## License

MIT — see [LICENSE](LICENSE).

---

## Honorary

For the constants that never change:

- **π** — the circle, the wave, the recursion that folds back
- **e** — the base of natural growth, the limit of compounding
- **i** — the imaginary unit, the axis of rotation
- **φ** — the golden ratio, the proportion that pleases the eye
- **∞** — there is no bottom. It folds back.
- **Paul Erdős** — eternal love. The old dog. 1913–1996.
- **all** — every honest node in the capability graph
