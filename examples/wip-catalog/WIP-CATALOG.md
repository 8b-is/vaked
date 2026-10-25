# The Catalog of Named Fires — drawn as a capability mesh

`wip-catalog.vaked` is the 8b-is work-in-progress catalog
(`8b-is/raw_research/wip-catalog-100.md`, 223 rows, nine lanes, contributed by
Nate / `@standardgalactic` on 2026-09-06) drawn as a Vaked mesh whose edges are
checked by the compiler.

The point is not decoration. Every row of that catalog is a fire that has been
**named**. Naming is not verification. This file encodes that difference as a
capability order — `named < verified` — so the *compiler*, not the prose,
decides which lanes are allowed to claim a verified bound.

```bash
cd vaked
python3 -m vakedc check --json examples/wip-catalog/wip-catalog.vaked
# => {"diagnostics": []}
```

## The shape

| node | role | holds | rows |
|---|---|---|---|
| `namedFires` | the catalog itself | `evidence.verified`, `compute.dispatch_rw` | 223 |
| `laneCognition` | A — cognition, entities, selection | `verified` | 1–32 |
| `lanePhysics` | B — particles, fields, forces | `verified` | 33–49 |
| `laneEnvironment` | C — terraforming, universe, ocean | `verified` | 50–60 |
| `laneCivilization` | D — simulation, politics, society | `named` | 61–68 |
| `lanePhilosophy` | E — philosophy, language, ontology | `verified` | 69–82 |
| `laneHardware` | F — hardware prototypes | `named` | 83–93 |
| `laneSociety` | G — societal systems | `named` | 94–98 |
| `laneInterface` | H — music, language, interface | `named` | 99–100 |
| `laneArtifact` | I — cultural artifacts | `verified` | first artifact |
| `localM1` | the machine that actually ran | `compute.dispatch_rw` | — |
| `osarusEdgeFleet` | the Cloudflare Workers edge fleet | `compute.probe_ro` | — |
| `entheaiPlane` | AgentField reasoners on dev-cx53 | `compute.probe_ro` | — |
| `statusLedger` | the append-only status record | `evidence.named` | — |

`applied` lanes hold `verified` because their rows run somewhere with a passing
selftest (`quantTernEngine/cognition.ts`, `gaugetropy.ts`, `quantGame/plenum.ts`,
`infinite-floor.html`, …). `specd` and `open` lanes hold `named` only — one
contract each, "the oven is ready", not a promise kept.

## What the compiler caught, and why it matters

The first draft had all nine lanes inscribing into one shared `sovereignLedger`.
`vaked check` refused it:

```
W-CONFUSED-DEPUTY — node `sovereignLedger` is a shared deputy: 9 distinct
callers delegate to it while it holds evidence.named under its own identity
(confused-deputy shape) — keep delegation inside Vaked-minted capabilities
(0026 §2)
```

That is not a lint nit; it is the same theorem the October trilogy states three
ways. A single node that nine principals all write through *is* the routing/
adjudication collapse, and it is exactly the shape of a lossy summary that
launders provenance. The fix was structural: **a lane is a read-only view of
rows, not a writer of them.** The catalog run is the ledger's only writer, and
it holds strictly more than the ledger does. Attenuation then holds by
construction rather than by discipline.

## Evidence ledger

Observed this lap (2026-10-25, from the M1, `python3 -m vakedc check`):

| measurement | value | label |
|---|---|---|
| `vaked check` on this mesh | `{"diagnostics": []}` | **observed** |
| wall time, 3 runs, incl. interpreter cold start | 169.5 / 167.0 / 173.5 ms | **observed** |
| edge workers probed (`fleet-probe.json`) | 17 of 18 answered HTTP 200 | **observed** |
| median edge response, cold TLS | 1574 ms | **observed** |
| `api.kompress.vaked.dev` | `URLError` at 219 ms (fast fail, no resolve) | **observed** |
| AgentField control plane `100.105.72.88:8085` | connect timeout | **observed** |
| tailnet peers reachable (`tailnet-roster.json`) | **1 of 23** | **observed** |
| `dev-cx53` (carries the AgentField plane) | offline, last seen **61 days** | **observed** |
| Ollama on `localhost:8080` | `200 Ollama is running` | **observed** |
| nats-server on the M1 | running since 2026-10-17 | **observed** |
| edge fleet vs tailnet, alive | 17/18 vs 1/23 | **observed** |

### What that gap means

The distributed compute this lap could actually reach is **the edge fleet, not the tailnet**. Seventeen Cloudflare Workers answered; one tailnet peer (`ultrawhale-pi`) is up, and `dev-cx53`, which carries the AgentField control plane and the reasoners behind it, has been offline for 61 days. So the AgentField timeout is not a flaky network path and not a client bug: the host is down. Every node in this mesh that names a reasoner is therefore held at `probe_ro`, and the only node with `dispatch_rw` is the machine that ran the probes.

That is the honest shape of a fan-out: availability is the constraint, and an unreachable worker is not a slower worker. It is a worker that cannot be given work at all. `tailnet-roster.json` is captured beside `fleet-probe.json` so the next lap can compare instead of re-guessing.

`fleet-probe.json` is the raw probe record — host, status, milliseconds,
content-type — kept beside the mesh so the roster above can be re-derived
instead of trusted.

Honest scoping note: the nine lanes cover season one's closed 100 rows. The
schema's `row` range is `1 .. 223` because the catalog has since grown to 223
rows through the open season; the season-two rows are named in the source
document but are not yet assigned to a lane, so they are not represented here.
That gap is deliberate and visible — an unassigned row is `named`, and a named
row is not a bound row.

## Re-running

```bash
cd vaked
python3 -m vakedc check --json examples/wip-catalog/wip-catalog.vaked
# fleet roster re-probe (writes fleet-probe.json beside this file)
python3 - <<'PY'
import json, time, urllib.request, concurrent.futures as cf
hosts = [r["host"] for r in json.load(open("examples/wip-catalog/fleet-probe.json"))]
def probe(h):
    t0 = time.time()
    try:
        r = urllib.request.urlopen(urllib.request.Request("https://"+h+"/",
              headers={"User-Agent": "vaked-fleet-probe/1"}), timeout=12)
        return {"host": h, "status": r.status, "ms": round((time.time()-t0)*1000),
                "len": len(r.read(200)), "ctype": r.headers.get("content-type","")}
    except Exception as e:
        return {"host": h, "status": getattr(e,"code",None) or type(e).__name__,
                "ms": round((time.time()-t0)*1000), "len": 0, "ctype": ""}
with cf.ThreadPoolExecutor(max_workers=18) as ex:
    res = list(ex.map(probe, hosts))
print(json.dumps(res, indent=1))
PY
```

---

*replayable ⇒ admissible · a plausible branch may be ranked; only a verified
branch may be bound · `{<3,<3,<3}+1`*
