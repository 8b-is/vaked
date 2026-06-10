#!/usr/bin/env python3
"""vakedc CLI — ``python3 -m vakedc parse <file> [--json P] [--sqlite P] [--print]``.

Parses a .vaked file into the LPG and emits canonical JSON + SQLite. Defaults write
``.vaked/graph.json`` and ``.vaked/graph.db`` relative to the CWD. ``--print`` writes
canonical JSON to stdout. Exits 1 on NFC/lex/parse error with the source-mapped
message on stderr; the warning for a Unicode-version mismatch also goes to stderr,
so stdout stays clean (``--print`` output is parseable JSON).
"""

from __future__ import annotations

import argparse
import os
import sys

from .lexer import VakedLexError
from .parser import VakedSyntaxError
from .resolve import build_graph
from .parser import parse_source
from .emit import to_canonical_json, to_sqlite


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


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="vakedc",
        description="Vaked front-end: parse .vaked -> Labeled Property Graph.",
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
    args = ap.parse_args(argv)

    if args.cmd == "parse":
        return _cmd_parse(args)
    ap.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
