#!/usr/bin/env python3
"""vakedc.lower — the 0012 lowering pass: validated graph -> artifacts.

This module implements `docs/language/0012-lowering.md` (the normative spec). It
turns a *validated* typed semantic graph (the output of :mod:`vakedc.check`) into
the boring, inspectable artifacts Vaked owns plus the Nix spine that wires them,
together with a decl-level provenance manifest.

Purity / totality / hermeticity (0012 §2). Every emitter here is a **pure,
total, hermetic** function of ``(graph, nodes)``:

  * No IO of any kind (no file reads/writes, no sockets, no subprocesses), no
    wall-clock, no randomness, no environment/locale/hostname. The only IO in
    the whole pipeline is the CLI write layer in :mod:`vakedc.__main__`, which
    writes the ``Files`` this module returns. (0012 §2.3, §3.2.1)
  * Deterministic: the same graph yields byte-identical artifacts. All ordering
    is by a stable graph-derived key — declaration source order for top-level
    decls, the fixed structural layout order for the flake spine, lexicographic
    order for the provenance ``artifacts`` map. No hash-map iteration order.
    (0012 §2.1, §3.2.2)
  * No graph mutation, no cross-emitter state, no re-checking. (0012 §3.2.3-.5)

Emitter interface (0012 §3.1)::

    emit : (graph, nodes) -> (files, provenance_entries)
      files               : dict[str path -> str | bytes]   (rooted at the out tree)
      provenance_entries  : list[ProvEntry]                 (one per artifact/region)

Registry + selection (0012 §3.3/§3.4):

  * ``nix.spine`` ALWAYS runs (every runtime lowers to a flake + NixOS module).
  * ``docs.runtime`` runs on presence of the ``runtime`` node (unconditional).
  * Direct emitters are selected by declared ``emit`` targets / fiber presence:
      - a ``fiber`` selects ``zig.daemoncfg`` (a fiber has no ``emit`` field; it
        is selected by presence under the runtime, 0012 §3.4 note);
      - an ``index`` whose ``emit`` contains ``catalog.jsonl`` selects
        ``catalog.jsonl``;
      - an ``index`` whose ``emit`` contains ``nix.derivation`` selects
        ``crabcc.index`` (the derivation lives in the spine, but it contributes
        a distinct provenance entry, 0012 §5.3a).
  * Deferred targets (``ebpf.policy`` / ``otel.config`` / ``systemd.units`` /
    ``surface.launcher``) are inert registry slots that emit nothing (0012 §7).
    The surface launcher still surfaces in the spine as the §7 deferred no-op
    *stub app* (``apps.<system>.<surface>``), derived from nothing but the
    surface decl name.

inputsHash — the per-region projection (0012 §6.2). ``inputsHash`` is
``"sha256-" + sha256(canonical_projection_json).hexdigest()`` where the
*projection* is the emitter's resolved inputs for that region. The canonical
projection JSON is produced by :func:`_canonical_projection_json` (sorted keys,
compact separators, ``ensure_ascii=False``, no trailing newline). Per-region
projection definitions:

  ====================  =============================================================
  Region (provenance)   Projection (what the hash keys — "what the region was
                        projected from", 0012 §6.2)
  ====================  =============================================================
  spine nixosModules    the ``runtime`` node projection (its name + ``systems``).
  spine inputs.<idx>    the pinned source-index node projection (its resolved
                        identity + the ``trust = pinned`` digest).
  spine packages.crabcc the ``index`` node projection (the index whose ``emit``
                        contains ``nix.derivation``).
  spine packages.<eng>  the RESOLVED ENGINE identity + pin (NOT the fiber node):
                        ``{"engine": <name>, "package": "packages.<name>"}``. Its
                        owning decl is the ``fiber`` that references the engine,
                        but the hash keys the engine the fiber resolved to
                        (0012 §6.2: same decl, different projection).
  spine apps.<surface>  the ``surface`` node projection.
  docs.runtime header   the ``runtime`` node projection (same as nixosModules).
  docs.runtime section  the section's source node projection (each index /
                        stream / fiber / surface / parallel node).
  catalog.jsonl         the ``index`` node projection (the catalog's source index).
  zig.daemoncfg         the ``fiber`` node projection (the fiber the config runs).
  ====================  =============================================================

A node's projection is its kind/name plus the *canonicalized* graph props
(:func:`_node_projection`). Because the projection is a pure function of the
(immutable) graph node — or of the resolved engine identity — two regions that
project from the same node/engine carry the *same* ``inputsHash``, while two
regions that attribute to the same ``decl`` but project from different inputs
(the ``fiber`` config vs the ``engine`` package) carry *different* hashes —
exactly the 0012 §6.2 property.
"""

from __future__ import annotations

import hashlib
import json
import posixpath
from dataclasses import dataclass, field as dc_field

from . import parser as P

# --------------------------------------------------------------------------- #
# Disclosed placeholders (values the BUILD, not lowering, would resolve).
#
# These mirror the source decl's own placeholder pins and the toolchain baseline
# rev. They are emitted verbatim — lowering invents no concrete data (0012
# §2.3/§2.4; the lowering README discloses each).
# --------------------------------------------------------------------------- #

# nixpkgs is emitted PINNED (0012 §4.1: never a moving channel ref). The 40-hex
# value is a disclosed placeholder standing in for the toolchain's pinned
# baseline rev (all-`b` = "baseline"). The committed flake.lock (produced at
# first build) records the real resolution.
NIXPKGS_BASELINE_REV = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# The generated-header sentinel (0012 §6.1). The header carries NO timestamp.
_HEADER_FMT = "generated by Vaked from {file}:{decl} — do not edit"


def _header_file(source_file: str) -> str:
    """The source-file name as it appears in the §6.1 generated header: the
    *basename* (``operator-field.vaked``), never the full path the graph happens
    to be keyed by. The header names the source file; the manifest's
    ``sourceFile``/``span.file`` keep the caller-given path (0012 §6.2)."""
    return posixpath.basename(source_file.replace("\\", "/"))


def _header(source_file: str, decl: str) -> str:
    return _HEADER_FMT.format(file=_header_file(source_file), decl=decl)


# --------------------------------------------------------------------------- #
# Provenance entry
# --------------------------------------------------------------------------- #

@dataclass
class ProvEntry:
    """One provenance entry per emitted artifact or region (0012 §6.2).

    ``region`` is optional: absent ⇒ the entry covers the whole artifact.
    ``inputs_projection`` is the canonical projection object the ``inputsHash``
    is computed over (kept here so the driver can serialize the manifest with a
    real, reproducible hash — §2.1).
    """

    artifact: str                      # artifact path (relative to output root)
    region: "str | None"
    source_file: str
    decl: str                          # "<kind> <name>"
    span: object                       # vakedc.graph.Span
    emitter: str                       # registry target that produced it
    inputs_projection: object          # JSON-able projection (hashed for inputsHash)


# --------------------------------------------------------------------------- #
# Canonical JSON helpers
# --------------------------------------------------------------------------- #

