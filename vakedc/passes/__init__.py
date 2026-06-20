#!/usr/bin/env python3
"""vakedc.passes — MLIR-mirror pass pipeline (Stage 0 Python reference).

This package factors the three MLIR passes from the monolithic checker/lowerer
into composable, independently testable units that mirror the Stage-1 MLIR
dialect pass design (0013, 0019--0024). Each pass maps to one MLIR pass:

  Pass 1 — topology analysis    (0021)  analysis-only, produces diagnostics
  Pass 2 — WAL injection         (0022)  lowering, transforms workflow IR
  Pass 3 — AOT supervisor index  (0023)  codegen, emits gen/workflow/<n>.json

Usage::

    from vakedc.passes import PassPipeline, PassResult

    pipe = PassPipeline()
    result = pipe.run(graph, workflow_nodes)
    # result.diagnostics  — Pass 1 cycle/depth errors
    # result.workflows    — Pass 2 WAL-injected workflow descriptions
    # result.artifacts    — Pass 3 emitted gen/ artifacts

Each pass is importable separately for unit testing:

    from vakedc.passes.pass01_topology import TopologyAnalysis
    diags = TopologyAnalysis.run(graph, wf_node)
"""

from __future__ import annotations

from dataclasses import dataclass, field as dc_field
from typing import Any

from vakedc.graph import Graph, GraphNode
from vakedc.check import Diagnostic


@dataclass
class WorkflowIR:
    """Lowered intermediate representation for one workflow, produced by Pass 1
    and consumed/elaborated by Pass 2, then emitted by Pass 3.

    Mirrors the MLIR ``vaked`` -> ``hcp`` dialect lowering: Pass 1 enriches
    the topology, Pass 2 injects WAL frames, Pass 3 serialises.
    """
    node: GraphNode
    steps: list[GraphNode]
    edges: list[tuple[str, str]]          # (from_name, to_name)
    depth: int = 0
    critical_path: list[str] = dc_field(default_factory=list)
    wal_frames: list[dict] = dc_field(default_factory=list)   # Pass 2 output


@dataclass
class PassResult:
    """Aggregate result of running all three passes on a set of workflows."""
    diagnostics: list[Diagnostic] = dc_field(default_factory=list)
    workflows: list[WorkflowIR] = dc_field(default_factory=list)
    artifacts: dict[str, str] = dc_field(default_factory=dict)   # path -> content


def run_pipeline(graph: Graph, workflow_nodes: list[GraphNode]) -> PassResult:
    """Run all three passes in order on the given workflow nodes.

    This is the Stage-0 reference pipeline that Stage-1 MLIR must reproduce
    (0024 §2.1 observational equivalence)."""
    from .pass01_topology import TopologyAnalysis
    from .pass02_wal import WALInjection
    from .pass03_aot_index import AOTIndexGeneration

    # Pass 1 — analyse topology (cycle + depth + bound). Pass 1 attaches
    # ``_diagnostics`` to each workflow IR that fails (E-WORKFLOW-CYCLE /
    # E-WORKFLOW-DEPTH). Per 0024 §2.1, an IR that failed topology must be
    # rejected with NO artifacts — neither WAL frames (Pass 2) nor the AOT
    # supervisor index (Pass 3) may be materialized for it.
    wf_irs = TopologyAnalysis.run(graph, workflow_nodes)
    failing = [wf for wf in wf_irs if getattr(wf, "_diagnostics", [])]
    clean = [wf for wf in wf_irs if not getattr(wf, "_diagnostics", [])]

    # Pass 2 + Pass 3 run ONLY on the clean IRs. Failing IRs are returned
    # unmodified (no WAL, no AOT), so their artifacts stay empty.
    clean = WALInjection.run(graph, clean)
    artifacts = AOTIndexGeneration.run(graph, clean)

    # Collect diagnostics from the failing IRs (Pass 1 already attached them).
    diags: list[Diagnostic] = []
    for wf in failing:
        diags.extend(getattr(wf, "_diagnostics", []))

    return PassResult(
        diagnostics=diags,
        workflows=clean + failing,
        artifacts=artifacts,
    )


# Convenience alias
PassPipeline = run_pipeline


__all__ = [
    "PassPipeline", "PassResult", "WorkflowIR", "run_pipeline",
]
