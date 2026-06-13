#!/usr/bin/env python3
"""test_doc_links.py — every relative markdown link resolves to an existing file.

Scope: docs/**/*.md, vaked/**/*.md, protocol/**/*.md, README.md, CLAUDE.md.
Rules:
  * anchor fragments (`...#section`) are stripped before resolution
  * external links (http://, https://, mailto:) are skipped
  * pure-anchor links (`#section`) are skipped (in-page)
  * a relative link must resolve, relative to the containing file's directory, to
    a path that exists on disk (file or directory)

Guards against a doc/spec move that orphans a cross-reference.
"""

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parse_support as ps  # noqa: E402

REPO = ps.REPO

SCOPE_GLOBS = [
    "docs/**/*.md",
    "vaked/**/*.md",
    "protocol/**/*.md",
]
SCOPE_FILES = ["README.md", "CLAUDE.md", "VAKED_AGENTS.md"]

# Inline-style markdown links: [text](target). We intentionally do not chase
# reference-style links or autolinks; the repo uses inline links throughout.
_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
_EXTERNAL = ("http://", "https://", "mailto:", "tel:")


def _md_files():
    files = []
    for pat in SCOPE_GLOBS:
        files.extend(glob.glob(os.path.join(REPO, pat), recursive=True))
    for f in SCOPE_FILES:
        p = os.path.join(REPO, f)
        if os.path.exists(p):
            files.append(p)
    return sorted(set(files))


def run():
    lines = []
    ok = True
    files = _md_files()
    total = 0
    external = 0
    broken = []
    for mf in files:
        base = os.path.dirname(mf)
        txt = open(mf, encoding="utf-8").read()
        for m in _LINK_RE.finditer(txt):
            target = m.group(1).strip()
            # link may carry a title: [t](path "title") — drop the title part
            if " " in target and not target.startswith("<"):
                target = target.split(" ", 1)[0]
            target = target.strip("<>")
            if target.startswith(_EXTERNAL):
                external += 1
                continue
            if target.startswith("#") or target == "":
                continue
            total += 1
            path = target.split("#", 1)[0]
            if path == "":
                continue
            resolved = os.path.normpath(os.path.join(base, path))
            if not os.path.exists(resolved):
                ok = False
                broken.append((os.path.relpath(mf, REPO), target))

    lines.append(f"scanned {len(files)} markdown files; "
                 f"{total} relative links checked, {external} external skipped")
    if broken:
        for mf, target in broken:
            lines.append(f"  FAIL  {mf} -> {target} (does not resolve)")
    else:
        lines.append("  PASS  all relative links resolve")
    return ok, lines


if __name__ == "__main__":
    ok, lines = run()
    print("== test_doc_links ==")
    for ln in lines:
        print(ln)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
