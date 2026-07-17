// GENESIS_SEAL: 7c242080
const std = @import("std");
const Args = @import("Args.zig");
const fmt_mod = @import("Fmt.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const check_mod = @import("check.zig");
const resolve_mod = @import("resolve.zig");
const emit_mod = @import("emit.zig");
const lower_mod = @import("lower.zig");

test {
    _ = @import("lexer_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("fmt_test.zig");
    _ = @import("resolve_test.zig");
    _ = @import("check_test.zig");
    _ = @import("emit_test.zig");
    _ = @import("lower_test.zig");
}

test "fmtSource: check-mode change detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // unformatted source (missing trailing newline) -> changed, canonical output
    switch (try fmtSource(a, "t.vaked", "engine foo {\n}")) {
        .ok => |res| {
            try std.testing.expect(res.changed);
            try std.testing.expectEqualStrings("engine foo {\n}\n", res.formatted);
        },
        .fail => return error.TestUnexpectedResult,
    }

    // already-canonical source -> unchanged
    switch (try fmtSource(a, "t.vaked", "engine foo {\n}\n")) {
        .ok => |res| try std.testing.expect(!res.changed),
        .fail => return error.TestUnexpectedResult,
    }
}

test "fmtSource: parse error reported as fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    switch (try fmtSource(a, "bad.vaked", "not_a_kind foo {\n}")) {
        .fail => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "parse error") != null),
        .ok => return error.TestUnexpectedResult,
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var it = init.minimal.args.iterate();
    _ = it.next();
    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(allocator);
    while (it.next()) |arg| {
        try arg_list.append(allocator, arg);
    }
    const args = try arg_list.toOwnedSlice(allocator);
    defer allocator.free(args);

    const cmd = Args.parse(allocator, args);
    switch (cmd) {
        .fmt => |f| try runFmt(allocator, io, f),
        .check => |c| try runCheck(allocator, io, c),
        .parse => |p| try runParse(allocator, io, p),
        .lower => |l| try runLower(allocator, io, l),
        .cache => {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: {s} not yet implemented\n", .{@tagName(cmd)});
            std.process.exit(1);
        },
        .help => {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).writeAll(
                \\usage: vakedz <command> [options] [files...]
                \\
                \\commands:
                \\  fmt       Format Vaked source files
                \\  parse     Parse a .vaked file into the LPG (canonical JSON)
                \\  check     Type-check Vaked files (0011 stages 3-4)
                \\  lower     Lower a checked .vaked file to artifacts (0012)
                \\  help      Show this help message
                \\  version   Show version
                \\
                \\fmt options:
                \\  --check    Exit 1 if any file would change (CI gate)
                \\  --stdout   Print formatted result to stdout
                \\
                \\parse options:
                \\  --json PATH    Write canonical JSON to PATH (default: .vaked/graph.json)
                \\  --sqlite PATH  NOT IMPLEMENTED (SQLite serialization deferred; exits 2)
                \\  --print        Write canonical JSON to stdout
                \\
                \\check options:
                \\  --json            Emit diagnostics as canonical JSON to stdout
                \\  --builtins PATH   Builtin catalog (default: vaked/schema/builtins.vaked)
                \\
                \\lower options:
                \\  --out DIR         Output directory for the artifact tree
                \\                    (default: .vaked/lower/)
                \\  --builtins PATH   Builtin catalog (default: vaked/schema/builtins.vaked)
                \\  --allow-partial   Write the tree even when the graph selects registry
                \\                    targets this build has not ported yet. The result is
                \\                    knowingly INCOMPLETE (differential harness only).
                \\
            );
        },
        .version => {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).writeAll("vakedz 0.1.0\n");
        },
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(st.size));
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    // Never hand the caller a slice shorter than the allocation: freeing it
    // would violate the allocator contract. Shrink the allocation instead.
    if (n != buf.len) return allocator.realloc(buf, n);
    return buf;
}

fn stderrWriter(ls: std.Io.LockedStderr) *std.Io.Writer {
    return &ls.file_writer.*.interface;
}

/// Result of formatting one file's source. IO-free and exit-free so the
/// check-mode contract is unit-testable; process.exit stays in runFmt/main.
const FmtOutcome = union(enum) {
    ok: struct { formatted: []const u8, changed: bool },
    fail: []const u8, // diagnostic message, no trailing newline
};

