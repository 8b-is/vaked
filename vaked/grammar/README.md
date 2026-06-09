# Vaked Grammar — v0.2

The normative grammar for the Vaked capability-graph language lives in
[`vaked-v0-plus.ebnf`](./vaked-v0-plus.ebnf).

## Overview

Vaked v0.2 is a flake-native capability-graph language for declaring
reproducible agentic, native, mesh-aware, parallel systems.  A Vaked file
(`*.vaked`) is a sequence of top-level declarations (`decl`) and imports
(`use`).  Each declaration names a `kind`, an optional typed signature, and a
configuration `block`.

## Notation

The grammar uses an EBNF dialect documented in its header:

| Form | Meaning |
|------|---------|
| `"literal"` | Terminal matched verbatim |
| `{ x }` | Zero or more repetitions |
| `[ x ]` | Optional (zero or one) |
| `x \| y` | Alternation (ordered) |
| `( x )` | Grouping |
| `rule = ... ;` | One production, semicolon-terminated |

Whitespace (space, tab, newline) separates tokens and is otherwise
insignificant.  `#` begins a line comment that runs to end of line and is
discarded by the lexer.

## Key constructs

### Declarations

```
decl = { annotation } kind name [ signature ] block ;
```

`kind` is one of the 22 keywords (`runtime`, `engine`, `index`, `mesh`, …).
`name` is a plain identifier or a quoted string.  The optional `signature` is a
typed parameter list with an optional return type — **parsed and stored in the
AST, but not type-checked in v0.2** (see Goal 2 below).

### Uniform applicative syntax (`app`)

All call-like forms share one rule:

```
app = ref [ "(" [ arg { "," arg } ] ")" ] [ record ] ;
```

A bare dotted path (`crabcc.markdown`) is a ref-only `app`.  A positional call
(`raw.github("owner/repo", "file")`) adds parens.  A named-block constructor
(`zig.build { inherit src }`) appends a record.  All three can combine.

### Graph blocks (`node` / `->`)

Any `block` can contain `node` declarations and `->` edges:

```
node_decl = "node" name block ;
edge      = ref "->" ref { "->" ref } [ ":" string ] ;
```

This makes `mesh` (and any graph-shaped `kind`) expressible without
grammar-level special-casing.

### Inherit

```
inherit_stmt = "inherit" ident { ident } ;
```

Copies named bindings from the enclosing scope into the current record or
block — mirrors Nix `inherit`.

### Annotations

```
annotation = "@" ident [ "(" [ arg { "," arg } ] ")" ] ;
```

Annotations precede the `decl` they decorate.  Their semantics are
compiler-defined per annotation name.

## Type syntax is parsed but not yet checked (Goal 2)

`signature` and `type` syntax are fully parsed and included in the AST.
The v0.2 evaluator does **not** raise type errors.  Type inference and checking
are Goal 2 work, tracked separately.  This means:

- `engine zigDaemon(name: String, src: Path) -> Engine { … }` parses correctly.
- Type mismatches at call sites are silently accepted in v0.2.

## Deferrals

The following features are intentionally absent from v0.2:

### Backpressure rules

The `backpressure { when … reduce … }` sub-language from
[`docs/language/0008-parallel-fibers-indexes-surfaces.md`](../../docs/language/0008-parallel-fibers-indexes-surfaces.md)
requires a conditional/reactive sub-language that is not yet designed.  It is
tracked as a post-v0.2 extension.  `parallel` blocks today accept only
`fibers`, `strategy`, and `supervisor`.

### Deep device / mediaPipeline schemas

`device` and `mediaPipeline` are valid grammar kinds and can be declared with
arbitrary assignment/block bodies.  Their field schemas (driver interface,
codec registry, stage graph) are not yet specified and will be added
incrementally.

## Examples

Minimal per-primitive examples live in
[`../examples/primitives/`](../examples/primitives/):

| File | Primitive |
|------|-----------|
| `index.vaked` | `index` |
| `catalog.vaked` | `catalog` |
| `stream.vaked` | `stream` |
| `fiber.vaked` | `fiber` |
| `surface.vaked` | `surface` |
| `mesh.vaked` | `mesh` (uses `node` + `->`) |
| `device.vaked` | `device` |
| `mediaPipeline.vaked` | `mediaPipeline` |
| `parallel.vaked` | `parallel` |

A complete, real-world example is
[`../examples/operator-field.vaked`](../examples/operator-field.vaked).

## Grammar self-containment

Every nonterminal that appears on a right-hand side is defined in the grammar
file.  Lexical terminals that cannot be written as quoted literals (`letter`,
`digit`, `char`, etc.) are defined using the EBNF `? prose description ?`
convention, consistent with the style used in
[`protocol/hcplang/grammar.ebnf`](../../protocol/hcplang/grammar.ebnf).
`comment` is defined for documentation purposes; it is consumed by the lexer
and does not appear in any parser production's right-hand side.
