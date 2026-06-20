//===-- HcpDialect.td - HCP MLIR dialect definitions ---------*- tablegen -*-===//
//
// Defines the `hcp` dialect: low-level orchestration mechanics.
// Spec: docs/language/0020-mlir-hcp-dialect.md
//
//===----------------------------------------------------------------------===//

#ifndef VAKED_HCP_DIALECT
#define VAKED_HCP_DIALECT

// MLIR base class definitions.
include "mlir/IR/OpBase.td"

// ---------------------------------------------------------------------------//
// Dialect definition
// ---------------------------------------------------------------------------//

def Hcp_Dialect : Dialect {
  let name = "hcp";
  let summary = "Low-level orchestration (HCP protocol) dialect";
  let description = [{
    The `hcp` dialect models the low-level orchestration mechanics defined by
    the HCP (Hierarchical Control Plane) protocol. It provides operations for
    write-ahead logging, state-dependency registration, canonical data fetching,
    and rewind-scope framing — with strong guarantees around concurrency and
    state drift.

    This dialect is produced by lowering the high-level `vaked` dialect
    (via Pass 2), and serves as the intermediate layer before LLVM lowering.
  }];
  let cppNamespace = "::vaked::mlir::hcp";
  let hasConstantMaterializer = 0;
  let hasOperationAttrVerify = 0;
  let hasRegionArgAttrVerify = 0;
}

// ---------------------------------------------------------------------------//
// Type definitions
// ---------------------------------------------------------------------------//

// Opaque WAL registration token.
def Hcp_TokenType : TypeDef<Hcp_Dialect, "token"> {
  let mnemonic = "token";
  let summary = "Write-ahead-log registration token";
  let description = [{
    Opaque type representing a recorded write-ahead-log registration.
    Created by hcp.create_registration_token.
    Proof that a dependency was logged in the WAL before consumption.
  }];
  let assemblyFormat = "`token`";
}

// Opaque state hash validated against the WAL.
def Hcp_HashType : TypeDef<Hcp_Dialect, "hash"> {
  let mnemonic = "hash";
  let summary = "State hash validated against the WAL";
  let description = [{
    Opaque type representing a state hash validated against the WAL.
    Token that the state producer and consumer agree upon for a given step.
  }];
  let assemblyFormat = "`hash`";
}

// Polymorphic canonical data container.
def Hcp_DataType : TypeDef<Hcp_Dialect, "data"> {
  let mnemonic = "data";
  let summary = "Polymorphic canonical state data";
  let description = [{
    Polymorphic type for canonical state data indexed by a type parameter.
    Syntax: !hcp.data<type>
    Carries validated state bytes fetched after WAL registration.
  }];
  let parameters = (ins TypeParameter<"inner type", "inner type">:$innerType);
  let assemblyFormat = "`<` $innerType `>`";
}

// ---------------------------------------------------------------------------//
// Operation definitions
// ---------------------------------------------------------------------------//

// Base class for hcp ops.
class Hcp_Op<string mnemonic, list<Trait> traits = []>
    : Op<Hcp_Dialect, mnemonic, traits> {
  let hasVerifier = 0;
}

//===----------------------------------------------------------------------===//
// hcp.create_registration_token
//===----------------------------------------------------------------------===//

def Hcp_CreateRegistrationTokenOp : Hcp_Op<"create_registration_token"> {
  let summary = "Create a WAL registration token";
  let description = [{
    Creates a WAL token before a cross-agent dependency is consumed.
    Constructs a DependencyRegistration frame and records it in the WAL
    via eventd. The returned token proves that the registration was logged
    before state was consumed.

    Syntax:
      %token = hcp.create_registration_token(%producer, %step, %hash) : !hcp.token

    Verifier rules:
    1. All operands must be SSA values.
    2. The third operand must be of type !vaked.state_hash.
    3. The result type is always !hcp.token.
    4. Must appear before the corresponding hcp.fetch_canonical_data.

    Reference: RFC 0004 §3.1 (DependencyRegistration frame structure).
  }];

  // Using untyped operands; the verifier checks the %hash type constraint.
  let arguments = (ins
    AnyType:$producer_id,
    AnyType:$step_id,
    AnyType:$hash
  );

  let results = (outs Hcp_TokenType:$token);

  let assemblyFormat = [{
    `(` $producer_id `,` $step_id `,` $hash `)` attr-dict
    `:` `(` type($producer_id) `,` type($step_id) `,` type($hash) `)` `->` type($token)
  }];
}