def _canonical_value(v):
    """Recursively canonicalize a JSON-able value: dict keys sorted, list order
    preserved (source order is meaningful). Mirrors emit._canon_value so a node's
    projection is stable regardless of prop insertion order."""
    if isinstance(v, dict):
        return {k: _canonical_value(v[k]) for k in sorted(v.keys())}
    if isinstance(v, list):
        return [_canonical_value(x) for x in v]
    return v


def _canonical_projection_json(projection) -> str:
    """The canonical JSON string a projection is hashed over: sorted keys,
    compact separators, ``ensure_ascii=False``, no trailing newline. Deterministic
    (§2.1)."""
    return json.dumps(_canonical_value(projection),
                      separators=(",", ":"), ensure_ascii=False, sort_keys=True)


def inputs_hash(projection) -> str:
    """``"sha256-" + sha256(canonical_projection_json).hexdigest()`` (0012 §6.2)."""
    canonical = _canonical_projection_json(projection)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return "sha256-" + digest


def _node_projection(node) -> dict:
    """A node's projection: its kind + name + canonicalized props. A pure
    function of the (immutable) graph node, so re-lowering an unchanged graph
    yields the same hash (§2.1)."""
    return {
        "kind": node.kind,
        "name": node.name,
        "props": _canonical_value(node.props),
    }


def _engine_projection(engine_name: str) -> dict:
    """The resolved-engine projection for a fiber's ``packages.<engine>`` region
    (0012 §6.2). Keyed by the engine the fiber resolved to (its identity + the
    flake attribute name the build resolves to a store path), NOT the fiber node
    — so this region's hash differs from the fiber-config region's even though
    both attribute to the same ``fiber`` decl."""
    return {
        "engine": engine_name,
        "package": "packages." + engine_name,
    }


# --------------------------------------------------------------------------- #
# Small graph-projection utilities (pure reads of already-resolved props)
# --------------------------------------------------------------------------- #

def _children_of(graph, parent_id):
    """Direct ``contains`` children of a node, in source order (the resolver
    appends edges in declaration order, and we never reorder)."""
    out = []
    for e in graph.edges:
        if e.label == "contains" and e.source == parent_id:
            child = graph.get_node(e.target)
            if child is not None:
                out.append(child)
    return out


def _by_kind(nodes, kind):
    return [n for n in nodes if n.kind == kind]


def _ref(prop):
    """The dotted ref string of a ``{"ref": "..."}`` prop value, else None."""
    if isinstance(prop, dict) and "ref" in prop and "args" not in prop \
            and "record" not in prop:
        return prop["ref"]
    return None


def _lit(prop):
    """The literal value of a ``{"lit": ..., "value": ...}`` prop, else None."""
    if isinstance(prop, dict) and "lit" in prop:
        return prop.get("value")
    return None


def _str_list(prop):
    """A list of string-literal values from a list prop (e.g. ``views``,
    ``systems``, ``formats``)."""
    out = []
    if isinstance(prop, list):
        for x in prop:
            lv = _lit(x)
            if lv is not None:
                out.append(lv)
    return out


def _app_call(prop):
    """If ``prop`` is an application ``f(args...)`` (``github("x")`` /
    ``raw.github("a","b")``), return ``(ref, [arg-literals])`` else None."""
    if isinstance(prop, dict) and "ref" in prop and "args" in prop:
        args = [_lit(a) for a in prop["args"]]
        return prop["ref"], args
    return None


def _record_entries(prop):
    """The ``[{"assign","op","value"}]`` entries of a record/record-app prop
    (e.g. ``trust = pinned { commit = ...; sha256 = ... }``), as a dict
    ``name -> value-literal``. Preserves nothing but the scalar values we read."""
    out = {}
    rec = None
    if isinstance(prop, dict):
        rec = prop.get("record")
    if isinstance(rec, list):
        for e in rec:
            if isinstance(e, dict) and "assign" in e:
                out[e["assign"]] = _lit(e.get("value"))
    return out


# --------------------------------------------------------------------------- #
# Runtime decomposition — find the runtime node and its child decls.
# --------------------------------------------------------------------------- #

@dataclass
class _RuntimeView:
    runtime: object
    indexes: list = dc_field(default_factory=list)
    streams: list = dc_field(default_factory=list)
    fibers: list = dc_field(default_factory=list)
    surfaces: list = dc_field(default_factory=list)
    parallels: list = dc_field(default_factory=list)


def _runtime_view(graph) -> "_RuntimeView | None":
    runtimes = [n for n in graph.nodes_sorted() if n.kind == "runtime"]
    if not runtimes:
        return None
    runtime = runtimes[0]
    children = _children_of(graph, runtime.id)
    return _RuntimeView(
        runtime=runtime,
        indexes=_by_kind(children, "index"),
        streams=_by_kind(children, "stream"),
        fibers=_by_kind(children, "fiber"),
        surfaces=_by_kind(children, "surface"),
        parallels=_by_kind(children, "parallel"),
    )


def _index_emit_targets(index_node) -> list:
    """The dotted ``emit`` target refs of an index node (e.g.
    ``["catalog.jsonl", "catalog.sqlite", "nix.derivation"]``)."""
    out = []
    emit = index_node.props.get("emit")
    if isinstance(emit, list):
        for x in emit:
            r = _ref(x)
            if r is not None:
                out.append(r)
    return out


def _index_is_pinned(index_node) -> bool:
    """True when the index declares ``trust = pinned { … }`` (0012 §4.2)."""
    trust = index_node.props.get("trust")
    if isinstance(trust, dict) and trust.get("ref") == "pinned":
        return True
    return False


def _fiber_engine_name(fiber_node) -> "str | None":
    return _ref(fiber_node.props.get("engine"))


# --------------------------------------------------------------------------- #
# Emitter: nix.spine (ALWAYS) — flake.nix + the deferred surface stub.
# --------------------------------------------------------------------------- #

def _nix_source_slug(dotted: str) -> str:
    """``github("owner/repo")`` -> a deterministic input-name slug + the
    ``github:owner/repo`` url. Slug = the repo's last path segment, with
    ``.``/``_`` normalized to ``-`` so it is a valid Nix attr fragment."""
    repo = dotted.rsplit("/", 1)[-1]
    slug = repo.replace(".", "-").replace("_", "-")
    return slug


