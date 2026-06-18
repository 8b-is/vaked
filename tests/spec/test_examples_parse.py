#!/usr/bin/env python3
"""test_examples_parse.py — every example derives from its grammar.

(a) All 17 `.vaked` example files parse against vaked/grammar/vaked-v0-plus.ebnf.
(b) protocol/hcplang/examples/hcp-core.hcplang parses against the hcplang grammar.
(c) v0.2-compat regression probes (inline snippets) verify the v0.3 soft-keyword
    disambiguation did not change how any previously-legal v0.2 program parses:
      * `open = true`  parses as an ASSIGNMENT (open_decl is ordered AFTER assignment)
      * `order = 3`, `grant = "x"`, `field = 1`, `engine = 1` likewise parse as
        assignments (each soft-keyword decl self-disambiguates on its required
        second token, which `=` is not)
      * a bare `open` (inside a schema block) parses as an open_decl.

Each item reports PASS/FAIL with a source location on failure.
"""

import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parse_support as ps  # noqa: E402

REPO = ps.REPO

# The 22 expected example files (explicit count, per spec).
# v0.4 adds vaked/examples/namespace/ (2 files: valid + error-unknown-namespace).
# #226 adds vaked/examples/types/pola-{violation,least-authority}.vaked (2 files).
VAKED_EXAMPLE_GLOBS = [
    "vaked/examples/primitives/*.vaked",   # 10 (memory.vaked: #24)
    "vaked/examples/types/*.vaked",        # 14 (#226: +pola pair; Risk 6: +8 cap-use-*)
    "vaked/examples/membrane/*.vaked",     # 1 (network-membrane slice: agent-egress)
    "vaked/examples/operator-field.vaked",  # 1
    "vaked/examples/engines/zig.vaked",     # 1
    "vaked/examples/agentfield-swe.vaked",  # 1 (#27 dogfood: swe_af workflow)
    "vaked/examples/namespace/*.vaked",     # 2 (RFC 0017: valid + error-unknown-namespace)
    "vaked/examples/ebpf/*.vaked",          # 1 (#225: observe/enforce hook typing)
]
EXPECTED_VAKED_COUNT = 36

HCP_EXAMPLE = "protocol/hcplang/examples/hcp-core.hcplang"


def _vaked_files():
    files = []
    for pat in VAKED_EXAMPLE_GLOBS:
        files.extend(glob.glob(os.path.join(REPO, pat)))
    return sorted(set(files))


# (rel-path-or-label, src, parser, expect_pass)
def _regression_probes():
    """v0.2-compat probes as inline snippets (wrapped in a minimal schema block so
    they sit in statement position, which is where the disambiguation happens)."""
    probes = []

    def schema_stmt(stmt):
        return f'schema s {{\n  {stmt}\n}}\n'

    for stmt in ['open = true', 'order = 3', 'grant = "x"',
                 'field = 1', 'engine = 1', 'member = 1']:
        probes.append((f'probe: `{stmt}` parses as assignment',
                       schema_stmt(stmt), ps.parse_vaked, True))
    probes.append(('probe: bare `open` parses as open_decl',
                   'schema s {\n  open\n}\n', ps.parse_vaked, True))
    # v0.4 (RFC 0017): bare `member ident` inside a namespace block parses as member_decl.
    probes.append(('probe: `member ringbuf` inside namespace parses as member_decl',
                   'namespace agentGuardd {\n  member ringbuf\n}\n', ps.parse_vaked, True))
    return probes


def run():
    lines = []
    ok = True

    # (a) .vaked example files
    vaked_files = _vaked_files()
    lines.append(f"vaked examples: found {len(vaked_files)} "
                 f"(expected {EXPECTED_VAKED_COUNT})")
    if len(vaked_files) != EXPECTED_VAKED_COUNT:
        ok = False
        lines.append(f"  FAIL: expected {EXPECTED_VAKED_COUNT} .vaked files, "
                     f"found {len(vaked_files)}")
    for f in vaked_files:
        rel = os.path.relpath(f, REPO)
        out = ps.parse_vaked(open(f, encoding="utf-8").read(), rel)
        if out.ok:
            lines.append(f"  PASS  {rel}")
        else:
            ok = False
            lines.append(f"  FAIL  {rel}: {out.location()}")

    # (b) hcp-core.hcplang
    hcp = os.path.join(REPO, HCP_EXAMPLE)
    out = ps.parse_hcplang(open(hcp, encoding="utf-8").read(), HCP_EXAMPLE)
    if out.ok:
        lines.append(f"  PASS  {HCP_EXAMPLE}")
    else:
        ok = False
        lines.append(f"  FAIL  {HCP_EXAMPLE}: {out.location()}")

    # (c) v0.2-compat regression probes
    lines.append("v0.2-compat regression probes:")
    for label, src, parser, expect_pass in _regression_probes():
        out = parser(src)
        got_pass = out.ok
        if got_pass == expect_pass:
            lines.append(f"  PASS  {label}")
        else:
            ok = False
            detail = out.location() if not got_pass else "parsed but should NOT"
            lines.append(f"  FAIL  {label}: {detail}")

    return ok, lines


if __name__ == "__main__":
    ok, lines = run()
    print("== test_examples_parse ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
