#!/usr/bin/env python3
"""Pass 1 — Topology analysis (MLIR 0021, Stage-0 check.py:1720-1785).

Analysis-only pass over workflow nodes: cycle detection (iterative DFS),
critical-path depth computation, and maxDepth bound enforcement. Produces
diagnostics but does not transform the IR.

Maps to: MLIR ``vaked`` dialect Pass 1 (0021).
Reference: ``vakedc/check.py:1727-1785``.
"""

from __future__ import annotations

from vakedc.graph import Graph, GraphNode
from vakedc.check import Diagnostic
from vakedc.lower import _workflow_steps_edges
from . import WorkflowIR


class TopologyAnalysis:
    """Pass 1: Static DAG / critical-path analysis over workflow topologies.

    Verifies each workflow's step graph is acyclic, computes the critical-path
    depth, and enforces the declared maxDepth bound (if present).
    """

    @staticmethod
    def run(graph: Graph, workflow_nodes: list[GraphNode]) -> list[WorkflowIR]:
        """Analyse all workflow nodes. Returns one WorkflowIR per node, with
        diagnostics attached to ``_diagnostics`` on each IR that fails."""
        results: list[WorkflowIR] = []
        for wf in workflow_nodes:
            ir = _analyse_one(graph, wf)
            results.append(ir)
        return results


def _analyse_one(graph: Graph, wf: GraphNode) -> WorkflowIR:
    """Analyse a single workflow node. Returns a WorkflowIR (with depth and
    critical_path populated) and attaches diagnostics on error."""
    diags: list[Diagnostic] = []
    steps, edges = _workflow_steps_edges(graph, wf)
    file = graph.source_file
    span = _decl_span(wf)

    # Build successor map
    step_names = {s.name for s in steps}
    succ: dict[str, list[str]] = {s.name: [] for s in steps}
    for a, b in edges:
        if a in step_names and b in step_names:
            succ[a].append(b)

    # --- Cycle detection: iterative DFS with colour map (check.py:1727-1759) ---
    WHITE, GREY, BLACK = 0, 1, 2
    colour = {s: WHITE for s in step_names}
    cycle = None
    for root in step_names:
        if cycle is not None or colour[root] != WHITE:
            continue
        stack = [(root, iter(succ[root]))]
        colour[root] = GREY
        path = [root]
        while stack and cycle is None:
            node, it = stack[-1]
            advanced = False
            for nxt in it:
                if colour[nxt] == GREY:
                    cycle = path[path.index(nxt):] + [nxt]
                    break
                if colour[nxt] == WHITE:
                    colour[nxt] = GREY
                    path.append(nxt)
                    stack.append((nxt, iter(succ[nxt])))
                    advanced = True
                    break
            if not advanced and cycle is None:
                colour[node] = BLACK
                path.pop()
                stack.pop()
    if cycle is not None:
        diags.append(Diagnostic(
            code="E-WORKFLOW-CYCLE",
            message=(f"workflow `{wf.name}` step edges must form a DAG; cycle: "
                     f"{' -> '.join(cycle)} (express revision loops as `retries` "
                     f"on a step, not back-edges)"),
            file=file, severity="error", **span,
            decl=f"workflow {wf.name}",
        ))
        ir = WorkflowIR(node=wf, steps=steps, edges=edges, depth=0)
        ir._diagnostics = diags  # type: ignore[attr-defined]
        return ir

    # --- Critical-path depth (check.py:1761-1769) ---
    memo: dict[str, int] = {}
    def _depth(name: str) -> int:
        if name not in memo:
            memo[name] = 1 + max((_depth(n) for n in succ[name]), default=0)
        return memo[name]

    depth = max((_depth(s.name) for s in steps), default=0)

    # Reconstruct the longest path
    critical_path = _longest_path(succ, memo)

    # --- Depth bound enforcement (check.py:1771-1785) ---
    from vakedc.lower import _lit
    bindings = wf.props  # Already-resolved props from the graph
    md_raw = wf.props.get("maxDepth")
    if md_raw is not None:
        try:
            md_lit = _lit({"lit": "number", "value": md_raw}) \
                if not isinstance(md_raw, dict) else _lit(md_raw)
            if md_lit is not None:
                bound = int(str(md_lit))
                if depth > bound:
                    diags.append(Diagnostic(
                        code="E-WORKFLOW-DEPTH",
                        message=(f"workflow `{wf.name}` has critical-path depth "
                                 f"{depth}, exceeding the declared maxDepth = {bound}"),
                        file=file, severity="error", **span,
                        decl=f"workflow {wf.name}",
                    ))
        except (ValueError, TypeError):
            pass  # Non-integer literal — the type checker owns that error

    ir = WorkflowIR(node=wf, steps=steps, edges=edges,
                    depth=depth, critical_path=critical_path)
    ir._diagnostics = diags  # type: ignore[attr-defined]
    return ir


def _longest_path(succ: dict[str, list[str]],
                  memo: dict[str, int]) -> list[str]:
    """Reconstruct the longest path from the memoised depth map."""
    if not succ or not memo:
        return []
    start = max(memo, key=memo.get)  # deepest node
    path = [start]
    while succ.get(start):
        # Pick the deepest successor
        nexts = [(n, memo.get(n, 0)) for n in succ[start]]
        if not nexts:
            break
        nexts.sort(key=lambda x: -x[1])
        start = nexts[0][0]
        path.append(start)
    return path


def _decl_span(wf: GraphNode) -> dict:
    """Extract span info from a workflow node's provenance."""
    prov = wf.provenance
    if prov and prov.span:
        return {
            "line": prov.span.line,
            "col": prov.span.col,
            "byteStart": prov.span.byteStart,
            "byteEnd": prov.span.byteEnd,
        }
    return {"line": 0, "col": 0, "byteStart": 0, "byteEnd": 0}
