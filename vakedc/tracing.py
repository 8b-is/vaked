"""Optional Langfuse instrumentation for the vakedc compiler pipeline.
Zero-cost when Langfuse is not configured: this module is always importable
and every function is a no-op when the client is absent. Same lazy-guard
pattern as tools/ralph/ralph.py:109-133.
Enable with:
pip install langfuse
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
export LANGFUSE_HOST=https://langfuse.crabcc.app
"""
from __future__ import annotations
import os
from collections import Counter
from contextlib import contextmanager
try:
from langfuse import Langfuse as _Langfuse
except Exception:
_Langfuse = None
_LF_CLIENT = None
_LF_INIT = False
def _langfuse():
"""Langfuse client, or None when tracing is unavailable/unconfigured."""
global _LF_CLIENT, _LF_INIT
if not _LF_INIT:
_LF_INIT = True
if _Langfuse is not None and os.environ.get("LANGFUSE_PUBLIC_KEY"):
try:
_LF_CLIENT = _Langfuse()
except Exception:
_LF_CLIENT = None
return _LF_CLIENT
def _flush() -> None:
client = _langfuse()
if client is not None:
try:
client.flush()
except Exception:
pass
@contextmanager
def trace_compile(cmd: str, file: str):
"""Context manager wrapping a compile command in a Langfuse trace.
Yields the trace object (or None when Langfuse is off) so callers can
annotate it with record_* helpers. The trace is flushed on exit.
"""
client = _langfuse()
if client is None:
yield None
return
basename = os.path.basename(file)
try:
file_bytes = os.path.getsize(file)
except OSError:
file_bytes = 0
trace = client.trace(
name=f"vakedc.{cmd}",
tags=["vaked", "compiler", cmd],
metadata={"file": basename, "file_bytes": file_bytes, "cmd": cmd},
)
try:
yield trace
except Exception as e:
try:
trace.update(level="ERROR", status_message=f"{type(e).__name__}: {e}")
except Exception:
pass
raise
finally:
_flush()
def record_parse(trace, items: list, elapsed_ms: float) -> None:
"""Record parse-stage metrics (AST item count, timing)."""
if trace is None:
return
try:
trace.update(metadata={"ast_items": len(items), "parse_ms": round(elapsed_ms, 1)})
except Exception:
pass
def record_check(trace, diags: list, elapsed_ms: float) -> None:
"""Record check-stage metrics (diagnostic count and error code histogram)."""
if trace is None:
return
try:
hist = dict(Counter(d.code for d in diags))
meta: dict = {"diag_count": len(diags), "check_ms": round(elapsed_ms, 1)}
if hist:
meta["diag_codes"] = hist
kwargs: dict = {}
if diags:
kwargs["level"] = "WARNING"
kwargs["status_message"] = f"{len(diags)} diagnostic{'s' if len(diags) != 1 else ''}"
trace.update(metadata=meta, **kwargs)
except Exception:
pass
def record_error(trace, exc: Exception) -> None:
"""Mark a trace ERROR for caught exceptions that cause an early return."""
if trace is None:
return
try:
trace.update(level="ERROR", status_message=f"{type(exc).__name__}: {exc}")
except Exception:
pass
def record_lower(trace, artifact_count: int, elapsed_ms: float) -> None:
"""Record lower-stage metrics (artifact count, timing)."""
if trace is None:
return
try:
trace.update(metadata={"artifacts": artifact_count, "lower_ms": round(elapsed_ms, 1)})
except Exception:
pass