const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FmtOptions = struct {
    paths: []const []const u8,
    check: bool = false,
    stdout: bool = false,
};

pub const CheckOptions = struct {
    paths: []const []const u8,
    json: bool = false,
    /// Overrides the builtin catalog path (default:
    /// vaked/schema/builtins.vaked relative to the CWD).
    builtins: ?[]const u8 = null,
};

/// Mirrors `python3 -m vakedc parse <file> [--json P] [--sqlite P]
/// [--print]`. NOTE: unlike check's boolean `--json`, parse's `--json`
/// takes a PATH argument (vakedc parity).
pub const ParseOptions = struct {
    paths: []const []const u8,
    json: ?[]const u8 = null,
    sqlite: ?[]const u8 = null,
    print: bool = false,
};

/// Mirrors `python3 -m vakedc lower <file> [--out DIR] [--builtins PATH]`.
/// NOTE: unlike fmt/parse/check, lower takes exactly ONE file (vakedc's
/// argparse declares a single positional `file`); `file` is null when none was
/// given, which the driver reports as a usage error.
pub const LowerOptions = struct {
    file: ?[]const u8 = null,
    /// Output directory for the artifact tree (default: `.vaked/lower/`
    /// under the CWD, exactly like vakedc).
    out: ?[]const u8 = null,
    /// Overrides the builtin catalog path (default:
    /// vaked/schema/builtins.vaked relative to the CWD).
    builtins: ?[]const u8 = null,
    /// vakedz-only (NOT a vakedc flag): write the artifact tree even when the
    /// graph selects registry targets this build has not ported yet, so the
    /// per-artifact differential harness can compare the artifacts that ARE
    /// ported. The tree is knowingly INCOMPLETE — never use it as a real
    /// lowering. Without this flag such a graph is refused (exit 2).
    allow_partial: bool = false,
};

pub const Command = union(enum) {
    fmt: FmtOptions,
    parse: ParseOptions,
    check: CheckOptions,
    lower: LowerOptions,
    cache,
    help,
    version,
};

pub fn parse(allocator: Allocator, args: []const []const u8) Command {
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
    if (std.mem.eql(u8, first, "parse")) {
        var json: ?[]const u8 = null;
        var sqlite: ?[]const u8 = null;
        var print = false;
        var paths = std.ArrayList([]const u8).empty;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--json") and i + 1 < args.len) {
                i += 1;
                json = args[i];
            } else if (std.mem.eql(u8, a, "--sqlite") and i + 1 < args.len) {
                i += 1;
                sqlite = args[i];
            } else if (std.mem.eql(u8, a, "--print")) {
                print = true;
            } else {
                paths.append(allocator, a) catch return .help;
            }
        }

        return .{ .parse = .{
            .paths = paths.toOwnedSlice(allocator) catch return .help,
            .json = json,
            .sqlite = sqlite,
            .print = print,
        } };
    }
    if (std.mem.eql(u8, first, "check")) {
        var json = false;
        var builtins: ?[]const u8 = null;
        var paths = std.ArrayList([]const u8).empty;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--json")) {
                json = true;
            } else if (std.mem.eql(u8, a, "--builtins") and i + 1 < args.len) {
                i += 1;
                builtins = args[i];
            } else {
                paths.append(allocator, a) catch return .help;
            }
        }

        return .{ .check = .{
            .paths = paths.toOwnedSlice(allocator) catch return .help,
            .json = json,
            .builtins = builtins,
        } };
    }
    if (std.mem.eql(u8, first, "lower")) {
        var file: ?[]const u8 = null;
        var out: ?[]const u8 = null;
        var builtins: ?[]const u8 = null;
        var allow_partial = false;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
                i += 1;
                out = args[i];
            } else if (std.mem.eql(u8, a, "--builtins") and i + 1 < args.len) {
                i += 1;
                builtins = args[i];
            } else if (std.mem.eql(u8, a, "--allow-partial")) {
                allow_partial = true;
            } else if (file == null) {
                file = a;
            }
            // Extra positionals are ignored: argparse would error, but the
            // single-file contract is enforced by the driver on `file`.
        }

        return .{ .lower = .{
            .file = file,
            .out = out,
            .builtins = builtins,
            .allow_partial = allow_partial,
        } };
    }
    if (std.mem.eql(u8, first, "cache")) return .cache;

    return .help;
}
