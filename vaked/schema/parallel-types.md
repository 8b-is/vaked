# Parallel Types — Built-in Schema & Capability Catalog

**Normative.** This file is the *data* the Vaked type system operates on: one
**schema** per built-in kind, plus the built-in **capability taxonomy**. The
*rules* (structural matching, conformance, the closed constraint set, capability
attenuation, generics, the checking pipeline) are
[`docs/language/0011-type-system.md`](../../docs/language/0011-type-system.md);
the surface syntax is [`../grammar/vaked-v0-plus.ebnf`](../grammar/vaked-v0-plus.ebnf)
(v0.3). The primitives are introduced in
[`docs/language/0008-parallel-fibers-indexes-surfaces.md`](../../docs/language/0008-parallel-fibers-indexes-surfaces.md).

Every schema below is written in the v0.3 `schema` surface syntax (or its
prose-table equivalent) and is **calibrated against the worked examples** in
[`../examples/`](../examples/): every block in `examples/primitives/*.vaked`,
`examples/operator-field.vaked`, and `examples/engines/zig.vaked` conforms to the
schema for its kind. Where an example revealed a field the earlier sketch
omitted, the schema was widened to match real usage (never the reverse); those
cases are flagged **[from examples]**.

Conventions:

- A field with no presence marker is **required** (per 0011 §3.3).
- `optional` / `default` mark optional fields.
- A schema is **closed** unless it declares `open`. Closed ⇒ unknown fields are
  rejected. Two built-in kinds are `open` for forward-compatibility (`device`,
  `mediaPipeline`), as noted; the rest are closed.
- Type names (`Index<T>`, `Stream<T>`, `ArtifactTarget`, `Capability`, …) are the
  domain/auxiliary types of 0011 §2.

---

## Domain types (type-level signatures)

```text
Index<T>          Catalog<T>        Stream<T>
Fiber<I, O>       Surface           Mesh<Node, Edge>
Device            MediaPipeline     ParallelGroup
Engine            Capability        Schema<T>
Runtime           Memory<T>         Workflow
```

## Auxiliary (built-in) types referenced by the schemas

