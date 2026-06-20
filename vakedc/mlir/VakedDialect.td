//===-- VakedDialect.td - Vaked MLIR dialect definitions ------*- tablegen -*-===//
//
// Defines the `vaked` dialect: high-level agent topology compilation.
// Spec: docs/language/0019-mlir-vaked-dialect.md
//
//===----------------------------------------------------------------------===//

#ifndef VAKED_VAKED_DIALECT
#define VAKED_VAKED_DIALECT

// MLIR base class definitions.
include "mlir/IR/OpBase.td"
include "mlir/IR/SymbolInterfaces.td"

// ---------------------------------------------------------------------------//
// Dialect definition
// ---------------------------------------------------------------------------//

def Vaked_Dialect : Dialect {
  let name = "vaked";
  let summary = "High-level multi-agent topology dialect";
  let description = [{
    The `vaked` dialect models the high-level multi-agent dependency graph as
    an MLIR abstraction layer. It defines structural operations for agents,
    state consumption, execution steps, and the types needed to represent the
    typed semantic graph that vakedc produces. SSA use-def chains in this
    dialect directly model agent dependency lineages.
  }];
  let cppNamespace = "::vaked::mlir";
  let hasConstantMaterializer = 0;
  let hasOperationAttrVerify = 0;
  let hasRegionArgAttrVerify = 0;
}

// ---------------------------------------------------------------------------//
// Type definitions
// ---------------------------------------------------------------------------//

// Opaque state hash — produced by execute_step, consumed by consume.
def Vaked_StateHashType : TypeDef<Vaked_Dialect, "state_hash"> {
  let mnemonic = "state_hash";
  let summary = "Opaque agent state content hash";
  let description = [{
    The opaque type representing an agent state's content hash.
    Must not be constructed from literals; only produced by vaked.execute_step.
  }];
  let assemblyFormat = "`state_hash`";
}

// Agent identity — reserved for future SSA type constraints.
def Vaked_AgentIdType : TypeDef<Vaked_Dialect, "agent_id"> {
  let mnemonic = "agent_id";
  let summary = "Agent identity type";
  let description = [{
    Agent identity type. Reserved for future SSA type constraints.
  }];
  let assemblyFormat = "`agent_id`";
}

// Polymorphic state container — indexed by a schema parameter.
def Vaked_StateType : TypeDef<Vaked_Dialect, "state"> {
  let mnemonic = "state";
  let summary = "Polymorphic state payload type";
  let description = [{
    Polymorphic payload type indexed by a state schema.
    Syntax: !vaked.state<"schema_name">
    Generic container for agent memory; used in vaked.agent context.
  }];
  let parameters = (ins StringRefParameter<"schema">:$schema);
  let assemblyFormat = "`<` $schema `>`";
}

// ---------------------------------------------------------------------------//
// Operation definitions
// ---------------------------------------------------------------------------//

// Base class for vaked ops.
class Vaked_Op<string mnemonic, list<Trait> traits = []>
    : Op<Vaked_Dialect, mnemonic, traits> {
  let hasVerifier = 1;
}

//===----------------------------------------------------------------------===//
// vaked.agent
//===----------------------------------------------------------------------===//

def Vaked_AgentOp : Vaked_Op<"agent", [
    IsolatedFromAbove,
    Symbol,
    SingleBlockImplicitTerminator<"VakedYieldOp">,
]> {
  let summary = "Agent boundary and execution context";
  let description = [{
    Defines an agent boundary and its execution context.
    An agent takes no positional parameters; all cross-agent state flow is
    via vaked.consume inside the region. The region must end with vaked.yield.

    Syntax:
      vaked.agent @agent_name -> (result_type, ...) {
        ...
      }

    Verifier rules:
    1. Region is non-empty and contains exactly one block.
    2. The block's terminator is vaked.yield.
    3. Result count matches vaked.yield operand count.
    4. Symbol name must be unique within the module.
  }];

  let arguments = (ins
    SymbolNameAttr:$sym_name,
    OptionalAttr<StrAttr>:$state_schema
  );

  let results = (outs Variadic<AnyType>:$results);

  let regions = (region SizedRegion<1>:$body);

  let assemblyFormat = [{
    $sym_name (`->` type($results)^)? $body attr-dict
  }];


}

