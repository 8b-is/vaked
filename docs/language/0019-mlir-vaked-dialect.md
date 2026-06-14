---
doc: 0019
title: "MLIR vaked dialect — agent dataflow ops, types, verifier"
status: Review
track: Language / MLIR
created: 2026-06-14
issue: 23
epic: 17
---

# 0019 — The `vaked` MLIR dialect

Status: **Review** (2026-06-14) · Series: language design notes · Track:
**Language / MLIR** · Issue
[#23](https://github.com/peterlodri-sec/vaked-base/issues/23) · Epic
[#17](https://github.com/peterlodri-sec/vaked-base/issues/17)

Part of the MLIR set; umbrella + terminology in
[0013](./0013-mlir-topology-compilation.md). Stage-0 reference semantics: the
typed semantic graph (LPG) `vakedc` produces, specifically the `workflow`
agent-step DAG checked in `vakedc/check.py` (`_check_workflow`) and the
[0015](./0015-workflow.md) construct.

## Abstract

This part specifies the **high-level `vaked` dialect**: the MLIR serialization
of the multi-agent dataflow graph. Agents are structural region ops; a step's
committed output is an SSA value of type `!vaked.state_hash`; a cross-agent
dependency is an explicit `vaked.consume`. SSA use-def chains *are* the agent
dependency lineages — the property [0021](./0021-mlir-pass-topology-analysis.md)
analyzes. Every op is given as operands / results / attributes / types +
verifier invariants, at the precision needed to write its TableGen `.td`.

## Terminology

| Term | Definition |
|------|------------|
| Agent | A boundary owning state schemas + execution logic; a `vaked.agent` region op, named by a `sym_name`. |
| State hash | The eventd `StepHash` (RFC 0004 terminology) anchoring a step's committed output; the SSA value type `!vaked.state_hash`. |
| Producer / consumer | The agent whose step output is read / the agent reading it (RFC 0004 §1). A `vaked.consume` names its producer by symbol. |
| Dependency lineage | The transitive use-def chain of `!vaked.state_hash` values across `vaked.consume`; the `state_dependency` edge set Pass 1 requires acyclic. |

## 1. Types

### `!vaked.state_hash`

An opaque, value-typed handle to a step's committed output — the cryptographic
anchor a downstream dependency pins (RFC 0004's `StepHash`). It carries no
payload in the IR; it is a dataflow token whose **use-def edges encode the
dependency graph**. Parameterless in v1.

```
!vaked.state_hash
```

### `!vaked.agent` (symbol, not a value type)

Agents are **symbols**, not SSA values: a `vaked.agent` op defines a
`SymbolRefAttr`-addressable name, and `vaked.consume` references a producer by
that symbol (`@agent_alpha`). v1 introduces no first-class `!vaked.agent` value
type; if a future revision needs to pass an agent as a value (e.g. higher-order
supervision), it is added then. State, not agents, flows as SSA.

## 2. Operations

Worked reference (the canonical shape this dialect serializes):

```mlir
vaked.agent @agent_alpha {
  %s15 = vaked.execute_step { step = 15 : i64 } : () -> !vaked.state_hash
  vaked.yield %s15 : !vaked.state_hash
}

vaked.agent @agent_beta {
  // beta consumes alpha's step-15 output — the load-bearing cross-agent edge
  %in = vaked.consume { producer = @agent_alpha, producer_step = 15 : i64 } : !vaked.state_hash
  %out = vaked.execute_with_dep(%in) : (!vaked.state_hash) -> !vaked.state_hash
  vaked.yield %out : !vaked.state_hash
}
```

### 2.1 `vaked.agent`

| | |
|---|---|
| **Role** | Agent boundary; the structural region op (like `func.func`). |
| **Attributes** | `sym_name : SymbolNameAttr` (required, unique in the module). Optional `epoch : i64` recording the topology epoch the body was compiled under (RFC 0004 §7). |
| **Regions** | exactly one, single-block, terminated by `vaked.yield`. |
| **Operands / results** | none (it is a definition, not a value). |
| **Traits** | `Symbol`, `IsolatedFromAbove`, `SingleBlockImplicitTerminator<"vaked.yield">`. |

Verifier — **V-AGENT**:
1. `sym_name` is present and unique among `vaked.agent` ops in the module.
2. The region has exactly one block whose terminator is `vaked.yield`.

### 2.2 `vaked.execute_step`

| | |
|---|---|
| **Role** | An intra-agent step that commits an output (no cross-agent dependency). |
| **Operands** | variadic `!vaked.state_hash` — intra-agent predecessors (may be empty). |
| **Results** | exactly one `!vaked.state_hash`. |
| **Attributes** | `step : i64` (optional; the eventd `StepId`, else inferred by Pass 3 ordering). |

Verifier — **V-STEP**: the single result is `!vaked.state_hash`; all operands
are `!vaked.state_hash`; the op is inside a `vaked.agent` region.

### 2.3 `vaked.consume` — the load-bearing op

| | |
|---|---|
| **Role** | Agent B reading agent A's step output. **Every cross-agent dependency is one `vaked.consume`** — there is no other way to depend on another agent. |
| **Operands** | none. |
| **Results** | exactly one `!vaked.state_hash` (the consumed input). |
| **Attributes** | `producer : FlatSymbolRefAttr` (required → a `vaked.agent`); `producer_step : i64` (optional; the anchored producer step, RFC 0004 §1). |

Verifier — **V-CONSUME**:
1. `producer` resolves to a `vaked.agent` symbol in the module (else the
   structural analogue of `E-REF-UNRESOLVED`).
2. The op is lexically inside a `vaked.agent` region (the **consumer**).
3. `producer != ` the enclosing consumer's `sym_name` (no self-consume — a
   trivial cycle; the non-trivial case is Pass 1's, [0021](./0021-mlir-pass-topology-analysis.md)).
4. The single result is `!vaked.state_hash`.

This op is the surface Pass 1 reads to build the `state_dependency` edge
(consumer agent ← `producer`) and Pass 2 rewrites into the `hcp` WAL sequence
([0022](./0022-mlir-pass-wal-injection.md)).

### 2.4 `vaked.execute_with_dep`

| | |
|---|---|
| **Role** | Downstream execution built on consumed input(s) — the dependent form of `execute_step`. |
| **Operands** | **≥ 1** `!vaked.state_hash` (its dependencies, typically `vaked.consume` results). |
| **Results** | exactly one `!vaked.state_hash`. |
| **Attributes** | `step : i64` (optional). |

Verifier — **V-DEP**: at least one operand; all operands and the single result
are `!vaked.state_hash`; inside a `vaked.agent` region. The use-def edge from a
`vaked.consume` result into a `vaked.execute_with_dep` operand is the IR
encoding of "this step's output causally depends on the consumed anchor."

### 2.5 `vaked.yield`

| | |
|---|---|
| **Role** | Terminator of a `vaked.agent` region; names the agent's exported outputs. |
| **Operands** | variadic `!vaked.state_hash`. |
| **Traits** | `Terminator`, `HasParent<"vaked.agent">`. |

Verifier — **V-YIELD**: parent is `vaked.agent`; every operand is
`!vaked.state_hash`.

## 3. SSA use-def chains as dependency lineages

Because state flows as SSA values, the use-def chain *is* the dependency graph,
with no separate bookkeeping:

- **Intra-agent**: `execute_step`/`execute_with_dep` results feed later ops in
  the same region — ordinary SSA dominance.
- **Inter-agent**: a `vaked.consume {producer = @A}` in agent `@B` is a
  cross-region edge `@A → @B`, recovered by the verifier resolving the symbol.
  The union of these edges (one per `vaked.consume`) is the **state-dependency
  subgraph** (RFC 0004 §5) whose acyclicity Pass 1 enforces.

This mirrors what the LPG already encodes: a `workflow`'s `->` step edges are
`state_dependency` edges (`vakedc/check.py` `_check_workflow`), and the dialect
is a *serialization of the same typed graph* — "syntax is the mask; the graph
is the face."

## 4. TableGen mapping (Stage-1 starting point)

Each op above maps directly to ODS. Sketch for the two load-bearing ops:

```tablegen
def Vaked_StateHashType : TypeDef<Vaked_Dialect, "StateHash"> {
  let mnemonic = "state_hash";
}

def Vaked_AgentOp : Vaked_Op<"agent", [
    Symbol, IsolatedFromAbove,
    SingleBlockImplicitTerminator<"vaked::YieldOp">]> {
  let arguments = (ins SymbolNameAttr:$sym_name, OptionalAttr<I64Attr>:$epoch);
  let regions = (region SizedRegion<1>:$body);
}

def Vaked_ConsumeOp : Vaked_Op<"consume", []> {
  let arguments = (ins FlatSymbolRefAttr:$producer,
                       OptionalAttr<I64Attr>:$producer_step);
  let results   = (outs Vaked_StateHashType:$input);
  let hasVerifier = 1;   // V-CONSUME (1)-(4)
}
```

The verifier invariants V-AGENT … V-YIELD are the `hasVerifier` bodies. A
compiler developer can begin the dialect from this part alone; nothing here
defers an op's shape to a later document.

## 5. Stage-0 fidelity

The Stage-1 verifier MUST agree with the shipped Stage-0 checks
([0024](./0024-mlir-lowering-staged-adoption.md) §4):

| `vaked` dialect | Stage-0 (LPG) |
|-----------------|---------------|
| `vaked.agent @X` | a `workflow` step's `agent = mesh.X` / a mesh agent node |
| `vaked.consume {producer=@A}` in `@B` | a `workflow` `->` ordering edge `A -> B` (a `state_dependency` edge) |
| `!vaked.state_hash` result of a step | the step `output` token in `gen/workflow/<name>.json` |
| V-CONSUME (1) symbol resolution | `_check_workflow`'s `E-REF-UNRESOLVED` on an `agent` head that names no sibling node |

## Security considerations

- **Symbol resolution is a trust boundary.** An unresolved `producer`
  (V-CONSUME 1) MUST fail verification, never silently drop the edge — a
  dropped edge is a dependency the runtime won't register (RFC 0004 §3),
  re-opening the "run on history that was never pinned" hazard.
- **No implicit cross-agent dataflow.** Because `vaked.consume` is the only way
  to depend on another agent, the verified IR cannot hide a dependency from
  Pass 1. Any future op that introduces cross-agent dataflow MUST be added to
  the Pass-1 edge extraction in the same change.

## Open questions

- Whether `!vaked.state_hash` should be parameterized by the producing agent's
  state schema (a typed `!vaked.state<@A, "schemaName">`) for richer
  verification, or stay opaque in v1. Opaque is sufficient for Pass 1/2/3.
- Whether `vaked.execute_step` and `vaked.execute_with_dep` should be one op
  distinguished by operand arity, or stay two ops for readability. (Non-gating;
  either lowers identically.)