fn fmtSource(a: std.mem.Allocator, path: []const u8, source: []const u8) std.mem.Allocator.Error!FmtOutcome {
    var l = lex.Lexer.init(a, source);
    try l.run();
    if (l.errors.items.len > 0) {
        const le = l.errors.items[0];
        return .{ .fail = try std.fmt.allocPrint(a, "vaked fmt: lex error in '{s}': {s} at line {d} col {d}", .{ path, le.msg, le.line, le.col }) };
    }

    var p = parser_mod.Parser.init(a, l.tokens.items);
    const items = p.parseFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Parse => {
            if (p.err) |pe| {
                return .{ .fail = try std.fmt.allocPrint(a, "vaked fmt: parse error in '{s}': {s} at line {d} col {d}", .{ path, pe.msg, pe.line, pe.col }) };
            }
            return .{ .fail = try std.fmt.allocPrint(a, "vaked fmt: parse error in '{s}'", .{path}) };
        },
    };

    var out: std.ArrayList(u8) = .empty;
    try fmt_mod.formatFile(a, items, &out);
    const formatted = try out.toOwnedSlice(a);
    return .{ .ok = .{ .formatted = formatted, .changed = !std.mem.eql(u8, source, formatted) } };
}

fn runFmt(allocator: std.mem.Allocator, io: std.Io, opts: Args.FmtOptions) !void {
    if (opts.paths.len == 0) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).writeAll("vaked fmt: no files specified\n");
        std.process.exit(2);
    }

    var any_changed = false;
    var any_error = false;

    for (opts.paths) |path| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const source = readFileAlloc(aa, io, path) catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vaked fmt: cannot open '{s}': {}\n", .{ path, err });
            any_error = true;
            continue;
        };

        switch (try fmtSource(aa, path, source)) {
            .fail => |msg| {
                const ls = try io.lockStderr(&.{}, null);
                defer io.unlockStderr();
                try stderrWriter(ls).print("{s}\n", .{msg});
                any_error = true;
            },
            .ok => |res| {
                if (opts.stdout) {
                    try std.Io.File.stdout().writeStreamingAll(io, res.formatted);
                } else if (res.changed) {
                    any_changed = true;
                    if (opts.check) {
                        // gofmt -l style: list each file that would be reformatted
                        const line = try std.fmt.allocPrint(aa, "{s}\n", .{path});
                        try std.Io.File.stdout().writeStreamingAll(io, line);
                    } else {
                        const cwd = std.Io.Dir.cwd();
                        try cwd.writeFile(io, .{ .sub_path = path, .data = res.formatted });
                    }
                }
            },
        }
    }

    // exit 2: lex/parse/IO errors; exit 1: --check found unformatted files
    if (any_error) std.process.exit(2);
    if (opts.check and any_changed) std.process.exit(1);
}

