// GENESIS_SEAL: 7c242080
const std = @import("std");
const testing = std.testing;
const cache = @import("cache.zig");

// --- pinned vectors (pre-existing; these lock the primitives) --------------

test "sha256Hex empty string" {
    var out: [64]u8 = undefined;
    cache.sha256Hex("", &out);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "Phase enum" {
    try testing.expectEqualStrings("parse", cache.Phase.parse.str());
    try testing.expectEqualStrings("check", cache.Phase.check.str());
    try testing.expectEqualStrings("lower", cache.Phase.lower.str());
}

test "chainHex from GENESIS" {
    var out: [64]u8 = undefined;
    cache.chainHex(cache.GENESIS, "payload", &out);
    try testing.expectEqualStrings(
        "574feb55908dbb2b4c72bc2dc3e70fc1b8f1b32264e064b5a557c6e6a068b3a8",
        &out,
    );
}

// --- harness ---------------------------------------------------------------

const BUILD_A = "vakedz-git-aaaaaaa";
const BUILD_B = "vakedz-git-bbbbbbb"; // a later compiler build

/// A cache rooted in a per-test temp dir under `.zig-cache/tmp` (Zig's own
/// testing temp location — cleaned up, gitignored, never the source tree).
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    c: cache.Cache,

    fn init() !Fixture {
        return initBuild(BUILD_A);
    }

    fn initBuild(build_id: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try std.fmt.allocPrint(
            testing.allocator,
            ".zig-cache/tmp/{s}",
            .{tmp.sub_path},
        );
        errdefer testing.allocator.free(root);
        const c = try cache.Cache.open(testing.allocator, testing.io, root, build_id);
        return Fixture{ .tmp = tmp, .root = root, .c = c };
    }

    /// Reopen the same on-disk cache as a different compiler build, exactly as
    /// a developer upgrading the compiler would.
    fn reopenAs(self: *Fixture, build_id: []const u8) !void {
        self.c.deinit();
        self.c = try cache.Cache.open(testing.allocator, testing.io, self.root, build_id);
    }

    fn deinit(self: *Fixture) void {
        self.c.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn chainPath(self: *Fixture, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/chain", .{self.c.root});
    }

    fn readChainText(self: *Fixture, a: std.mem.Allocator) ![]u8 {
        const path = try self.chainPath(a);
        defer a.free(path);
        const f = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
        defer f.close(testing.io);
        const st = try f.stat(testing.io);
        const buf = try a.alloc(u8, @intCast(st.size));
        errdefer a.free(buf);
        const n = try f.readPositionalAll(testing.io, buf, 0);
        return if (n != buf.len) a.realloc(buf, n) else buf;
    }

    fn writeChainText(self: *Fixture, text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const path = try self.chainPath(arena.allocator());
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = text });
    }
};

const check_inputs: cache.Inputs = .{ .check = .{ .builtins = "builtin fiber" } };

// --- open ------------------------------------------------------------------

test "open joins the cache dir under root" {
    var f = try Fixture.init();
    defer f.deinit();
    const want = try std.fmt.allocPrint(testing.allocator, "{s}/.vakedz-cache", .{f.root});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, f.c.root);
}

// `Inputs` makes you NAME builtins; these make you MEAN it. `.builtins = ""`
// compiles, so the emptiness check is the only thing standing between a
// `readFileAlloc(...) orelse ""` and a permanently poisoned key.
test "check rejects empty builtins" {
    var f = try Fixture.init();
    defer f.deinit();
    const empty: cache.Inputs = .{ .check = .{ .builtins = "" } };
    try testing.expectError(error.BuiltinsRequired, f.c.lookup("a.vaked", "src", empty));
    try testing.expectError(error.BuiltinsRequired, f.c.put("a.vaked", "src", empty, "OUT"));
}

test "lower rejects empty builtins" {
    var f = try Fixture.init();
    defer f.deinit();
    const empty: cache.Inputs = .{ .lower = .{ .builtins = "", .options = "{}" } };
    try testing.expectError(error.BuiltinsRequired, f.c.lookup("a.vaked", "src", empty));
    try testing.expectError(error.BuiltinsRequired, f.c.put("a.vaked", "src", empty, "OUT"));
}

