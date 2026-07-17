#!/usr/bin/env python3
"""test_vakedc_passes.py — spec tests for the MLIR-mirror pass pipeline
(`vakedc passes`, 0021--0024).

WHY THIS MODULE EXISTS (the assertion that was missing):

  tests/corpus/0024-differential/run_corpus.py asserts only that cyclic.vaked is
  rejected with the CODE `E-WORKFLOW-CYCLE`. It never looks at the message. That
  gap let a real nondeterminism bug live in `pass01_topology.py` unnoticed: the
  DFS roots were iterated over the `step_names` SET, and Python's set iteration
  order for strings depends on PYTHONHASHSEED, so the ROTATION of the reported
  cycle changed run-to-run. All three rotations of cyclic.vaked were observed
  across seeds:

      PYTHONHASHSEED=3 -> "cycle: A -> B -> C -> A"
      PYTHONHASHSEED=0 -> "cycle: B -> C -> A -> B"
      PYTHONHASHSEED=1 -> "cycle: C -> A -> B -> C"

  The fix iterates `steps` (a list, declaration order). This module locks the
  EXACT message, and re-runs it under several PYTHONHASHSEEDs in SUBPROCESSES —
  the seed is fixed at interpreter start, so an in-process loop could not test
  this. Seeds 0, 1 and 3 cover every rotation that was observed in the wild.

  A diagnostic that disagrees with itself run-to-run violates the reproducibility
  the 0024 corpus exists to prove (§2.2 / §11 Determinism), so the message is
  part of the output contract, not cosmetic.

Test groups:
  1. Cycle message is EXACT and byte-identical across PYTHONHASHSEEDs.
  2. The whole `passes --json` document is byte-identical across PYTHONHASHSEEDs
     for every corpus fixture (the general determinism claim, not just cycles).
  3. The topology oracle: depth / criticalPath / walFrames / artifacts / status
     per topology class.
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
FIXTURES = os.path.join(REPO, "tests", "corpus", "0024-differential", "fixtures")

# Every rotation observed in the wild before the fix: 3 -> A.., 0 -> B.., 1 -> C..
SEEDS = ("0", "1", "3")

# The exact, deterministic cycle diagnostic for cyclic.vaked (A -> B -> C -> A
# declared in that order, with the back-edge C -> A).
EXPECTED_CYCLE_MESSAGE = (
    "workflow `wf` step edges must form a DAG; cycle: A -> B -> C -> A "
    "(express revision loops as `retries` on a step, not back-edges)"
)


def _run_passes(fixture, seed=None):
    """Run `python3 -m vakedc passes --json <fixture>` in a subprocess.

    A subprocess is REQUIRED for the seed sweep: PYTHONHASHSEED is read once at
    interpreter startup, so it cannot be varied in-process.
    """
    env = dict(os.environ)
    if seed is not None:
        env["PYTHONHASHSEED"] = seed
    else:
        env.pop("PYTHONHASHSEED", None)
    return subprocess.run(
        [sys.executable, "-m", "vakedc", "passes", "--json",
         os.path.join(FIXTURES, fixture)],
        cwd=REPO, capture_output=True, text=True, env=env,
    )


def _test_cycle_message_exact(lines):
    """Group 1 — the exact cycle message, under every observed-rotation seed."""
    ok = True
    seen = {}
    for seed in SEEDS:
        r = _run_passes("cyclic.vaked", seed)
        if r.returncode != 1:
            lines.append(f"    FAIL cyclic.vaked seed={seed}: expected exit 1, "
                         f"got {r.returncode}")
            ok = False
            continue
        try:
            doc = json.loads(r.stdout)
        except Exception as e:
            lines.append(f"    FAIL cyclic.vaked seed={seed}: unparseable JSON: {e}")
            ok = False
            continue
        diags = doc.get("diagnostics", [])
        if len(diags) != 1 or diags[0].get("code") != "E-WORKFLOW-CYCLE":
            lines.append(f"    FAIL cyclic.vaked seed={seed}: expected exactly one "
                         f"E-WORKFLOW-CYCLE, got {[d.get('code') for d in diags]}")
            ok = False
            continue
        msg = diags[0].get("message")
        seen[seed] = msg
        if msg != EXPECTED_CYCLE_MESSAGE:
            lines.append(f"    FAIL cyclic.vaked seed={seed}: cycle message differs")
            lines.append(f"      expected: {EXPECTED_CYCLE_MESSAGE!r}")
            lines.append(f"      actual  : {msg!r}")
            ok = False

    distinct = set(seen.values())
    if len(distinct) > 1:
        lines.append(f"    FAIL cycle message is PYTHONHASHSEED-dependent — "
                     f"{len(distinct)} distinct messages across seeds {SEEDS}:")
        for seed, msg in sorted(seen.items()):
            lines.append(f"      seed={seed}: {msg!r}")
        ok = False

    if ok:
        lines.append(f"    cycle message exact + identical across "
                     f"{len(SEEDS)} PYTHONHASHSEEDs {SEEDS}")
    return ok


def _test_document_seed_stable(lines):
    """Group 2 — the WHOLE document is byte-stable across seeds, every fixture.

    Broader than group 1: catches any future hash-order leak into `passes`
    output, not just the cycle-rotation class.
    """
    ok = True
    fixtures = sorted(f for f in os.listdir(FIXTURES) if f.endswith(".vaked"))
    if len(fixtures) < 6:
        lines.append(f"    FAIL only {len(fixtures)} fixtures found (< 6) — "
                     f"fixture set is broken")
        return False
    for fixture in fixtures:
        outs = {}
        for seed in SEEDS:
            r = _run_passes(fixture, seed)
            outs[seed] = r.stdout
        distinct = set(outs.values())
        if len(distinct) != 1:
            lines.append(f"    FAIL {fixture}: passes --json output differs across "
                         f"seeds ({len(distinct)} distinct)")
            for seed, out in sorted(outs.items()):
                lines.append(f"      seed={seed}: {out[:200]!r}")
            ok = False
    if ok:
        lines.append(f"    {len(fixtures)} fixtures: passes --json byte-identical "
                     f"across seeds {SEEDS}")
    return ok


# (fixture, exit, depth, criticalPath, wal frame count, artifacts, status)
TOPOLOGY_ORACLE = [
    ("single-agent.vaked",         0, 1, ["s1"],          0, ["gen/workflow/wf.json"], "PASS"),
    ("linear-chain.vaked",         0, 3, ["A", "B", "C"], 2, ["gen/workflow/wf.json"], "PASS"),
    ("diamond.vaked",              0, 3, ["A", "B", "D"], 4, ["gen/workflow/wf.json"], "PASS"),
    ("depth-bound-ok.vaked",       0, 3, ["A", "B", "C"], 2, ["gen/workflow/wf.json"], "PASS"),
    # Topology-rejected IRs keep their Pass-1 depth/criticalPath but get NO WAL
    # frames and NO artifacts (passes/__init__.py:69-81, 0024 §2.1).
    ("depth-bound-exceeded.vaked", 1, 3, ["A", "B", "C"], 0, [],                       "FAIL"),
    ("cyclic.vaked",               1, 0, [],              0, [],                       "FAIL"),
]


def _test_topology_oracle(lines):
    """Group 3 — per-topology-class depth / path / WAL / artifacts / status."""
    ok = True
    for fixture, rc, depth, path, nwal, artifacts, status in TOPOLOGY_ORACLE:
        r = _run_passes(fixture)
        if r.returncode != rc:
            lines.append(f"    FAIL {fixture}: expected exit {rc}, got {r.returncode}")
            ok = False
            continue
        doc = json.loads(r.stdout)
        wfs = doc.get("workflows", [])
        if len(wfs) != 1:
            lines.append(f"    FAIL {fixture}: expected 1 workflow, got {len(wfs)}")
            ok = False
            continue
        wf = wfs[0]
        for label, actual, expected in (
            ("depth", wf.get("depth"), depth),
            ("criticalPath", wf.get("criticalPath"), path),
            ("walFrames", len(wf.get("walFrames", [])), nwal),
            ("artifacts", doc.get("artifacts"), artifacts),
            ("status", doc.get("status"), status),
        ):
            if actual != expected:
                lines.append(f"    FAIL {fixture}: {label} expected {expected!r}, "
                             f"got {actual!r}")
                ok = False
    if ok:
        lines.append(f"    {len(TOPOLOGY_ORACLE)} topology classes: depth / "
                     f"criticalPath / walFrames / artifacts / status all correct")
    return ok


def run():
    lines = []
    ok = True
    for fn in (_test_cycle_message_exact, _test_document_seed_stable,
               _test_topology_oracle):
        try:
            ok = fn(lines) and ok
        except Exception as e:  # a sub-test crashing is a failure
            import traceback
            ok = False
            lines.append(f"    ERROR in {fn.__name__}: {type(e).__name__}: {e}")
            lines.append(traceback.format_exc())
    return ok, lines


if __name__ == "__main__":
    ok, lines = run()
    print("== test_vakedc_passes ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
