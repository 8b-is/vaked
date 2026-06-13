//! vakedz — the Zig front-end for the Vaked capability-graph language.
//!
//! Subcommands mirror `vakedc`:
//!   vakedz parse <file> [--json PATH] [--print] [--no-cache]
//!   vakedz check <file> [--json] [--builtins PATH]
//!   vakedz lower <file> [--out DIR]
//!   vakedz all   <file> [--out DIR]
//!   vakedz cache verify | path
//!
//! The `parse` stage is the v0.1 deliverable: a faithful, cache-mediated port of
//! vakedc's lexer → parser → LPG → canonical JSON. Every parse is mediated by the
//! ralphloop-cache (src/cache.zig): a hit replays the content-addressed graph
//! from the immutable hash-chained ledger; a miss computes it and records the
//! source→graph binding. This is the closed-loop dogfooding primitive.
//!
//! Zig 0.16: file I/O goes through the `std.Io` interface; we construct one
//! `std.Io.Threaded` instance in main and thread it through.

const std = @import("std");
const graph = @import("graph.zig");
const cache = @import("cache.zig");
const check = @import("check.zig");
const lower = @import("lower.zig");
const Io = std.Io;

// Re-export modules so `zig build test` discovers their unit tests.
test {
    std.testing.refAllDecls(@import("json.zig"));
    std.testing.refAllDecls(@import("lexer.zig"));
    std.testing.refAllDecls(@import("parser.zig"));
    std.testing.refAllDecls(@import("graph.zig"));
    std.testing.refAllDecls(@import("cache.zig"));
}

const usage =
    \\vakedz — the Zig front-end for the Vaked capability-graph language
    \\
    \\usage:
    \\  vakedz parse <file> [--json PATH] [--print] [--no-cache]
    \\  vakedz check <file> [--json] [--builtins PATH]
    \\  vakedz lower <file> [--out DIR]
    \\  vakedz all   <file> [--out DIR]
    \\  vakedz cache verify | path
    \\
;

pub fn main(init: std.process.Init) !void {
    // Zig 0.16 hands main the io, allocators, and args via std.process.Init.
    const a = init.arena.allocator();
    const io = init.io;

    const argv_z = try init.minimal.args.toSlice(a);
    const argv = try a.alloc([]const u8, argv_z.len);
    for (argv_z, 0..) |s, i| argv[i] = s;

    if (argv.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "parse")) {
        std.process.exit(try cmdParse(a, io, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "check")) {
        std.process.exit(try cmdCheck(a, io, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "lower")) {
        std.process.exit(try cmdLower(a, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "all")) {
        const rc = try cmdParse(a, io, argv[2..]);
        if (rc != 0) std.process.exit(rc);
        _ = try cmdCheck(a, io, argv[2..]);
        std.process.exit(try cmdLower(a, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "cache")) {
        std.process.exit(try cmdCache(a, io, argv[2..]));
    } else {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
}

fn readFile(a: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
}

fn writeOut(io: Io, path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch {};
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}

fn firstNonFlag(args: []const []const u8) ?[]const u8 {
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) return arg;
    }
    return null;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn cmdParse(a: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    const file = firstNonFlag(args) orelse {
        std.debug.print("parse: missing <file>\n", .{});
        return 2;
    };
    const src = readFile(a, io, file) catch |e| {
        std.debug.print("parse: cannot read {s}: {s}\n", .{ file, @errorName(e) });
        return 1;
    };

    const use_cache = !hasFlag(args, "--no-cache");
    var from_cache = false;
    var out_json: ?[]u8 = null;

    if (use_cache) {
        const c = try cache.Cache.open(a, io, ".");
        if (try c.lookup(file, src, .parse)) |cached| {
            out_json = cached;
            from_cache = true;
        }
    }

    if (out_json == null) {
        var err: ?[]const u8 = null;
        const g = graph.parseToGraph(a, file, src, &err) catch |e| {
            std.debug.print("parse: {s}\n", .{@errorName(e)});
            return 1;
        };
        if (g == null) {
            std.debug.print("{s}\n", .{err orelse "parse failed"});
            return 1;
        }
        out_json = g.?;
        if (use_cache) {
            const c = try cache.Cache.open(a, io, ".");
            try c.put(file, src, .parse, out_json.?);
        }
    }

    // Output: default .vaked/graph.json, or --json PATH; --print also to stdout.
    if (flagValue(args, "--json")) |path| {
        try writeOut(io, path, out_json.?);
    } else {
        try writeOut(io, ".vaked/graph.json", out_json.?);
    }
    if (hasFlag(args, "--print")) {
        try writeStdout(io, out_json.?);
    }
    std.debug.print("parse: {s} → {d} bytes{s}\n", .{ file, out_json.?.len, if (from_cache) " (cache hit)" else "" });
    return 0;
}

fn cmdCheck(a: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    const file = firstNonFlag(args) orelse {
        std.debug.print("check: missing <file>\n", .{});
        return 2;
    };
    const src = readFile(a, io, file) catch |e| {
        std.debug.print("check: cannot read {s}: {s}\n", .{ file, @errorName(e) });
        return 1;
    };

    if (hasFlag(args, "--json")) {
        // Write diagnostic JSON to stdout; exit 0 if clean, 1 if diagnostics.
        var buf: [4096]u8 = undefined;
        var fw = Io.File.stdout().writer(io, &buf);
        const builtins_path = flagValue(args, "--builtins") orelse "vaked/schema/builtins.vaked";
        const clean = try check.runJson(a, file, src, builtins_path, fw.interface);
        try fw.interface.flush();
        return if (clean) 0 else 1;
    }

    const r = try check.run(a, file, src);
    std.debug.print("{s}\n", .{r.message});
    return if (r.ok) 0 else 1;
}

fn cmdLower(a: std.mem.Allocator, args: []const []const u8) !u8 {
    const file = firstNonFlag(args) orelse {
        std.debug.print("lower: missing <file>\n", .{});
        return 2;
    };
    const out_dir = flagValue(args, "--out") orelse ".vaked/lower";
    try lower.run(a, file, out_dir);
    return 3; // not yet ported — non-zero so callers don't assume artifacts
}

fn cmdCache(a: std.mem.Allocator, io: Io, args: []const []const u8) !u8 {
    const sub = if (args.len > 0) args[0] else "verify";
    const c = try cache.Cache.open(a, io, ".");
    if (std.mem.eql(u8, sub, "path")) {
        std.debug.print("{s}\n", .{c.dir});
        return 0;
    }
    const r = try c.verify();
    std.debug.print("cache: {d}/{d} entries form a valid chain ({s})\n", .{
        r.valid_prefix, r.entries, if (r.ok) "OK" else "TORN TAIL",
    });
    return if (r.ok) 0 else 1;
}
