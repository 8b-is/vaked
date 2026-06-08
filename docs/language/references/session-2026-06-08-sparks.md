# Reference sparks — 2026-06-08 session

New reference repos surfaced while scaffolding `vaked-base`. Captured here for the dedicated language/runtime sessions. (Complements [`parallel-reference-pack.md`](parallel-reference-pack.md) and the [reference map](../0003-reference-map.md).)

## Runtime / Zig foundations

- **[mitchellh/libxev](https://github.com/mitchellh/libxev)** — cross-platform, high-performance event loop: non-blocking IO, timers, events; Linux (io_uring or epoll), macOS (kqueue), Wasm+WASI; **Zig and C API**.
  - *Vaked relevance:* the async foundation for the Zig enforcement daemons (`sandboxd`, `agent-guardd`, `eventd`, `mcp-brokerd`). The C API also lets the OTP control plane and any C-FFI surface share one loop model. Strong default for [`docs/runtime`](../runtime/README.md).

## Index / code-intelligence (CrabCC lineage)

- **[justrach/codedb](https://github.com/justrach/codedb)** — Zig code-intelligence server **and MCP toolset** for AI agents: tree, outline, symbol, search, read, edit, deps, snapshot, and remote GitHub repo queries.
  - *Vaked relevance:* directly parallels **CrabCC indexes** and the `index` membrane; an MCP-native indexer is a reference design for how `mcp-brokerd` could expose code-intelligence as brokered tools. Compare/contrast with `crabcc-labs/crabcc` (Rust + SQLite + Tantivy + tree-sitter).

## Native surfaces

- **[tonybanters/oxwm](https://github.com/tonybanters/oxwm)** — a window manager written in **Zig**.
  - *Vaked relevance:* a reference for native, Zig-built operator **surfaces** — compositor/WM-level control of how operator clients are presented. Complements the raylib-zig / zero-native surface sparks.

## Materialization target

- **MirageOS** — see the dedicated design note: [`0010-mirageos-unikernel-surface.md`](../0010-mirageos-unikernel-surface.md).
