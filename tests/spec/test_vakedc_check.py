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
5. All examples. All 17 ``.vaked`` examples check clean (rejected.vaked is the
   sole intentional exception — see group 4).
5b. Ref resolution (#7). Closed-world resolution: a kind-qualified or bare
   data-flow / `fibers` ref inside a `runtime {}` must resolve to an in-runtime
   (or imported) declaration; bare top-level fragments are not enforced.
5c. Import binding. A bare ref to a `use`-imported declaration resolves
   (fixtures under tests/spec/fixtures/refres/).
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
# 5. All 17 examples check clean (rejected is the sole exception)
# --------------------------------------------------------------------------- #

def _test_all_examples(lines):
    ok = True
    cache = _builtins_cache()
    n_clean = 0
    files = _all_examples()
    for f in files:
        rel = os.path.relpath(f, REPO)
        # base_dir = the file's real directory so `use` imports resolve
        # independent of CWD (operator-field.vaked imports ./engines/zig.vaked).
        diags = vakedc.check_source(open(f, encoding="utf-8").read(), rel,
                                    builtins_cache=cache,
                                    base_dir=os.path.dirname(f))
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
# 5b. Closed-world reference resolution (#7 — 0011 §6.1 stage 2)
# --------------------------------------------------------------------------- #
# A `<kind>.<name>` data-flow ref (engine/input/output/from/source) inside a
# `runtime {}` block must resolve to an in-runtime declaration of that kind;
# otherwise it is E-REF-UNRESOLVED.  Bare top-level fragments (no enclosing
# runtime) are illustrative and NOT enforced.

_REF_UNRESOLVED = "E-REF-UNRESOLVED"

# A complete runtime whose fiber inputs an UNDECLARED stream (kind-qualified).
# The `engine`/`output` refs are deliberately resolvable (declared engine; a
# non-kind `artifacts.*` output is branch-B, unenforced) so the ONLY unresolved
# ref is the kind-qualified `stream.nope`.
_RR_UNRESOLVED = '''runtime "t" {
  systems = ["x86_64-linux"]
  engine e { package = nix.derivation }
  stream s { source = agentGuardd.ringbuf  type = Event.Ebpf }
  fiber f {
    engine = e
    input  = stream.nope
    output = artifacts.x
  }
}
'''

# Same runtime, but the fiber inputs the DECLARED stream `s`.
_RR_RESOLVED = '''runtime "t" {
  systems = ["x86_64-linux"]
  engine e { package = nix.derivation }
  stream s { source = agentGuardd.ringbuf  type = Event.Ebpf }
  fiber f {
    engine = e
    input  = stream.s
    output = artifacts.x
  }
}
'''

# The SAME undeclared kind-qualified ref, but as a bare top-level fragment
# (no enclosing runtime) — must NOT be enforced.
_RR_FRAGMENT = '''fiber f {
  engine = someEngine
  input  = stream.nope
  output = artifacts.x
}
'''

# Bare-name refs inside a runtime are also enforced: a bare `engine` must name
# an in-runtime (or imported) declaration.
_RR_BARE_ENGINE = '''runtime "t" {
  systems = ["x86_64-linux"]
  stream s { source = agentGuardd.ringbuf  type = Event.Ebpf }
  fiber f {
    engine = ghostEngine
    input  = stream.s
    output = artifacts.x
  }
}
'''

# A bare member of a `parallel`'s `fibers` list must also resolve in-runtime.
_RR_BARE_FIBER = '''runtime "t" {
  systems = ["x86_64-linux"]
  engine e { package = nix.derivation }
  stream s { source = agentGuardd.ringbuf  type = Event.Ebpf }
  fiber f {
    engine = e
    input  = stream.s
    output = artifacts.x
  }
  parallel "p" {
    fibers = [f, ghostFiber]
    strategy = "supervised-dag"
    supervisor = otp
  }
}
'''


# Cohort (#1-#6) accessor refs: secret.X.path / hostResource.X.dsn nested inside
# a service's `options { … }` config block must resolve to in-runtime decls.
_RR_ACCESSOR_OK = '''runtime "t" {
  systems = ["x86_64-linux"]
  secret appSecret { provider = "sops" name = "umami_app_secret" }
  hostResource db { kind = "postgresql" name = "umami" }
  service umami {
    package = pkgs.umami
    bind = loopback(3003)
    options {
      APP_SECRET_FILE = secret.appSecret.path
      DATABASE_URL    = hostResource.db.dsn
    }
  }
}
'''

# Same, but the secret accessor names an UNDECLARED secret.
_RR_ACCESSOR_BAD = '''runtime "t" {
  systems = ["x86_64-linux"]
  hostResource db { kind = "postgresql" name = "umami" }
  service umami {
    package = pkgs.umami
    options {
      APP_SECRET_FILE = secret.ghost.path
      DATABASE_URL    = hostResource.db.dsn
    }
  }
}
'''


def _test_ref_resolution(lines):
    cache = _builtins_cache()

    def codes(src, name):
        return [d.code for d in vakedc.check_source(src, name, builtins_cache=cache)]

    ok = True

    acc_ok = [c for c in codes(_RR_ACCESSOR_OK, "rr-accessor-ok.vaked")
              if c == _REF_UNRESOLVED]
    if acc_ok:
        ok = False
        lines.append(f"  FAIL ref-res: declared secret.X.path / hostResource.X.dsn "
                     f"(in a service `options` block) should resolve, got {acc_ok}")

    acc_bad = [c for c in codes(_RR_ACCESSOR_BAD, "rr-accessor-bad.vaked")
               if c == _REF_UNRESOLVED]
    if acc_bad != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ref-res: undeclared `secret.ghost.path` should yield "
                     f"exactly one {_REF_UNRESOLVED}, got {acc_bad}")

    unresolved = [c for c in codes(_RR_UNRESOLVED, "rr-unresolved.vaked")
                  if c == _REF_UNRESOLVED]
    if unresolved != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ref-res: runtime with `input = stream.nope` should "
                     f"yield exactly one {_REF_UNRESOLVED}, got {unresolved}")

    resolved = [c for c in codes(_RR_RESOLVED, "rr-resolved.vaked")
                if c == _REF_UNRESOLVED]
    if resolved:
        ok = False
        lines.append(f"  FAIL ref-res: runtime with `input = stream.s` (declared) "
                     f"should yield no {_REF_UNRESOLVED}, got {resolved}")

    fragment = [c for c in codes(_RR_FRAGMENT, "rr-fragment.vaked")
                if c == _REF_UNRESOLVED]
    if fragment:
        ok = False
        lines.append(f"  FAIL ref-res: bare top-level fragment (no runtime) must "
                     f"not be enforced, got {fragment}")

    bare_engine = [c for c in codes(_RR_BARE_ENGINE, "rr-bare-engine.vaked")
                   if c == _REF_UNRESOLVED]
    if bare_engine != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ref-res: runtime with bare `engine = ghostEngine` "
                     f"should yield exactly one {_REF_UNRESOLVED}, got {bare_engine}")

    bare_fiber = [c for c in codes(_RR_BARE_FIBER, "rr-bare-fiber.vaked")
                  if c == _REF_UNRESOLVED]
    if bare_fiber != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ref-res: runtime with bare `fibers = [..., ghostFiber]` "
                     f"should yield exactly one {_REF_UNRESOLVED}, got {bare_fiber}")

    if ok:
        lines.append("  ref-resolution: kind-qualified + bare refs enforced inside "
                     "runtime; fragments illustrative")
    return ok


