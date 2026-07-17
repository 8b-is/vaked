// GENESIS_SEAL: 7c242080
//! Content-addressed, hash-chained compile cache.
//!
//! # Safety posture
//!
//! The design rule is **a miss is free, a wrong hit is fatal**. Every path in
//! here is biased toward returning `null` (recompute) rather than serving a
//! byte it is not certain about. Concretely:
//!
//! * A blob is only returned if `sha256(blob)` equals the content hash the
//!   chain entry committed to, AND the length matches. A corrupted or swapped
//!   CAS blob reads as a miss, never as a hit.
//! * Only entries inside the cryptographically valid chain prefix are
//!   eligible to serve a hit.
//! * Any parse failure, short read, or unexpected shape degrades to a miss.
//!
//! # Key derivation
//!
//! The cache key is `sha256(K)` where `K` is the canonical JSON document
//! (compact, keys in the fixed order below — `json.zig` never reorders, so
//! canonicality is produced here deliberately):
//!
//! ```text
//! {"deps":[{"name":<name>,"sha256":<hex>},...],
//!  "file":<path>,
//!  "grammar":<grammar version>,
//!  "phase":"parse"|"check"|"lower",
//!  "schema":"vakedz-cache-1",
//!  "source":<sha256(source bytes) hex>}
//! ```
//!
//! Field-by-field rationale:
//!
//! * `source` — the source bytes decide the output. Hashed, not embedded, so
//!   the key stays fixed-size.
//! * `file` — the path is *not* incidental: diagnostics and provenance embed
//!   the filename, so two identical sources at different paths legitimately
//!   produce different output. The path is used verbatim, so `./a.vaked` and
//!   `a.vaked` key differently — that costs an extra miss, never a wrong hit.
//! * `grammar` — a grammar bump changes parse/check/lower semantics, so it
//!   must invalidate. Defaults to `GRAMMAR_VERSION`; a field on `Cache` so a
//!   bump is expressible (and testable) without recompiling constants.
//! * `phase` — hard isolation: a `parse` entry can never serve a `check`
//!   lookup even at an identical source.
//! * `schema` — this file's on-disk/keying contract. Bumping it invalidates
//!   every key, which is what a layout or derivation change requires.
//! * `deps` — every *other* input the caller knows affects output, hashed by
//!   content. Sorted by (name, hash) here, so caller ordering cannot change a
//!   key. See the contract below.
//!
//! # The `deps` contract — read this before caching a new phase
//!
//! `parse` is self-contained: source + file + grammar + phase is the complete
//! input set, and this module can see all of it. It is sound with no deps.
//!
//! `check` and `lower` are **not** self-contained — they additionally depend on
//! the builtins catalog (`vaked/schema/builtins.vaked`), and `lower` further
//! depends on its lowering options. This module cannot read those; only the
//! caller knows them. So the contract is inverted: the caller MUST pass every
//! such input as a `Dep`, and `lookup`/`put` **reject** `.check`/`.lower` with
//! an empty dep set (`error.DepsRequired`) rather than silently computing an
//! unsound key.
//!
//! That enforcement is a guardrail, not a proof: this module can verify that
//! deps were supplied, but it cannot verify they are the *right* ones. A caller
//! that passes a stale or wrong dep gets a wrong hit. Soundness for
//! `check`/`lower` therefore rests with the caller — keep the dep set in the
//! same function that reads the inputs, so the two cannot drift.
//!
//! # On-disk layout
//!
//! ```text
//! .vakedz-cache/
//!   chain          # header line + one line per entry (the index AND the log)
//!   lock           # advisory lock file; guards the chain read-modify-write
//!   cas/<xx>/<yy>  # blob, named by sha256(content): xx = first 2 hex, yy = other 62
//! ```
//!
//! `chain` is deliberately both the log and the lookup index. A separate index
//! could disagree with the log; one file cannot.
//!
//! ```text
//! vakedz-cache-1 <count> <head_link>
//! <key_hex> <content_hex> <len> <link_hex>
//! ...
//! ```
//!
//! # Chain design and what tamper-evidence means here
//!
//! Entry `i` commits to payload `P_i = "<key> <content> <len>"` with
//! `link_i = chainHex(link_{i-1}, P_i)`, rooted at `link_{-1} = GENESIS`.
//! `verify()` recomputes each link and reports the longest valid prefix, so a
//! mid-chain edit is localized to its index. The header's `count`/`head_link`
//! anchor the chain's *length*: a plain hash chain cannot detect having its
//! tail lopped off (a prefix of a valid chain is itself a valid chain), so
//! truncation is caught by the header disagreeing with the body.
//!
//! **This is tamper-evidence against truncation, partial edits, and bit-rot —
//! not against an adversary.** Anyone with write access to `.vakedz-cache/` can
//! rewrite the body and recompute the header consistently. Detecting that needs
//! an anchor outside the cache (a signature or an external head pointer), which
//! this module does not have and does not claim.
//!
//! # Concurrency envelope
//!
//! * **Writers** serialize on an advisory exclusive lock over `lock` for the
//!   whole read-modify-write of `chain`. Safe for concurrent processes on a
//!   local POSIX filesystem. The lock is advisory: it only coordinates
//!   processes going through this API, and it is not guaranteed over NFS or
//!   other network filesystems.
//! * **Readers take no lock and need none.** `chain` is only ever replaced
//!   whole via create-temp + atomic rename, so a reader observes either the
//!   complete old chain or the complete new one — never a torn entry.
//! * CAS blobs are written before the chain entry that references them, and are
//!   content-addressed, so a concurrent writer of the same blob writes
//!   identical bytes. A crash between blob write and chain append leaks an
//!   unreferenced blob (wasted space, never incorrect).
//! * `put` refuses to append to a chain that fails verification
//!   (`error.ChainBroken`) rather than building on a corrupt base. Remediation
//!   is to delete `.vakedz-cache/`.
const std = @import("std");
const json = @import("json.zig");

