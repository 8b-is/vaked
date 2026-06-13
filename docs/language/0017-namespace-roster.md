# 0017 — Namespace & daemon-channel roster (closing branch-B)

Status: **design — for review** (2026-06-13) · Series: language design notes ·
Issue [#8](https://github.com/peterlodri-sec/vaked-base/issues/8) · closes the
checker half of [#7](https://github.com/peterlodri-sec/vaked-base/issues/7)

## Spark

The Goal-2 checker resolves references inside a `runtime {}` as a closed world
([0011](./0011-type-system.md) §6.1; `vakedc/check.py:_check_ref_resolution`):
a `<kind>.<name>` ref (`input = stream.transcripts`) must name an in-runtime
declaration of that kind, and a bare ref (`engine = zigDaemon`, a `parallel`'s
`fibers = [f]`) must be in scope. Two reference shapes are **deliberately left
unenforced** — the comment in `check.py` calls them *branch B*:

```python
# len(parts) >= 2 with a non-kind head (`pkgs.x`, `<daemon>.<channel>`,
# `artifacts.x`) is the deferred "branch B" — left unenforced (no roster).
```

Because branch-B refs are never checked, a typo in a package name, an artifact
name, or a daemon channel sails through `check` and only fails (or silently
misbehaves) far downstream. That is the **checker half of #7**: #7's lowering
half — dotted names spliced into Nix attrpath keys — is already fixed
(`lower._nix_attr_key`), but the checker still greenlights a dangling
`engine = pkgs.doesNotExist`.

The blocker named in `check.py` is precise: *"no roster"*. There is no built-in
catalog of the legitimate non-kind namespaces, so the checker cannot tell a real
`pkgs.umami` from a fat-fingered `pkgs.umani`. This note designs that roster.

## What branch-B refs actually are (the raw material)

Every non-kind dotted head used across `vaked/examples/**` and `builtins.vaked`,
grouped by what kind of thing it names:

| Class | Heads (members seen) | How it should resolve |
|-------|----------------------|-----------------------|
| **Capability domain** | `fs` (repo_rw…), `mem`, `process`, `mcp`, `bus`, `storage` | **Already checked** — these are `capability` decls in the registry; `requires_capability` edges and mesh attenuation validate them (`E-CAP-*`). Not branch-B; out of scope here. |
| **Open value-namespace** | `pkgs` (umami…), `nix` (derivation) | Head is a known external namespace; the member set is **unbounded** (you cannot enumerate nixpkgs). Validate the *head*, accept any member. |
| **Daemon channel** | `agentGuardd` (ringbuf), `agentpipe` (transcripts, screenrec), `eventd` (log) | Head is a daemon in the runtime roster; the member is a **channel it exposes** — an *enumerable, closed* set sourced from [`docs/runtime/README.md`](../runtime/README.md) + the daemon designs. |
| **External service / tool** | `crabcc` (markdown, semantic), `github` (issue), `mempalace` (convos) | Known external producers; members are a closed, rosterable set. |
| **In-runtime production (open question)** | `artifacts` (plan, patch, verdict…), `graph` (swe_af, field…) | In `agentfield-swe.vaked` these name things *produced inside the runtime* (a fiber/step output, a sub-graph). They may belong in closed-world resolution (resolve to a declared producer), **not** the external roster. See *Open questions*. |

The takeaway: branch-B is not one bucket. The roster only needs to cover the
**open value-namespaces**, **daemon channels**, and **external services**; the
capability heads are done, and `artifacts`/`graph` may be a closed-world matter.

## Design

### The construct: a built-in `namespace` catalog

Add one built-in kind, `namespace`, declared (like `schema` / `capability`) in
`vaked/schema/builtins.vaked` and loaded through the **existing** registry path
(`check.load_builtins` → `_load_decls_into` → `_Registry`). A namespace is a head
plus either an `open` marker (any member accepted) or an enumerated, closed
`member` set:

```vaked
# Open value-namespaces — head approved, members unbounded.
namespace pkgs { open }            # nixpkgs attrset
namespace nix  { open }            # nix builtins / stdlib

# Daemon channels — head = a roster daemon, members = the channels it exposes
# (closed; sourced from docs/runtime/README.md + the daemon designs).
namespace agentGuardd { member ringbuf }
namespace agentpipe   { member transcripts  member screenrec }
namespace eventd      { member log }

# External services/tools — closed member sets.
namespace crabcc      { member markdown  member semantic }
namespace github      { member issue }
namespace mempalace   { member convos }
```

Why a dedicated kind rather than overloading `capability`: a capability domain is
*authority with an attenuation order* (`grant` + `order`, POLA-checked); a
namespace is *a reference target with a member set*. Same registry mechanism,
different semantics — conflating them would muddy both. `open` already exists in
the grammar (schemas use it), so the only new surface is the `namespace` keyword
and a `member <name>` body statement.

Proposed grammar delta (EBNF sketch, for the implementation step — not yet
landed; `vaked/grammar/vaked-v0-plus.ebnf` is the normative source):

```ebnf
kind        = "runtime" | … | "memory" | "namespace" ;   (* +1: 28 → 29 *)

(* a namespace block is either `open` (any member) or a set of `member`s;
   reuses the existing open_decl, adds one line-terminated member_decl *)
member_decl = "member" ident ;
```

`member_decl` joins the ordered `stmt` alternatives next to `grant_decl` /
`order_decl` (it begins with the reserved leading keyword `member`, so it is a
non-breaking soft-keyword addition, same discipline as the v0.3 type-layer
statements). A `namespace` body is `open_decl` **xor** `{ member_decl }`; mixing
them (an `open` namespace that also enumerates members) is a load-time error.

This keeps the language "small enough to implement and remember" (CLAUDE.md):
**one** new kind, reusing `open` and the builtins-loading path.

### Checker integration

Extend `_Registry` with `namespaces: dict[str, NamespaceSpec]` (head → `{open,
members}`), populate it in `_load_decls_into`, and replace the branch-B no-op in
`_check_ref_resolution` (the `len(parts) >= 2`, non-kind-head arm) with:

```text
head = parts[0]
if head in registry.namespaces:
    ns = registry.namespaces[head]
    if not ns.open and parts[1] not in ns.members:
        emit E-REF-UNRESOLVED  # known namespace, unknown member  → typo
    # open namespace, or member present → accept
elif head is a known capability domain:
    # already handled elsewhere; leave to the capability checker
else:
    emit E-REF-UNRESOLVED      # unknown head → typo / un-rostered namespace
```

Reuse the existing `E-REF-UNRESOLVED` code (it already carries the closed-world
"this ref names nothing" meaning) with a message that distinguishes *unknown
namespace head* from *unknown member of a known namespace*.

### Strictness posture

The point of #8 is to **catch typos**, so the recommended v1 is **strict**: an
unknown head, and an unknown member of a *closed* namespace, are both errors.
That fully closes branch-B. The cost is that every external head a real file uses
must be in the roster — which is exactly the inventory above (already enumerated
from the examples), so the migration is "seed the roster, then green." Open
namespaces (`pkgs`, `nix`) keep their typo-blind spot by necessity — documented,
not a regression.

Alternative (if a hard cutover feels risky): land the roster emitting
`severity: "warning"` for unknown heads first, watch a release, then flip to
error. The grammar + roster are identical either way, so this is a one-line
posture choice, deferred to the owner at review.

### Relationship to the rest

- **#7** — this is its checker half; together with the shipped `_nix_attr_key`
  lowering fix, #7 is fully closed once this lands.
- **Lowering** — unchanged. A rostered `pkgs.umami` still lowers through
  `_nix_attr_key` (quoted single attr key); the roster only gates `check`.
- **0015 trigger vocabulary** — a *future* extension: if `namespace` members
  carry a type (`member issue : Event`), a workflow `on = "github.issue.labeled"`
  could resolve against the roster instead of being a bare string
  ([0015](./0015-workflow.md) open item). Out of scope for v1 — v1 rosters
  names, not types.

## Open questions (owner decisions at review)

1. **`artifacts.*` / `graph.*`: roster or closed-world?** In `agentfield-swe`
   these name in-runtime productions. If they should resolve to a declared
   producer (a fiber/step output, a sub-graph), they belong in
   `_check_ref_resolution`'s closed-world arm, not the external roster — a
   stronger check. Needs a ruling before seeding the roster.
2. **Strictness v1**: hard error on unknown heads immediately, or warn-then-error
   over one release? (See *Strictness posture*.)
3. **Daemon-channel authority**: is the channel set per-daemon **global**
   (every runtime sees `eventd.log`), or does a runtime only get the channels of
   the daemons its declarations actually instantiate? v1 proposes global (the
   roster is built-in and version-pinned, like the schema catalog); a
   runtime-scoped roster is a larger change tied to the daemon designs.
4. **Member types (0015 link)**: defer entirely to a follow-up, or reserve the
   `member <name> : <Type>` syntax now even if v1 ignores the type?

## Plan (after this design is accepted)

Per the repo convention (grammar-first, design → plan → implement; #8 is the
issue of record):

0. *(this note)* design + owner rulings on the open questions.
1. *(grammar-first)* add `namespace` + `member` to
   `vaked/grammar/vaked-v0-plus.ebnf` (kind list 28 → 29; one body statement) and
   a worked example; document the kind in `parallel-types.md` /
   `docs/language/README.md`.
2. *(catalog)* seed `vaked/schema/builtins.vaked` with the rostered namespaces
   from the inventory above.
3. *(checker)* extend `_Registry` + `_load_decls_into` + the branch-B arm of
   `_check_ref_resolution`; add `tests/spec/test_vakedc_check.py` probes
   (known-open accept, known-closed bad-member reject, unknown-head reject) and
   confirm every existing example still checks clean against the seeded roster.

## Verification (of the eventual implementation)

- `tests/spec/run_all.py` stays green; the seeded roster makes every current
  example resolve with **no** new diagnostics (the migration baseline).
- A fixture `engine = pkgs.doesNotExist` (open ns) still passes (member-unbounded,
  documented), but `input = agentGuardd.ringbufff` (closed ns, bad member) and
  `output = nope.thing` (unknown head) each yield exactly one `E-REF-UNRESOLVED`.
- The #7 reproducer (`crabcc-umami.vaked`-style dotted dangling engine) now fails
  `check` instead of reaching `lower`.
