#!/usr/bin/env python3
"""test_lowering_fixtures.py — the lowering spec-by-example fixtures are internally
consistent and consistent with docs/language/0012-lowering.md.

These fixtures are hand-authored expected output (no compiler exists yet). This
test makes permanent the by-hand review: it recomputes everything checkable from
first principles rather than trusting the fixture.

(a) provenance.json
    - valid JSON; schema shape (version/source/artifacts; each entry has
      sourceFile/decl/span/emitter/inputsHash; region optional)
    - artifacts map keys in lexicographic (Unicode-code-point) order by path
    - every artifact path exists on disk (output root = the lowering dir)
    - every emitter is in the 0012 §3.4 registry set
    - every span recomputed against vaked/examples/operator-field.vaked:
        byteStart lands on the decl's leading keyword and the decl name matches;
        byteEnd is EXCLUSIVE, one past the matching closing '}';
        line/col are 1-based and locate byteStart.
(b) gen/zig/mediaCompress.json
    - valid JSON; `_generated` is the FIRST key; top-level key order is exactly the
      0012 §5.2 canonical order; no null-valued optionals anywhere.
(c) gen/catalog/zigCorpus.jsonl
    - line 1 is the `_generated` header object; every line is valid JSON.
(d) gen/RUNTIME.md + flake.nix
    - each contains its generated-by-Vaked header (in the format's comment syntax)
    - flake.nix has balanced ()/[]/{} and a 40-hex pinned nixpkgs rev (no moving
      branch ref).
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parse_support as ps  # noqa: E402

REPO = ps.REPO
LOWER = os.path.join(REPO, "vaked", "examples", "lowering")
SOURCE_VAKED = os.path.join(REPO, "vaked", "examples", "operator-field.vaked")

# 0012 §3.4 registry: the full set of emitter targets (ALWAYS + emit-SELECTED +
# DEFERRED). A provenance entry's `emitter` MUST be one of these. Hardcoded here
# with this comment pointing at the source of truth (docs/language/0012-lowering.md
# §3.4 "The registry").
EMITTER_REGISTRY = {
    # ALWAYS (structural)
    "nix.spine", "docs.runtime",
    # emit-SELECTED (direct gen/ artifacts)
    "catalog.jsonl", "catalog.sqlite", "crabcc.index", "zig.daemoncfg",
    # Runtime plane (#18/#24/#27) + Track C (#19)
    "eventd.config", "memory.store", "workflow.spec", "otp.supervision",
    "colmena.hive",
    # DEFERRED (interface slots, §7)
    "ebpf.policy", "otel.config", "systemd.units", "surface.launcher",
}

# 0012 §5.2 canonical top-level key order for a Zig daemon config.
ZIG_CFG_KEY_ORDER = [
    "_generated", "engine", "engine_package", "input", "output", "policy",
    "observe",
]


def _find_nulls(obj, path=""):
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if v is None:
                out.append(f"{path}/{k}")
            out.extend(_find_nulls(v, f"{path}/{k}"))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out.extend(_find_nulls(v, f"{path}[{i}]"))
    return out


def _line_col(data: bytes, byte_off: int):
    pre = data[:byte_off]
    line = pre.count(b"\n") + 1
    col = byte_off - (pre.rfind(b"\n") + 1) + 1
    return line, col


def _check_provenance(lines):
    ok = True
    path = os.path.join(LOWER, "provenance.json")
    try:
        prov = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        lines.append(f"  FAIL provenance.json: invalid JSON: {e}")
        return False

    # top-level shape
    for k in ("version", "source", "artifacts"):
        if k not in prov:
            ok = False
            lines.append(f"  FAIL provenance.json: missing top-level key {k!r}")
    if prov.get("version") != 1:
        ok = False
        lines.append(f"  FAIL provenance.json: version != 1 ({prov.get('version')!r})")

    artifacts = prov.get("artifacts", {})
    keys = list(artifacts.keys())
    if keys != sorted(keys):
        ok = False
        lines.append(f"  FAIL provenance.json: artifacts keys not lexicographic: {keys}")
    else:
        lines.append(f"  PASS provenance.json: artifacts keys lexicographic ({len(keys)})")

    # artifact paths exist (output root = lowering dir)
    for ap in keys:
        if not os.path.exists(os.path.join(LOWER, ap)):
            ok = False
            lines.append(f"  FAIL provenance.json: artifact path missing on disk: {ap}")

    # entries: schema + emitter registry + span recomputation
    data = open(SOURCE_VAKED, "rb").read()
    n_entries = 0
    n_spans_ok = 0
    for ap, entries in artifacts.items():
        if not isinstance(entries, list):
            ok = False
            lines.append(f"  FAIL provenance.json: artifacts[{ap!r}] is not a list")
            continue
        for e in entries:
            n_entries += 1
            for rf in ("sourceFile", "decl", "span", "emitter", "inputsHash"):
                if rf not in e:
                    ok = False
                    lines.append(f"  FAIL provenance.json: entry in {ap!r} missing {rf!r}")
            if e.get("emitter") not in EMITTER_REGISTRY:
                ok = False
                lines.append(f"  FAIL provenance.json: emitter {e.get('emitter')!r} "
                             f"(in {ap!r}) not in 0012 §3.4 registry")
            # span recomputation
            span = e.get("span", {})
            decl = e.get("decl", "")
            sok = _verify_span(data, decl, span, ap, lines)
            if sok:
                n_spans_ok += 1
            else:
                ok = False
    lines.append(f"  {'PASS' if ok else 'FAIL'} provenance.json: "
                 f"{n_entries} entries, {n_spans_ok} spans recomputed-OK, "
                 f"emitters ⊆ registry")
    return ok


def _verify_span(data: bytes, decl: str, span: dict, ap: str, lines):
    """Recompute the span from the source bytes; don't trust the fixture."""
    parts = decl.split(None, 1)
    if len(parts) != 2:
        lines.append(f"  FAIL span ({ap}/{decl!r}): decl is not '<kind> <name>'")
        return False
    kind, name = parts
    bs = span.get("byteStart")
    be = span.get("byteEnd")
    if not isinstance(bs, int) or not isinstance(be, int):
        lines.append(f"  FAIL span ({ap}/{decl!r}): byteStart/byteEnd not ints")
        return False
    # byteStart must land exactly on the leading keyword
    if data[bs:bs + len(kind)].decode("utf-8", "replace") != kind:
        lines.append(f"  FAIL span ({ap}/{decl!r}): byteStart {bs} not on keyword {kind!r} "
                     f"(found {data[bs:bs+len(kind)]!r})")
        return False
    # the decl name must appear right after the keyword (ws-separated; name may be
    # a quoted string e.g. runtime "operator-field")
    head = data[bs:be].decode("utf-8", "replace")
    m = re.match(r"^" + re.escape(kind) + r"\s+(\"[^\"]*\"|[A-Za-z_][A-Za-z0-9_\-]*)",
                 head)
    if not m:
        lines.append(f"  FAIL span ({ap}/{decl!r}): no name token after keyword")
        return False
    got_name = m.group(1).strip('"')
    if got_name != name:
        lines.append(f"  FAIL span ({ap}/{decl!r}): name mismatch "
                     f"(span names {got_name!r}, decl says {name!r})")
        return False
    # byteEnd is EXCLUSIVE: byte at be-1 is the closing '}', and the [bs,be) region
    # must have balanced braces ending exactly there.
    if be < 1 or be > len(data) or data[be - 1:be] != b"}":
        lines.append(f"  FAIL span ({ap}/{decl!r}): byteEnd {be} not one past a '}}'")
        return False
    if not _braces_balanced_region(data, bs, be):
        lines.append(f"  FAIL span ({ap}/{decl!r}): [byteStart,byteEnd) braces unbalanced")
        return False
    # line/col 1-based, locate byteStart
    line, col = _line_col(data, bs)
    if span.get("line") != line or span.get("col") != col:
        lines.append(f"  FAIL span ({ap}/{decl!r}): line/col {span.get('line')},"
                     f"{span.get('col')} != recomputed {line},{col}")
        return False
    return True


