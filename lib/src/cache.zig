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
//! # What decides a phase's output
//!
//! There are two kinds of input, and both must be in the key:
//!
//! 1. **Data** — the source bytes, the file path, and (for check/lower) the
//!    builtins catalog and lowering options.
//! 2. **The compiler itself.** A parser bugfix changes output with every byte
//!    of data unchanged. This is not hypothetical: four parser fixes landed in
//!    a single session (inline comments/`pending_newline`, comment round-trip,
//!    comment loss/blank lines, union types in generic args) — every one of
//!    them changes emitted output, and none of them touched the language
//!    version. A cache that keys only data serves the pre-fix result to the
//!    post-fix compiler, which is exactly the wrong hit this module exists to
//!    make impossible. So `build_id` is a required, keyed input.
//!
//! `GRAMMAR_VERSION` does NOT stand in for the compiler. It tracks the language
//! *spec*, is hand-maintained, and has already drifted from the implementation
//! in practice. It is keyed because a spec bump *should* invalidate, but it is
//! not load-bearing for soundness and must never be treated as such.
//!
//! # Key derivation
//!
//! The cache key is `sha256(K)` where `K` is the canonical JSON document
//! (compact, keys in the fixed order below — `json.zig` never reorders, so
//! canonicality is produced here deliberately):
//!
//! ```text
//! {"build":<sha256(build_id) hex>,
//!  "deps":[{"name":<name>,"sha256":<hex>},...],
//!  "file":<path>,
//!  "grammar":<grammar version>,
//!  "phase":"parse"|"check"|"lower",
//!  "schema":"vakedz-cache-2",
//!  "source":<sha256(source bytes) hex>}
//! ```
//!
//! Field-by-field rationale:
//!
//! * `build` — the identity of the compiler that produces the output. See the
//!   `build_id` contract below.
//! * `source` — the source bytes decide the output. Hashed, not embedded, so
//!   the key stays fixed-size.
//! * `file` — the path is *not* incidental: diagnostics and provenance embed
//!   the filename, so two identical sources at different paths legitimately
//!   produce different output. The path is used verbatim, so `./a.vaked` and
//!   `a.vaked` key differently — that costs an extra miss, never a wrong hit.
//! * `grammar` — a language-spec bump invalidates. Not a compiler identity.
//! * `phase` — hard isolation: a `parse` entry can never serve a `check`
//!   lookup even at an identical source.
//! * `schema` — this file's on-disk/keying contract. Bumping it invalidates
//!   every key, which is what a layout or derivation change requires.
//! * `deps` — the per-phase inputs, derived from `Inputs` (never supplied as
//!   caller-computed hashes; see below) and sorted by (name, hash) so ordering
//!   cannot change a key.
//!
//! # The `build_id` contract — the one thing this module must be told
//!
//! This module cannot observe the compiler that links it: Zig 0.16 has no
//! `selfExePath`, and reaching into `vakedz/src/` from `lib/` would invert the
//! layering. Only the build system knows. So `open` takes `build_id` as a
//! **required** parameter — there is no default and no way to omit it, because
//! a forgettable build id is the same wrong-hit bug with extra steps. An empty
//! `build_id` is rejected (`error.BuildIdRequired`): it is indistinguishable
//! from "nobody wired this up".
//!
//! `build_id` must be the raw identity bytes (this module hashes them itself,
//! and never accepts a pre-computed hash). It MUST change whenever compiler
//! behaviour can change, and it must never be a hand-edited constant — that is
//! precisely how `GRAMMAR_VERSION` drifted.
//!
//! ## What `build_id` must cover — get this wrong and the bug comes back
//!
//! **The whole compiled module graph, not just `vakedz/src/**`.** `vakedz`
//! imports this very package: `vakedz/src/emit.zig` does `@import("lib")` and
//! emits through `lib/src/json.zig`, whose own doc warns its escape table must
//! not drift from emit.zig's `writeSpaced`. So a fix to `json.zig` changes
//! emitted output while `vakedz/src/**` is byte-identical. A `build_id` derived
//! from `vakedz/src/**` alone would not move, the key would not move, and the
//! stale output would be served — the exact wrong hit this field exists to
//! prevent. Cover `vakedz/src/**` AND `lib/src/**`, and prefer deriving the
//! file set from the build graph over a hardcoded directory list, so that a
//! future third module cannot silently fall outside it.
//!
//! Recommended ingredients, all cheap and all able to change output:
//!
//! * A hash of every source file in the compiled module graph (see above).
//! * `git describe --always --dirty`. Note what `--dirty` does and does not do:
//!   it flags modifications to *tracked* files only, so it misses a brand-new
//!   untracked `.zig` file that is nonetheless compiled in. The source hash is
//!   what covers that case — the two are complements, not alternatives, which
//!   is why both are listed.
//! * `@import("builtin").zig_version` — a compiler upgrade can change codegen
//!   and stdlib behaviour underneath identical sources.
//! * `@import("builtin").mode` — optimize mode can change observable output
//!   (e.g. safety checks, and any behaviour that differs under ReleaseFast).
//!
//! # Per-phase inputs: `Inputs`, not caller-supplied hashes
//!
//! `parse` is decided by (build, source, file). `check` additionally reads the
//! builtins catalog; `lower` reads builtins plus its lowering options. This
//! module cannot read those files, so the caller must provide them — but it
//! provides the **bytes**, not a hash or a name/hash pair.
//!
//! That distinction is the whole guardrail, and it has two halves, because
//! `Inputs` alone prevents *omission*, not *emptiness*:
//!
//! 1. **Compile time — you must name the input.** `Inputs` is an enum-backed
//!    union, so `.check` cannot be constructed without a `builtins` field.
//!    Forgetting it is a compile error.
//! 2. **Run time — you must mean it.** Naming the field is not meaning it:
//!    `.check = .{ .builtins = "" }` compiles and would key cleanly. The
//!    realistic path there is not malice but `readFileAlloc(...) orelse ""`,
//!    or a `.builtins = ""` placeholder left behind during wiring. An empty
//!    builtins catalog is never legitimate, and the same reasoning that
//!    rejects an empty `build_id` applies verbatim: empty is
//!    indistinguishable from "nobody wired this up". So `deriveKey` rejects
//!    it (`error.BuiltinsRequired`), and both `lookup` and `put` inherit
//!    that. Fail closed.
//!
//! `lower.options` gets the same treatment for the same reason
//! (`error.OptionsRequired`), with one wrinkle: unlike builtins, empty
//! options could *legitimately* mean "all defaults". That ambiguity is
//! exactly the problem — `""` would mean both "defaults" and "forgot". So
//! "defaults" has a canonical non-empty spelling: pass `"{}"`. It keys
//! distinctly, and it is unambiguous evidence the caller decided.
//!
//! None of this makes the caller irrelevant: passing the *wrong* builtins
//! still mis-keys, and no in-module check can catch that. Keep the `Inputs`
//! construction in the same function that reads the inputs, so the two
//! cannot drift.
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
//! vakedz-cache-2 <count> <head_link>
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
//!
//! # Known scaling limit (correctness first; no callers yet)
//!
//! Every `put` rewrites the whole chain and every `lookup` recomputes every
//! link: O(n) per op, O(n^2) cumulative. Acceptable at today's zero callers,
//! not at 10k entries. Fixing it needs an epoch/compaction story, tracked
//! separately — deliberately not traded against correctness here.
const std = @import("std");
const json = @import("json.zig");

