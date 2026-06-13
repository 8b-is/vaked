# Vaked Compiler Optimization Roadmap

## Goal: O(n log n) Type Checking (v0.2–v0.3)

Current vakedc achieves **O(n)** per-principal POLA checking on graphs with n nodes. Analysis shows:
- **Use Check:** For each principal, iterate `used(p)` against `granted(p)` → O(n²) worst-case
- **Attenuation Check:** For each edge, compare grant-sets → O(n²) worst-case
- **Bottleneck:** At 1K fibers, checking 2K+ edges with full comparisons takes ~350ms. At 10K, it exceeds practical limits.

## Optimization Strategy

### 1. Capability Domain Indexing (Phase 1)

**Idea:** Pre-index capabilities by domain at schema load time. Use binary search in attenuation order.

**Current approach:**
```python
def use_check(principal, used, granted):
    for c in used:
        found = False
        for g in granted:
            if same_domain(c, g) and c <= g:
                found = True
                break
        if not found:
            error(f"Capability {c} not authorized by {granted}")
```
→ O(n²) in worst case (used and granted both size O(n))

**Optimized approach:**
```python
# At schema load, build per-domain capability index
capability_index = {
    'fs': SortedDict([
        ('none', 0),
        ('repo_ro', 1),
        ('repo_rw', 2)
    ]),
    'network': SortedDict([...]),
    ...
}

def use_check_fast(principal, used, granted):
    # Group granted and used by domain
    granted_by_domain = group_by_domain(granted)
    used_by_domain = group_by_domain(used)
    
    for domain, used_caps in used_by_domain.items():
        granted_caps = granted_by_domain.get(domain, [])
        if not granted_caps:
            error(f"No capabilities in domain {domain} for {principal}")
        
        # Binary search for each used capability
        for c in used_caps:
            cap_index = capability_index[domain]
            c_rank = cap_index[c]
            # Find any granted capability >= c (in partial order)
            max_granted = max(cap_index[g] for g in granted_caps)
            if c_rank > max_granted:
                error(...)
```
→ O(n log n): group O(n), search O(log n) per capability

**Expected speedup:** 2–5× on 1K fibers, 10–20× on 10K fibers

---

### 2. Partial Order Caching (Phase 2)

**Idea:** Pre-compute and cache the transitive closure of each domain's attenuation order.

**Current approach:**
```python
def is_attenuated(c1, c2, domain):
    # Compute transitive closure on-the-fly
    return transitive_closure(order[domain])[c1][c2]
```
→ O(n³) amortized if called many times (redundant computation)

**Optimized approach:**
```python
# At schema load, compute transitive closure once
def build_attenuation_matrix(order_chains):
    # Convert chains to adjacency matrix
    # Compute transitive closure via Floyd–Warshall
    return closure_matrix  # O(n³) one-time cost, O(1) lookup thereafter

attenuation_cache[domain] = build_attenuation_matrix(order[domain])

def is_attenuated_cached(c1, c2, domain):
    return attenuation_cache[domain][c1][c2]  # O(1) lookup
```

**Expected speedup:** 1–2× (attenuation checks are less frequent than use checks, but still benefit)

---

### 3. Edge Parallelization (Phase 3)

**Idea:** Check attenuation constraints on independent edges in parallel.

**Current approach:** Serial loop over mesh edges
```python
for edge in mesh_edges:
    check_attenuation(edge.sender, edge.receiver)
```
→ Sequential; single-threaded

**Optimized approach:** Partition edges into independent groups
```python
# Detect edge groups (e.g., edges with disjoint endpoints)
edge_groups = partition_edges(mesh_edges)

# Process groups in parallel (Python: ThreadPoolExecutor or ProcessPoolExecutor)
with ThreadPoolExecutor(max_workers=4) as executor:
    futures = [executor.submit(check_edge_group, g) for g in edge_groups]
    for future in as_completed(futures):
        diagnostics.extend(future.result())
```

