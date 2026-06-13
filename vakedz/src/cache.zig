//! ralphloop-cache — the content-addressed, hash-chained compiler cache.
//!
//! This is the "native primitive" that closes Vaked's dogfooding loop. It is a
//! direct application of ralph's research bet (tools/ralph/PURPOSE.md): compile
//! *history* into an immutable, content-addressed increment instead of a growing
//! context, and you get a loop that runs indefinitely at near-flat cost while
//! staying coherent and rewindable.
//!
//! The ledger format is byte-for-byte the FROZEN ralph/eventd chain
//! (tools/ralph/ralphcore.py, eventd/core.py) so the three cross-verify:
//!
//!   one JSON object per line, append-only:
//!     {"seq":N,"prev":<hex sha256 of prev entry, GENESIS="0"*64>,
//!      "payload":<canonical-json event body, sorted keys>,
//!      "hash":sha256(prev_hex ++ canonical_json(payload))}
//!
//! Layout on disk (gitignored, ephemeral — rebuildable from sources):
//!     .vakedz-cache/ledger.jsonl   the hash-chained state-of-record
//!     .vakedz-cache/cas/<sha256>   content-addressed output blobs (graph JSON…)
//!
//! A cache *hit* is deterministic: hash the source, scan the ledger for the
//! latest matching {event,file,source_sha256,grammar_version}, fetch the cached
//! output from the CAS by its content hash. Same source ⇒ same key ⇒ replay,
//! never recompute.
//!
//! Zig 0.16: all file I/O goes through the `std.Io` interface (Dir/File take an
//! `io`). The ledger is small, so appends are done as a whole-file rewrite.

const std = @import("std");
const json = @import("json.zig");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const GENESIS: [64]u8 = "0000000000000000000000000000000000000000000000000000000000000000".*;
pub const GRAMMAR_VERSION = "v0.3";
pub const CACHE_DIR = ".vakedz-cache";

/// Hex sha256 of `bytes` into a caller-supplied 64-byte buffer.
pub fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    out.* = std.fmt.bytesToHex(digest, .lower);
}

/// chain_hash(prev_hex, payload) = sha256(prev_hex ++ canonical_json(payload)).
/// Identical to ralphcore.chain_hash / eventd.core.chain_hash.
pub fn chainHex(prev_hex: []const u8, payload_canonical: []const u8, out: *[64]u8) void {
    var h = Sha256.init(.{});
    h.update(prev_hex);
    h.update(payload_canonical);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
}

pub const Phase = enum {
    parse,
    check,
    lower,

    pub fn str(self: Phase) []const u8 {
        return @tagName(self);
    }
};

