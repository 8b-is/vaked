//===-- VakedDialect.h - Vaked MLIR dialect declarations ---------*- c++ -*-===//
//
// Defines the vaked dialect classes. The TableGen-generated .inc files
// provide most declarations; this header wraps them for compilation.
//
//===----------------------------------------------------------------------===//

#ifndef VAKED_VAKEDDIALECT_H
#define VAKED_VAKEDDIALECT_H

#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/IR/OpImplementation.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"

// Include the auto-generated dialect and type declarations.
#include "VakedDialect.h.inc"

// Dialect class (matches TableGen's cppNamespace in .td).
namespace vaked::mlir {
class VakedDialect : public ::vaked::mlir::VakedDialectBase {
public:
  using VakedDialectBase::VakedDialectBase;
  void initialize() override;
};
} // namespace vaked::mlir

#endif // VAKED_VAKEDDIALECT_H
