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
_CAP_USE_BROKEN = frozenset((
    "cap-use-underpowered.vaked",
    "cap-use-no-caps.vaked",
    "cap-use-wrong-domain.vaked",
    "cap-use-partial.vaked",
    "cap-use-two-nodes.vaked",
    "cap-use-and-excess.vaked",
    "cap-use-and-attenuation.vaked",
))
_EGRESS_BROKEN = frozenset((
    "egress-use-exceeds.vaked",
    "egress-use-bad-principal.vaked",
))
def _test_all_examples(lines):
    ok = True
    cache = _builtins_cache()
    n_clean = 0
    files = _all_examples()
    for f in files:
        rel = os.path.relpath(f, REPO)
        diags = vakedc.check_source(open(f, encoding="utf-8").read(), rel,
                                    builtins_cache=cache,
                                    base_dir=os.path.dirname(f))
        if os.path.basename(f) == "rejected.vaked":
            continue   # intentionally invalid (covered by group 4)
        if os.path.basename(f) == "error-unknown-namespace.vaked":
            continue
        if os.path.basename(f) in _CAP_USE_BROKEN:
            continue
        if os.path.basename(f) in _EGRESS_BROKEN:
            continue
        errs = [d for d in diags if d.severity == "error"]
        if errs:
            ok = False
            lines.append(f"  FAIL examples: {rel} expected clean, "
                         f"got {len(errs)} {[d.code for d in errs]}")
            for d in errs[:4]:
                lines.append(f"      {d.code} @ {d.line}:{d.col} :: {d.message}")
        else:
            n_clean += 1
    n_excluded = 2 + len(_CAP_USE_BROKEN) + len(_EGRESS_BROKEN)
    lines.append(f"  examples: {n_clean}/{len(files) - n_excluded} non-error examples "
                 f"check clean (+ rejected.vaked + error-unknown-namespace.vaked "
                 f"+ {len(_CAP_USE_BROKEN)} cap-use-* + {len(_EGRESS_BROKEN)} "
                 f"egress-use-* fixtures covered separately)")
    return ok