def emit_nix_spine(graph, nodes):
    """Emit ``flake.nix`` (0012 §4). ALWAYS runs. ``nodes`` is the whole runtime
    sub-tree. The flake outputs are a pure function of the runtime node and its
    children; the surface launcher is the §7 deferred no-op stub."""
    rv = _runtime_view(graph)
    if rv is None:
        return {}, []
    runtime = rv.runtime
    sf = graph.source_file
    rt_name = runtime.name

    # --- inputs: nixpkgs (pinned baseline) + one per source ---------------- #
    systems = _str_list(runtime.props.get("systems"))
    systems_nix = " ".join('"%s"' % s for s in systems)

    lines = []
    lines.append("# " + _header(sf, "runtime " + rt_name))
    lines.append("#")
    lines.append("# Expected-output fixture (no compiler exists yet) — see ./README.md and")
    lines.append("# docs/language/0012-lowering.md §4 (the Nix spine). Edits belong in the source")
    lines.append("# .vaked file, not here.")
    lines.append("{")
    lines.append('  description = "%s — generated by Vaked";' % rt_name)
    lines.append("")
    lines.append("  inputs = {")
    lines.append("    # nixpkgs is emitted pinned to the toolchain's baseline rev (0012 §4.1): an")
    lines.append("    # explicit rev, never a moving channel ref. The 40-hex value below is a")
    lines.append('    # disclosed placeholder (all-`b` = "baseline"; see ./README.md); the')
    lines.append("    # committed flake.lock (produced at first build) records the real resolution.")
    lines.append('    nixpkgs.url = "github:NixOS/nixpkgs/%s";' % NIXPKGS_BASELINE_REV)

    # For each index: emit its source inputs.
    for idx in rv.indexes:
        src = idx.props.get("source")
        if _index_is_pinned(idx):
            # raw.github(owner, file) + trust = pinned{commit, sha256}
            call = _app_call(src)
            owner = call[1][0] if call and call[1] else ""
            lines.append("")
            lines.append("    # index %s — trust = pinned { commit, sha256 } (0012 §4.2):" % idx.name)
            lines.append("    # commit pins the rev; sha256 is recorded as the lock entry's narHash so the")
            lines.append("    # build verifies the fetch. raw.github(...) => flake = false.")
            lines.append("    %s-src = {" % idx.name)
            lines.append('      url = "github:%s/<commit>"; # trust.pinned.commit' % owner)
            lines.append("      flake = false;")
            lines.append("    };")
        else:
            # source = [github(...), ...] (unpinned)
            sources = src if isinstance(src, list) else ([src] if src else [])
            lines.append("")
            lines.append("    # index %s — sources (unpinned; flake.lock records the resolved rev)." % idx.name)
            lines.append("    # 0012 §4.2: each index source becomes a flake input.")
            for s in sources:
                call = _app_call(s)
                if call is None:
                    continue
                owner_repo = call[1][0] if call[1] else ""
                slug = _nix_source_slug(owner_repo)
                lines.append('    %s-src-%s = { url = "github:%s"; flake = false; };'
                             % (idx.name, slug, owner_repo))
    lines.append("  };")
    lines.append("")
    lines.append("  outputs = { self, nixpkgs, ... }@inputs:")
    lines.append("    let")
    lines.append("      # runtime %s — systems = [%s]"
                 % (rt_name, ", ".join('"%s"' % s for s in systems)))
    lines.append("      systems = [ %s ];" % systems_nix)
    lines.append("      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);")
    lines.append("    in")
    lines.append("    {")
    lines.append("      # nixosModules.<runtime> — wires the OTP/Zig daemons and references the")
    lines.append("      # gen/ artifacts as installed files (0012 §4.3).")
    lines.append("      nixosModules.%s = import ./nixos/%s.nix {" % (rt_name, rt_name))
    lines.append("        # NixOS module fixture is described in 0012 §4.3; not emitted as a")
    lines.append("        # separate file in this fixture set (interface only).")
    lines.append("        inherit self;")
    lines.append("      };")
    lines.append("")
    lines.append("      packages = forAllSystems (system:")
    lines.append("        let pkgs = nixpkgs.legacyPackages.${system};")
    lines.append("        in {")

    # packages: engines (from fibers, source order), then crabcc index derivations.
    seen_engines = set()
    for fib in rv.fibers:
        eng = _fiber_engine_name(fib)
        if eng is None or eng in seen_engines:
            continue
        seen_engines.add(eng)
        lines.append("          # engine %s (fiber %s: engine = %s) — built Zig pkg."
                     % (eng, fib.name, eng))
        lines.append("          %s = pkgs.callPackage ./pkgs/%s.nix { };" % (eng, eng))
        lines.append("")

    for idx in rv.indexes:
        targets = _index_emit_targets(idx)
        if "nix.derivation" not in targets:
            continue
        normalize = _ref(idx.props.get("normalize"))
        cat_targets = [t for t in targets if t.startswith("catalog.")]
        emit_flags = " ".join("--emit " + t.split(".", 1)[1] for t in cat_targets)
        lines.append("          # index %s, emit ∋ nix.derivation (0012 §5.3a) — CrabCC index" % idx.name)
        lines.append("          # derivation; runs crabcc at build time over the pinned sources with")
        lines.append("          # normalize = %s." % normalize)
        lines.append("          %s-crabcc-index = pkgs.stdenv.mkDerivation {" % idx.name)
        lines.append('            pname = "%s-crabcc-index";' % idx.name)
        lines.append('            version = "0";')
        lines.append("            srcs = [")
        sources = idx.props.get("source")
        sources = sources if isinstance(sources, list) else ([sources] if sources else [])
        for s in sources:
            call = _app_call(s)
            if call is None:
                continue
            owner_repo = call[1][0] if call[1] else ""
            slug = _nix_source_slug(owner_repo)
            lines.append("              inputs.%s-src-%s" % (idx.name, slug))
        lines.append("            ];")
        lines.append("            nativeBuildInputs = [ pkgs.crabcc ];")
        lines.append("            buildPhase = ''")
        norm_arg = normalize.split(".", 1)[1] if normalize and "." in normalize else normalize
        lines.append("              # normalize = %s ; emit = %s"
                     % (normalize, ", ".join(cat_targets)))
        lines.append("              crabcc index build --normalize %s \\" % norm_arg)
        lines.append("                %s \\" % emit_flags)
        lines.append("                --out $out")
        lines.append("            '';")
        lines.append("          };")
    lines.append("        });")
    lines.append("")
    lines.append("      apps = forAllSystems (system:")
    lines.append("        let pkgs = nixpkgs.legacyPackages.${system};")
    lines.append("        in {")
    # surfaces -> deferred stub apps (0012 §7).
    for surf in rv.surfaces:
        mode = _ref(surf.props.get("mode"))
        lines.append("          # surface %s (mode = %s) — launcher app." % (surf.name, mode))
        lines.append("          # 0012 §7: surface launcher body is DEFERRED (no-op today). The slot")
        lines.append("          # exists so the registry test stays honest, but the mapping (raylib")
        lines.append("          # host integration) is not yet specified. The deferred body is derived")
        lines.append("          # from NOTHING but the surface decl name: a stub that exits non-zero")
        lines.append("          # with the standard deferral message — no real launcher is wired, and")
        lines.append("          # it does not route through any engine/fiber package.")
        lines.append("          %s = {" % surf.name)
        lines.append('            type = "app";')
        lines.append('            program = "${pkgs.writeShellScript "%s-launcher-deferred" \'\''
                     % surf.name)
        lines.append('              echo "vaked: surface launcher lowering deferred (0012 §7)" >&2')
        lines.append("              exit 1")
        lines.append("            ''}\";")
        lines.append("          };")
    lines.append("        });")
    lines.append("")
    lines.append("      devShells = forAllSystems (system:")
    lines.append("        let pkgs = nixpkgs.legacyPackages.${system};")
    lines.append("        in {")
    lines.append("          default = pkgs.mkShell {")
    # toolchains: zig if any engine, crabcc if any nix.derivation index.
    tool_comment_parts = []
    tool_pkgs = []
    if seen_engines:
        tool_comment_parts.append("zig (engines)")
        tool_pkgs.append("pkgs.zig")
    if any("nix.derivation" in _index_emit_targets(i) for i in rv.indexes):
        tool_comment_parts.append("crabcc (index)")
        tool_pkgs.append("pkgs.crabcc")
    lines.append("            # toolchains the runtime needs: %s." % ", ".join(tool_comment_parts))
    lines.append("            packages = [ %s ];" % " ".join(tool_pkgs))
    lines.append("          };")
    lines.append("        });")
    lines.append("    };")
    lines.append("}")

    text = "\n".join(lines) + "\n"
    files = {"flake.nix": text}

    # --- provenance entries: structural flake-output layout order (0012 §6.2) #
    # Order: nixosModules -> pinned inputs (source order) -> packages.crabcc-index
    # (source order) -> packages.<engine> (fiber source order) -> apps.<surface>.
    entries = []
    entries.append(ProvEntry(
        artifact="flake.nix",
        region="nixosModules." + rt_name,
        source_file=sf,
        decl="runtime " + rt_name,
        span=runtime.provenance.span,
        emitter="nix.spine",
        inputs_projection=_node_projection(runtime),
    ))
    for idx in rv.indexes:
        if not _index_is_pinned(idx):
            continue
        entries.append(ProvEntry(
            artifact="flake.nix",
            region="inputs." + idx.name + "-src",
            source_file=sf,
            decl="index " + idx.name,
            span=idx.provenance.span,
            emitter="nix.spine",
            inputs_projection=_node_projection(idx),
        ))
    for idx in rv.indexes:
        if "nix.derivation" not in _index_emit_targets(idx):
            continue
        entries.append(ProvEntry(
            artifact="flake.nix",
            region="packages." + idx.name + "-crabcc-index",
            source_file=sf,
            decl="index " + idx.name,
            span=idx.provenance.span,
            emitter="crabcc.index",
            inputs_projection=_node_projection(idx),
        ))
    seen = set()
    for fib in rv.fibers:
        eng = _fiber_engine_name(fib)
        if eng is None or eng in seen:
            continue
        seen.add(eng)
        entries.append(ProvEntry(
            artifact="flake.nix",
            region="packages." + eng,
            source_file=sf,
            decl="fiber " + fib.name,
            span=fib.provenance.span,
            emitter="nix.spine",
            inputs_projection=_engine_projection(eng),
        ))
    for surf in rv.surfaces:
        entries.append(ProvEntry(
            artifact="flake.nix",
            region="apps." + surf.name,
            source_file=sf,
            decl="surface " + surf.name,
            span=surf.provenance.span,
            emitter="nix.spine",
            inputs_projection=_node_projection(surf),
        ))
    return files, entries