/// `vakedz parse <file> [--json PATH] [--sqlite PATH] [--print]` — parse a
/// .vaked file into the LPG and emit the canonical JSON graph, mirroring
/// `python3 -m vakedc parse` (`_cmd_parse`): with no output flag the JSON
/// lands in .vaked/graph.json; `--json PATH` writes it to PATH; `--print`
/// streams it to stdout (byte-identical to Python — the emit differential
/// tools/emit-diff/run.sh locks this). Exit codes mirror `_cmd_parse`:
/// 0 emitted, 1 read / lex / parse error, 2 usage error.
///
/// DIVERGENCES (documented, stderr/SQLite only — never stdout bytes):
///   * SQLite is deferred (no SQLite in the Zig stdlib; vakedz is
///     stdlib-only — see emit.zig `sqlite_deferred`): `--sqlite` exits 2
///     with a message instead of writing graph.db, and the default mode
///     writes only .vaked/graph.json (Python also writes .vaked/graph.db).
///   * the default-mode "wrote ..." notice on stderr names only the JSON
///     path (and says so).
fn runParse(allocator: std.mem.Allocator, io: std.Io, opts: Args.ParseOptions) !void {
    // Args.parse hands over ownership of the paths slice; free it on the
    // normal-return path so a Debug-build DebugAllocator exit stays quiet
    // (std.process.exit paths below never reach the leak check).
    defer allocator.free(opts.paths);
    if (opts.paths.len != 1) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).writeAll("vakedz parse: expected exactly one file\n");
        std.process.exit(2);
    }
    if (opts.sqlite != null) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).writeAll("vakedz parse: --sqlite is not implemented yet (SQLite serialization deferred — Zig stdlib has no SQLite and vakedz is stdlib-only)\n");
        std.process.exit(2);
    }
    const path = opts.paths[0];

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const source = readFileAlloc(aa, io, path) catch |err| {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).print("vakedz: cannot read {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    const items = switch (try check_mod.parseSource(aa, source, path)) {
        .ok => |items| items,
        .fail => |msg| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: {s}\n", .{msg});
            std.process.exit(1);
        },
    };

    // Shared pipeline with check (checkSource runs the same parseSource +
    // buildGraph): resolve the LPG, ignore collision diagnostics — Python's
    // parse command has no check stage and emits the keep-first graph.
    var res = try resolve_mod.buildGraph(aa, items, path);
    defer res.graph.deinit();
    const canonical = try emit_mod.toCanonicalJson(aa, &res.graph, path);

    // Output targets (Python `_cmd_parse`): explicit --json wins; otherwise
    // default under .vaked/. --print never suppresses the writes.
    const explicit = opts.json != null; // --sqlite already rejected above
    var json_path: ?[]const u8 = opts.json;
    const cwd = std.Io.Dir.cwd();
    if (!explicit) {
        cwd.createDirPath(io, ".vaked") catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: cannot create .vaked: {}\n", .{err});
            std.process.exit(1);
        };
        json_path = ".vaked/graph.json";
    }
    if (json_path) |jp| {
        cwd.writeFile(io, .{ .sub_path = jp, .data = canonical }) catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: cannot write {s}: {}\n", .{ jp, err });
            std.process.exit(1);
        };
    }

    if (opts.print) {
        try std.Io.File.stdout().writeStreamingAll(io, canonical);
    } else if (!explicit) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).print("vakedz: wrote {s} (graph.db deferred — no SQLite in the Zig stdlib)\n", .{json_path.?});
    }
}

/// The ImportReader the checker uses for `use`-imported files: reads via the
/// process Io; unreadable paths return null (Python's OSError skip-path).
const ImportIoCtx = struct { io: std.Io };