def _braces_balanced_region(data: bytes, bs: int, be: int) -> bool:
    """Verify the region opens its first '{' and closes at be-1 with balance 0,
    ignoring braces inside strings (the .vaked decls have no '{' in strings, but be
    safe)."""
    depth = 0
    seen_open = False
    in_str = False
    esc = False
    i = bs
    while i < be:
        c = data[i:i + 1]
        if in_str:
            if esc:
                esc = False
            elif c == b"\\":
                esc = True
            elif c == b'"':
                in_str = False
        else:
            if c == b'"':
                in_str = True
            elif c == b"{":
                depth += 1
                seen_open = True
            elif c == b"}":
                depth -= 1
                if depth == 0 and i == be - 1:
                    return seen_open
                if depth < 0:
                    return False
        i += 1
    return seen_open and depth == 0


def _check_zig_config(lines):
    ok = True
    path = os.path.join(LOWER, "gen", "zig", "mediaCompress.json")
    try:
        # Preserve key order: json.load on a dict already preserves insertion order
        # in CPython 3.7+, which reflects file order.
        cfg = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        lines.append(f"  FAIL mediaCompress.json: invalid JSON: {e}")
        return False
    keys = list(cfg.keys())
    if not keys or keys[0] != "_generated":
        ok = False
        lines.append(f"  FAIL mediaCompress.json: first key is {keys[:1]} not '_generated'")
    if keys != ZIG_CFG_KEY_ORDER:
        ok = False
        lines.append(f"  FAIL mediaCompress.json: top-level key order {keys} != "
                     f"canonical {ZIG_CFG_KEY_ORDER}")
    nulls = _find_nulls(cfg)
    if nulls:
        ok = False
        lines.append(f"  FAIL mediaCompress.json: null-valued optional(s): {nulls}")
    if ok:
        lines.append("  PASS mediaCompress.json: _generated first, canonical key "
                     "order, no nulls")
    return ok