// Empty options are ambiguous between "defaults" and "forgot", so defaults get
// a canonical non-empty spelling instead.
test "lower rejects empty options but accepts canonical defaults" {
    var f = try Fixture.init();
    defer f.deinit();
    const empty: cache.Inputs = .{ .lower = .{ .builtins = "B", .options = "" } };
    try testing.expectError(error.OptionsRequired, f.c.lookup("a.vaked", "src", empty));
    try testing.expectError(error.OptionsRequired, f.c.put("a.vaked", "src", empty, "OUT"));

    const defaults: cache.Inputs = .{ .lower = .{ .builtins = "B", .options = "{}" } };
    try f.c.put("a.vaked", "src", defaults, "OUT");
    const hit = try f.c.lookup("a.vaked", "src", defaults);
    try testing.expect(hit != null);
    defer testing.allocator.free(hit.?);
    try testing.expectEqualStrings("OUT", hit.?);
}

test "open rejects an empty build id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(root);
    try testing.expectError(
        error.BuildIdRequired,
        cache.Cache.open(testing.allocator, testing.io, root, ""),
    );
}

// --- round trip ------------------------------------------------------------

test "miss then put then hit" {
    var f = try Fixture.init();
    defer f.deinit();

    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", .parse));

    try f.c.put("a.vaked", "src", .parse, "OUT");

    const hit = try f.c.lookup("a.vaked", "src", .parse);
    try testing.expect(hit != null);
    defer testing.allocator.free(hit.?);
    try testing.expectEqualStrings("OUT", hit.?);
}

test "empty output round-trips (not confused with a miss)" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "");
    const hit = try f.c.lookup("a.vaked", "src", .parse);
    try testing.expect(hit != null);
    defer testing.allocator.free(hit.?);
    try testing.expectEqualStrings("", hit.?);
}

// --- key sensitivity: each input must invalidate ---------------------------

test "source change misses" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "OUT");
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src2", .parse));
}

test "file identity change misses" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "OUT");
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("b.vaked", "src", .parse));
}

// The regression this module exists to prevent: a parser bugfix changes output
// with every byte of data identical. Keying only data serves the pre-fix AST to
// the post-fix compiler.
test "build identity change misses (compiler upgrade)" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "AST-FROM-BUGGY-PARSER");

    // Same source, same file, same grammar — only the compiler changed.
    try f.reopenAs(BUILD_B);
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", .parse));

    // And the original build still hits: the entry was invalidated, not lost.
    try f.reopenAs(BUILD_A);
    const hit = try f.c.lookup("a.vaked", "src", .parse);
    try testing.expect(hit != null);
    defer testing.allocator.free(hit.?);
    try testing.expectEqualStrings("AST-FROM-BUGGY-PARSER", hit.?);
}

test "build identity change misses for check and lower too" {
    var f = try Fixture.init();
    defer f.deinit();
    const lower_inputs: cache.Inputs = .{ .lower = .{ .builtins = "B", .options = "O" } };
    try f.c.put("a.vaked", "src", check_inputs, "CHECK_OUT");
    try f.c.put("a.vaked", "src", lower_inputs, "LOWER_OUT");

    try f.reopenAs(BUILD_B);
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", check_inputs));
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", lower_inputs));
}

test "builtins change misses" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", check_inputs, "OUT");

    const hit = try f.c.lookup("a.vaked", "src", check_inputs);
    try testing.expect(hit != null);
    testing.allocator.free(hit.?);

    const changed: cache.Inputs = .{ .check = .{ .builtins = "builtin fiber + engine" } };
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", changed));
}

test "lower options change misses" {
    var f = try Fixture.init();
    defer f.deinit();
    const a: cache.Inputs = .{ .lower = .{ .builtins = "B", .options = "{\"out\":\"x\"}" } };
    const b: cache.Inputs = .{ .lower = .{ .builtins = "B", .options = "{\"out\":\"y\"}" } };
    try f.c.put("a.vaked", "src", a, "OUT");
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", b));
}

test "GRAMMAR_VERSION change misses" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "OUT");

    f.c.grammar = "v0.6"; // simulate a language-spec bump
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", .parse));

    f.c.grammar = cache.GRAMMAR_VERSION;
    const hit = try f.c.lookup("a.vaked", "src", .parse);
    try testing.expect(hit != null);
    testing.allocator.free(hit.?);
}

