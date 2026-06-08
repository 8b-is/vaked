# Parallel Reference Pack

This reference pack captures projects that inspired the expanded Vaked language model.

## Native surface references

### raylib-zig

Use as inspiration for fast native operator visualization surfaces.

```vaked
surface operatorMap {
  mode = raylib
  fps = 60
  input = [stream.ebpfEvents, graph.workflow]
}
```

### zero-native

Use as inspiration for Zig-native desktop/mobile shells with web UI frontends.

```vaked
surface desktopShell {
  mode = zero-native
  frontend = "./ui"
  native = zig "operator-shell"
}
```

## Media references

### zigimg

Use as inspiration for native image/media artifact pipelines.

```vaked
mediaPipeline runMedia {
  source = artifacts.screenshots
  process = zigimg {
    formats = ["png", "webp"]
    strip_metadata = true
  }
}
```

## Mesh/device references

### Zigbee

Use Zigbee as a mental model for mesh topology, device capabilities, route recovery, and bounded node communication.

### zigpy

Use as a reference for Zigbee stack semantics and Python ecosystem integration.

### zigbee-OTA

Use as a reference for raw firmware indexes and manifest-driven catalogs.

```vaked
index zigbeeFirmware {
  source = raw.github("Koenkk/zigbee-OTA", "index.json")
  schema = schema.zigbeeOta
}
```

## Zig-native agent infra references

### nullclaw

Use as a signal that Zig-native AI assistant infrastructure is a live design space.

## Zig corpus references

### awesome-zig

Use as a broad corpus source for Zig package/project discovery.

### zig.guide

Use as a curated educational corpus source for Zig learning material.

```vaked
index zigCorpus {
  source = [
    github("Sobeston/zig.guide"),
    github("C-BJ/awesome-zig")
  ]

  normalize = crabcc.markdown
  emit = [catalog.jsonl, catalog.sqlite]
}
```
