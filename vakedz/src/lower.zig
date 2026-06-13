//! lower — the 0012 lowering stage (graph → flake.nix + gen/ + provenance.json).
//!
//! v0.1 status: SCAFFOLD. The reference (vakedc/lower.py, docs 0012) has ~16
//! emitters; the smallest end-to-end slice a Zig port targets first is the
//! operator-field set: nix.spine, docs.runtime, zig.daemoncfg, catalog.jsonl,
//! otp.supervision. None are ported yet. This stage refuses to emit (mirroring
//! the reference's "refuse on any diagnostic" gate) and points at the backlog.

const std = @import("std");

pub fn run(_: std.mem.Allocator, _: []const u8, out_dir: []const u8) !void {
    _ = out_dir;
    std.debug.print(
        "lower: not yet ported in v0.1. The front-end (parse → graph) and the\n" ++
            "ralphloop-cache are shipped and cross-verified against vakedc; the\n" ++
            "emitter port (nix.spine, docs.runtime, zig.daemoncfg, catalog.jsonl,\n" ++
            "otp.supervision) is the tracked v0.1\u{2192}v1.0 backlog.\n",
        .{},
    );
}
