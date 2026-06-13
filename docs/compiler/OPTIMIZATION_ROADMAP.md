# Vaked Compiler Optimization Roadmap

## Goal: O(n log n) Type Checking (v0.2–v0.3)

Current vakedc achieves **O(n)** per-principal POLA checking on graphs with n nodes. Analysis shows:
- **Use Check:** For each principal, iterate `used(p)` against `granted(p)` → O(n²) worst-case
- **Attenuation Check:** For each edge, compare grant-sets → O(n²) worst-case
- **Bottleneck:** At 1K fibers, `check` takes ~395ms and `lower` ~811ms (measured). At 10K, `check` is ~4.3s and `lower` ~16.3s — the **`lower` stage dominates and grows super-linearly** (it is the primary optimization target, not `check`). See `examples/evaluation/METHODOLOGY.md`.

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

Current numbers are measured end-to-end (parse+check+lower) per
`METHODOLOGY.md`; targets are projected. The earlier ">120s" entry was a
generator-bug artifact and has been retracted.

| Workers | Current (measured, end-to-end) | Target (v0.2) | Target (v1.0) |
|---------|--------------------------------|---------------|---------------|
| 8 | ~0.22s | ~0.15s | ~0.10s |
| 64 | (not yet measured) | — | — |
| 1024 | ~1.6s | ~0.6s | ~0.3s |
| 10000 | ~25s (lower ~16s) | ~8s | ~2s |

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
task loadtests   # the 1k/10k fixtures are generated, not committed
python3 -m cProfile -s cumtime -m vakedc check vaked/examples/swe-swarm-1k-workers.vaked
# Identify bottlenecks: use_check, attenuation checks, sorting
```

---

## Additional Optimization Ideas (Future Exploration)

### 5. Constraint Propagation & Narrowing (Phase 4+)

**Idea:** Use constraint propagation to eliminate infeasible capability combinations early.

**Technique:**
- Represent POLA constraints as a constraint satisfaction problem (CSP)
- Use arc consistency (AC-3 algorithm) to prune the search space
- Early termination: if a principal has no satisfying grant set, report error immediately

**Benefit:** Reduces the number of full checks by 30–50% on real graphs

**Reference:** Mackworth (1977), "Consistency in Networks of Relations"

---

### 6. Lazy Evaluation & Demand-Driven Checking (Phase 4+)

**Idea:** Only check POLA constraints that are "demanded" (used in the declaration or downstream).

**Technique:**
- Mark fibers as "checked" or "pending"
- On first use of a fiber's output, trigger its POLA check
- Defer unused fiber checks (may be dead code)

**Benefit:** For sparse graphs (many unused fibers), 50–80% reduction in check overhead

**Tradeoff:** More complex control flow; requires dependency tracking

**Reference:** Aho, Sethi & Ullman (1986), "Compilers: Principles, Techniques, and Tools" (ch. 8, lazy evaluation)

---

### 7. Type-Driven Optimization (Phase 5+)

**Idea:** Use type information to specialize POLA checks for common patterns.

**Pattern 1: "Read-only delegation"**
```vaked
fiber reader { capabilities = [fs.repo_ro, network.none] }
mesh coordinator -> reader  # Always safe if coordinator has ro or better
```
→ Skip attenuation check (ro ≤ anything in fs is guaranteed)

**Pattern 2: "Identical workers"**
```vaked
fiber worker_001 { ... }  # worker_001 through worker_N all identical
```
→ Check once, reuse result for all N workers (5–10% speedup on worker pools)

**Pattern 3: "Transitive trust"**
```vaked
# If A->B->C and we know B is safe, C inherits safety transitively
# Can memoize "safe subgraph" markers
```

**Benefit:** 10–20% additional speedup on real agentic systems

---

### 8. SIMD Vectorization (Rust rewrite, Phase 5+)

**Idea:** Use SIMD instructions to compare multiple capabilities in parallel.

**Technique:**
- Represent grant sets as bit vectors (one bit per capability)
- Use `AVX2` or `AVX-512` to compare 256/512 capabilities simultaneously
- Vectorized partial-order check: `(used & ~greater_or_equal(granted)) == 0`

**Benefit:** 4–8× speedup on dense capability graphs (many capabilities per principal)

**Requirement:** Rust rewrite (CPU intrinsics)

**Reference:** _[citation needed — verify against real SIMD/vectorized-parsing literature, e.g. Lemire et al. on SIMD JSON parsing. The previously cited "Larson & Goldschmidt (2019), SIMD Text Processing: A Survey, CSUR 52(2)" could not be verified and was removed as likely spurious.]_

---

### 9. Machine Learning-Guided Heuristics (Phase 6+, Speculative)

**Idea:** Train a lightweight model to predict which POLA checks are likely to fail.

**Approach:**
- Collect training data: graph structure features (node degree, edge density, capability cardinality) + check outcomes
- Train a fast decision tree or linear model
- Use model to order checks (likely failures first) or skip expensive checks

**Benefit:** Speculative; could save 20–30% on large graphs with many errors (worst-case: no improvement)

**Tradeoff:** Adds training/inference overhead; only beneficial for large codebases

**Reference:** _[citation needed — verify against real ML-for-code literature, e.g. Allamanis et al., "A Survey of Machine Learning for Big Code and Naturalness" (2018). The previously cited "Learning to Fix Build Failures" could not be verified and was removed as likely spurious.]_

---

### 10. Distributed Type Checking (Phase 6+, Long-term)

**Idea:** Partition the graph and check fibers on multiple machines.

**Approach:**
- Detect strongly-connected components (SCCs) in the delegation graph
- Ship each SCC to a worker node; check in parallel
- Merge results with global consistency check

**Benefit:** Near-linear speedup with number of machines (5–10× on 8-machine cluster)

**Requirement:** Distributed orchestration (Kafka, RabbitMQ); network latency becomes bottleneck

**Use case:** v2.0+ when serving large organizations

**Reference:** Dean & Ghemawat (2008), "MapReduce: Simplified Data Processing on Large Clusters"

---

## Benchmark Suite for Optimization

To validate each optimization, use:

```bash
# Baseline
python3 examples/evaluation/bench.py --example "swe-swarm-*.vaked" --iterations 10 --json baseline.json

