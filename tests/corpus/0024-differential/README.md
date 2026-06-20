# 0024 differential test corpus

Runnable oracle for the §11 verification checklist of
`docs/language/0024-mlir-lowering-staged-adoption.md`. Closes claim C14.

Design: `docs/superpowers/specs/2026-06-14-0024-differential-corpus-design.md`.

## Run

From the repo root:

```
python3 tests/corpus/0024-differential/run_corpus.py
```

Stdlib only; no build, no install. Exits nonzero if any fixture fails and prints
a per-fixture PASS/FAIL table.

## What it proves today (Stage-0 leg)

Stage-0 is the pure-Python `vakedc` pipeline (`parse -> check -> lower`).

- **Determinism.** Each should-lower fixture (`single-agent`, `linear-chain`,
  `diamond`, `depth-bound-ok`) is lowered into two temp dirs from the same
  source path; the two trees are compared byte-for-byte and must be identical.
- **Correct rejection.** `cyclic` and `depth-bound-exceeded` are run through
  `vakedc check --json`; the harness asserts exit 1 and that the expected
  diagnostic code (`E-WORKFLOW-CYCLE`, `E-WORKFLOW-DEPTH`) is present.

This makes the §11 **Determinism** box tickable and pins the Stage-0 rejection
baseline for §13.1 soundness.

## What it will prove when Stage-1 exists

Stage-1 (the C++/MLIR `vaked`/`hcp` dialects + passes) does not exist yet. When
it does, the harness gains a `lower_stage1()` leg and a cross-stage comparator
(see the module docstring in `run_corpus.py` and §4/§5 of the design doc). That
flips the comparative §11 boxes: dialect verifiers, Pass 1 cycle/depth parity,
Pass 2/3 structure parity, and Stage-0↔Stage-1 round-trip equivalence.

Note: the cross-stage compare is **not** a naive whole-tree byte-compare -
`provenance.json` embeds the absolute source path + a derived `inputsHash`,
which differ by host. The comparator must exclude those or compare only the
semantic artifacts. See the design doc canonicalization note.

## Where each leg runs

- **Stage-0 leg (this harness):** pure stdlib Python - runs anywhere (laptop or
  CI).
- **Future Stage-1 leg (C++/MLIR):** MUST build and run on **dev-cx53**, never on
  the developer MacBook (project no-build-on-laptop rule). The Stage-0
  assertions stay valid on either host.

## Layout

```
fixtures/                      6 fixtures over 5 topology classes
  single-agent.vaked           1 node, no edges
  linear-chain.vaked           A -> B -> C
  diamond.vaked                A->B, A->C, B->D, C->D
  depth-bound-ok.vaked         3-step chain, maxDepth = 3 (== depth, accepts)
  depth-bound-exceeded.vaked   3-step chain, maxDepth = 2 (< depth, rejects)
  cyclic.vaked                 A -> B -> C -> A (rejects)
run_corpus.py                  the harness
```
