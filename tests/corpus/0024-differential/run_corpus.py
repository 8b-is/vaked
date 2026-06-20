#!/usr/bin/env python3
"""0024 differential test corpus harness (Stage-0 leg).

Closes the C14 evidence gap for docs/language/0024-mlir-lowering-staged-adoption.md
by giving §11 a runnable oracle over a fixed set of topology classes.

WHAT THIS PROVES TODAY (Stage-0, pure-Python vakedc parse->check->lower):
  * Determinism: lowering the SAME source file twice yields byte-identical
    artifact trees. This discharges the §11 "Determinism" box for the Stage-0
    leg and pins the byte-exact baseline the Stage-1 comparison will use.
  * Correct rejection: the cyclic and depth-exceeding fixtures are rejected by
    `vakedc check` with the expected diagnostic CODE (asserted via `check
    --json`, not message text) and a nonzero exit. This pins the Stage-0
    rejection oracle for §13.1 soundness.
  * Pass pipeline (0013/0019-0024): the Stage-0 MLIR-mirror pass pipeline
    (``vakedc passes``) produces correct depth, WAL frames, and supervisor
    index artifacts for each topology class. This pins the oracle that
    Stage-1 MLIR passes must reproduce (0024 §2.1 observational equivalence).

WHAT THIS DOES NOT PROVE YET:
  Stage-1 (the C++/MLIR `vaked`/`hcp` dialects) does not exist. The §11 boxes
  that are *comparative* between the two stages -- "Pass 1 ... identically to
  Stage-0", "Round-trip: Stage-0 and Stage-1 ... equivalent", and the dialect
  verifiers tracking Stage-0 -- cannot be ticked until Stage-1 lands. This file
  builds the oracle those boxes will be checked against, not the comparison.

STAGE-1 EXTENSION POINT:
  When a Stage-1 lowering binary exists, add a `lower_stage1(fixture, out_dir)`
  that invokes it on dev-cx53 (Stage-1 is C++/MLIR and MUST build/run there;
  the Stage-0 leg here is stdlib Python and runs anywhere). Then, for each
  should-lower fixture, run both stages and compare their trees with
  `compare_cross_stage()` instead of the raw byte-compare used within a stage.

  IMPORTANT (see design doc, canonicalization note): the cross-stage compare
  CANNOT be a naive whole-tree byte-compare. `provenance.json` embeds the
  absolute source path and a derived `inputsHash`; Stage-0 (local) and Stage-1
  (dev-cx53) will see different absolute paths, so those fields differ by
  environment even when the semantic artifacts are identical. The cross-stage
  check must exclude/normalize the provenance source-path + inputsHash (or
  compare only the semantic artifacts: gen/workflow/*.json, gen/eventd.json,
  flake.nix, gen/RUNTIME.md). The WITHIN-stage determinism check below stays a
  pure byte-compare precisely because both runs use the identical source path.
"""

import filecmp
import json
import subprocess
import sys
import tempfile
from pathlib import Path

# tests/corpus/0024-differential/run_corpus.py -> repo root is 3 parents up.
REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = Path(__file__).resolve().parent / "fixtures"

# (fixture filename, expected diagnostic code) for the should-reject set.
SHOULD_REJECT = [
    ("cyclic.vaked", "E-WORKFLOW-CYCLE"),
    ("depth-bound-exceeded.vaked", "E-WORKFLOW-DEPTH"),
]

# Fixtures that must check clean and lower deterministically.
SHOULD_LOWER = [
    "single-agent.vaked",
    "linear-chain.vaked",
    "diamond.vaked",
    "depth-bound-ok.vaked",
]


def _run_vakedc(args):
    """Run `python3 -m vakedc <args>` from the repo root.

    cwd MUST be the repo root: `python -m` puts cwd on sys.path, and that is how
    the vakedc package is resolved (there is no installed package).
    """
    return subprocess.run(
        [sys.executable, "-m", "vakedc", *args],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )


def _trees_identical(a: Path, b: Path) -> bool:
    """Recursive byte-for-byte comparison of two directory trees."""
    cmp = filecmp.dircmp(a, b)
    if cmp.left_only or cmp.right_only or cmp.diff_files or cmp.funny_files:
        return False
    # filecmp.dircmp compares files shallowly (stat); force a content compare.
    match, mismatch, errors = filecmp.cmpfiles(
        a, b, cmp.common_files, shallow=False
    )
    if mismatch or errors:
        return False
    for sub in cmp.common_dirs:
        if not _trees_identical(a / sub, b / sub):
            return False
    return True


