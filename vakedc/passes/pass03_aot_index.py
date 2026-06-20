#!/usr/bin/env python3
"""Pass 3 — AOT supervisor index generation (MLIR 0023).

Code-generation pass that emits the ``gen/workflow/<name>.json`` supervisor
index for each workflow. This is the read-only routing table that
``agent-supervisord`` loads at boot — precomputed agent IDs, subscriptions,
depths, WAL frames, and eventd log path.

Maps to: MLIR ``hcp`` dialect Pass 3 (0023).
Reference: ``vakedc/lower.py:1909-1962`` (emit_workflow_spec).
"""

from __future__ import annotations

from vakedc.graph import Graph
from vakedc.lower import (
    _header, _lit, _coerce_number, _budget_prop, _ref, _runtime_view,
    _eventd_log_path, _Ordered, _emit_zig_json,
)
from . import WorkflowIR


class AOTIndexGeneration:
    """Pass 3: Emit the boot-time supervisor index for each workflow.

    Produces deterministic JSON artifacts (``gen/workflow/<name>.json``) with
    steps, edges, depth, WAL frames, and eventd log path. Byte-identical to
    the Stage-0 ``emit_workflow_spec`` output (0024 §2.2 reproducibility).
    """

    @staticmethod
    def run(graph: Graph,
            workflows: list[WorkflowIR]) -> dict[str, str]:
        """Emit one ``gen/workflow/<name>.json`` per workflow.

        Returns a ``{path: content}`` dict. Returns empty dict if no runtime
        is declared in the graph.
        """
        rv = _runtime_view(graph)
        if rv is None:
            return {}
        sf = graph.source_file
        files: dict[str, str] = {}

        for wf in workflows:
            pairs = [("_generated", _header(sf, "workflow " + wf.node.name))]
            on = _lit(wf.node.props.get("on"))
            if on is not None:
                pairs.append(("on", on))
            budget = _budget_prop(wf.node.props.get("budget"))
            if budget is not None:
                pairs.append(("budget", budget))
            max_depth = _lit(wf.node.props.get("maxDepth"))
            if max_depth is not None:
                pairs.append(("maxDepth", _coerce_number(max_depth)))

            # Step roster
            step_objs = []
            for st in wf.steps:
                sp = [("name", st.name)]
                agent = _ref(st.props.get("agent"))
                if agent is not None:
                    sp.append(("agent", agent))
                for fld in ("input", "output"):
                    r = _ref(st.props.get(fld))
                    if r is not None:
                        sp.append((fld, r))
                retries = _lit(st.props.get("retries"))
                if retries is not None:
                    sp.append(("retries", _coerce_number(retries)))
                sbudget = _budget_prop(st.props.get("budget"))
                if sbudget is not None:
                    sp.append(("budget", sbudget))
                step_objs.append(_Ordered(sp))
            pairs.append(("steps", step_objs))

            # DAG edges
            pairs.append(("edges", [_Ordered([("from", a), ("to", b)])
                                    for a, b in wf.edges]))

            # Precomputed critical-path depth (Pass 1)
            pairs.append(("depth", wf.depth))

            # WAL frames (Pass 2)
            if wf.wal_frames:
                pairs.append(("wal", wf.wal_frames))

            # eventd log path
            pairs.append(("log", _eventd_log_path(rv)))

            # Critical path (diagnostic enrichment from Pass 1)
            if wf.critical_path:
                pairs.append(("criticalPath", wf.critical_path))

            path = "gen/workflow/%s.json" % wf.node.name
            files[path] = _emit_zig_json(_Ordered(pairs))

        return files