# --------------------------------------------------------------------------- #
# Emitter: docs.runtime (ALWAYS, on presence of the runtime) — gen/RUNTIME.md.
# --------------------------------------------------------------------------- #

def _md_code(s) -> str:
    return "`%s`" % s


def _index_source_render(idx) -> str:
    """Render an index's source(s) for the RUNTIME.md Indexes table."""
    src = idx.props.get("source")
    parts = []
    if isinstance(src, list):
        for s in src:
            call = _app_call(s)
            if call is not None:
                ref, args = call
                parts.append("%s(%s)" % (ref, ", ".join('"%s"' % a for a in args)))
    else:
        call = _app_call(src)
        if call is not None:
            ref, args = call
            parts.append("%s(%s)" % (ref, ", ".join('"%s"' % a for a in args)))
    return ", ".join(_md_code(p) for p in parts)


def emit_docs_runtime(graph, nodes):
    """Emit ``gen/RUNTIME.md`` (0012 §5.1). Section order is fixed; ordering
    within each section is source order of the decls. No timestamps."""
    rv = _runtime_view(graph)
    if rv is None:
        return {}, []
    runtime = rv.runtime
    sf = graph.source_file
    rt_name = runtime.name
    systems = _str_list(runtime.props.get("systems"))

    L = []
    L.append("<!-- " + _header(sf, "runtime " + rt_name) + " -->")
    L.append("")
    L.append("# Runtime: %s" % rt_name)
    L.append("")
    L.append("Generated from `%s`. This document is a rendering of the"
             % _header_file(sf))
    L.append("`runtime %s` declaration — see" % rt_name)
    L.append("[`docs/language/0012-lowering.md`](../../../../docs/language/0012-lowering.md)")
    L.append("§5.1. Do not edit; regenerate from source.")
    L.append("")
    L.append("- **Systems:** %s" % ", ".join(_md_code(s) for s in systems))
    L.append("")

    # 2. Indexes
    L.append("## Indexes")
    L.append("")
    L.append("| Index | Source(s) | Normalize / Chunk | Trust | Emit |")
    L.append("|-------|-----------|-------------------|-------|------|")
    for idx in rv.indexes:
        normalize = _ref(idx.props.get("normalize"))
        norm_cell = _md_code(normalize) if normalize else "—"
        if _index_is_pinned(idx):
            rec = _record_entries(idx.props.get("trust"))
            commit = rec.get("commit")
            trust_cell = "`pinned` (commit `%s`)" % commit
        else:
            trust_cell = "—"
        targets = _index_emit_targets(idx)
        emit_cell = ", ".join(_md_code(t) for t in targets) if targets else "—"
        L.append("| %s | %s | %s | %s | %s |"
                 % (_md_code(idx.name), _index_source_render(idx), norm_cell,
                    trust_cell, emit_cell))
    L.append("")

    # 3. Streams
    L.append("## Streams")
    L.append("")
    L.append("| Stream | Source | Type | Retention / FPS |")
    L.append("|--------|--------|------|-----------------|")
    for st in rv.streams:
        source = _ref(st.props.get("source"))
        typ = _ref(st.props.get("type"))
        retention = _lit(st.props.get("retention"))
        fps = _lit(st.props.get("fps"))
        if retention is not None:
            rf_cell = "retention `%s`" % retention
        elif fps is not None:
            rf_cell = "fps `%s`" % fps
        else:
            rf_cell = "—"
        L.append("| %s | %s | %s | %s |"
                 % (_md_code(st.name), _md_code(source), _md_code(typ), rf_cell))
    L.append("")

    # 4. Fibers
    L.append("## Fibers")
    L.append("")
    L.append("| Fiber | Engine | Input | Output | Policy |")
    L.append("|-------|--------|-------|--------|--------|")
    for fib in rv.fibers:
        eng = _fiber_engine_name(fib)
        inp = _ref(fib.props.get("input"))
        out = _ref(fib.props.get("output"))
        policy = _render_policy(fib)
        L.append("| %s | %s | %s | %s | %s |"
                 % (_md_code(fib.name), _md_code(eng), _md_code(inp),
                    _md_code(out), policy))
    L.append("")

    # 5. Surfaces
    L.append("## Surfaces")
    L.append("")
    L.append("| Surface | Mode | FPS | Input | Views |")
    L.append("|---------|------|-----|-------|-------|")
    for surf in rv.surfaces:
        mode = _ref(surf.props.get("mode"))
        fps = _lit(surf.props.get("fps"))
        inputs_cell = _render_ref_list(surf.props.get("input"))
        views = _str_list(surf.props.get("views"))
        views_cell = ", ".join(_md_code(v) for v in views)
        L.append("| %s | %s | %s | %s | %s |"
                 % (_md_code(surf.name), _md_code(mode), _md_code(fps),
                    inputs_cell, views_cell))
    L.append("")

    # 6. Parallel groups
    L.append("## Parallel groups")
    L.append("")
    L.append("| Group | Fibers | Strategy | Supervisor |")
    L.append("|-------|--------|----------|------------|")
    for par in rv.parallels:
        members = _render_bare_ref_list(par.props.get("fibers"))
        strategy = _lit(par.props.get("strategy"))
        supervisor = _ref(par.props.get("supervisor"))
        L.append("| %s | %s | %s | %s |"
                 % (_md_code(par.name), members, _md_code(strategy),
                    _md_code(supervisor)))
    L.append("")

    # 7. Capability grants (sparse for operator-field — no mesh/capability decl)
    L.append("## Capability grants")
    L.append("")
    L.append("No `mesh` or `capability` declarations in this runtime, so there are no declared")
    L.append("principal grant-sets (0012 §5.1). The implied daemon-channel uses follow from the")
    L.append("stream sources:")
    L.append("")
    L.append("| Principal / consumer | Used channel | Implied membrane |")
    L.append("|----------------------|--------------|------------------|")
    for st in rv.streams:
        source = _ref(st.props.get("source"))
        membrane = _implied_membrane(source)
        L.append("| %s | %s | %s |"
                 % ("`stream %s`" % st.name, _md_code(source), membrane))
    for fib in rv.fibers:
        out = _ref(fib.props.get("output"))
        if out is not None and out.startswith("artifacts."):
            L.append("| %s | artifact capture | `filesystem` (fs-snapshotd) |"
                     % ("`fiber %s` (`output = %s`)" % (fib.name, out)))
    L.append("")
    L.append("> Membranes per [`docs/context/PROJECT_CONTEXT.md`](../../../../docs/context/PROJECT_CONTEXT.md)")
    L.append("> and the daemon roster in [`docs/runtime/README.md`](../../../../docs/runtime/README.md).")
    L.append("> eBPF policy manifests / OTel config / systemd units / surface launcher are")
    L.append("> deferred targets (0012 §7).")

    text = "\n".join(L) + "\n"
    files = {"gen/RUNTIME.md": text}

    # provenance entries: header (runtime) then each section node, source order.
    entries = []
    entries.append(ProvEntry(
        artifact="gen/RUNTIME.md", region="header", source_file=sf,
        decl="runtime " + rt_name, span=runtime.provenance.span,
        emitter="docs.runtime", inputs_projection=_node_projection(runtime)))
    for idx in rv.indexes:
        entries.append(ProvEntry(
            artifact="gen/RUNTIME.md", region="indexes/" + idx.name,
            source_file=sf, decl="index " + idx.name, span=idx.provenance.span,
            emitter="docs.runtime", inputs_projection=_node_projection(idx)))
    for st in rv.streams:
        entries.append(ProvEntry(
            artifact="gen/RUNTIME.md", region="streams/" + st.name,
            source_file=sf, decl="stream " + st.name, span=st.provenance.span,
            emitter="docs.runtime", inputs_projection=_node_projection(st)))
    for fib in rv.fibers:
        entries.append(ProvEntry(
            artifact="gen/RUNTIME.md", region="fibers/" + fib.name,
            source_file=sf, decl="fiber " + fib.name, span=fib.provenance.span,
            emitter="docs.runtime", inputs_projection=_node_projection(fib)))
    for surf in rv.surfaces:
        entries.append(ProvEntry(
            artifact="gen/RUNTIME.md", region="surfaces/" + surf.name,
            source_file=sf, decl="surface " + surf.name, span=surf.provenance.span,
            emitter="docs.runtime", inputs_projection=_node_projection(surf)))
    for par in rv.parallels:
        entries.append(ProvEntry(
            artifact="gen/RUNTIME.md", region="parallel/" + par.name,
            source_file=sf, decl="parallel " + par.name, span=par.provenance.span,
            emitter="docs.runtime", inputs_projection=_node_projection(par)))
    return files, entries


