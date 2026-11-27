const std = @import("std");
const crypto = @import("crypto");
const transaction_encoding = @import("transaction_encoding.zig");
const ckzg = @cImport(@cInclude("ckzg.h"));

/// Lazily initialized c-kzg verifier backed by Voltaire's embedded Ethereum
/// trusted setup. Owned by `NodeRuntime`; the structural wrapper decoder never
/// initializes cryptography on its own.
pub const Verifier = struct {
    settings: ?ckzg.KZGSettings = null,
    mutex: std.Thread.Mutex = .{},

    pub fn deinit(self: *Verifier) void {
        if (self.settings) |*settings| ckzg.free_trusted_setup(settings);
        self.settings = null;
    }

    pub fn verify(
        self: *Verifier,
        allocator: std.mem.Allocator,
        sidecars: []const transaction_encoding.BlobSidecar,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.settings == null) self.settings = try loadSettings(allocator);
        const settings = &self.settings.?;
        for (sidecars) |*sidecar| {
            var ok: bool = false;
            switch (sidecar.proofs) {
                .blob => |*proof| try check(ckzg.verify_blob_kzg_proof(
                    &ok,
                    @ptrCast(&sidecar.blob),
                    @ptrCast(&sidecar.commitment),
                    @ptrCast(proof),
                    settings,
                )),
                .cells => |*proofs| {
                    const cells = try allocator.alloc(ckzg.Cell, ckzg.CELLS_PER_EXT_BLOB);
                    defer allocator.free(cells);
                    try check(ckzg.compute_cells_and_kzg_proofs(cells.ptr, null, @ptrCast(&sidecar.blob), settings));
                    const commitments = [_]ckzg.Bytes48{.{ .bytes = sidecar.commitment }} ** ckzg.CELLS_PER_EXT_BLOB;
                    var indices: [ckzg.CELLS_PER_EXT_BLOB]u64 = undefined;
                    for (&indices, 0..) |*index, i| index.* = i;
                    try check(ckzg.verify_cell_kzg_proof_batch(
                        &ok,
                        &commitments,
                        &indices,
                        cells.ptr,
                        @ptrCast(proofs),
                        cells.len,
                        settings,
                    ));
                },
            }
            if (!ok) return error.InvalidBlobProof;
        }
    }
};

fn check(result: ckzg.C_KZG_RET) !void {
    return switch (result) {
        ckzg.C_KZG_OK => {},
        ckzg.C_KZG_MALLOC => error.OutOfMemory,
        ckzg.C_KZG_BADARGS => error.InvalidBlobProof,
        else => error.KzgFailure,
    };
}

fn loadSettings(allocator: std.mem.Allocator) !ckzg.KZGSettings {
    try crypto.kzg_trusted_setup.verify();
    var lines = std.mem.tokenizeAny(u8, crypto.kzg_trusted_setup.data, "\r\n");
    _ = lines.next(); // Verified G1 and G2 counts.
    _ = lines.next();
    const lagrange = try setupPoints(allocator, &lines, 4096, 48);
    defer allocator.free(lagrange);
    const g2 = try setupPoints(allocator, &lines, 65, 96);
    defer allocator.free(g2);
    const monomial = try setupPoints(allocator, &lines, 4096, 48);
    defer allocator.free(monomial);
    var settings: ckzg.KZGSettings = undefined;
    try check(ckzg.load_trusted_setup(
        &settings,
        monomial.ptr,
        monomial.len,
        lagrange.ptr,
        lagrange.len,
        g2.ptr,
        g2.len,
        0,
    ));
    return settings;
}

fn setupPoints(allocator: std.mem.Allocator, lines: *std.mem.TokenIterator(u8, .any), count: usize, size: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, count * size);
    errdefer allocator.free(bytes);
    for (0..count) |i| {
        _ = try std.fmt.hexToBytes(bytes[i * size ..][0..size], lines.next() orelse return error.InvalidSetup);
    }
    return bytes;
}

test "both v0 blob proof and v1 cell proof formats verify the zero polynomial and reject tampering" {
    const allocator = std.testing.allocator;
    const sidecar = try allocator.create(transaction_encoding.BlobSidecar);
    defer allocator.destroy(sidecar);
    @memset(&sidecar.blob, 0);
    const infinity = [_]u8{0xc0} ++ [_]u8{0} ** 47;
    sidecar.commitment = infinity;
    var verifier = Verifier{};
    defer verifier.deinit();
    inline for (.{ false, true }) |cells| {
        sidecar.proofs = if (cells)
            .{ .cells = [_][48]u8{infinity} ** ckzg.CELLS_PER_EXT_BLOB }
        else
            .{ .blob = infinity };
        sidecar.blob[31] = 0;
        try verifier.verify(allocator, sidecar[0..1]);
        sidecar.blob[31] = 1;
        try std.testing.expectError(error.InvalidBlobProof, verifier.verify(allocator, sidecar[0..1]));
    }
}
