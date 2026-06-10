# Vaked Grammar — v0.3

The normative grammar for the Vaked capability-graph language lives in
[`vaked-v0-plus.ebnf`](./vaked-v0-plus.ebnf).

## Overview

Vaked v0.3 is a flake-native capability-graph language for declaring
reproducible agentic, native, mesh-aware, parallel systems.  A Vaked file
(`*.vaked`) is a sequence of top-level declarations (`decl`) and imports
(`use`).  Each declaration names a `kind`, an optional typed signature, and a
configuration `block`.

v0.3 is a **strict superset of v0.2**: every v0.2 file parses unchanged.  It
adds the *surface syntax* of the Vaked type system (Goal 2) — the form in which
users write **schemas with field constraints** and **capability taxonomies**.
The constraint set is closed and total; there is no expression/predicate
sub-language.  The checker that consumes this syntax (parse → resolve →
elaborate → check, deterministic and side-effect-free) is specified
normatively in
[`docs/language/0011-type-system.md`](../../docs/language/0011-type-system.md);
the built-in schema and capability catalog is
[`../schema/parallel-types.md`](../schema/parallel-types.md).

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

`kind` is one of the 23 keywords (`runtime`, `engine`, `index`, `mesh`,
`schema`, `capability`, …).  `name` is a plain identifier or a quoted string.
The optional `signature` is a typed parameter list with an optional return
type.  In v0.3 the signature is still **parsed and stored in the AST**; the
Goal-2 checker (0011) uses it for arity/return checking of user-defined
generics, but the v0.2 evaluator path remains untyped.

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

## v0.3 additions — the Goal-2 type layer

v0.3 adds two surface forms. Both are reached only via new soft keywords
(`field`, `open`, `grant`, `order`) that do not begin any v0.2 statement, so
the addition is non-breaking. They are syntactically legal in any block but are
*meaningful* only inside `schema` / `capability` declarations; the checker
(0011) rejects them elsewhere.

### Schema field declarations with constraint refinements

A `schema` block declares the record type and constraints of one Vaked kind:

```
field_decl  = "field" ident ":" type [ "{" { refinement } "}" ] ;
open_decl   = "open" ;
refinement  = "required" | "optional" | "nonempty"
            | "default" "=" expr | "oneof" list
            | cmp_ref | range_ref | "matches" regex ;
cmp_ref     = ( ">=" | "<=" | ">" | "<" ) number ;
range_ref   = "in" number ".." number ;
```

The refinement set is **closed and total** — no user-defined predicates, no
expression language beyond the literal `default`/`oneof` values. `field x : T`
is shorthand for `field x : T {}`. A bare `open` statement marks the schema as
accepting unknown fields (default is closed → unknown fields rejected). Example:

```vaked
schema zigbeeOta {
  field manufacturer : String { required nonempty }
  field image_type   : Int    { required in 0 .. 255 }
  field file_version : Int     { required >= 0 }
  field url          : Path    { required matches /^https:\/\// }
  field channel      : String  { default = "stable" oneof ["stable", "beta"] }
}
```

### Capability declarations

A `capability` block declares **one** capability domain. The decl `name` is the
domain; the body lists grants and exactly one attenuation order:

```
grant_decl  = "grant" ident { ident } ;
order_decl  = "order" order_chain { ";" order_chain } ;
order_chain = ident "<" ident { "<" ident } ;
```

`a < b` means *a is the lesser (more attenuated) capability*, so a holder of `b`
may delegate `a` but not vice-versa (POLA; see 0011). Every grant named in an
`order` must be declared. Capability **values** elsewhere keep the existing
`ref` form `domain.grant` (e.g. `fs.repo_rw`) — no new value syntax. Example:

```vaked
capability fs {
  grant none repo_ro repo_rw
  order none < repo_ro < repo_rw
}
```

### Regex literal

`matches` takes a `/.../ ` regex literal (`regex = "/" { regex_char } "/"`). The
body is opaque to the parser and validated by the checker against a fixed,
bounded dialect (anchored, no backreferences; see 0011). It is **not** a Vaked
expression.

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

## Type syntax and the Goal-2 checker

`signature` and `type` syntax are fully parsed and included in the AST. The
**Goal-2 type system** that consumes them — structural conformance, the closed
constraint set, and capability attenuation/flow (POLA) checking — is now
specified normatively in
[`docs/language/0011-type-system.md`](../../docs/language/0011-type-system.md),
with the built-in schema and capability catalog in
[`../schema/parallel-types.md`](../schema/parallel-types.md). The checker is
total and side-effect-free (parse → resolve → elaborate → check); it validates
a file before any lowering (Goal 3). The legacy untyped v0.2 evaluator path
still accepts type mismatches silently; type *checking* is opt-in via `vaked
check`.

## Deferrals

The following features are intentionally absent from v0.3:

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

Type-layer (v0.3) examples — user `schema` with constraints, a `capability`
taxonomy, and an attenuated delegation, plus paired conformant/rejected blocks
— live in [`../examples/types/`](../examples/types/).

## Grammar self-containment

Every nonterminal that appears on a right-hand side is defined in the grammar
file.  Lexical terminals that cannot be written as quoted literals (`letter`,
`digit`, `char`, etc.) are defined using the EBNF `? prose description ?`
convention, consistent with the style used in
[`protocol/hcplang/grammar.ebnf`](../../protocol/hcplang/grammar.ebnf).
`comment` is defined for documentation purposes; it is consumed by the lexer
and does not appear in any parser production's right-hand side.
