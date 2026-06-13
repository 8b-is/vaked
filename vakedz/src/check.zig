//! check — the 0011 type-system stage.
//!
//! v0.1 status: SCAFFOLD. The pipeline is wired (parse → graph → check), but the
//! 22 diagnostic codes of the reference checker (vakedc/check.py, docs 0011) are
//! not yet ported. This stage therefore does NOT yet assert a program is
//! well-typed; it reports parse success and the decl count, and defers the real
//! verdict. Porting the checker (closed refinement set, capability attenuation,
//! workflow DAG, ref resolution) is the v0.1→v1.0 backlog tracked on GitHub.
//!
//! It deliberately refuses to print "0 diagnostics / clean" so nothing downstream
//! mistakes the scaffold for a passing check.

const std = @import("std");
const graph = @import("graph.zig");

pub const Result = struct { ok: bool, message: []const u8 };

pub fn run(a: std.mem.Allocator, source_path: []const u8, src: []const u8) !Result {
    var err: ?[]const u8 = null;
    const g = try graph.parseToGraph(a, source_path, src, &err);
    if (g == null) return .{ .ok = false, .message = err orelse "parse failed" };
    return .{
        .ok = true,
        .message = "check: v0.1 scaffold — parsed + graph built; 0011 diagnostics not yet ported (verdict deferred)",
    };
}