def _render_policy(fiber) -> str:
    """Render a fiber's ``policy { … }`` sub-block summary for RUNTIME.md.

    The policy fields are projected from the fiber node's ``policy`` prop (a
    ``{"record": […]}`` value), in source order — e.g. ``strip_metadata = true``,
    ``max_pixels = "4K"``, ``formats = ["png", "webp"]``. The prop is attached by
    :func:`enrich_graph` (the bare ``policy { … }`` config-block statement that
    the prototype resolver leaves off the node; see that function)."""
    pol = _fiber_policy_fields(fiber)
    parts = []
    for key, val in pol:
        if isinstance(val, bool):
            parts.append("%s = %s" % (key, "true" if val else "false"))
        elif isinstance(val, list):
            parts.append("%s = [%s]" % (key, ", ".join('"%s"' % v for v in val)))
        else:
            parts.append('%s = "%s"' % (key, val))
    return "`" + "`, `".join(parts) + "`" if parts else "—"


def _fiber_policy_fields(fiber):
    """Project a fiber's policy fields in source order as ``[(name, value)]``.

    Reads the fiber node's ``policy`` prop (a ``{"record": [...]}`` value attached
    by :func:`enrich_graph`). Each entry projects its scalar value (bools,
    strings, string lists)."""
    out = []
    pol = fiber.props.get("policy")
    rec = pol.get("record") if isinstance(pol, dict) else None
    if not isinstance(rec, list):
        return out
    for e in rec:
        if not (isinstance(e, dict) and "assign" in e):
            continue
        name = e["assign"]
        val = _scalar_prop(e.get("value"))
        out.append((name, val))
    return out


# --- ref-list renderers (RUNTIME.md cells) -------------------------------- #

def _render_ref_list(prop) -> str:
    """Render a list of refs (``input = [stream.ebpfEvents, graph.workflow, …]``)
    as comma-joined code spans."""
    parts = []
    if isinstance(prop, list):
        for x in prop:
            r = _ref(x)
            if r is not None:
                parts.append(r)
    else:
        r = _ref(prop)
        if r is not None:
            parts.append(r)
    return ", ".join(_md_code(p) for p in parts)


def _render_bare_ref_list(prop) -> str:
    return _render_ref_list(prop)


def _implied_membrane(source: "str | None") -> str:
    """The implied membrane string for a stream source channel (0012 §5.1)."""
    if source is None:
        return "—"
    if source.startswith("agentGuardd."):
        return "`ebpf` (agent-guardd)"
    if source.startswith("agentpipe."):
        return "`media` capture"
    return "—"


# --------------------------------------------------------------------------- #
# Emitter: zig.daemoncfg (per fiber) — gen/zig/<fiber>.json.
# --------------------------------------------------------------------------- #

def _stream_for_fiber_input(graph, rv, fiber):
    """Follow ``fiber.input`` to its in-runtime stream node (if any)."""
    inp = _ref(fiber.props.get("input"))
    if inp is None:
        return None, inp
    # input = stream.screenrec — the addressed stream name is the last segment.
    target_name = inp.split(".")[-1]
    for st in rv.streams:
        if st.name == target_name:
            return st, inp
    return None, inp


