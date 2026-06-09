# 0008: Parallel Fibers, Indexes, and Native Surfaces

## Status

Seed draft. The primitives introduced here are implemented in grammar v0.2 —
see [`vaked/grammar/README.md`](../../vaked/grammar/README.md).

## Summary

The language should support more than agents, hosts, and policies. Vaked should describe parallel capability graphs made of indexes, catalogs, streams, fibers, native surfaces, media pipelines, and mesh/device nodes.

This extends the system from:

```text
agent runtime declaration language
```

to:

```text
capability graph language for native parallel systems
```

## New top-level declarations

```text
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

## Concept: index

An `index` is a reproducible source of structured or semi-structured content.

```vaked
index zigRefs {
  source = [
    github("Sobeston/zig.guide"),
    github("C-BJ/awesome-zig"),
    github("raylib-zig/raylib-zig"),
    github("zigimg/zigimg")
  ]

  normalize = crabcc.markdown
  chunk = crabcc.semantic {
    max_tokens = 1200
    overlap = 120
  }

  emit = [catalog.jsonl, catalog.sqlite, nix.derivation]
}
```

```vaked
index zigbeeFirmware {
  source = raw.github("Koenkk/zigbee-OTA", "index.json")
  schema = schema.zigbeeOta
  trust = pinned {
    commit = "<commit>"
    sha256 = "<sha256>"
  }
}
```

## Concept: catalog

A `catalog` is a queryable materialization of an index.

```vaked
catalog firmware {
  from = index.zigbeeFirmware
  key = ["manufacturer", "image_type", "file_version"]
  emit = sqlite "./var/firmware.db"
}
```

## Concept: stream

A `stream` is a typed runtime event flow.

```vaked
stream ebpfEvents {
  source = agentGuardd.ringbuf
  type = Event.Ebpf
  retention = "24h"
}
```

## Concept: fiber

A `fiber` is a policy-bound execution lane with typed inputs and outputs.

It is not necessarily a low-level coroutine. It is a language-level lane for parallel supervised work.

```vaked
fiber mediaCompress {
  engine = zigimg
  input = stream.screenrec
  output = artifacts.compressedMedia

  policy {
    strip_metadata = true
    max_pixels = "4K"
    formats = ["png", "webp"]
  }
}
```

## Concept: surface

A `surface` is an operator-facing view or UI shell.

```vaked
surface operatorMap {
  mode = raylib
  fps = 60

  input = [
    stream.ebpfEvents,
    graph.workflow,
    graph.agentfield
  ]

  views = [
    "network-flows",
    "workflow-dag",
    "filesystem-diff",
    "mesh-topology"
  ]
}
```

## Concept: mesh

A `mesh` models agent, process, tool, or device topology.

```vaked
mesh agentfield {
  node codex {
    role = "worker"
    capabilities = [fs.repo_rw, mcp.github_read]
  }

  node redteam {
    role = "reviewer"
    capabilities = [fs.repo_ro, network.none]
  }

  route codex -> mcpBroker
  route redteam -> eventd
}
```

## Parallel block

```vaked
parallel "operator-runtime" {
  fibers = [
    ebpfIngest,
    otaIndex,
    mediaCompress,
    operatorMap
  ]

  strategy = "supervised-dag"
  supervisor = otp

  backpressure {
    when stream.ebpfEvents.lag > "10s" {
      reduce surface.operatorMap.fps to 15
    }
  }
}
```

## Compiler artifacts

These declarations should be able to emit:

```text
flake.nix
NixOS modules
systemd units
Zig daemon configs
CrabCC index derivations
SQLite/JSONL catalog artifacts
OTel stream mappings
surface launcher configs
policy manifests
generated RUNTIME.md
```

## v0 boundary

v0 should define the graph model and support at least:

- `index`
- `stream`
- `fiber`
- `surface`
- `parallel`

even if some targets are stubs.