_REF_UNRESOLVED = "E-REF-UNRESOLVED"
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
_RR_FRAGMENT = '''fiber f {
  engine = someEngine
  input  = stream.nope
  output = artifacts.x
}
'''
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
_RR_RUNCLASS = '''runtime "t" {
  systems = ["x86_64-linux"]
  engine e { package = nix.derivation }
  stream s { source = agentGuardd.ringbuf  type = Event.Ebpf }
  fiber f {
    engine = e
    input  = stream.s
    output = artifacts.x
    runclass = runclass.ghost
  }
}
'''
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
_RR_ISSUE7_REPRO = '''runtime "repro" {
  systems = ["x86_64-linux"]
  fiber f {
    engine = pkgs.doesNotExist
    input  = stream.neverDeclared
    output = artifacts.whatever
  }
}
'''
def _test_ref_resolution(lines):
    cache = _builtins_cache()
    def codes(src, name):
        return [d.code for d in vakedc.check_source(src, name, builtins_cache=cache)]
    ok = True
    repro = [c for c in codes(_RR_ISSUE7_REPRO, "issue7-repro.vaked")
             if c == _REF_UNRESOLVED]
    if repro != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ref-res (#7 reproducer): `input = stream.neverDeclared` "
                     f"must yield exactly one {_REF_UNRESOLVED} (engine=pkgs.X open-ns "
                     f"OK, output=artifacts.X is a write), got {repro}")
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
    rc = [c for c in codes(_RR_RUNCLASS, "rr-runclass.vaked")
          if c == _REF_UNRESOLVED]
    if rc != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ref-res: undeclared `runclass.ghost` should yield "
                     f"exactly one {_REF_UNRESOLVED}, got {rc}")
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
_COLLIDE = "E-DECL-NAME-COLLISION"
_NC_DIFF_KIND = '''schema memory { field topic : String { nonempty } }
capability memory { grant none recall
                    order none < recall }
'''
_NC_TRIPLE = '''engine dup { package = nix.derivation }
schema dup { field x : Int { optional } }
capability dup { grant none a
                 order none < a }
'''
_NC_CLEAN = '''schema memory { field topic : String { nonempty } }
capability mem { grant none recall
                 order none < recall }
'''
_NC_NESTED = '''runtime r {
  schema dup { field x : Int { optional } }
  capability dup { grant none a
                   order none < a }
}
'''
_NC_CROSS_LEVEL = '''schema memory { field topic : String { nonempty } }
runtime r {
  stream memory { from = source.x }
}
'''
def _test_name_collision(lines):
    cache = _builtins_cache()
    def diags(src, name):
        return vakedc.check_source(src, name, builtins_cache=cache)
    ok = True
    diff = [d for d in diags(_NC_DIFF_KIND, "nc-diff.vaked") if d.code == _COLLIDE]
    if len(diff) != 1:
        ok = False
        lines.append(f"  FAIL name-collision: `schema memory` + `capability memory` "
                     f"should yield exactly one {_COLLIDE}, got {[d.code for d in diff]}")
    elif not diff[0].related:
        ok = False
        lines.append("  FAIL name-collision: collision diagnostic should carry a "
                     "`related` span pointing at the first declaration")
    triple = [d for d in diags(_NC_TRIPLE, "nc-triple.vaked") if d.code == _COLLIDE]
    if len(triple) != 2:
        ok = False
        lines.append(f"  FAIL name-collision: three same-name decls should yield two "
                     f"{_COLLIDE} (2nd + 3rd), got {len(triple)}")
    clean = [d for d in diags(_NC_CLEAN, "nc-clean.vaked") if d.code == _COLLIDE]
    if clean:
        ok = False
        lines.append(f"  FAIL name-collision: distinct names (`memory`/`mem`) must "
                     f"not collide, got {len(clean)}")
    nested = [d for d in diags(_NC_NESTED, "nc-nested.vaked") if d.code == _COLLIDE]
    if len(nested) != 1:
        ok = False
        lines.append(f"  FAIL name-collision: nested `schema dup` + `capability dup` "
                     f"in one runtime should yield exactly one {_COLLIDE}, got "
                     f"{len(nested)}")
    elif not nested[0].related:
        ok = False
        lines.append("  FAIL name-collision: nested collision diagnostic should carry "
                     "a `related` span pointing at the first declaration")
    cross = [d for d in diags(_NC_CROSS_LEVEL, "nc-cross.vaked") if d.code == _COLLIDE]
    if cross:
        ok = False
        lines.append(f"  FAIL name-collision: same name at different nesting levels "
                     f"(top-level `memory` vs nested `stream memory`) must not "
                     f"collide, got {len(cross)}")
    if ok:
        lines.append("  name-collision: same-name top-level AND nested-sibling decls "
                     "flagged (E-DECL-NAME-COLLISION); distinct names / cross-level "
                     "reuse clean")
    return ok
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
_WF_OK = '''workflow ok {
  maxDepth = 3
  node a { agent = m.x }
  node b { agent = m.y  retries = 1 }
  node c { agent = m.z }
  a -> b -> c
  a -> c
}
'''
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
_WF_AGENT_NONMESH = '''stream field {
  source = agentGuardd.ringbuf
  type = Event.Ebpf
}
workflow w {
  node a { agent = field.worker }
  node b { agent = external.thing }
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
        (_WF_AGENT_NONMESH, "wf-agent-nonmesh.vaked", ["E-REF-UNRESOLVED"]),
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
_NS_OPEN = '''runtime "t" {
  systems = ["x86_64-linux"]
  stream s { source = pkgs.anyMemberAtAll  type = T }
}
'''
_NS_CLOSED_OK = '''runtime "t" {
  systems = ["x86_64-linux"]
  namespace agentGuardd { member ringbuf }
  stream s { source = agentGuardd.ringbuf  type = Event.Ebpf }
}
'''
_NS_CLOSED_BAD = '''runtime "t" {
  systems = ["x86_64-linux"]
  namespace agentGuardd { member ringbuf }
  stream s { source = agentGuardd.ringbufff  type = Event.Ebpf }
}
'''
_NS_UNKNOWN_HEAD = '''runtime "t" {
  systems = ["x86_64-linux"]
  stream s { source = totallymadeup.thing  type = T }
}
'''
_NS_ARTIFACTS_PASS = '''runtime "t" {
  systems = ["x86_64-linux"]
  engine e { package = nix.derivation }
  stream s { source = agentGuardd.ringbuf  type = T }
  fiber f {
    engine = e
    input  = stream.s
    output = artifacts.plan
  }
}
'''
_NS_GLOBAL_FALLBACK = '''runtime "t" {
  systems = ["x86_64-linux"]
  stream s { source = agentGuardd.ringbuf  type = Event.Ebpf }
}
'''
_NS_ERROR_FILE = os.path.join(REPO, "vaked", "examples", "namespace",
                              "error-unknown-namespace.vaked")
def _test_namespace_checker(lines):
    cache = _builtins_cache()
    ok = True
    def codes(src, name):
        return [d.code for d in vakedc.check_source(src, name, builtins_cache=cache)]
    got = [c for c in codes(_NS_OPEN, "ns-open.vaked") if c == _REF_UNRESOLVED]
    if got:
        ok = False
        lines.append(f"  FAIL ns: open namespace (pkgs) should accept any member, "
                     f"got {got}")
    got = [c for c in codes(_NS_CLOSED_OK, "ns-closed-ok.vaked") if c == _REF_UNRESOLVED]
    if got:
        ok = False
        lines.append(f"  FAIL ns: declared member of closed namespace should resolve, "
                     f"got {got}")
    got = [c for c in codes(_NS_CLOSED_BAD, "ns-closed-bad.vaked") if c == _REF_UNRESOLVED]
    if got != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ns: unknown member of closed namespace should yield one "
                     f"{_REF_UNRESOLVED}, got {got}")
    got = [c for c in codes(_NS_UNKNOWN_HEAD, "ns-unknown-head.vaked") if c == _REF_UNRESOLVED]
    if got != [_REF_UNRESOLVED]:
        ok = False
        lines.append(f"  FAIL ns: unknown namespace head should yield one "
                     f"{_REF_UNRESOLVED}, got {got}")
    got = [c for c in codes(_NS_ARTIFACTS_PASS, "ns-artifacts.vaked") if c == _REF_UNRESOLVED]
    if got:
        ok = False
        lines.append(f"  FAIL ns: artifacts.* (D1-deferred) should pass silently, "
                     f"got {got}")
    got = [c for c in codes(_NS_GLOBAL_FALLBACK, "ns-global-fallback.vaked") if c == _REF_UNRESOLVED]
    if got:
        ok = False
        lines.append(f"  FAIL ns: global catalog fallback for daemon channel should "
                     f"pass, got {got}")
    if os.path.exists(_NS_ERROR_FILE):
        err_diags = vakedc.check_source(
            open(_NS_ERROR_FILE, encoding="utf-8").read(),
            os.path.relpath(_NS_ERROR_FILE, REPO),
            builtins_cache=cache,
            base_dir=os.path.dirname(_NS_ERROR_FILE),
        )
        err_codes = [d.code for d in err_diags if d.code == _REF_UNRESOLVED]
        if len(err_codes) != 2:
            ok = False
            lines.append(f"  FAIL ns: error-unknown-namespace.vaked should yield exactly "
                         f"2 {_REF_UNRESOLVED}, got {err_codes}")
    else:
        ok = False
        lines.append(f"  FAIL ns: error-unknown-namespace.vaked not found at "
                     f"{_NS_ERROR_FILE}")
    if ok:
        lines.append("  namespace checker (RFC 0017): open/closed/unknown-head/D1-deferred "
                     "all correct; error-unknown-namespace.vaked yields exactly 2 "
                     "E-REF-UNRESOLVED")
    return ok
_EBPF_ENFORCE_ON_KPROBE = '''ebpf badGuard {
  hook   = "kprobe"
  intent = "enforce"
}
'''
_EBPF_ENFORCE_ON_TRACEPOINT = '''ebpf badGuard {
  hook   = "tracepoint"
  intent = "enforce"
}
'''
_EBPF_OBSERVE_ON_KPROBE_OK = '''ebpf okGuard {
  hook   = "kprobe"
  intent = "observe"
}
'''
_EBPF_ENFORCE_ON_LSM_OK = '''ebpf lsmGuard {
  hook   = "lsm"
  intent = "enforce"
}
'''
_EBPF_ENFORCE_ON_CGROUP_OK = '''ebpf egressGuard {
  hook   = "cgroup_connect"
  intent = "enforce"
}
'''
_EBPF_BAD_HOOK = '''ebpf typoGuard {
  hook   = "kprobr"
  intent = "observe"
}
'''
def _test_ebpf_intent(lines):
    cache = _builtins_cache()
    def codes(src, name):
        return [d.code for d in vakedc.check_source(src, name, builtins_cache=cache)]
    ok = True
    cases = [
        (_EBPF_ENFORCE_ON_KPROBE, "ebpf-enforce-kprobe.vaked",
         ["E-EBPF-ENFORCE-ON-OBSERVE"]),
        (_EBPF_ENFORCE_ON_TRACEPOINT, "ebpf-enforce-tracepoint.vaked",
         ["E-EBPF-ENFORCE-ON-OBSERVE"]),
        (_EBPF_OBSERVE_ON_KPROBE_OK, "ebpf-observe-kprobe.vaked", []),
        (_EBPF_ENFORCE_ON_LSM_OK, "ebpf-enforce-lsm.vaked", []),
        (_EBPF_ENFORCE_ON_CGROUP_OK, "ebpf-enforce-cgroup.vaked", []),
        (_EBPF_BAD_HOOK, "ebpf-bad-hook.vaked", ["E-EBPF-UNKNOWN-HOOK"]),
    ]
    for src, name, want in cases:
        got = codes(src, name)
        if got != want:
            ok = False
            lines.append(f"  FAIL ebpf-intent: {name} expected {want}, got {got}")
    if ok:
        lines.append("  ebpf-intent (#225): enforce on kprobe/tracepoint rejected; "
                     "observe-on-kprobe and enforce-on-lsm/cgroup check clean")
    return ok
def _test_determinism(lines):
    cache = _builtins_cache()
    rel = os.path.relpath(REJECTED, REPO)
    src = open(REJECTED, encoding="utf-8").read()
    j1 = _diagnostics_json(vakedc.check_source(src, rel, builtins_cache=cache))
    j2 = _diagnostics_json(vakedc.check_source(src, rel, builtins_cache=cache))
    j3 = _diagnostics_json(vakedc.check_source(src, rel, builtins_path=BUILTINS))
    if j1 == j2 == j3:
        lines.append("  determinism: identical diagnostics JSON across runs "
                     "(cached + fresh catalog)")
        return True
    lines.append("  FAIL determinism: diagnostics JSON differs across runs")
    return False
_DB_REJECT = '''mesh field {
  node planner { role = "plan" }
}
workflow w {
  node decide { agent = field.planner  control = true  effects = ["llm"] }
}
'''
_DB_PURE_OK = '''mesh field {
  node planner { role = "plan" }
}
workflow w {
  node fanout { agent = field.planner  control = true }
}
'''
_DB_STEP_OK = '''mesh field {
  node planner { role = "plan" }
}
workflow w {
  node code { agent = field.planner  effects = ["llm", "network"] }
}
'''
def _test_determinism_boundary(lines):
    cache = _builtins_cache()
    def codes(src, name):
        return [d.code for d in vakedc.check_source(src, name, builtins_cache=cache)]
    ok = True
    cases = [
        (_DB_REJECT, "db-reject.vaked", ["E-DETERMINISM-EFFECT"]),
        (_DB_PURE_OK, "db-pure-ok.vaked", []),
        (_DB_STEP_OK, "db-step-ok.vaked", []),
    ]
    for src, name, want in cases:
        got = codes(src, name)
        if got != want:
            ok = False
            lines.append(f"  FAIL determinism-boundary: {name} expected {want}, "
                         f"got {got}")
    diags = vakedc.check_source(_DB_REJECT, "db-reject.vaked", builtins_cache=cache)
    eff = [d for d in diags if d.code == "E-DETERMINISM-EFFECT"]
    if not eff or "decide" not in eff[0].message or "llm" not in eff[0].message:
        ok = False
        msg = eff[0].message if eff else "(none)"
        lines.append(f"  FAIL determinism-boundary: diagnostic must name step "
                     f"`decide` and effect `llm`; got: {msg}")
    if ok:
        lines.append("  determinism-boundary: control-flow step with a "
                     "side-effecting effect rejected; pure coordination and "
                     "side-effecting steps check clean")
    return ok
_POLA_EXCESS = "W-POLA-EXCESS"
_CONFUSED_DEPUTY = "W-CONFUSED-DEPUTY"
POLA_VIOLATION = os.path.join(REPO, "vaked", "examples", "types", "pola-violation.vaked")
POLA_CLEAN = os.path.join(REPO, "vaked", "examples", "types", "pola-least-authority.vaked")
def _test_capability_reachability(lines):
    ok = True
    cache = _builtins_cache()
    rel = os.path.relpath(POLA_VIOLATION, REPO)
    vdiags = vakedc.check_source(open(POLA_VIOLATION, encoding="utf-8").read(), rel,
                                 builtins_cache=cache)
    errs = [d for d in vdiags if d.severity == "error"]
    if errs:
        ok = False
        lines.append(f"  FAIL reach: pola-violation has {len(errs)} errors "
                     f"{[d.code for d in errs]} (expected warnings only)")
    excess = [d for d in vdiags if d.code == _POLA_EXCESS]
    deputy = [d for d in vdiags if d.code == _CONFUSED_DEPUTY]
    if len(excess) != 1:
        ok = False
        lines.append(f"  FAIL reach: expected 1 {_POLA_EXCESS}, got {len(excess)}")
    if len(deputy) != 1:
        ok = False
        lines.append(f"  FAIL reach: expected 1 {_CONFUSED_DEPUTY}, got {len(deputy)}")
    for d in excess + deputy:
        if d.severity != "warning":
            ok = False
            lines.append(f"  FAIL reach: {d.code} severity is {d.severity} "
                         f"(expected warning)")
    if excess and "builder" not in excess[0].message:
        ok = False
        lines.append(f"  FAIL reach: {_POLA_EXCESS} message lacks node name: "
                     f"{excess[0].message}")
    if deputy:
        m = deputy[0].message
        if "proxy" not in m or "worker" not in m or "cron" not in m:
            ok = False
            lines.append(f"  FAIL reach: {_CONFUSED_DEPUTY} message lacks "
                         f"node/edge names: {m}")
    relc = os.path.relpath(POLA_CLEAN, REPO)
    cdiags = vakedc.check_source(open(POLA_CLEAN, encoding="utf-8").read(), relc,
                                 builtins_cache=cache)
    noise = [d for d in cdiags
             if d.severity == "error" or d.code in (_POLA_EXCESS, _CONFUSED_DEPUTY)]
    if noise:
        ok = False
        lines.append(f"  FAIL reach: pola-least-authority expected clean, got "
                     f"{[d.code for d in noise]}")
    if ok:
        lines.append("  reach: POLA-excess + confused-deputy lints fire on the "
                     "violation example and stay silent on the clean one")
    return ok
_CAP_USE = "E-CAP-USE"
_CAP_USE_DIR = os.path.join(REPO, "vaked", "examples", "types")
_CAP_USE_CASES = [
    ("cap-use-underpowered.vaked",     [_CAP_USE]),
    ("cap-use-no-caps.vaked",          [_CAP_USE]),
    ("cap-use-wrong-domain.vaked",     [_CAP_USE]),
    ("cap-use-partial.vaked",          [_CAP_USE]),
    ("cap-use-two-nodes.vaked",        [_CAP_USE]),
    ("cap-use-and-excess.vaked",       [_CAP_USE, _POLA_EXCESS]),
    ("cap-use-and-attenuation.vaked",  ["E-CAP-ATTENUATION", _CAP_USE]),
]
def _test_cap_use(lines):
    ok = True
    cache = _builtins_cache()
    for base, expect in _CAP_USE_CASES:
        path = os.path.join(_CAP_USE_DIR, base)
        rel = os.path.relpath(path, REPO)
        diags = vakedc.check_source(open(path, encoding="utf-8").read(), rel,
                                    builtins_cache=cache)
        codes = sorted(d.code for d in diags)
        if codes != sorted(expect):
            ok = False
            lines.append(f"  FAIL cap-use: {base} expected {sorted(expect)}, "
                         f"got {codes}")
            continue
        for d in diags:
            if d.code != _CAP_USE:
                continue
            if d.severity != "error":
                ok = False
                lines.append(f"  FAIL cap-use: {base} {_CAP_USE} severity is "
                             f"{d.severity} (expected error)")
            if "node `" not in d.message or "(0011 §4.3)" not in d.message:
                ok = False
                lines.append(f"  FAIL cap-use: {base} {_CAP_USE} message lacks "
                             f"node name / §-ref: {d.message}")
            if (d.byteStart, d.byteEnd) == (0, 0):
                ok = False
                lines.append(f"  FAIL cap-use: {base} {_CAP_USE} is not "
                             f"source-mapped (span 0..0)")
    pdiags = vakedc.check_source(
        open(os.path.join(_CAP_USE_DIR, "cap-use-partial.vaked"),
             encoding="utf-8").read(),
        "cap-use-partial.vaked", builtins_cache=cache)
    puse = [d for d in pdiags if d.code == _CAP_USE]
    if len(puse) != 1 or "network.egress" not in puse[0].message:
        ok = False
        lines.append(f"  FAIL cap-use: partial expected 1 {_CAP_USE} naming "
                     f"network.egress, got {[d.message for d in puse]}")
    tdiags = vakedc.check_source(
        open(os.path.join(_CAP_USE_DIR, "cap-use-two-nodes.vaked"),
             encoding="utf-8").read(),
        "cap-use-two-nodes.vaked", builtins_cache=cache)
    tuse = [d for d in tdiags if d.code == _CAP_USE]
    if len(tuse) != 1 or "`reviewer`" not in tuse[0].message \
            or "`author`" in tuse[0].message:
        ok = False
        lines.append(f"  FAIL cap-use: two-nodes expected 1 {_CAP_USE} on "
                     f"`reviewer` only, got {[d.message for d in tuse]}")
    ndiags = vakedc.check_source(
        open(os.path.join(_CAP_USE_DIR, "cap-use-no-needs.vaked"),
             encoding="utf-8").read(),
        "cap-use-no-needs.vaked", builtins_cache=cache)
    if ndiags:
        ok = False
        lines.append(f"  FAIL cap-use: cap-use-no-needs expected clean (opt-out), "
                     f"got {[d.code for d in ndiags]}")
    if ok:
        lines.append("  cap-use (Risk 6): E-CAP-USE fires on underpowered / "
                     "no-caps / wrong-domain / partial / two-node nodes (+ combos "
                     "with W-POLA-EXCESS and E-CAP-ATTENUATION); the no-needs "
                     "opt-out stays clean")
    return ok
_EGRESS_USE = "E-EGRESS-USE"
_EGRESS_UNREF = "W-EGRESS-UNREFINED"
_EGRESS_DIR = os.path.join(REPO, "vaked", "examples", "types")
_EGRESS_CASES = [
    ("egress-use-exceeds.vaked",       [_EGRESS_USE]),
    ("egress-use-ok.vaked",            []),
    ("egress-unrefined.vaked",         [_EGRESS_UNREF]),
    ("egress-use-bad-principal.vaked", [_EGRESS_USE]),
]
def _test_egress_use(lines):
    ok = True
    cache = _builtins_cache()
    for base, expect in _EGRESS_CASES:
        path = os.path.join(_EGRESS_DIR, base)
        rel = os.path.relpath(path, REPO)
        diags = vakedc.check_source(open(path, encoding="utf-8").read(), rel, builtins_cache=cache)
        codes = sorted(d.code for d in diags)
        if codes != sorted(expect):
            ok = False
            lines.append(f"  FAIL egress-use: {base} expected {sorted(expect)}, got {codes}")
            continue
        for d in diags:
            if d.code == _EGRESS_USE and d.severity != "error":
                ok = False; lines.append(f"  FAIL egress-use: {base} {_EGRESS_USE} not error")
            if d.code == _EGRESS_UNREF and d.severity != "warning":
                ok = False; lines.append(f"  FAIL egress-use: {base} {_EGRESS_UNREF} not warning")
            if d.code in (_EGRESS_USE, _EGRESS_UNREF) and (d.byteStart, d.byteEnd) == (0, 0):
                ok = False; lines.append(f"  FAIL egress-use: {base} {d.code} not source-mapped")
    ot = os.path.join(REPO, "vaked", "examples", "oracle-team.vaked")
    d2 = vakedc.check_source(open(ot, encoding="utf-8").read(),
                             os.path.relpath(ot, REPO), builtins_cache=cache)
    if any(d.code == _EGRESS_USE for d in d2):
        ok = False; lines.append("  FAIL egress-use: oracle-team.vaked raised E-EGRESS-USE")
    if ok:
        lines.append("  egress-use (0026): E-EGRESS-USE fires on membrane over-reach / "
                     "bad principal; W-EGRESS-UNREFINED warns unrefined egress; "
                     "oracle-team cordons match grants (no error)")
    return ok
_NET_OK = '''runtime "t" {
  systems = ["x86_64-linux"]
  mesh m { node worker { role = "worker"  capabilities = [network.loopback] } }
  network agentEgress {
    principal = "worker"
    default   = "deny"
    allow = [ egress("127.0.0.1", 9) ]
  }
}
'''
_NET_BAD = '''runtime "t" {
  systems = ["x86_64-linux"]
  network agentEgress {
    principal = "worker"
    default   = "drop"
    principl  = "worker"
  }
}
'''
def _test_network_schema(lines):
    ok = True
    cache = _builtins_cache()
    diags = vakedc.check_source(_NET_OK, "net-ok.vaked", builtins_cache=cache)
    if diags:
        ok = False
        lines.append(f"  FAIL network: valid membrane should be clean, got "
                     f"{[d.code for d in diags]}")
    codes = sorted(d.code for d in
                   vakedc.check_source(_NET_BAD, "net-bad.vaked", builtins_cache=cache))
    want = ["E-CONFORM-UNKNOWN-FIELD", "E-CONSTRAINT-ONEOF"]
    if codes != want:
        ok = False
        lines.append(f"  FAIL network: invalid membrane should yield {want}, "
                     f"got {codes}")
    if ok:
        lines.append("  network schema (#28): valid membrane clean; typo field "
                     "+ bad `default` yield E-CONFORM-UNKNOWN-FIELD + "
                     "E-CONSTRAINT-ONEOF")
    return ok
def run():
    lines = []
    ok = True
    for fn in (_test_builtins, _test_coverage, _test_conformant, _test_rejected,
               _test_all_examples, _test_ref_resolution, _test_import_binding,
               _test_name_collision, _test_workflow, _test_namespace_checker,
               _test_network_schema, _test_ebpf_intent,
               _test_capability_reachability, _test_cap_use, _test_egress_use,
               _test_determinism, _test_determinism_boundary):
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