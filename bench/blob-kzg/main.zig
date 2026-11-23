const std = @import("std");
const zevm = @import("zevm");
const harness = @import("harness");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try harness.parseArgs(allocator, "blob-kzg");
    var runner = harness.Runner.init(allocator, cfg);
    defer runner.deinit();

    const Ctx = struct {
        allocator: std.mem.Allocator,
        acc: u256 = 0,
        ts: u64 = 1_740_000_000,
    };
    var ctx = Ctx{ .allocator = allocator };

    try runner.run("blob_fee/fake_exponential", &ctx, struct {
        fn f(c: *Ctx) !void {
            const v = zevm.blob_fee.fakeExponential(1, 33_384_770, 3_338_477);
            c.acc +%= v;
            std.mem.doNotOptimizeAway(&c.acc);
        }
    }.f, .{});

    try runner.run("blob_fee/calc_blob_base_fee", &ctx, struct {
        fn f(c: *Ctx) !void {
            const v = zevm.blob_fee.calcBlobBaseFee(25_000_000, 5_007_716);
            c.acc +%= v;
            std.mem.doNotOptimizeAway(&c.acc);
        }
    }.f, .{});

    try runner.run("blob_fee/resolve_blob_params_mainnet", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.ts +%= 12;
            const p = zevm.blob_fee.resolveBlobParams(zevm.hardfork_schedule.MAINNET_CHAIN_CONFIG, 22_000_000, c.ts);
            c.acc +%= p.max_blobs;
            std.mem.doNotOptimizeAway(&c.acc);
        }
    }.f, .{});

    try runner.run("hardfork_schedule/resolve_mainnet", &ctx, struct {
        fn f(c: *Ctx) !void {
            c.ts +%= 12;
            const fork = zevm.hardfork_schedule.resolveHardfork(22_000_000, c.ts);
            std.mem.doNotOptimizeAway(&fork);
        }
    }.f, .{});

    // KZG verifier (pre-warmed trusted setup, measuring per-blob v0 proof and v1 cell proof verification)
    {
        const sidecar = try allocator.create(zevm.transaction_encoding.BlobSidecar);
        defer allocator.destroy(sidecar);
        @memset(&sidecar.blob, 0);
        const infinity = [_]u8{0xc0} ++ [_]u8{0} ** 47;
        sidecar.commitment = infinity;
        sidecar.proofs = .{ .blob = infinity };

        var verifier = zevm.blob_kzg.Verifier{};
        defer verifier.deinit();
        // Pre-load trusted setup outside timed loop
        try verifier.verify(allocator, sidecar[0..1]);

        const KzgCtx = struct {
            verifier: *zevm.blob_kzg.Verifier,
            allocator: std.mem.Allocator,
            sidecar: *zevm.transaction_encoding.BlobSidecar,
        };
        var kctx = KzgCtx{ .verifier = &verifier, .allocator = allocator, .sidecar = sidecar };

        try runner.run("blob_kzg/verify_v0_blob_proof", &kctx, struct {
            fn f(c: *KzgCtx) !void {
                try c.verifier.verify(c.allocator, c.sidecar[0..1]);
            }
        }.f, .{ .warmup_iters = 2, .bytes_per_op = sidecar.blob.len });

        sidecar.proofs = .{ .cells = [_][48]u8{infinity} ** 128 };
        try runner.run("blob_kzg/verify_v1_cell_proof_batch", &kctx, struct {
            fn f(c: *KzgCtx) !void {
                try c.verifier.verify(c.allocator, c.sidecar[0..1]);
            }
        }.f, .{ .warmup_iters = 1, .bytes_per_op = sidecar.blob.len });
    }

    try runner.finish();
}
