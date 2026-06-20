#!/usr/bin/env python3
"""Pass 2 — WAL injection (MLIR 0022, write-ahead log insertion).

Lowering pass that transforms each ``WorkflowIR`` by injecting write-ahead-log
(WAL) frames. For every cross-step dependency edge, a WAL frame is created
modelling the ``hcp`` dialect sequence from 0022:

  1. ``hcp.create_registration_token``  —  record the dependency
  2. ``hcp.write_ahead_log``             —  atomically persist to eventd
  3. ``hcp.fetch_canonical_data``        —  read validated state

In Stage 0 this pass produces abstract frame descriptors rather than actual
MLIR ops. Stage 1 MLIR must produce observationally equivalent WAL sequences
(0024 §7).

Maps to: MLIR ``hcp`` dialect Pass 2 (0022).
Reference: ``vakedc/lower.py`` (emit_workflow_spec embeds eventd log path).
"""

from __future__ import annotations

from vakedc.graph import Graph
from . import WorkflowIR


class WALInjection:
    """Pass 2: Inject write-ahead-log frames for every cross-step dependency.

    For each edge ``A -> B``, generates a WAL frame recording that B depends
    on A's output. These frames are emitted as part of the supervisor index
    by Pass 3.
    """

    @staticmethod
    def run(graph: Graph,
            workflows: list[WorkflowIR]) -> list[WorkflowIR]:
        """Lower all workflow IRs by injecting WAL frames."""
        for wf in workflows:
            wf.wal_frames = _inject_wal(wf)
        return workflows


def _inject_wal(wf: WorkflowIR) -> list[dict]:
    """Generate WAL frames for one workflow's dependency edges.

    Each edge ``(from_step -> to_step)`` produces a registration frame
    following RFC 0004 §3.1 and the 0022 lowering pattern.

    Returns a list of frame dicts with this structure::

        {
            "type": "DependencyRegistration",
            "producer": <step_name>,        # the step whose output is consumed
            "consumer": <step_name>,        # the step doing the consuming
            "step": <producer_step_index>,  # which step of the producer
            "protocol": "hcp.create_registration_token"
        }
    """
    frames: list[dict] = []
    step_index = {s.name: i for i, s in enumerate(wf.steps)}

    for from_name, to_name in wf.edges:
        frame = {
            "type": "DependencyRegistration",
            "producer": from_name,
            "consumer": to_name,
            "step": step_index.get(from_name, 0),
            "protocol": "hcp.create_registration_token",
            "wal": "hcp.write_ahead_log",
            "fetch": "hcp.fetch_canonical_data",
        }
        frames.append(frame)

    return frames
