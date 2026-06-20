#!/usr/bin/env python3
"""vaked-mlir — Vaked MLIR dialect development tool.

Subcommands for the Stage-1 MLIR dialect workflow. Run from repo root.

Usage:
  vaked-mlir check           Verify .td files are valid TableGen (needs mlir-tblgen)
  vaked-mlir current-env     Show MLIR toolchain versions and paths
  vaked-mlir validate <file> Run Stage-0 pass pipeline, validate output
  vaked-mlir passes <file>   Run vakedc passes CLI wrapper
  vaked-mlir build           Build the dialect library (nix build .#vaked-mlir)
  vaked-mlir sync <host>     Sync sources to remote and trigger build
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MLIR_DIR = os.path.join(REPO_ROOT, "vakedc/mlir")


# --------------------------------------------------------------------------- #
# Subcommands
# --------------------------------------------------------------------------- #

def cmd_check(args) -> int:
    """Verify TableGen .td files produce valid output."""
    tg = _find_mlir_tblgen()
    if tg is None:
        print("vaked-mlir: mlir-tblgen not found. Install or 'nix develop .'", file=sys.stderr)
        return 1

    td_files = [
        ("vaked dialect", os.path.join(MLIR_DIR, "VakedDialect.td")),
        ("hcp dialect",   os.path.join(MLIR_DIR, "HcpDialect.td")),
    ]
    all_ok = True
    for name, path in td_files:
        if not os.path.exists(path):
            print(f"  FAIL  {name}: {path} not found", file=sys.stderr)
            all_ok = False
            continue
        r = subprocess.run([tg, "--gen-op-defs", path],
                           capture_output=True, text=True)
        if r.returncode == 0:
            lines = r.stdout.count("\n")
            print(f"  PASS  {name}: {lines} lines generated")
        else:
            print(f"  FAIL  {name}: {r.stderr.strip()}", file=sys.stderr)
            all_ok = False

    return 0 if all_ok else 1


def cmd_current_env(args) -> int:
    """Show MLIR toolchain status."""
    tg = _find_mlir_tblgen()
    info = {
        "mlir-tblgen": tg or "not found",
        "nix mlir": _pkg_version(),
    }
    if tg:
        r = subprocess.run([tg, "--version"], capture_output=True, text=True)
        info["mlir-tblgen version"] = r.stdout.strip() or r.stderr.strip()
    print(json.dumps(info, indent=2))

    # Check .td files
    for name in ("VakedDialect.td", "HcpDialect.td"):
        path = os.path.join(MLIR_DIR, name)
        size = os.path.getsize(path) if os.path.exists(path) else 0
        print(f"  {name}: {'✓' if size else '✗'} ({size} bytes)")

    return 0


def cmd_build(args) -> int:
    """Build the dialect library via Nix."""
    r = subprocess.run(
        ["nix", "build", ".#vaked-mlir"],
        cwd=REPO_ROOT,
    )
    if r.returncode == 0:
        out = os.path.join(REPO_ROOT, "result")
        lib = os.path.join(out, "lib", "libVakedMLIRDialects.a")
        inc = os.path.join(out, "include")
        if os.path.exists(lib):
            kb = os.path.getsize(lib) // 1024
            print(f"vaked-mlir: built {lib} ({kb} KB)")
            print(f"vaked-mlir: headers in {inc}")
        else:
            print("vaked-mlir: built but output not found at result/", file=sys.stderr)
            return 1
    return r.returncode


def cmd_validate(args) -> int:
    """Run the Stage-0 pass pipeline and validate output against expected values."""
    vakedc_dir = os.path.join(REPO_ROOT, "vakedc")
    sys.path.insert(0, REPO_ROOT)
    try:
        from vakedc import parse_source, build_graph, load_builtins
        from vakedc.passes import PassPipeline as PP
    except ImportError:
        print("vaked-mlir: cannot import vakedc — run from repo root", file=sys.stderr)
        return 1

    bi_path = os.path.normpath(os.path.join(vakedc_dir, "..", "vaked", "schema", "builtins.vaked"))
    if not os.path.exists(bi_path):
        print(f"vaked-mlir: builtins not found at {bi_path}", file=sys.stderr)
        return 1

    filepath = args.file
    if not os.path.exists(filepath):
        print(f"vaked-mlir: file not found: {filepath}", file=sys.stderr)
        return 1
    with open(filepath) as f:
        src = f.read()

    try:
        bi = load_builtins(bi_path)
        items = parse_source(src, filepath)
        g = build_graph(items, filepath)
        wf_nodes = [n for n in g.nodes if n.kind == "workflow"]
        if not wf_nodes:
            print(f"vaked-mlir: no workflow declarations in {filepath}", file=sys.stderr)
            return 1
        result = PP(g, wf_nodes)
    except Exception as e:
        print(f"vaked-mlir: pass pipeline failed: {e}", file=sys.stderr)
        return 1

    # Print structured output
    output = {
        "file": filepath,
        "workflows": [
            {
                "name": w.node.name,
                "depth": w.depth,
                "criticalPath": w.critical_path,
                "steps": [s.name for s in w.steps],
                "edges": [{"from": a, "to": b} for a, b in w.edges],
                "walFrames": len(w.wal_frames),
            }
            for w in result.workflows
        ],
        "diagnostics": [{"code": d.code, "message": d.message} for d in result.diagnostics],
        "artifacts": list(result.artifacts.keys()),
        "status": "PASS" if not result.diagnostics else "FAIL",
    }
    print(json.dumps(output, indent=2))
    return 1 if result.diagnostics else 0


def cmd_passes(args) -> int:
    """Run vakedc passes CLI with the given file."""
    cmd = [sys.executable, "-m", "vakedc", "passes", args.file]
    if args.json:
        cmd.append("--json")
    if args.out:
        cmd.extend(["--out", args.out])
    r = subprocess.run(cmd, cwd=REPO_ROOT)
    return r.returncode


def cmd_sync(args) -> int:
    """Sync sources to remote host and trigger build."""
    host = args.host
    remote_path = args.remote or "/home/dev/vaked-base"

    sources = [
        "vakedc/mlir/",
        "nix/vaked-mlir.nix",
        "flake.nix",
        "flake.lock",
    ]

    print(f"Syncing MLIR sources to {host}:{remote_path} ...")
    for src in sources:
        src_path = os.path.join(REPO_ROOT, src)
        if not os.path.exists(src_path):
            print(f"  skip {src}: not found")
            continue
        r = subprocess.run(
            ["scp", "-r", src_path, f"{host}:{remote_path}/{src}"],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            print(f"  ok   {src}")
        else:
            print(f"  FAIL {src}: {r.stderr.strip()}", file=sys.stderr)

    # Trigger build on remote
    if args.build:
        print(f"Triggering build on {host}...")
        ssh_cmd = f"cd {remote_path} && nix build .#vaked-mlir 2>&1"
        r = subprocess.run(
            ["ssh", host, ssh_cmd],
        )
        return r.returncode

    return 0


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #

def _find_mlir_tblgen() -> str | None:
    """Locate mlir-tblgen on PATH or via nix."""
    for cmd in ("mlir-tblgen",):
        r = subprocess.run(["which", cmd], capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout.strip()
    # Try via nix build
    return None


def _pkg_version() -> str:
    """Check nixpkgs mlir version."""
    r = subprocess.run(
        ["nix", "eval", "nixpkgs#llvmPackages_latest.mlir.name", "--impure"],
        capture_output=True, text=True,
    )
    return r.stdout.strip() or "nix eval failed"


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="vaked-mlir",
        description="Vaked MLIR dialect development tool",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("check", help="validate TableGen .td files")
    sub.add_parser("current-env", help="show MLIR toolchain status")

    validate_p = sub.add_parser("validate",
        help="run Stage-0 pass pipeline and validate output")
    validate_p.add_argument("file", help="path to a .vaked file")

    passes_p = sub.add_parser("passes",
        help="run vakedc passes CLI")
    passes_p.add_argument("file", help="path to a .vaked file")
    passes_p.add_argument("--json", action="store_true",
                          help="emit structured JSON output")
    passes_p.add_argument("--out", metavar="DIR",
                          help="output directory for artifacts")

    build_p = sub.add_parser("build", help="build via nix build .#vaked-mlir")
    build_p.add_argument("--check", action="store_true",
                         help="run TableGen check before building")

    sync_p = sub.add_parser("sync", help="sync sources to remote and build")
    sync_p.add_argument("host", help="remote host (user@host)")
    sync_p.add_argument("--remote", default="/home/dev/vaked-base",
                        help="remote path (default: /home/dev/vaked-base)")
    sync_p.add_argument("--build", action="store_true",
                        help="trigger build after sync")

    args = ap.parse_args(argv)

    dispatch = {
        "check": cmd_check,
        "current-env": cmd_current_env,
        "validate": cmd_validate,
        "passes": cmd_passes,
        "build": cmd_build,
        "sync": cmd_sync,
    }
    return dispatch[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