# --------------------------------------------------------------------------- #
# 5c. `use`-import binding (#7 fast-follow) — a bare ref to an imported decl
# --------------------------------------------------------------------------- #
# `use "./dep.vaked"` binds dep.vaked's top-level decls into this file's scope,
# so a runtime may reference them by name.  Without binding, the bare
# `engine = depEngine` in main.vaked would be E-REF-UNRESOLVED.

_REFRES_FIXT = os.path.join(HERE, "fixtures", "refres")


def _test_import_binding(lines):
    cache = _builtins_cache()
    main = os.path.join(_REFRES_FIXT, "main.vaked")
    diags = vakedc.check_source(open(main, encoding="utf-8").read(),
                                os.path.relpath(main, REPO),
                                builtins_cache=cache,
                                base_dir=_REFRES_FIXT)
    unresolved = [d for d in diags if d.code == _REF_UNRESOLVED]
    if unresolved:
        lines.append(f"  FAIL import-binding: `engine = depEngine` (imported from "
                     f"dep.vaked) should resolve, got "
                     f"{[d.message for d in unresolved]}")
        return False
    lines.append("  import-binding: bare ref to a `use`-imported decl resolves")
    return True


# --------------------------------------------------------------------------- #
# 5d. Workflow step-DAG checks (#27 — 0015)
# --------------------------------------------------------------------------- #
# A `workflow` is a typed agent-step DAG: step bodies conform to workflowStep,
# the `->` edges must be acyclic (E-WORKFLOW-CYCLE), and a declared `maxDepth`
# bounds the longest step chain (E-WORKFLOW-DEPTH).