def _check_jsonl(lines):
    ok = True
    path = os.path.join(LOWER, "gen", "catalog", "zigCorpus.jsonl")
    raw = open(path, encoding="utf-8").read().splitlines()
    raw = [ln for ln in raw if ln.strip() != ""]
    if not raw:
        lines.append("  FAIL zigCorpus.jsonl: empty file")
        return False
    for i, ln in enumerate(raw, 1):
        try:
            obj = json.loads(ln)
        except Exception as e:
            ok = False
            lines.append(f"  FAIL zigCorpus.jsonl: line {i} invalid JSON: {e}")
            continue
        if i == 1:
            if list(obj.keys())[:1] != ["_generated"]:
                ok = False
                lines.append("  FAIL zigCorpus.jsonl: line 1 is not a "
                             "{'_generated': ...} header object")
    if ok:
        lines.append(f"  PASS zigCorpus.jsonl: {len(raw)} lines valid JSON, "
                     "line 1 is _generated header")
    return ok


def _check_headers_and_flake(lines):
    ok = True
    # RUNTIME.md header (markdown comment)
    rmd = open(os.path.join(LOWER, "gen", "RUNTIME.md"), encoding="utf-8").read()
    if "generated by Vaked from operator-field.vaked:runtime operator-field" not in rmd \
            or not rmd.lstrip().startswith("<!--"):
        ok = False
        lines.append("  FAIL RUNTIME.md: missing/incorrect generated-by-Vaked header")
    else:
        lines.append("  PASS RUNTIME.md: generated-by-Vaked header present")

    # flake.nix header (nix comment), balance, pinned rev
    flk = open(os.path.join(LOWER, "flake.nix"), encoding="utf-8").read()
    if "generated by Vaked from operator-field.vaked:runtime operator-field" not in flk \
            or not flk.lstrip().startswith("#"):
        ok = False
        lines.append("  FAIL flake.nix: missing/incorrect generated-by-Vaked header")
    else:
        lines.append("  PASS flake.nix: generated-by-Vaked header present")

    for o, c in [("(", ")"), ("[", "]"), ("{", "}")]:
        if flk.count(o) != flk.count(c):
            ok = False
            lines.append(f"  FAIL flake.nix: unbalanced {o}{c} "
                         f"({flk.count(o)} vs {flk.count(c)})")
    if all(flk.count(o) == flk.count(c) for o, c in [("(", ")"), ("[", "]"), ("{", "}")]):
        lines.append("  PASS flake.nix: ()/[]/{} balanced")

    # nixpkgs pinned to a 40-hex rev embedded in the github: URL, no moving branch.
    pin = re.search(r'nixpkgs\.url\s*=\s*"github:[^/]+/nixpkgs/([0-9a-f]{40})"', flk)
    moving = re.search(
        r'nixpkgs\.url\s*=\s*"github:[^"]*?/'
        r'(nixos-unstable|nixpkgs-unstable|master|main|release-[\d.]+)"', flk)
    if not pin:
        ok = False
        lines.append("  FAIL flake.nix: nixpkgs is not pinned to a 40-hex rev")
    elif moving:
        ok = False
        lines.append(f"  FAIL flake.nix: nixpkgs uses a moving branch ref "
                     f"{moving.group(1)!r}")
    else:
        lines.append(f"  PASS flake.nix: nixpkgs pinned to 40-hex rev "
                     f"({pin.group(1)[:8]}...), no moving ref")
    return ok


def run():
    lines = []
    ok = True
    lines.append("provenance.json:")
    ok &= _check_provenance(lines)
    lines.append("gen/zig/mediaCompress.json:")
    ok &= _check_zig_config(lines)
    lines.append("gen/catalog/zigCorpus.jsonl:")
    ok &= _check_jsonl(lines)
    lines.append("gen/RUNTIME.md + flake.nix:")
    ok &= _check_headers_and_flake(lines)
    return bool(ok), lines


if __name__ == "__main__":
    ok, lines = run()
    print("== test_lowering_fixtures ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
