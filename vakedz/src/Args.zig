const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FmtOptions = struct {
    paths: []const []const u8,
    check: bool = false,
    stdout: bool = false,
};

pub const Command = union(enum) {
    fmt: FmtOptions,
    parse,
    check,
    lower,
    cache,
    help,
    version,
};

pub fn parse(allocator: Allocator, args: []const []const u8) Command {
    _ = allocator;
    if (args.len == 0) return .help;

    const first = args[0];
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version")) {
        return .version;
    }
    if (std.mem.eql(u8, first, "fmt")) {
        var check = false;
        var stdout = false;
        var paths_start: usize = 1;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--check")) {
                check = true;
                paths_start = i + 1;
            } else if (std.mem.eql(u8, a, "--stdout")) {
                stdout = true;
                paths_start = i + 1;
            } else {
                break;
            }
        }

        return .{ .fmt = .{
            .paths = args[paths_start..],
            .check = check,
            .stdout = stdout,
        } };
    }
    if (std.mem.eql(u8, first, "parse")) return .parse;
    if (std.mem.eql(u8, first, "check")) return .check;
    if (std.mem.eql(u8, first, "lower")) return .lower;
    if (std.mem.eql(u8, first, "cache")) return .cache;

    return .help;
}
