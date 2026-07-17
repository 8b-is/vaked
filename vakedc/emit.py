#!/usr/bin/env python3
"""vakedc.emit — deterministic serialization of an LPG.

(a) ``to_canonical_json(graph) -> str`` — stable everywhere: nodes sorted by id,
    edges by (from, label, to), a fixed key order on every object, compact
    separators, ``ensure_ascii=False``, trailing newline. Byte-identical across
    runs (no wall-clock, no set iteration order).

(b) ``to_sqlite(graph, path)`` — tables ``nodes`` and ``edges`` with provenance
    columns; ``canonical_dump(path) -> str`` SELECTs in canonical order for the
    determinism tests (not file bytes — SQLite page layout is not byte-stable).
"""

from __future__ import annotations

import json
import sqlite3

# Fixed key order for every emitted object (canonicality).
_NODE_KEYS = ("id", "kind", "name", "labels", "props", "provenance")
_EDGE_KEYS = ("from", "to", "label", "props")
_PROV_KEYS = ("file", "decl", "span")
_SPAN_KEYS = ("byteStart", "byteEnd", "line", "col")


def _canon_span(span: dict) -> dict:
    return {k: span[k] for k in _SPAN_KEYS}


def _canon_prov(prov):
    if prov is None:
        return None
    return {
        "file": prov["file"],
        "decl": prov["decl"],
        "span": _canon_span(prov["span"]),
    }


def _canon_node(nd: dict) -> dict:
    return {
        "id": nd["id"],
        "kind": nd["kind"],
        "name": nd["name"],
        "labels": nd["labels"],
        "props": _canon_value(nd["props"]),
        "provenance": _canon_prov(nd["provenance"]),
    }


def _canon_edge(e: dict) -> dict:
    return {
        "from": e["from"],
        "to": e["to"],
        "label": e["label"],
        "props": _canon_value(e["props"]),
    }


def _canon_value(v):
    """Recursively canonicalize prop dicts: sort object keys for stable output.

    Lists preserve order (source order is meaningful). Dict keys are sorted so the
    same logical graph always serializes identically regardless of insertion order.
    """
    if isinstance(v, dict):
        return {k: _canon_value(v[k]) for k in sorted(v.keys())}
    if isinstance(v, list):
        return [_canon_value(x) for x in v]
    return v


def to_canonical_json(graph) -> str:
    nodes = [_canon_node(n.as_dict()) for n in graph.nodes_sorted()]
    edges = [_canon_edge(e.as_dict()) for e in graph.edges_sorted()]
    doc = {"version": 1, "source": graph.source_file,
           "nodes": nodes, "edges": edges}
    return json.dumps(doc, separators=(",", ":"), ensure_ascii=False) + "\n"


# --------------------------------------------------------------------------- #
# SQLite
# --------------------------------------------------------------------------- #

_SCHEMA = """
CREATE TABLE nodes (
    id         TEXT PRIMARY KEY,
    kind       TEXT NOT NULL,
    name       TEXT NOT NULL,
    labels     TEXT NOT NULL,
    props      TEXT NOT NULL,
    prov_file  TEXT,
    prov_decl  TEXT,
    byte_start INTEGER,
    byte_end   INTEGER,
    line       INTEGER,
    col        INTEGER
);
CREATE TABLE edges (
    src   TEXT NOT NULL,
    dst   TEXT NOT NULL,
    label TEXT NOT NULL,
    props TEXT NOT NULL
);
"""


def _dump_json(v) -> str:
    return json.dumps(_canon_value(v), separators=(",", ":"), ensure_ascii=False)


def to_sqlite(graph, path) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.executescript(_SCHEMA)
        for n in graph.nodes_sorted():
            prov = n.provenance
            if prov is not None:
                pf, pd = prov.file, prov.decl
                bs, be, ln, co = (prov.span.byteStart, prov.span.byteEnd,
                                  prov.span.line, prov.span.col)
            else:
                pf = pd = None
                bs = be = ln = co = None
            conn.execute(
                "INSERT INTO nodes (id,kind,name,labels,props,prov_file,prov_decl,"
                "byte_start,byte_end,line,col) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (n.id, n.kind, n.name, _dump_json(n.labels), _dump_json(n.props),
                 pf, pd, bs, be, ln, co),
            )
        for e in graph.edges_sorted():
            conn.execute(
                "INSERT INTO edges (src,dst,label,props) VALUES (?,?,?,?)",
                (e.source, e.target, e.label, _dump_json(e.props)),
            )
        conn.commit()
    finally:
        conn.close()


def canonical_dump(path) -> str:
    """Deterministic textual dump of a SQLite graph DB (canonical SELECT order)."""
    conn = sqlite3.connect(path)
    try:
        out = []
        cur = conn.execute(
            "SELECT id,kind,name,labels,props,prov_file,prov_decl,"
            "byte_start,byte_end,line,col FROM nodes ORDER BY id"
        )
        for row in cur.fetchall():
            out.append("NODE\t" + "\t".join("" if v is None else str(v)
                                            for v in row))
        cur = conn.execute(
            "SELECT src,label,dst,props FROM edges ORDER BY src,label,dst,props"
        )
        for row in cur.fetchall():
            out.append("EDGE\t" + "\t".join(str(v) for v in row))
        return "\n".join(out) + "\n"
    finally:
        conn.close()
