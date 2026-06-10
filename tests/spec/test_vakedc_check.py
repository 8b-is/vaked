#!/usr/bin/env python3
"""test_vakedc_check.py — the 0011 type-system checker (vakedc stages 3-4).

Six test groups (see docs/superpowers/specs/2026-06-10-vakedc-checker-design.md →
Tests):

1. Builtins. ``vaked/schema/builtins.vaked`` parses and self-checks clean (the
   dogfooded catalog is itself a valid Vaked file with no diagnostics).
2. Catalog coverage. Every kind named by a ``## Schema:`` heading and every
   ``schema``/``capability`` named in a fenced ```vaked``` block in
   ``vaked/schema/parallel-types.md`` (minus the two meta-kinds ``schema`` /
   ``capability``) exists as a node in the builtins graph — guards builtins ↔ md
   drift.  The md is parsed minimally for NAMES only (headings + code-fence decl
   keywords), which stays robust to prose edits.
3. Conformant. ``vaked/examples/types/conformant.vaked`` → 0 diagnostics.
4. Rejected. ``vaked/examples/types/rejected.vaked`` → EXACTLY the three
   documented codes (E-CAP-ATTENUATION, E-CONSTRAINT-RANGE,
   E-CONFORM-UNKNOWN-FIELD), and its canonical ``--json`` output is byte-identical
   to tests/spec/golden/rejected.diagnostics.json.
5. All examples. All 15 ``.vaked`` examples check clean (rejected.vaked is the
   sole intentional exception — see group 4).
6. Determinism. Two checks of the same file produce identical diagnostics JSON.

vakedc is imported as a top-level package (the repo root is on sys.path).
"""

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, REPO)

import vakedc  # noqa: E402

BUILTINS = os.path.join(REPO, "vaked", "schema", "builtins.vaked")
PARALLEL_TYPES = os.path.join(REPO, "vaked", "schema", "parallel-types.md")
CONFORMANT = os.path.join(REPO, "vaked", "examples", "types", "conformant.vaked")
REJECTED = os.path.join(REPO, "vaked", "examples", "types", "rejected.vaked")
GOLDEN = os.path.join(HERE, "golden", "rejected.diagnostics.json")

# meta-kinds: declaration mechanisms, NOT catalog record-schemas.
_META_KINDS = frozenset(("schema", "capability"))


def _builtins_cache():
    return vakedc.load_builtins(BUILTINS)


def _diagnostics_json(diags):
    """Mirror vakedc.__main__._diagnostics_json (the canonical --json form)."""
    doc = {"diagnostics": [d.as_dict() for d in diags]}
    return json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def _all_examples():
    return sorted(glob.glob(os.path.join(REPO, "vaked", "examples", "**", "*.vaked"),
                            recursive=True))


# --------------------------------------------------------------------------- #
# 1. Builtins parses + self-checks clean
# --------------------------------------------------------------------------- #

def _test_builtins(lines):
    try:
        cache = _builtins_cache()
    except Exception as e:
        lines.append(f"  FAIL builtins: catalog failed to parse: "
                     f"{type(e).__name__}: {e}")
        return False
    b_items, b_src, b_file = cache
    n_schema = sum(1 for it in b_items
                   if getattr(it, "kind", None) == "schema")
    n_cap = sum(1 for it in b_items
                if getattr(it, "kind", None) == "capability")
    diags = vakedc.check_source(b_src, b_file, builtins_cache=cache)
    if diags:
        lines.append(f"  FAIL builtins self-check: {len(diags)} diagnostics")
        for d in diags[:8]:
            lines.append(f"    {d.code} @ {d.line}:{d.col} :: {d.message}")
        return False
    lines.append(f"  builtins: parses + self-checks clean "
                 f"({n_schema} schemas, {n_cap} capability domains)")
    return True


# --------------------------------------------------------------------------- #
# 2. Catalog coverage (builtins ↔ parallel-types.md)
# --------------------------------------------------------------------------- #

def _md_names():
    """Extract (schema_kinds, capability_domains) named in parallel-types.md by
    NAME only — robust to prose edits.

    Two complementary sources are unioned:
      * ``## Schema: `<kind>``` headings (the canonical one-schema-per-kind list);
      * ``schema <name>`` / ``capability <name>`` decls inside fenced ```vaked```
        blocks (catches the nested helper schemas: meshNode, fiberPolicy, …).
    Meta-kinds (`schema`, `capability`) are excluded — they are declaration
    mechanisms, not catalog record-schemas.
    """
    md = open(PARALLEL_TYPES, encoding="utf-8").read()
    schemas = set(re.findall(r'^##\s+Schema:\s*`([A-Za-z0-9_]+)`', md, re.MULTILINE))
    domains = set(re.findall(r'^###\s+Domain\s+`([A-Za-z0-9_]+)`', md, re.MULTILINE))
    for blk in re.findall(r'```vaked\s*(.*?)```', md, re.DOTALL):
        schemas.update(re.findall(r'^\s*schema\s+([A-Za-z_][A-Za-z0-9_]*)\b',
                                  blk, re.MULTILINE))
        domains.update(re.findall(r'^\s*capability\s+([A-Za-z_][A-Za-z0-9_]*)\b',
                                  blk, re.MULTILINE))
    schemas -= _META_KINDS
    domains -= _META_KINDS
    return schemas, domains