test "phase isolation: a parse entry never serves a check lookup" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "PARSE_OUT");
    const lower_inputs: cache.Inputs = .{ .lower = .{ .builtins = "builtin fiber", .options = "{}" } };
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", check_inputs));
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", lower_inputs));
}

// check and lower can carry an identical builtins dep; only `phase` separates
// their keys.
test "check and lower with identical inputs key differently" {
    var f = try Fixture.init();
    defer f.deinit();
    var k_check: [64]u8 = undefined;
    var k_lower: [64]u8 = undefined;
    try f.c.deriveKey("a.vaked", "src", .{ .check = .{ .builtins = "B" } }, &k_check);
    try f.c.deriveKey("a.vaked", "src", .{ .lower = .{ .builtins = "B", .options = "{}" } }, &k_lower);
    try testing.expect(!std.mem.eql(u8, &k_check, &k_lower));
}

test "Inputs.phase reports the active tag" {
    try testing.expectEqual(cache.Phase.parse, (cache.Inputs{ .parse = {} }).phase());
    try testing.expectEqual(cache.Phase.check, check_inputs.phase());
    try testing.expectEqual(
        cache.Phase.lower,
        (cache.Inputs{ .lower = .{ .builtins = "B", .options = "O" } }).phase(),
    );
}

// --- verify ----------------------------------------------------------------

test "verify on a fresh cache is ok and empty" {
    var f = try Fixture.init();
    defer f.deinit();
    const vr = try f.c.verify();
    try testing.expect(vr.ok);
    try testing.expectEqual(@as(usize, 0), vr.entries);
    try testing.expectEqual(@as(usize, 0), vr.valid_prefix);
}

test "verify on a clean chain reports every entry valid" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "s1", .parse, "O1");
    try f.c.put("b.vaked", "s2", .parse, "O2");
    try f.c.put("c.vaked", "s3", .parse, "O3");

    const vr = try f.c.verify();
    try testing.expect(vr.ok);
    try testing.expectEqual(@as(usize, 3), vr.entries);
    try testing.expectEqual(@as(usize, 3), vr.valid_prefix);
}

test "repeated identical put does not grow the chain" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "s1", .parse, "O1");
    try f.c.put("a.vaked", "s1", .parse, "O1");
    const vr = try f.c.verify();
    try testing.expect(vr.ok);
    try testing.expectEqual(@as(usize, 1), vr.entries);
}

test "truncated chain: valid prefix intact but ok is false" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "s1", .parse, "O1");
    try f.c.put("b.vaked", "s2", .parse, "O2");
    try f.c.put("c.vaked", "s3", .parse, "O3");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Drop the last entry line, leaving the header claiming 3.
    const text = try f.readChainText(a);
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > 0) try lines.append(a, l);
    }
    try testing.expectEqual(@as(usize, 4), lines.items.len); // header + 3

    const kept = try std.mem.join(a, "\n", lines.items[0..3]);
    const truncated = try std.fmt.allocPrint(a, "{s}\n", .{kept});
    try f.writeChainText(truncated);

    const vr = try f.c.verify();
    try testing.expectEqual(@as(usize, 2), vr.entries);
    try testing.expectEqual(@as(usize, 2), vr.valid_prefix); // survivors still link
    try testing.expect(!vr.ok); // but the header anchors the true length
}

// The header carries both `count` and `head_link`. Truncation trips the head
// check, so this pins `count` independently: a header that lies about the
// length while still naming the correct head must not report ok.
test "header count disagreeing with the body is not ok" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "s1", .parse, "O1");
    try f.c.put("b.vaked", "s2", .parse, "O2");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text = try f.readChainText(a);
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > 0) try lines.append(a, l);
    }

    // Rewrite only the header's count; keep the (correct) head link.
    var h = std.mem.splitScalar(u8, lines.items[0], ' ');
    _ = h.next().?; // schema
    _ = h.next().?; // count
    const head = h.next().?;
    lines.items[0] = try std.fmt.allocPrint(a, "{s} 5 {s}", .{ cache.SCHEMA, head });

    const joined = try std.mem.join(a, "\n", lines.items);
    try f.writeChainText(try std.fmt.allocPrint(a, "{s}\n", .{joined}));

    const vr = try f.c.verify();
    try testing.expectEqual(@as(usize, 2), vr.entries);
    try testing.expectEqual(@as(usize, 2), vr.valid_prefix); // bodies still link
    try testing.expect(!vr.ok); // but the count is a lie
}

