// GENESIS_SEAL: 7c242080
const std = @import("std");
const json = @import("json.zig");

pub const GENESIS: [64]u8 = [_]u8{'0'} ** 64;
pub const GRAMMAR_VERSION: []const u8 = "v0.5";
pub const CACHE_DIR: []const u8 = ".vakedz-cache";

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

pub const VerifyResult = struct {
    entries: usize,
    valid_prefix: usize,
    ok: bool,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    root: []const u8,

    /// Stub: records the cache root path only. Directory creation and CAS
    /// I/O land with the real implementation (0.16 filesystem access goes
    /// through `std.Io`, mirroring vakedz/src/main.zig).
    pub fn open(allocator: std.mem.Allocator, root: []const u8) !Cache {
        const cache_root = try std.fs.path.join(allocator, &.{ root, CACHE_DIR });
        return Cache{
            .allocator = allocator,
            .root = cache_root,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.root);
    }

    pub fn lookup(self: *Cache, file: []const u8, source: []const u8, phase: Phase) !?[]u8 {
        _ = file;
        _ = source;
        _ = phase;
        _ = self;
        return null;
    }

    pub fn put(self: *Cache, file: []const u8, source: []const u8, phase: Phase, output: []const u8) !void {
        _ = output;
        _ = phase;
        _ = source;
        _ = file;
        _ = self;
    }

    pub fn verify(self: *Cache) !VerifyResult {
        _ = self;
        return VerifyResult{ .entries = 0, .valid_prefix = 0, .ok = true };
    }
};

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