fn readImportFile(ctx_o: ?*anyopaque, a: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]const u8 {
    const ctx: *ImportIoCtx = @ptrCast(@alignCast(ctx_o.?));
    return readFileAlloc(a, ctx.io, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// `vakedz check <files...> [--json] [--builtins PATH]` — 0011 checker, full
/// rule set (see check.zig module doc). Human-readable diagnostics go to
/// stderr; `--json` prints one sorted canonical-JSON diagnostics document
/// (all files merged) to stdout, matching vakedc's field names. Exit codes:
/// 0 clean, 1 ANY diagnostic present (warnings included — Python's
/// `return 1 if diags else 0`), 2 usage / read / parse error (mirrors
/// `python3 -m vakedc check`).
fn runCheck(allocator: std.mem.Allocator, io: std.Io, opts: Args.CheckOptions) !void {
    if (opts.paths.len == 0) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).writeAll("vakedz check: no files specified\n");
        std.process.exit(2);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Load + parse the builtins catalog once (check.py `load_builtins`).
    const b_path = opts.builtins orelse "vaked/schema/builtins.vaked";
    const b_src = readFileAlloc(aa, io, b_path) catch |err| {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).print("vakedz: cannot read builtins {s}: {}\n", .{ b_path, err });
        std.process.exit(2);
    };
    const b_items = switch (try check_mod.parseSource(aa, b_src, b_path)) {
        .ok => |items| items,
        .fail => |msg| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: builtins catalog failed to parse: {s}\n", .{msg});
            std.process.exit(2);
        },
    };
    const builtins = check_mod.Builtins{ .items = b_items, .src = b_src, .file = b_path };

    var all: std.ArrayList(lib_diag.Diagnostic) = .empty;
    var hard_fail = false;
    var any_diag = false;

    var import_ctx = ImportIoCtx{ .io = io };
    const reader = check_mod.ImportReader{ .ctx = &import_ctx, .read = readImportFile };

    for (opts.paths) |path| {
        const source = readFileAlloc(aa, io, path) catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: cannot read {s}: {}\n", .{ path, err });
            hard_fail = true;
            continue;
        };
        // `use` imports resolve against the file's own dirname, exactly like
        // check.py's base_dir default in check_source (dirname of the path
        // as given — "" for a bare filename).
        const base_dir = std.fs.path.dirname(path) orelse "";
        switch (try check_mod.checkSource(aa, source, path, builtins, base_dir, reader)) {
            .fail => |msg| {
                const ls = try io.lockStderr(&.{}, null);
                defer io.unlockStderr();
                try stderrWriter(ls).print("vakedz: {s}\n", .{msg});
                hard_fail = true;
            },
            .ok => |diags| {
                if (diags.len > 0) any_diag = true;
                if (opts.json) {
                    try all.appendSlice(aa, diags);
                } else {
                    const ls = try io.lockStderr(&.{}, null);
                    defer io.unlockStderr();
                    const w = stderrWriter(ls);
                    for (diags) |d| {
                        try w.print("{s}:{d}:{d}: {s}: {s}: {s} [{s}]\n", .{ d.file, d.line, d.col, @tagName(d.severity), d.code, d.message, d.decl });
                    }
                    if (diags.len > 0) {
                        try w.print("vakedz: {d} diagnostic{s} in {s}\n", .{ diags.len, if (diags.len != 1) "s" else "", path });
                    } else {
                        try w.print("vakedz: {s} — no diagnostics\n", .{path});
                    }
                }
            },
        }
    }

    if (opts.json) {
        // Merged across files; already per-file sorted, re-sorted stably by
        // (file, byteStart, byteEnd, code) — single-file output is identical
        // to vakedc's ordering.
        std.sort.insertion(lib_diag.Diagnostic, all.items, {}, check_mod.diagLess);
        const doc = try check_mod.diagnosticsToJson(aa, all.items);
        try std.Io.File.stdout().writeStreamingAll(io, doc);
    }

    if (hard_fail) std.process.exit(2);
    if (any_diag) std.process.exit(1);
}

