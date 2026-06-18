#!/usr/bin/env python3
"""vakedc.graph — the Labeled Property Graph (LPG) model.

A parsed Vaked file instantiates an LPG: one :class:`GraphNode` per declaration
(``decl`` / ``node`` / ``capability`` / external stub), with provenance attached
at instantiation, and :class:`GraphEdge` relationships derived by the resolver.

Node id is stable and path-derived:  ``<filename>#<outer>/<inner>`` — the file's
basename, then the slash-joined chain of enclosing decl names (top-level decls
have no inner segment, e.g. ``operator-field.vaked#operator-field``). External
stub nodes use ``external:<head-path>`` as their id.

Provenance ``decl`` string = ``"<kind> <name>"`` (e.g. ``"fiber mediaCompress"``),
matching docs/language/0012-lowering.md §6.2 and the provenance.json fixture.
Span = 0012 §6.2 byte-exact: ``byteStart`` at the decl's leading keyword,
``byteEnd`` exclusive one past the closing ``}``; ``line``/``col`` 1-based.
"""

from __future__ import annotations

from dataclasses import dataclass, field as dc_field


@dataclass
class Span:
    byteStart: int
    byteEnd: int
    line: int
    col: int

    def as_dict(self):
        return {
            "byteStart": self.byteStart,
            "byteEnd": self.byteEnd,
            "line": self.line,
            "col": self.col,
        }


@dataclass
class Provenance:
    file: str
    decl: str               # "<kind> <name>"
    span: Span

    def as_dict(self):
        return {"file": self.file, "decl": self.decl, "span": self.span.as_dict()}


@dataclass
class GraphNode:
    id: str
    kind: str
    name: str
    labels: list
    props: dict
    provenance: "Provenance | None"

    def as_dict(self):
        prov = self.provenance.as_dict() if self.provenance is not None else None
        return {
            "id": self.id,
            "kind": self.kind,
            "name": self.name,
            "labels": list(self.labels),
            "props": self.props,
            "provenance": prov,
        }


@dataclass
class GraphEdge:
    source: str             # 'from' node id
    target: str             # 'to' node id
    label: str
    props: dict = dc_field(default_factory=dict)

    def as_dict(self):
        return {
            "from": self.source,
            "to": self.target,
            "label": self.label,
            "props": self.props,
        }


class Graph:
    """A Labeled Property Graph: id-keyed nodes plus a list of edges."""

    def __init__(self, source_file: str):
        self.source_file = source_file
        self._nodes: "dict[str, GraphNode]" = {}
        self._edges: "list[GraphEdge]" = []
        # Adjacency index: (source_id, label) -> [target_id, ...] in edge
        # insertion order. Populated at edge-add time so it is a single O(E)
        # pass overall (one append per edge), giving O(deg) child lookups
        # instead of an O(E) full scan per parent. The insertion-order list
        # preserves the exact order a full scan of ``edges`` would yield, so
        # downstream determinism (lowering golden bytes) is unchanged.
        self._adjacency: "dict[tuple, list[str]]" = {}

    # --- nodes ----------------------------------------------------------- #

    def add_node(self, node: GraphNode) -> GraphNode:
        if node.id in self._nodes:
            return self._nodes[node.id]
        self._nodes[node.id] = node
        return node

    def get_node(self, node_id: str) -> "GraphNode | None":
        return self._nodes.get(node_id)

    def has_node(self, node_id: str) -> bool:
        return node_id in self._nodes

    def ensure_external(self, head_path: str) -> GraphNode:
        """One external stub node per distinct head path (kind 'external')."""
        node_id = f"external:{head_path}"
        existing = self._nodes.get(node_id)
        if existing is not None:
            return existing
        node = GraphNode(
            id=node_id,
            kind="external",
            name=head_path,
            labels=["external"],
            props={"external": True},
            provenance=None,
        )
        self._nodes[node_id] = node
        return node

    # --- edges ----------------------------------------------------------- #

    def add_edge(self, edge: GraphEdge) -> None:
        self._edges.append(edge)
        self._adjacency.setdefault((edge.source, edge.label), []).append(edge.target)

    def children(self, source_id: str, label: str = "contains") -> "list[GraphNode]":
        """Direct ``label`` children of ``source_id`` as resolved nodes, in edge
        insertion order (the order a full scan of :attr:`edges` would yield).

        O(deg(source_id)) via the adjacency index built at edge-add time, rather
        than the O(E) full edge scan it replaces. Targets that did not resolve to
        a node (e.g. external stubs absent from ``_nodes``) are skipped, matching
        the historical full-scan behaviour."""
        out = []
        for target_id in self._adjacency.get((source_id, label), ()):
            node = self._nodes.get(target_id)
            if node is not None:
                out.append(node)
        return out

    # --- views ----------------------------------------------------------- #

    @property
    def nodes(self) -> "list[GraphNode]":
        return list(self._nodes.values())

    @property
    def edges(self) -> "list[GraphEdge]":
        return list(self._edges)

    def nodes_sorted(self) -> "list[GraphNode]":
        return sorted(self._nodes.values(), key=lambda nd: nd.id)

    def edges_sorted(self) -> "list[GraphEdge]":
        # canonical order: (from, label, to), then a stable tiebreak on props
        return sorted(
            self._edges,
            key=lambda e: (e.source, e.label, e.target, _stable_props_key(e.props)),
        )


def _stable_props_key(props: dict) -> str:
    import json
    return json.dumps(props, sort_keys=True, ensure_ascii=False)


def node_id(filename: str, chain: "list[str]") -> str:
    """Stable, path-derived node id: ``<filename>#<outer>/<inner>/...``."""
    return f"{filename}#{'/'.join(chain)}"
