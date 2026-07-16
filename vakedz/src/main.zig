// GENESIS_SEAL: 7c242080
const std = @import("std");
const Args = @import("Args.zig");
const fmt_mod = @import("Fmt.zig");
const lex = @import("lexer.zig");
const parser_mod = @import("parser.zig");

test {
    _ = @import("lexer_test.zig");
    _ = @import("parser_test.zig");
    _ = @import("fmt_test.zig");
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
        .parse, .check, .lower, .cache => {
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
                \\  help      Show this help message
                \\  version   Show version
                \\
                \\fmt options:
                \\  --check    Exit 1 if any file would change (CI gate)
                \\  --stdout   Print formatted result to stdout
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
    return buf[0..n];
}

fn stderrWriter(ls: std.Io.LockedStderr) *std.Io.Writer {
    return &ls.file_writer.*.interface;
}

fn runFmt(allocator: std.mem.Allocator, io: std.Io, opts: Args.FmtOptions) !void {
    if (opts.paths.len == 0) {
        const ls = try io.lockStderr(&.{}, null);
        defer io.unlockStderr();
        try stderrWriter(ls).writeAll("vaked fmt: no files specified\n");
        std.process.exit(1);
    }

    var any_changed = false;

    for (opts.paths) |path| {
        const source = readFileAlloc(allocator, io, path) catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vaked fmt: cannot open '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        };
        defer allocator.free(source);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var l = lex.Lexer.init(aa, source);
        l.run() catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vaked fmt: lex error in '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        };

        var p = parser_mod.Parser.init(aa, l.tokens.items);
        const items = p.parseFile() catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            if (p.err) |pe| {
                try stderrWriter(ls).print("vaked fmt: parse error in '{s}': {} at line {} col {}\n", .{ path, err, pe.line, pe.col });
            } else {
                try stderrWriter(ls).print("vaked fmt: parse error in '{s}': {}\n", .{ path, err });
            }
            std.process.exit(1);
        };

        var out: std.ArrayList(u8) = .empty;

        fmt_mod.formatFile(aa, items, &out) catch |err| {
            const ls = try io.lockStderr(&.{}, null);
            defer io.unlockStderr();
            try stderrWriter(ls).print("vaked fmt: format error in '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        };

        if (opts.stdout) {
            try std.Io.File.stdout().writeStreamingAll(io, out.items);
        } else {
            const original_size = source.len;
            const formatted_size = out.items.len;
            if (original_size != formatted_size or !std.mem.eql(u8, source, out.items)) {
                any_changed = true;
                if (!opts.check) {
                    const cwd = std.Io.Dir.cwd();
                    try cwd.writeFile(io, .{ .sub_path = path, .data = out.items });
                }
            }
        }
    }

    if (opts.check and any_changed) {
        std.process.exit(1);
    }
}