//===----------------------------------------------------------------------===//
// hcp.write_ahead_log
//===----------------------------------------------------------------------===//

def Hcp_WriteAheadLogOp : Hcp_Op<"write_ahead_log"> {
  let summary = "Log a registration token to the WAL";
  let description = [{
    Explicitly logs a registration token to the WAL (called by Pass 2 as
    part of lowering vaked.consume). Atomically records the token in eventd.

    Syntax:
      hcp.write_ahead_log %token

    Verifier rules:
    1. Operand must be of type !hcp.token.
    2. Must appear between hcp.create_registration_token and
       hcp.fetch_canonical_data in program order.
    3. Must appear inside a hcp.rewind_scope.

    Reference: RFC 0004 §2 (WAL discipline).
  }];

  let arguments = (ins Hcp_TokenType:$token);

  let assemblyFormat = "$token attr-dict";
}

//===----------------------------------------------------------------------===//
// hcp.fetch_canonical_data
//===----------------------------------------------------------------------===//

def Hcp_FetchCanonicalDataOp : Hcp_Op<"fetch_canonical_data"> {
  let summary = "Fetch validated state data from the producer";
  let description = [{
    Fetches the validated state from the producer agent.
    Retrieves the actual state bytes from the producer agent, validated to
    match the hash in the registered token. If the state has drifted (hash
    mismatch), a RewindEvent is raised.

    Syntax:
      %data = hcp.fetch_canonical_data(%producer_id, %token) : !hcp.data<T>

    Verifier rules:
    1. The token operand must be of type !hcp.token.
    2. Must be preceded by hcp.write_ahead_log.
    3. Must appear inside a hcp.rewind_scope.

    Reference: RFC 0004 §5 (canonical data fetch and hash validation).
  }];

  let arguments = (ins
    AnyType:$producer_id,
    Hcp_TokenType:$token
  );

  let results = (outs Hcp_DataType:$data);

  let assemblyFormat = [{
    `(` $producer_id `,` $token `)` attr-dict
    `:` `(` type($producer_id) `)` `->` type($data)
  }];
}

//===----------------------------------------------------------------------===//
// hcp.rewind_scope
//===----------------------------------------------------------------------===//

def Hcp_RewindScopeOp : Hcp_Op<"rewind_scope", [
    SingleBlockImplicitTerminator<"HcpYieldOp">,
]> {
  let summary = "Encapsulate a state-drift-vulnerable block";
  let description = [{
    Encapsulates a code block vulnerable to state drift (RFC 0004 §3.3).
    All hcp.fetch_canonical_data and hcp.write_ahead_log operations must
    appear inside a rewind_scope. The scope body must be idempotent so that
    re-execution after recovery yields the same result.

    Syntax:
      hcp.rewind_scope {
        ...
      }

    Verifier rules:
    1. Contains exactly one block.
    2. Block must terminate with hcp.yield.
    3. All WAL operations must appear inside the scope.
    4. May be nested (up to MAX_RECURSION_DEPTH = 256).

    Reference: RFC 0004 §3.3 (anchor voiding on rewind);
    RFC 0004 §6 (cold-start verification).
  }];

  let regions = (region SizedRegion<1>:$body);

  let assemblyFormat = "$body attr-dict";
}

//===----------------------------------------------------------------------===//
// hcp.yield
//===----------------------------------------------------------------------===//

def Hcp_YieldOp : Hcp_Op<"yield", [
    Terminator,
    ParentOneOf<["HcpRewindScopeOp"]>,
]> {
  let summary = "Terminate a hcp.rewind_scope region";
  let description = [{
    Terminates a hcp.rewind_scope region. Returns control to the enclosing
    operation. Takes no operands — hcp.rewind_scope produces no results.
  }];

  let assemblyFormat = "attr-dict";
}

#endif // VAKED_HCP_DIALECT
