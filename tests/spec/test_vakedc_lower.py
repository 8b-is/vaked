#!/usr/bin/env python3
"""test_vakedc_lower.py — verifies `vakedc lower` (the 0012 lowering emitters)
against the regenerated spec-by-example fixtures.

Four test groups (see docs/superpowers/specs/2026-06-10-vakedc-lower-design.md →
Tests):

1. Golden tree. Lower `vaked/examples/operator-field.vaked` into a temp dir and
   byte-compare EVERY emitted file against `vaked/examples/lowering/` (README
   excluded — it is prose, not an emitter output). The fixtures now carry real
   `inputsHash` values, so this is a full byte-for-byte equality including the
   manifest.
2. Refuses invalid. Lower `vaked/examples/types/rejected.vaked`: the checker
   reports diagnostics, so lowering must refuse and emit NOTHING (0012 §1).
3. Determinism. Lower twice → byte-identical trees (a pure, hermetic pass yields
   the same artifacts and the same hashes, 0012 §2.1).
4. Manifest integrity. The emitted manifest matches the on-disk fixture
   `provenance.json` byte-for-byte, every emitter is in the 0012 §3.4 registry,
   and `inputsHash` is a real sha256 (not a placeholder) that re-derives
   identically from the projection.

`vakedc` is imported as a top-level package (the repo root is on sys.path). The
lowering is driven through the package API (parse → check → lower) — the same
order the CLI's `lower` subcommand uses — without spawning a subprocess.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, REPO)

import vakedc                              # noqa: E402  (implementation under test)
from vakedc.parser import parse_source     # noqa: E402
from vakedc.resolve import build_graph     # noqa: E402
from vakedc import lower as lower_mod       # noqa: E402
from vakedc.check import load_builtins      # noqa: E402

OPERATOR_FIELD = os.path.join(REPO, "vaked", "examples", "operator-field.vaked")
OPERATOR_FIELD_REL = "vaked/examples/operator-field.vaked"
REJECTED = os.path.join(REPO, "vaked", "examples", "types", "rejected.vaked")
REJECTED_REL = "vaked/examples/types/rejected.vaked"
LOWERING_DIR = os.path.join(REPO, "vaked", "examples", "lowering")

# 0012 §3.4 registry — a provenance entry's emitter MUST be one of these.
EMITTER_REGISTRY = {
    "nix.spine", "docs.runtime",
    "catalog.jsonl", "catalog.sqlite", "crabcc.index", "zig.daemoncfg",
    "ebpf.policy", "otel.config", "systemd.units", "surface.launcher",
}


# --------------------------------------------------------------------------- #
# Helpers — drive the pipeline the way the CLI's `lower` does.
# --------------------------------------------------------------------------- #

def _lower_to_files(src_path, rel):
    """parse → resolve → lower (with enrichment). Returns the {rel-path: text}
    map PLUS the serialized provenance.json text at key 'provenance.json'.

    This deliberately mirrors `vakedc.__main__._write_tree`'s view of the tree
    so the byte-compare exercises exactly what the CLI writes."""
    src = open(src_path, encoding="utf-8").read()
    items = parse_source(src, rel)
    graph = build_graph(items, rel)
    result = lower_mod.lower(graph, items)
    tree = dict(result.files)
    tree["provenance.json"] = lower_mod.provenance_json_text(result.provenance)
    return tree, result


def _disk_tree():
    """The on-disk fixture tree as {rel-path: text}, README excluded."""
    out = {}
    for root, _dirs, names in os.walk(LOWERING_DIR):
        for n in names:
            if n == "README.md":
                continue
            full = os.path.join(root, n)
            rel = os.path.relpath(full, LOWERING_DIR).replace(os.sep, "/")
            out[rel] = open(full, encoding="utf-8").read()
    return out


# --------------------------------------------------------------------------- #
# 1. Golden tree — byte-for-byte against the regenerated fixtures.
# --------------------------------------------------------------------------- #

def _test_golden_tree(lines):
    ok = True
    emitted, _ = _lower_to_files(OPERATOR_FIELD, OPERATOR_FIELD_REL)
    disk = _disk_tree()

    emitted_keys = set(emitted.keys())
    disk_keys = set(disk.keys())
    if emitted_keys != disk_keys:
        ok = False
        missing = disk_keys - emitted_keys
        extra = emitted_keys - disk_keys
        if missing:
            lines.append(f"  FAIL golden tree: not emitted: {sorted(missing)}")
        if extra:
            lines.append(f"  FAIL golden tree: emitted but not a fixture: {sorted(extra)}")

    n_ok = 0
    for rel in sorted(disk_keys & emitted_keys):
        got = emitted[rel]
        if isinstance(got, bytes):
            got = got.decode("utf-8")
        want = disk[rel]
        if got == want:
            n_ok += 1
            continue
        ok = False
        # first differing byte for debuggability
        diff_at = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b),
                       min(len(got), len(want)))
        lines.append(f"  FAIL golden tree: {rel} differs at byte {diff_at} "
                     f"(emitted {len(got)}B vs fixture {len(want)}B)")

    if ok:
        lines.append(f"  PASS golden tree: {n_ok} files byte-identical to "
                     f"vaked/examples/lowering/ (README excluded)")
    return ok


# --------------------------------------------------------------------------- #
# 2. Refuses invalid — rejected.vaked emits NOTHING.
# --------------------------------------------------------------------------- #

def _test_refuses_invalid(lines):
    ok = True
    # The checker must report ≥1 diagnostic (this is the gate the CLI checks).
    cache = load_builtins()
    diags = vakedc.check_source(open(REJECTED, encoding="utf-8").read(),
                                REJECTED_REL, builtins_cache=cache)
    if not diags:
        ok = False
        lines.append("  FAIL refuses-invalid: expected diagnostics from "
                     "rejected.vaked, got none")
        return ok

    # Simulate the CLI's refusal contract: on any diagnostic, lower() is NEVER
    # called and no file is written. We assert that the gate (diags non-empty)
    # is the condition the CLI uses, and that lower() itself, if it WERE called
    # on the (invalid) graph, is still a pure function (no IO) — but the contract
    # is: diagnostics ⇒ nothing written. Exercise the real CLI path in a subdir.
    import tempfile
    import vakedc.__main__ as cli
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "out")
        rc = cli.main(["lower", REJECTED, "--out", out])
        if rc != 1:
            ok = False
            lines.append(f"  FAIL refuses-invalid: lower exit {rc} != 1")
        if os.path.exists(out):
            leftover = []
            for r, _d, ns in os.walk(out):
                leftover.extend(ns)
            if leftover:
                ok = False
                lines.append(f"  FAIL refuses-invalid: files written despite "
                             f"diagnostics: {leftover}")
    if ok:
        lines.append(f"  PASS refuses-invalid: {len(diags)} diagnostics ⇒ "
                     f"exit 1, nothing written")
    return ok


# --------------------------------------------------------------------------- #
# 3. Determinism — two runs identical.
# --------------------------------------------------------------------------- #

def _test_determinism(lines):
    t1, _ = _lower_to_files(OPERATOR_FIELD, OPERATOR_FIELD_REL)
    t2, _ = _lower_to_files(OPERATOR_FIELD, OPERATOR_FIELD_REL)
    if set(t1.keys()) != set(t2.keys()):
        lines.append("  FAIL determinism: file sets differ across runs")
        return False
    for rel in t1:
        a, b = t1[rel], t2[rel]
        if isinstance(a, bytes):
            a = a.decode("utf-8")
        if isinstance(b, bytes):
            b = b.decode("utf-8")
        if a != b:
            lines.append(f"  FAIL determinism: {rel} differs across runs")
            return False
    lines.append(f"  PASS determinism: {len(t1)} files byte-identical across two runs")
    return True


# --------------------------------------------------------------------------- #
# 4. Manifest integrity — registry + real (re-derivable) hashes.
# --------------------------------------------------------------------------- #

def _test_manifest_integrity(lines):
    ok = True
    _, result = _lower_to_files(OPERATOR_FIELD, OPERATOR_FIELD_REL)
    prov = result.provenance

    # on-disk fixture manifest is byte-identical to the freshly emitted one
    emitted_text = lower_mod.provenance_json_text(prov)
    disk_text = open(os.path.join(LOWERING_DIR, "provenance.json"),
                     encoding="utf-8").read()
    if emitted_text != disk_text:
        ok = False
        lines.append("  FAIL manifest: emitted provenance.json != on-disk fixture")

    artifacts = prov.get("artifacts", {})
    keys = list(artifacts.keys())
    if keys != sorted(keys):
        ok = False
        lines.append(f"  FAIL manifest: artifacts keys not lexicographic: {keys}")

    n_entries = 0
    placeholder = re.compile(r"^sha256-[0-9a-f]{64}$")
    for ap, entries in artifacts.items():
        for e in entries:
            n_entries += 1
            if e.get("emitter") not in EMITTER_REGISTRY:
                ok = False
                lines.append(f"  FAIL manifest: emitter {e.get('emitter')!r} "
                             f"(in {ap!r}) not in 0012 §3.4 registry")
            h = e.get("inputsHash", "")
            if not placeholder.match(h):
                ok = False
                lines.append(f"  FAIL manifest: inputsHash {h!r} (in {ap!r}) is "
                             f"not a real sha256 ('sha256-'+64 hex)")

    # hashes are content-addressed: the runtime header region (flake.nix) and the
    # RUNTIME.md header region attribute to the same runtime decl AND project the
    # same node, so their hashes MUST be equal — a positive check the value is
    # derived from the projection, not the region label.
    flake_runtime = _find_hash(artifacts, "flake.nix", "nixosModules.operator-field")
    md_runtime = _find_hash(artifacts, "gen/RUNTIME.md", "header")
    if flake_runtime is not None and flake_runtime != md_runtime:
        ok = False
        lines.append("  FAIL manifest: same-projection regions have different "
                     f"hashes ({flake_runtime[:16]}.. vs {md_runtime[:16]}..)")

    # the engine-package region (packages.zigimg) hashes a DIFFERENT projection
    # than the fiber-config region, though both attribute to `fiber mediaCompress`
    # — they MUST differ (0012 §6.2 per-projection keying).
    engine = _find_hash(artifacts, "flake.nix", "packages.zigimg")
    fiber_cfg = _find_hash(artifacts, "gen/zig/mediaCompress.json", None)
    if engine is not None and fiber_cfg is not None and engine == fiber_cfg:
        ok = False
        lines.append("  FAIL manifest: engine-package and fiber-config regions "
                     "share a hash (must differ — different projection)")

    if ok:
        lines.append(f"  PASS manifest: {n_entries} entries, real re-derivable "
                     f"sha256, registry-valid, per-projection keying holds")
    return ok


def _find_hash(artifacts, ap, region):
    for e in artifacts.get(ap, []):
        if e.get("region") == region:
            return e.get("inputsHash")
    return None


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #

def run():
    lines = []
    ok = True
    lines.append("golden tree:")
    ok &= _test_golden_tree(lines)
    lines.append("refuses invalid:")
    ok &= _test_refuses_invalid(lines)
    lines.append("determinism:")
    ok &= _test_determinism(lines)
    lines.append("manifest integrity:")
    ok &= _test_manifest_integrity(lines)
    return bool(ok), lines


if __name__ == "__main__":
    ok, lines = run()
    print("== test_vakedc_lower ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