| Type | Inhabitants (built-in values / shape) |
|------|----------------------------------------|
| `Source` | `github("owner/repo")`, `raw.github("owner/repo", "file")`, `<daemon>.<channel>` ref (e.g. `agentGuardd.ringbuf`, `agentpipe.screenrec`), `device.<name>` ref |
| `Bind` | `loopback(port : Int)` (= `127.0.0.1:port`), `loopback(hostPort : Int, containerPort : Int)` (OCI host:container), `bind(addr : String, port : Int)` — a host:port binding (#3) |
| `Secret` / `SecretRef` | a `secret.<name>.path` ref → `config.sops.secrets."<name>".path` (#2) |
| `HostResource` | a `hostResource.<name>.dsn` ref → the NixOS-computed connection URL, e.g. `postgresql:///<name>?host=/run/postgresql` (#5) |
| `ArtifactTarget` | `catalog.jsonl`, `catalog.sqlite`, `nix.derivation`, `sqlite("./path.db")` |
| `Normalizer` | `crabcc.markdown`, `crabcc.semantic { … }`, other `crabcc.*` refs |
| `TrustPolicy` | `pinned { commit : String, sha256 : String }` |
| `SurfaceMode` | `raylib` (extensible enum of built-in surface backends) |
| `Supervisor` | `otp` (extensible enum of built-in supervisors) |
| `Strategy` | `String` — currently `"supervised-dag"` and other documented strategy tags |
| `View` | `String` — a named surface view (`"network-flows"`, …) |
| `DriverRef` | a `ref`/app to a driver (`usb.cdc_acm`, `device.framebuffer`) |
| `Stage` | an app-with-record stage (`resize { … }`, `encode { … }`) |
| `Schema<T>` | a `ref` to a `schema` declaration (`schema.zigbeeOta`) |
| `Capability` | `domain.grant` ref (§ Capability taxonomy) |
| `RunClass` | a `ref` to a `runclass` declaration (`runclass.interactive`) — the scheduling class a fiber/step runs under |
| `MeshNode` | a `<mesh>.<node>` ref to a declared mesh node (`field.coder`) — the executing agent of a workflow step |
| `Budget` | a `ref` to a `budget` decl, or a budget record |
| `Policy` | a structural record (per-kind, e.g. the `fiber` policy block) |

These auxiliary types are *built-in vocabulary*; they are enumerated here so the
checker can resolve the refs the examples use (0011 §2.3). Marked-extensible
enums admit further built-in values without a schema change.

---

## Schema: `runtime`

A `runtime` is the top-level system container. It carries system targets and may
**nest** other declarations (indexes, streams, fibers, surfaces, parallels) in
its block; nested decls are checked as their own kinds.

```vaked
schema runtime {
  field systems : List<String> { nonempty }   # [from examples] e.g. ["x86_64-linux","aarch64-linux"]
  # Nested declarations (index/stream/fiber/surface/parallel/…) are permitted in
  # the block and checked under their own schemas; they are not "fields".
}
```

- `systems` is the Nix-style system-double list. Conforms to
  `operator-field.vaked` (`systems = ["x86_64-linux", "aarch64-linux"]`).
- Nesting is a structural property of the block, handled by elaboration (0011
  §6.1), not a record field — so `runtime` stays closed w.r.t. *fields* while
  freely containing sub-declarations.

---

## Schema: `engine`

An `engine` builds a native artifact. Engines are typically generic via a
`signature` (0011 §5.2), e.g. `engine zigDaemon(name : String, src : Path) ->
Engine`.

```vaked
schema engine {
  field package  : Derivation                      # the built package, e.g. zig.build { … }
  field optimize : String { optional               # [from examples] inside zig.build record
                            oneof ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"] }
  # check("name", "cmd") app-statements are permitted in the block (smoke checks).
}
```

- Conforms to `engines/zig.vaked`: `package = zig.build { inherit src; optimize
  = "ReleaseSafe" }` and the `check("smoke", "…")` statement. `optimize` lives in
  the `zig.build` record (a `Derivation`-producing builder); the schema lists it
  for documentation of the accepted optimize tags.
- `Derivation` is the Nix-derivation auxiliary type (a built-in builder result).

---

## Schema: `index`

`Index<T>` — a reproducible source of structured/semi-structured content.

```vaked
schema index {
  field source    : Source | List<Source> { nonempty }
  field schema    : Schema<T>   { optional }     # item schema; binds T
  field normalize : Normalizer  { optional }
  field chunk     : Normalizer  { optional }     # [from examples] crabcc.semantic { max_tokens, overlap }
  field trust     : TrustPolicy { optional }     # pinned { commit, sha256 }
  field emit      : List<ArtifactTarget> { optional nonempty }
}
```

- Conforms to both `index` blocks in `examples/primitives/index.vaked` and
  `operator-field.vaked`:
  - `zigRefs`: `source` (list of `github(...)`), `normalize = crabcc.markdown`,
    `chunk = crabcc.semantic { max_tokens = 1200, overlap = 120 }`, `emit =
    [catalog.jsonl, catalog.sqlite, nix.derivation]`.
  - `zigbeeFirmware`: `source = raw.github(…)`, `schema = schema.zigbeeOta`,
    `trust = pinned { commit, sha256 }`.
- `source` is a union `Source | List<Source>` so both the single-source and
  multi-source forms type-check. **[from examples]** `chunk` was not in the
  original sketch; added to match `index.vaked`.
- `chunk`'s record (`max_tokens : Int`, `overlap : Int`) is the
  `crabcc.semantic` builder's argument schema, checked structurally.
- `T` (the item type) is bound by `schema` when present (0011 §5.1) and flows to
  any `catalog` built `from` this index.

---

## Schema: `catalog`

`Catalog<T>` — a queryable materialization of an index.

```vaked
schema catalog {
  field from : Index<T>             # binds T; must equal source index's T
  field key  : List<String> { optional nonempty }
  field emit : ArtifactTarget | List<ArtifactTarget>
}
```

- Conforms to `examples/primitives/catalog.vaked`: `from = index.zigbeeFirmware`,
  `key = ["manufacturer", "image_type", "file_version"]`, `emit =
  sqlite("./var/firmware.db")`.
- `emit` is `ArtifactTarget | List<ArtifactTarget>` to accept both the single
  (`sqlite(...)`) and list forms.
- Generic consistency: `from : Index<T>` ⇒ this catalog is `Catalog<T>` for the
  **same** `T` (0011 §5.1).

---

## Schema: `stream`

`Stream<T>` — a typed runtime event flow.

```vaked
schema stream {
  field source    : Source              # daemon channel ref, e.g. agentGuardd.ringbuf
  field type      : TypeRef             # event type; binds T (Event.Ebpf, Media.Frame)
  field retention : Duration { optional }   # 24h  — accepts duration literal or "24h" string
  field fps       : Int      { optional > 0 }   # [from examples] screenrec fps = 10
}
```

- Conforms to both `stream` blocks: `ebpfEvents` (`source = agentGuardd.ringbuf`,
  `type = Event.Ebpf`, `retention = 24h`) and `screenrec` (`source =
  agentpipe.screenrec`, `type = Media.Frame`, `fps = 10`). Also matches
  `operator-field.vaked`.
- `type` is a `TypeRef` (a dotted ref naming the event type); it binds the
  stream's `T`. `retention` accepts the `duration` literal `24h` (0008 sketch
  used `"24h"` — both forms are accepted per 0011 §2.1).
- **[from examples]** `fps` was not in the original Stream sketch; added because
  `screenrec` carries it.

---

## Schema: `fiber`

`Fiber<I, O>` — a policy-bound execution lane with typed input and output.

```vaked
schema fiber {
  field engine  : Engine                  # ref to an engine
  field input   : I                        # typically a Stream<I> ref
  field output  : O                        # an artifact / target ref
  field policy  : Policy  { optional }     # structural record (see below)
  field budget  : Budget  { optional }
  field runclass : RunClass { optional }   # scheduling class (#28)
  field observe : Bool    { optional default = false }
}
```

The `policy` record schema (nested, **[from examples]** from `fiber.vaked`):

```vaked
schema fiberPolicy {           # the shape of a fiber's `policy { … }` block
  field strip_metadata : Bool          { optional }
  field max_pixels     : String        { optional }   # e.g. "4K"
  field formats        : List<String>  { optional nonempty }
  open                                                # forward-compatible policy keys
}
```

- Conforms to `examples/primitives/fiber.vaked` and `operator-field.vaked`:
  `engine = zigimg`, `input = stream.screenrec`, `output =
  artifacts.compressedMedia`, `policy { strip_metadata = true; max_pixels =
  "4K"; formats = ["png", "webp"] }`.
- `budget` and `observe` come from the original `parallel-types` sketch; they are
  optional and absent in the examples (so the examples still conform). `policy`
  is `open` so additional policy keys do not break checking while the policy
  vocabulary stabilizes.
- Generic flow: `input` binds `I` (from the source stream's `T`), `output` binds
  `O` (0011 §5.1).

---

## Schema: `surface`

`Surface` — an operator-facing view or control shell.

```vaked
schema surface {
  field mode   : SurfaceMode                              # raylib (extensible)
  field fps    : Int { optional > 0 }
  field input  : List<Stream<_> | Graph | Catalog<_>> { nonempty }
  field views  : List<View> { nonempty }
  field budget : Budget { optional }
}
```

- Conforms to `examples/primitives/surface.vaked` and `operator-field.vaked`:
  `mode = raylib`, `fps = 60`, `input = [stream.ebpfEvents, graph.workflow,
  graph.agentfield]`, `views = ["network-flows", …]`.
- `input` elements are a union of `Stream<_>`, `Graph` (a graph ref like
  `graph.workflow`), and `Catalog<_>`. `_` is an anonymous parameter position
  (any item type accepted; surfaces do not constrain it). `Graph` is the
  auxiliary type for graph refs (`graph.workflow`, `graph.agentfield`).
- `budget` is from the sketch; optional, absent in examples.

---

## Schema: `mesh`

`Mesh<Node, Edge>` — agent/process/tool/device topology. A mesh's block is a
**graph block** (0008): `node` declarations and `->` edges, not record fields.

Node record schema (the body of each `node`):

```vaked
schema meshNode {                 # shape of a `node <name> { … }` body
  field role         : String { nonempty }
  field capabilities : List<Capability> { optional nonempty }
  open                            # nodes may carry additional descriptive keys
}
```

Edges:

- `a -> b` and `a -> b -> c` chains, with an optional `: "label"` (grammar
  `edge`). Edges marked as **delegations** carry authority and are subject to the
  attenuation check (0011 §4.4); a labelled edge (`mcpBroker -> eventd :
  "audit"`) records the label for source-mapping.

- Conforms to `examples/primitives/mesh.vaked`: nodes `codex`
  (`capabilities = [fs.repo_rw, mcp.github_read]`) and `redteam`
  (`capabilities = [fs.repo_ro, network.none]`), and the edges `codex ->
  mcpBroker`, `redteam -> eventd`, `mcpBroker -> eventd : "audit"`.
- `Node`/`Edge` type parameters are `meshNode` and the edge record respectively.
  `meshNode` is `open` so role-specific node keys are allowed.

---

## Schema: `device`

`Device` — a hardware/driver node. **Open** schema (driver vocabularies vary).

```vaked
schema device {
  field driver      : DriverRef                          # usb.cdc_acm
  field mount       : Path                               # "/dev/ttyUSB0" (string-as-path, 0011 §2.5)
  field permissions : List<String> { nonempty
                        }                                  # subset of ["read","write","mmap",…]
  field observe     : Bool { optional default = false }
  open                                                    # deep driver schema TBD (0008 / grammar README)
}
```

- Conforms to `examples/primitives/device.vaked`: `driver = usb.cdc_acm`,
  `mount = "/dev/ttyUSB0"`, `permissions = ["read", "write"]`, `observe = true`.
- `mount` is `Path`; the quoted form is accepted per 0011 §2.5. `device` is
  `open` because its full driver-interface schema is deferred (consistent with
  the grammar README's "deep device/mediaPipeline schemas" deferral).

---

## Schema: `mediaPipeline`

`MediaPipeline` — a source → stages → sink media graph. **Open** (codec/stage
vocabularies vary).

```vaked
schema mediaPipeline {
  field source : Source                     # device.framebuffer
  field stages : List<Stage> { nonempty }    # [ resize { … }, encode { … } ]
  field sink   : Stream<_> | Source          # stream.screenrec
  open                                       # deep stage/codec schema TBD
}
```

Stage record schemas (nested, **[from examples]** from `mediaPipeline.vaked`):

```vaked
schema stageResize {
  field width  : Int { > 0 }
  field height : Int { > 0 }
}
schema stageEncode {
  field codec   : String { nonempty }     # "h264"
  field bitrate : Int    { > 0 }          # 2000000
}
```

- Conforms to `examples/primitives/mediaPipeline.vaked`: `source =
  device.framebuffer`, `stages = [resize { width=1920, height=1080 }, encode {
  codec="h264", bitrate=2000000 }]`, `sink = stream.screenrec`.
- `Stage` is an app-with-record; the `resize`/`encode` builders carry the stage
  schemas above. `mediaPipeline` is `open` for the same deferral reason as
  `device`.

---

## Schema: `parallel`

`ParallelGroup` — a supervised group of fibers. (Per the grammar README, v0.2/0.3
`parallel` accepts only `fibers`, `strategy`, `supervisor`; `backpressure` is a
deferred post-v0.2 sub-language and is **not** a field here.)

```vaked
schema parallel {
  field fibers     : List<Fiber<_, _>> { nonempty }   # refs to fibers
  field strategy   : Strategy                          # "supervised-dag"
  field supervisor : Supervisor                        # otp
}
```

- Conforms to `examples/primitives/parallel.vaked` and the `parallel
  "operator-runtime"` block in `operator-field.vaked`: `fibers = [ebpfIngest,
  otaIndex, mediaCompress, operatorMap]`, `strategy = "supervised-dag"`,
  `supervisor = otp`.
- `fibers` elements are `Fiber<_, _>` refs (any in/out types). `parallel` is
  **closed**, enforcing the deferral: a stray `backpressure { … }` would be
  rejected as an unknown field until that sub-language lands.

---

## Schema: `workflow`

`Workflow` — a typed **agent-step DAG** (#27,
[`docs/language/0015-workflow.md`](../../docs/language/0015-workflow.md)): the
swe_af pattern (plan → code → review → publish). Graph-shaped like `mesh`:
steps are `node` decls, ordering is `->` edges. The semantic split that keeps
both kinds honest: **mesh edges delegate authority** (attenuation-checked,
0011 §4.4); **workflow edges order steps** (DAG-checked). Agents are declared
once in the mesh; steps *reference* them. **Closed** record.

```vaked
schema workflow {
  field on       : String { optional nonempty }   # trigger selector, e.g. "github.issue.labeled:agent"
  field budget   : Budget { optional }
  field maxDepth : Int    { optional > 0 }        # declared critical-path bound
}
```

Step record schema (the body of each `node`, like `meshNode` for `mesh`):

```vaked
schema workflowStep {
  field agent   : MeshNode                # executing agent: a mesh node ref
  field input   : I      { optional }     # consumed artifact/stream ref
  field output  : O      { optional }     # produced artifact ref
  field budget  : Budget { optional }
  field runclass : RunClass { optional }     # scheduling class (#28)
  field retries : Int    { optional >= 0 }   # bounded revision loop (NOT a back-edge)
  open                                    # step vocabularies grow with the roster
}
```

Checking (0015; Stage-0 Pass 1 of the topology pipeline,
[`0013-mlir-topology-compilation.md`](../../docs/language/0013-mlir-topology-compilation.md)):

- Each step body conforms to `workflowStep` (a step without an `agent` is
  `E-CONFORM-MISSING-FIELD`).
- The step edges must form a **DAG** — a cycle is `E-WORKFLOW-CYCLE`. Revision
  loops are `retries` on a step; a bounded-loop edge surface is deferred.
- With `maxDepth` declared, the longest step chain (counted in steps) must not
  exceed it — `E-WORKFLOW-DEPTH`. This is the O(depth) propagation-latency
  bound enforced at check time.

Conforms to `examples/agentfield-swe.vaked` (`workflow swe_af`: four steps,
`plan -> code -> review -> publish`, depth 4 ≤ `maxDepth = 6`).

---

## Schema: `budget`

`Budget` — resource bounds a fiber/surface/workflow (step) runs under (#28,
first slice), enforced by the runtime plane (`mcp-brokerd` is specced as
"policy, budgets, approvals"; `fs-snapshotd` carries write budgets). Referenced
by the `Budget` auxiliary type (`fiber.budget`, `surface.budget`,
`workflow.budget`, `workflowStep.budget`). All fields optional — a budget
constrains only what it names. **Closed.**

```vaked
schema budget {
  field tokens    : Int      { optional > 0 }     # model-token ceiling
  field wallClock : Duration { optional }         # 2h
  field toolCalls : Int      { optional > 0 }     # brokered MCP call ceiling
  field approvals : String   { optional oneof ["never", "destructive", "always"] }
}
```

- Conforms to `examples/agentfield-swe.vaked` (`budget swe { tokens = 2000000
  wallClock = 2h toolCalls = 400 approvals = "destructive" }`, referenced as
  `budget = budget.swe`).
- `approvals` gates the broker: `"never"` (fully autonomous), `"destructive"`
  (approval on destructive calls only), `"always"`.
- `runclass` and the remaining schema-less kinds stay open under #28.

---

## Schema: `runclass`

`RunClass` — the scheduling class a fiber / workflow step runs under (#28,
second slice). `priority` is the intended worker process priority (the
`process_flag` mapping is follow-up); `interval` is
the worker's tick baseline (the RFC 0005 `slow` verb overrides it live);
`maxRestarts`/`window` feed supervisor restart intensity. Referenced via the
`RunClass` auxiliary type (`runclass = runclass.interactive`). Lowering wiring into the
`otp.supervision` lowering (worker args + SupFlags) is a follow-up tracked
on #28.
**Closed.**

```vaked
schema runclass {
  field priority    : String   { optional oneof ["low", "normal", "high"] default = "normal" }
  field interval    : Duration { optional }     # tick baseline, e.g. 5s
  field maxRestarts : Int      { optional >= 0 }
  field window      : Duration { optional }     # restart-intensity window
}
```

- Conforms to `examples/agentfield-swe.vaked` (`runclass interactive {
  priority = "high"  interval = 5s }`, referenced from the `transcriptMiner`
  fiber).
- The remaining schema-less kinds (`input`, `network`, `filesystem`, `mcp`,
  `ebpf`, `observability`) stay open under #28's audit: each gets a schema or
  a removal decision (`host` got its schema in slice 3, below).

---

## Schema: `host`

`Host` — a deployment target the runtime's `nixosModules` bind to (#28, third
slice). Thin on purpose: richer host modeling (hardware, membranes) arrives
with the daemon designs; binding `nixosModules.<runtime>` to a host decl is
the `colmena.hive` emitter (#51): each host lowers to a colmena node
(`deployment.targetHost` from `deploy`, `nixpkgs.system` from `system`).
**Closed.**

```vaked
schema host {
  field system : String { nonempty }            # nix system double
  field deploy : String { optional nonempty }   # "ssh://root@vps" | "local"
}
```

- Conforms to `examples/agentfield-swe.vaked` (`host vps { system =
  "x86_64-linux"  deploy = "ssh://root@vps" }`).
- `deploy`'s format ("ssh://…" | "local") is documentation until the lowering
  follow-up enforces it; a `host.system` ∈ enclosing `runtime.systems`
  membership check is a follow-up checker rule tracked on #28.
- Audit state (#28): `input` has a removal decision issue (#48); `network` /
  `filesystem` / `mcp` / `ebpf` / `observability` get schemas with their
  daemons' policy formats.

---

## Schema: `service`

`Service` — a long-running nixpkgs-packaged NixOS systemd service (#1), e.g.
umami/forgejo/mastodon. Distinct from `fiber` (a Zig execution lane needing an
engine + input stream): a service wraps a nixpkgs `package` and an option set.
Lowers to `services.<name> = { enable = true; package = …; … }`.

```vaked
schema service {
  field package  : Derivation                  # pkgs.umami
  field bind     : Bind          { optional }   # loopback(3003) → HOSTNAME/PORT
  field options  : Record        { optional }   # NixOS option set, forwarded verbatim
  field secrets  : List<Secret>  { optional nonempty }   # secret.X refs consumed
  field database : HostResource  { optional }   # hostResource.X dependency
  field user     : String        { optional }
  field stateDir : Path          { optional }
  field after    : List<String>  { optional nonempty }
}
```

- `bind` is a `Bind` (#3); it lowers to the service's `HOSTNAME`/`PORT` options.
- `secrets` are `secret.X` refs (#2); `database` is a `hostResource.X` ref (#5).
  Their `.path`/`.dsn` accessors (used inside `options`) are resolved by the
  closed-world checker (0011 §6.1).
- `options` is an open verbatim record forwarded to `services.<name>`.

---

## Schema: `secret`

`Secret` — a sops-managed runtime secret (#2). Decrypted at activation to
`/run/secrets/<name>`. Exposes the auxiliary ref `secret.<decl>.path` (→
`config.sops.secrets."<name>".path`) that `service`/`container` consume; lowers a
`sops.secrets."<name>"` entry into the NixOS module.

```vaked
schema secret {
  field provider : String { oneof ["sops", "age", "vault"] default = "sops" }
  field name     : String { nonempty }                  # sops.secrets key name
  field owner    : String { optional }                  # owning systemd unit
  field mode     : String { optional matches /0[0-7]{3}/ }   # octal file mode, e.g. "0400"
}
```

- The ref middle segment is the **decl name** (`secret umamiAppSecret` →
  `secret.umamiAppSecret.path`); the Nix key is the **`name` field**
  (`"umami_app_secret"`). Only `sops` lowers today.

---

## Schema: `hostResource`

`HostResource` — a dependency on a host-managed resource (#5): the box's shared
PostgreSQL/MySQL/Redis, reused by several services. Distinct from `index` (a
read-only corpus). Exposes `hostResource.<decl>.dsn` (the NixOS-computed
connection URL); provisions the database/user when a `service` consumes it.

```vaked
schema hostResource {
  field kind     : String { nonempty oneof ["postgresql", "mysql", "redis", "other"] }
  field name     : String { nonempty }                  # database / user name
  field create   : Bool   { optional default = true }   # provision DB + user
  field password : String { optional }
}
```

- `hostResource.X.dsn` lowers (postgresql) to `postgresql:///<name>?host=/run/postgresql`.
  `kind` selects the provisioning + DSN template; `create` (default `true`) gates it.

---

## Schema: `ingress`

`Ingress` — a Caddy HTTP reverse-proxy virtual host (#4), **distinct from
`surface`** (raylib operator visualization). An HTTP vhost has a domain, an
upstream address, and an optional TLS policy. Lowers to
`services.caddy.virtualHosts."<domain>".extraConfig`.

```vaked
schema ingress {
  field domain      : String { nonempty }               # "analytics.crabcc.app"
  field upstream    : Bind | String                     # loopback(3003) | "127.0.0.1:3003"
  field tls         : String { optional }               # named TLS policy, e.g. "crabcc_sec"
  field extraConfig : String { optional }               # raw Caddy config (escape hatch)
}
```

- `upstream` is a `Bind` (#3) or a literal `"host:port"`. The snippet is
  `import <tls>` (when present) + `reverse_proxy <upstream>` + raw `extraConfig`.
- **Closed**: the escape hatch is the explicit `extraConfig`, not openness.

---

## Schema: `container`

`Container` — an OCI/Docker container (#6), e.g. the browser-pool roster. Distinct
from `service` (no nixpkgs package — an opaque image) and `fiber` (no Zig engine).
Lowers to `virtualisation.oci-containers.containers.<name>`.

```vaked
schema container {
  field image            : String { nonempty }          # "ghcr.io/browserless/chromium:latest"
  field ports            : List<Bind>      { optional nonempty }   # loopback(3030, 3000)
  field environment      : Record          { optional } # plain env key=value pairs
  field environmentFiles : List<SecretRef> { optional nonempty }   # secret.X.path refs
  field volumes          : List<String>    { optional nonempty }   # "host:container:ro"
  field memory           : Bytes           { optional } # Docker --memory cap
  field network          : String          { optional oneof ["bridge", "host", "none"] }
  field healthCmd        : String          { optional nonempty }
  field extraOptions     : List<String>    { optional nonempty }   # raw Docker flags
}
```

- `ports` are `Bind` host:container mappings (#3); `environmentFiles` are
  `secret.X.path` refs (#2). `memory`/`network`/`healthCmd` synthesize into
  Docker `extraOptions` flags at lowering (no NixOS option maps to them).

---

## Schema: `memory`

`Memory<T>` — a MemPalace-shaped **runtime-accumulated, mined, replayable**
store of typed entries (#24,
[`docs/language/0014-memory-primitive.md`](../../docs/language/0014-memory-primitive.md)).
Distinct from `index` (a build-time read-only corpus), `catalog` (a derived
view of an index), and `stream` (an ephemeral flow): memory entries are
appended at runtime by **mining** `source` streams and recalled under the
`mem` capability domain. Memory state is the fold over the runtime's
`eventd` log, so rewind rewinds memory too. **Closed.**

```vaked
schema memory {
  field source    : Stream<T> | List<Stream<T>> { nonempty }   # what gets mined
  field schema    : Schema<T>    { optional }     # entry schema; binds T
  field mine      : Normalizer   { optional }     # distiller: raw events → entries
  field scope     : String       { optional oneof ["session", "agent", "runtime"] default = "agent" }
  field retention : Duration     { optional }     # entry time-to-live in the fold
  field emit      : List<ArtifactTarget> { optional nonempty }
}
```

- Conforms to `examples/primitives/memory.vaked`: `source =
  stream.agentTranscripts`, `schema = schema.memoryEpisode`, `mine =
  mempalace.convos`, `scope = "agent"`, `retention = 90d`, `emit =
  [catalog.jsonl, catalog.sqlite]`.
- `schema` binds the entry type `T` (0011 §5.1), exactly as `index.schema`
  does; `emit` materializes the **recall side** as ordinary catalog artifacts.
- `scope` partitions the fold: `"session"` (one turn-sequence), `"agent"` (one
  agent across sessions — the default), `"runtime"` (shared across the
  runtime's agents).
- Reading a memory *uses* `mem.recall`; a mining daemon *uses*
  `mem.append` (0011 §4.3 use-gathering; § Domain `mem`).

---

## Schema: `schema` and `capability` (the meta-kinds)

- **`schema <Name> { field … ; [open] }`** — declares a schema. Its body is a
  set of `field_decl`s and an optional `open`. Well-formedness (legal refinement
  on legal field type, valid default/oneof/range/regex) is checked at load (0011
  §3.6, §6.4a). A `schema` may be generic via its `signature`.
- **`capability <domain> { grant … ; order … }`** — declares one capability
  domain (next section). Its body is `grant_decl`s and exactly one `order_decl`.

These two kinds are how users *extend* the type system within its closed bounds:
new schemas and new capability domains, never new constraint forms or new
evaluation.

---

# Built-in capability taxonomy

A capability is `domain.grant` (0011 §4). The six built-in domains below are
**predeclared**; each lists its grants and its attenuation order (`a < b` ⇒ `a`
is the weaker/more-attenuated grant; delegation may only go to `≤`). Each order
is acyclic ⇒ a partial order (0011 §4.2). Users may declare further domains with
the `capability` kind.

### Domain `fs` — filesystem authority

```vaked
capability fs {
  grant none repo_ro repo_rw host_ro host_rw
  order none < repo_ro < repo_rw < host_rw ;
        repo_ro < host_ro < host_rw
}
```

| Grant | Meaning |
|-------|---------|
| `none` | no filesystem access |
| `repo_ro` | read-only within the repository |
| `repo_rw` | read-write within the repository |
| `host_ro` | read-only on the host beyond the repo |
| `host_rw` | read-write on the host |

Order (a partial order, two chains sharing `none`/`repo_ro`/`host_rw`): `none` is
least; `host_rw` is greatest. `repo_rw` and `host_ro` are **incomparable**
(neither dominates the other) — a node with `repo_rw` may not be delegated
`host_ro` and vice-versa. **[from examples]** `fs.repo_ro` and `fs.repo_rw` are
exercised by `mesh.vaked` / `operator-field`'s mesh nodes; `host_*` extend the
lattice upward.

### Domain `network` — network authority

```vaked
capability network {
  grant none loopback lan egress
  order none < loopback < lan < egress
}
```

| Grant | Meaning |
|-------|---------|
| `none` | no network |
| `loopback` | localhost only |
| `lan` | local network |
| `egress` | outbound to the internet |

Total order (a chain) `none < loopback < lan < egress`. **[from examples]**
`network.none` is used by `mesh.vaked`'s `redteam` node.

### Domain `mcp` — MCP broker authority

```vaked
capability mcp {
  grant none github_read github_write broker_admin
  order none < github_read < github_write < broker_admin
}
```

| Grant | Meaning |
|-------|---------|
| `none` | no MCP access |
| `github_read` | read via the GitHub MCP tool |
| `github_write` | read+write via the GitHub MCP tool |
| `broker_admin` | administer the MCP broker |

Total order. **[from examples]** `mcp.github_read` is used by `mesh.vaked`'s
`codex` node.

### Domain `ebpf` — eBPF/observation authority

```vaked
capability ebpf {
  grant none observe attach_ro attach_rw
  order none < observe < attach_ro < attach_rw
}
```

| Grant | Meaning |
|-------|---------|
| `none` | no eBPF |
| `observe` | read eBPF-produced events (e.g. a ringbuf stream) |
| `attach_ro` | attach read-only (tracing) programs |
| `attach_rw` | attach programs that may act (e.g. enforce) |

Total order. Relates to `stream`s whose `source` is an eBPF ringbuf (e.g.
`agentGuardd.ringbuf` in `operator-field`): consuming such a stream *uses*
`ebpf.observe` (0011 §4.3 use-gathering).

### Domain `process` — process/exec authority

```vaked
capability process {
  grant none spawn_sandboxed spawn exec_host
  order none < spawn_sandboxed < spawn < exec_host
}
```

| Grant | Meaning |
|-------|---------|
| `none` | may not start processes |
| `spawn_sandboxed` | spawn inside a sandbox/namespace |
| `spawn` | spawn normal child processes |
| `exec_host` | execute arbitrary host processes |

Total order. An `engine` whose smoke `check(…)` runs a command *uses*
`process.spawn` (or `spawn_sandboxed`), gathered per 0011 §4.3.

### Domain `mem` — runtime-memory authority

```vaked
capability mem {
  grant none recall append admin
  order none < recall < append < admin
}
```

| Grant | Meaning |
|-------|---------|
| `none` | no memory access |
| `recall` | query/read folded memory entries |
| `append` | mine/append new entries (implies recall) |
| `admin` | administer the store (scope, retention, eviction) |

Total order. Authority over the `memory` kind (#24,
[`0014-memory-primitive.md`](../../docs/language/0014-memory-primitive.md)):
a mesh node holding `mem.recall` may read but not write; the mining daemon
holds `mem.append`; only the control plane holds `mem.admin`. The domain is
named `mem` (not `memory`) because a top-level `capability memory` would
collide with `schema memory` in the LPG's kind-agnostic decl ids (#25).

---

## Attenuation examples (cross-link to checking)

- `mesh.vaked`: `codex` holds `[fs.repo_rw, mcp.github_read]`; `redteam` holds
  `[fs.repo_ro, network.none]`. The edge `codex -> mcpBroker` must satisfy
  attenuation against whatever `mcpBroker` holds; a delegation that handed
  `mcpBroker` `fs.host_rw` would be rejected (`E-CAP-ATTENUATION`) since `codex`
  holds no `fs` grant `≥ host_rw`.
- A node delegating `fs.repo_ro` to a receiver that holds `fs.repo_rw` is
  rejected: `repo_rw ≰ repo_ro`. The reverse (deliver `repo_ro` from a `repo_rw`
  holder) is permitted.

A runnable conformant-vs-rejected pair is in
[`../examples/types/`](../examples/types/).
