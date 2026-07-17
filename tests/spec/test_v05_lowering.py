#!/usr/bin/env python3
"""test_v05_lowering.py — the THIRD frozen lowering golden (v0.5 trio).

`vaked/examples/lowering/` freezes `operator-field.vaked` and
`vaked/examples/lowering-agentfield/` freezes `agentfield-swe.vaked`; neither
exercises the v0.5 `trust.config` emitter (trust / quorum / probe → the
`gen/trust.json` topology config the runtime supervisor loads).

This module freezes `vaked/examples/v0.5/runtime-with-trust.vaked`
byte-for-byte against `vaked/examples/lowering-v0.5/`, and additionally pins
the trust.json SEMANTICS the golden alone cannot express:

  * `score` is a JSON number (0.9), not the lexer's string form ("0.9");
  * `on_failure` is present — its checker-legal value is a bare ref
    (`on_failure = retry`), so a literal-only projection silently drops it;
  * `min` is a JSON integer.

Three checks (mirroring the other two goldens' discipline):
1. Golden tree — lower the example and byte-compare EVERY emitted file against
   `vaked/examples/lowering-v0.5/`.
2. trust.json semantics — the typed assertions above, on the EMITTED bytes
   (not the fixture), so a stale regeneration cannot mask an emitter bug.
3. Determinism + emitter coverage — two lowers byte-identical; `trust.config`
   actually ran.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, REPO)

from vakedc.parser import parse_source     # noqa: E402
from vakedc.resolve import build_graph      # noqa: E402
from vakedc import lower as lower_mod        # noqa: E402

EXAMPLE = os.path.join(REPO, "vaked", "examples", "v0.5", "runtime-with-trust.vaked")
EXAMPLE_REL = "vaked/examples/v0.5/runtime-with-trust.vaked"
GOLDEN_DIR = os.path.join(REPO, "vaked", "examples", "lowering-v0.5")

# the emitter this golden exists to lock (absent from the other two goldens).
_REQUIRED_EMITTERS = {"trust.config"}


def _lower():
    src = open(EXAMPLE, encoding="utf-8").read()
    items = parse_source(src, EXAMPLE_REL)
    graph = build_graph(items, EXAMPLE_REL)
    result = lower_mod.lower(graph, items)
    tree = dict(result.files)
    tree["provenance.json"] = lower_mod.provenance_json_text(result.provenance)
    return tree, result


def _disk_tree():
    out = {}
    for root, _d, names in os.walk(GOLDEN_DIR):
        for n in names:
            full = os.path.join(root, n)
            rel = os.path.relpath(full, GOLDEN_DIR).replace(os.sep, "/")
            out[rel] = open(full, encoding="utf-8").read()
    return out


def _test_golden_tree(lines):
    ok = True
    emitted, _ = _lower()
    disk = _disk_tree()
    if set(emitted) != set(disk):
        ok = False
        miss = sorted(set(disk) - set(emitted))
        extra = sorted(set(emitted) - set(disk))
        if miss:
            lines.append(f"  FAIL golden: not emitted: {miss}")
        if extra:
            lines.append(f"  FAIL golden: emitted but not a fixture: {extra}")
    n = 0
    for rel in sorted(set(emitted) & set(disk)):
        got = emitted[rel]
        if isinstance(got, bytes):
            got = got.decode("utf-8")
        if got == disk[rel]:
            n += 1
            continue
        ok = False
        at = next((i for i, (a, b) in enumerate(zip(got, disk[rel]))
                   if a != b), min(len(got), len(disk[rel])))
        lines.append(f"  FAIL golden: {rel} differs at byte {at} "
                     f"(emitted {len(got)}B vs fixture {len(disk[rel])}B)")
    if ok:
        lines.append(f"  golden tree: {n} files byte-identical to "
                     f"lowering-v0.5/")
    return ok


def _test_trust_json_semantics(lines):
    """Typed assertions on the EMITTED gen/trust.json (0cdea63 intent: numeric
    score, ref-valued on_failure survives projection, integer min)."""
    ok = True
    emitted, _ = _lower()
    raw = emitted.get("gen/trust.json")
    if raw is None:
        lines.append("  FAIL trust.json: not emitted at all")
        return False
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    doc = json.loads(raw)

    trusts = {t["name"]: t for t in doc.get("trusts", [])}
    quorums = {q["name"]: q for q in doc.get("quorums", [])}
    probes = {p["name"]: p for p in doc.get("probes", [])}
    if set(trusts) != {"primaryScore", "delegateScore"}:
        ok = False
        lines.append(f"  FAIL trust.json: trusts roster {sorted(trusts)}")
    if set(quorums) != {"consensus", "compactionGuard"}:
        ok = False
        lines.append(f"  FAIL trust.json: quorums roster {sorted(quorums)}")
    if set(probes) != {"readinessProbe", "preUpgradeProbe"}:
        ok = False
        lines.append(f"  FAIL trust.json: probes roster {sorted(probes)}")

    for name, want in (("primaryScore", 0.9), ("delegateScore", 0.7)):
        got = trusts.get(name, {}).get("score")
        if not isinstance(got, float) or got != want:
            ok = False
            lines.append(f"  FAIL trust.json: trust `{name}` score must be the "
                         f"JSON number {want}, got {got!r}")
    for name, want_min, want_fail in (("consensus", 2, "retry"),
                                      ("compactionGuard", 1, "abort")):
        q = quorums.get(name, {})
        if not isinstance(q.get("min"), int) or q.get("min") != want_min:
            ok = False
            lines.append(f"  FAIL trust.json: quorum `{name}` min must be the "
                         f"JSON integer {want_min}, got {q.get('min')!r}")
        if q.get("on_failure") != want_fail:
            ok = False
            lines.append(f"  FAIL trust.json: quorum `{name}` on_failure must "
                         f"be {want_fail!r} (ref-valued per grammar "
                         f"quorum_decl), got {q.get('on_failure')!r}")
    if ok:
        lines.append("  trust.json semantics: numeric scores, integer mins, "
                     "ref-valued on_failure all correct")
    return ok


def _test_determinism(lines):
    t1, _ = _lower()
    t2, _ = _lower()
    if t1 != t2:
        lines.append("  FAIL determinism: two lowers differ")
        return False
    lines.append(f"  determinism: {len(t1)} files byte-identical across lowers")
    return True


def _test_emitter_coverage(lines):
    _, result = _lower()
    seen = {e.emitter for e in result.entries}
    missing = sorted(_REQUIRED_EMITTERS - seen)
    if missing:
        lines.append(f"  FAIL coverage: golden no longer exercises {missing}")
        return False
    lines.append("  emitter coverage: trust.config present")
    return True


def run():
    lines = []
    ok = True
    for fn in (_test_golden_tree, _test_trust_json_semantics,
               _test_determinism, _test_emitter_coverage):
        try:
            ok = fn(lines) and ok
        except Exception as e:
            import traceback
            ok = False
            lines.append(f"    ERROR in {fn.__name__}: {type(e).__name__}: {e}")
            lines.append(traceback.format_exc())
    return ok, lines


if __name__ == "__main__":
    ok, lines = run()
    print("== test_v05_lowering ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