pub const GENESIS: [64]u8 = [_]u8{'0'} ** 64;
pub const GRAMMAR_VERSION: []const u8 = "v0.5";
pub const CACHE_DIR: []const u8 = ".vakedz-cache";

/// On-disk + key-derivation contract version. Bump on any change to the
/// layout, the chain format, or the key document: it invalidates every key.
pub const SCHEMA: []const u8 = "vakedz-cache-1";

pub const Phase = enum {
    parse,
    check,
    lower,

    pub fn str(self: Phase) []const u8 {
        return switch (self) {
            .parse => "parse",
            .check => "check",
            .lower => "lower",
        };
    }

    /// Whether this phase reads inputs beyond (source, file, grammar) that
    /// only the caller can supply. See the deps contract in the module doc.
    pub fn requiresDeps(self: Phase) bool {
        return switch (self) {
            .parse => false,
            .check, .lower => true,
        };
    }
};

/// A named, content-hashed input that affects a phase's output but that this
/// module cannot read for itself (e.g. `.{ .name = "builtins", .bytes = src }`).
pub const Dep = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const VerifyResult = struct {
    /// Entry lines present in the chain body.
    entries: usize,
    /// Length of the cryptographically valid prefix. Equals the index of the
    /// first entry whose link does not recompute.
    valid_prefix: usize,
    /// Whole chain intact: every entry links, and the header's count/head
    /// agree with the body (i.e. no truncation).
    ok: bool,
};

pub const Error = error{
    /// `.check`/`.lower` were used with an empty dep set. See the deps contract.
    DepsRequired,
    /// Refusing to append to a chain that does not verify.
    ChainBroken,
};

const Entry = struct {
    key: [64]u8,
    content: [64]u8,
    len: usize,
    link: [64]u8,
};

const Header = struct {
    count: usize,
    head: [64]u8,
};

const Chain = struct {
    header: Header,
    entries: []Entry,
};

