#!/usr/bin/env python3
"""vakedc CLI — ``parse``, ``check`` and ``lower`` subcommands.

  python3 -m vakedc parse <file> [--json P] [--sqlite P] [--print]
  python3 -m vakedc check <file> [--json] [--builtins PATH]
  python3 -m vakedc lower <file> [--out DIR] [--builtins PATH]

``parse`` parses a .vaked file into the LPG and emits canonical JSON + SQLite
(defaults under ``.vaked/``; ``--print`` writes canonical JSON to stdout).

``check`` runs the 0011 type-system checker (stages 3-4) over a .vaked file
against the built-in catalog and prints diagnostics: human-readable to stderr by
default, or canonical JSON to stdout with ``--json``.  ``--builtins PATH``
overrides the catalog (default: the repo's ``vaked/schema/builtins.vaked``,
resolved relative to the package, so it works from any CWD).  Exit codes:
``0`` clean, ``1`` diagnostics present, ``2`` usage / read / parse error.

``lower`` runs the full 0012 pipeline parse → resolve → check → **lower**: it
refuses to emit anything if the checker reports a single diagnostic (0012 §1),
otherwise it writes the artifact tree (``flake.nix``, ``gen/…``, and the
``provenance.json`` manifest at the out root) under ``--out DIR`` (default
``.vaked/lower/``).  Exit codes: ``0`` emitted, ``1`` diagnostics / read / parse
error (nothing written), ``2`` usage error.

Both commands exit ``1`` on an NFC/lex/parse error with the source-mapped message
on stderr; the Unicode-version-mismatch warning also goes to stderr so stdout
stays clean.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from .lexer import VakedLexError
from .parser import VakedSyntaxError
from .resolve import build_graph
from .parser import parse_source
from .emit import to_canonical_json, to_sqlite
from .check import check_source, load_builtins, default_builtins_path
from . import lower as lower_mod


def _cmd_lsp(args) -> int:
    """Run as a JSON-RPC 2.0 LSP server over stdio (LSP 3.17)."""
    from .lsp import LspServer
    server = LspServer(builtins_path=args.builtins)
    return server.run()


def _cmd_parse(args) -> int:
    try:
        with open(args.file, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"vakedc: cannot read {args.file}: {e}", file=sys.stderr)
        return 1

    try:
        items = parse_source(src, args.file)
    except (VakedLexError, VakedSyntaxError) as e:
        print(f"vakedc: {e}", file=sys.stderr)
        return 1

    graph = build_graph(items, args.file)
    canonical = to_canonical_json(graph)

    # Determine output targets. If neither --json/--sqlite/--print is given, use
    # the defaults under .vaked/. --print does not suppress the default writes
    # unless the user explicitly set output paths.
    explicit = args.json is not None or args.sqlite is not None
    json_path = args.json
    sqlite_path = args.sqlite
    if not explicit:
        out_dir = os.path.join(os.getcwd(), ".vaked")
        os.makedirs(out_dir, exist_ok=True)
        json_path = os.path.join(out_dir, "graph.json")
        sqlite_path = os.path.join(out_dir, "graph.db")

    if json_path is not None:
        with open(json_path, "w", encoding="utf-8") as fh:
            fh.write(canonical)
    if sqlite_path is not None:
        if os.path.exists(sqlite_path):
            os.remove(sqlite_path)
        to_sqlite(graph, sqlite_path)

    if args.print_:
        sys.stdout.write(canonical)
    elif not explicit:
        print(f"vakedc: wrote {json_path} and {sqlite_path}", file=sys.stderr)

    return 0


def _diagnostics_json(diags) -> str:
    """Canonical JSON for a diagnostics list: stable key order, sorted records
    (the checker already sorts by (file, byteStart, byteEnd, code)), 2-space
    indent, trailing newline."""
    doc = {"diagnostics": [d.as_dict() for d in diags]}
    return json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def _format_diag(d) -> str:
    return (f"{d.file}:{d.line}:{d.col}: {d.severity}: {d.code}: {d.message} "
            f"[{d.decl}]")


def _cmd_check(args) -> int:
    try:
        with open(args.file, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"vakedc: cannot read {args.file}: {e}", file=sys.stderr)
        return 2

    builtins_path = args.builtins or default_builtins_path()
    try:
        builtins_cache = load_builtins(builtins_path)
    except OSError as e:
        print(f"vakedc: cannot read builtins {builtins_path}: {e}", file=sys.stderr)
        return 2
    except (VakedLexError, VakedSyntaxError) as e:
        print(f"vakedc: builtins catalog failed to parse: {e}", file=sys.stderr)
        return 2

    try:
        diags = check_source(src, args.file, builtins_cache=builtins_cache)
    except (VakedLexError, VakedSyntaxError) as e:
        print(f"vakedc: {e}", file=sys.stderr)
        return 2

    if args.json:
        # canonical JSON to stdout (parseable; warnings go to stderr).
        sys.stdout.write(_diagnostics_json(diags))
    else:
        for d in diags:
            print(_format_diag(d), file=sys.stderr)
        if diags:
            n = len(diags)
            print(f"vakedc: {n} diagnostic{'s' if n != 1 else ''} in {args.file}",
                  file=sys.stderr)
        else:
            print(f"vakedc: {args.file} — no diagnostics", file=sys.stderr)

    return 1 if diags else 0


def _cmd_lower(args) -> int:
    """parse → resolve → check → lower (0012 §1). Refuse to emit on any
    diagnostic; otherwise write the artifact tree under ``--out``."""
    try:
        with open(args.file, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as e:
        print(f"vakedc: cannot read {args.file}: {e}", file=sys.stderr)
        return 1

    # 1) parse
    try:
        items = parse_source(src, args.file)
    except (VakedLexError, VakedSyntaxError) as e:
        print(f"vakedc: {e}", file=sys.stderr)
        return 1

    # 2) check FIRST — lowering only runs on a clean, validated graph (0012 §1).
    #    Any diagnostic ⇒ print, emit NOTHING, exit 1.
    builtins_path = args.builtins or default_builtins_path()
    try:
        builtins_cache = load_builtins(builtins_path)
    except OSError as e:
        print(f"vakedc: cannot read builtins {builtins_path}: {e}", file=sys.stderr)
        return 2
    except (VakedLexError, VakedSyntaxError) as e:
        print(f"vakedc: builtins catalog failed to parse: {e}", file=sys.stderr)
        return 2

    try:
        diags = check_source(src, args.file, builtins_cache=builtins_cache)
    except (VakedLexError, VakedSyntaxError) as e:
        print(f"vakedc: {e}", file=sys.stderr)
        return 1

    if diags:
        for d in diags:
            print(_format_diag(d), file=sys.stderr)
        n = len(diags)
        print(f"vakedc: {n} diagnostic{'s' if n != 1 else ''} in {args.file}; "
              f"refusing to lower (nothing written)", file=sys.stderr)
        return 1

    # 3) resolve + lower. enrich_graph (config sub-blocks) runs inside lower()
    #    when the parsed items are supplied.
    graph = build_graph(items, args.file)
    result = lower_mod.lower(graph, items)

    # 4) write the tree. The manifest lands at <out>/provenance.json; the rest of
    #    the files are relative paths under <out> (0012 §6.2 erratum).
    out_dir = args.out or os.path.join(os.getcwd(), ".vaked", "lower")
    written = _write_tree(out_dir, result)
    print(f"vakedc: lowered {args.file} → {out_dir} ({written} files)",
          file=sys.stderr)
    return 0


def _write_tree(out_dir: str, result) -> int:
    """Write a LowerResult to ``out_dir``: every emitted file at its relative
    path, plus ``provenance.json`` at the root. Returns the file count. This is
    the only IO in the lowering pipeline (the emitters are pure)."""
    written = 0
    for rel, content in sorted(result.files.items()):
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        data = content.encode("utf-8") if isinstance(content, str) else content
        with open(dest, "wb") as fh:
            fh.write(data)
        written += 1
    # provenance manifest at the out root (0012 §6.2 erratum).
    os.makedirs(out_dir, exist_ok=True)
    prov_text = lower_mod.provenance_json_text(result.provenance)
    with open(os.path.join(out_dir, "provenance.json"), "wb") as fh:
        fh.write(prov_text.encode("utf-8"))
    written += 1
    return written


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="vakedc",
        description="Vaked front-end: parse .vaked -> Labeled Property Graph; "
                    "check .vaked against the 0011 type system.",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("parse", help="parse a .vaked file into the LPG")
    pp.add_argument("file", help="path to a .vaked source file")
    pp.add_argument("--json", metavar="PATH", default=None,
                    help="write canonical JSON to PATH")
    pp.add_argument("--sqlite", metavar="PATH", default=None,
                    help="write the SQLite graph DB to PATH")
    pp.add_argument("--print", dest="print_", action="store_true",
                    help="write canonical JSON to stdout")

    cp = sub.add_parser("check", help="type-check a .vaked file (0011 stages 3-4)")
    cp.add_argument("file", help="path to a .vaked source file")
    cp.add_argument("--json", action="store_true",
                    help="emit diagnostics as canonical JSON to stdout")
    cp.add_argument("--builtins", metavar="PATH", default=None,
                    help="path to the built-in catalog (default: the repo's "
                         "vaked/schema/builtins.vaked)")

    lp = sub.add_parser("lower",
                        help="lower a checked .vaked file to artifacts (0012)")
    lp.add_argument("file", help="path to a .vaked source file")
    lp.add_argument("--out", metavar="DIR", default=None,
                    help="output directory for the artifact tree "
                         "(default: .vaked/lower/)")
    lp.add_argument("--builtins", metavar="PATH", default=None,
                    help="path to the built-in catalog (default: the repo's "
                         "vaked/schema/builtins.vaked)")

    sp = sub.add_parser("lsp",
                        help="run as an LSP 3.17 server over stdio (for vaked-ide)")
    sp.add_argument("--builtins", metavar="PATH", default=None,
                    help="path to the built-in catalog (default: the repo's "
                         "vaked/schema/builtins.vaked)")

    args = ap.parse_args(argv)

    if args.cmd == "parse":
        return _cmd_parse(args)
    if args.cmd == "check":
        return _cmd_check(args)
    if args.cmd == "lower":
        return _cmd_lower(args)
    if args.cmd == "lsp":
        return _cmd_lsp(args)
    ap.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
