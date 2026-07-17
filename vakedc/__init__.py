#!/usr/bin/env python3
"""vakedc — the first executable Vaked front-end (lexer + parser -> LPG + checker).

Implements 0011 pipeline stages 1-2 (parse + resolve) over grammar v0.3, producing
a Labeled Property Graph with byte-exact provenance, and stages 3-4 (elaborate +
check) in :mod:`vakedc.check` (the Goal-2 type system).  Standalone,
Python-3-stdlib-only prototype (the production parser is Zig later).

See ``vakedc/README.md``,
``docs/superpowers/specs/2026-06-10-vakedc-parser-prototype-design.md`` and
``docs/superpowers/specs/2026-06-10-vakedc-checker-design.md``.
"""

from __future__ import annotations

from .check import (
    Diagnostic,
    check_file,
    check_source,
    default_builtins_path,
    load_builtins,
)
from .emit import canonical_dump, to_canonical_json, to_sqlite
from .graph import Graph
from .lexer import PINNED_UNICODE, VakedLexError, tokenize
from .parser import VakedSyntaxError, parse_source
from .resolve import build_graph

__all__ = [
    "parse_file", "parse_string", "tokenize", "build_graph",
    "to_canonical_json", "to_sqlite", "canonical_dump",
    "Graph", "VakedLexError", "VakedSyntaxError", "PINNED_UNICODE",
    "check_source", "check_file", "load_builtins", "default_builtins_path",
    "Diagnostic",
]


def parse_string(src: str, filename: str = "<vaked>") -> Graph:
    """Parse Vaked source text into a resolved :class:`Graph`."""
    items = parse_source(src, filename)
    return build_graph(items, filename)


def parse_file(path: str) -> Graph:
    """Parse a ``.vaked`` file into a resolved :class:`Graph`.

    The provenance/source file recorded in the graph is ``path`` as given.
    """
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    return parse_string(src, path)
