const std = @import("std");
const p = @import("parser.zig");
const lex = @import("lexer.zig");
pub const Span = struct { byte_start: usize, byte_end: usize, line: usize, col: usize };
pub const Related = struct {
file: []const u8,
decl: []const u8,
span: Span,
message: []const u8,
};
pub const Diagnostic = struct {
code: []const u8,
message: []const u8,
file: []const u8,
line: usize,
col: usize,
byte_start: usize,
byte_end: usize,
decl: []const u8,
severity: []const u8 = "error",
related: []const Related,
};
fn diagLessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
const fc = std.mem.order(u8, a.file, b.file);
if (fc != .eq) return fc == .lt;
if (a.byte_start != b.byte_start) return a.byte_start < b.byte_start;
if (a.byte_end != b.byte_end) return a.byte_end < b.byte_end;
return std.mem.lessThan(u8, a.code, b.code);
}
const SourceMap = struct {
tokens: []const lex.Token,
starts: []const usize,
fn init(a: std.mem.Allocator, src: []const u8, filename: []const u8) !SourceMap {
var lx = lex.Lexer.init(a, src);
lx.run() catch {};
var toks = std.array_list.Managed(lex.Token).init(a);
for (lx.tokens.items) |t| {
if (t.kind != .newline and t.kind != .eof) try toks.append(t);
}
_ = filename;
const owned = try toks.toOwnedSlice();
var starts = try a.alloc(usize, owned.len);
for (owned, 0..) |t, i| starts[i] = t.byte_start;
return .{ .tokens = owned, .starts = starts };
}
fn toksIn(self: SourceMap, byte_start: usize, byte_end: usize) []const lex.Token {
var lo: usize = 0;
var hi: usize = self.starts.len;
while (lo < hi) {
const mid = lo + (hi - lo) / 2;
if (self.starts[mid] < byte_start) lo = mid + 1 else hi = mid;
}
const from = lo;
lo = 0;
hi = self.starts.len;
while (lo < hi) {
const mid = lo + (hi - lo) / 2;
if (self.starts[mid] < byte_end) lo = mid + 1 else hi = mid;
}
return self.tokens[from..lo];
}
fn fieldNameSpan(self: SourceMap, ds: usize, de: usize, name: []const u8) ?Span {
const toks = self.toksIn(ds, de);
for (toks, 0..) |t, idx| {
if (t.kind == .ident and std.mem.eql(u8, t.value, name)) {
if (idx + 1 >= toks.len) continue;
const nxt = toks[idx + 1];
if (nxt.kind == .op and (std.mem.eql(u8, nxt.value, "=") or
std.mem.eql(u8, nxt.value, "?=") or
std.mem.eql(u8, nxt.value, ":") or
std.mem.eql(u8, nxt.value, "{")))
{
return .{ .byte_start = t.byte_start, .byte_end = t.byte_end, .line = t.line, .col = t.col };
}
}
}
return null;
}
fn fieldValueSpan(self: SourceMap, ds: usize, de: usize, name: []const u8) ?Span {
const toks = self.toksIn(ds, de);
for (toks, 0..) |t, idx| {
if (t.kind == .ident and std.mem.eql(u8, t.value, name)) {
if (idx + 1 >= toks.len) continue;
const nxt = toks[idx + 1];
if (nxt.kind == .op and (std.mem.eql(u8, nxt.value, "=") or std.mem.eql(u8, nxt.value, "?="))) {
if (idx + 2 < toks.len) {
const val = toks[idx + 2];
return .{ .byte_start = val.byte_start, .byte_end = val.byte_end, .line = val.line, .col = val.col };
}
}
}
}
return self.fieldNameSpan(ds, de, name);
}
fn declKwSpan(self: SourceMap, d: *const p.Decl) ?Span {
const toks = self.toksIn(d.byte_start, d.byte_end);
for (toks) |t| {
if (t.kind == .ident and std.mem.eql(u8, t.value, d.kind)) {
return .{ .byte_start = t.byte_start, .byte_end = t.byte_end, .line = t.line, .col = t.col };
}
}
return null;
}
};
const SCALARS = [_][]const u8{ "String", "Int", "Float", "Bool", "Path", "Duration", "Bytes", "Null" };
const STRING_ALIASES = [_][]const u8{ "Strategy", "View" };
fn isScalar(s: []const u8) bool {
for (SCALARS) |sc| if (std.mem.eql(u8, s, sc)) return true;
return false;
}
fn isStringAlias(s: []const u8) bool {
for (STRING_ALIASES) |sa| if (std.mem.eql(u8, s, sa)) return true;
return false;
}
fn isGenericParam(s: []const u8) bool {
if (std.mem.eql(u8, s, "Node") or std.mem.eql(u8, s, "Edge")) return true;
if (s.len == 1 and std.ascii.isAlphabetic(s[0]) and std.ascii.isUpper(s[0])) return true;
return false;
}
fn isNumericType(type_text: []const u8) bool {
const inner = baseType(type_text);
return std.mem.eql(u8, inner, "Int") or std.mem.eql(u8, inner, "Float") or
std.mem.eql(u8, inner, "Duration") or std.mem.eql(u8, inner, "Bytes");
}
fn isList(type_text: []const u8) bool {
const t = std.mem.trim(u8, type_text, " \t");
return std.mem.startsWith(u8, t, "List<") and std.mem.endsWith(u8, t, ">");
}
fn baseType(type_text: []const u8) []const u8 {
const t = std.mem.trim(u8, type_text, " \t");
if (std.mem.startsWith(u8, t, "List<") and std.mem.endsWith(u8, t, ">")) {
return std.mem.trim(u8, t[5 .. t.len - 1], " \t");
}
return t;
}
fn splitUnion(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
var parts = std.array_list.Managed([]const u8).init(a);
var depth: usize = 0;
var cur = std.array_list.Managed(u8).init(a);
for (text) |ch| {
switch (ch) {
'<' => { depth += 1; try cur.append(ch); },
'>' => { if (depth > 0) depth -= 1; try cur.append(ch); },
'|' => if (depth == 0) {
try parts.append(std.mem.trim(u8, try cur.toOwnedSlice(), " \t"));
cur = std.array_list.Managed(u8).init(a);
} else try cur.append(ch),
else => try cur.append(ch),
}
}
try parts.append(std.mem.trim(u8, try cur.toOwnedSlice(), " \t"));
return parts.toOwnedSlice();
}
const Presence = enum { required, optional };
const FieldSpec = struct {
name: []const u8,
type_text: []const u8,
refinements: []const p.Refinement,
presence: Presence,
has_default: bool,
};
const SchemaSpec = struct {
name: []const u8,
fields: std.StringHashMap(FieldSpec),
open: bool,
origin_file: []const u8,
decl_span: Span,
};
const CapabilitySpec = struct {
domain: []const u8,
grants: std.StringHashMap(void),
order_chains: []const []const []const u8,
leq: std.StringHashMap(std.StringHashMap(void)),
origin_file: []const u8,
decl_span: Span,
};
fn presenceOf(refs: []const p.Refinement) struct { presence: Presence, has_default: bool } {
var has_default = false;
var has_optional = false;
for (refs) |r| {
switch (r) {
.default => has_default = true,
.optional => has_optional = true,
else => {},
}
}
if (has_optional or has_default) return .{ .presence = .optional, .has_default = has_default };
return .{ .presence = .required, .has_default = false };
}
fn schemaFromDecl(a: std.mem.Allocator, d: *const p.Decl, filename: []const u8) !SchemaSpec {
var fields = std.StringHashMap(FieldSpec).init(a);
var is_open = false;
for (d.body) |st| {
switch (st) {
.field => |fd| {
const pres = presenceOf(fd.refinements);
try fields.put(fd.name, .{
.name = fd.name,
.type_text = fd.type_text,
.refinements = fd.refinements,
.presence = pres.presence,
.has_default = pres.has_default,
});
},
.open => is_open = true,
else => {},
}
}
return .{
.name = d.name,
.fields = fields,
.open = is_open,
.origin_file = filename,
.decl_span = .{ .byte_start = d.byte_start, .byte_end = d.byte_end, .line = d.line, .col = d.col },
};
}
fn capabilityFromDecl(a: std.mem.Allocator, d: *const p.Decl, filename: []const u8) !CapabilitySpec {
var grants = std.StringHashMap(void).init(a);
var chains = std.array_list.Managed([]const []const u8).init(a);
for (d.body) |st| {
switch (st) {
.grant => |names| for (names) |n| try grants.put(n, {}),
.order => |chs| for (chs) |ch| try chains.append(ch),
else => {},
}
}
return .{
.domain = d.name,
.grants = grants,
.order_chains = try chains.toOwnedSlice(),
.leq = std.StringHashMap(std.StringHashMap(void)).init(a),
.origin_file = filename,
.decl_span = .{ .byte_start = d.byte_start, .byte_end = d.byte_end, .line = d.line, .col = d.col },
};
}
fn transitiveClosureFill(a: std.mem.Allocator, cap: *CapabilitySpec) !?[2][]const u8 {
var succ = std.StringHashMap(std.array_list.Managed([]const u8)).init(a);
{
var git = cap.grants.keyIterator();
while (git.next()) |k| try succ.put(k.*, std.array_list.Managed([]const u8).init(a));
}
for (cap.order_chains) |ch| {
var i: usize = 0;
while (i + 1 < ch.len) : (i += 1) {
const aa = ch[i];
const bb = ch[i + 1];
{
const entry = try succ.getOrPut(aa);
if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed([]const u8).init(a);
try entry.value_ptr.append(bb);
}
{
const entry = try succ.getOrPut(bb);
if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed([]const u8).init(a);
}
}
}
var reach = std.StringHashMap(std.StringHashMap(void)).init(a);
{
var kit = succ.keyIterator();
while (kit.next()) |k| {
var s = std.StringHashMap(void).init(a);
try s.put(k.*, {});
try reach.put(k.*, s);
}
}
{
var kit = succ.keyIterator();
while (kit.next()) |k| {
var stack = std.array_list.Managed([]const u8).init(a);
if (succ.get(k.*)) |sl| for (sl.items) |x| try stack.append(x);
const r = reach.getPtr(k.*).?;
while (stack.items.len > 0) {
const x = stack.pop().?;
if (!r.contains(x)) {
try r.put(x, {});
if (succ.get(x)) |sl| for (sl.items) |y| try stack.append(y);
}
}
}
}
{
var kit = succ.iterator();
while (kit.next()) |e| {
for (e.value_ptr.items) |x| {
if (std.mem.eql(u8, x, e.key_ptr.*)) return [2][]const u8{ e.key_ptr.*, e.key_ptr.* };
}
}
}
{
var rit = reach.iterator();
while (rit.next()) |e| {
const aa = e.key_ptr.*;
var vit = e.value_ptr.keyIterator();
while (vit.next()) |bp| {
const bb = bp.*;
if (std.mem.eql(u8, aa, bb)) continue;
if (reach.get(bb)) |rbb| {
if (rbb.contains(aa)) return [2][]const u8{ aa, bb };
}
}
}
}
var git2 = reach.iterator();
while (git2.next()) |e| try cap.leq.put(e.key_ptr.*, e.value_ptr.*);
return null;
}
const Registry = struct {
schemas: std.StringHashMap(SchemaSpec),
caps: std.StringHashMap(CapabilitySpec),
fn init(a: std.mem.Allocator) Registry {
return .{ .schemas = std.StringHashMap(SchemaSpec).init(a), .caps = std.StringHashMap(CapabilitySpec).init(a) };
}
};
fn loadDeclsInto(a: std.mem.Allocator, reg: *Registry, items: []const p.Item, filename: []const u8) !void {
for (items) |it| {
if (it != .decl) continue;
const d = it.decl;
if (std.mem.eql(u8, d.kind, "schema")) {
try reg.schemas.put(d.name, try schemaFromDecl(a, d, filename));
} else if (std.mem.eql(u8, d.kind, "capability")) {
try reg.caps.put(d.name, try capabilityFromDecl(a, d, filename));
}
}
}
fn regexDialectError(regex_literal: []const u8) ?[]const u8 {
var body = regex_literal;
if (body.len >= 2 and body[0] == '/' and body[body.len - 1] == '/') body = body[1 .. body.len - 1];
var i: usize = 0;
var in_class = false;
while (i < body.len) {
const c = body[i];
if (c == '\\') {
if (i + 1 >= body.len) return "trailing backslash";
const nxt = body[i + 1];
if (nxt >= '1' and nxt <= '9') return "backreference is not in the bounded dialect";
i += 2; continue;
}
if (in_class) { if (c == ']') in_class = false; i += 1; continue; }
if (c == '[') { in_class = true; i += 1; continue; }
if (c == '(') {
if (i + 1 < body.len and body[i + 1] == '?') {
const kind_: u8 = if (i + 2 < body.len) body[i + 2] else 0;
if (kind_ == '=' or kind_ == '!') return "lookahead is not in the bounded dialect";
if (kind_ == '<') {
const nxt2: u8 = if (i + 3 < body.len) body[i + 3] else 0;
if (nxt2 == '=' or nxt2 == '!') return "lookbehind is not in the bounded dialect";
return "named group is not in the bounded dialect";
}
if (kind_ == 'P') return "named group is not in the bounded dialect";
if (kind_ == '>') return "atomic group is not in the bounded dialect";
if (kind_ == ':') { i += 3; continue; }
return "extended group is not in the bounded dialect";
}
i += 1; continue;
}
i += 1;
}
if (in_class) return "unterminated character class '['";
return null;
}
const VProp = union(enum) {
lit: struct { kind: []const u8, value: []const u8 },
ref: struct { dotted: []const u8 },
nonscalar_ref: struct { dotted: []const u8 },
list: []const VProp,
record: []const VRecordEntry,
other,
const VRecordEntry = struct {
key: ?[]const u8,
value: ?VProp,
};
};
fn exprToVProp(a: std.mem.Allocator, e: p.Expr) error{OutOfMemory}!VProp {
switch (e) {
.literal => |lit| {
const kind = switch (lit.kind) {
.string => "STRING",
.number => "number",
.bool => "BOOL",
.path => "PATH",
.duration => "DURATION",
.bytes => "BYTES",
.null => "NULL",
};
return .{ .lit = .{ .kind = kind, .value = lit.value } };
},
.list => |items| {
var out = try a.alloc(VProp, items.len);
for (items, 0..) |item, i| out[i] = try exprToVProp(a, item);
return .{ .list = out };
},
.record => |entries| {
var out = std.array_list.Managed(VProp.VRecordEntry).init(a);
for (entries) |ent| {
switch (ent) {
.assign => |asn| {
const v = try exprToVProp(a, asn.value.*);
try out.append(.{ .key = asn.target, .value = v });
},
.inherit => try out.append(.{ .key = null, .value = null }),
}
}
return .{ .record = try out.toOwnedSlice() };
},
.app => |app| {
const dotted = try std.mem.join(a, ".", app.ref.parts);
if (app.args == null and app.record == null) return .{ .ref = .{ .dotted = dotted } };
return .{ .nonscalar_ref = .{ .dotted = dotted } };
},
}
}
fn litKindMatchesScalar(kind: []const u8, value: []const u8, atom: []const u8) bool {
if (isGenericParam(atom)) return true;
if (isStringAlias(atom)) return std.mem.eql(u8, kind, "STRING");
if (!isScalar(atom)) return false;
if (std.mem.eql(u8, atom, "Null")) return std.mem.eql(u8, kind, "NULL");
if (std.mem.eql(u8, atom, "String")) return std.mem.eql(u8, kind, "STRING");
if (std.mem.eql(u8, atom, "Bool")) return std.mem.eql(u8, kind, "BOOL");
if (std.mem.eql(u8, atom, "Int")) return std.mem.eql(u8, kind, "number") and std.mem.indexOf(u8, value, ".") == null;
if (std.mem.eql(u8, atom, "Float")) return std.mem.eql(u8, kind, "number");
if (std.mem.eql(u8, atom, "Path")) return std.mem.eql(u8, kind, "PATH") or std.mem.eql(u8, kind, "STRING");
if (std.mem.eql(u8, atom, "Duration")) return std.mem.eql(u8, kind, "DURATION") or std.mem.eql(u8, kind, "STRING");
if (std.mem.eql(u8, atom, "Bytes")) return std.mem.eql(u8, kind, "BYTES") or std.mem.eql(u8, kind, "STRING");
return false;
}
fn vpropMatchesType(a: std.mem.Allocator, vprop: VProp, type_text: []const u8, reg: ?*Registry) bool {
if (isList(type_text)) {
switch (vprop) {
.list => |items| {
const inner = baseType(type_text);
for (items) |item| if (!vpropMatchesType(a, item, inner, reg)) return false;
return true;
},
else => return false,
}
}
const arms = splitUnion(a, type_text) catch return true;
for (arms) |arm| if (vpropMatchesAtom(a, vprop, arm, reg)) return true;
return false;
}
fn vpropMatchesAtom(a: std.mem.Allocator, vprop: VProp, atom: []const u8, reg: ?*Registry) bool {
const atom_t = std.mem.trim(u8, atom, " \t");
if (isList(atom_t)) return vpropMatchesType(a, vprop, atom_t, reg);
const base = baseType(atom_t);
if (isGenericParam(base)) return true;
switch (vprop) {
.lit => |lv| return litKindMatchesScalar(lv.kind, lv.value, base),
.list => return false,
.ref, .nonscalar_ref => {
if (isScalar(base) or isStringAlias(base)) return false;
return true;
},
.record => |entries| {
if (isScalar(base) or isStringAlias(base)) return false;
if (reg) |r| {
if (r.schemas.get(base)) |schema| return recordConforms(a, entries, schema, r);
}
return true;
},
.other => return true,
}
}
fn recordConforms(a: std.mem.Allocator, entries: []const VProp.VRecordEntry, schema: SchemaSpec, reg: *Registry) bool {
var present = std.StringHashMap(VProp).init(a);
defer present.deinit();
for (entries) |e| {
if (e.key) |k| if (e.value) |v| present.put(k, v) catch {};
}
var fit = schema.fields.valueIterator();
while (fit.next()) |f| {
if (f.presence == .required and !present.contains(f.name)) return false;
}
if (!schema.open) {
var pit = present.keyIterator();
while (pit.next()) |k| if (!schema.fields.contains(k.*)) return false;
}
var pit2 = present.iterator();
while (pit2.next()) |kv| {
if (schema.fields.get(kv.key_ptr.*)) |f| {
if (!vpropMatchesType(a, kv.value_ptr.*, f.type_text, reg)) return false;
}
}
return true;
}
fn parseNum(s: []const u8) ?f64 {
return std.fmt.parseFloat(f64, s) catch null;
}
fn vpropNumber(vprop: VProp) ?f64 {
switch (vprop) {
.lit => |lv| if (std.mem.eql(u8, lv.kind, "number")) return parseNum(lv.value),
else => {},
}
return null;
}
fn fmtNum(a: std.mem.Allocator, v: f64) ![]const u8 {
if (v == @trunc(v) and @abs(v) < 1e15) return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(v))});
return std.fmt.allocPrint(a, "{d}", .{v});
}
fn renderVProp(a: std.mem.Allocator, vprop: VProp) ![]const u8 {
switch (vprop) {
.lit => |lv| {
if (std.mem.eql(u8, lv.kind, "STRING")) return std.fmt.allocPrint(a, "\"{s}\"", .{lv.value});
return a.dupe(u8, lv.value);
},
.ref => |rv| return a.dupe(u8, rv.dotted),
.nonscalar_ref => |rv| return a.dupe(u8, rv.dotted),
else => return a.dupe(u8, "<value>"),
}
}
fn emit(a: std.mem.Allocator, diags: *std.array_list.Managed(Diagnostic), code: []const u8, file: []const u8, span: Span, decl_lbl: []const u8, message: []const u8) !void {
_ = a;
try diags.append(.{
.code = code, .message = message, .file = file,
.line = span.line, .col = span.col,
.byte_start = span.byte_start, .byte_end = span.byte_end,
.decl = decl_lbl, .severity = "error", .related = &.{},
});
}
fn emitWithRelated(a: std.mem.Allocator, diags: *std.array_list.Managed(Diagnostic), code: []const u8, file: []const u8, span: Span, decl_lbl: []const u8, message: []const u8, related: []const Related) !void {
_ = a;
try diags.append(.{
.code = code, .message = message, .file = file,
.line = span.line, .col = span.col,
.byte_start = span.byte_start, .byte_end = span.byte_end,
.decl = decl_lbl, .severity = "error", .related = related,
});
}
fn checkSchemaWellformed(a: std.mem.Allocator, spec: SchemaSpec, smap_opt: ?*const SourceMap, diags: *std.array_list.Managed(Diagnostic)) !void {
const ds = spec.decl_span.byte_start;
const de = spec.decl_span.byte_end;
const default_span = spec.decl_span;
const label = try std.fmt.allocPrint(a, "schema {s}", .{spec.name});
var fit = spec.fields.iterator();
while (fit.next()) |kv| {
const fname = kv.key_ptr.*;
const f = kv.value_ptr.*;
var seen_required = false;
var seen_optional = false;
for (f.refinements) |r| {
const span = if (smap_opt) |smap| smap.fieldNameSpan(ds, de, fname) orelse default_span else default_span;
switch (r) {
.required => seen_required = true,
.optional => seen_optional = true,
.matches => |rx| {
const inner_base = baseType(f.type_text);
if (!std.mem.eql(u8, inner_base, "String") and !std.mem.eql(u8, inner_base, "Path")) {
const msg = try std.fmt.allocPrint(a, "`matches` applies only to String or Path; field `{s}` is `{s}`", .{ fname, f.type_text });
try emit(a, diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, label, msg);
} else if (regexDialectError(rx)) |err| {
const msg = try std.fmt.allocPrint(a, "field `{s}`: {s}", .{ fname, err });
try emit(a, diags, "E-SCHEMA-BAD-REGEX", spec.origin_file, span, label, msg);
}
},
.oneof => |items| {
if (items.len < 1) {
const msg = try std.fmt.allocPrint(a, "field `{s}`: `oneof` needs at least one element", .{fname});
try emit(a, diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, label, msg);
}
for (items) |lit_expr| {
const vprop = try exprToVProp(a, lit_expr);
if (!vpropMatchesType(a, vprop, f.type_text, null)) {
const rv = try renderVProp(a, vprop);
const msg = try std.fmt.allocPrint(a, "field `{s}`: `oneof` element {s} does not match type `{s}`", .{ fname, rv, f.type_text });
try emit(a, diags, "E-SCHEMA-BAD-ONEOF", spec.origin_file, span, label, msg);
}
}
},
.cmp => {
if (!isNumericType(f.type_text)) {
const msg = try std.fmt.allocPrint(a, "field `{s}`: numeric refinement on non-numeric type `{s}`", .{ fname, f.type_text });
try emit(a, diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, label, msg);
}
},
.range => |rng| {
if (!isNumericType(f.type_text)) {
const msg = try std.fmt.allocPrint(a, "field `{s}`: numeric refinement on non-numeric type `{s}`", .{ fname, f.type_text });
try emit(a, diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, label, msg);
}
const lo = parseNum(rng.lo);
const hi = parseNum(rng.hi);
if (lo != null and hi != null and lo.? > hi.?) {
const msg = try std.fmt.allocPrint(a, "field `{s}`: range lower bound {s} exceeds upper bound {s}", .{ fname, rng.lo, rng.hi });
try emit(a, diags, "E-SCHEMA-BAD-RANGE", spec.origin_file, span, label, msg);
}
},
.default => |dexpr| {
const vprop = try exprToVProp(a, dexpr.*);
switch (vprop) {
.ref, .nonscalar_ref => {
const msg = try std.fmt.allocPrint(a, "field `{s}`: `default` must be a literal, not a ref", .{fname});
try emit(a, diags, "E-SCHEMA-BAD-DEFAULT", spec.origin_file, span, label, msg);
},
.lit => {
if (!vpropMatchesType(a, vprop, f.type_text, null)) {
const rv = try renderVProp(a, vprop);
const msg = try std.fmt.allocPrint(a, "field `{s}`: default {s} does not match type `{s}`", .{ fname, rv, f.type_text });
try emit(a, diags, "E-SCHEMA-BAD-DEFAULT", spec.origin_file, span, label, msg);
}
},
else => {},
}
},
.nonempty => {},
}
}
if (seen_required and (seen_optional or f.has_default)) {
const span = if (smap_opt) |smap| smap.fieldNameSpan(ds, de, fname) orelse default_span else default_span;
const msg = try std.fmt.allocPrint(a, "field `{s}`: `required` cannot be combined with `optional`/`default`", .{fname});
try emit(a, diags, "E-SCHEMA-REFINEMENT", spec.origin_file, span, label, msg);
}
}
}
fn checkCapabilityWellformed(a: std.mem.Allocator, spec: *CapabilitySpec, smap_opt: ?*const SourceMap, diags: *std.array_list.Managed(Diagnostic)) !void {
const ds = spec.decl_span.byte_start;
const de = spec.decl_span.byte_end;
const span = spec.decl_span;
const label = try std.fmt.allocPrint(a, "capability {s}", .{spec.domain});
for (spec.order_chains) |ch| {
for (ch) |g| {
if (!spec.grants.contains(g)) {
const gs = if (smap_opt) |smap| smap.fieldNameSpan(ds, de, g) orelse span else span;
const msg = try std.fmt.allocPrint(a,
"capability `{s}`: order names grant `{s}` which is not declared by a `grant` statement",
.{ spec.domain, g });
try emit(a, diags, "E-CAP-ORDER-DANGLING", spec.origin_file, gs, label, msg);
}
}
}
const cyc = try transitiveClosureFill(a, spec);
if (cyc) |cc| {
const msg = try std.fmt.allocPrint(a,
"capability `{s}`: order is cyclic (`{s}` and `{s}` are mutually ≤) — the relation must be a partial order",
.{ spec.domain, cc[0], cc[1] });
try emit(a, diags, "E-CAP-ORDER-CYCLE", spec.origin_file, span, label, msg);
var git = spec.grants.keyIterator();
while (git.next()) |k| {
var s = std.StringHashMap(void).init(a);
try s.put(k.*, {});
try spec.leq.put(k.*, s);
}
}
}
fn checkFieldConstraints(a: std.mem.Allocator, vprop: VProp, fspec: FieldSpec, smap_opt: ?*const SourceMap, ds: usize, de: usize, decl_span: Span, file: []const u8, decl_lbl: []const u8, diags: *std.array_list.Managed(Diagnostic)) !void {
const vspan = if (smap_opt) |sm| sm.fieldValueSpan(ds, de, fspec.name) orelse decl_span else decl_span;
for (fspec.refinements) |r| {
switch (r) {
.nonempty => {
const empty = switch (vprop) {
.list => |items| items.len == 0,
.lit => |lv| lv.value.len == 0,
else => false,
};
if (empty) {
const msg = try std.fmt.allocPrint(a, "field `{s}` is `nonempty` but the value is empty", .{fspec.name});
try emit(a, diags, "E-CONSTRAINT-NONEMPTY", file, vspan, decl_lbl, msg);
}
},
.oneof => |items| {
switch (vprop) {
.lit => |lv| {
var found = false;
for (items) |item| {
const iv = try exprToVProp(a, item);
switch (iv) {
.lit => |ilv| {
if (std.mem.eql(u8, ilv.kind, lv.kind) and std.mem.eql(u8, ilv.value, lv.value)) { found = true; break; }
if (std.mem.eql(u8, ilv.kind, "number") and std.mem.eql(u8, lv.kind, "number")) {
if (parseNum(ilv.value)) |iv_n| if (parseNum(lv.value)) |lv_n| if (iv_n == lv_n) { found = true; break; };
}
},
else => {},
}
}
if (!found) {
const rv = try renderVProp(a, vprop);
var parts = std.array_list.Managed(u8).init(a);
try parts.append('[');
for (items, 0..) |item, idx| {
if (idx != 0) try parts.appendSlice(", ");
const iv = try exprToVProp(a, item);
try parts.appendSlice(try renderVProp(a, iv));
}
try parts.append(']');
const msg = try std.fmt.allocPrint(a, "field `{s}`: value {s} is not one of {s}", .{ fspec.name, rv, parts.items });
try emit(a, diags, "E-CONSTRAINT-ONEOF", file, vspan, decl_lbl, msg);
}
},
else => {},
}
},
.cmp => |cmpv| {
if (vpropNumber(vprop)) |v| {
if (parseNum(cmpv.num)) |b| {
const ok = if (std.mem.eql(u8, cmpv.op, ">=")) v >= b
else if (std.mem.eql(u8, cmpv.op, "<=")) v <= b
else if (std.mem.eql(u8, cmpv.op, ">")) v > b
else if (std.mem.eql(u8, cmpv.op, "<")) v < b
else true;
if (!ok) {
const fv = try fmtNum(a, v);
const msg = try std.fmt.allocPrint(a, "field `{s}`: value {s} violates `{s} {s}`", .{ fspec.name, fv, cmpv.op, cmpv.num });
try emit(a, diags, "E-CONSTRAINT-RANGE", file, vspan, decl_lbl, msg);
}
}
}
},
.range => |rng| {
if (vpropNumber(vprop)) |v| {
const lo = parseNum(rng.lo);
const hi = parseNum(rng.hi);
if (lo != null and hi != null and !(lo.? <= v and v <= hi.?)) {
const fv = try fmtNum(a, v);
const msg = try std.fmt.allocPrint(a, "field `{s}`: value {s} is outside `in {s} .. {s}`", .{ fspec.name, fv, rng.lo, rng.hi });
try emit(a, diags, "E-CONSTRAINT-RANGE", file, vspan, decl_lbl, msg);
}
}
},
.matches => {},
else => {},
}
}
}
fn checkMatches(a: std.mem.Allocator, vprop: VProp, rx: []const u8, fname: []const u8, vspan: Span, file: []const u8, decl_lbl: []const u8, diags: *std.array_list.Managed(Diagnostic)) !void {
_ = a; _ = vprop; _ = rx; _ = fname; _ = vspan; _ = file; _ = decl_lbl; _ = diags;
}
const Bindings = struct {
map: std.StringHashMap(VProp),
order: std.array_list.Managed([]const u8),
fn init(a: std.mem.Allocator) Bindings {
return .{ .map = std.StringHashMap(VProp).init(a), .order = std.array_list.Managed([]const u8).init(a) };
}
};
fn declFieldBindings(a: std.mem.Allocator, d: *const p.Decl) !Bindings {
var b = Bindings.init(a);
for (d.body) |st| {
switch (st) {
.assign => |asn| {
try b.map.put(asn.target, try exprToVProp(a, asn.value.*));
try b.order.append(asn.target);
},
.app => |app| {
if (app.args == null and app.record != null and app.ref.parts.len == 1) {
const name_ = app.ref.parts[0];
var rec_entries = std.array_list.Managed(VProp.VRecordEntry).init(a);
for (app.record.?) |ent| {
switch (ent) {
.assign => |asn| {
const v = try exprToVProp(a, asn.value.*);
try rec_entries.append(.{ .key = asn.target, .value = v });
},
.inherit => try rec_entries.append(.{ .key = null, .value = null }),
}
}
try b.map.put(name_, .{ .record = try rec_entries.toOwnedSlice() });
try b.order.append(name_);
}
},
else => {},
}
}
return b;
}
fn nodeBindings(a: std.mem.Allocator, nd: *const p.NodeDecl) !Bindings {
var b = Bindings.init(a);
for (nd.body) |st| {
switch (st) {
.assign => |asn| {
try b.map.put(asn.target, try exprToVProp(a, asn.value.*));
try b.order.append(asn.target);
},
else => {},
}
}
return b;
}
const NESTED_SCHEMA = [_]struct { kind: []const u8, field: []const u8, schema: []const u8 }{
.{ .kind = "fiber", .field = "policy", .schema = "fiberPolicy" },
};
fn conformDecl(a: std.mem.Allocator, d: *const p.Decl, schema: SchemaSpec, reg: *Registry, smap_opt: ?*const SourceMap, file: []const u8, diags: *std.array_list.Managed(Diagnostic)) !void {
const ds = d.byte_start;
const de = d.byte_end;
const decl_span = Span{ .byte_start = ds, .byte_end = de, .line = d.line, .col = d.col };
const lbl = try std.fmt.allocPrint(a, "{s} {s}", .{ d.kind, d.name });
const bindings = try declFieldBindings(a, d);
var fit = schema.fields.valueIterator();
while (fit.next()) |f| {
if (f.presence == .required and !bindings.map.contains(f.name)) {
const msg = try std.fmt.allocPrint(a, "required field `{s}` of schema `{s}` is missing", .{ f.name, schema.name });
try emit(a, diags, "E-CONFORM-MISSING-FIELD", file, decl_span, lbl, msg);
}
}
if (!schema.open) {
for (bindings.order.items) |fname| {
if (!schema.fields.contains(fname)) {
const span = if (smap_opt) |sm| sm.fieldNameSpan(ds, de, fname) orelse decl_span else decl_span;
const msg = try std.fmt.allocPrint(a, "`{s}` is not a declared field of closed schema `{s}`", .{ fname, schema.name });
try emit(a, diags, "E-CONFORM-UNKNOWN-FIELD", file, span, lbl, msg);
}
}
}
var bit = bindings.map.iterator();
while (bit.next()) |kv| {
const fname = kv.key_ptr.*;
const vprop = kv.value_ptr.*;
const f = schema.fields.get(fname) orelse continue;
var is_nested = false;
for (NESTED_SCHEMA) |ns| {
if (std.mem.eql(u8, d.kind, ns.kind) and std.mem.eql(u8, fname, ns.field)) {
if (reg.schemas.get(ns.schema)) |nested_schema| {
switch (vprop) {
.record => |entries| try conformNestedRecord(a, entries, nested_schema, reg, smap_opt, file, diags, lbl, fname, decl_span, ds, de),
else => {},
}
is_nested = true;
}
break;
}
}
if (is_nested) continue;
if (!vpropMatchesType(a, vprop, f.type_text, reg)) {
const span = if (smap_opt) |sm| sm.fieldValueSpan(ds, de, fname) orelse decl_span else decl_span;
const rv = try renderVProp(a, vprop);
const msg = try std.fmt.allocPrint(a, "field `{s}` of schema `{s}` expects `{s}` but got {s}", .{ fname, schema.name, f.type_text, rv });
try emit(a, diags, "E-CONFORM-TYPE", file, span, lbl, msg);
}
try checkFieldConstraints(a, vprop, f, smap_opt, ds, de, decl_span, file, lbl, diags);
for (f.refinements) |r| {
switch (r) {
.matches => |rx| {
const vspan = if (smap_opt) |sm| sm.fieldValueSpan(ds, de, fname) orelse decl_span else decl_span;
try checkMatches(a, vprop, rx, fname, vspan, file, lbl, diags);
},
else => {},
}
}
}
}
fn conformNestedRecord(a: std.mem.Allocator, entries: []const VProp.VRecordEntry, schema: SchemaSpec, reg: *Registry, smap_opt: ?*const SourceMap, file: []const u8, diags: *std.array_list.Managed(Diagnostic), owner_lbl: []const u8, owner_field: []const u8, decl_span: Span, ds: usize, de: usize) !void {
var present = std.StringHashMap(VProp).init(a);
for (entries) |e| {
if (e.key) |k| if (e.value) |v| try present.put(k, v);
}
var fit = schema.fields.valueIterator();
while (fit.next()) |f| {
if (f.presence == .required and !present.contains(f.name)) {
const msg = try std.fmt.allocPrint(a, "required field `{s}` of nested schema `{s}` (in `{s}`) is missing", .{ f.name, schema.name, owner_field });
try emit(a, diags, "E-CONFORM-MISSING-FIELD", file, decl_span, owner_lbl, msg);
}
}
if (!schema.open) {
var pit = present.keyIterator();
while (pit.next()) |k| {
if (!schema.fields.contains(k.*)) {
const span = if (smap_opt) |sm| sm.fieldNameSpan(ds, de, k.*) orelse decl_span else decl_span;
const msg = try std.fmt.allocPrint(a, "`{s}` is not a declared field of nested schema `{s}` (in `{s}`)", .{ k.*, schema.name, owner_field });
try emit(a, diags, "E-CONFORM-UNKNOWN-FIELD", file, span, owner_lbl, msg);
}
}
}
var pit2 = present.iterator();
while (pit2.next()) |kv| {
const f = schema.fields.get(kv.key_ptr.*) orelse continue;
if (!vpropMatchesType(a, kv.value_ptr.*, f.type_text, reg)) {
const span = if (smap_opt) |sm| sm.fieldValueSpan(ds, de, kv.key_ptr.*) orelse decl_span else decl_span;
const rv = try renderVProp(a, kv.value_ptr.*);
const msg = try std.fmt.allocPrint(a, "field `{s}` of nested schema `{s}` expects `{s}` but got {s}", .{ kv.key_ptr.*, schema.name, f.type_text, rv });
try emit(a, diags, "E-CONFORM-TYPE", file, span, owner_lbl, msg);
}
try checkFieldConstraints(a, kv.value_ptr.*, f, smap_opt, ds, de, decl_span, file, owner_lbl, diags);
}
}
fn conformNode(a: std.mem.Allocator, nd: *const p.NodeDecl, schema: SchemaSpec, reg: *Registry, smap_opt: ?*const SourceMap, file: []const u8, diags: *std.array_list.Managed(Diagnostic), nspan: Span) !void {
const ns = nd.byte_start;
const ne = nd.byte_end;
const lbl = try std.fmt.allocPrint(a, "node {s}", .{nd.name});
const b = try nodeBindings(a, nd);
var fit = schema.fields.valueIterator();
while (fit.next()) |f| {
if (f.presence == .required and !b.map.contains(f.name)) {
const msg = try std.fmt.allocPrint(a, "required field `{s}` of schema `{s}` is missing", .{ f.name, schema.name });
try emit(a, diags, "E-CONFORM-MISSING-FIELD", file, nspan, lbl, msg);
}
}
if (!schema.open) {
for (b.order.items) |fname| {
if (!schema.fields.contains(fname)) {
const span = if (smap_opt) |sm| sm.fieldNameSpan(ns, ne, fname) orelse nspan else nspan;
const msg = try std.fmt.allocPrint(a, "`{s}` is not a declared field of closed schema `{s}`", .{ fname, schema.name });
try emit(a, diags, "E-CONFORM-UNKNOWN-FIELD", file, span, lbl, msg);
}
}
}
var bit = b.map.iterator();
while (bit.next()) |kv| {
const f = schema.fields.get(kv.key_ptr.*) orelse continue;
if (!vpropMatchesType(a, kv.value_ptr.*, f.type_text, reg)) {
const span = if (smap_opt) |sm| sm.fieldValueSpan(ns, ne, kv.key_ptr.*) orelse nspan else nspan;
const rv = try renderVProp(a, kv.value_ptr.*);
const msg = try std.fmt.allocPrint(a, "field `{s}` of schema `{s}` expects `{s}` but got {s}", .{ kv.key_ptr.*, schema.name, f.type_text, rv });
try emit(a, diags, "E-CONFORM-TYPE", file, span, lbl, msg);
}
try checkFieldConstraints(a, kv.value_ptr.*, f, smap_opt, ns, ne, nspan, file, lbl, diags);
}
}
const GrantRef = struct { domain: []const u8, grant: []const u8 };
fn grantRefParts(vprop: VProp) ?GrantRef {
switch (vprop) {
.ref => |rv| {
var it = std.mem.splitScalar(u8, rv.dotted, '.');
const d = it.next() orelse return null;
const g = it.next() orelse return null;
if (it.next() != null) return null;
return .{ .domain = d, .grant = g };
},
else => return null,
}
}
fn checkCapabilityRefs(a: std.mem.Allocator, domain: []const u8, grant: []const u8, reg: *Registry, file: []const u8, span: Span, decl_lbl: []const u8, diags: *std.array_list.Managed(Diagnostic)) !bool {
if (reg.caps.get(domain)) |cap| {
if (!cap.grants.contains(grant)) {
const msg = try std.fmt.allocPrint(a, "`{s}` is not a declared grant of capability domain `{s}`", .{ grant, domain });
try emit(a, diags, "E-CAP-UNKNOWN-GRANT", file, span, decl_lbl, msg);
return false;
}
return true;
}
const msg = try std.fmt.allocPrint(a, "unknown capability domain `{s}` in `{s}.{s}`", .{ domain, domain, grant });
try emit(a, diags, "E-CAP-UNKNOWN-DOMAIN", file, span, decl_lbl, msg);
return false;
}
fn leqGrant(cap: CapabilitySpec, aa: []const u8, bb: []const u8) bool {
if (cap.leq.get(aa)) |s| return s.contains(bb);
return std.mem.eql(u8, aa, bb);
}
fn checkMesh(a: std.mem.Allocator, mesh_decl: *const p.Decl, reg: *Registry, smap_opt: ?*const SourceMap, file: []const u8, diags: *std.array_list.Managed(Diagnostic)) !void {
const mesh_schema = reg.schemas.get("meshNode");
const mesh_lbl = try std.fmt.allocPrint(a, "mesh {s}", .{mesh_decl.name});
var node_grants = std.StringHashMap(std.array_list.Managed(GrantRef)).init(a);
for (mesh_decl.body) |st| {
switch (st) {
.node => |nd| {
const nspan = Span{ .byte_start = nd.byte_start, .byte_end = nd.byte_end, .line = nd.line, .col = nd.col };
if (mesh_schema) |ms| try conformNode(a, nd, ms, reg, smap_opt, file, diags, nspan);
const b = try nodeBindings(a, nd);
var grants_list = std.array_list.Managed(GrantRef).init(a);
if (b.map.get("capabilities")) |caps_vprop| {
switch (caps_vprop) {
.list => |items| {
for (items) |item| {
const dg = grantRefParts(item) orelse continue;
const cspan = if (smap_opt) |sm| sm.fieldValueSpan(nd.byte_start, nd.byte_end, "capabilities") orelse nspan else nspan;
const node_lbl = try std.fmt.allocPrint(a, "node {s}", .{nd.name});
if (try checkCapabilityRefs(a, dg.domain, dg.grant, reg, file, cspan, node_lbl, diags)) {
try grants_list.append(dg);
}
}
},
else => {},
}
}
try node_grants.put(nd.name, grants_list);
},
else => {},
}
}
for (mesh_decl.body) |st| {
switch (st) {
.edge => |edge| {
var i: usize = 0;
while (i + 1 < edge.refs.len) : (i += 1) {
const a_ref = edge.refs[i];
const b_ref = edge.refs[i + 1];
const sender = if (a_ref.parts.len == 1) a_ref.parts[0] else continue;
const receiver = if (b_ref.parts.len == 1) b_ref.parts[0] else continue;
const s_grants = node_grants.get(sender) orelse continue;
const r_grants = node_grants.get(receiver) orelse continue;
const edge_span = Span{ .byte_start = a_ref.byte_start, .byte_end = b_ref.byte_end, .line = a_ref.line, .col = a_ref.col };
var s_by_dom = std.StringHashMap(std.array_list.Managed([]const u8)).init(a);
for (s_grants.items) |dg| {
const entry = try s_by_dom.getOrPut(dg.domain);
if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed([]const u8).init(a);
try entry.value_ptr.append(dg.grant);
}
for (r_grants.items) |dg| {
const cap = reg.caps.get(dg.domain) orelse continue;
const sender_gs = if (s_by_dom.get(dg.domain)) |sl| sl.items else &[_][]const u8{};
var ok = false;
for (sender_gs) |sg| if (leqGrant(cap, dg.grant, sg)) { ok = true; break; };
if (!ok) {
var held = std.array_list.Managed(u8).init(a);
if (sender_gs.len == 0) {
try held.appendSlice("(none)");
} else {
for (sender_gs, 0..) |sg, idx| {
if (idx != 0) try held.appendSlice(", ");
try held.appendSlice(dg.domain);
try held.append('.');
try held.appendSlice(sg);
}
}
const msg = try std.fmt.allocPrint(a,
"delegation `{s} -> {s}` escalates authority: receiver holds `{s}.{s}` but sender holds {s} (receiver's grant must be ≤ the sender's in domain `{s}`)",
.{ sender, receiver, dg.domain, dg.grant, held.items, dg.domain });
try emit(a, diags, "E-CAP-ATTENUATION", file, edge_span, mesh_lbl, msg);
}
}
}
},
else => {},
}
}
}
fn checkWorkflow(a: std.mem.Allocator, wf: *const p.Decl, reg: *Registry, smap_opt: ?*const SourceMap, file: []const u8, diags: *std.array_list.Managed(Diagnostic), sibling_meshes: ?*const std.StringHashMap(std.StringHashMap(void)), sibling_kinds: ?*const std.StringHashMap([]const u8)) !void {
const step_schema = reg.schemas.get("workflowStep");
const wf_lbl = try std.fmt.allocPrint(a, "workflow {s}", .{wf.name});
const dspan = Span{ .byte_start = wf.byte_start, .byte_end = wf.byte_end, .line = wf.line, .col = wf.col };
var steps = std.array_list.Managed([]const u8).init(a);
for (wf.body) |st| {
switch (st) {
.node => |nd| {
try steps.append(nd.name);
const nspan = Span{ .byte_start = nd.byte_start, .byte_end = nd.byte_end, .line = nd.line, .col = nd.col };
if (step_schema) |ss| try conformNode(a, nd, ss, reg, smap_opt, file, diags, nspan);
const b = try nodeBindings(a, nd);
if (b.map.get("agent")) |agent_vprop| {
if (grantRefParts(agent_vprop)) |dg| {
const head = dg.domain;
const member = dg.grant;
var bad: ?[]const u8 = null;
if (sibling_meshes) |sm| {
if (sm.get(head)) |nodes| {
if (!nodes.contains(member)) {
bad = try std.fmt.allocPrint(a,
"step `{s}`: `agent = {s}.{s}` references mesh `{s}` but it declares no node `{s}`",
.{ nd.name, head, member, head, member });
}
} else if (sibling_kinds) |sk| {
if (sk.get(head)) |kind| {
bad = try std.fmt.allocPrint(a,
"step `{s}`: `agent = {s}.{s}` references `{s} {s}`, which is not a mesh — an agent must be a mesh node",
.{ nd.name, head, member, kind, head });
}
}
}
if (bad) |msg| {
const span = if (smap_opt) |sm2| sm2.fieldValueSpan(nd.byte_start, nd.byte_end, "agent") orelse nspan else nspan;
try emit(a, diags, "E-REF-UNRESOLVED", file, span, wf_lbl, msg);
}
}
}
},
else => {},
}
}
const step_arr = try steps.toOwnedSlice();
var step_set = std.StringHashMap(void).init(a);
for (step_arr) |s| try step_set.put(s, {});
var succ = std.StringHashMap(std.array_list.Managed([]const u8)).init(a);
for (step_arr) |s| try succ.put(s, std.array_list.Managed([]const u8).init(a));
for (wf.body) |st| {
switch (st) {
.edge => |edge| {
var i: usize = 0;
while (i + 1 < edge.refs.len) : (i += 1) {
const aa = if (edge.refs[i].parts.len == 1) edge.refs[i].parts[0] else continue;
const bb = if (edge.refs[i + 1].parts.len == 1) edge.refs[i + 1].parts[0] else continue;
if (step_set.contains(aa) and step_set.contains(bb)) {
const entry = try succ.getOrPut(aa);
if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed([]const u8).init(a);
try entry.value_ptr.append(bb);
}
}
},
else => {},
}
}
const WHITE: u8 = 0;
const GREY: u8 = 1;
const BLACK: u8 = 2;
var colour = std.StringHashMap(u8).init(a);
for (step_arr) |s| try colour.put(s, WHITE);
var cycle_found: ?[]const []const u8 = null;
for (step_arr) |root| {
if (cycle_found != null) break;
if ((colour.get(root) orelse WHITE) != WHITE) continue;
var stack = std.array_list.Managed(struct { node: []const u8, idx: usize }).init(a);
var path = std.array_list.Managed([]const u8).init(a);
try colour.put(root, GREY);
try stack.append(.{ .node = root, .idx = 0 });
try path.append(root);
outer: while (stack.items.len > 0) {
const top = &stack.items[stack.items.len - 1];
const children = if (succ.get(top.node)) |sl| sl.items else &[_][]const u8{};
while (top.idx < children.len) {
const nxt = children[top.idx];
top.idx += 1;
const nc = colour.get(nxt) orelse WHITE;
if (nc == GREY) {
var cyc = std.array_list.Managed([]const u8).init(a);
var found_start = false;
for (path.items) |pp| {
if (std.mem.eql(u8, pp, nxt)) found_start = true;
if (found_start) try cyc.append(pp);
}
try cyc.append(nxt);
cycle_found = try cyc.toOwnedSlice();
break :outer;
}
if (nc == WHITE) {
try colour.put(nxt, GREY);
try path.append(nxt);
try stack.append(.{ .node = nxt, .idx = 0 });
continue :outer;
}
}
try colour.put(top.node, BLACK);
_ = path.pop();
_ = stack.pop();
}
}
if (cycle_found) |cyc| {
var parts = std.array_list.Managed(u8).init(a);
for (cyc, 0..) |s, i| {
if (i != 0) try parts.appendSlice(" -> ");
try parts.appendSlice(s);
}
const msg = try std.fmt.allocPrint(a,
"workflow `{s}` step edges must form a DAG; cycle: {s} (express revision loops as `retries` on a step, not back-edges)",
.{ wf.name, parts.items });
try emit(a, diags, "E-WORKFLOW-CYCLE", file, dspan, wf_lbl, msg);
return;
}
var depth_of = std.StringHashMap(usize).init(a);
var max_depth: usize = 0;
for (step_arr) |root| {
var stk = std.array_list.Managed(struct { node: []const u8, processed: bool }).init(a);
try stk.append(.{ .node = root, .processed = false });
while (stk.items.len > 0) {
const top = &stk.items[stk.items.len - 1];
if (depth_of.contains(top.node)) { _ = stk.pop(); continue; }
if (top.processed) {
const node = top.node;
_ = stk.pop();
const children = if (succ.get(node)) |sl| sl.items else &[_][]const u8{};
var max_child: usize = 0;
for (children) |ch| { const cd = depth_of.get(ch) orelse 1; if (cd > max_child) max_child = cd; }
const d = 1 + max_child;
try depth_of.put(node, d);
if (d > max_depth) max_depth = d;
} else {
top.processed = true;
const children = if (succ.get(top.node)) |sl| sl.items else &[_][]const u8{};
for (children) |ch| try stk.append(.{ .node = ch, .processed = false });
}
}
}
const wf_bindings = try declFieldBindings(a, wf);
if (wf_bindings.map.get("maxDepth")) |md| {
switch (md) {
.lit => |lv| if (std.mem.eql(u8, lv.kind, "number")) {
if (std.fmt.parseInt(usize, lv.value, 10)) |bound| {
if (max_depth > bound) {
const span = if (smap_opt) |sm| sm.fieldValueSpan(wf.byte_start, wf.byte_end, "maxDepth") orelse dspan else dspan;
const msg = try std.fmt.allocPrint(a,
"workflow `{s}` has critical-path depth {d}, exceeding the declared maxDepth = {d}",
.{ wf.name, max_depth, bound });
try emit(a, diags, "E-WORKFLOW-DEPTH", file, span, wf_lbl, msg);
}
} else |_| {}
},
else => {},
}
}
}
fn checkGenerics(a: std.mem.Allocator, d: *const p.Decl, reg: *Registry, by_name_kind: *const std.StringHashMap(*const p.Decl), smap_opt: ?*const SourceMap, file: []const u8, diags: *std.array_list.Managed(Diagnostic)) !void {
_ = reg;
if (!std.mem.eql(u8, d.kind, "catalog")) return;
const ds = d.byte_start;
const de = d.byte_end;
const decl_span = Span{ .byte_start = ds, .byte_end = de, .line = d.line, .col = d.col };
const lbl = try std.fmt.allocPrint(a, "catalog {s}", .{d.name});
const bindings = try declFieldBindings(a, d);
const frm = bindings.map.get("from") orelse return;
const dotted = switch (frm) { .ref => |rv| rv.dotted, else => return };
var parts_it = std.mem.splitScalar(u8, dotted, '.');
const part0 = parts_it.next() orelse return;
const part1 = parts_it.next() orelse return;
if (parts_it.next() != null) return;
if (p.isKind(part0)) {
const kn = try std.fmt.allocPrint(a, "{s}/{s}", .{ part0, part1 });
if (by_name_kind.contains(kn) and !std.mem.eql(u8, part0, "index")) {
const span = if (smap_opt) |sm| sm.fieldValueSpan(ds, de, "from") orelse decl_span else decl_span;
const msg = try std.fmt.allocPrint(a, "catalog `from` must target an `index` (Index<T>); `{s}` is a `{s}`", .{ dotted, part0 });
try emit(a, diags, "E-GENERIC-INCONSISTENT", file, span, lbl, msg);
}
}
}
fn checkNameCollisions(a: std.mem.Allocator, items: []const p.Item, file: []const u8, smap_opt: ?*const SourceMap, diags: *std.array_list.Managed(Diagnostic)) !void {
var first_seen = std.StringHashMap(*const p.Decl).init(a);
for (items) |it| {
if (it != .decl) continue;
const d = it.decl;
if (first_seen.get(d.name)) |prior| {
const span = if (smap_opt) |sm| sm.declKwSpan(d) orelse Span{ .byte_start = d.byte_start, .byte_end = d.byte_end, .line = d.line, .col = d.col } else Span{ .byte_start = d.byte_start, .byte_end = d.byte_end, .line = d.line, .col = d.col };
const kindnote = if (std.mem.eql(u8, d.kind, prior.kind)) "the same kind" else "a different kind";
const msg = try std.fmt.allocPrint(a,
"`{s} {s}` collides with `{s} {s}` ({s}, same name): top-level declarations share a kind-agnostic graph id, so the later one is silently dropped — rename one",
.{ d.kind, d.name, prior.kind, prior.name, kindnote });
const related = try a.alloc(Related, 1);
related[0] = .{
.file = file,
.decl = try std.fmt.allocPrint(a, "{s} {s}", .{ prior.kind, prior.name }),
.span = .{ .byte_start = prior.byte_start, .byte_end = prior.byte_end, .line = prior.line, .col = prior.col },
.message = try std.fmt.allocPrint(a, "first declared here as `{s} {s}`", .{ prior.kind, prior.name }),
};
try emitWithRelated(a, diags, "E-DECL-NAME-COLLISION", file, span, try std.fmt.allocPrint(a, "{s} {s}", .{ d.kind, d.name }), msg, related);
} else try first_seen.put(d.name, d);
}
}
fn collectRuntimeDecls(a: std.mem.Allocator, decl: *const p.Decl, found: *std.StringHashMap(void)) !void {
for (decl.body) |st| {
switch (st) {
.decl => |child| {
const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ child.kind, child.name });
try found.put(key, {});
try collectRuntimeDecls(a, child, found);
},
else => {},
}
}
}
const REF_FIELDS = [_][]const u8{ "source", "input", "output", "engine", "from", "fibers", "budget", "runclass" };
fn isRefField(name_: []const u8) bool {
for (REF_FIELDS) |f| if (std.mem.eql(u8, f, name_)) return true;
return false;
}
const RefItem = struct { ref: p.Ref, field: []const u8, owner: *const p.Decl };
fn walkDependsRefs(a: std.mem.Allocator, decl: *const p.Decl, out: *std.array_list.Managed(RefItem)) !void {
for (decl.body) |st| {
switch (st) {
.assign => |asn| if (isRefField(asn.target)) try refsInValue(asn.value.*, asn.target, decl, out),
.decl => |child| try walkDependsRefs(a, child, out),
else => {},
}
}
}
fn refsInValue(e: p.Expr, field: []const u8, owner: *const p.Decl, out: *std.array_list.Managed(RefItem)) !void {
switch (e) {
.app => |app| {
if (app.args == null and app.record == null) try out.append(.{ .ref = app.ref, .field = field, .owner = owner });
},
.list => |items| for (items) |item| try refsInValue(item, field, owner, out),
else => {},
}
}
const ACCESSOR_REFS = [_]struct { head: []const u8, accessor: []const u8, kind: []const u8 }{
.{ .head = "secret", .accessor = "path", .kind = "secret" },
.{ .head = "hostResource", .accessor = "dsn", .kind = "hostResource" },
};
fn walkAccessorRefs(a: std.mem.Allocator, decl: *const p.Decl, out: *std.array_list.Managed(p.Ref)) !void {
for (decl.body) |st| {
switch (st) {
.assign => |asn| try scanValue(a, asn.value.*, out),
.app => |app| try scanApp(a, app, out),
.decl => |child| try walkAccessorRefs(a, child, out),
else => {},
}
}
}
fn scanApp(a: std.mem.Allocator, app: p.App, out: *std.array_list.Managed(p.Ref)) std.mem.Allocator.Error!void {
if (app.args == null and app.record == null and app.ref.parts.len == 3) try out.append(app.ref);
if (app.record) |rec| for (rec) |ent| {
switch (ent) {
.assign => |asn| try scanValue(a, asn.value.*, out),
else => {},
}
};
if (app.args) |args| for (args) |arg| try scanValue(a, arg, out);
}
fn scanValue(a: std.mem.Allocator, e: p.Expr, out: *std.array_list.Managed(p.Ref)) std.mem.Allocator.Error!void {
switch (e) {
.app => |app| try scanApp(a, app, out),
.list => |items| for (items) |item| try scanValue(a, item, out),
.record => |entries| for (entries) |ent| {
switch (ent) {
.assign => |asn| try scanValue(a, asn.value.*, out),
else => {},
}
},
else => {},
}
}
fn checkRefResolution(a: std.mem.Allocator, runtime_decl: *const p.Decl, file: []const u8, diags: *std.array_list.Managed(Diagnostic), imported: std.StringHashMap(void)) !void {
var declared = std.StringHashMap(void).init(a);
try collectRuntimeDecls(a, runtime_decl, &declared);
var iit = imported.keyIterator();
while (iit.next()) |k| try declared.put(k.*, {});
var declared_names = std.StringHashMap(void).init(a);
var dit = declared.keyIterator();
while (dit.next()) |k| {
if (std.mem.indexOfScalar(u8, k.*, '/')) |slash| try declared_names.put(k.*[slash + 1 ..], {});
}
const runtime_lbl = try std.fmt.allocPrint(a, "runtime {s}", .{runtime_decl.name});
var refs = std.array_list.Managed(RefItem).init(a);
try walkDependsRefs(a, runtime_decl, &refs);
for (refs.items) |item| {
const ref = item.ref;
const field = item.field;
const owner = item.owner;
const owner_lbl = try std.fmt.allocPrint(a, "{s} {s}", .{ owner.kind, owner.name });
const span = Span{ .byte_start = ref.byte_start, .byte_end = ref.byte_end, .line = ref.line, .col = ref.col };
if (ref.parts.len == 2 and p.isKind(ref.parts[0])) {
const kn = try std.fmt.allocPrint(a, "{s}/{s}", .{ ref.parts[0], ref.parts[1] });
if (!declared.contains(kn)) {
const dotted = try std.mem.join(a, ".", ref.parts);
const msg = try std.fmt.allocPrint(a,
"`{s}` references `{s}` but no `{s} {s}` is declared in runtime `{s}`",
.{ field, dotted, ref.parts[0], ref.parts[1], runtime_decl.name });
try emit(a, diags, "E-REF-UNRESOLVED", file, span, owner_lbl, msg);
}
} else if (ref.parts.len == 1) {
if (!declared_names.contains(ref.parts[0])) {
const msg = try std.fmt.allocPrint(a,
"`{s}` references `{s}` but no declaration named `{s}` is in scope of runtime `{s}`",
.{ field, ref.parts[0], ref.parts[0], runtime_decl.name });
try emit(a, diags, "E-REF-UNRESOLVED", file, span, owner_lbl, msg);
}
}
}
var accessor_refs = std.array_list.Managed(p.Ref).init(a);
try walkAccessorRefs(a, runtime_decl, &accessor_refs);
var seen = std.StringHashMap(void).init(a);
for (accessor_refs.items) |ref| {
if (ref.parts.len != 3) continue;
const head = ref.parts[0];
const middle = ref.parts[1];
const acc = ref.parts[2];
var kind: ?[]const u8 = null;
for (ACCESSOR_REFS) |ar| {
if (std.mem.eql(u8, ar.head, head) and std.mem.eql(u8, ar.accessor, acc)) { kind = ar.kind; break; }
}
const k = kind orelse continue;
const key = try std.fmt.allocPrint(a, "{d}/{d}", .{ ref.byte_start, ref.byte_end });
if (seen.contains(key)) continue;
try seen.put(key, {});
const kn = try std.fmt.allocPrint(a, "{s}/{s}", .{ k, middle });
if (!declared.contains(kn)) {
const span = Span{ .byte_start = ref.byte_start, .byte_end = ref.byte_end, .line = ref.line, .col = ref.col };
const dotted = try std.mem.join(a, ".", ref.parts);
const msg = try std.fmt.allocPrint(a,
"`{s}` references `{s} {s}` but no such declaration is in scope of runtime `{s}`",
.{ dotted, k, middle, runtime_decl.name });
try emit(a, diags, "E-REF-UNRESOLVED", file, span, runtime_lbl, msg);
}
}
}
fn meshNodeIndex(a: std.mem.Allocator, stmts: []const p.Stmt) !std.StringHashMap(std.StringHashMap(void)) {
var result = std.StringHashMap(std.StringHashMap(void)).init(a);
for (stmts) |st| {
if (st != .decl) continue;
const d = st.decl;
if (!std.mem.eql(u8, d.kind, "mesh")) continue;
var nodes = std.StringHashMap(void).init(a);
for (d.body) |bst| {
switch (bst) { .node => |nd| try nodes.put(nd.name, {}), else => {} }
}
try result.put(d.name, nodes);
}
return result;
}
fn declKindIndex(a: std.mem.Allocator, stmts: []const p.Stmt) !std.StringHashMap([]const u8) {
var result = std.StringHashMap([]const u8).init(a);
for (stmts) |st| {
if (st != .decl) continue;
try result.put(st.decl.name, st.decl.kind);
}
return result;
}
fn itemsMeshNodeIndex(a: std.mem.Allocator, items: []const p.Item) !std.StringHashMap(std.StringHashMap(void)) {
var result = std.StringHashMap(std.StringHashMap(void)).init(a);
for (items) |it| {
if (it != .decl) continue;
const d = it.decl;
if (!std.mem.eql(u8, d.kind, "mesh")) continue;
var nodes = std.StringHashMap(void).init(a);
for (d.body) |bst| {
switch (bst) { .node => |nd| try nodes.put(nd.name, {}), else => {} }
}
try result.put(d.name, nodes);
}
return result;
}
fn itemsDeclKindIndex(a: std.mem.Allocator, items: []const p.Item) !std.StringHashMap([]const u8) {
var result = std.StringHashMap([]const u8).init(a);
for (items) |it| {
if (it != .decl) continue;
try result.put(it.decl.name, it.decl.kind);
}
return result;
}
fn checkDeclTree(a: std.mem.Allocator, d: *const p.Decl, reg: *Registry, by_name_kind: *const std.StringHashMap(*const p.Decl), smap_opt: ?*const SourceMap, file: []const u8, diags: *std.array_list.Managed(Diagnostic), sibling_meshes: ?*const std.StringHashMap(std.StringHashMap(void)), sibling_kinds: ?*const std.StringHashMap([]const u8)) anyerror!void {
const kind = d.kind;
if (!std.mem.eql(u8, kind, "schema") and !std.mem.eql(u8, kind, "capability")) {
if (reg.schemas.get(kind)) |schema| try conformDecl(a, d, schema, reg, smap_opt, file, diags);
try checkGenerics(a, d, reg, by_name_kind, smap_opt, file, diags);
}
if (std.mem.eql(u8, kind, "mesh")) try checkMesh(a, d, reg, smap_opt, file, diags);
if (std.mem.eql(u8, kind, "workflow")) try checkWorkflow(a, d, reg, smap_opt, file, diags, sibling_meshes, sibling_kinds);
const child_meshes = try meshNodeIndex(a, d.body);
const child_kinds = try declKindIndex(a, d.body);
for (d.body) |st| {
switch (st) {
.decl => |child| try checkDeclTree(a, child, reg, by_name_kind, smap_opt, file, diags, &child_meshes, &child_kinds),
else => {},
}
}
}
fn writeJsonStr(w: anytype, s: []const u8) !void {
try w.writeByte('"');
for (s) |c| {
switch (c) {
'"' => try w.writeAll("\\\""),
'\\' => try w.writeAll("\\\\"),
'\n' => try w.writeAll("\\n"),
'\r' => try w.writeAll("\\r"),
'\t' => try w.writeAll("\\t"),
0x08 => try w.writeAll("\\b"),
0x0c => try w.writeAll("\\f"),
0x00...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
else => try w.writeByte(c),
}
}
try w.writeByte('"');
}
pub fn writeDiagnosticsJson(w: anytype, diags: []const Diagnostic) !void {
try w.writeAll("{\n \"diagnostics\": [");
for (diags, 0..) |d, i| {
if (i != 0) try w.writeByte(',');
try w.writeAll("\n {\n");
try w.writeAll(" \"code\": "); try writeJsonStr(w, d.code);
try w.writeAll(",\n \"decl\": "); try writeJsonStr(w, d.decl);
try w.writeAll(",\n \"file\": "); try writeJsonStr(w, d.file);
try w.writeAll(",\n \"message\": "); try writeJsonStr(w, d.message);
try w.writeAll(",\n \"related\": [");
for (d.related, 0..) |rel, ri| {
if (ri != 0) try w.writeByte(',');
try w.writeAll("\n {\n");
try w.writeAll(" \"decl\": "); try writeJsonStr(w, rel.decl);
try w.writeAll(",\n \"file\": "); try writeJsonStr(w, rel.file);
try w.writeAll(",\n \"message\": "); try writeJsonStr(w, rel.message);
try w.writeAll(",\n \"span\": {\n");
try w.print(" \"byteEnd\": {d},\n", .{rel.span.byte_end});
try w.print(" \"byteStart\": {d},\n", .{rel.span.byte_start});
try w.print(" \"col\": {d},\n", .{rel.span.col});
try w.print(" \"line\": {d}\n", .{rel.span.line});
try w.writeAll(" }\n }");
}
if (d.related.len > 0) try w.writeAll("\n ");
try w.writeAll("],\n \"severity\": "); try writeJsonStr(w, d.severity);
try w.writeAll(",\n \"span\": {\n");
try w.print(" \"byteEnd\": {d},\n", .{d.byte_end});
try w.print(" \"byteStart\": {d},\n", .{d.byte_start});
try w.print(" \"col\": {d},\n", .{d.col});
try w.print(" \"line\": {d}\n", .{d.line});
try w.writeAll(" }\n }");
}
if (diags.len > 0) try w.writeAll("\n ");
try w.writeAll("]\n}\n");
}
pub const Result = struct { ok: bool, message: []const u8 };
pub fn run(a: std.mem.Allocator, source_path: []const u8, src: []const u8) !Result {
_ = a; _ = source_path; _ = src;
return .{ .ok = true, .message = "check: use --json for diagnostic output" };
}
pub fn runJson(a: std.mem.Allocator, source_path: []const u8, src: []const u8, builtins_path: []const u8, builtins_src: []const u8, out_writer: anytype) !bool {
const lex_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
var lx_src = lex_mod.Lexer.init(a, src);
lx_src.run() catch {
const err = lx_src.err orelse lex_mod.LexError{ .msg = "lex error", .line = 0, .col = 0 };
std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ source_path, err.line, err.col, err.msg });
return false;
};
var parser_src = parser_mod.Parser.init(a, lx_src.tokens.items);
const items = parser_src.parseFile() catch {
const err = parser_src.err orelse parser_mod.ParseError{ .msg = "parse error", .line = 0, .col = 0 };
std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ source_path, err.line, err.col, err.msg });
return false;
};
const b_src = builtins_src;
var lx_b = lex_mod.Lexer.init(a, b_src);
lx_b.run() catch {
std.debug.print("check: cannot lex builtins: {s}\n", .{builtins_path});
return false;
};
var parser_b = parser_mod.Parser.init(a, lx_b.tokens.items);
const b_items = parser_b.parseFile() catch {
std.debug.print("check: cannot parse builtins: {s}\n", .{builtins_path});
return false;
};
var reg = Registry.init(a);
try loadDeclsInto(a, &reg, b_items, builtins_path);
try loadDeclsInto(a, &reg, items, source_path);
const smap_src = try SourceMap.init(a, src, source_path);
var schema_list = std.array_list.Managed(SchemaSpec).init(a);
{
var sit = reg.schemas.valueIterator();
while (sit.next()) |s| try schema_list.append(s.*);
}
std.sort.pdq(SchemaSpec, schema_list.items, {}, struct {
fn lt(_: void, x: SchemaSpec, y: SchemaSpec) bool {
const fc = std.mem.order(u8, x.origin_file, y.origin_file);
if (fc != .eq) return fc == .lt;
return std.mem.lessThan(u8, x.name, y.name);
}
}.lt);
var diags = std.array_list.Managed(Diagnostic).init(a);
for (schema_list.items) |spec| {
const smap_opt: ?*const SourceMap = if (std.mem.eql(u8, spec.origin_file, source_path)) &smap_src else null;
try checkSchemaWellformed(a, spec, smap_opt, &diags);
}
var cap_list = std.array_list.Managed(*CapabilitySpec).init(a);
{
var cit = reg.caps.valueIterator();
while (cit.next()) |c| try cap_list.append(c);
}
std.sort.pdq(*CapabilitySpec, cap_list.items, {}, struct {
fn lt(_: void, x: *CapabilitySpec, y: *CapabilitySpec) bool {
const fc = std.mem.order(u8, x.origin_file, y.origin_file);
if (fc != .eq) return fc == .lt;
return std.mem.lessThan(u8, x.domain, y.domain);
}
}.lt);
for (cap_list.items) |spec| {
const smap_opt: ?*const SourceMap = if (std.mem.eql(u8, spec.origin_file, source_path)) &smap_src else null;
try checkCapabilityWellformed(a, spec, smap_opt, &diags);
}
var by_name_kind = std.StringHashMap(*const p.Decl).init(a);
for (items) |it| {
if (it != .decl) continue;
const kn = try std.fmt.allocPrint(a, "{s}/{s}", .{ it.decl.kind, it.decl.name });
if (!by_name_kind.contains(kn)) try by_name_kind.put(kn, it.decl);
}
try checkNameCollisions(a, items, source_path, &smap_src, &diags);
const top_meshes = try itemsMeshNodeIndex(a, items);
const top_kinds = try itemsDeclKindIndex(a, items);
for (items) |it| {
if (it != .decl) continue;
const d = it.decl;
try checkDeclTree(a, d, &reg, &by_name_kind, &smap_src, source_path, &diags, &top_meshes, &top_kinds);
if (std.mem.eql(u8, d.kind, "runtime")) {
try checkRefResolution(a, d, source_path, &diags, std.StringHashMap(void).init(a));
}
}
std.sort.pdq(Diagnostic, diags.items, {}, diagLessThan);
try writeDiagnosticsJson(out_writer, diags.items);
return diags.items.len == 0;
}