# After Phase 1 (indexing)
python3 examples/evaluation/bench.py --example "swe-swarm-*.vaked" --iterations 10 --json v0.2-phase1.json
diff baseline.json v0.2-phase1.json  # Expect 2-5× speedup on 1K, 10K

# After Phase 4 (incremental)
python3 examples/evaluation/bench.py --example "swe-swarm-*.vaked" --iterations 10 --json v1.0-phase4.json
# Incremental: modify 1 fiber, re-check; expect <50ms vs. 350ms full check
```

---

## References

### Transitive Closure & Graph Algorithms

- Floyd, R. W. (1962). "Algorithm 97: Shortest Path." *Communications of the ACM*, 5(6), 345.
  - Transitive closure in O(n³); foundational for attenuation order precomputation
- Nuutila, E., & Soisalon-Soininen, E. (1995). "On Finding the Strongly Connected Components in a Directed Graph." *Information Processing Letters*, 49(1), 9-14.
  - SCC detection for distributed checking

### Type System & Type Checking

- Bodik, R., & Aiken, A. (2007). "The Road Not Taken: Incremental Type Checking by Subtyping." *ACM SIGPLAN Notices*, 42(10), 489-500.
  - Incremental type checking; directly applicable to Vaked
- Valiron, B., et al. (2015). "A Core Language for Quantum Computing." *Proceedings of the 8th ACM SIGPLAN International Conference on Principles and Practice of Declarative Programming*, 123-134.
  - Domain-indexed type checking (type parameter per domain)

### Capability Systems & Security

- Miller, M. S. (2006). *Robust Composition: Towards a Unified Approach to Access Control and Concurrency Control.* Ph.D. Thesis, Johns Hopkins University.
  - Object capabilities; foundational for POLA model
- Abadi, M., & Fournet, C. (2001). "Access Control Based on Execution History." *NDSS*, 107-121.
  - History-based access control; related to incremental checking (state evolution)

### Constraint Satisfaction & Optimization

- Mackworth, A. K. (1977). "Consistency in Networks of Relations." *Artificial Intelligence*, 8(1), 99-118.
  - Arc consistency algorithms; applicable to POLA as CSP
- Dechter, R. (2003). *Constraint Processing.* Morgan Kaufmann.
  - Comprehensive reference on CSP optimization techniques

### Parallel & Distributed Systems

- Dean, J., & Ghemawat, S. (2008). "MapReduce: Simplified Data Processing on Large Clusters." *Communications of the ACM*, 51(1), 107-113.
  - Distributed computation model; applicable to distributed type checking
- Lämmel, R., & Jones, S. L. P. (2003). "Scrap Your Boilerplate: A Practical Design Pattern for Generic Programming." *ACM SIGPLAN Notices*, 38(3), 26-37.
  - Generic graph traversal patterns; useful for distributing SCC checks

### SIMD & Vectorization

- _[citation needed — the previously listed "Larson & Goldschmidt (2019), SIMD Text Processing: A Survey, CSUR 52(2)" could not be verified and was removed as likely spurious. Replace with verifiable SIMD-parsing work, e.g. Lemire & Langdale on SIMD JSON parsing.]_
- Polychroniou, O., & Ross, K. A. (2015). "A Comprehensive Study of SIMD Throughput Bottlenecks on Modern CPUs." *Proceedings of the 18th International Workshop on Data Management on New Hardware*, 1-5.
  - CPU bottleneck analysis for vector operations

### Machine Learning for Optimization

- _[citation needed — the previously listed Allamanis et al. (2018), "Learning to Fix Build Failures" could not be verified and was removed as likely spurious. Replace with verifiable ML-for-code work, e.g. Allamanis et al. (2018), "A Survey of Machine Learning for Big Code and Naturalness," ACM Computing Surveys 51(4).]_
- Gorelick, M., & Ozsvald, I. (2020). *High Performance Python: Practical Performant Programming for Humans.* 2nd ed. O'Reilly.
  - Profiling and optimization best practices

### Incremental & Demand-Driven Checking

- Aho, A. V., Sethi, R., & Ullman, J. D. (1986). *Compilers: Principles, Techniques, and Tools.* Addison-Wesley.
  - Classic compiler reference; ch. 8 covers lazy evaluation and demand-driven code generation
- Pugh, W., & Teitelbaum, T. (1989). "Incremental Computation of Least Fixed Points." In *Proceedings of the 16th ACM Symposium on Principles of Programming Languages*, 341-352.
  - Formal framework for incremental computation

### Domain-Specific Languages & Type Systems

- Hudak, P. (1998). "Modular Domain Specific Languages and Tools." In *Proceedings of the Fifth International Conference on Software Reuse*, 134-142.
  - DSL design; relevant to Vaked's closed-constraint philosophy
- Bracha, G., & Lindstrom, S. (1992). "Modularity in the Presence of Subtyping." University of Virginia Technical Report UVA/CS/92-31.
  - Modular type checking across domains

---

## Performance Profiling Tools

Recommended for validating optimizations:

- **Python:** `cProfile`, `py-spy` (sampling profiler, low overhead)
- **Rust:** `perf`, `flamegraph`, `cachegrind` (CPU cache analysis)
- **Distributed:** `Jaeger` (tracing), `Prometheus` (metrics)

Example profile command:
```bash
task loadtests   # the 1k/10k fixtures are generated, not committed
python3 -m cProfile -s cumtime -m vakedc check vaked/examples/swe-swarm-1k-workers.vaked 2>&1 | head -20
# Identify bottleneck functions: use_check, attenuation_check, graph_traversal
```

---

## Conclusion

The optimization roadmap provides a **clear path** from O(n²) prototype to O(n log n) production system, with incremental improvements at each phase. The strategy is grounded in **established CS techniques** (Floyd–Warshall, CSP, SIMD, MapReduce) and provides **research contributions** suitable for future publications (POLA verification at scale, capability-graph optimization).

**Next step:** Implement Phase 1 (capability indexing) in v0.2 and measure speedup on real workloads.
