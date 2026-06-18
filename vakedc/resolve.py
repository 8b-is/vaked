"""vakedc.resolve — build the LPG from a parsed AST (0011 pipeline stages 1-2).
Walks the top-level items, instantiating one node per declaration (with byte-exact
provenance attached immediately), maintaining a lexically-scoped symbol table, and
collecting *refs* on a worklist tagged with their edge-label semantics. At end of
parse the worklist is resolved against the scope captured at each ref site (this
handles forward refs); a ref whose HEAD resolves to no in-file declaration produces
ONE external stub node per distinct dotted path.
Edge labels (by source-field semantics — only these become edges; every other ref
in props stays a plain value, we do NOT over-edge):
contains nesting: parent decl -> child decl / node
imports a `use "<path>"` import -> external stub for the path
depends_on refs in input / output / from / source / engine fields
requires_capability refs in `capabilities` lists; target = the domain.grant ref
routes_to mesh `->` edges; the optional ":" label string as a prop
member_of refs in a `parallel`'s `fibers` list
The symbol table is lexical: a ref's head is looked up from the innermost scope
outward. Top-level decls and each decl's direct child decls/nodes are bindings.
"""
from __future__ import annotations
import os
from . import parser as P
from .graph import Graph, GraphNode, GraphEdge, Provenance, Span, node_id
_DEPENDS_FIELDS = frozenset(("input", "output", "from", "source", "engine"))
class _Scope:
"""A lexical scope: simple-name -> node id, with a parent link."""
def __init__(self, parent=None):
self.parent = parent
self.bindings: "dict[str, str]" = {}
def define(self, name: str, nid: str):
self.bindings[name] = nid
def lookup(self, name: str) -> "str | None":
s = self
while s is not None:
if name in s.bindings:
return s.bindings[name]
s = s.parent
return None
class _RefTask:
"""A deferred ref resolution captured with its lexical scope."""
__slots__ = ("ref", "label", "source_id", "scope", "partner", "edge_props")
def __init__(self, ref, label, source_id, scope, partner=None, edge_props=None):
self.ref = ref
self.label = label
self.source_id = source_id
self.scope = scope
self.partner = partner # for routes_to: the 'to' ref
self.edge_props = edge_props or {}
class Resolver:
def __init__(self, items, filename: str):
self.items = items
self.basename = os.path.basename(filename)
self.provfile = filename
self.graph = Graph(self.provfile)
self.worklist: "list[_RefTask]" = []
def build(self) -> Graph:
root = _Scope()
for it in self.items:
if isinstance(it, P.Decl):
root.define(it.name, node_id(self.basename, [it.name]))
for it in self.items:
if isinstance(it, P.Import):
self._handle_import(it)
elif isinstance(it, P.Decl):
self._build_decl(it, [it.name], root, parent_id=None)
self._resolve_worklist()
return self.graph
def _handle_import(self, imp: P.Import):
file_id = f"{self.basename}#"
if not self.graph.has_node(file_id):
self.graph.add_node(GraphNode(
id=file_id, kind="file", name=self.basename,
labels=["file"], props={}, provenance=None,
))
stub = self.graph.ensure_external(imp.path)
self.graph.add_edge(GraphEdge(file_id, stub.id, "imports"))
def _build_decl(self, decl: P.Decl, chain, scope: _Scope, parent_id):
nid = node_id(self.basename, chain)
prov = Provenance(
file=self.provfile,
decl=f"{decl.kind} {decl.name}",
span=Span(decl.byteStart, decl.byteEnd, decl.line, decl.col),
)
props = {}
if decl.signature is not None:
props["signature"] = _signature_to_props(decl.signature)
if decl.annotations:
props["annotations"] = [_annotation_to_props(a) for a in decl.annotations]
node = GraphNode(
id=nid, kind=decl.kind, name=decl.name,
labels=["decl", decl.kind], props=props, provenance=prov,
)
self.graph.add_node(node)
if parent_id is not None:
self.graph.add_edge(GraphEdge(parent_id, nid, "contains"))
child_scope = _Scope(scope)
for st in decl.body:
if isinstance(st, (P.Decl, P.NodeDecl)):
child_scope.define(st.name,
node_id(self.basename, chain + [st.name]))
self._build_body(decl, decl.body, chain, nid, child_scope)
def _build_body(self, owner, stmts, chain, owner_id, scope):
for st in stmts:
self._build_stmt(owner, st, chain, owner_id, scope)
def _build_stmt(self, owner, st, chain, owner_id, scope):
if isinstance(st, P.Decl):
self._build_decl(st, chain + [st.name], scope, parent_id=owner_id)
elif isinstance(st, P.NodeDecl):
self._build_node_decl(st, chain, owner_id, scope)
elif isinstance(st, P.Edge):
self._build_edge(st, scope, owner_id)
elif isinstance(st, P.Assignment):
self._build_assignment(owner, st, owner_id, scope)
elif isinstance(st, P.App):
pass # bare app statement: no inter-node edge, keep graph minimal
elif isinstance(st, P.FieldDecl):
self._record_prop(owner_id, "field:" + st.name, _field_to_props(st))
elif isinstance(st, P.GrantDecl):
self._append_prop_list(owner_id, "grants", st.names)
elif isinstance(st, P.OrderDecl):
self._append_prop_list(owner_id, "order", [list(c) for c in st.chains])
elif isinstance(st, P.OpenDecl):
self._record_prop(owner_id, "open", True)
elif isinstance(st, P.InheritStmt):
self._append_prop_list(owner_id, "inherit", st.names)
def _build_node_decl(self, nd: P.NodeDecl, chain, owner_id, scope):
nid = node_id(self.basename, chain + [nd.name])
prov = Provenance(
file=self.provfile,
decl=f"node {nd.name}",
span=Span(nd.byteStart, nd.byteEnd, nd.line, nd.col),
)
node = GraphNode(
id=nid, kind="node", name=nd.name,
labels=["node"], props={}, provenance=prov,
)
self.graph.add_node(node)
self.graph.add_edge(GraphEdge(owner_id, nid, "contains"))
child_scope = _Scope(scope)
for st in nd.body:
if isinstance(st, (P.Decl, P.NodeDecl)):
child_scope.define(st.name,
node_id(self.basename, chain + [nd.name, st.name]))
self._build_body(nd, nd.body, chain + [nd.name], nid, child_scope)
def _build_edge(self, edge: P.Edge, scope, owner_id):
edge_props = {"label": edge.label} if edge.label is not None else {}
for a, b in zip(edge.refs, edge.refs[1:]):
self.worklist.append(_RefTask(
a, "routes_to", owner_id, scope, partner=b, edge_props=edge_props))
def _build_assignment(self, owner, asn: P.Assignment, owner_id, scope):
target, val = asn.target, asn.value
if target in _DEPENDS_FIELDS:
self._defer_value_refs(val, "depends_on", owner_id, scope)
elif target == "fibers" and getattr(owner, "kind", None) == "parallel":
self._defer_value_refs(val, "member_of", owner_id, scope)
elif target == "capabilities":
self._defer_value_refs(val, "requires_capability", owner_id, scope)
prop_val = _value_to_props(val)
if asn.op != "=":
prop_val = {"op": asn.op, "value": prop_val}
self._record_prop(owner_id, target, prop_val)
def _defer_value_refs(self, val, label, owner_id, scope):
for r in _refs_in_value(val):
self.worklist.append(_RefTask(r, label, owner_id, scope))
def _resolve_worklist(self):
for task in self.worklist:
if task.label == "routes_to":
src = self._resolve_ref(task.ref, task.scope)
dst = self._resolve_ref(task.partner, task.scope)
self.graph.add_edge(
GraphEdge(src, dst, "routes_to", dict(task.edge_props)))
else:
tgt = self._resolve_ref(task.ref, task.scope)
self.graph.add_edge(GraphEdge(task.source_id, tgt, task.label))
def _resolve_ref(self, ref, scope: _Scope) -> str:
"""Resolve a ref to a node id; unresolvable -> external stub keyed by the
full dotted path. Forward refs work because scopes are fully populated
before the worklist runs.
Two in-file forms resolve to a declaration node:
* a bare name (``screenrec``) — looked up directly in scope;
* a ``<kind>.<name>`` ref (``stream.screenrec``, ``index.zigbeeFirmware``)
where ``kind`` is a Vaked kind keyword and ``name`` resolves in scope to
a declaration of that kind. This is the addressing convention the type/
lowering specs use (``index.zigbeeFirmware`` names the index decl).
Everything else (``graph.workflow``, ``fs.repo_rw``, ``crabcc.markdown``)
is external."""
head = ref.head
if len(ref.parts) == 1:
head_id = scope.lookup(head)
if head_id is not None:
return head_id
return self.graph.ensure_external(ref.dotted).id
if len(ref.parts) == 2 and head in P._KIND_SET:
target_id = scope.lookup(ref.parts[1])
if target_id is not None:
node = self.graph.get_node(target_id)
if node is not None and node.kind == head:
return target_id
if scope.lookup(head) is not None:
candidate = node_id(self.basename, ref.parts)
if self.graph.has_node(candidate):
return candidate
return self.graph.ensure_external(ref.dotted).id
def _record_prop(self, owner_id, key, value):
node = self.graph.get_node(owner_id)
if node is not None:
node.props[key] = value
def _append_prop_list(self, owner_id, key, values):
node = self.graph.get_node(owner_id)
if node is not None:
lst = node.props.setdefault(key, [])
lst.extend(values if isinstance(values, list) else [values])
def _value_to_props(v):
if isinstance(v, P.Literal):
return {"lit": v.kind.lower(), "value": v.value}
if isinstance(v, P.ListLit):
return [_value_to_props(x) for x in v.items]
if isinstance(v, P.RecordLit):
return {"record": [_entry_to_props(e) for e in v.entries]}
if isinstance(v, P.App):
out = {"ref": v.ref.dotted}
if v.args is not None:
out["args"] = [_value_to_props(a) for a in v.args]
if v.record is not None:
out["record"] = [_entry_to_props(e) for e in v.record]
return out
return {"unknown": repr(v)}
def _entry_to_props(e):
if isinstance(e, P.Assignment):
return {"assign": e.target, "op": e.op, "value": _value_to_props(e.value)}
if isinstance(e, P.InheritStmt):
return {"inherit": list(e.names)}
return {"unknown": repr(e)}
def _is_bare_ref(x) -> bool:
"""A *bare* ref-app: a reference to another entity, NOT a call or a config
block. `screenrec`, `stream.screenrec`, `fs.repo_rw` are bare refs;
`github("x")` and `crabcc.semantic { ... }` are applications (values), not
dependency references — so they do NOT become edges (don't over-edge)."""
return isinstance(x, P.App) and x.args is None and x.record is None
def _refs_in_value(v):
"""Yield the bare-ref dependency targets in a value: the value itself if it is
a bare ref-app, or the bare ref-app elements of a list literal. Function calls,
config-block apps, refs nested in records / call args, and literals are NOT
dependency targets (they live as plain props)."""
out = []
if _is_bare_ref(v):
out.append(v.ref)
elif isinstance(v, P.ListLit):
for x in v.items:
if _is_bare_ref(x):
out.append(x.ref)
return out
def _field_to_props(f: P.FieldDecl):
return {"type": f.type.text, "refinements": [list(r) for r in f.refinements]}
def _signature_to_props(sig):
params, ret = sig
return {
"params": [{"name": n, "type": t.text,
"default": (_value_to_props(d) if d is not None else None)}
for (n, t, d) in params],
"return": (ret.text if ret is not None else None),
}
def _annotation_to_props(a):
_, name, args = a
return {"name": name,
"args": ([_value_to_props(x) for x in args] if args is not None else None)}
def build_graph(items, filename: str) -> Graph:
return Resolver(items, filename).build()