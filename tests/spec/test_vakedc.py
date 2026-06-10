#!/usr/bin/env python3
"""test_vakedc.py — verifies the `vakedc` front-end against the spec infrastructure.

Four test groups (see docs/superpowers/specs/2026-06-10-vakedc-parser-prototype-
design.md → Verification):

1. Differential oracle. For all 15 `.vaked` examples AND the v0.2-compat probe
   snippets, vakedc's accept/reject verdict must MATCH the from-EBNF recognizer
   (parse_support.parse_vaked). vakedc must NOT import tests/spec; it is exercised
   through its own `vakedc.parse_string` helper.
2. Golden snapshot. operator-field.vaked → canonical JSON, byte-for-byte equal to
   the checked-in tests/spec/golden/operator-field.graph.json.
3. Cross-artifact provenance. For each artifacts entry in
   vaked/examples/lowering/provenance.json whose decl exists as a graph node, the
   node's span (all four fields) is IDENTICAL to the fixture span.
4. Determinism. Parse twice → identical JSON; SQLite canonical_dump identical
   (a tempfile DB).

vakedc is imported as a top-level package (the repo root is added to sys.path).
"""

import glob
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                       # parse_support, test_examples_parse
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, REPO)                       # the standalone `vakedc` package

import parse_support as ps          # noqa: E402  (the EBNF recognizer side)
import test_examples_parse as tep   # noqa: E402  (reuse its probes + example globs)
import vakedc                       # noqa: E402  (the implementation under test)

GOLDEN = os.path.join(HERE, "golden", "operator-field.graph.json")
OPERATOR_FIELD = "vaked/examples/operator-field.vaked"
PROVENANCE = "vaked/examples/lowering/provenance.json"


def _vakedc_accepts(src, filename="<probe>"):
    """vakedc's accept/reject verdict for a source string (no exceptions leak)."""
    try:
        vakedc.parse_string(src, filename)
        return True, None
    except (vakedc.VakedLexError, vakedc.VakedSyntaxError) as e:
        return False, str(e)


# --------------------------------------------------------------------------- #
# 1. Differential oracle
# --------------------------------------------------------------------------- #

def _test_differential(lines):
    ok = True
    n_match = 0
    n_total = 0

    # (a) all 15 example files
    for f in tep._vaked_files():
        rel = os.path.relpath(f, REPO)
        src = open(f, encoding="utf-8").read()
        ebnf_ok = ps.parse_vaked(src, rel).ok
        v_ok, verr = _vakedc_accepts(src, rel)
        n_total += 1
        if ebnf_ok == v_ok:
            n_match += 1
        else:
            ok = False
            lines.append(f"    FAIL diff  {rel}: ebnf={ebnf_ok} vakedc={v_ok}"
                         f"{(' :: ' + verr) if verr else ''}")

    # (b) the v0.2-compat probes from test_examples_parse
    for label, src, _parser, _expect in tep._regression_probes():
        ebnf_ok = ps.parse_vaked(src).ok
        v_ok, verr = _vakedc_accepts(src)
        n_total += 1
        if ebnf_ok == v_ok:
            n_match += 1
        else:
            ok = False
            lines.append(f"    FAIL diff  {label}: ebnf={ebnf_ok} vakedc={v_ok}"
                         f"{(' :: ' + verr) if verr else ''}")

    lines.append(f"  differential oracle: {n_match}/{n_total} verdicts match "
                 f"the EBNF recognizer")
    return ok


# --------------------------------------------------------------------------- #
# 2. Golden snapshot
# --------------------------------------------------------------------------- #

def _test_golden(lines):
    if not os.path.exists(GOLDEN):
        lines.append(f"  FAIL golden: missing {GOLDEN}")
        return False
    graph = vakedc.parse_file(OPERATOR_FIELD)
    produced = vakedc.to_canonical_json(graph)
    expected = open(GOLDEN, encoding="utf-8").read()
    if produced == expected:
        doc = json.loads(produced)
        lines.append(f"  golden snapshot: byte-identical "
                     f"({len(doc['nodes'])} nodes, {len(doc['edges'])} edges)")
        return True
    lines.append("  FAIL golden: canonical JSON differs from "
                 "tests/spec/golden/operator-field.graph.json")
    # show the first differing offset for debuggability
    for i, (a, b) in enumerate(zip(produced, expected)):
        if a != b:
            lines.append(f"    first diff at byte {i}: "
                         f"produced {a!r} vs golden {b!r}")
            break
    else:
        lines.append(f"    length differs: produced {len(produced)} "
                     f"vs golden {len(expected)}")
    return False


# --------------------------------------------------------------------------- #
# 3. Cross-artifact provenance
# --------------------------------------------------------------------------- #

def _test_provenance(lines):
    ok = True
    prov = json.load(open(os.path.join(REPO, PROVENANCE), encoding="utf-8"))
    graph = vakedc.parse_file(OPERATOR_FIELD)
    by_decl = {n.provenance.decl: n.provenance.span
               for n in graph.nodes if n.provenance is not None}

    # distinct (decl, span) pairs across all artifacts entries
    want = {}
    for entries in prov["artifacts"].values():
        for e in entries:
            want[e["decl"]] = e["span"]

    checked = 0
    for decl, span in sorted(want.items()):
        if decl not in by_decl:
            # not all provenance decls are necessarily graph nodes; skip those
            continue
        got = by_decl[decl]
        checked += 1
        same = (got.byteStart == span["byteStart"]
                and got.byteEnd == span["byteEnd"]
                and got.line == span["line"]
                and got.col == span["col"])
        if not same:
            ok = False
            lines.append(
                f"    FAIL prov  {decl!r}: fixture "
                f"{span['byteStart']}..{span['byteEnd']} "
                f"L{span['line']}C{span['col']} vs graph "
                f"{got.byteStart}..{got.byteEnd} L{got.line}C{got.col}")
    lines.append(f"  cross-artifact provenance: {checked} decl spans match "
                 f"vaked/examples/lowering/provenance.json")
    if checked == 0:
        ok = False
        lines.append("    FAIL prov: no decls matched (expected >= 5)")
    return ok


# --------------------------------------------------------------------------- #
# 4. Determinism
# --------------------------------------------------------------------------- #

def _test_determinism(lines):
    ok = True
    g1 = vakedc.parse_file(OPERATOR_FIELD)
    g2 = vakedc.parse_file(OPERATOR_FIELD)
    j1 = vakedc.to_canonical_json(g1)
    j2 = vakedc.to_canonical_json(g2)
    if j1 != j2:
        ok = False
        lines.append("    FAIL determinism: JSON differs across two parses")

    tmpdir = tempfile.mkdtemp(prefix="vakedc-det-")
    p1 = os.path.join(tmpdir, "a.db")
    p2 = os.path.join(tmpdir, "b.db")
    vakedc.to_sqlite(g1, p1)
    vakedc.to_sqlite(g2, p2)
    d1 = vakedc.canonical_dump(p1)
    d2 = vakedc.canonical_dump(p2)
    if d1 != d2:
        ok = False
        lines.append("    FAIL determinism: SQLite canonical_dump differs")
    for p in (p1, p2):
        try:
            os.remove(p)
        except OSError:
            pass
    try:
        os.rmdir(tmpdir)
    except OSError:
        pass

    if ok:
        lines.append("  determinism: JSON + SQLite canonical_dump identical "
                     "across runs")
    return ok


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #

def run():
    lines = []
    ok = True
    for fn in (_test_differential, _test_golden, _test_provenance,
               _test_determinism):
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
    print("== test_vakedc ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
