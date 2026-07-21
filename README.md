# vaked

Vaked is a flake-native capability-graph language. You write a declarative
`.vaked` file describing a system's capabilities, and the compiler turns it
into a typed semantic graph, then lowers that graph into real artifacts:
`flake.nix`/NixOS modules, Zig daemon configs, eBPF policy manifests, OTel
config, CrabCC indexes, and docs.

> Vaked declares. Nix materializes. OTP supervises. Zig enforces. eBPF testifies.

## Layout

- `vaked/grammar/` — EBNF grammar (`vaked-v0-plus.ebnf`, v0.3, 29 kinds)
- `vaked/schema/`, `vaked/examples/`, `vaked/designs/` — language schema and example programs
- `vakedc/` — reference compiler (Python, stdlib-only): parse → check → lower
- `vakedz/` — Zig port of the same pipeline, cache-native, mid-port
- `lib/` — shared Zig package (`span`, `diagnostic`, `json`, `cache`, `graph`) vakedz builds on
- `docs/language/` — design docs 0001…0018+
- `docs/compiler/`, `docs/context/` — compiler dev guide, optimization roadmap
- `tests/spec/`, `tests/corpus/` — grammar/lexer/parser/lowering test suite
- `bin/vaked` — CLI: parse, check, lower, lint, bench, audit, grammar, schema, docs

## Quick start

```sh
bin/vaked check examples/whatever.vaked
bin/vaked lower examples/whatever.vaked
```

## Build (Zig port)

```sh
zig build          # builds vakedz
zig build test     # lib tests + vakedz tests
zig build check    # zig fmt --check
```

Or via Nix:

```sh
nix develop
nix build .#vakedz
```

## Scale

Scale-tested to 100k workers @ 273ms avg, deterministic (1M projected).

## Known limitations

Some `docs/language/*.md` RFCs link to sibling subsystems (`protocol/`,
`superpowers/`, `runtime/`) that live in the parent monorepo this language was
extracted from and aren't included here — `tests/spec/test_doc_links.py`
flags these as unresolved; they're expected until those docs are ported or
the links are rewritten. `hcplang` (a separate protocol grammar previously
tested alongside vaked's) was also dropped from the test suite as unrelated.

## License

MIT — see [LICENSE](LICENSE).
