# Vaked type-layer examples (grammar v0.3)

These examples exercise the **Goal-2 type system**: user-defined `schema`s with
the closed constraint set, `capability` taxonomies, and capability attenuation
(POLA). They are all derivable from grammar
[`vaked-v0-plus.ebnf`](../../grammar/vaked-v0-plus.ebnf) v0.3 and checked by the
rules in [`docs/language/0011-type-system.md`](../../../docs/language/0011-type-system.md)
against the built-in catalog
[`vaked/schema/parallel-types.md`](../../schema/parallel-types.md).

| File | Shows |
|------|-------|
| [`schema-constraints.vaked`](./schema-constraints.vaked) | A user `schema` using every closed refinement (`required`, `optional`, `nonempty`, `default`, `oneof`, `>=`/`<=`/`in`, `matches /re/`) and an `open` schema. |
| [`capability-attenuation.vaked`](./capability-attenuation.vaked) | Two `capability` domains (one total order, one branching/partial order) and a `mesh` whose edge delegates a **strictly attenuated** capability. |
| [`conformant.vaked`](./conformant.vaked) | A fragment that **passes** `vaked check`. |
| [`rejected.vaked`](./rejected.vaked) | A fragment that **parses but fails** `vaked check`, annotated with the exact diagnostics. |

## Conformant vs rejected — the checking illustration

The two files declare the *same* `capability fs` and a *same-shaped*
`mesh reviewField` + `stream telemetry`, differing only in the values — so the
contrast isolates what the checker enforces.

### Capability attenuation (0011 §4.4)

```vaked
# conformant.vaked                     # rejected.vaked
node author   { capabilities = [fs.repo_rw] }   node author   { capabilities = [fs.repo_ro] }
node reviewer { capabilities = [fs.repo_ro] }   node reviewer { capabilities = [fs.repo_rw] }
author -> reviewer                              author -> reviewer
```

`fs`'s order is `none < repo_ro < repo_rw < …`. A delegation `author ->
reviewer` requires `granted(reviewer) ⊑ granted(author)` — the receiver may hold
**only ≤** what the sender holds.

- **Conformant:** `repo_ro ≤ repo_rw` ✓ — authority *decreases* along the edge.
- **Rejected:** `repo_rw ≰ repo_ro` ✗ — the receiver would gain authority the
  sender never had ⇒ `E-CAP-ATTENUATION`. This is POLA as a typing rule.

### Closed constraints + closed schemas (0011 §1, §3)

`stream telemetry` conforms to the built-in `stream` schema
(`fps : Int { optional > 0 }`, closed):

- **Conformant:** `fps = 30` satisfies `> 0`; no unknown fields.
- **Rejected:**
  - `fps = 0` violates the range refinement ⇒ `E-CONSTRAINT-RANGE`.
  - `colour = "red"` is not a declared field of the closed `stream` schema ⇒
    `E-CONFORM-UNKNOWN-FIELD` (would be accepted only if `stream` were `open`).

Each diagnostic is source-mapped to the offending token and names the schema,
field, or order edge involved (0011 §6.5). `rejected.vaked` is intentionally
invalid and should be left that way.