/// Three genuinely different situations that must not be collapsed: a fresh
/// cache (absent) is intact-and-empty, whereas an unparseable chain file is a
/// fault and must not report `ok`.
const ChainState = union(enum) {
    absent,
    corrupt,
    present: Chain,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    /// Grammar version mixed into every key. Split out from the constant so a
    /// bump is expressible without recompiling — and so it is testable.
    grammar: []const u8,

    /// Open (creating if absent) the cache under `<root>/.vakedz-cache`.
    /// `root` is resolved against the process cwd, mirroring vakedz/src/main.zig.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Cache {
        const cache_root = try std.fs.path.join(allocator, &.{ root, CACHE_DIR });
        errdefer allocator.free(cache_root);

        const cwd = std.Io.Dir.cwd();
        // createDirPath is idempotent. NOTE for future maintainers: 0.16 has no
        // `makeDir`/`makePath` on std.Io.Dir — the spelling is createDir* and
        // every filesystem call takes an `io`.
        try cwd.createDirPath(io, cache_root);
        const cas_dir = try std.fs.path.join(allocator, &.{ cache_root, "cas" });
        defer allocator.free(cas_dir);
        try cwd.createDirPath(io, cas_dir);

        return Cache{
            .allocator = allocator,
            .io = io,
            .root = cache_root,
            .grammar = GRAMMAR_VERSION,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.root);
    }

    /// Derive the cache key. See the module doc for the exact document.
    pub fn deriveKey(
        self: *Cache,
        file: []const u8,
        source: []const u8,
        phase: Phase,
        deps: []const Dep,
        out: *[64]u8,
    ) !void {
        if (phase.requiresDeps() and deps.len == 0) return Error.DepsRequired;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var src_hex: [64]u8 = undefined;
        sha256Hex(source, &src_hex);

        const dep_vals = try a.alloc(json.Value, deps.len);
        for (deps, 0..) |d, i| {
            var dep_hex: [64]u8 = undefined;
            sha256Hex(d.bytes, &dep_hex);
            const obj = try a.alloc(json.Value.Entry, 2);
            obj[0] = .{ .key = "name", .value = .{ .string = d.name } };
            obj[1] = .{ .key = "sha256", .value = .{ .string = try a.dupe(u8, &dep_hex) } };
            dep_vals[i] = .{ .object = obj };
        }
        // Sort so caller ordering cannot change the key.
        std.mem.sort(json.Value, dep_vals, {}, depLess);

        const top = try a.alloc(json.Value.Entry, 6);
        top[0] = .{ .key = "deps", .value = .{ .array = dep_vals } };
        top[1] = .{ .key = "file", .value = .{ .string = file } };
        top[2] = .{ .key = "grammar", .value = .{ .string = self.grammar } };
        top[3] = .{ .key = "phase", .value = .{ .string = phase.str() } };
        top[4] = .{ .key = "schema", .value = .{ .string = SCHEMA } };
        top[5] = .{ .key = "source", .value = .{ .string = &src_hex } };

        const canonical = try (json.Value{ .object = top }).toOwned(a);
        sha256Hex(canonical, out);
    }

    /// Return the cached output for this key, or null on any doubt.
    /// Caller owns the returned slice.
    pub fn lookup(
        self: *Cache,
        file: []const u8,
        source: []const u8,
        phase: Phase,
        deps: []const Dep,
    ) !?[]u8 {
        var key: [64]u8 = undefined;
        try self.deriveKey(file, source, phase, deps, &key);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const chain = switch (try self.readChain(a)) {
            .absent, .corrupt => return null, // any doubt is a miss
            .present => |c| c,
        };
        const vr = verifyChain(chain);

        // Only the cryptographically intact prefix may serve a hit.
        var i = vr.valid_prefix;
        while (i > 0) {
            i -= 1;
            const e = chain.entries[i];
            if (!std.mem.eql(u8, &e.key, &key)) continue;

            const blob = (try self.readBlob(self.allocator, e.content)) orelse return null;
            errdefer self.allocator.free(blob);

            // The blob must be exactly what the chain committed to. This is the
            // last line of defence against a swapped or rotted CAS file.
            if (blob.len != e.len) {
                self.allocator.free(blob);
                return null;
            }
            var actual: [64]u8 = undefined;
            sha256Hex(blob, &actual);
            if (!std.mem.eql(u8, &actual, &e.content)) {
                self.allocator.free(blob);
                return null;
            }
            return blob;
        }
        return null;
    }

    /// Store `output` for this key: write the blob, then append a chain entry.
    pub fn put(
        self: *Cache,
        file: []const u8,
        source: []const u8,
        phase: Phase,
        deps: []const Dep,
        output: []const u8,
    ) !void {
        var key: [64]u8 = undefined;
        try self.deriveKey(file, source, phase, deps, &key);

        var content: [64]u8 = undefined;
        sha256Hex(output, &content);

        const io = self.io;
        const cwd = std.Io.Dir.cwd();

        // Serialize writers for the whole read-modify-write of `chain`.
        const lock_path = try std.fs.path.join(self.allocator, &.{ self.root, "lock" });
        defer self.allocator.free(lock_path);
        const lock_file = try cwd.createFile(io, lock_path, .{ .truncate = false });
        defer lock_file.close(io);
        try lock_file.lock(io, .exclusive);
        defer lock_file.unlock(io);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const chain = switch (try self.readChain(a)) {
            .absent => Chain{ .header = .{ .count = 0, .head = GENESIS }, .entries = &.{} },
            .corrupt => return Error.ChainBroken,
            .present => |c| c,
        };
        const vr = verifyChain(chain);
        if (!vr.ok) return Error.ChainBroken;

        // Exact (key, content) already committed: nothing to add. Keeps repeated
        // puts from growing the chain without bound.
        for (chain.entries) |e| {
            if (std.mem.eql(u8, &e.key, &key) and std.mem.eql(u8, &e.content, &content)) return;
        }

        // Blob first, so a chain entry never references a missing blob.
        try self.writeBlob(content, output);

        const prev: [64]u8 = if (chain.entries.len == 0) GENESIS else chain.entries[chain.entries.len - 1].link;
        var payload_buf: std.Io.Writer.Allocating = .init(a);
        try payload_buf.writer.print("{s} {s} {d}", .{ &key, &content, output.len });
        const payload = payload_buf.written();

        var link: [64]u8 = undefined;
        chainHex(prev, payload, &link);

        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.print("{s} {d} {s}\n", .{ SCHEMA, chain.entries.len + 1, &link });
        for (chain.entries) |e| {
            // Re-emit stored links verbatim — never silently "repair" a chain.
            try out.writer.print("{s} {s} {d} {s}\n", .{ &e.key, &e.content, e.len, &e.link });
        }
        try out.writer.print("{s} {s}\n", .{ payload, &link });

        try self.writeAtomic("chain", out.written());
    }

    /// Walk the chain, reporting entry count, longest valid prefix, and whether
    /// the whole chain (including its length) is intact.
    pub fn verify(self: *Cache) !VerifyResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        return switch (try self.readChain(a)) {
            // A fresh cache is vacuously intact.
            .absent => VerifyResult{ .entries = 0, .valid_prefix = 0, .ok = true },
            // A chain file we cannot parse is a fault, not an empty cache.
            .corrupt => VerifyResult{ .entries = 0, .valid_prefix = 0, .ok = false },
            .present => |c| verifyChain(c),
        };
    }

    // --- internals ---------------------------------------------------------

    fn readChain(self: *Cache, a: std.mem.Allocator) !ChainState {
        const path = try std.fs.path.join(a, &.{ self.root, "chain" });
        const text = (try readFileAlloc(a, self.io, path)) orelse return .absent;
        const chain = (try parseChain(a, text)) orelse return .corrupt;
        return .{ .present = chain };
    }

    fn blobPath(self: *Cache, a: std.mem.Allocator, content: [64]u8) ![]const u8 {
        return std.fs.path.join(a, &.{ self.root, "cas", content[0..2], content[2..] });
    }

    fn readBlob(self: *Cache, a: std.mem.Allocator, content: [64]u8) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const path = try self.blobPath(arena.allocator(), content);
        return readFileAlloc(a, self.io, path);
    }

    fn writeBlob(self: *Cache, content: [64]u8, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const rel = try std.fs.path.join(a, &.{ "cas", content[0..2], content[2..] });
        try self.writeAtomic(rel, data);
    }

    /// Create-temp + atomic rename, so a reader never observes a partial file.
    fn writeAtomic(self: *Cache, rel_path: []const u8, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const path = try std.fs.path.join(arena.allocator(), &.{ self.root, rel_path });

        const io = self.io;
        const cwd = std.Io.Dir.cwd();
        var af = try cwd.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, data);
        try af.replace(io);
    }
};

