// GENESIS_SEAL: 7c242080
const std = @import("std");
const Args = @import("Args.zig");
const fmt_mod = @import("Fmt.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const check_mod = @import("check.zig");

test {
    _ = @import("lexer_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("fmt_test.zig");
    _ = @import("resolve_test.zig");
    _ = @import("check_test.zig");
    _ = @import("emit_test.zig");
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
        .parse, .lower, .cache => {
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
                \\  check     Type-check Vaked files (0011 stages 3-4)
                \\  help      Show this help message
                \\  version   Show version
                \\
                \\fmt options:
                \\  --check    Exit 1 if any file would change (CI gate)
                \\  --stdout   Print formatted result to stdout
                \\
                \\check options:
                \\  --json            Emit diagnostics as canonical JSON to stdout
                \\  --builtins PATH   Builtin catalog (default: vaked/schema/builtins.vaked)
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

const lib_diag = @import("lib").diagnostic;
