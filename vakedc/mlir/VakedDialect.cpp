//===-- VakedDialect.cpp - Vaked MLIR dialect implementation ---------------===//
//
// Implements the vaked dialect: agent topology for multi-agent compilation.
// Spec: docs/language/0019-mlir-vaked-dialect.md
//
//===----------------------------------------------------------------------===//

#include "VakedDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/Verifier.h"
#include "llvm/ADT/TypeSwitch.h"

//===----------------------------------------------------------------------===//
// Op definitions (included ONCE at file scope).
//===----------------------------------------------------------------------===//

#define GET_OP_CLASSES
#include "VakedDialect.cpp.inc"

//===----------------------------------------------------------------------===//
// Dialect registration (uses filtered types-only inc to avoid duplicate).
//===----------------------------------------------------------------------===//

void vaked::mlir::VakedDialect::initialize() {
  addOperations<
    #define GET_OP_LIST
    #include "VakedDialect.cpp.inc"
  >();

  addTypes<
    #define GET_TYPEDEF_LIST
    #include "VakedDialectTypes.cpp.inc"
  >();
}