def _test_coverage(lines):
    cache = _builtins_cache()
    graph = vakedc.parse_file(BUILTINS)
    have_schema = {n.name for n in graph.nodes if n.kind == "schema"}
    have_cap = {n.name for n in graph.nodes if n.kind == "capability"}

    want_schema, want_cap = _md_names()
    if not want_schema or not want_cap:
        lines.append("  FAIL coverage: parsed no kind/domain names from "
                     "parallel-types.md (extractor broken?)")
        return False

    missing_s = sorted(want_schema - have_schema)
    missing_c = sorted(want_cap - have_cap)
    ok = not missing_s and not missing_c
    if missing_s:
        lines.append(f"  FAIL coverage: schemas in parallel-types.md missing from "
                     f"builtins.vaked: {missing_s}")
    if missing_c:
        lines.append(f"  FAIL coverage: capability domains in parallel-types.md "
                     f"missing from builtins.vaked: {missing_c}")
    if ok:
        lines.append(f"  catalog coverage: all {len(want_schema)} md schema kinds "
                     f"+ {len(want_cap)} capability domains present in builtins "
                     f"graph")
    return ok


# --------------------------------------------------------------------------- #
# 3. Conformant → 0 diagnostics
# --------------------------------------------------------------------------- #

def _test_conformant(lines):
    cache = _builtins_cache()
    diags = vakedc.check_source(open(CONFORMANT, encoding="utf-8").read(),
                                os.path.relpath(CONFORMANT, REPO),
                                builtins_cache=cache)
    if diags:
        lines.append(f"  FAIL conformant: expected 0 diagnostics, got {len(diags)}")
        for d in diags:
            lines.append(f"    {d.code} @ {d.line}:{d.col} :: {d.message}")
        return False
    lines.append("  conformant.vaked: 0 diagnostics")
    return True


# --------------------------------------------------------------------------- #
# 4. Rejected → exactly the three documented codes + golden snapshot
# --------------------------------------------------------------------------- #

_EXPECTED_REJECTED = ["E-CAP-ATTENUATION", "E-CONSTRAINT-RANGE",
                      "E-CONFORM-UNKNOWN-FIELD"]


def _test_rejected(lines):
    ok = True
    cache = _builtins_cache()
    rel = os.path.relpath(REJECTED, REPO)
    diags = vakedc.check_source(open(REJECTED, encoding="utf-8").read(), rel,
                                builtins_cache=cache)
    codes = [d.code for d in diags]
    if codes != _EXPECTED_REJECTED:
        ok = False
        lines.append(f"  FAIL rejected: expected exactly {_EXPECTED_REJECTED}, "
                     f"got {codes}")

    produced = _diagnostics_json(diags)
    if not os.path.exists(GOLDEN):
        ok = False
        lines.append(f"  FAIL rejected: missing golden {GOLDEN}")
    else:
        expected = open(GOLDEN, encoding="utf-8").read()
        if produced != expected:
            ok = False
            lines.append("  FAIL rejected: --json differs from "
                         "tests/spec/golden/rejected.diagnostics.json")
            for i, (a, b) in enumerate(zip(produced, expected)):
                if a != b:
                    lines.append(f"    first diff at byte {i}: "
                                 f"produced {a!r} vs golden {b!r}")
                    break
            else:
                lines.append(f"    length differs: produced {len(produced)} "
                             f"vs golden {len(expected)}")
    if ok:
        lines.append("  rejected.vaked: exactly the 3 documented codes; "
                     "--json byte-identical to golden")
    return ok


# --------------------------------------------------------------------------- #
# 5. All 15 examples check clean (rejected is the sole exception)
# --------------------------------------------------------------------------- #

def _test_all_examples(lines):
    ok = True
    cache = _builtins_cache()
    n_clean = 0
    files = _all_examples()
    for f in files:
        rel = os.path.relpath(f, REPO)
        diags = vakedc.check_source(open(f, encoding="utf-8").read(), rel,
                                    builtins_cache=cache)
        if os.path.basename(f) == "rejected.vaked":
            continue   # intentionally invalid (covered by group 4)
        if diags:
            ok = False
            lines.append(f"  FAIL examples: {rel} expected clean, "
                         f"got {len(diags)} {[d.code for d in diags]}")
            for d in diags[:4]:
                lines.append(f"      {d.code} @ {d.line}:{d.col} :: {d.message}")
        else:
            n_clean += 1
    lines.append(f"  examples: {n_clean}/{len(files) - 1} non-rejected examples "
                 f"check clean (+ rejected.vaked covered separately)")
    return ok


# --------------------------------------------------------------------------- #
# 6. Determinism
# --------------------------------------------------------------------------- #

def _test_determinism(lines):
    cache = _builtins_cache()
    rel = os.path.relpath(REJECTED, REPO)
    src = open(REJECTED, encoding="utf-8").read()
    j1 = _diagnostics_json(vakedc.check_source(src, rel, builtins_cache=cache))
    j2 = _diagnostics_json(vakedc.check_source(src, rel, builtins_cache=cache))
    # also re-read the catalog fresh on the second run (no caching) to prove the
    # IO path is deterministic too.
    j3 = _diagnostics_json(vakedc.check_source(src, rel, builtins_path=BUILTINS))
    if j1 == j2 == j3:
        lines.append("  determinism: identical diagnostics JSON across runs "
                     "(cached + fresh catalog)")
        return True
    lines.append("  FAIL determinism: diagnostics JSON differs across runs")
    return False


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #

def run():
    lines = []
    ok = True
    for fn in (_test_builtins, _test_coverage, _test_conformant, _test_rejected,
               _test_all_examples, _test_determinism):
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
    print("== test_vakedc_check ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
