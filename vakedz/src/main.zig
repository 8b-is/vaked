//! vakedz — the Zig front-end for the Vaked capability-graph language.
//!
//! Subcommands mirror `vakedc`:
//!   vakedz parse <file> [--json PATH] [--print] [--no-cache]
//!   vakedz check <file>
//!   vakedz lower <file> [--out DIR]
//!   vakedz all   <file> [--out DIR]
//!   vakedz cache verify | path
//!
//! The `parse` stage is the v0.1 deliverable: a faithful, cache-mediated port of
//! vakedc's lexer → parser → LPG → canonical JSON. Every parse is mediated by the
//! ralphloop-cache (src/cache.zig): a hit replays the content-addressed graph
//! from the immutable hash-chained ledger; a miss computes it and records the
//! source→graph binding. This is the closed-loop dogfooding primitive.

const std = @import("std");
const graph = @import("graph.zig");
const cache = @import("cache.zig");
const check = @import("check.zig");
const lower = @import("lower.zig");

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
    \\  vakedz check <file>
    \\  vakedz lower <file> [--out DIR]
    \\  vakedz all   <file> [--out DIR]
    \\  vakedz cache verify | path
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const a = arena.allocator();

    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(2);
    }
    const cmd = argv[1];

    if (std.mem.eql(u8, cmd, "parse")) {
        std.process.exit(try cmdParse(a, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "check")) {
        std.process.exit(try cmdCheck(a, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "lower")) {
        std.process.exit(try cmdLower(a, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "all")) {
        const rc = try cmdParse(a, argv[2..]);
        if (rc != 0) std.process.exit(rc);
        _ = try cmdCheck(a, argv[2..]);
        std.process.exit(try cmdLower(a, argv[2..]));
    } else if (std.mem.eql(u8, cmd, "cache")) {
        std.process.exit(try cmdCache(a, argv[2..]));
    } else {
        try std.io.getStdErr().writeAll(usage);
        std.process.exit(2);
    }
}

fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return f.readToEndAlloc(a, 64 * 1024 * 1024);
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

fn cmdParse(a: std.mem.Allocator, args: []const []const u8) !u8 {
    const file = firstNonFlag(args) orelse {
        try std.io.getStdErr().writeAll("parse: missing <file>\n");
        return 2;
    };
    const src = readFile(a, file) catch |e| {
        std.debug.print("parse: cannot read {s}: {s}\n", .{ file, @errorName(e) });
        return 1;
    };

    const use_cache = !hasFlag(args, "--no-cache");
    var from_cache = false;
    var out_json: ?[]u8 = null;

    if (use_cache) {
        const c = try cache.Cache.open(a, ".");
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
            const c = try cache.Cache.open(a, ".");
            try c.put(file, src, .parse, out_json.?);
        }
    }

    // Output: default .vaked/graph.json, or --json PATH; --print also to stdout.
    if (flagValue(args, "--json")) |path| {
        try writeOut(path, out_json.?);
    } else {
        std.fs.cwd().makePath(".vaked") catch {};
        try writeOut(".vaked/graph.json", out_json.?);
    }
    if (hasFlag(args, "--print")) {
        try std.io.getStdOut().writeAll(out_json.?);
    }
    std.debug.print("parse: {s} → {d} bytes{s}\n", .{ file, out_json.?.len, if (from_cache) " (cache hit)" else "" });
    return 0;
}

fn writeOut(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

fn cmdCheck(a: std.mem.Allocator, args: []const []const u8) !u8 {
    const file = firstNonFlag(args) orelse {
        try std.io.getStdErr().writeAll("check: missing <file>\n");
        return 2;
    };
    const src = readFile(a, file) catch |e| {
        std.debug.print("check: cannot read {s}: {s}\n", .{ file, @errorName(e) });
        return 1;
    };
    const r = try check.run(a, file, src);
    std.debug.print("{s}\n", .{r.message});
    return if (r.ok) 0 else 1;
}

fn cmdLower(a: std.mem.Allocator, args: []const []const u8) !u8 {
    const file = firstNonFlag(args) orelse {
        try std.io.getStdErr().writeAll("lower: missing <file>\n");
        return 2;
    };
    const out_dir = flagValue(args, "--out") orelse ".vaked/lower";
    try lower.run(a, file, out_dir);
    return 3; // not yet ported — non-zero so callers don't assume artifacts
}

fn cmdCache(a: std.mem.Allocator, args: []const []const u8) !u8 {
    const sub = if (args.len > 0) args[0] else "verify";
    const c = try cache.Cache.open(a, ".");
    if (std.mem.eql(u8, sub, "path")) {
        std.debug.print("{s}\n", .{c.dir});
        return 0;
    }
    // verify
    const r = try c.verify();
    std.debug.print("cache: {d}/{d} entries form a valid chain ({s})\n", .{
        r.valid_prefix, r.entries, if (r.ok) "OK" else "TORN TAIL",
    });
    return if (r.ok) 0 else 1;
}