//===----------------------------------------------------------------------===//
// vaked.yield
//===----------------------------------------------------------------------===//

def Vaked_YieldOp : Vaked_Op<"yield", [
    Terminator,
    ParentOneOf<["VakedAgentOp"]>,
]> {
  let summary = "Terminate a vaked.agent region";
  let description = [{
    Terminates a vaked.agent region and returns SSA values as the agent's
    outputs. The operand types and count must match the parent agent's
    declared result types.

    Syntax:
      vaked.yield %val1, %val2, ...
  }];

  let arguments = (ins Variadic<AnyType>:$operands);

  let assemblyFormat = "$operands attr-dict `:` type($operands)";


}

//===----------------------------------------------------------------------===//
// vaked.execute_step
//===----------------------------------------------------------------------===//

def Vaked_ExecuteStepOp : Vaked_Op<"execute_step"> {
  let summary = "Execute a single agent step, producing a state hash";
  let description = [{
    Represents the execution of a single agent step, producing a state hash.
    Must appear inside a vaked.agent region. Multiple steps within an agent
    are chained via SSA dependencies.

    Syntax:
      %result = vaked.execute_step()
      %result = vaked.execute_step(%arg0, %arg1) -> !vaked.state_hash

    Verifier rules:
    1. Must appear inside a vaked.agent region.
    2. Always produces exactly one !vaked.state_hash result.
  }];

  let arguments = (ins Variadic<AnyType>:$dependencies);

  let results = (outs Vaked_StateHashType:$result);

  let assemblyFormat = [{
    (`(` $dependencies^ `)`)? attr-dict
    `:` `(` type($dependencies) `)` `->` type($result)
  }];

  let hasVerifier = 0;
}

//===----------------------------------------------------------------------===//
// vaked.consume
//===----------------------------------------------------------------------===//

def Vaked_ConsumeOp : Vaked_Op<"consume"> {
  let summary = "Cross-agent dependency: agent B reads agent A's output";
  let description = [{
    Agent B reads agent A's output (cross-agent dependency).
    The referenced producer agent must exist in the module.
    This operation is the insertion point for Pass 2's WAL injection.

    Syntax:
      %input = vaked.consume @agent_name : !vaked.state_hash
      %input = vaked.consume @agent_name (%token) : !vaked.state_hash

    Verifier rules:
    1. Must appear inside a vaked.agent region.
    2. The referenced producer agent must exist.
    3. Result type is always !vaked.state_hash.
  }];

  let arguments = (ins
    FlatSymbolRefAttr:$producer,
    Optional<Vaked_StateHashType>:$token
  );

  let results = (outs Vaked_StateHashType:$result);

  let assemblyFormat = [{
    $producer (`(` $token^ `)`)? attr-dict `:` type($result)
  }];

  let hasVerifier = 0;
}

//===----------------------------------------------------------------------===//
// vaked.execute_with_dep
//===----------------------------------------------------------------------===//

def Vaked_ExecuteWithDepOp : Vaked_Op<"execute_with_dep"> {
  let summary = "Execute with explicit dependency annotation";
  let description = [{
    A variant of vaked.execute_step that explicitly documents a dependency
    from another agent (often the result of a vaked.consume). The first
    operand is the critical path dependency. This aids in critical-path
    analysis (Pass 1).

    Syntax:
      %result = vaked.execute_with_dep(%dep) -> !vaked.state_hash

    Verifier rules:
    1. Must have at least 1 operand (the primary dependency).
    2. Always produces exactly 1 !vaked.state_hash result.
  }];

  let arguments = (ins
    Variadic<AnyType>:$operands
  );

  let results = (outs Vaked_StateHashType:$result);

  let assemblyFormat = [{
    `(` $operands `)` attr-dict `:` type($operands) `->` type($result)
  }];


}

#endif // VAKED_VAKED_DIALECT