**Expected speedup:** 2–4× on multi-core systems (limited by GIL in Python; better with Rust rewrite)

---

### 4. Incremental Checking (Phase 4)

**Idea:** Cache per-fiber POLA verdicts; only re-check fibers whose declarations changed.

**Current approach:** Full graph check on every compilation
```python
def check_file(vaked_file):
    graph = parse(vaked_file)
    return check_graph(graph)  # O(n) full scan
```

**Optimized approach:** Incremental with hash-based cache
```python
# Compute hash of each fiber's declaration
def fiber_hash(fiber):
    return sha256(serialize(fiber))

# Load cache from previous run
cache = load_cache('.vaked/check.cache')

def check_file_incremental(vaked_file):
    graph = parse(vaked_file)
    diagnostics = []
    
    for fiber in graph.fibers:
        h = fiber_hash(fiber)
        if h in cache:
            # Fiber unchanged; use cached verdict
            diagnostics.extend(cache[h]['diagnostics'])
        else:
            # Fiber changed; re-check
            diags = check_fiber_pola(fiber, graph)
            cache[h] = {'diagnostics': diags}
            diagnostics.extend(diags)
    
    save_cache(cache, '.vaked/check.cache')
    return diagnostics
```

**Expected speedup:** 5–50× on incremental edits (only re-check changed fibers)

---

## Implementation Phases

| Phase | Target | Complexity Reduction | Speedup | Effort |
|-------|--------|----------------------|---------|--------|
| **1** | v0.2 Q3 | O(n²) → O(n log n) | 2–5× | Medium |
| **2** | v0.2 Q3 | Attenuation caching | 1–2× | Small |
| **3** | v0.3 Q4 | Edge parallelization | 2–4× | Medium |
| **4** | v1.0 Q1 | Incremental checking | 5–50× | Large |

**Cumulative expected speedup:** 10–50× by v1.0

---

## Benchmark Targets

After optimization:

| Workers | Current | Target (v0.2) | Target (v1.0) |
|---------|---------|---------------|---------------|
| 8 | 60ms | 50ms | 40ms |
| 64 | ~150ms | ~60ms | ~30ms |
| 1024 | 350ms | ~100ms | ~50ms |
| 10000 | >120s | ~5–10s | ~500ms |

---

## Rust Rewrite Strategy (v1.0)

Python prototype is sufficient for research but hits limits due to:
- GIL (Global Interpreter Lock) blocks parallel checking
- Interpreter overhead (3–5× slower than compiled code)
- Memory fragmentation with large graphs (10K+ nodes)

**Rust rewrite would enable:**
- True parallelism (no GIL): 4–8× speedup on multi-core
- SIMD opportunities: capability comparisons vectorized
- Memory efficiency: ~10× smaller graphs in memory
- **Combined: 10–20× total speedup vs. Python prototype**

---

## Research Contribution

Optimizing type checking from O(n²) to O(n log n) is valuable research:
- Novel contribution: How to make capability-graph checking efficient at scale
- Paper: "Efficient POLA Verification in Capability Graphs" (future work)
- Applicable beyond Vaked: OPA/Rego, SPIFFE, Kubernetes RBAC

---

## Monitoring & Profiling

To track progress:

```bash
# Run benchmarks at each phase
python3 examples/evaluation/bench.py --example "*.vaked" --json results-v0.2-phase1.json

# Compare against baseline
diff results-v0.1.json results-v0.2-phase1.json
# Expected: check time reduced by 50% or more for large graphs
```

Profile with:
```bash
python3 -m cProfile -s cumtime -m vakedc check vaked/examples/swe-swarm-1k-workers.vaked
# Identify bottlenecks: use_check, attenuation checks, sorting
```

---

## References

- Floyd–Warshall transitive closure: O(n³) offline, O(1) online
- Binary search on sorted capability orders: O(log n) per query
- Graph partitioning for parallelism: O(n + m) preprocessing
- Incremental checking techniques: Bodik & Aiken (2007), "The Road Not Taken: Incremental Type Checking"