fn depLess(_: void, lhs: json.Value, rhs: json.Value) bool {
    const l = lhs.object;
    const r = rhs.object;
    const name = std.mem.order(u8, l[0].value.string, r[0].value.string);
    if (name != .eq) return name == .lt;
    return std.mem.order(u8, l[1].value.string, r[1].value.string) == .lt;
}

/// Any malformed byte makes the whole chain unusable rather than
/// partially-trusted: callers then see a miss, which is always safe.
fn parseChain(a: std.mem.Allocator, text: []const u8) !?Chain {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header_line = lines.next() orelse return null;
    const header = parseHeader(header_line) orelse return null;

    var list: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0) continue; // trailing newline
        const e = parseEntry(line) orelse return null;
        try list.append(a, e);
    }
    return Chain{ .header = header, .entries = try list.toOwnedSlice(a) };
}

fn parseHeader(line: []const u8) ?Header {
    var it = std.mem.splitScalar(u8, line, ' ');
    const schema = it.next() orelse return null;
    if (!std.mem.eql(u8, schema, SCHEMA)) return null;
    const count_s = it.next() orelse return null;
    const head_s = it.next() orelse return null;
    if (it.next() != null) return null;
    if (head_s.len != 64 or !isHex(head_s)) return null;
    const count = std.fmt.parseInt(usize, count_s, 10) catch return null;
    var head: [64]u8 = undefined;
    @memcpy(&head, head_s);
    return Header{ .count = count, .head = head };
}