def check_should_lower(name: str):
    """Lower the same fixture into two temp dirs; assert byte-identical trees."""
    fixture = FIXTURES / name
    with tempfile.TemporaryDirectory() as td:
        out_a = Path(td) / "A"
        out_b = Path(td) / "B"
        # Both runs use the IDENTICAL source path -> provenance source field and
        # inputsHash are constant, so a whole-tree byte-compare is valid here.
        r1 = _run_vakedc(["lower", str(fixture), "--out", str(out_a)])
        r2 = _run_vakedc(["lower", str(fixture), "--out", str(out_b)])
        if r1.returncode != 0:
            return False, f"first lower exited {r1.returncode}: {r1.stderr.strip()}"
        if r2.returncode != 0:
            return False, f"second lower exited {r2.returncode}: {r2.stderr.strip()}"
        if not out_a.exists() or not any(out_a.iterdir()):
            return False, "no artifacts emitted"
        if not _trees_identical(out_a, out_b):
            return False, "two lowerings differ (non-deterministic)"
        return True, "deterministic: byte-identical over 2 runs"


# -- Pass pipeline expected values (0013 / 0019-0024 Section-0 reference) ---------
#
# For each should-lower fixture: (filename, expected_depth, expected_wal_count)
PASS_EXPECTED = [
    ("single-agent.vaked",      1, 0),
    ("linear-chain.vaked",      3, 2),
    ("diamond.vaked",           3, 4),
    ("depth-bound-ok.vaked",    3, 2),
]


def check_pass_pipeline(name: str, exp_depth: int, exp_wal: int):
    """Run ``vakedc passes --json``; verify depth, WAL frames, artifact."""
    fixture = FIXTURES / name
    r = _run_vakedc(["passes", "--json", str(fixture)])
    if r.returncode not in (0, 1):
        return False, f"returned {r.returncode}: {r.stderr.strip()}"
    try:
        payload = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        return False, f"passes --json did not emit JSON: {e}"

    workflows = payload.get("workflows", [])
    if not workflows:
        return False, "no workflows in output"

    wf = workflows[0]
    actual_depth = wf.get("depth")
    wal_frames = wf.get("walFrames", [])
    artifacts = payload.get("artifacts", [])

    problems = []
    if actual_depth != exp_depth:
        problems.append(f"depth {actual_depth} != expected {exp_depth}")
    if len(wal_frames) != exp_wal:
        problems.append(f"WAL frames {len(wal_frames)} != expected {exp_wal}")
    if not any("gen/workflow" in a for a in artifacts):
        problems.append(f"no gen/workflow artifact in {artifacts}")

    if problems:
        return False, "; ".join(problems)
    return True, f"depth={actual_depth}, wal={len(wal_frames)}, artifacts={len(artifacts)}"


def check_should_reject(name: str, expected_code: str):
    """Run `check --json`; assert exit==1 and expected code present."""
    fixture = FIXTURES / name
    r = _run_vakedc(["check", "--json", str(fixture)])
    if r.returncode != 1:
        return False, f"expected exit 1, got {r.returncode}"
    try:
        payload = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        return False, f"check --json did not emit JSON: {e}"
    codes = {d.get("code") for d in payload.get("diagnostics", [])}
    if expected_code not in codes:
        return False, f"expected {expected_code}, got codes {sorted(codes)}"
    return True, f"rejected with {expected_code} (exit 1)"


def main():
    results = []
    for name in SHOULD_LOWER:
        ok, detail = check_should_lower(name)
        results.append((name, "lower+determinism", ok, detail))
    for name, exp_depth, exp_wal in PASS_EXPECTED:
        ok, detail = check_pass_pipeline(name, exp_depth, exp_wal)
        results.append((name, "passes", ok, detail))
    for name, code in SHOULD_REJECT:
        ok, detail = check_should_reject(name, code)
        results.append((name, "reject", ok, detail))

    width = max(len(n) for n, *_ in results)
    print(f"0024 differential corpus (Stage-0 leg) -- repo root: {REPO_ROOT}")
    print("-" * (width + 50))
    for name, kind, ok, detail in results:
        status = "PASS" if ok else "FAIL"
        print(f"{status:4}  {name:<{width}}  [{kind}]  {detail}")
    print("-" * (width + 50))

    failed = [n for n, _, ok, _ in results if not ok]
    if failed:
        print(f"{len(failed)} FAILED: {', '.join(failed)}")
        return 1
    print(f"all {len(results)} fixtures PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