test "tampered payload mid-chain is detected at its index" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "s1", .parse, "O1");
    try f.c.put("b.vaked", "s2", .parse, "O2");
    try f.c.put("c.vaked", "s3", .parse, "O3");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text = try f.readChainText(a);
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > 0) try lines.append(a, l);
    }

    // Repoint entry index 1 (line 2) at a different blob, leaving its link.
    var parts = std.mem.splitScalar(u8, lines.items[2], ' ');
    const key = parts.next().?;
    _ = parts.next().?;
    const len = parts.next().?;
    const link = parts.next().?;
    lines.items[2] = try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{
        key, "a" ** 64, len, link,
    });

    const joined = try std.mem.join(a, "\n", lines.items);
    try f.writeChainText(try std.fmt.allocPrint(a, "{s}\n", .{joined}));

    const vr = try f.c.verify();
    try testing.expectEqual(@as(usize, 3), vr.entries);
    try testing.expectEqual(@as(usize, 1), vr.valid_prefix); // tamper is at index 1
    try testing.expect(!vr.ok);
}

test "tampered chain never serves a hit past the tamper" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "s1", .parse, "O1");
    try f.c.put("b.vaked", "s2", .parse, "O2");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text = try f.readChainText(a);
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > 0) try lines.append(a, l);
    }
    // Corrupt entry 0 (line 1); entry 1 then falls outside the valid prefix.
    var parts = std.mem.splitScalar(u8, lines.items[1], ' ');
    const key = parts.next().?;
    _ = parts.next().?;
    const len = parts.next().?;
    const link = parts.next().?;
    lines.items[1] = try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ key, "b" ** 64, len, link });
    const joined = try std.mem.join(a, "\n", lines.items);
    try f.writeChainText(try std.fmt.allocPrint(a, "{s}\n", .{joined}));

    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "s1", .parse));
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("b.vaked", "s2", .parse));
}

test "put refuses to append to a broken chain" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "s1", .parse, "O1");
    try f.writeChainText(cache.SCHEMA ++ " 9 " ++ "c" ** 64 ++ "\n");
    try testing.expectError(error.ChainBroken, f.c.put("b.vaked", "s2", .parse, "O2"));
}

// --- corruption tolerance --------------------------------------------------

test "garbage chain file reads as a miss and verify reports not-ok" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.writeChainText("this is not a chain\n\x00\xff garbage");

    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", .parse));
    const vr = try f.c.verify();
    try testing.expect(!vr.ok);
    try testing.expectEqual(@as(usize, 0), vr.entries);
}

test "empty chain file reads as a miss, not a crash" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.writeChainText("");
    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", .parse));
    const vr = try f.c.verify();
    try testing.expect(!vr.ok);
}

test "missing CAS blob reads as a miss, not a crash" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "OUT");

    // Delete the blob out from under an otherwise valid chain entry.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var content: [64]u8 = undefined;
    cache.sha256Hex("OUT", &content);
    const blob = try std.fmt.allocPrint(a, "{s}/cas/{s}/{s}", .{
        f.c.root, content[0..2], content[2..],
    });
    try std.Io.Dir.cwd().deleteFile(testing.io, blob);

    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", .parse));
}

test "corrupted CAS blob reads as a miss, never a wrong hit" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.c.put("a.vaked", "src", .parse, "OUT");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var content: [64]u8 = undefined;
    cache.sha256Hex("OUT", &content);
    const blob = try std.fmt.allocPrint(a, "{s}/cas/{s}/{s}", .{
        f.c.root, content[0..2], content[2..],
    });
    // Same length, different bytes: only the content hash catches this.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = blob, .data = "EVL" });

    try testing.expectEqual(@as(?[]u8, null), try f.c.lookup("a.vaked", "src", .parse));
}