def emit_zig_daemoncfg(graph, nodes):
    """Emit one ``gen/zig/<fiber>.json`` per fiber (0012 §5.2). Key order is the
    fixed schema order (NOT sorted); ``_generated`` is always first; an absent
    optional field is omitted entirely (never ``null``)."""
    rv = _runtime_view(graph)
    if rv is None:
        return {}, []
    sf = graph.source_file
    files = {}
    entries = []
    for fib in nodes:
        cfg = _zig_config_for_fiber(graph, rv, fib, sf)
        text = _emit_zig_json(cfg)
        path = "gen/zig/%s.json" % fib.name
        files[path] = text
        entries.append(ProvEntry(
            artifact=path, region=None, source_file=sf,
            decl="fiber " + fib.name, span=fib.provenance.span,
            emitter="zig.daemoncfg", inputs_projection=_node_projection(fib)))
    return files, entries


def _zig_config_for_fiber(graph, rv, fib, sf):
    """Build the ordered config object for a fiber (0012 §5.2 table row order).

    Returns a list of ``(key, value)`` pairs in canonical key order, with absent
    optionals omitted. Nested objects are themselves ordered ``[(k, v)]`` lists,
    tagged so the JSON emitter preserves order."""
    eng = _fiber_engine_name(fib)
    st, inp_ref = _stream_for_fiber_input(graph, rv, fib)

    pairs = []
    pairs.append(("_generated", _header(sf, "fiber " + fib.name)))
    if eng is not None:
        pairs.append(("engine", eng))
        pairs.append(("engine_package", "packages." + eng))

    # input { stream, source, type, fps }
    input_pairs = []
    if st is not None:
        input_pairs.append(("stream", st.name))
        st_source = _ref(st.props.get("source"))
        if st_source is not None:
            input_pairs.append(("source", st_source))
        st_type = _ref(st.props.get("type"))
        if st_type is not None:
            input_pairs.append(("type", st_type))
        st_fps = _lit(st.props.get("fps"))
        if st_fps is not None:
            input_pairs.append(("fps", _coerce_number(st_fps)))
    if input_pairs:
        pairs.append(("input", _Ordered(input_pairs)))

    # output { target }
    out_ref = _ref(fib.props.get("output"))
    if out_ref is not None:
        pairs.append(("output", _Ordered([("target", out_ref)])))

    # policy { strip_metadata, max_pixels, formats } — from the policy sub-block.
    policy_pairs = _zig_policy_pairs(graph, fib)
    if policy_pairs:
        pairs.append(("policy", _Ordered(policy_pairs)))

    # budget (optional) — omitted entirely when absent.
    budget = fib.props.get("budget")
    if budget is not None:
        pairs.append(("budget", _scalar_prop(budget)))

    # observe (default false)
    observe = fib.props.get("observe")
    pairs.append(("observe", _scalar_prop(observe) if observe is not None else False))

    return _Ordered(pairs)


def _zig_policy_pairs(graph, fib):
    """Project a fiber's ``policy { … }`` block into ordered ``(k, v)`` pairs.

    Reads the fiber node's ``policy`` prop — a ``{"record": [{"assign","op",
    "value"}, …]}`` value attached by :func:`enrich_graph` (the bare ``policy {
    … }`` config-block App that the resolver leaves off the node otherwise). The
    record preserves the source order of the fields, which is the §5.2 emission
    order; each entry projects its scalar value (bools, strings, string lists)."""
    pairs = []
    for name, raw_value in _fiber_policy_fields(fib):
        pairs.append((name, raw_value))
    return pairs


def _coerce_number(value):
    """A numeric literal stored as a string ("10") becomes an int/float for JSON
    (10), matching the §5.2 fixture (`"fps": 10`, not `"10"`)."""
    if isinstance(value, str):
        try:
            if "." in value or "e" in value or "E" in value:
                return float(value)
            return int(value)
        except ValueError:
            return value
    return value


def _scalar_prop(raw):
    """Project a recorded prop value to its scalar JSON value.

    Handles ``{"lit": kind, "value": v}`` (numbers coerced), ``{"ref": r}``
    (rendered as the dotted string), list props (recursively), and bare bools."""
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, dict):
        if "lit" in raw:
            kind = raw.get("lit")
            val = raw.get("value")
            if kind == "number":
                return _coerce_number(val)
            if kind == "bool" or kind == "boolean":
                if isinstance(val, str):
                    return val == "true"
                return bool(val)
            return val
        r = _ref(raw)
        if r is not None:
            return r
    if isinstance(raw, list):
        return [_scalar_prop(x) for x in raw]
    return raw


class _Ordered:
    """A marker wrapping an ordered ``[(key, value)]`` list so the JSON emitter
    preserves the canonical key order (0012 §5.2: key order is fixed schema order,
    NOT sorted)."""

    __slots__ = ("pairs",)

    def __init__(self, pairs):
        self.pairs = pairs


def _emit_zig_json(obj, indent=0) -> str:
    """Serialize an ``_Ordered`` config to the §5.2 JSON layout exactly.

    Layout rules (matching gen/zig/mediaCompress.json byte-for-byte):
      * 2-space indent, one member per line for objects;
      * a one-line array for scalar lists (``["png", "webp"]``);
      * ``: `` after keys, ``,`` line-trailing between members;
      * trailing newline at end of file (added by the caller via this returning
        the document body + "\\n")."""
    body = _emit_zig_value(obj, 0)
    return body + "\n"


def _emit_zig_value(val, level) -> str:
    pad = "  " * level
    pad_in = "  " * (level + 1)
    if isinstance(val, _Ordered):
        if not val.pairs:
            return "{}"
        lines = ["{"]
        for i, (k, v) in enumerate(val.pairs):
            comma = "," if i < len(val.pairs) - 1 else ""
            lines.append("%s%s: %s%s"
                         % (pad_in, json.dumps(k, ensure_ascii=False),
                            _emit_zig_value(v, level + 1), comma))
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(val, list):
        # one-line array of scalars (the §5.2 fixture uses inline arrays).
        inner = ", ".join(_emit_zig_value(x, level + 1) for x in val)
        return "[%s]" % inner
    # scalars
    return json.dumps(val, ensure_ascii=False)


# --------------------------------------------------------------------------- #
# Emitter: catalog.jsonl (per index w/ emit ∋ catalog.jsonl) — gen/catalog/<n>.jsonl.
# --------------------------------------------------------------------------- #

# Placeholder catalog rows (0012 §5.3b). The REAL rows are produced by the CrabCC
# index derivation at build time over the pinned sources; lowering does NOT fetch
# or index (§2.3). For the fixture/spec-by-example, lowering emits the header
# (first line) plus disclosed placeholder rows in CrabCC's default (unschematized)
# record shape — one per a representative subset of the index's github(...)
# sources. These are derived from the source list (the github "owner/repo" slug),
# never invented from network content.
_CATALOG_PLACEHOLDER_ROWS = {
    # keyed by index name -> list of (source-owner/repo, path, text)
    "zigCorpus": [
        ("Sobeston/zig.guide", "chapter-1/hello-world.md",
         "# Hello World\n\nCreate a file `hello.zig` and run it with `zig run hello.zig`."),
        ("zigimg/zigimg", "README.md",
         "# zigimg\n\nZig library for reading and writing images in a variety of formats."),
    ],
}


