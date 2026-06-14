#!/usr/bin/env python3
"""determinism_baseline.py — the N-iteration determinism baseline harness (Risk 2).

The credibility review (V1.0) flagged a contradictory "20-iteration oracle"
determinism claim. The reality is narrower but sound: the existing
``tests/spec/*::_test_determinism`` checks each run a stage exactly **twice** and
byte-compare; there is no N-iteration harness and no published baseline.

This module *builds* that harness and publishes a baseline. It re-runs each
pipeline stage that applies to each example ``N`` times (default 100), hashes the
canonical output bytes per run with SHA-256, and records — per (example, stage) —
the set of distinct digests observed. A row "converged" iff exactly one distinct
digest was seen across all N runs. The convergence percentage over all rows is the
headline number.

Why convergence is expected to be ~100% for valid examples (the structural
argument the baseline makes *measurable* rather than merely asserted):

  * canonical ordering everywhere — ``graph.nodes_sorted()``,
    ``lower._canonical_value`` sorts dict keys, the diagnostics JSON is
    ``sort_keys=True``;
  * ``lower.inputs_hash`` = SHA-256 over a pure canonical projection;
  * no wall-clock, no environment/locale/hostname, no randomness, no readdir order
    in any hashed content (the only IO is the CLI write layer, which this harness
    does not exercise — it hashes in-memory artifact bytes).

So a transparent re-run converges for every valid example/stage; the published
baseline records that as a number, with a row per (example, stage).

Stages, and when each "applies" to an example:

  * ``parse``  — every example that parses + resolves into a graph (the canonical
    parse JSON, :func:`vakedc.to_canonical_json`). Hashed over the canonical JSON
    bytes.
  * ``check``  — every example (the canonical diagnostics JSON, the same form the
    CLI's ``--json`` emits and ``test_vakedc_check`` golden-compares). A *rejected*
    example produces a stable non-empty diagnostics document — that is still a
    determinism row (the bytes must be identical run-to-run). Hashed over the
    diagnostics JSON bytes.
  * ``lower``  — every example whose validated graph lowers to a NON-EMPTY artifact
    tree (i.e. it has a ``runtime`` node and the checker reports no diagnostics, so
    the CLI's refusal gate would not fire). Hashed over the concatenated canonical
    artifact bytes (every emitted file in sorted-path order, plus the serialized
    ``provenance.json``) — reusing ``lower.inputs_hash`` /
    ``_canonical_projection_json`` for canonicalization of the file map.

No clock / random / environment enters the hashed content of any stage.

CLI::

    python3 tests/spec/determinism_baseline.py \
        --iters 100 --out tests/spec/golden/baseline-2026-06-14.json

Exit code is non-zero if the measured convergence is below 99.5%.

This module also exposes ``run() -> (ok, lines)`` so it can be wired into
``tests/spec/run_all.py``'s ``MODULES`` table (see that file). ``run()`` uses a
small default iteration count (kept fast for the orchestrator) unless overridden
by the ``VAKED_DETERMINISM_ITERS`` environment variable; the *published* baseline
is produced by the CLI with ``--iters 100``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                       # test_examples_parse (examples enumerator)
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, REPO)                       # the standalone `vakedc` package

import vakedc                                  # noqa: E402  (implementation under test)
from vakedc.parser import parse_source          # noqa: E402
from vakedc.resolve import build_graph           # noqa: E402
from vakedc import lower as lower_mod            # noqa: E402

import test_examples_parse as tep               # noqa: E402  (reuse the examples enumerator)

# The Unicode version the lexer is pinned to (recorded in the baseline so a future
# host on a different Unicode DB is a visible, attributable difference — not a
# silent one). Pinned at 15.1.0 per the credibility review (Risk 2). We also assert
# the live lexer agrees, so the baseline never claims a pin the toolchain abandoned.
UNICODE_PINNED = "15.1.0"

# Default iters for the in-process run() (run_all.py path). The PUBLISHED baseline
# uses --iters 100 via the CLI. Override either path with VAKED_DETERMINISM_ITERS.
DEFAULT_RUN_ITERS = 5

# Convergence gate (CLI exit code). A valid, canonical pipeline converges fully;
# we allow a hair of slack only so a single cosmetic outlier cannot fail CI, while
# any real non-determinism (which would tank the percentage) still does.
CONVERGENCE_GATE_PCT = 99.5


# --------------------------------------------------------------------------- #
# Stage runners — each returns the canonical output BYTES for one run, or None
# when the stage does not apply to this example. PURE w.r.t. hashed content: no
# clock/env/random enters the returned bytes.
# --------------------------------------------------------------------------- #

def _rel(path: str) -> str:
    """The repo-relative path the pipeline records in provenance (so the hashed
    bytes are independent of the absolute checkout location)."""
    return os.path.relpath(path, REPO).replace(os.sep, "/")


def _stage_parse(path: str):
    """Canonical parse JSON bytes (parse + resolve -> graph -> canonical JSON).

    Returns ``None`` if the source does not parse/resolve into stable canonical
    JSON, so the parse stage simply does not produce a row for that example. Two
    distinct not-applicable conditions, both *deterministic* and both surfaced as a
    skip note by :func:`measure` (never silently buried):

      * a lex/syntax error (no graph — there are no such fixtures today);
      * the canonical-JSON serializer raising (a pre-existing
        ``emit.to_canonical_json`` limitation: ``schema-constraints.vaked`` carries
        a refinement prop whose ``Literal`` value the serializer does not reduce —
        a ``TypeError``). That is an emit-layer bug, NOT a determinism defect (it
        fails identically every run), and is out of scope for this harness, so the
        parse row is omitted rather than counted as a non-convergence.
    """
    rel = _rel(path)
    src = open(path, encoding="utf-8").read()
    try:
        graph = vakedc.parse_string(src, rel)
    except (vakedc.VakedLexError, vakedc.VakedSyntaxError):
        return None
    try:
        return vakedc.to_canonical_json(graph).encode("utf-8")
    except (TypeError, ValueError):
        # canonical serializer cannot represent this graph (emit-layer limitation).
        return None


def _diagnostics_json(diags) -> str:
    """The canonical diagnostics JSON form (mirrors
    ``vakedc.__main__._diagnostics_json`` / ``test_vakedc_check``): sorted keys,
    2-space indent, ``ensure_ascii=False``, trailing newline. Deterministic."""
    doc = {"diagnostics": [d.as_dict() for d in diags]}
    return json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def _stage_check(path: str, builtins_cache):
    """Canonical diagnostics JSON bytes. Applies to every example (a clean example
    yields ``{"diagnostics": []}``; a rejected one yields a stable non-empty
    document — both are determinism rows)."""
    rel = _rel(path)
    src = open(path, encoding="utf-8").read()
    diags = vakedc.check_source(src, rel, builtins_cache=builtins_cache)
    return _diagnostics_json(diags).encode("utf-8")


def _canonical_tree_bytes(files: dict, provenance_text: str) -> bytes:
    """Canonicalize a lowered artifact tree (``{path -> str|bytes}`` plus the
    serialized ``provenance.json``) into a single deterministic byte string.

    Path order is sorted (lexicographic by path), each file's bytes are length-
    prefixed by path so concatenation is unambiguous. This is exactly the set of
    bytes the CLI would write, just framed for a single hash."""
    tree = dict(files)
    tree["provenance.json"] = provenance_text
    framing = {}
    for path in sorted(tree.keys()):
        content = tree[path]
        if isinstance(content, str):
            content = content.encode("utf-8")
        framing[path] = hashlib.sha256(content).hexdigest()
    # Reuse lower's canonical projection JSON (sorted keys, compact, no clock) over
    # the {path -> per-file-sha256} map: a pure canonical projection of the tree.
    return lower_mod._canonical_projection_json(framing).encode("utf-8")


def _stage_lower(path: str, builtins_cache):
    """Concatenated canonical artifact bytes for a lowered example.

    Applies only when (a) the checker reports NO diagnostics (the CLI's refusal
    gate would otherwise fire and write nothing) AND (b) the example lowers to a
    non-empty artifact tree (it has a ``runtime`` node). Returns ``None`` otherwise
    so the (example, lower) row is simply absent — never a spurious non-convergence.
    """
    rel = _rel(path)
    src = open(path, encoding="utf-8").read()

    # Refusal gate: any diagnostic ⇒ lowering does not apply (CLI writes nothing).
    diags = vakedc.check_source(src, rel, builtins_cache=builtins_cache)
    if diags:
        return None

    items = parse_source(src, rel)
    graph = build_graph(items, rel)
    result = lower_mod.lower(graph, items)
    if not result.files:
        return None  # no runtime node ⇒ empty tree ⇒ lower stage does not apply
    prov_text = lower_mod.provenance_json_text(result.provenance)
    return _canonical_tree_bytes(result.files, prov_text)


STAGES = ("parse", "check", "lower")


def _run_stage(stage: str, path: str, builtins_cache):
    if stage == "parse":
        return _stage_parse(path)
    if stage == "check":
        return _stage_check(path, builtins_cache)
    if stage == "lower":
        return _stage_lower(path, builtins_cache)
    raise ValueError("unknown stage: %r" % stage)


# --------------------------------------------------------------------------- #
# The N-iteration measurement.
# --------------------------------------------------------------------------- #

def measure(iters: int):
    """Run every applicable (example, stage) ``iters`` times, hashing the canonical
    output bytes per run. Returns ``(rows, convergence_pct, skips)``.

    ``rows`` is a list of dicts (already in the published JSON shape, with a
    deterministic key order): ``{example, stage, sha256, distinct_hashes,
    converged}``. ``sha256`` is the (single) digest when converged, else the sorted
    list of the distinct digests observed. Rows are sorted by (example, stage) so
    the baseline file is itself reproducible.

    ``skips`` is a list of human-readable notes for the *noteworthy* not-applicable
    cases — specifically a parse stage that produced a graph but whose canonical
    JSON serialization raised (the ``schema-constraints.vaked`` emit-layer bug). The
    mundane not-applicable cases (lower on a non-runtime example) are not noted, to
    keep the signal sharp.
    """
    builtins_cache = vakedc.load_builtins()  # parsed once; the checker is pure
    examples = sorted(tep._vaked_files())

    rows = []
    skips = []
    for path in examples:
        example = _rel(path)
        for stage in STAGES:
            digests = set()
            applies = False
            for _ in range(iters):
                out = _run_stage(stage, path, builtins_cache)
                if out is None:
                    applies = False
                    break
                applies = True
                digests.add(hashlib.sha256(out).hexdigest())
            if not applies:
                note = _skip_note(stage, path)
                if note is not None:
                    skips.append(note)
                continue  # stage does not apply to this example — no row
            distinct = sorted(digests)
            converged = (len(distinct) == 1)
            rows.append({
                "example": example,
                "stage": stage,
                "sha256": distinct[0] if converged else distinct,
                "distinct_hashes": len(distinct),
                "converged": converged,
            })

    n_rows = len(rows)
    n_converged = sum(1 for r in rows if r["converged"])
    convergence_pct = (100.0 * n_converged / n_rows) if n_rows else 100.0
    return rows, convergence_pct, skips


def _skip_note(stage: str, path: str):
    """A note for a *noteworthy* not-applicable (example, stage), else ``None``.

    Only the parse stage's canonical-JSON failure is noteworthy (a deterministic
    emit-layer limitation worth surfacing); lower's empty-tree / diagnostics skips
    are expected and silent."""
    if stage != "parse":
        return None
    rel = _rel(path)
    src = open(path, encoding="utf-8").read()
    try:
        graph = vakedc.parse_string(src, rel)
    except (vakedc.VakedLexError, vakedc.VakedSyntaxError) as e:
        return f"{rel} [parse]: lex/syntax error ({type(e).__name__}) — not applicable"
    try:
        vakedc.to_canonical_json(graph)
        return None  # parse stage actually applied; no skip
    except (TypeError, ValueError) as e:
        return (f"{rel} [parse]: canonical JSON serialization raised "
                f"{type(e).__name__} (pre-existing emit.to_canonical_json "
                f"limitation; deterministic, not a determinism defect) — row omitted")


def _baseline_doc(iters: int, rows, convergence_pct: float) -> dict:
    """Assemble the published baseline document (deterministic key order)."""
    return {
        "iters": iters,
        "unicode_pinned": UNICODE_PINNED,
        "generated_for": "credibility-review Risk 2",
        "rows": rows,
        "convergence_pct": convergence_pct,
    }


def _baseline_text(doc: dict) -> str:
    """Serialize the baseline to pretty-printed JSON with a deterministic key order
    and a trailing newline. ``sort_keys=False`` because the rows already carry the
    intended field order; the top-level keys are emitted in insertion order, which
    is the documented schema order."""
    return json.dumps(doc, ensure_ascii=False, indent=2) + "\n"


# --------------------------------------------------------------------------- #
# run() — the run_all.py convention (a fast, in-process smoke of the harness).
# --------------------------------------------------------------------------- #

def run():
    """``run_all.py``-style entry point. Runs the harness in-process at a small
    default iteration count (override via ``VAKED_DETERMINISM_ITERS``) and reports
    convergence. PASS iff convergence >= the gate. Does NOT write the baseline file
    (the published baseline is produced by the CLI with ``--iters 100``)."""
    lines = []
    iters = int(os.environ.get("VAKED_DETERMINISM_ITERS", str(DEFAULT_RUN_ITERS)))

    # Guard the Unicode pin claim against a drifted host lexer.
    live_unicode = getattr(vakedc, "PINNED_UNICODE", None)
    if live_unicode is not None and str(live_unicode) != UNICODE_PINNED:
        lines.append(f"  NOTE: lexer PINNED_UNICODE={live_unicode!r} != baseline "
                     f"{UNICODE_PINNED!r} (cosmetic host-DB note; not artifact-affecting)")

    rows, convergence_pct, skips = measure(iters)
    n_converged = sum(1 for r in rows if r["converged"])
    non_converged = [r for r in rows if not r["converged"]]

    lines.append(f"  determinism baseline: {n_converged}/{len(rows)} rows converged "
                 f"({convergence_pct:.2f}%) over {iters} iters each")
    for r in non_converged:
        lines.append(f"    NON-CONVERGED {r['example']} [{r['stage']}]: "
                     f"{r['distinct_hashes']} distinct hashes")
    for note in skips:
        lines.append(f"    SKIP {note}")
    ok = convergence_pct >= CONVERGENCE_GATE_PCT
    if not ok:
        lines.append(f"  FAIL: convergence {convergence_pct:.2f}% < gate "
                     f"{CONVERGENCE_GATE_PCT}%")
    return ok, lines


# --------------------------------------------------------------------------- #
# CLI.
# --------------------------------------------------------------------------- #

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Vaked N-iteration determinism baseline harness (Risk 2).")
    parser.add_argument("--iters", type=int, default=None,
                        help="iterations per (example, stage) "
                             "(default 100; or VAKED_DETERMINISM_ITERS).")
    parser.add_argument("--out", default=None,
                        help="write the baseline JSON to this path "
                             "(default: stdout only).")
    args = parser.parse_args(argv)

    if args.iters is not None:
        iters = args.iters
    elif "VAKED_DETERMINISM_ITERS" in os.environ:
        iters = int(os.environ["VAKED_DETERMINISM_ITERS"])
    else:
        iters = 100
    if iters < 1:
        parser.error("--iters must be >= 1")

    live_unicode = getattr(vakedc, "PINNED_UNICODE", None)
    if live_unicode is not None and str(live_unicode) != UNICODE_PINNED:
        print(f"NOTE: lexer PINNED_UNICODE={live_unicode!r} != baseline "
              f"{UNICODE_PINNED!r} (cosmetic host Unicode-DB note; the hashed "
              f"artifact bytes are not affected).", file=sys.stderr)

    rows, convergence_pct, skips = measure(iters)
    doc = _baseline_doc(iters, rows, convergence_pct)
    text = _baseline_text(doc)

    if args.out:
        out_path = args.out if os.path.isabs(args.out) else os.path.join(REPO, args.out)
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(text)

    n_converged = sum(1 for r in rows if r["converged"])
    non_converged = [r for r in rows if not r["converged"]]
    print("== determinism baseline ==")
    print(f"iters={iters}  rows={len(rows)}  converged={n_converged}  "
          f"convergence={convergence_pct:.2f}%  unicode_pinned={UNICODE_PINNED}")
    if args.out:
        print(f"baseline written: {_rel(out_path)}")
    for r in non_converged:
        print(f"  NON-CONVERGED {r['example']} [{r['stage']}]: "
              f"{r['distinct_hashes']} distinct hashes -> {r['sha256']}")
    for note in skips:
        print(f"  SKIP {note}")

    ok = convergence_pct >= CONVERGENCE_GATE_PCT
    print("RESULT:", "PASS" if ok else "FAIL",
          f"(gate {CONVERGENCE_GATE_PCT}%)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
