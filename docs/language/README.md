# Vaked Language Track

Vaked is a proposed typed, flake-native complement language for Nix.

It began as a way to make flake definitions, engines, and runtime declarations easier to author. It has now expanded into a capability graph language for agentic, native, mesh-aware, parallel systems.

## Current definition

Vaked is a **flake-native capability graph language** for declaring reproducible agentic, native, mesh-aware, parallel systems.

It compiles to:

- ordinary `flake.nix`
- NixOS modules
- Zig daemon configs
- eBPF policy manifests
- MCP broker configs
- OpenTelemetry config
- CrabCC indexes/catalogs
- generated documentation

## Core top-level declarations

```text
runtime
input
system
engine
host
network
filesystem
mcp
ebpf
budget
observability
runclass
workflow
index
catalog
stream
fiber
surface
mesh
device
mediaPipeline
parallel
```

## Golden commands

```bash
vaked fmt
vaked check
vaked emit graph
vaked emit nix
vaked emit docs
vaked explain runtime operator-field
vaked explain fiber mediaCompress
vaked explain index zigbeeFirmware
```
