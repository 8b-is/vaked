# Lowering fixtures — expected output for `operator-field.vaked`

These are **hand-authored expected-output fixtures**, not compiler output.
**No Vaked compiler exists yet** ([`docs/language/0012-lowering.md`](../../../docs/language/0012-lowering.md)
is the *spec*; this directory is the *spec-by-example*). Each file is what a
correct Goal-3 lowering pass *should* emit when given the validated typed
semantic graph of [`../operator-field.vaked`](../operator-field.vaked).

A reviewer can spot-derive each region from a source declaration: every fixture
carries the §6.1 generated header (in the format's comment syntax) naming the
`<file>:<decl>` it came from, and the mappings match
[`0012-lowering.md`](../../../docs/language/0012-lowering.md) §4–§6.

| Fixture | Spec section | Derived from (decls in `operator-field.vaked`) |
|---------|--------------|------------------------------------------------|
| [`flake.nix`](./flake.nix) | 0012 §4 (Nix spine) | `runtime operator-field` (`systems`), `index zigCorpus` (`emit ∋ nix.derivation`), `index zigbeeFirmware` (`trust = pinned`), `engine zigimg`, `surface operatorMap` |
| [`gen/zig/mediaCompress.json`](./gen/zig/mediaCompress.json) | 0012 §5.2 (Zig daemon config) | `fiber mediaCompress` + linked `stream screenrec` + `engine zigimg` |
| [`gen/catalog/zigCorpus.jsonl`](./gen/catalog/zigCorpus.jsonl) | 0012 §5.3b (JSONL catalog) | `index zigCorpus` (`emit ∋ catalog.jsonl`) — header + chunk rows over its `github(…)` sources |
| [`gen/RUNTIME.md`](./gen/RUNTIME.md) | 0012 §5.1 (generated docs) | the whole `runtime operator-field` (all nested decls) |
| [`provenance.json`](./provenance.json) | 0012 §6.2 (provenance schema) | maps the 4 above artifacts back to their decls (5 artifact paths total) |

> Spans in `provenance.json` (`byteStart`/`byteEnd`/`line`/`col`) are derived
> from the actual byte offsets of each decl in `operator-field.vaked`, consistent
> with 0012 §6.2's Span convention (`byteStart` = the decl's leading keyword;
> `byteEnd` = exclusive, one past the closing `}`; `line`/`col` 1-based) and the
> *shape* of 0011 §6.5 spans.
>
> **Placeholder convention.** Values the *build* (not lowering) would resolve are
> written as **disclosed placeholders**, never invented concrete data:
> - `<commit>`/`<sha256>` in `flake.nix` mirror the placeholder pins in
>   `operator-field.vaked`'s `zigbeeFirmware` decl.
> - `nixpkgs` is emitted **pinned** (0012 §4.1: inputs are pinned, never a moving
>   channel ref) to a clearly-placeholder 40-hex rev,
>   `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb` (all-`b` = "baseline" — stands in
>   for the toolchain's pinned baseline rev). No `flake.lock` fixture is
>   committed: lowering does **not** emit `flake.lock` (0012 §2.3/§4.2) — the lock
>   is produced at first `nix build` and records the full resolution.
> - `inputsHash` values in `provenance.json` are disclosed zero-padded
>   placeholders (`sha256-<label>-000…=`); the label records *what the region was
>   projected from* per 0012 §6.2 (e.g. `packages.zigimg`'s region attributes to
>   `decl = "fiber mediaCompress"` but hashes the resolved `engine-zigimg`
>   inputs — same decl, different projection).
> - `gen/catalog/zigCorpus.jsonl` rows are plausible placeholder chunk rows in
>   CrabCC's default (unschematized) record shape (0012 §5.3b), one referencing
>   each of two `zigCorpus` `github(…)` sources; the real rows are produced by
>   the CrabCC index derivation at build time.
>
> **Attribution note.** `operator-field.vaked` references `engine = zigimg` and
> `output = artifacts.compressedMedia`, but declares no in-file `engine zigimg`
> or `artifacts.compressedMedia` — these resolve to an imported/built-in engine
> value and a built-in artifact target (a Goal-2 *resolve* concern, 0011 §6.1,
> not a lowering one). The fixtures therefore attribute the `packages.zigimg`
> output and the Zig config's `engine` field to the **`fiber mediaCompress`**
> decl that references them (the load-bearing source decl present in the file).
> `engine_package` is the flake *attribute name* `packages.zigimg`, not a
> computed store path — Nix resolves the path at build time (0012 §2.3/§2.4).

These fixtures are reviewed by hand against the EBNF and 0012 until a parser +
lowering pass exist (per the `vaked-language-author` convention: no compiler yet,
so review by hand).