_WF_CYCLE = '''workflow cyclic {
  node a { agent = m.x }
  node b { agent = m.y }
  a -> b
  b -> a
}
'''

_WF_DEEP = '''workflow deep {
  maxDepth = 2
  node p { agent = m.x }
  node q { agent = m.y }
  node r { agent = m.z }
  p -> q -> r
}
'''

_WF_NO_AGENT = '''workflow noagent {
  node s { input = artifacts.x }
}
'''

# A valid workflow: DAG with fan-out, depth 3 == maxDepth 3, all steps agented.
_WF_OK = '''workflow ok {
  maxDepth = 3
  node a { agent = m.x }
  node b { agent = m.y  retries = 1 }
  node c { agent = m.z }
  a -> b -> c
  a -> c
}
'''

# Codex review fixes (PR #26): a non-integer maxDepth must not crash the
# checker — the Int constraint owns the diagnostic, the depth bound is simply
# not enforced; an `agent` ref whose head names a SIBLING mesh must name one
# of that mesh's nodes, while unknown heads stay unvalidated (branch B, #8).
_WF_FLOAT_DEPTH = '''workflow w {
  maxDepth = 2.5
  node a { agent = m.x }
}
'''

_WF_AGENT_TYPO = '''mesh field {
  node planner { role = "plan" }
}
workflow w {
  node a { agent = field.planner }
  node b { agent = field.ghost }
  node c { agent = missingMesh.missingNode }
  a -> b -> c
}
'''


def _test_workflow(lines):
    cache = _builtins_cache()

    def codes(src, name):
        return [d.code for d in vakedc.check_source(src, name, builtins_cache=cache)]

    ok = True
    cases = [
        (_WF_CYCLE, "wf-cycle.vaked", ["E-WORKFLOW-CYCLE"]),
        (_WF_DEEP, "wf-deep.vaked", ["E-WORKFLOW-DEPTH"]),
        (_WF_NO_AGENT, "wf-noagent.vaked", ["E-CONFORM-MISSING-FIELD"]),
        (_WF_OK, "wf-ok.vaked", []),
        (_WF_FLOAT_DEPTH, "wf-float.vaked", ["E-CONFORM-TYPE"]),
        (_WF_AGENT_TYPO, "wf-agent-typo.vaked", ["E-REF-UNRESOLVED"]),
    ]
    for src, name, want in cases:
        got = codes(src, name)
        if got != want:
            ok = False
            lines.append(f"  FAIL workflow: {name} expected {want}, got {got}")
    if ok:
        lines.append("  workflow: cycle/depth/missing-agent rejected; "
                     "fan-out DAG at the depth bound checks clean")
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
               _test_all_examples, _test_ref_resolution, _test_import_binding,
               _test_workflow, _test_determinism):
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