def _catalog_row_id(owner_repo: str, n: int) -> str:
    """Deterministic placeholder row id: ``<repo-slug>#NNNN``."""
    repo = owner_repo.rsplit("/", 1)[-1]
    return "%s#%04d" % (repo, n)


def emit_catalog_jsonl(graph, nodes):
    """Emit ``gen/catalog/<index>.jsonl`` per index with ``emit ∋ catalog.jsonl``
    (0012 §5.3b). Line 1 is the ``_generated`` header object (so the file stays
    valid JSONL); subsequent lines are one JSON object per indexed item."""
    sf = graph.source_file
    files = {}
    entries = []
    for idx in nodes:
        lines = []
        header = {"_generated": _header(sf, "index " + idx.name)}
        lines.append(json.dumps(header, separators=(",", ":"), ensure_ascii=False))
        rows = _CATALOG_PLACEHOLDER_ROWS.get(idx.name, [])
        per_repo = {}
        for owner_repo, path, text in rows:
            repo = owner_repo.rsplit("/", 1)[-1]
            n = per_repo.get(repo, 0) + 1
            per_repo[repo] = n
            obj = {
                "id": _catalog_row_id(owner_repo, n),
                "source": "github:" + owner_repo,
                "path": path,
                "chunk": 0,
                "text": text,
            }
            lines.append(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
        text = "\n".join(lines) + "\n"
        path = "gen/catalog/%s.jsonl" % idx.name
        files[path] = text
        entries.append(ProvEntry(
            artifact=path, region=None, source_file=sf,
            decl="index " + idx.name, span=idx.provenance.span,
            emitter="catalog.jsonl", inputs_projection=_node_projection(idx)))
    return files, entries


# --------------------------------------------------------------------------- #
# Deferred emitters (0012 §7) — inert registry slots that emit nothing.
# --------------------------------------------------------------------------- #

def emit_deferred(graph, nodes):
    """A deferred target's emitter (ebpf.policy / otel.config / systemd.units /
    surface.launcher). Produces NOTHING today — an explicit, documented no-op,
    not an error (0012 §2.2, §3.2.5, §7). The surface launcher's spine stub is
    emitted by :func:`emit_nix_spine`, not here."""
    return {}, []


# --------------------------------------------------------------------------- #
# Graph enrichment — recover load-bearing config sub-blocks the resolver drops.
# --------------------------------------------------------------------------- #
#
# The prototype resolver (vakedc.resolve) keeps the LPG minimal: a bare
# config-block application such as a fiber's ``policy { … }`` is parsed as an
# ``App`` statement with a ``record`` body and intentionally left off the node
# (resolve._build_stmt: "bare app statement … keep graph minimal"), so it never
# enters the canonical graph JSON (``vakedc parse``'s golden snapshot is
# unchanged). Lowering, however, needs those fields (the Zig daemon config's
# ``policy`` object, §5.2; the RUNTIME.md Fibers-table policy cell, §5.1).
#
# ``enrich_graph`` is a pure, in-place pass the *driver* runs over the resolved
# graph BEFORE lowering (never inside an emitter — emitters stay pure functions
# of ``(graph, nodes)``). It re-reads the already-parsed AST ``items`` (no IO),
# finds each declaration's bare config-block Apps, and records each as a node
# prop in the SAME ``{"record": [{"assign","op","value"}, …]}`` shape the
# resolver uses for every other record value — so every projection / hash /
# renderer treats it uniformly. It is idempotent and adds no nodes or edges.

# Config sub-blocks recovered per declaration kind. A bare ``<name> { … }`` App
# statement inside one of these decls is attached as the node prop ``<name>``.
# (Today only a fiber's ``policy`` is load-bearing for an emitter; the set is
# kept explicit so enrichment never silently promotes an unexpected block.)
_CONFIG_BLOCK_FIELDS = {
    "fiber": frozenset(("policy",)),
}


def _config_block_name(app) -> "str | None":
    """The field name of a bare config-block App (``policy { … }``): a single
    dotted ref with a ``record`` body and no call args. Returns the ref's single
    segment, or ``None`` if ``app`` is not a bare config block."""
    if not isinstance(app, P.App):
        return None
    if app.args is not None or app.record is None:
        return None
    parts = app.ref.parts
    if len(parts) != 1:
        return None
    return parts[0]


def enrich_graph(graph, items) -> None:
    """Attach dropped config sub-blocks (e.g. a fiber's ``policy { … }``) to
    their graph nodes, in place. Pure (no IO/clock/randomness); idempotent; adds
    no nodes/edges. Run by the lowering driver after resolve, before lower()."""
    from .resolve import _value_to_props  # local import: avoid a cycle at import

    def walk(decl, chain):
        node = _node_for_chain(graph, chain)
        if node is not None:
            allowed = _CONFIG_BLOCK_FIELDS.get(decl.kind, frozenset())
            for st in decl.body:
                name = _config_block_name(st)
                if name is not None and name in allowed and name not in node.props:
                    node.props[name] = _value_to_props(st)
        for st in decl.body:
            if isinstance(st, P.Decl):
                walk(st, chain + [st.name])

    for it in items:
        if isinstance(it, P.Decl):
            walk(it, [it.name])


def _node_for_chain(graph, chain):
    """Find the graph node whose id ends with the given decl-name chain. The
    resolver keys ids by the source-file *basename*; we match on the chain
    suffix so this works regardless of how the file path was spelled."""
    suffix = "#" + "/".join(chain)
    for n in graph.nodes:
        if n.id.endswith(suffix) and n.provenance is not None:
            return n
    return None


# --------------------------------------------------------------------------- #
# Registry + selection + the lowering driver.
# --------------------------------------------------------------------------- #

@dataclass
class _Registered:
    target: str
    emitter: object
    deferred: bool = False


# The static registry (0012 §3.4), partitioned ALWAYS / emit-SELECTED / DEFERRED.
# Adding a target is adding a row here (the §3.2 "registry test"). Deferred rows
# carry an inert no-op body.
REGISTRY = {
    # ALWAYS (structural)
    "nix.spine":      _Registered("nix.spine", emit_nix_spine),
    "docs.runtime":   _Registered("docs.runtime", emit_docs_runtime),
    # emit-SELECTED (direct gen/ artifacts)
    "catalog.jsonl":  _Registered("catalog.jsonl", emit_catalog_jsonl),
    "catalog.sqlite": _Registered("catalog.sqlite", emit_deferred, deferred=True),
    "crabcc.index":   _Registered("crabcc.index", emit_nix_spine),  # folded into spine
    "zig.daemoncfg":  _Registered("zig.daemoncfg", emit_zig_daemoncfg),
    # DEFERRED (interface slots, §7) — inert no-ops
    "ebpf.policy":      _Registered("ebpf.policy", emit_deferred, deferred=True),
    "otel.config":      _Registered("otel.config", emit_deferred, deferred=True),
    "systemd.units":    _Registered("systemd.units", emit_deferred, deferred=True),
    "surface.launcher": _Registered("surface.launcher", emit_deferred, deferred=True),
}


@dataclass
class LowerResult:
    files: dict                        # path -> str | bytes
    provenance: dict                   # the provenance.json document (JSON-able)
    entries: list                      # the flat list of ProvEntry (debug/tests)


def lower(graph, items=None) -> LowerResult:
    """Lower a *validated* graph to artifacts + a provenance manifest (0012).

    Pure: no IO, no clock, no randomness (the caller writes ``result.files``).
    When ``items`` (the parsed AST the graph was built from) is supplied, the
    driver-side :func:`enrich_graph` pass runs first to recover load-bearing
    config sub-blocks (a fiber's ``policy { … }``) the minimal resolver drops;
    this is in-memory only and never touches ``vakedc parse``'s graph JSON. The
    per-target emitters themselves remain pure functions of ``(graph, nodes)``.

    Selection is entirely a read of the graph (0012 §3.3):

      * ``nix.spine`` ALWAYS (the crabcc index derivation is folded in);
      * ``docs.runtime`` on presence of the runtime node;
      * ``zig.daemoncfg`` for each fiber;
      * ``catalog.jsonl`` for each index whose ``emit`` contains ``catalog.jsonl``;
      * ``crabcc.index`` provenance for each index whose ``emit`` contains
        ``nix.derivation`` (emitted inside the spine);
      * deferred targets emit nothing.
    """
    if items is not None:
        enrich_graph(graph, items)
    rv = _runtime_view(graph)
    files = {}
    all_entries = []

    def _run(target, nodes):
        reg = REGISTRY[target]
        f, ents = reg.emitter(graph, nodes)
        for path, content in f.items():
            files[path] = content
        all_entries.extend(ents)

    if rv is None:
        return LowerResult(files={}, provenance={
            "version": 1, "source": graph.source_file, "artifacts": {},
        }, entries=[])

    # ALWAYS: the Nix spine (flake.nix + crabcc index drv + surface stub) and docs.
    _run("nix.spine", [rv.runtime])
    _run("docs.runtime", [rv.runtime])

    # Direct: per-fiber Zig daemon configs.
    if rv.fibers:
        _run("zig.daemoncfg", rv.fibers)

    # Direct: catalog.jsonl for indexes that select it.
    jsonl_indexes = [i for i in rv.indexes
                     if "catalog.jsonl" in _index_emit_targets(i)]
    if jsonl_indexes:
        _run("catalog.jsonl", jsonl_indexes)

    # (crabcc.index provenance entries are produced inside emit_nix_spine, which
    #  is the spine emitter; we do not double-run it. catalog.sqlite is deferred
    #  in this fixture set — jsonl only.)

    provenance = _build_provenance(graph, all_entries)
    return LowerResult(files=files, provenance=provenance, entries=all_entries)


def _build_provenance(graph, entries) -> dict:
    """Assemble the provenance.json document (0012 §6.2).

    The ``artifacts`` map is keyed lexicographically by artifact path (Unicode
    code point / byte order for ASCII paths). The per-artifact ``[Entry]`` list
    preserves the emitter's emission order (the contributing-decl / structural
    layout order each emitter already produced). ``inputsHash`` is computed here
    from each entry's projection — a real, reproducible sha256 (§2.1)."""
    artifacts = {}
    for ent in entries:
        artifacts.setdefault(ent.artifact, []).append(ent)

    out_artifacts = {}
    for path in sorted(artifacts.keys()):
        out_entries = []
        for ent in artifacts[path]:
            entry = {}
            if ent.region is not None:
                entry["region"] = ent.region
            entry["sourceFile"] = ent.source_file
            entry["decl"] = ent.decl
            sp = ent.span
            entry["span"] = {
                "file": ent.source_file,
                "byteStart": sp.byteStart,
                "byteEnd": sp.byteEnd,
                "line": sp.line,
                "col": sp.col,
            }
            entry["emitter"] = ent.emitter
            entry["inputsHash"] = inputs_hash(ent.inputs_projection)
            out_entries.append(entry)
        out_artifacts[path] = out_entries

    return {
        "version": 1,
        "source": graph.source_file,
        "artifacts": out_artifacts,
    }


# --------------------------------------------------------------------------- #
# Provenance manifest serialization (the exact §6.2 fixture layout).
# --------------------------------------------------------------------------- #
#
# The manifest is JSON, but with one deliberate readability convention that the
# `vaked/examples/lowering/provenance.json` fixture established and reviewers
# rely on: it is pretty-printed at a 2-space indent, EXCEPT each ``span`` object
# is rendered inline on a single line (``"span": { "file": …, "byteStart": 27,
# … }``) so an entry reads as one decl + one compact source location. Standard
# ``json.dumps(indent=2)`` would explode every span across six lines, burying the
# attribution. We therefore emit with a small, deterministic pretty-printer that
# inlines exactly the ``span`` value and pretty-prints everything else.

_SPAN_KEY = "span"


def _json_scalar(v) -> str:
    return json.dumps(v, ensure_ascii=False)


def _json_inline(v) -> str:
    """A value rendered on one line with ``", "`` / ``": "`` spacing (used for the
    ``span`` object): ``{ "file": "x", "byteStart": 27 }`` / ``[1, 2]``."""
    if isinstance(v, dict):
        if not v:
            return "{}"
        inner = ", ".join('%s: %s' % (_json_scalar(k), _json_inline(val))
                          for k, val in v.items())
        return "{ %s }" % inner
    if isinstance(v, list):
        if not v:
            return "[]"
        return "[%s]" % ", ".join(_json_inline(x) for x in v)
    return _json_scalar(v)


def _json_pretty(v, level) -> str:
    """Pretty-print ``v`` at a 2-space indent, but render any ``span`` object
    inline. Object keys keep insertion order (the §6.2 field order each entry was
    built in); list items keep order (emission order)."""
    pad = "  " * level
    pad_in = "  " * (level + 1)
    if isinstance(v, dict):
        if not v:
            return "{}"
        parts = []
        for k, val in v.items():
            if k == _SPAN_KEY:
                rendered = _json_inline(val)
            else:
                rendered = _json_pretty(val, level + 1)
            parts.append("%s%s: %s" % (pad_in, _json_scalar(k), rendered))
        return "{\n" + ",\n".join(parts) + "\n" + pad + "}"
    if isinstance(v, list):
        if not v:
            return "[]"
        parts = [pad_in + _json_pretty(x, level + 1) for x in v]
        return "[\n" + ",\n".join(parts) + "\n" + pad + "]"
    return _json_scalar(v)


def provenance_json_text(provenance_doc) -> str:
    """Serialize a provenance document (from :func:`_build_provenance`) to the
    exact §6.2 fixture bytes: 2-space indent, inline ``span`` objects, trailing
    newline. Pure and deterministic — the same document always serializes
    identically (the manifest is itself a reproducible artifact, §2.1)."""
    return _json_pretty(provenance_doc, 0) + "\n"