pub const GENESIS: [64]u8 = [_]u8{'0'} ** 64;

/// The language *spec* version. Keyed so a spec bump invalidates — but this is
/// NOT the compiler's identity and carries no soundness weight. See `build_id`.
pub const GRAMMAR_VERSION: []const u8 = "v0.5";
pub const CACHE_DIR: []const u8 = ".vakedz-cache";

/// On-disk + key-derivation contract version. Bump on any change to the
/// layout, the chain format, or the key document: it invalidates every key.
/// Bumped to -2 when `build` entered the key document.
pub const SCHEMA: []const u8 = "vakedz-cache-2";

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
};

/// The inputs a phase reads, beyond source/file/build. Enum-backed union so a
/// phase cannot be named without supplying its inputs: `.check` is
/// unconstructible without builtins bytes, making "forgot the builtins" a
/// compile error instead of a silent wrong hit.
///
/// Always pass the raw bytes. This module hashes them; it never takes a hash
/// on trust, because a caller-computed hash can be forged or defaulted.
pub const Inputs = union(Phase) {
    parse: void,
    check: Check,
    lower: Lower,

    pub const Check = struct {
        /// Contents of the builtins catalog (`vaked/schema/builtins.vaked`).
        /// Must be non-empty: empty reads as "nobody wired this up".
        builtins: []const u8,
    };

    pub const Lower = struct {
        /// Must be non-empty. See `Check.builtins`.
        builtins: []const u8,
        /// Canonical serialization of the lowering options that affect output.
        /// Must be non-empty; spell "all defaults" as `"{}"`, so that the
        /// bytes distinguish "decided on defaults" from "forgot to pass them".
        options: []const u8,
    };

    pub fn phase(self: Inputs) Phase {
        return std.meta.activeTag(self);
    }
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
    /// Refusing to append to a chain that does not verify.
    ChainBroken,
    /// `build_id` was empty — indistinguishable from "nobody wired this up",
    /// which is the state that produces wrong hits across compiler upgrades.
    /// Fail closed.
    BuildIdRequired,
    /// `check`/`lower` were given empty builtins. An empty builtins catalog is
    /// never legitimate; naming the field is not the same as meaning it.
    BuiltinsRequired,
    /// `lower` was given empty options. Empty is ambiguous between "defaults"
    /// and "forgot"; spell defaults `"{}"`.
    OptionsRequired,
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

/// A `name`/`bytes` pair contributing to the key. Internal by design: deps are
/// derived from `Inputs` and hashed here, never accepted from the caller
/// pre-hashed.
const Dep = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    /// Grammar version mixed into every key. Split out from the constant so a
    /// bump is expressible without recompiling — and so it is testable.
    grammar: []const u8,
    /// sha256 of the caller-supplied `build_id` bytes, hashed at `open`.
    build: [64]u8,

    /// Open (creating if absent) the cache under `<root>/.vakedz-cache`.
    /// `root` is resolved against the process cwd, mirroring vakedz/src/main.zig.
    ///
    /// `build_id` identifies the compiler build and is REQUIRED — see the
    /// contract in the module doc. Pass raw identity bytes (e.g. `git describe
    /// --always --dirty` output plus a compiler-source hash), not a digest.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        build_id: []const u8,
    ) !Cache {
        if (build_id.len == 0) return Error.BuildIdRequired;

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

        var build: [64]u8 = undefined;
        sha256Hex(build_id, &build);

        return Cache{
            .allocator = allocator,
            .io = io,
            .root = cache_root,
            .grammar = GRAMMAR_VERSION,
            .build = build,
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
        inputs: Inputs,
        out: *[64]u8,
    ) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Deps are derived from `Inputs`, so the set is decided by the phase —
        // a caller cannot omit or rename one. The emptiness checks close the
        // other half: `Inputs` makes you NAME builtins, these make you MEAN it.
        var dep_buf: [2]Dep = undefined;
        const deps: []const Dep = switch (inputs) {
            .parse => dep_buf[0..0],
            .check => |c| blk: {
                if (c.builtins.len == 0) return Error.BuiltinsRequired;
                dep_buf[0] = .{ .name = "builtins", .bytes = c.builtins };
                break :blk dep_buf[0..1];
            },
            .lower => |l| blk: {
                if (l.builtins.len == 0) return Error.BuiltinsRequired;
                // "defaults" is spelled "{}", never "" — see the module doc.
                if (l.options.len == 0) return Error.OptionsRequired;
                dep_buf[0] = .{ .name = "builtins", .bytes = l.builtins };
                dep_buf[1] = .{ .name = "options", .bytes = l.options };
                break :blk dep_buf[0..2];
            },
        };

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
        // Sort so dep ordering cannot change the key.
        std.mem.sort(json.Value, dep_vals, {}, depLess);

        const top = try a.alloc(json.Value.Entry, 7);
        top[0] = .{ .key = "build", .value = .{ .string = &self.build } };
        top[1] = .{ .key = "deps", .value = .{ .array = dep_vals } };
        top[2] = .{ .key = "file", .value = .{ .string = file } };
        top[3] = .{ .key = "grammar", .value = .{ .string = self.grammar } };
        top[4] = .{ .key = "phase", .value = .{ .string = inputs.phase().str() } };
        top[5] = .{ .key = "schema", .value = .{ .string = SCHEMA } };
        top[6] = .{ .key = "source", .value = .{ .string = &src_hex } };

        const canonical = try (json.Value{ .object = top }).toOwned(a);
        sha256Hex(canonical, out);
    }

    /// Return the cached output for this key, or null on any doubt.
    /// Caller owns the returned slice.
    pub fn lookup(
        self: *Cache,
        file: []const u8,
        source: []const u8,
        inputs: Inputs,
    ) !?[]u8 {
        var key: [64]u8 = undefined;
        try self.deriveKey(file, source, inputs, &key);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const chain = switch (try self.readChain(a)) {
            .absent, .corrupt => return null, // any doubt is a miss
            .present => |c| c,
        };
        const vr = verifyChain(chain);

        // Scan backwards so the newest entry for a key wins. Keys are meant to
        // be functional (same key => same output), so a duplicate key should be
        // unreachable; if a nondeterministic phase ever produced one anyway,
        // newest-wins matches `put`'s append order and the freshest compile.
        // Only the cryptographically intact prefix is eligible.
        var i = vr.valid_prefix;
        while (i > 0) {
            i -= 1;
            const e = chain.entries[i];
            if (!std.mem.eql(u8, &e.key, &key)) continue;

            const blob = (try self.readBlob(self.allocator, e.content)) orelse return null;
            // Intentionally inert: nothing between here and the returns below
            // can fail today. Kept so a future fallible step cannot leak.
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
        inputs: Inputs,
        output: []const u8,
    ) !void {
        var key: [64]u8 = undefined;
        try self.deriveKey(file, source, inputs, &key);

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
