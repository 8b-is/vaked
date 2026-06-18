"""vakedc.lsp — LSP 3.17 server over stdio (JSON-RPC 2.0, stdlib-only).
Capabilities:
textDocumentSync: incremental (open + change + close)
completionProvider: keyword + kind completion on space/=/{ triggers
hoverProvider: kind schema summary on identifier hover
definitionProvider: navigate to declaration span
On every open/change: parse → check → publishDiagnostics.
"""
from __future__ import annotations
import io
import json
import sys
import threading
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional
from .lexer import VakedLexError, tokenize
from .parser import VakedSyntaxError, parse_source
from .resolve import build_graph
from .check import check_source, load_builtins, default_builtins_path
def _read_message(stdin: io.RawIOBase) -> Optional[dict]:
"""Read one Content-Length framed JSON-RPC message from stdin."""
while True:
header = stdin.readline()
if not header:
return None
header = header.decode("utf-8", errors="replace").strip()
if not header.startswith("Content-Length:"):
continue
try:
length = int(header[len("Content-Length:"):].strip())
except ValueError:
continue
blank = stdin.readline()
body = stdin.read(length)
if not body:
return None
try:
return json.loads(body.decode("utf-8"))
except json.JSONDecodeError:
return None
def _write_message(stdout: io.RawIOBase, msg: dict) -> None:
body = json.dumps(msg, ensure_ascii=False).encode("utf-8")
header = f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8")
stdout.write(header + body)
stdout.flush()
_SEVERITY_MAP = {"error": 1, "warning": 2, "info": 3, "hint": 4}
def _diag_to_lsp(d: dict, uri: str) -> dict:
"""Convert a vakedc Diagnostic.as_dict() → LSP Diagnostic."""
line_0 = max(0, d.get("line", 1) - 1)
col_0 = max(0, d.get("col", 1) - 1)
span = d.get("byteEnd", d.get("byteStart", 0)) - d.get("byteStart", 0)
end_col = col_0 + max(1, span)
return {
"range": {
"start": {"line": line_0, "character": col_0},
"end": {"line": line_0, "character": end_col},
},
"severity": _SEVERITY_MAP.get(d.get("severity", "error"), 1),
"code": d.get("code", "E-UNKNOWN"),
"source": "vakedc",
"message": d.get("message", ""),
}
_KIND_KEYWORDS = [
"runtime", "input", "engine", "host", "network", "filesystem", "mcp",
"ebpf", "budget", "observability", "runclass", "workflow", "index",
"catalog", "stream", "fiber", "surface", "mesh", "device", "mediaPipeline",
"parallel", "schema", "capability", "service", "secret", "hostResource",
"ingress", "container", "memory",
]
_COMMON_FIELDS = [
"source", "normalize", "chunk", "emit", "schema", "trust",
"from", "key", "type", "retention", "fps", "engine", "input", "output",
"policy", "mode", "views", "strategy", "supervisor",
"mine", "scope", "driver", "mount", "permissions", "observe",
"fibers", "steps", "on", "use",
"field", "open", "grant", "order",
]
_REFINEMENT_WORDS = [
"required", "optional", "default", "oneof", "nonempty", "matches",
"in",
]
_BUILTINS_SUMMARY: Dict[str, str] = {
"index": "Index<T> — reproducible source of structured content.\nFields: source, normalize?, chunk?, emit, schema, trust",
"catalog": "Catalog<T> — queryable materialization of an index.\nFields: from (index ref), key, emit",
"stream": "Stream<T> — typed runtime event flow.\nFields: source, type, retention, fps?",
"fiber": "Fiber<I,O> — policy-bound execution lane.\nFields: engine, input (stream ref), output (artifact ref), policy{...}",
"surface": "Surface — operator-facing visualization/UI.\nFields: mode (raylib|...), fps?, input (list of stream/graph/catalog), views (list of view names), budget?",
"mesh": "Mesh<Node,Edge> — agent/process/tool/device topology.\nContains: node decls, -> delegation edges",
"device": "Device — hardware/driver node (open schema).\nFields: driver, mount, permissions, observe?",
"mediaPipeline": "MediaPipeline — source→stages→sink media graph (open).\nFields: source, stages, sink",
"parallel": "ParallelGroup — supervised group of fibers.\nFields: fibers (list of fiber refs), strategy, supervisor (otp)",
"workflow": "Workflow — typed agent-step DAG.\nContains: steps with on/use, -> ordering edges",
"memory": "Memory<T> — runtime-accumulated, mined, replayable store.\nFields: source (stream list), schema, mine (normalizer), scope, retention, emit",
"schema": "Schema declaration — defines a named type with field constraints.\nFields: field declarations with : type and {refinements}",
"capability": "Capability declaration — defines grant partial orders for a domain.\nFields: grant sets, order chains",
"budget": "Budget — resource bounds.\nFields: tokens, wallClock, toolCalls, fuel (optional)",
"runtime": "Runtime — top-level declaration grouping all other kinds.",
"engine": "Engine — execution engine declaration.",
"runclass": "RunClass — scheduling class for fibers.",
"service": "Service — long-running NixOS systemd service.",
"secret": "Secret — sops-managed runtime secret.",
"hostResource": "HostResource — host-managed database/resource (PostgreSQL/Redis).",
"ingress": "Ingress — Caddy HTTP reverse-proxy vhost.",
"container": "Container — OCI/Docker container.",
}
class LspServer:
def __init__(self, builtins_path: Optional[str] = None) -> None:
self._builtins_path = builtins_path or default_builtins_path()
self._builtins: Optional[Any] = None
self._docs: Dict[str, str] = {} # uri → content
self._shutdown = False
self._stdin = sys.stdin.buffer
self._stdout = sys.stdout.buffer
def _load_builtins(self) -> Any:
if self._builtins is None:
try:
self._builtins = load_builtins(self._builtins_path)
except Exception:
pass
return self._builtins
def _publish_diagnostics(self, uri: str, source: str) -> None:
diags: List[dict] = []
builtins = self._load_builtins()
if builtins is not None:
try:
raw_diags = check_source(source, uri, builtins_cache=builtins)
diags = [_diag_to_lsp(d.as_dict(), uri) for d in raw_diags]
except (VakedLexError, VakedSyntaxError) as exc:
diags = [
{
"range": {
"start": {"line": 0, "character": 0},
"end": {"line": 0, "character": 1},
},
"severity": 1,
"code": "E-PARSE",
"source": "vakedc",
"message": str(exc),
}
]
_write_message(self._stdout, {
"jsonrpc": "2.0",
"method": "textDocument/publishDiagnostics",
"params": {"uri": uri, "diagnostics": diags},
})
def _handle_initialize(self, req: dict) -> dict:
return {
"jsonrpc": "2.0",
"id": req["id"],
"result": {
"capabilities": {
"textDocumentSync": {
"openClose": True,
"change": 1, # full sync
},
"completionProvider": {
"triggerCharacters": [" ", "=", "{", "\n"],
},
"hoverProvider": True,
"definitionProvider": True,
},
"serverInfo": {
"name": "vakedc-lsp",
"version": "0.1.0",
},
},
}
def _handle_did_open(self, params: dict) -> None:
uri = params["textDocument"]["uri"]
text = params["textDocument"]["text"]
self._docs[uri] = text
threading.Thread(
target=self._publish_diagnostics, args=(uri, text), daemon=True
).start()
def _handle_did_change(self, params: dict) -> None:
uri = params["textDocument"]["uri"]
changes = params.get("contentChanges", [])
if changes:
text = changes[-1].get("text", "")
self._docs[uri] = text
threading.Thread(
target=self._publish_diagnostics, args=(uri, text), daemon=True
).start()
def _handle_did_close(self, params: dict) -> None:
uri = params["textDocument"]["uri"]
self._docs.pop(uri, None)
_write_message(self._stdout, {
"jsonrpc": "2.0",
"method": "textDocument/publishDiagnostics",
"params": {"uri": uri, "diagnostics": []},
})
def _handle_completion(self, req: dict) -> dict:
items = []
for kw in _KIND_KEYWORDS:
items.append({
"label": kw,
"kind": 14, # Keyword
"detail": _BUILTINS_SUMMARY.get(kw, f"Vaked {kw} declaration"),
"insertText": kw,
})
for field in _COMMON_FIELDS:
items.append({
"label": field,
"kind": 5, # Field
"insertText": field,
})
for word in _REFINEMENT_WORDS:
items.append({
"label": word,
"kind": 14,
"detail": f"Field refinement: {word}",
"insertText": word,
})
return {
"jsonrpc": "2.0",
"id": req["id"],
"result": {"isIncomplete": False, "items": items},
}
def _handle_hover(self, req: dict) -> dict:
params = req.get("params", {})
uri = params.get("textDocument", {}).get("uri", "")
pos = params.get("position", {})
line_0 = pos.get("line", 0)
char_0 = pos.get("character", 0)
source = self._docs.get(uri, "")
word = _word_at(source, line_0, char_0)
content = None
if word in _BUILTINS_SUMMARY:
content = {"kind": "markdown", "value": f"**{word}**\n\n{_BUILTINS_SUMMARY[word]}"}
elif word in _COMMON_FIELDS:
content = {"kind": "markdown", "value": f"`{word}` — common Vaked field"}
return {
"jsonrpc": "2.0",
"id": req["id"],
"result": {"contents": content} if content else None,
}
def _handle_definition(self, req: dict) -> dict:
params = req.get("params", {})
uri = params.get("textDocument", {}).get("uri", "")
pos = params.get("position", {})
line_0 = pos.get("line", 0)
char_0 = pos.get("character", 0)
source = self._docs.get(uri, "")
word = _word_at(source, line_0, char_0)
if word and source:
loc = _find_declaration(source, uri, word)
if loc:
return {"jsonrpc": "2.0", "id": req["id"], "result": loc}
return {"jsonrpc": "2.0", "id": req["id"], "result": None}
def run(self) -> int:
while not self._shutdown:
msg = _read_message(self._stdin)
if msg is None:
break
method = msg.get("method", "")
msg_id = msg.get("id")
params = msg.get("params", {})
if method == "initialize":
_write_message(self._stdout, self._handle_initialize(msg))
elif method == "initialized":
pass # notification, no response
elif method == "shutdown":
self._shutdown = True
_write_message(self._stdout, {"jsonrpc": "2.0", "id": msg_id, "result": None})
elif method == "exit":
break
elif method == "textDocument/didOpen":
self._handle_did_open(params)
elif method == "textDocument/didChange":
self._handle_did_change(params)
elif method == "textDocument/didClose":
self._handle_did_close(params)
elif method == "textDocument/completion":
_write_message(self._stdout, self._handle_completion(msg))
elif method == "textDocument/hover":
_write_message(self._stdout, self._handle_hover(msg))
elif method == "textDocument/definition":
_write_message(self._stdout, self._handle_definition(msg))
elif msg_id is not None:
_write_message(self._stdout, {
"jsonrpc": "2.0",
"id": msg_id,
"result": None,
})
return 0
def _word_at(source: str, line_0: int, char_0: int) -> str:
"""Extract the identifier word at the given (0-based) line/char position."""
lines = source.splitlines()
if line_0 >= len(lines):
return ""
line = lines[line_0]
if char_0 >= len(line):
return ""
lo = char_0
while lo > 0 and (line[lo - 1].isalnum() or line[lo - 1] in ("_",)):
lo -= 1
hi = char_0
while hi < len(line) and (line[hi].isalnum() or line[hi] in ("_",)):
hi += 1
return line[lo:hi]
def _find_declaration(source: str, uri: str, name: str) -> Optional[dict]:
"""Search the source for a declaration of `name` → LSP Location or None."""
try:
items = parse_source(source, uri)
for item in items:
if getattr(item, "name", None) == name:
span = getattr(item, "span", None)
if span:
line_0 = max(0, span.line - 1)
col_0 = max(0, span.col - 1)
return {
"uri": uri,
"range": {
"start": {"line": line_0, "character": col_0},
"end": {"line": line_0, "character": col_0 + len(name)},
},
}
except Exception:
pass
return None