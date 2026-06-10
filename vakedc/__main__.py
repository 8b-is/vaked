#!/usr/bin/env python3
"""vakedc CLI — ``parse`` and ``check`` subcommands.

  python3 -m vakedc parse <file> [--json P] [--sqlite P] [--print]
  python3 -m vakedc check <file> [--json] [--builtins PATH]

``parse`` parses a .vaked file into the LPG and emits canonical JSON + SQLite
(defaults under ``.vaked/``; ``--print`` writes canonical JSON to stdout).

``check`` runs the 0011 type-system checker (stages 3-4) over a .vaked file
against the built-in catalog and prints diagnostics: human-readable to stderr by
default, or canonical JSON to stdout with ``--json``.  ``--builtins PATH``
overrides the catalog (default: the repo's ``vaked/schema/builtins.vaked``,
resolved relative to the package, so it works from any CWD).  Exit codes:
``0`` clean, ``1`` diagnostics present, ``2`` usage / read / parse error.

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

    args = ap.parse_args(argv)

    if args.cmd == "parse":
        return _cmd_parse(args)
    if args.cmd == "check":
        return _cmd_check(args)
    ap.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