fn parseEntry(line: []const u8) ?Entry {
    var it = std.mem.splitScalar(u8, line, ' ');
    const key_s = it.next() orelse return null;
    const content_s = it.next() orelse return null;
    const len_s = it.next() orelse return null;
    const link_s = it.next() orelse return null;
    if (it.next() != null) return null;
    if (key_s.len != 64 or !isHex(key_s)) return null;
    if (content_s.len != 64 or !isHex(content_s)) return null;
    if (link_s.len != 64 or !isHex(link_s)) return null;
    const len = std.fmt.parseInt(usize, len_s, 10) catch return null;
    var e: Entry = .{ .key = undefined, .content = undefined, .len = len, .link = undefined };
    @memcpy(&e.key, key_s);
    @memcpy(&e.content, content_s);
    @memcpy(&e.link, link_s);
    return e;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn verifyChain(chain: Chain) VerifyResult {
    var prev = GENESIS;
    var valid: usize = 0;
    for (chain.entries) |e| {
        var buf: [64 + 1 + 64 + 1 + 20]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "{s} {s} {d}", .{ &e.key, &e.content, e.len }) catch break;
        var link: [64]u8 = undefined;
        chainHex(prev, payload, &link);
        if (!std.mem.eql(u8, &link, &e.link)) break;
        prev = e.link;
        valid += 1;
    }

    const n = chain.entries.len;
    const links_ok = valid == n;
    const count_ok = chain.header.count == n;
    // Anchors the length: a lopped-off tail is otherwise a valid chain.
    const head_ok = if (n == 0)
        std.mem.eql(u8, &chain.header.head, &GENESIS)
    else
        std.mem.eql(u8, &chain.header.head, &chain.entries[n - 1].link);

    return VerifyResult{
        .entries = n,
        .valid_prefix = valid,
        .ok = links_ok and count_ok and head_ok,
    };
}

/// Read a whole file, or null if it does not exist. Mirrors the `std.Io` shape
/// used by vakedz/src/main.zig's readFileAlloc.
fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const st = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(st.size));
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    // Never hand back a slice shorter than the allocation: freeing it would
    // violate the allocator contract. Shrink the allocation instead.
    if (n != buf.len) return try allocator.realloc(buf, n);
    return buf;
}

pub fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, &hex);
}

pub fn chainHex(prev: [64]u8, payload: []const u8, out: *[64]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&prev);
    hasher.update(payload);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, &hex);
}