const MAX_LEDGER = 64 * 1024 * 1024;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir: []const u8, // root/CACHE_DIR

    pub fn open(allocator: std.mem.Allocator, io: Io, root: []const u8) !Cache {
        const dir = try std.fs.path.join(allocator, &.{ root, CACHE_DIR });
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(io, dir) catch {};
        const cas = try std.fs.path.join(allocator, &.{ dir, "cas" });
        defer allocator.free(cas);
        cwd.createDirPath(io, cas) catch {};
        return .{ .allocator = allocator, .io = io, .dir = dir };
    }

    fn ledgerPath(self: Cache) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.dir, "ledger.jsonl" });
    }

    fn casPath(self: Cache, hex: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.dir, "cas", hex });
    }

    /// Read the whole ledger (or "" if absent).
    fn readLedger(self: Cache) ![]u8 {
        const path = try self.ledgerPath();
        defer self.allocator.free(path);
        return Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited) catch
            try self.allocator.dupe(u8, "");
    }

    /// Look up a cached output for (file, source, phase). Returns the cached
    /// bytes on a hit, or null on a miss. Deterministic: the key is the source
    /// content hash + grammar version + phase.
    pub fn lookup(self: Cache, file: []const u8, source: []const u8, phase: Phase) !?[]u8 {
        var src_hex: [64]u8 = undefined;
        sha256Hex(source, &src_hex);

        const body = try self.readLedger();
        defer self.allocator.free(body);

        var found: ?[64]u8 = null;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const payload_v = parsed.value.object.get("payload") orelse continue;
            if (payload_v != .object) continue;
            const payload = payload_v.object;
            if (!eqStr(payload.get("event"), phase.str())) continue;
            if (!eqStr(payload.get("file"), file)) continue;
            if (!eqStr(payload.get("source_sha256"), &src_hex)) continue;
            if (!eqStr(payload.get("grammar_version"), GRAMMAR_VERSION)) continue;
            const out = payload.get("output_sha256") orelse continue;
            if (out != .string or out.string.len != 64) continue;
            var h: [64]u8 = undefined;
            @memcpy(&h, out.string[0..64]);
            found = h;
        }

        const out_hex = found orelse return null;
        const cas = try self.casPath(&out_hex);
        defer self.allocator.free(cas);
        return Io.Dir.cwd().readFileAlloc(self.io, cas, self.allocator, .unlimited) catch null;
    }

    /// Record (file, source, phase) -> output. Writes the output blob to the CAS
    /// (keyed by its own content hash) and appends one hash-chained ledger entry
    /// binding the source key to the output hash.
    pub fn put(self: Cache, file: []const u8, source: []const u8, phase: Phase, output: []const u8) !void {
        const cwd = Io.Dir.cwd();
        var src_hex: [64]u8 = undefined;
        sha256Hex(source, &src_hex);
        var out_hex: [64]u8 = undefined;
        sha256Hex(output, &out_hex);

        // CAS write (idempotent: same content ⇒ same path).
        const cas = try self.casPath(&out_hex);
        defer self.allocator.free(cas);
        if (cwd.access(self.io, cas, .{})) |_| {} else |_| {
            try cwd.writeFile(self.io, .{ .sub_path = cas, .data = output });
        }

        // Determine prev hash + next seq from the ledger tail.
        const body = try self.readLedger();
        defer self.allocator.free(body);
        var prev: [64]u8 = GENESIS;
        var seq: i64 = 0;
        {
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                if (parsed.value.object.get("hash")) |h| {
                    if (h == .string and h.string.len == 64) @memcpy(&prev, h.string[0..64]);
                }
                if (parsed.value.object.get("seq")) |s| {
                    if (s == .integer) seq = s.integer + 1;
                }
            }
        }

        // Canonical payload (deterministic — no clock — and key-sorted so the
        // chain hash is byte-compatible with the ralph/eventd ledgers). Built on
        // the heap so sortRecursive may reorder keys in place.
        const payload_entries = try self.allocator.dupe(json.Value.Entry, &.{
            .{ .key = "event", .value = .{ .string = phase.str() } },
            .{ .key = "file", .value = .{ .string = file } },
            .{ .key = "source_sha256", .value = .{ .string = &src_hex } },
            .{ .key = "grammar_version", .value = .{ .string = GRAMMAR_VERSION } },
            .{ .key = "output_sha256", .value = .{ .string = &out_hex } },
        });
        var payload = json.Value{ .object = payload_entries };
        payload.sortRecursive();
        const payload_json = try payload.toOwned(self.allocator);
        defer self.allocator.free(payload_json);

        var hash_hex: [64]u8 = undefined;
        chainHex(&prev, payload_json, &hash_hex);

        const entry = json.Value{ .object = &.{
            .{ .key = "seq", .value = .{ .int = seq } },
            .{ .key = "prev", .value = .{ .string = &prev } },
            .{ .key = "payload", .value = payload },
            .{ .key = "hash", .value = .{ .string = &hash_hex } },
        } };
        const entry_json = try entry.toOwned(self.allocator);
        defer self.allocator.free(entry_json);

        // Append by whole-file rewrite (the ledger is small).
        const full = try std.mem.concat(self.allocator, u8, &.{ body, entry_json, "\n" });
        defer self.allocator.free(full);
        const path = try self.ledgerPath();
        defer self.allocator.free(path);
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = full });
    }

    pub const VerifyResult = struct { entries: usize, valid_prefix: usize, ok: bool };

    /// Walk the chain, recomputing each link. Returns the longest valid prefix
    /// (torn-tail recovery, like ralphcore.longest_valid_prefix).
    pub fn verify(self: Cache) !VerifyResult {
        const body = try self.readLedger();
        defer self.allocator.free(body);
        var prev: [64]u8 = GENESIS;
        var expect_seq: i64 = 0;
        var valid: usize = 0;
        var total: usize = 0;
        var it = std.mem.splitScalar(u8, body, '\n');
        outer: while (it.next()) |line| {
            if (line.len == 0) continue;
            total += 1;
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch break :outer;
            defer parsed.deinit();
            if (parsed.value != .object) break :outer;
            const obj = parsed.value.object;
            const seq = obj.get("seq") orelse break :outer;
            const ent_prev = obj.get("prev") orelse break :outer;
            const ent_hash = obj.get("hash") orelse break :outer;
            if (seq != .integer or seq.integer != expect_seq) break :outer;
            if (ent_prev != .string or !std.mem.eql(u8, ent_prev.string, &prev)) break :outer;
            const payload_raw = rawPayload(line) orelse break :outer;
            var computed: [64]u8 = undefined;
            chainHex(&prev, payload_raw, &computed);
            if (ent_hash != .string or !std.mem.eql(u8, ent_hash.string, &computed)) break :outer;
            @memcpy(&prev, &computed);
            expect_seq += 1;
            valid += 1;
        }
        return .{ .entries = total, .valid_prefix = valid, .ok = valid == total };
    }
};

fn eqStr(v: ?std.json.Value, want: []const u8) bool {
    const val = v orelse return false;
    return val == .string and std.mem.eql(u8, val.string, want);
}

/// Extract the raw `payload` object bytes from a canonical ledger line, i.e. the
/// substring between `"payload":` and `,"hash":`. The chain entry is always
/// `{"seq":N,"prev":"…","payload":{…},"hash":"…"}`, so this is exact.
fn rawPayload(line: []const u8) ?[]const u8 {
    const marker = "\"payload\":";
    const start = std.mem.indexOf(u8, line, marker) orelse return null;
    const ps = start + marker.len;
    const tail = "},\"hash\":";
    const end = std.mem.lastIndexOf(u8, line, tail) orelse return null;
    if (end + 1 < ps) return null;
    return line[ps .. end + 1]; // include the payload's closing '}'
}

// ---- tests ---------------------------------------------------------------

test "sha256Hex matches known vector (empty string)" {
    var out: [64]u8 = undefined;
    sha256Hex("", &out);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "chainHex over GENESIS is deterministic" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    chainHex(&GENESIS, "{\"x\":1}", &a);
    chainHex(&GENESIS, "{\"x\":1}", &b);
    try std.testing.expectEqualStrings(&a, &b);
}
