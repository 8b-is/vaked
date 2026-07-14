// GENESIS_SEAL: 7c242080

pub const Span = struct {
    file: []const u8,
    byte_start: usize,
    byte_end: usize,
    line: usize,
    col: usize,
};

pub const Provenance = struct {
    file: []const u8,
    decl: []const u8,
    span: Span,
};