/// `vakedz lower <file> [--out DIR] [--builtins PATH]` — parse → resolve →
/// check → lower (0012 §1), a port of vakedc `__main__._cmd_lower`.
///
/// Lowering is CHECK-GATED: any diagnostic ⇒ print them, emit NOTHING, exit 1.
/// The exit contract is vakedc's, which differs from `check`'s:
///   * 0 — the artifact tree was written;
///   * 1 — cannot read the source file, a lex/parse error, or ANY diagnostic
///         (nothing written);
///   * 2 — the BUILTINS catalog could not be read or parsed.
/// Note the asymmetry, faithfully reproduced: an unreadable SOURCE file exits
/// 1 here (vakedc `_cmd_lower` returns 1), whereas `check` exits 2 for the
/// same condition.
fn runLower(allocator: std.mem.Allocator, io: std.Io, opts: Args.LowerOptions) !void {
    const file = opts.file orelse {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).writeAll("vakedz lower: no file specified\n");
        std.process.exit(2);
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // 1) read + parse the source. An unreadable source is exit 1 (vakedc).
    const src = readFileAlloc(aa, io, file) catch |err| {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).print("vakedz: cannot read {s}: {}\n", .{ file, err });
        std.process.exit(1);
    };
    const items = switch (try check_mod.parseSource(aa, src, file)) {
        .ok => |its| its,
        .fail => |msg| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: {s}\n", .{msg});
            std.process.exit(1);
        },
    };

    // 2) check FIRST — lowering only runs on a clean, validated graph.
    //    Builtins failures are the only exit-2 path.
    const b_path = opts.builtins orelse "vaked/schema/builtins.vaked";
    const b_src = readFileAlloc(aa, io, b_path) catch |err| {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).print("vakedz: cannot read builtins {s}: {}\n", .{ b_path, err });
        std.process.exit(2);
    };
    const b_items = switch (try check_mod.parseSource(aa, b_src, b_path)) {
        .ok => |its| its,
        .fail => |msg| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: builtins catalog failed to parse: {s}\n", .{msg});
            std.process.exit(2);
        },
    };
    const builtins = check_mod.Builtins{ .items = b_items, .src = b_src, .file = b_path };

    var import_ctx = ImportIoCtx{ .io = io };
    const reader = check_mod.ImportReader{ .ctx = &import_ctx, .read = readImportFile };
    const base_dir = std.fs.path.dirname(file) orelse "";
    const diags = switch (try check_mod.checkSource(aa, src, file, builtins, base_dir, reader)) {
        .ok => |ds| ds,
        .fail => |msg| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vakedz: {s}\n", .{msg});
            std.process.exit(1);
        },
    };
    if (diags.len > 0) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        const w = stderrWriter(ls);
        for (diags) |d| {
            try w.print("{s}:{d}:{d}: {s}: {s}: {s} [{s}]\n", .{ d.file, d.line, d.col, @tagName(d.severity), d.code, d.message, d.decl });
        }
        try w.print("vakedz: {d} diagnostic{s} in {s}; refusing to lower (nothing written)\n", .{ diags.len, if (diags.len != 1) "s" else "", file });
        std.process.exit(1);
    }

    // 3) resolve + lower. enrichGraph (config sub-blocks) runs inside lower()
    //    when the parsed items are supplied.
    var res = try resolve_mod.buildGraph(aa, items, file);
    const result = try lower_mod.lower(aa, &res.graph, file, items);

    // A graph selecting an emitter this port does not have yet must NOT be
    // written as if it were a complete lowering: the tree would silently be
    // missing artifacts. Refuse, name the targets, and exit 2 (a vakedz
    // limitation, not a source diagnostic — so it can never be mistaken for
    // vakedc's exit-1 "refusing to lower" path).
    if (result.unported_targets.len > 0 and !opts.allow_partial) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        const w = stderrWriter(ls);
        try w.print("vakedz: lowering {s} selects registry targets this build has not ported yet:\n", .{file});
        for (result.unported_targets) |t| try w.print("  - {s}\n", .{t});
        try w.writeAll("vakedz: refusing to write a partial artifact tree (nothing written)\n");
        try w.writeAll("vakedz: pass --allow-partial to write the ported artifacts anyway\n");
        std.process.exit(2);
    }

    // 4) write the tree. The manifest lands at <out>/provenance.json; the rest
    //    of the files are relative paths under <out> (0012 §6.2 erratum).
    const out_dir = opts.out orelse ".vaked/lower";
    const written = try writeTree(aa, io, out_dir, result);
    const ls = try io.lockStderr(&.{}, null);
    defer io.unlockStderr();
    const w = stderrWriter(ls);
    if (result.unported_targets.len > 0) {
        try w.print("vakedz: WARNING: --allow-partial: {s} is an INCOMPLETE lowering; these selected targets emitted nothing:\n", .{out_dir});
        for (result.unported_targets) |t| try w.print("  - {s}\n", .{t});
    }
    try w.print("vakedz: lowered {s} → {s} ({d} files)\n", .{ file, out_dir, written });
}

/// vakedc `__main__._write_tree`: write a LowerResult to `out_dir` — every
/// emitted file at its relative path, plus `provenance.json` at the root.
/// Returns the file count. The ONLY IO in the lowering pipeline (the emitters
/// are pure). `result.files` is already sorted by path, matching Python's
/// `sorted(result.files.items())`.
fn writeTree(a: std.mem.Allocator, io: std.Io, out_dir: []const u8, result: lower_mod.LowerResult) !usize {
    const cwd = std.Io.Dir.cwd();
    var written: usize = 0;
    for (result.files) |f| {
        const dest = try std.fs.path.join(a, &.{ out_dir, f.path });
        if (std.fs.path.dirname(dest)) |dir| try cwd.createDirPath(io, dir);
        try cwd.writeFile(io, .{ .sub_path = dest, .data = f.content });
        written += 1;
    }
    try cwd.createDirPath(io, out_dir);
    const prov_text = try lower_mod.provenanceJsonText(a, result.provenance);
    const prov_path = try std.fs.path.join(a, &.{ out_dir, "provenance.json" });
    try cwd.writeFile(io, .{ .sub_path = prov_path, .data = prov_text });
    written += 1;
    return written;
}

const lib_diag = @import("lib").diagnostic;
